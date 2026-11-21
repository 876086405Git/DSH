import test from 'node:test';
import assert from 'node:assert/strict';
import { chatSourceFixture, auxiliarySse, piAiSourceFixture } from './fixtures/companion-chat-usage-source.mjs';

const root = process.env.DSH_CHAT_USAGE_SOURCES;
const sourceTest = (name, fn) => test(name, { skip: root ? false :
  'Set DSH_CHAT_USAGE_SOURCES to the verified dependency slice; these tests do not install or boot the engine' }, fn);
const tick = () => new Promise(resolve => setImmediate(resolve));
const eventually = async check => {
  const deadline = Date.now() + 2000;
  while (!check()) { assert(Date.now() < deadline, 'source boundary was not reached'); await tick(); }
};
const frame = event => new TextEncoder().encode(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
async function fixture(t, options) {
  const f = await chatSourceFixture(root, { ...options, lookupWindow: process.env.DSH_LOOKUP_WINDOW === '1' });
  t.after(() => f.dispose()); return f;
}
const finish = f => { f.context.end(f.agent.session); return f.snapshot(); };

sourceTest('ordinary marked request uses actual AsyncLocal ownership, preserves tools/extensions/history and stores final raw without filling missing fields', async t => {
  let accepts = 0;
  const final = { input_tokens: 11, output_tokens: 7, cache_read_input_tokens: 13, extra: { original: true } };
  const f = await fixture(t, { response: { finalUsage: final }, extensionFields: { extension_synthetic: 123 }, onAccept: () => accepts++ });
  assert.equal(f.prepare().chatUsage, true); f.claim();
  const tools = [{ name: 'synthetic_tool', description: 'Synthetic read', parameters: { type: 'object', properties: {} } }];
  const chunks = await f.run({ controls: { ...f.config, tools } });
  const result = finish(f), receipt = result.receipts[0];
  assert.equal(f.requests.length, 1); assert.equal(accepts, 1);
  assert.equal(f.requests[0].url, 'https://synthetic.invalid/anthropic/v1/messages');
  assert.equal(f.requests[0].body.extension_synthetic, 123);
  assert.deepEqual(f.requests[0].body.tools, [{ name: tools[0].name, description: tools[0].description, input_schema: tools[0].parameters }]);
  assert.equal(f.requests[0].init.headers['x-deepseek-harness-session-id'], 'chat-session');
  assert.equal(chunks.at(-1).reason.kind, 'stop'); assert.equal(chunks.find(c => c.type === 'usage').usage.inputTokens, 11);
  assert.equal(result.state, 'settled'); assert.equal(result.complete, true);
  assert.equal(result.physicalRequests, 1); assert.equal(result.observedAdapterCalls, 1); assert.equal(result.activeCalls, 0);
  assert.deepEqual(receipt.requestIds, ['phone-request']); assert.equal(receipt.observation, 'fetch-invoked');
  assert.equal(receipt.dispatched, true); assert(Number.isSafeInteger(receipt.dispatchAtMs));
  assert.equal(receipt.phase, 'finished'); assert.equal(receipt.complete, true); assert.equal(receipt.terminal, 'complete');
  assert.deepEqual(receipt.usage.final_usage, final); assert.equal(receipt.usage.input_cache_write, null);
  assert.equal(receipt.usage.runtime_normalized_usage, undefined);
  assert(!JSON.stringify(result).includes('SYNTHETIC_PHONE_HUMAN'));
  assert(!JSON.stringify(result).includes('synthetic-test-only'));
  result.receipts[0].usage.final_usage.extra.original = false;
  assert.equal(f.snapshot().receipts[0].usage.final_usage.extra.original, true, 'queries return detached snapshots');
});

sourceTest('actual translator final-only output stays missing input even when normalized usage retains message_start input', async t => {
  const f = await fixture(t, { response: { startUsage: { input_tokens: 90, cache_read_input_tokens: 3 }, finalUsage: { output_tokens: 5 } } });
  f.prepare(); f.claim(); const chunks = await f.run();
  const receipt = finish(f).receipts[0];
  assert.equal(chunks.find(c => c.type === 'usage').usage.inputTokens, 90);
  assert.equal(receipt.usage.start_usage.input_tokens, 90);
  assert.deepEqual(receipt.usage.final_usage, { output_tokens: 5 });
  assert.equal(receipt.usage.input_uncached, null); assert.equal(receipt.usage.input_cache_read, null);
  assert.equal(receipt.usage.output_tokens, 5);
});

sourceTest('final usage followed by EOF remains known while the response is incomplete', async t => {
  const f = await fixture(t, { response: { finalUsage: { output_tokens: 7, original: 'final' }, incomplete: true } });
  f.prepare(); f.claim(); const chunks = await f.run();
  const result = finish(f), receipt = result.receipts[0];
  assert.equal(chunks.at(-1).reason.failure.code, 'STREAM_CLOSED');
  assert.equal(chunks.some(c => c.type === 'usage'), false);
  assert.equal(result.complete, true, 'physical coverage can be closed while the provider response is incomplete');
  assert.equal(receipt.complete, false); assert.equal(receipt.terminal, 'incomplete');
  assert.equal(receipt.usage.final_usage.original, 'final'); assert.equal(receipt.usage.output_tokens, 7);
});

sourceTest('start-only EOF and empty complete reply keep different terminal evidence', async t => {
  const f = await fixture(t, { transport: () => Promise.resolve(new Response(frame({ type: 'message_start', message: { usage: { input_tokens: 19 } } }))) });
  f.prepare(); f.claim(); const chunks = await f.run();
  const receipt = finish(f).receipts[0];
  assert.equal(chunks.at(-1).reason.failure.code, 'STREAM_CLOSED');
  assert.deepEqual(receipt.usage.start_usage, { input_tokens: 19 });
  assert.equal(receipt.usage.final_usage, null); assert.equal(receipt.usage.input_uncached, null);
  assert.equal(receipt.complete, false);
  const g = await fixture(t, { response: { empty: true } }); g.prepare(); g.claim();
  assert.equal((await g.run()).at(-1).reason.failure.code, 'EMPTY_RESPONSE');
  const empty = finish(g).receipts[0];
  assert.equal(empty.complete, true); assert.equal(empty.terminal, 'empty_response');
  assert.equal(empty.usage.output_tokens, 7);
});

sourceTest('HTTP failure and synchronous fetch throw are physical invocations; credentials failure is preflight', async t => {
  const f = await fixture(t, { transport: () => Promise.resolve(new Response(JSON.stringify({ error: { message: 'SYNTHETIC_SECRET_BODY', type: 'authentication_error' } }), { status: 401 })) });
  f.prepare(); f.claim(); assert.equal((await f.run()).at(-1).reason.failure.code, 'AUTH');
  const http = finish(f).receipts[0];
  assert.equal(http.dispatched, true); assert.equal(http.httpStatus, 401); assert.equal(http.terminal, 'http_error');
  assert.equal(http.errorCode, 'AUTH'); assert.equal(http.complete, false);
  assert(!JSON.stringify(http).includes('SYNTHETIC_SECRET_BODY'));
  const g = await fixture(t, { transport: () => { throw new Error('SYNTHETIC_SECRET_EXCEPTION'); } });
  g.prepare(); g.claim(); assert.equal((await g.run()).at(-1).reason.failure.code, 'TRANSPORT');
  const thrown = finish(g).receipts[0];
  assert.equal(thrown.physicalRequests, 1); assert.equal(thrown.terminal, 'network_error');
  assert(!JSON.stringify(thrown).includes('SYNTHETIC_SECRET_EXCEPTION'));
  const h = await fixture(t, { authError: true }); h.prepare(); h.claim();
  assert.equal((await h.run()).at(-1).reason.failure.code, 'MISSING_CREDENTIAL');
  const preflight = finish(h);
  assert.equal(h.requests.length, 0); assert.equal(preflight.physicalRequests, 0);
  assert.equal(preflight.receipts[0].observation, 'preflight'); assert.equal(preflight.receipts[0].dispatched, false);
});

sourceTest('the real RequestFiles stale-id branch makes two model POSTs and two receipts under one call', async t => {
  const attachment = { attachmentId: 'sha256:synthetic-image', width: 2, height: 2, mediaType: 'image/png' };
  const version = { attachment, variantId: 'synthetic-variant', bytes: 4, data: new Uint8Array([1, 2, 3, 4]),
    width: 2, height: 2, mediaType: 'image/png', hasAlpha: false };
  let uploads = 0; const invalidated = [];
  const f = await fixture(t, { attachments: { async readImageRequest(ref, target) {
    assert.equal(ref, attachment); assert.equal(target.width, 2); return version;
  } }, files: {
    async ensureUploaded() { return { record: { fileId: ++uploads === 1 ? 'file-old' : 'file-new' } }; },
    async invalidate(value) { invalidated.push(value); },
  }, transport: (_url, _init, attempt) => Promise.resolve(attempt === 1 ? new Response(JSON.stringify({
    error: { type: 'invalid_request_error', message: 'file_id file-old not found' },
  }), { status: 400 }) : auxiliarySse()) });
  f.connection.models[0].inputModalities.push('image'); f.prepare(); f.claim();
  const human = f.human(), message = Object.freeze({ ...human,
    content: Object.freeze([...human.content, { type: 'image', attachment }]) });
  const before = JSON.stringify(message), chunks = await f.run({ messages: [message] });
  assert.equal(chunks.at(-1).reason.kind, 'stop'); assert.equal(JSON.stringify(message), before);
  assert.equal(f.requests.length, 2); assert.equal(uploads, 2);
  assert.deepEqual(invalidated, [[{ variantId: 'synthetic-variant', fileId: 'file-old' }]]);
  assert(JSON.stringify(f.requests[0].body).includes('file-old')); assert(JSON.stringify(f.requests[1].body).includes('file-new'));
  const result = finish(f); assert.equal(result.complete, true); assert.equal(result.observedAdapterCalls, 1);
  assert.equal(result.physicalRequests, 2); assert.equal(result.receipts.length, 2);
  assert.equal(result.receipts[0].callId, result.receipts[1].callId);
  assert.notEqual(result.receipts[0].receiptId, result.receipts[1].receiptId);
  assert.equal(result.receipts[0].terminal, 'http_error'); assert.equal(result.receipts[0].complete, false);
  assert.equal(result.receipts[1].complete, true);
});

sourceTest('the selected real PiAiAdapter retains normalized data separately and leaves physical and raw evidence unknown', async t => {
  const f = await fixture(t), pi = await piAiSourceFixture(root, f);
  f.llm.adapters.set(pi.provider, { provider: { id: pi.provider }, adapter: pi.adapter });
  f.prepare(); f.claim(); const chunks = await f.run({ controls: { provider: pi.provider, model: pi.model.id, maxTokens: 111 } });
  assert.equal(chunks.at(-1).reason.kind, 'stop'); assert.equal(f.requests.length, 0);
  assert.equal(pi.calls.length, 1); assert.equal(pi.calls[0].options.maxRetries, 0);
  assert.equal(pi.calls[0].options.sessionId, 'chat-session');
  const result = finish(f), receipt = result.receipts[0];
  assert.equal(result.state, 'settled'); assert.equal(result.complete, false); assert.equal(result.physicalRequests, null);
  assert.deepEqual(result.gaps, ['physical-count-unknown']); assert.equal(receipt.dispatched, null);
  assert.equal(receipt.observation, 'adapter-invoked'); assert.equal(receipt.usage.final_usage, null);
  assert.equal(receipt.usage.input_uncached, null); assert.equal(receipt.usage.output_tokens, null);
  assert.deepEqual(receipt.usage.runtime_normalized_usage, [{ inputTokens: 4, outputTokens: 2, totalTokens: 6 }]);
  assert.equal(receipt.usage.runtime_normalized_usage_semantics, 'runtime-normalized-events');
});

sourceTest('unmarked compaction, absent initiator, wrong actual agent and an unprepared human do not borrow phone accounting', async t => {
  for (const boundary of ['unmarked', 'compaction', 'no-initiator', 'other-agent', 'unprepared-human']) {
    const f = await fixture(t); f.prepare(); f.claim();
    const options = boundary === 'unmarked' ? { marked: false } : boundary === 'compaction' ? {
      marked: false, controls: { ...f.config, purpose: 'compaction' },
    } : boundary === 'no-initiator' ? { initiator: null } : boundary === 'other-agent' ? {
      initiator: f.actor('another-session'),
    } : { requestId: 'unprepared' };
    if (boundary === 'unprepared-human') f.claim(f.agent, 'unprepared');
    assert.equal((await f.run(options)).at(-1).reason.kind, 'stop', boundary);
    const result = finish(f);
    assert.equal(result.observedAdapterCalls, 0, boundary); assert.deepEqual(result.receipts, [], boundary);
    assert.equal(result.complete, false, boundary); assert(result.gaps.includes('no-call-observation'), boundary);
  }
  const f = await fixture(t); await f.run();
  assert.equal(f.snapshot().state, 'unknown', 'ordinary non-phone session has no chat receipt');
});

sourceTest('auxiliary calls remain outside chat ownership even inside the real initiating Agent context', async t => {
  const f = await fixture(t); f.prepare(); f.claim(); const events = [];
  const call = await f.llm.prepareCompanionAuxiliaryCall(f.config, new AbortController().signal,
    { guard() {}, observe(event) { events.push(event); } });
  await f.agents.withInitiator(f.agent, async () => { for await (const _ of call.stream({ system: 'synthetic', input: 'AUXILIARY_ONLY' })) {} });
  assert.equal(f.requests.length, 1); assert.equal(events[0].type, 'dispatch');
  const result = finish(f); assert.equal(result.observedAdapterCalls, 0); assert.deepEqual(result.receipts, []);
});

sourceTest('same-turn roots share stable global receipts while subsequent actual adapter calls have distinct call IDs', async t => {
  const f = await fixture(t); f.prepare(f.agent, 'first'); f.prepare(f.agent, 'second');
  f.claim(f.agent, 'first', 9); f.claim(f.agent, 'second', 9);
  const messages = [f.human('first'), f.human('second')];
  await f.run({ requestId: 'second', messages });
  await f.run({ requestId: 'second', messages });
  f.context.end(f.agent.session);
  const first = f.snapshot('first'), second = f.snapshot('second');
  assert.equal(first.physicalRequests, 2); assert.equal(second.physicalRequests, 2);
  assert.deepEqual(first.receipts, second.receipts);
  assert.deepEqual(first.receipts[0].requestIds, ['first', 'second']);
  assert.notEqual(first.receipts[0].callId, first.receipts[1].callId);
  assert.notEqual(first.receipts[0].receiptId, first.receipts[1].receiptId);
  assert.equal(new Set([...first.receipts, ...second.receipts].map(r => r.receiptId)).size, 2);
});

sourceTest('concurrent actual AgentRegistry AsyncLocal scopes never cross-charge distinct phone sessions', async t => {
  let release, entered = 0;
  const f = await fixture(t, { authGate: new Promise(resolve => { release = resolve; }), onAuth: () => entered++ });
  const other = f.actor('other-phone-session');
  f.prepare(f.agent, 'first'); f.prepare(other, 'second'); f.claim(f.agent, 'first'); f.claim(other, 'second');
  const first = f.run({ requestId: 'first' }), second = f.run({ target: other, requestId: 'second' });
  await eventually(() => entered === 2); release();
  assert.equal((await first).at(-1).reason.kind, 'stop'); assert.equal((await second).at(-1).reason.kind, 'stop');
  f.context.end(f.agent.session); f.context.end(other.session);
  const a = f.snapshot('first'), b = f.snapshot('second', other);
  assert.equal(a.physicalRequests, 1); assert.equal(b.physicalRequests, 1);
  assert.deepEqual(a.receipts[0].requestIds, ['first']); assert.deepEqual(b.receipts[0].requestIds, ['second']);
  assert.notEqual(a.receipts[0].receiptId, b.receipts[0].receiptId);
  assert.deepEqual(new Set(f.requests.map(r => r.init.headers['x-deepseek-harness-session-id'])),
    new Set(['chat-session', 'other-phone-session']));
});

sourceTest('receipt ownership survives the selected-memory TTL, while a changed real Agent during auth remains preflight', async t => {
  const f = await fixture(t); f.prepare(); f.claim(); f.setTime(1795280000000 + 31 * 60000);
  assert.equal((await f.run()).at(-1).reason.kind, 'stop'); assert.equal(finish(f).physicalRequests, 1);
  let release, authEntered = false;
  const g = await fixture(t, { authGate: new Promise(resolve => { release = resolve; }), onAuth: () => { authEntered = true; } });
  g.prepare(); g.claim(); const pending = g.run(); await eventually(() => authEntered);
  g.actor(g.agent.id); release(); const chunks = await pending;
  assert.equal(g.requests.length, 0); assert.equal(chunks.at(-1).reason.kind, 'error');
  const result = finish(g); assert.equal(result.receipts[0].dispatched, false);
});

sourceTest('raw final is queryable before EOF; cancellation and turn end cannot seal a still-draining physical reader', async t => {
  let controller;
  const response = new Response(new ReadableStream({ start(value) { controller = value; } }));
  const abort = new AbortController();
  const f = await fixture(t, { transport: () => Promise.resolve(response) }); f.prepare(); f.claim();
  const pending = f.run({ signal: abort.signal });
  controller.enqueue(frame({ type: 'message_start', message: { usage: { input_tokens: 5 } } }));
  controller.enqueue(frame({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }));
  controller.enqueue(frame({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'synthetic' } }));
  controller.enqueue(frame({ type: 'content_block_stop', index: 0 }));
  controller.enqueue(frame({ type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 8 } }));
  await eventually(() => f.snapshot().receipts[0]?.usage.output_tokens === 8);
  const active = f.snapshot(); assert.equal(active.state, 'running'); assert.equal(active.receipts[0].phase, 'active');
  abort.abort(); assert.equal((await pending).at(-1).reason.kind, 'aborted');
  f.context.end(f.agent.session);
  const draining = f.snapshot(); assert.equal(draining.state, 'running'); assert.equal(draining.activeCalls, 1);
  controller.close(); await eventually(() => f.snapshot().activeCalls === 0);
  const settled = f.snapshot(); assert.equal(settled.state, 'settled'); assert.equal(settled.physicalRequests, 1);
  assert.equal(settled.receipts[0].receiptId, active.receipts[0].receiptId);
  assert(settled.receipts[0].revision > active.receipts[0].revision);
  assert.equal(settled.receipts[0].usage.output_tokens, 8); assert.equal(settled.receipts[0].terminal, 'cancelled');
  assert.equal(settled.receipts[0].complete, false);
});

sourceTest('observer exceptions never change the actual model chunks, extensions or physical dispatch', async t => {
  for (const method of ['beginPhysical', 'chunk', 'observe', 'close']) {
    let accepted = 0;
    const f = await fixture(t, { onAccept: () => accepted++ }); f.prepare(); f.claim();
    f.services.set('dshGoCompanionContext', { ...f.context, observeUsageRequest(...args) {
      const real = f.context.observeUsageRequest(...args);
      return { ...real,
        beginPhysical(at) {
          if (method === 'beginPhysical') throw new Error('synthetic observer failure');
          const physical = real.beginPhysical(at);
          return { ...physical, [method]: method === 'observe' || method === 'close'
            ? () => { throw new Error('synthetic observer failure'); } : physical[method] };
        },
        chunk: method === 'chunk' ? () => { throw new Error('synthetic observer failure'); } : real.chunk,
      };
    } });
    const chunks = await f.run(); assert.equal(chunks.at(-1).reason.kind, 'stop', method);
    assert.equal(f.requests.length, 1, method); assert.equal(accepted, 1, method);
    const result = finish(f); assert(result.gaps.includes('observer-error'), method);
    assert.equal(result.complete, false, method); assert.equal(result.physicalRequests, null, method);
  }
});

sourceTest('cache capacity records an explicit accounting gap without refusing the next ordinary model call', async t => {
  const f = await fixture(t, { usageLimits: { receipts: 1 } }); f.prepare(); f.claim();
  await f.run(); const first = f.snapshot().receipts[0];
  assert.equal((await f.run()).at(-1).reason.kind, 'stop');
  const result = finish(f); assert.equal(f.requests.length, 2); assert.equal(result.observedAdapterCalls, 2);
  assert.equal(result.receipts.length, 1); assert.equal(result.receipts[0].receiptId, first.receiptId);
  assert(result.gaps.includes('capacity')); assert.equal(result.complete, false); assert.equal(result.physicalRequests, null);
});
