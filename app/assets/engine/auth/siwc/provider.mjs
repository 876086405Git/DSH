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
  { CONTEXT_WINDOW_EXCEEDED_CODE, EMPTY_RESPONSE_CODE, LlmAdapter, LlmError, attributionHeaders, resolveRetryPolicy },
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
const LOGIN_ERRORS = new Set(['siwc_sign_in_required', 'siwc_session_expired', 'siwc_plan_permission_missing', 'siwc_access_rejected'])

function argumentsObject(raw) {
  try {
    const value = JSON.parse(raw)
    if (value && typeof value === 'object' && !Array.isArray(value)) return value
  } catch {
    // Arguments may contain secrets.
  }
  throw new LlmError('A local function call has invalid JSON arguments.', 'INVALID_REQUEST')
}

function piMessages(messages, model, scope) {
  return messages.map(({ role, content, source, toolCallId, isError }) => {
    const replay = source?.replayState
    const sameGrant = scope && source?.provider === PROVIDER && source.model === model.id &&
      replay?.response?.version === 1 && replay.response.scope === scope
    const blocks = content.flatMap((block, index) => {
      switch (block.type) {
        case 'text': {
          const phase = sameGrant && replay.blocks?.[index]
          return [isMessagePhase(phase) ? { ...block, textSignature: JSON.stringify(phase) } : block]
        }
        case 'tool-call': return [{
          type: 'toolCall', id: block.id, name: block.name, arguments: argumentsObject(block.arguments),
        }]
        case 'reasoning': {
          const item = sameGrant && replay.blocks?.[index]
          const signature = encryptedReasoning(item)
          return signature ? [{ type: 'thinking', thinking: '', thinkingSignature: JSON.stringify(signature) }] : []
        }
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

function responsesBody(model, options, scope) {
  const input = convertResponsesMessages(model, { messages: piMessages(options.messages, model, scope) }, new Set([PROVIDER]), {
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
    ...(options.reasoningEffort === undefined ? {} : { reasoning: { effort: options.reasoningEffort } }),
  }
}

function identifier(value) {
  return typeof value === 'string' && /^[a-zA-Z0-9_.-]{1,128}$/.test(value) ? value : undefined
}

function encryptedReasoning(item) {
  if (item?.type !== 'reasoning' || !identifier(item.id) || typeof item.encrypted_content !== 'string' || !item.encrypted_content) return undefined
  return { type: 'reasoning', id: item.id, summary: [], encrypted_content: item.encrypted_content }
}

function isMessagePhase(value) {
  return !!identifier(value?.id) && (value.phase === 'commentary' || value.phase === 'final_answer')
}

function responseReplay(content, scope) {
  if (!scope) return undefined
  const blocks = content.map((block) => {
    if (block.type === 'thinking' && block.thinkingSignature) {
      return encryptedReasoning(JSON.parse(block.thinkingSignature)) ?? null
    }
    if (block.type === 'text' && block.textSignature) {
      const phase = JSON.parse(block.textSignature)
      if (isMessagePhase(phase)) return { v: 1, id: phase.id, phase: phase.phase }
    }
    return null
  })
  if (blocks.some(Boolean)) return { response: { version: 1, scope }, blocks }
}

function reasoningProfile(row) {
  if (!Array.isArray(row.supported_reasoning_levels)) return undefined
  const efforts = new Map()
  for (const level of row.supported_reasoning_levels) {
    const id = identifier(level?.effort)
    if (!id || efforts.has(id)) continue
    const description = typeof level.description === 'string' && level.description.trim()
    efforts.set(id, { id, name: id, ...(description ? { description } : {}) })
  }
  if (!efforts.size) return undefined
  const defaultEffort = row.default_reasoning_level
  return { efforts: [...efforts.values()], ...(efforts.has(defaultEffort) ? { defaultEffort } : {}) }
}

function responseError(response, payload, fallback, { code, status } = {}) {
  const upstreamCode = identifier(payload?.code)
  const errorCode = status === 401 || upstreamCode === 'subscription_sharing_invalid_user' ? 'SIWC_SIGN_IN_REQUIRED'
    : upstreamCode === 'context_length_exceeded' ? CONTEXT_WINDOW_EXCEEDED_CODE
    : upstreamCode === 'rate_limit_exceeded' || (status === 429 && !upstreamCode) ? 'RATE_LIMIT'
    : upstreamCode ?? code ?? 'SIWC_API_ERROR'
  const param = identifier(payload?.param)
  const requestId = identifier(response.headers.get('x-request-id'))
  const help = errorCode === 'subscription_sharing_usage_limit_exceeded' ? 'https://chatgpt.com/settings/usage' : undefined
  // Never forward upstream message/detail; either may quote request content or credentials.
  return new LlmError(
    [fallback, upstreamCode ?? errorCode, param && 'parameter: ' + param, help].filter(Boolean).join(': '),
    errorCode, { status, requestId },
  )
}

function readEvent(response, sse) {
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
  if ((type === 'response.output_item.added' || type === 'response.output_item.done') && !ITEM_TYPES.has(event?.item?.type)) {
    throw new LlmError('Unsupported OpenAI Responses output item.', 'MALFORMED_RESPONSE')
  }
  if (type === 'response.completed') {
    const completed = event?.response
    if (!completed || typeof completed !== 'object' || Array.isArray(completed) ||
        (completed.status === undefined ? !Array.isArray(completed.output) : completed.status !== 'completed')) {
      throw new LlmError('Invalid OpenAI response terminal status.', 'MALFORMED_RESPONSE')
    }
  }
  return { ...event, type }
}

async function* responsesEvents(response, requestSignal) {
  const reader = new AbortController()
  const signal = AbortSignal.any([requestSignal, reader.signal])
  for await (const sse of _iterSSEMessages(response, { signal, abort: () => reader.abort() })) {
    if (sse.data === '[DONE]') {
      reader.abort()
      break
    }
    let event
    try {
      event = readEvent(response, sse)
    } catch (error) {
      reader.abort()
      throw error
    }
    const completed = event.type === 'response.completed'
    // A settled response must not wait for the remote stream's cancel/close handshake.
    if (completed) reader.abort()
    yield event
    if (completed) return
  }
  requestSignal.throwIfAborted()
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
  const decoded = processResponsesStream(responsesEvents(response, request.signal), output, events, model)
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
  if (!output.content.length) throw new LlmError('OpenAI completed without any output.', EMPTY_RESPONSE_CODE)
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
  const replayState = responseReplay(output.content, request.scope)
  yield { type: 'finish', reason: { kind: tools.length ? 'tool-calls' : 'stop' }, ...(replayState ? { replayState } : {}) }
}

export function registerSiwcProvider({ llm, oauth, fetch = globalThis.fetch }) {
  let account = new AbortController()
  let catalog = new AbortController()
  let catalogModels
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
    const scope = body ? oauth.replayScope(token) : undefined
    const response = await fetch(BASE_URL + path, {
      method: body ? 'POST' : 'GET', signal, redirect: 'error',
      headers: {
        ...attributionHeaders(),
        Authorization: 'Bearer ' + token,
        Accept: body ? 'text/event-stream' : 'application/json',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      ...(body ? { body: JSON.stringify(body(scope)) } : {}),
    })
    if (!response.ok) {
      if (response.status === 401) oauth.rejectAccess(token)
      const payload = await response.json().catch(() => null)
      signal.throwIfAborted()
      if (response.status !== 401 && payload?.error?.code === 'subscription_sharing_invalid_user') oauth.rejectAccess(token)
      throw responseError(response, payload?.error, 'OpenAI HTTP ' + response.status, {
        code: 'SIWC_HTTP_ERROR', status: response.status,
      })
    }
    return { response, token, scope }
  }

  class SiwcAdapter extends LlmAdapter {
    providerInfo() { return { id: PROVIDER, name: 'OpenAI (Sign in with ChatGPT)' } }
    providerRetryPolicy() { return RETRY_POLICY }

    async listModels(_provider, callerSignal) {
      const catalogSignal = catalog.signal
      callerSignal?.throwIfAborted()
      const status = await oauth.status()
      callerSignal?.throwIfAborted()
      if (catalogSignal.aborted || !status.signedIn || status.planEnabled === false) return []
      const deadline = AbortSignal.timeout(MODEL_CATALOG_TIMEOUT_MS)
      const signal = AbortSignal.any([catalogSignal, deadline, ...(callerSignal ? [callerSignal] : [])])
      try {
        const { response } = await request('/models', signal)
        let result
        try {
          result = await response.json()
        } catch (error) {
          if (!(error instanceof SyntaxError)) throw error
        }
        signal.throwIfAborted()
        const models = result?.models
        if (!Array.isArray(models)) throw new LlmError('Invalid OpenAI model catalog.', 'INVALID_CATALOG')
        const listed = new Map()
        for (const row of models) {
          if (row?.visibility !== 'list' || typeof row.slug !== 'string' || !row.slug.trim() || listed.has(row.slug)) continue
          const id = row.slug
          const name = typeof row.display_name === 'string' && row.display_name.trim() ? row.display_name : id
          const reasoning = reasoningProfile(row)
          const contextWindow = row.context_window
          listed.set(id, {
            provider: PROVIDER, id, name, inputModalities: ['text'],
            ...(reasoning ? { reasoning } : {}),
            ...(Number.isSafeInteger(contextWindow) && contextWindow > 0 ? { context: { contextWindow } } : {}),
          })
        }
        catalogModels = listed
        return [...listed.values()]
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
      if (!catalogModels) {
        try {
          await this.listModels(provider, signal)
        } catch (error) {
          signal?.throwIfAborted()
          // A temporarily unavailable catalog must not prevent using a saved model without an explicit effort.
          if (!(error instanceof TypeError) && error?.code !== 'TIMEOUT' && error?.code !== 'INVALID_CATALOG' &&
              !(error?.failure?.status >= 500)) throw error
        }
      }
      return catalogModels?.get(id) ?? { provider, id, name: id, inputModalities: ['text'] }
    }

    async *stream(options) {
      const transport = new AbortController()
      const signal = AbortSignal.any([account.signal, transport.signal, ...(options.signal ? [options.signal] : [])])
      // Only the fields used by pi-ai's conversion and decoding, not model limits or prices.
      const model = { id: options.model, provider: PROVIDER, api: API, input: ['text'],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }
      let accessToken
      try {
        signal.throwIfAborted()
        const { response, token, scope } = await request('/responses', signal, (scope) => responsesBody(model, options, scope))
        accessToken = token
        const contentType = response.headers.get('content-type')?.split(';', 1)[0]?.trim().toLowerCase()
        // The direct subscription route can omit this header on otherwise valid SSE.
        if (!response.body || (contentType && contentType !== 'text/event-stream')) {
          throw new LlmError('Expected an OpenAI Responses event stream.', 'MALFORMED_RESPONSE')
        }
        yield* decodeResponse(response, { signal, scope }, model)
      } catch (error) {
        if (signal.aborted) throw new LlmError('OpenAI request cancelled.', 'ABORTED')
        if (accessToken && error?.code === 'SIWC_SIGN_IN_REQUIRED') oauth.rejectAccess(accessToken)
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
      catalogModels = undefined
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
      catalogModels = undefined
      unregister.replace([PROVIDER])
    },
  }
}
