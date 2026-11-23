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
  const g = await sourceFixture(root, { image: true });
  const imageCapability = await g.llm.companionScreenCapability(g.config.provider, g.config.model, g.abort.signal);
  assert.equal(imageCapability.transientImage, 'jpeg-512-inline');
  // A bounded SOF envelope isolates encoded dimensions and exact serialization;
  // this transport fixture is not a JPEG decoder or a device screenshot test.
  const image = { mediaType: 'image/jpeg', width: 1, height: 1, data: '/9j/wAALCAABAAEBAREA/9k=' };
  const imageCall = await g.prepare();
  await collect(imageCall.stream({ system: 'Classify external screen data.', input: 'SCREEN_TEXT', screenImage: image }));
  assert.equal(g.requests.length, 1, 'inline pixels never invoke Files upload or a second model request');
  const wire = g.requests[0];
  assert.equal(wire.url, 'https://synthetic.invalid/anthropic/v1/messages');
  assert.equal(wire.body.messages[0].content[0].text, 'SCREEN_TEXT');
  assert.deepEqual(wire.body.messages[0].content.at(-1), { type: 'image', source: { type: 'base64', media_type: image.mediaType, data: image.data } });
  assert.equal(wire.body.tools, undefined); assert.equal(wire.init.headers['anthropic-beta'], undefined);
  assert.deepEqual(g.events.map(e => e.type), ['dispatch', 'http', 'usage', 'stop', 'usage', 'complete']);
  const bad = await sourceFixture(root, { image: true });
  const badCall = await bad.prepare();
  await assert.rejects(collect(badCall.stream({ system: 'fixed', input: 'fixed', screenImage: { ...image, width: 512 } })), { code: 'UNSUPPORTED_CONTENT' });
  assert.equal(bad.requests.length, 0, 'declared dimensions cannot replace the encoded SOF');
  const larger = Buffer.from(image.data, 'base64');
  larger.writeUInt16BE(2, 7); larger.writeUInt16BE(2, 9);
  for (const limits of [{ imagePixelBudget: 1 }, { imageMaxBytes: 1 }]) {
    const bounded = await sourceFixture(root, { image: true });
    Object.assign(bounded.connection.models[0], limits);
    const boundedCall = await bounded.prepare();
    await assert.rejects(collect(boundedCall.stream({ system: 'fixed', input: 'fixed',
      screenImage: { ...image, width: 2, height: 2, data: larger.toString('base64') } })), { code: 'UNSUPPORTED_CONTENT' });
    assert.equal(bounded.requests.length, 0, 'a selected model limit is not bypassed by the transient path');
  }
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
  let imageRelease; const imageAuthGate = new Promise(r => { imageRelease = r; });
  const image = await sourceFixture(root, { image: true, authGate: imageAuthGate });
  const imageCall = await image.prepare();
  const imagePending = collect(imageCall.stream({ system: 'fixed', input: 'screen',
    screenImage: { mediaType: 'image/jpeg', width: 1, height: 1, data: '/9j/wAALCAABAAEBAREA/9k=' } }));
  await new Promise(r => setImmediate(r)); image.abort.abort(); imageRelease();
  await assert.rejects(imagePending, { code: 'ABORTED' });
  assert.equal(image.requests.length, 0); assert.equal(image.events.length, 0);
});

sourceTest('physical guard rejects a changed provider registration after preparation/auth without dispatch', async () => {
  let release; const authGate = new Promise(r => { release = r; });
  const f = await sourceFixture(root, { authGate });
  const pending = f.run(); await new Promise(r => setImmediate(r));
  f.llm.adapters.set(f.config.provider, { ...f.registration }); release();
  await assert.rejects(pending, { code: 'COMPANION_AUXILIARY_STALE' });
  assert.equal(f.requests.length, 0); assert.equal(f.events.length, 0);
  let imageRelease; const imageAuthGate = new Promise(r => { imageRelease = r; });
  const image = await sourceFixture(root, { image: true, authGate: imageAuthGate });
  const imageCall = await image.prepare();
  const imagePending = collect(imageCall.stream({ system: 'fixed', input: 'screen',
    screenImage: { mediaType: 'image/jpeg', width: 1, height: 1, data: '/9j/wAALCAABAAEBAREA/9k=' } }));
  await new Promise(r => setImmediate(r));
  image.llm.adapters.set(image.config.provider, { ...image.registration }); imageRelease();
  await assert.rejects(imagePending, { code: 'COMPANION_AUXILIARY_STALE' });
  assert.equal(image.requests.length, 0); assert.equal(image.events.length, 0);
});

sourceTest('actual HTTP error makes one dispatch even with a retry policy and does not run file recovery', async () => {
  const f = await sourceFixture(root, { transport: () => Promise.resolve(new Response(JSON.stringify({ error: { message: 'stale file id', type: 'invalid_request_error' } }), { status: 400 })) });
  await assert.rejects(f.run(), { code: 'INVALID_REQUEST' });
  assert.equal(f.requests.length, 1); assert.deepEqual(f.events.map(e => e.type), ['dispatch', 'http']);
  const aux = { observer: f.observer, dispatched: true };
  assert.throws(() => f.companionAuxiliaryFetch(aux, 'https://synthetic.invalid/second', { signal: f.abort.signal }), { code: 'COMPANION_AUXILIARY_RETRY_DENIED' });
  assert.equal(f.requests.length, 1);
  const image = await sourceFixture(root, { image: true, transport: () => Promise.resolve(new Response('rejected', { status: 400 })) });
  const call = await image.prepare();
  await assert.rejects(collect(call.stream({ system: 'fixed', input: 'screen',
    screenImage: { mediaType: 'image/jpeg', width: 1, height: 1, data: '/9j/wAALCAABAAEBAREA/9k=' } })), { code: 'INVALID_REQUEST' });
  assert.equal(image.requests.length, 1, 'a rejected image has no text retry');
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
  assert.equal(await f.llm.companionScreenCapability(f.config.provider, f.config.model, f.abort.signal), undefined);
  const call = await f.prepare();
  assert.throws(() => call.stream({ system: 'fixed', input: 'fixed', screenImage: {} }), { code: 'UNSUPPORTED_CONTENT' });
  assert.equal(f.requests.length, 0, 'a text-only model cannot use the image entry');
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
