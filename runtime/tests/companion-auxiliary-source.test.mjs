import test from 'node:test';
import assert from 'node:assert/strict';
import { sourceFixture, auxiliarySse, piAiSourceFixture } from './fixtures/companion-auxiliary-source.mjs';

const root = process.env.DSH_AUXILIARY_SOURCES;
const sourceTest = (name, fn) => test(name, { skip: root ? false : 'Set DSH_AUXILIARY_SOURCES to the verified dependency slice; no engine is installed by these tests' }, fn);
const collect = async stream => { const all = []; for await (const chunk of stream) all.push(chunk); return all; };

sourceTest('locked runtime and actual adapter serialize exactly one text-only model request and expose raw cumulative events', async () => {
  const f = await sourceFixture(root, { response: { finalUsage: { input_tokens: 11, output_tokens: 7, cache_read_input_tokens: 13, extra: { original: true } } } });
  const { call, chunks } = await f.run();
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].url, 'https://synthetic.invalid/anthropic/v1/messages');
  assert.deepEqual(f.requests[0].body.messages, [{ role: 'user', content: [{ type: 'text', text: 'SOURCE_ONLY' }] }]);
  assert.equal(f.requests[0].body.model, 'chosen-model'); assert.equal(f.requests[0].body.max_tokens, 512);
  assert.deepEqual(f.requests[0].body.thinking, { type: 'disabled' });
  assert.equal(f.requests[0].body.tools, undefined); assert.equal(f.requests[0].init.headers['x-deepseek-harness-session-id'], undefined);
  assert.deepEqual(f.events.map(e => e.type), ['dispatch', 'http', 'usage', 'stop', 'usage', 'complete']);
  assert.equal(f.events[0].boundary, 'fetch-invoked'); assert(Number.isSafeInteger(f.events[0].atMs));
  assert.equal(f.events.find(e => e.event === 'message_delta').raw.extra.original, true);
  assert.equal(chunks.find(e => e.type === 'usage').usage.inputTokens, 11);
  assert.equal(chunks.at(-1).reason.kind, 'stop');
  assert.throws(() => call.stream({ system: 'again', input: 'again' }), { code: 'INVALID_PREPARED_CALL' });
});

sourceTest('actual auth failure and cancellation during auth make zero fetch invocations', async () => {
  const missing = await sourceFixture(root, { authError: true });
  await assert.rejects(missing.run(), { code: 'MISSING_CREDENTIAL' });
  assert.equal(missing.requests.length, 0); assert.equal(missing.events.length, 0);
  let release; const authGate = new Promise(r => { release = r; });
  const f = await sourceFixture(root, { authGate });
  const pending = f.run(); await new Promise(r => setImmediate(r));
  f.abort.abort(); release();
  await assert.rejects(pending, { code: 'ABORTED' });
  assert.equal(f.requests.length, 0); assert.equal(f.events.length, 0);
});

sourceTest('physical guard rejects a changed provider registration after preparation/auth without dispatch', async () => {
  let release; const authGate = new Promise(r => { release = r; });
  const f = await sourceFixture(root, { authGate });
  const pending = f.run(); await new Promise(r => setImmediate(r));
  f.llm.adapters.set(f.config.provider, { ...f.registration }); release();
  await assert.rejects(pending, { code: 'COMPANION_AUXILIARY_STALE' });
  assert.equal(f.requests.length, 0); assert.equal(f.events.length, 0);
});

sourceTest('actual HTTP error makes one dispatch even with a retry policy and does not run file recovery', async () => {
  const f = await sourceFixture(root, { transport: () => Promise.resolve(new Response(JSON.stringify({ error: { message: 'stale file id', type: 'invalid_request_error' } }), { status: 400 })) });
  await assert.rejects(f.run(), { code: 'INVALID_REQUEST' });
  assert.equal(f.requests.length, 1); assert.deepEqual(f.events.map(e => e.type), ['dispatch', 'http']);
  const aux = { observer: f.observer, dispatched: true };
  assert.throws(() => f.companionAuxiliaryFetch(aux, 'https://synthetic.invalid/second', { signal: f.abort.signal }), { code: 'COMPANION_AUXILIARY_RETRY_DENIED' });
  assert.equal(f.requests.length, 1);
});

sourceTest('sync fetch throw is an invocation; truncated SSE retains raw usage without claiming complete', async () => {
  const f = await sourceFixture(root, { transport: () => { throw new Error('synthetic synchronous fetch failure'); } });
  await assert.rejects(f.run(), { code: 'TRANSPORT' }); assert.equal(f.requests.length, 1);
  assert.deepEqual(f.events.map(e => e.type), ['dispatch']);
  const g = await sourceFixture(root, { transport: () => Promise.resolve(auxiliarySse({ incomplete: true, finalUsage: { output_tokens: 7 } })) });
  await assert.rejects(g.run(), { code: 'STREAM_CLOSED' }); assert.equal(g.requests.length, 1);
  assert.equal(g.events.some(e => e.type === 'complete'), false);
  assert.deepEqual(g.events.find(e => e.event === 'message_delta').raw, { output_tokens: 7 });
});

sourceTest('runtime only refuses an absent call entry point or invalid extra controls', async () => {
  const f = await sourceFixture(root);
  f.llm.adapters.set('other-provider', { provider: { id: 'other-provider' }, adapter: { stream() { throw new Error('Must not use fallback'); } } });
  assert.equal(f.llm.companionAuxiliaryCapability('other-provider'), undefined);
  await assert.rejects(f.llm.prepareCompanionAuxiliaryCall({ ...f.config, provider: 'other-provider' }, f.abort.signal, f.observer), { code: 'COMPANION_AUXILIARY_UNAVAILABLE' });
  await assert.rejects(f.llm.prepareCompanionAuxiliaryCall({ ...f.config, tools: [] }, f.abort.signal, f.observer), { code: 'INVALID_PREPARED_CALL' });
  assert.equal(f.requests.length, 0);
});

sourceTest('actual runtime generic path uses the existing selected adapter prepareCall exactly once and makes no false physical/raw capability claim', async () => {
  const f = await sourceFixture(root); let calls = 0, request;
  const adapter = { async prepareCall(provider, model) {
    assert.equal(provider, 'other-provider'); assert.equal(model, 'other-model');
    return { model: { provider, id: model, name: 'Other', inputModalities: ['text'] }, stream: async function* (options) {
      calls++; request = options;
      yield { type: 'usage', usage: { inputTokens: 4, outputTokens: 2 } };
      yield { type: 'finish', reason: { kind: 'stop' } };
    } };
  } };
  f.llm.adapters.set('other-provider', { provider: { id: 'other-provider' }, adapter });
  assert.deepEqual(f.llm.companionAuxiliaryCapability('other-provider'), {
    physicalDispatch: 'unknown', rawUsage: 'unavailable', maxPhysicalRequests: null, noTools: true,
  });
  const call = await f.llm.prepareCompanionAuxiliaryCall({ provider: 'other-provider', model: 'other-model', maxTokens: 111 }, f.abort.signal, f.observer);
  const chunks = await collect(call.stream({ system: 'fixed', input: 'ONLY_THIS_SOURCE' }));
  assert.equal(calls, 1); assert.equal(f.requests.length, 0, 'no fallback to the default adapter');
  assert.deepEqual(request.messages, [{ role: 'user', content: [{ type: 'text', text: 'ONLY_THIS_SOURCE' }] }]);
  assert.equal(request.reasoningEffort, undefined); assert.equal(request.sessionId, undefined); assert.equal(request.tools, undefined);
  assert.deepEqual(f.events.map(e => e.type), ['handoff']); assert.equal(chunks[0].usage.inputTokens, 4);
  assert.throws(() => call.stream({ system: 'fixed', input: 'duplicate' }), { code: 'INVALID_PREPARED_CALL' });
});

sourceTest('locked pi-ai prepareCall and streamWithSnapshot preserve the current model and existing maxRetries zero', async () => {
  const f = await sourceFixture(root), pi = await piAiSourceFixture(root, f);
  f.llm.adapters.set(pi.provider, { provider: { id: pi.provider }, adapter: pi.adapter });
  const call = await f.llm.prepareCompanionAuxiliaryCall({ provider: pi.provider, model: pi.model.id, maxTokens: 111 }, f.abort.signal, f.observer);
  const chunks = await collect(call.stream({ system: 'Fixed extraction', input: 'PI_AI_ONLY_SOURCE' }));
  assert.equal(pi.calls.length, 1); assert.equal(pi.calls[0].model.id, pi.model.id);
  assert.equal(pi.calls[0].options.maxRetries, 0); assert.equal(pi.calls[0].options.maxTokens, 111);
  assert.equal(pi.calls[0].options.sessionId, undefined); assert.equal(pi.calls[0].context.tools, undefined);
  assert.deepEqual(pi.calls[0].context.messages, [{ role: 'user', content: 'PI_AI_ONLY_SOURCE', timestamp: 0 }]);
  assert.equal(pi.calls[0].context.systemPrompt, 'Fixed extraction');
  assert.deepEqual(chunks.find(c => c.type === 'usage').usage, { inputTokens: 4, outputTokens: 2, totalTokens: 6 });
  assert.equal(chunks.at(-1).reason.kind, 'stop'); assert.deepEqual(f.events.map(e => e.type), ['handoff']);
  assert.equal(f.requests.length, 0, 'the direct default adapter is not called');
});

sourceTest('an empty complete response is distinguishable from truncated transport for finite proposal retries', async () => {
  const f = await sourceFixture(root, { response: { empty: true } });
  await assert.rejects(f.run(), { code: 'EMPTY_RESPONSE' });
  assert.equal(f.requests.length, 1); assert.equal(f.events.at(-1).type, 'complete');
  assert.equal(f.events.find(e => e.event === 'message_delta').raw.output_tokens, 7);
});

sourceTest('the supplied abort signal remains cancellable after the sealed auxiliary request completes', async () => {
  const f = await sourceFixture(root);
  const call = await f.prepare();
  const stream = call.stream({ system: 'one', input: 'SOURCE_ONLY' });
  await collect(stream); f.abort.abort();
  assert.equal(f.abort.signal.aborted, true);
  assert.equal(f.requests.length, 1);
});
