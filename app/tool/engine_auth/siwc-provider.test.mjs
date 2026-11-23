// SPDX-License-Identifier: MIT

import assert from 'node:assert/strict'
import { test } from 'node:test'
import { join } from 'node:path'
import { registerSiwcProvider } from '../../assets/engine/auth/siwc/provider.mjs'

test('loads from the real engine entry when the install is not at /opt/dsh', async () => {
  const prefix = process.env.DSH_TEST_PREFIX
  assert.ok(prefix, 'CI must provide the locked engine prefix')
  const entry = process.argv[1]
  delete process.env.DSH_TEST_PREFIX
  process.argv[1] = join(prefix, 'node_modules/@deepseek-ai/dsh/lib/bin.js')
  try {
    const loaded = await import('../../assets/engine/auth/siwc/provider.mjs?engine-entry')
    assert.equal(typeof loaded.registerSiwcProvider, 'function')
  } finally {
    process.argv[1] = entry
    process.env.DSH_TEST_PREFIX = prefix
  }
})

const provider = 'openai-siwc'
const model = 'mock-text'
const base = 'https://api.openai.com/v1'
const fakeToken = 'mock-oauth-token'
const message = (role, text) => ({ role, content: [{ type: 'text', text }] })
const options = { provider, model, messages: [message('user', 'Hello')] }
const complete = { type: 'response.completed', response: { status: 'completed', output: [], usage: {
  input_tokens: 9, output_tokens: 3, total_tokens: 12, input_tokens_details: { cached_tokens: 4 },
} } }
const started = { type: 'response.output_item.added', output_index: 0, item: { type: 'message', id: 'msg_1' } }
const delta = { type: 'response.output_text.delta', output_index: 0, delta: 'Hello!' }
const ended = { type: 'response.output_item.done', output_index: 0, item: {
  ...started.item, role: 'assistant', content: [{ type: 'output_text', text: delta.delta }],
} }
const toolStart = { type: 'response.output_item.added', output_index: 0, item: {
  type: 'function_call', id: 'fc_1', call_id: 'call_1', name: 'echo', arguments: '',
} }
const argDelta = { type: 'response.function_call_arguments.delta', output_index: 0, delta: '{"value":' }
const toolEnd = { type: 'response.output_item.done', output_index: 0, item: {
  ...toolStart.item, arguments: '{"value":7}',
} }

function frame(event) {
  if (event === '[DONE]') return 'data: [DONE]\n\n'
  const { type, ...data } = event
  return 'event: ' + type + '\r\ndata: ' + JSON.stringify(data) + '\r\n\r\n'
}

function sse(...events) {
  return new Response(events.map(frame).join(''), { headers: { 'content-type': 'text/event-stream' } })
}

function harness(handler, { signedIn = true, token = async () => fakeToken } = {}) {
  let adapter
  const routes = []
  const requests = []
  const oauth = { status: () => ({ signedIn }), token, rejectAccess() {}, replayScope: () => 'mock-account-registration' }
  const llm = {
    registerAdapter(ids, instance) {
      routes.push(ids)
      adapter = instance
      return Object.assign(() => routes.push([]), { replace: (next) => routes.push(next) })
    },
  }
  const lifecycle = registerSiwcProvider({ llm, oauth, fetch: async (url, init) => {
    requests.push({ url, ...init })
    return handler(url, init)
  } })
  return { adapter, lifecycle, routes, requests, oauth }
}

async function collect(chunks, output = []) {
  for await (const chunk of chunks) output.push(chunk)
  return output
}

test('visible models use catalog order and display names without invented capabilities', async () => {
  const { adapter, lifecycle, routes, requests, oauth } = harness((url, init) => {
    assert.equal(url, base + '/models')
    assert.equal(init.method, 'GET')
    assert.equal(init.headers.Authorization, 'Bearer ' + fakeToken)
    assert.match(init.headers['user-agent'], /^deepseek-harness\//)
    return Response.json({ models: [
      { slug: 'hidden', visibility: 'hidden' },
      { slug: model, display_name: 'Mock Text', visibility: 'list', context_window: 500000, capabilities: ['image'] },
      { slug: 'aaa', display_name: 'Another', visibility: 'list' },
    ] })
  }, { signedIn: false })
  assert.deepEqual(routes, [[provider]])
  assert.equal(adapter.providerInfo().id, provider)
  assert.equal(adapter.providerRetryPolicy().maxRetries, 0)
  assert.deepEqual(await adapter.listModels(), [])
  assert.equal(requests.length, 0)
  oauth.status = () => ({ signedIn: true, planEnabled: false })
  assert.deepEqual(await adapter.listModels(), [])
  assert.equal(requests.length, 0)
  oauth.status = () => ({ signedIn: true, planEnabled: true })
  lifecycle.invalidate()
  assert.deepEqual(await adapter.listModels(), [
    { provider, id: model, name: 'Mock Text', inputModalities: ['text'], context: { contextWindow: 500_000 } },
    { provider, id: 'aaa', name: 'Another', inputModalities: ['text'] },
  ])
  assert.deepEqual(await adapter.resolveModel(provider, model), {
    provider, id: model, name: 'Mock Text', inputModalities: ['text'], context: { contextWindow: 500_000 },
  })
  oauth.status = () => ({ signedIn: false })
  lifecycle.invalidate()
  assert.equal((await adapter.resolveModel(provider, model)).name, model)
  assert.deepEqual(await adapter.listModels(), [])
  lifecycle.dispose()
  lifecycle.dispose()
  assert.deepEqual(routes, [[provider], [provider], [provider], []])
})

test('model resolution and inference use only the reasoning levels advertised by the account', async () => {
  const rows = [
    { slug: model, visibility: 'list', supported_reasoning_levels: [
      { effort: 'medium', description: 'Balanced' }, { effort: 'xhigh' },
      { effort: 'xhigh', description: 'Duplicate' }, { effort: '!' }, null,
    ], default_reasoning_level: 'xhigh' },
    { slug: 'another', visibility: 'list', supported_reasoning_levels: [ { effort: 'low' } ], default_reasoning_level: 'high' },
  ]
  const { adapter, requests } = harness((url) => url.endsWith('/models')
    ? Response.json({ models: rows })
    : sse(started, delta, ended, complete))
  const info = await adapter.resolveModel(provider, model)
  assert.deepEqual(info.reasoning, {
    efforts: [{ id: 'medium', name: 'medium', description: 'Balanced' }, { id: 'xhigh', name: 'xhigh' }],
    defaultEffort: 'xhigh',
  })
  assert.deepEqual((await adapter.resolveModel(provider, 'another')).reasoning, { efforts: [{ id: 'low', name: 'low' }] })
  await collect(adapter.stream({ ...options, reasoningEffort: 'medium' }))
  assert.deepEqual(requests.map(({ url }) => url), [base + '/models', base + '/responses'])
  assert.deepEqual(JSON.parse(requests[1].body).reasoning, { effort: 'medium' })
})

test('a broken model list does not stop an unconfigured saved chat', async (t) => {
  for (const [kind, catalogResponse, code] of [
    ['unavailable', () => new Response(null, { status: 503 }), 'SIWC_HTTP_ERROR'],
    ['wrong shape', () => Response.json({ data: [] }), 'INVALID_CATALOG'],
    ['not JSON', () => new Response('<html></html>'), 'INVALID_CATALOG'],
  ]) {
    await t.test(kind, async () => {
      const { adapter, requests } = harness((url) => url.endsWith('/models')
        ? catalogResponse()
        : sse(started, delta, ended, complete))
      assert.deepEqual(await adapter.resolveModel(provider, model), { provider, id: model, name: model, inputModalities: ['text'] })
      const chunks = await collect(adapter.stream(options))
      assert.deepEqual(chunks.at(-1), { type: 'finish', reason: { kind: 'stop' } })
      assert.equal(JSON.parse(requests[1].body).reasoning, undefined)
      await assert.rejects(adapter.listModels(), { code })
    })
  }
})

test('model catalog timeout aborts fetch and both success and error bodies', { timeout: 2000 }, async (t) => {
  for (const phase of ['headers', 'success body', 'error body']) {
    await t.test(phase, async (t) => {
      const deadline = new AbortController()
      const timeout = t.mock.method(AbortSignal, 'timeout', () => deadline.signal)
      const reached = Promise.withResolvers()
      const { adapter, requests } = harness((url, { signal }) => {
        assert.equal(url, base + '/models')
        if (phase === 'headers') return new Promise((_, reject) => {
          signal.addEventListener('abort', () => reject(signal.reason), { once: true })
          reached.resolve()
        })
        return new Response(new ReadableStream({
          start(controller) {
            signal.addEventListener('abort', () => controller.error(signal.reason), { once: true })
          },
          pull() { reached.resolve() },
        }, { highWaterMark: 0 }), { status: phase === 'success body' ? 200 : 503 })
      })
      const result = adapter.listModels()
      await reached.promise
      assert.equal(timeout.mock.callCount(), 1)
      assert.deepEqual(timeout.mock.calls[0].arguments, [5_000])
      deadline.abort(new DOMException('mock model catalog timeout', 'TimeoutError'))
      assert.equal(requests[0].signal.aborted, true)
      await assert.rejects(result, { code: 'TIMEOUT', message: 'OpenAI model catalog request timed out.' })
    })
  }
})

test('a catalog fetched before permission loss cannot restore old models', async () => {
  const fetched = Promise.withResolvers()
  const response = Promise.withResolvers()
  const { adapter, lifecycle, oauth } = harness(() => {
    fetched.resolve()
    return response.promise
  })
  const old = adapter.listModels()
  await fetched.promise
  oauth.status = () => ({ signedIn: true, planEnabled: false })
  lifecycle.invalidate({ stopRequests: false })
  response.resolve(Response.json({ models: [{ slug: model, display_name: 'Stale', visibility: 'list' }] }))
  assert.deepEqual(await old, [])
  assert.deepEqual(await adapter.listModels(), [])
  assert.equal((await adapter.resolveModel(provider, model)).name, model)
})

test('aborting after usage prevents a successful terminal event', async () => {
  const caller = new AbortController()
  const { adapter } = harness(() => sse(started, delta, ended, complete))
  const stream = adapter.stream({ ...options, signal: caller.signal })
  for await (const chunk of stream) {
    if (chunk.type !== 'usage') continue
    caller.abort()
    await assert.rejects(stream.next(), { code: 'ABORTED' })
    return
  }
  assert.fail('expected the usage event before completion')
})

test('stateless text history and DSH stream blocks, usage and stop', async () => {
  const { adapter, requests } = harness(() => sse(started, delta, ended, complete))
  const chunks = await collect(adapter.stream({
    ...options, system: 'Keep replies concise.', maxTokens: 50, temperature: 0.2,
    messages: [message('system', 'Use English'), message('user', 'My name is Sam'),
      message('assistant', 'Hi Sam'), message('developer', 'Use plain text'), message('user', 'Who am I?')],
  }))
  assert.equal(requests.length, 1)
  const [{ url, method, headers, redirect, body }] = requests
  assert.equal(url, base + '/responses')
  assert.equal(method, 'POST')
  assert.equal(redirect, 'error')
  assert.equal(headers.Authorization, 'Bearer ' + fakeToken)
  assert.match(headers['user-agent'], /^deepseek-harness\//)
  const payload = JSON.parse(body)
  assert.deepEqual(Object.keys(payload).sort(), ['input', 'instructions', 'model', 'store', 'stream'])
  assert.equal(payload.model, model)
  assert.equal(payload.store, false)
  assert.equal(payload.stream, true)
  assert.equal(payload.instructions, 'Keep replies concise.')
  assert.deepEqual(payload.input.map((item) => item.role), ['developer', 'user', 'assistant', 'developer', 'user'])
  assert.deepEqual(payload.input[2].content, [{ type: 'output_text', text: 'Hi Sam', annotations: [] }])
  assert.ok(!('id' in payload.input[2]))
  assert.deepEqual(chunks, [
    { type: 'block-start', index: 0, blockType: 'text' },
    { type: 'text-delta', index: 0, text: 'Hello!' },
    { type: 'block-end', index: 0, block: { type: 'text', text: 'Hello!' } },
    { type: 'usage', usage: { inputTokens: 5, outputTokens: 3, totalTokens: 12, cacheReadTokens: 4 } },
    { type: 'finish', reason: { kind: 'stop' } },
  ])
})

test('valid Responses streams need a body and a completed event, not a Content-Type header', async (t) => {
  const body = (...events) => new TextEncoder().encode(events.map(frame).join(''))
  for (const contentType of [undefined, 'Text/Event-Stream; charset=utf-8']) {
    await t.test(contentType ?? 'missing header', async () => {
      const response = new Response(body(started, delta, ended, complete), {
        headers: contentType ? { 'content-type': contentType } : {},
      })
      if (!contentType) assert.equal(response.headers.get('content-type'), null)
      const { adapter } = harness(() => response)
      const chunks = await collect(adapter.stream(options))
      assert.ok(chunks.some((chunk) => chunk.type === 'text-delta' && chunk.text === 'Hello!'))
      assert.deepEqual(chunks.at(-1), { type: 'finish', reason: { kind: 'stop' } })
    })
  }
  const headerlessIncomplete = harness(() => new Response(body(started, delta, ended)))
  await assert.rejects(collect(headerlessIncomplete.adapter.stream(options)), { code: 'STREAM_CLOSED' })
  for (const response of [Response.json({ ok: true }), new Response(null)]) {
    const { adapter } = harness(() => response)
    await assert.rejects(collect(adapter.stream(options)), { code: 'MALFORMED_RESPONSE' })
  }
})

test('a completed reply does not wait for a stalled or failing stream cancel', { timeout: 2000 }, async (t) => {
  for (const [kind, cancel] of [
    ['stalled', () => new Promise(() => {})],
    ['failed', () => Promise.reject(new Error('mock cleanup failure'))],
  ]) {
    await t.test(kind, async () => {
      const { adapter } = harness(() => new Response(new ReadableStream({
        start(controller) {
          controller.enqueue(new TextEncoder().encode([started, delta, ended, complete].map(frame).join('')))
        },
        cancel,
      })))
      const chunks = await collect(adapter.stream(options))
      assert.deepEqual(chunks.at(-1), { type: 'finish', reason: { kind: 'stop' } })
    })
  }
})

test('completed text without a usage object still finishes successfully', async () => {
  const terminal = { type: 'response.completed', response: { output: [ended.item] } }
  const { adapter } = harness(() => sse(started, delta, ended, terminal))
  const chunks = await collect(adapter.stream(options))
  assert.deepEqual(chunks.slice(-3), [
    { type: 'block-end', index: 0, block: { type: 'text', text: 'Hello!' } },
    { type: 'usage', usage: { inputTokens: 0, outputTokens: 0, totalTokens: 0 } },
    { type: 'finish', reason: { kind: 'stop' } },
  ])
})

test('a completed event still rejects a missing response or an explicit non-completed status', async () => {
  for (const response of [undefined, null, [], {}, { status: 'failed' }, { status: 'incomplete' }]) {
    const { adapter } = harness(() => sse({ type: 'response.completed', response }))
    await assert.rejects(collect(adapter.stream(options)), { code: 'MALFORMED_RESPONSE' })
  }
})

test('a successful terminal event without streamed output is not a completed reply', async () => {
  const { adapter } = harness(() => sse(complete))
  await assert.rejects(collect(adapter.stream(options)), { code: 'EMPTY_RESPONSE' })
})

test('declares a local function and replays its matching call and result', async () => {
  let count = 0
  const { adapter, requests } = harness(() => count++ === 0
    ? sse(toolStart, argDelta, toolEnd, complete)
    : sse(started, delta, ended, complete))
  const tools = [{ name: 'echo', description: 'Echo a value', parameters: { type: 'object', properties: { value: { type: 'number' } }, required: ['value'] } }]
  const chunks = await collect(adapter.stream({ ...options, tools }))
  const first = JSON.parse(requests[0].body)
  assert.ok(!('tools' in first))
  assert.deepEqual(first.input[0], {
    type: 'additional_tools', role: 'developer', tools: [{ ...tools[0], type: 'function', strict: false }],
  })
  const call = chunks.find(({ type }) => type === 'block-end').block
  assert.deepEqual(call, { type: 'tool-call', id: 'call_1', name: 'echo', arguments: '{"value":7}' })
  assert.deepEqual(chunks.find(({ type }) => type === 'tool-call-delta'), {
    type: 'tool-call-delta', index: 0, id: 'call_1', name: 'echo', argumentsDelta: '{"value":',
  })
  assert.equal(chunks.at(-1).reason.kind, 'tool-calls')
  await collect(adapter.stream({ ...options, tools, messages: [
    ...options.messages, { role: 'assistant', source: { provider, model }, content: [call] },
    { ...message('tool', '7'), toolCallId: call.id },
  ] }))
  assert.deepEqual(JSON.parse(requests[1].body).input.slice(-2), [
    { type: 'function_call', call_id: 'call_1', name: 'echo', arguments: '{"value":7}' },
    { type: 'function_call_output', call_id: 'call_1', output: '7' },
  ])
})

test('tool continuation replays opaque reasoning and phase only for the same account and model', async () => {
  const reasoning = { type: 'reasoning', id: 'rs_mock', summary: [{ type: 'summary_text', text: 'do not persist here' }] }
  const item = (event, output_index) => ({ ...event, output_index })
  const terminal = { ...complete, response: {
    ...complete.response, output: [{ ...reasoning, encrypted_content: 'mock-encrypted-reasoning' }],
  } }
  const { adapter, requests, oauth } = harness(() => requests.length > 1 ? sse(started, delta, ended, complete) : sse(
    { type: 'response.output_item.done', output_index: 0, item: reasoning },
    item(started, 1), item(delta, 1), { ...item(ended, 1), item: { ...ended.item, phase: 'commentary' } },
    item(toolStart, 2), item(argDelta, 2), item(toolEnd, 2), terminal,
  ))
  const chunks = await collect(adapter.stream(options))
  const { replayState } = chunks.at(-1)
  assert.equal(replayState.blocks[0].encrypted_content, 'mock-encrypted-reasoning')
  assert.ok(!JSON.stringify(replayState).includes('do not persist here'))
  const content = chunks.filter(({ type }) => type === 'block-end').map(({ block }) => block)
  const messages = [
    ...options.messages, { role: 'assistant', content, source: { provider, model, replayState } },
    { ...message('tool', '7'), toolCallId: 'call_1' },
  ]
  await collect(adapter.stream({ ...options, messages }))
  const input = JSON.parse(requests[1].body).input
  assert.deepEqual(input.map(({ type }) => type), [undefined, 'reasoning', 'message', 'function_call', 'function_call_output'])
  assert.equal(input[2].phase, 'commentary')
  assert.equal(input[3].call_id, input[4].call_id)
  await collect(adapter.stream({ ...options, model: 'different-model', messages }))
  oauth.replayScope = () => 'another-registration'
  await collect(adapter.stream({ ...options, messages }))
  for (const request of requests.slice(2)) {
    assert.ok(!JSON.parse(request.body).input.some((entry) => entry.type === 'reasoning' || entry.phase))
  }
})

test('failures after stream start are not treated as complete or retried', async (t) => {
  const failed = { type: 'response.failed', response: { error: {
    code: 'subscription_sharing_usage_limit_exceeded', message: 'mock usage limit',
  } } }
  const incomplete = { type: 'response.incomplete', response: { status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' } } }
  for (const [terminal, code] of [
    [failed, 'subscription_sharing_usage_limit_exceeded'],
    [incomplete, 'SIWC_INCOMPLETE'],
    ['[DONE]', 'STREAM_CLOSED'],
  ]) {
    await t.test(code, async () => {
      const { adapter, requests } = harness(() => sse(toolStart, argDelta, toolEnd, terminal))
      const seen = []
      await assert.rejects(collect(adapter.stream(options), seen), { code })
      assert.equal(seen.some((chunk) => chunk.type === 'block-end' || chunk.type === 'finish'), false)
      assert.equal(requests.length, 1)
    })
  }
})

test('malformed tool arguments and unfinished calls do not dispatch', async (t) => {
  for (const tail of [[], [{ ...toolEnd, item: { ...toolEnd.item, arguments: '{' } }]]) {
    await t.test(tail.length ? 'invalid JSON' : 'missing item end', async () => {
      const { adapter } = harness(() => sse(toolStart, argDelta, ...tail, complete))
      const seen = []
      await assert.rejects(collect(adapter.stream(options), seen))
      assert.equal(seen.some((chunk) => chunk.type === 'block-end' || chunk.type === 'finish'), false)
    })
  }
})

test('an admission error keeps status and request ID without exposing the token', async () => {
  const { adapter, requests } = harness(() => Response.json({ detail: 'Not accepted: ' + fakeToken }, {
    status: 403, headers: { 'x-request-id': 'req_mock' },
  }))
  await assert.rejects(collect(adapter.stream(options)), (error) => {
    assert.equal(error.failure.status, 403)
    assert.equal(error.failure.requestId, 'req_mock')
    assert.match(error.message, /OpenAI HTTP 403/)
    assert.ok(!error.message.includes('Not accepted'))
    assert.ok(!error.message.includes(fakeToken))
    return true
  })
  assert.equal(requests.length, 1)
})

test('OpenAI errors reach the engine as recoverable auth, context and rate-limit categories', async () => {
  const contextError = { code: 'context_length_exceeded' }
  for (const [response, code] of [
    [Response.json({ error: contextError }, { status: 400 }), 'CONTEXT_WINDOW_EXCEEDED'],
    [sse({ type: 'response.failed', response: { error: contextError } }), 'CONTEXT_WINDOW_EXCEEDED'],
    [Response.json({ error: { code: 'invalid_token' } }, { status: 401 }), 'SIWC_SIGN_IN_REQUIRED'],
    [Response.json({ error: { code: 'rate_limit_exceeded' } }, { status: 429 }), 'RATE_LIMIT'],
  ]) {
    const { adapter } = harness(() => response)
    await assert.rejects(collect(adapter.stream(options)), { code })
  }
})

test('an invalid signed identity marks the current token for renewal without retrying inference', async () => {
  for (const response of [
    Response.json({ error: { code: 'subscription_sharing_invalid_user' } }, { status: 401 }),
    Response.json({ error: { code: 'subscription_sharing_invalid_user' } }, { status: 403 }),
    sse({ type: 'response.failed', response: { error: { code: 'subscription_sharing_invalid_user' } } }),
  ]) {
    const { adapter, oauth, requests } = harness(() => response)
    const rejected = []
    oauth.rejectAccess = (token) => rejected.push(token)
    await assert.rejects(collect(adapter.stream(options)), { code: 'SIWC_SIGN_IN_REQUIRED' })
    assert.deepEqual(rejected, [fakeToken])
    assert.equal(requests.length, 1)
  }
})

test('caller abort and account replacement cancel a pending SSE body', { timeout: 2000 }, async (t) => {
  for (const mode of ['caller', 'account']) {
    await t.test(mode, async () => {
      const caller = new AbortController()
      let cancelled = false
      const { adapter, lifecycle, requests } = harness(() => new Response(new ReadableStream({
        start(controller) { controller.enqueue(new TextEncoder().encode(frame(started))) },
        cancel() { cancelled = true },
      }), { headers: { 'content-type': 'text/event-stream' } }))
      const stream = adapter.stream({ ...options, signal: caller.signal })
      assert.equal((await stream.next()).value.type, 'block-start')
      const pending = stream.next()
      if (mode === 'caller') caller.abort()
      else lifecycle.invalidate()
      await assert.rejects(pending, { code: 'ABORTED' })
      assert.equal(requests[0].signal.aborted, true)
      assert.equal(cancelled, true)
    })
  }
})

test('expired OAuth and an API key cannot reach inference', async (t) => {
  const cases = {
    expired: async () => { throw Object.assign(new Error('private detail'), { code: 'siwc_session_expired' }) },
    'wrong credential type': async () => 'sk-mock',
  }
  for (const [name, token] of Object.entries(cases)) {
    await t.test(name, async () => {
      const { adapter, requests } = harness(() => assert.fail('unexpected fetch'), { token })
      await assert.rejects(collect(adapter.stream(options)), { code: 'SIWC_SIGN_IN_REQUIRED' })
      assert.equal(requests.length, 0)
    })
  }
})

test('an already-cancelled request never acquires a credential or reaches fetch', async () => {
  const { adapter } = harness(() => assert.fail('unexpected fetch'), {
    token: () => assert.fail('unexpected token request'),
  })
  await assert.rejects(collect(adapter.stream({ ...options, signal: AbortSignal.abort() })), { code: 'ABORTED' })
})
