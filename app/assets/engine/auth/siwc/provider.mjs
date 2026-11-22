// SPDX-License-Identifier: MIT

import { createRequire } from 'node:module'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

// The engine entry lives under the real rootfs path in Android Direct mode.
// CI runs the adapter outside the engine with an explicit locked prefix.
const testPrefix = process.env.DSH_TEST_PREFIX
const hostRequire = createRequire(testPrefix
  ? resolve(testPrefix, 'package.json')
  : resolve(process.argv[1] ?? '/opt/dsh/package.json'))
const llmPackage = pathToFileURL(hostRequire.resolve('@deepseek-ai/dsh-llm/package.json'))
const piAi = new URL('../../@earendil-works/pi-ai/dist/', llmPackage)
const [
  { LlmAdapter, LlmError, attributionHeaders, resolveRetryPolicy },
  { convertResponsesMessages, convertResponsesTools, processResponsesStream },
  { AssistantMessageEventStream },
] = await Promise.all([
  import(pathToFileURL(hostRequire.resolve('@deepseek-ai/dsh-llm')).href),
  import(new URL('api/openai-responses-shared.js', piAi).href),
  import(new URL('utils/event-stream.js', piAi).href),
])
const { _iterSSEMessages } = hostRequire('openai/streaming')

const PROVIDER = 'openai-siwc'
const BASE_URL = 'https://api.openai.com/v1'
const API = 'openai-responses'
// Let the combined catalog report this provider's failure without blocking other routes.
const MODEL_CATALOG_TIMEOUT_MS = 5_000
const RETRY_POLICY = resolveRetryPolicy({ mode: 'normal', maxRetries: 0 }, PROVIDER)
const ITEM_TYPES = new Set(['message', 'reasoning', 'function_call'])
const LOGIN_ERRORS = new Set(['siwc_sign_in_required', 'siwc_session_expired', 'siwc_plan_permission_missing'])

function argumentsObject(raw) {
  try {
    const value = JSON.parse(raw)
    if (value && typeof value === 'object' && !Array.isArray(value)) return value
  } catch {
    // Arguments may contain secrets.
  }
  throw new LlmError('A local function call has invalid JSON arguments.', 'INVALID_REQUEST')
}

function piMessages(messages) {
  return messages.map(({ role, content, source, toolCallId, isError }) => {
    const blocks = content.flatMap((block) => {
      switch (block.type) {
        case 'text': return [block]
        case 'tool-call': return [{
          type: 'toolCall', id: block.id, name: block.name, arguments: argumentsObject(block.arguments),
        }]
        case 'reasoning':
        case 'tool-addition':
        case 'tool-removal': return []
        default: throw new LlmError('This SIWC adapter accepts text, not attachments.', 'INVALID_REQUEST')
      }
    })
    if (role === 'assistant') {
      return { role, content: blocks, provider: source?.provider, model: source?.model, api: API, stopReason: 'stop' }
    }
    if (role === 'tool') return { role: 'toolResult', content: blocks, toolCallId, isError }
    return { role: role === 'developer' ? 'system' : role, content: blocks }
  })
}

function responsesBody(model, options) {
  const input = convertResponsesMessages(model, { messages: piMessages(options.messages) }, new Set([PROVIDER]), {
    supportsMidConvoSystemMessages: true,
  }).map((item) => {
    // Developer instructions only; no server-stored output item references.
    if (item.role === 'system') return { ...item, role: 'developer' }
    if (item.type === 'message' || item.type === 'function_call') {
      const { id, ...stateless } = item
      return stateless
    }
    return item
  })
  if (options.tools?.length) {
    input.unshift({ type: 'additional_tools', role: 'developer', tools: convertResponsesTools(options.tools) })
  }
  return {
    model: model.id, input, store: false, stream: true,
    ...(options.system ? { instructions: options.system } : {}),
  }
}

function identifier(value) {
  return typeof value === 'string' && /^[a-zA-Z0-9_.-]{1,128}$/.test(value) ? value : undefined
}

function responseError(response, payload, fallback, { code, status } = {}) {
  const errorCode = identifier(payload?.code) ?? code ?? 'SIWC_API_ERROR'
  const param = identifier(payload?.param)
  const requestId = identifier(response.headers.get('x-request-id'))
  const help = errorCode === 'subscription_sharing_usage_limit_exceeded' ? 'https://chatgpt.com/settings/usage' : undefined
  // Never forward upstream message/detail; either may quote request content or credentials.
  return new LlmError(
    [fallback, errorCode, param && 'parameter: ' + param, help].filter(Boolean).join(': '),
    errorCode, { status, requestId },
  )
}

async function* responsesEvents(response, request) {
  for await (const sse of _iterSSEMessages(response, request)) {
    if (sse.data === '[DONE]') break
    let event
    try {
      event = JSON.parse(sse.data)
    } catch {
      throw new LlmError('Malformed OpenAI Responses event.', 'MALFORMED_RESPONSE')
    }
    const type = event?.type ?? sse.event
    if (type === 'response.failed' || type === 'error' || sse.event === 'error') {
      throw responseError(response, event?.response?.error ?? event?.error ?? event, 'OpenAI Responses failed')
    }
    if (type === 'response.incomplete' || type === 'response.cancelled') {
      const reason = identifier(event?.response?.incomplete_details?.reason)
      throw new LlmError(reason ? 'OpenAI response incomplete: ' + reason : 'OpenAI response did not complete.', 'SIWC_INCOMPLETE')
    }
    if (type === 'response.output_item.added' || type === 'response.output_item.done') {
      if (!ITEM_TYPES.has(event?.item?.type)) throw new LlmError('Unsupported OpenAI Responses output item.', 'MALFORMED_RESPONSE')
    }
    if (type === 'response.completed' && event.response?.status !== 'completed') {
      throw new LlmError('Invalid OpenAI response terminal status.', 'MALFORMED_RESPONSE')
    }
    yield { ...event, type }
    if (type === 'response.completed') return
  }
  request.signal.throwIfAborted()
  throw new LlmError('OpenAI Responses stream ended without response.completed.', 'STREAM_CLOSED')
}

async function* decodeResponse(response, request, model) {
  const events = new AssistantMessageEventStream()
  const output = {
    content: [], stopReason: 'pending',
    usage: {
      input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
  }
  let failure
  const decoded = processResponsesStream(responsesEvents(response, request), output, events, model)
    .catch((error) => { failure = error })
    .finally(() => events.end(output))
  const tools = []
  for await (const event of events) {
    request.signal.throwIfAborted()
    const index = event.contentIndex
    switch (event.type) {
      case 'text_start': yield { type: 'block-start', index, blockType: 'text' }; break
      case 'text_delta': yield { type: 'text-delta', index, text: event.delta }; break
      case 'text_end': yield { type: 'block-end', index, block: { type: 'text', text: event.content } }; break
      case 'thinking_start': yield { type: 'block-start', index, blockType: 'reasoning' }; break
      case 'thinking_delta': yield { type: 'reasoning-delta', index, text: event.delta }; break
      case 'thinking_end': yield { type: 'block-end', index, block: { type: 'reasoning', text: event.content } }; break
      case 'toolcall_start': yield { type: 'block-start', index, blockType: 'tool-call' }; break
      case 'toolcall_delta': {
        const { id, name } = event.partial.content[index]
        yield { type: 'tool-call-delta', index, id: id.split('|')[0], name, argumentsDelta: event.delta }
        break
      }
      case 'toolcall_end': {
        const { id, name, arguments: args, argumentsError } = event.toolCall
        const callId = id.split('|')[0]
        if (argumentsError || !callId || !name) throw new LlmError('Invalid OpenAI function call.', 'MALFORMED_RESPONSE')
        tools.push({ type: 'block-end', index, block: { type: 'tool-call', id: callId, name, arguments: JSON.stringify(args) } })
        break
      }
    }
  }
  await decoded
  request.signal.throwIfAborted()
  if (failure) throw failure
  // An item-level done event is not enough to dispatch a local tool.
  for (const tool of tools) {
    request.signal.throwIfAborted()
    yield tool
  }
  request.signal.throwIfAborted()
  const { input, output: outputTokens, totalTokens, cacheRead, cacheWrite, reasoning } = output.usage
  yield { type: 'usage', usage: {
    inputTokens: input, outputTokens, totalTokens,
    ...(cacheRead ? { cacheReadTokens: cacheRead } : {}),
    ...(cacheWrite ? { cacheWriteTokens: cacheWrite } : {}),
    ...(reasoning ? { reasoningTokens: reasoning } : {}),
  } }
  request.signal.throwIfAborted()
  yield { type: 'finish', reason: { kind: tools.length ? 'tool-calls' : 'stop' } }
}

export function registerSiwcProvider({ llm, oauth, fetch = globalThis.fetch }) {
  let account = new AbortController()
  let catalog = new AbortController()
  let names = new Map()
  let disposed = false

  async function request(path, signal, body) {
    signal.throwIfAborted()
    let token
    try {
      token = await oauth.token(signal)
    } catch (error) {
      signal.throwIfAborted()
      if (LOGIN_ERRORS.has(error?.code)) {
        throw new LlmError('This provider needs a ChatGPT login with plan access.', 'SIWC_SIGN_IN_REQUIRED')
      }
      throw new LlmError('OpenAI authorization is temporarily unavailable.', 'SIWC_AUTH_UNAVAILABLE')
    }
    signal.throwIfAborted()
    if (typeof token !== 'string' || !token || /\s/.test(token) || token.startsWith('sk-')) {
      throw new LlmError('Sign in with ChatGPT to use this provider.', 'SIWC_SIGN_IN_REQUIRED')
    }
    const response = await fetch(BASE_URL + path, {
      method: body ? 'POST' : 'GET', signal, redirect: 'error',
      headers: {
        ...attributionHeaders(),
        Authorization: 'Bearer ' + token,
        Accept: body ? 'text/event-stream' : 'application/json',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    })
    if (!response.ok) {
      const payload = await response.json().catch(() => null)
      signal.throwIfAborted()
      throw responseError(response, payload?.error, 'OpenAI HTTP ' + response.status, {
        code: response.status === 401 ? 'SIWC_SIGN_IN_REQUIRED' : 'SIWC_HTTP_ERROR', status: response.status,
      })
    }
    return response
  }

  class SiwcAdapter extends LlmAdapter {
    providerInfo() { return { id: PROVIDER, name: 'OpenAI (Sign in with ChatGPT)' } }
    providerRetryPolicy() { return RETRY_POLICY }

    async listModels() {
      const catalogSignal = catalog.signal
      const status = await oauth.status()
      if (catalogSignal.aborted || !status.signedIn || status.planEnabled === false) return []
      const deadline = AbortSignal.timeout(MODEL_CATALOG_TIMEOUT_MS)
      const signal = AbortSignal.any([catalogSignal, deadline])
      try {
        const response = await request('/models', signal)
        const { models } = await response.json()
        signal.throwIfAborted()
        if (!Array.isArray(models)) throw new LlmError('Invalid OpenAI model catalog.', 'INVALID_CATALOG')
        const listed = new Map()
        for (const row of models) {
          if (row?.visibility !== 'list' || typeof row.slug !== 'string' || !row.slug.trim() || listed.has(row.slug)) continue
          listed.set(row.slug, typeof row.display_name === 'string' && row.display_name.trim() ? row.display_name : row.slug)
        }
        names = listed
        return [...listed].map(([id, name]) => ({ provider: PROVIDER, id, name, inputModalities: ['text'] }))
      } catch (error) {
        if (deadline.aborted && signal.reason === deadline.reason) {
          throw new LlmError('OpenAI model catalog request timed out.', 'TIMEOUT')
        }
        if (catalogSignal.aborted) return []
        throw error
      }
    }

    async resolveModel(provider, id, signal) {
      signal?.throwIfAborted()
      return { provider, id, name: names.get(id) ?? id, inputModalities: ['text'] }
    }

    async *stream(options) {
      const transport = new AbortController()
      const signal = AbortSignal.any([account.signal, transport.signal, ...(options.signal ? [options.signal] : [])])
      // Only the fields used by pi-ai's conversion and decoding, not model limits or prices.
      const model = { id: options.model, provider: PROVIDER, api: API, input: ['text'],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }
      try {
        signal.throwIfAborted()
        const response = await request('/responses', signal, responsesBody(model, options))
        if (!response.headers.get('content-type')?.startsWith('text/event-stream') || !response.body) {
          throw new LlmError('Expected an OpenAI Responses event stream.', 'MALFORMED_RESPONSE')
        }
        yield* decodeResponse(response, { signal, abort: () => transport.abort() }, model)
      } catch (error) {
        if (signal.aborted) throw new LlmError('OpenAI request cancelled.', 'ABORTED')
        if (error instanceof LlmError) throw error
        // Avoid SDK or network error text that might embed a credential.
        throw new LlmError('OpenAI request could not be completed.', 'TRANSPORT')
      } finally {
        transport.abort()
      }
    }
  }

  const unregister = llm.registerAdapter([PROVIDER], new SiwcAdapter())
  return {
    dispose() {
      if (disposed) return
      disposed = true
      catalog.abort()
      account.abort()
      names.clear()
      unregister()
    },
    invalidate({ stopRequests = true } = {}) {
      if (disposed) return
      catalog.abort()
      catalog = new AbortController()
      if (stopRequests) {
        account.abort()
        account = new AbortController()
      }
      names.clear()
      unregister.replace([PROVIDER])
    },
  }
}
