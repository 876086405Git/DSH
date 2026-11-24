import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createCompanionRoutes } from '../bridge/dsh-go-bridge/lib/companion/routes.js';
import { FULL_PRESET } from '../bridge/dsh-go-bridge/lib/companion/prompt-context.js';

const PATH = '/dsh-go/v1/companion/auxiliary';
const capability = { physicalDispatch: 'fetch-invoked', rawUsage: 'deepseek-messages-cumulative', maxPhysicalRequests: 1, noTools: true };
const genericCapability = { physicalDispatch: 'unknown', rawUsage: 'unavailable', maxPhysicalRequests: null, noTools: true };
const defer = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const until = async predicate => { for (let i = 0; i < 200 && !predicate(); i++) await new Promise(r => setImmediate(r)); assert(predicate()); };

// These tests use a real HTTP route and a deliberately explicit adapter double.
// Locked adapter methods/physical fetch are exercised in the separate runtime
// tests; this double does not claim to prove a provider hook exists.
async function fixture(t, configure = {}) {
  const state = { selected: { provider: 'selected-provider', model: 'selected-model' },
    supported: true, resolves: 0, prepares: 0, invocations: 0, ...configure };
  const listeners = new Map();
  const llm = {
    companionAuxiliaryCapability(provider) { assert.equal(provider, state.selected.provider); return state.supported ? state.generic ? genericCapability : capability : undefined; },
    async companionScreenCapability(provider, model) {
      assert.equal(provider, 'screen-provider'); assert.equal(model, 'screen-model');
      return state.screenSupported ? { ...capability, transientImage: 'jpeg-512-inline' } : undefined;
    },
    async prepareCompanionAuxiliaryCall(config, signal, observer) {
      state.prepares++; state.config = config; state.signal = signal;
      await state.prepareGate?.promise;
      if (state.prepareError) throw state.prepareError;
      observer.guard();
      return { config, stream: async function* (payload) {
        state.payload = payload;
        await state.sendGate?.promise;
        observer.guard(); signal.throwIfAborted();
        state.invocations++;
        observer.observe({ type: state.generic ? 'handoff' : 'dispatch', atMs: 1795280000123,
          boundary: state.generic ? 'adapter-invoked' : 'fetch-invoked' });
        if (!state.generic) observer.observe({ type: 'http', status: state.httpStatus ?? 200 });
        if (state.streamError) throw state.streamError;
        if (!state.generic) observer.observe({ type: 'usage', event: 'message_start', raw: { input_tokens: 51, output_tokens: 0, cache_read_input_tokens: 99, custom_field: { retained: true } } });
        await state.outputGate?.promise;
        signal.throwIfAborted();
        yield { type: 'text-delta', text: state.output ?? '{"items":[]}' };
        if (state.tool) { yield { type: 'block-start', blockType: 'tool-call' }; return; }
        if (!state.generic) {
          observer.observe({ type: 'usage', event: 'message_delta', raw: state.finalUsage ?? { output_tokens: 7 } });
          observer.observe({ type: 'stop', stopReason: state.stopReason ?? 'end_turn' });
          observer.observe({ type: 'complete' });
          state.providerCompleted = true;
          await state.completeGate?.promise;
          if (state.completeError) throw state.completeError;
        }
        yield { type: 'usage', usage: { inputTokens: 99999, cacheReadTokens: 99999, outputTokens: 99999 } };
        yield { type: 'finish', reason: { kind: state.finishKind ?? 'stop' } };
      } };
    },
  };
  const session = { id: 'session', deriveMessages() { throw new Error('Auxiliary route must not read history'); }, append() { throw new Error('Auxiliary route must not persist events'); } };
  const agent = { id: 'session', session, model: { current: () => state.selected } };
  const ctx = { get(name) { return {
    llm,
    connection: { admit: req => req.headers.authorization === 'owner' ? { peer: { principal: { kind: 'owner' } } } :
      req.headers.authorization === 'reader' ? { peer: { principal: { kind: 'reader' } } } : { rejection: 401 } },
    sessionController: { async resolveAgent(id) {
      state.resolves++;
      if (state.resolveGate) await state.resolveGate.promise;
      return id === 'session' ? { agent } : undefined;
    } },
    agentPresets: { presetForSession: () => state.wrongPreset ? 'other' : FULL_PRESET },
    agents: { get: id => id === 'session' && !state.retired ? agent : undefined },
  }[name]; }, on(name, fn) { listeners.set(name, fn); return () => listeners.delete(name); } };
  agent.ctx = ctx;
  const route = createCompanionRoutes({ ctx,
    store: {}, send(res, status, body) { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); } });
  const server = createServer((req, res) => { void route.handle(req, res, new URL(req.url, 'http://local').pathname); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const origin = `http://127.0.0.1:${server.address().port}`;
  t.after(async () => { route.dispose(); server.closeAllConnections(); await new Promise(r => server.close(r)); });
  async function http({ path = `${PATH}?sessionId=session`, method = 'GET', auth = 'owner', body, type = 'application/json', signal } = {}) {
    const response = await fetch(origin + path, { method, headers: { authorization: auth, 'content-type': type },
      ...(body === undefined ? {} : { body: typeof body === 'string' ? body : JSON.stringify(body) }), signal });
    const value = await response.text();
    return { status: response.status, body: response.headers.get('content-type').startsWith('application/x-ndjson')
      ? value.trim().split('\n').map(line => JSON.parse(line)) : JSON.parse(value) };
  }
  const info = await http();
  const body = extra => ({ v: 1, instanceId: info.body.instanceId, requestId: 'request', sessionId: 'session',
    provider: state.selected.provider, model: state.selected.model, kind: 'extract', system: 'Fixed extraction instructions',
    input: 'A synthetic versioned source with its original time.', maxTokens: 512, ...extra });
  const post = extra => http({ method: 'POST', body: body(extra) });
  const screenBody = extra => ({ v: 1, instanceId: info.body.instanceId, requestId: 'screen-request',
    provider: 'screen-provider', model: 'screen-model', kind: 'screen', system: 'Classify this external screen data.',
    input: 'Synthetic accessibility text.', maxTokens: 220,
    image: { mediaType: 'image/jpeg', width: 1, height: 1, data: '/9j/wAALCAABAAEBAREA/9k=' }, ...extra });
  return { state, http, post, body, screenBody, info, agent, listeners, route, origin };
}

test('owner authentication and exact input validation run before model preparation', async t => {
  const f = await fixture(t); const baseline = f.state.resolves;
  for (const [auth, status] of [['reader', 403], ['anonymous', 401]]) {
    assert.equal((await f.http({ auth })).status, status);
    assert.equal((await f.http({ method: 'POST', auth, body: f.body() })).status, status);
  }
  for (const [body, type, status] of [[f.body(), 'text/plain', 415], ['{', 'application/json', 400],
    [f.body({ tools: [] }), 'application/json', 400], [f.body({ kind: 'chat' }), 'application/json', 400], [f.body({ maxTokens: 3001 }), 'application/json', 400],
    [f.body({ input: '\ud800' }), 'application/json', 400], ['x'.repeat(65537), 'application/json', 413],
    [JSON.stringify(f.body()).replace('"v":1', '"v":1,"v":1'), 'application/json', 400]]) {
    const r = await f.http({ method: 'POST', body, type }); assert.equal(r.status, status); assert.equal(r.body.dispatched, false);
  }
  assert.equal(f.state.resolves, baseline); assert.equal(f.state.prepares, 0);
  for (const auth of ['reader', 'anonymous']) {
    assert.equal((await f.http({ path: `${PATH}/screen`, method: 'POST', auth, body: f.screenBody() })).body.dispatched, false);
  }
  for (const extra of [{ sessionId: 'session' }, { tools: [] }, { image: { mediaType: 'image/jpeg', width: 513, height: 1, data: '/9j/2Q==' } }]) {
    assert.equal((await f.http({ path: `${PATH}/screen`, method: 'POST', body: f.screenBody(extra) })).status, 400);
  }
  assert.equal(f.state.prepares, 0); assert.equal(f.state.invocations, 0);
});

test('full mode follows the explicit current route and keeps provider raw usage separate from normalized usage', async t => {
  const f = await fixture(t);
  assert.equal(f.info.body.provider, 'selected-provider'); assert.deepEqual(f.info.body.capability, capability);
  const r = await f.post(); assert.equal(r.status, 200);
  assert.deepEqual(r.body.map(e => e.type), ['accepted', 'dispatch', 'usage', 'text', 'usage', 'finish']);
  const last = r.body.at(-1);
  assert.equal(last.dispatched, true); assert.equal(last.dispatchAtMs, 1795280000123);
  assert.equal(last.terminal, 'complete'); assert.equal(last.complete, true);
  assert.equal(last.usage.start_usage.custom_field.retained, true);
  assert.equal(last.usage.input_uncached, null); assert.equal(last.usage.input_cache_read, null);
  assert.equal(last.usage.input_cache_write, null); assert.equal(last.usage.output_tokens, 7);
  assert.equal(last.usage.provider, 'selected-provider'); assert.equal(last.usage.model, 'selected-model');
  assert.deepEqual(Object.keys(f.state.payload), ['system', 'input']);
  assert.deepEqual(f.state.config, { provider: 'selected-provider', model: 'selected-model', reasoningEffort: 'off', maxTokens: 512 });
  assert.equal(f.state.invocations, 1);
  f.state.screenSupported = true;
  const resolves = f.state.resolves;
  const selected = { ...f.state.selected };
  const screenInfo = await f.http({ path: `${PATH}?kind=screen&provider=screen-provider&model=screen-model&reasoningEffort=off` });
  assert.equal(screenInfo.body.supported, true); assert.equal(screenInfo.body.kind, 'screen');
  assert.equal(screenInfo.body.capability.transientImage, 'jpeg-512-inline');
  const screen = await f.http({ path: `${PATH}/screen`, method: 'POST', body: f.screenBody({ reasoningEffort: 'off' }) });
  assert.equal(screen.body.at(-1).terminal, 'complete'); assert.equal(screen.body.at(-1).complete, true);
  assert.equal(screen.body.at(-1).usage.provider, 'screen-provider');
  assert.equal(screen.body.at(-1).usage.output_tokens, 7);
  assert.deepEqual(f.state.payload.screenImage, f.screenBody().image);
  assert.deepEqual(f.state.config, { provider: 'screen-provider', model: 'screen-model', reasoningEffort: 'off', maxTokens: 220 });
  assert.equal(f.state.resolves, resolves, 'screen classification never resolves a Session');
  assert.deepEqual(f.state.selected, selected, 'the ordinary conversation selection is untouched');
  assert.equal(f.state.invocations, 2);
  f.state.streamError = Object.assign(new Error('synthetic image transport'), { code: 'TRANSPORT' });
  const failed = await f.http({ path: `${PATH}/screen`, method: 'POST', body: f.screenBody({ requestId: 'screen-failed' }) });
  assert.equal(failed.body.at(-1).complete, false);
  assert.equal(failed.body.at(-1).dispatched, true);
  assert.equal(f.state.invocations, 3, 'an image failure cannot dispatch a text fallback');
});

test('an absent callable transport and a different requested model never fall back to DeepSeek', async t => {
  const f = await fixture(t, { supported: false });
  assert.equal(f.info.body.supported, false); assert.equal(f.info.body.reason, 'adapter-call-unavailable');
  const r = await f.post(); assert.equal(r.body.at(-1).dispatched, false);
  assert.equal(r.body.at(-1).error.code, 'companion/auxiliary-unavailable');
  f.state.supported = true;
  const mismatch = await f.post({ requestId: 'changed-model', model: 'other' });
  assert.equal(mismatch.body.at(-1).dispatched, false);
  assert.equal(mismatch.body.at(-1).error.code, 'companion/auxiliary-selection-changed');
  assert.equal(f.state.prepares, 0); assert.equal(f.state.invocations, 0);
  const unavailable = await f.http({ path: `${PATH}?kind=screen&provider=screen-provider&model=screen-model` });
  assert.equal(unavailable.body.supported, false);
  const screen = await f.http({ path: `${PATH}/screen`, method: 'POST', body: f.screenBody() });
  assert.equal(screen.body.at(-1).dispatched, false);
  assert.equal(f.state.prepares, 0); assert.equal(f.state.invocations, 0);
});

test('generic selected provider is sent once through its adapter and finishes with nullable physical dispatch and distinct normalized usage', async t => {
  const f = await fixture(t, { generic: true });
  assert.equal(f.info.body.supported, true); assert.deepEqual(f.info.body.capability, genericCapability);
  const r = await f.post(), last = r.body.at(-1);
  assert.equal(f.state.prepares, 1); assert.equal(f.state.config.provider, 'selected-provider');
  assert.equal(f.state.config.reasoningEffort, undefined, 'do not force off on models without this control');
  assert.equal(r.body.some(e => e.type === 'dispatch' || e.type === 'usage'), false);
  assert.deepEqual(r.body.find(e => e.type === 'runtime-usage').usage, { inputTokens: 99999, cacheReadTokens: 99999, outputTokens: 99999 });
  assert.equal(last.dispatched, null); assert.equal(last.dispatchAtMs, null); assert.equal(last.complete, true);
  assert.equal(last.terminal, 'complete'); assert.equal(last.usage.usage_semantics, 'unknown');
  assert.equal(last.usage.start_usage, null); assert.equal(last.usage.final_usage, null);
  assert.equal(last.usage.input_uncached, null); assert.equal(last.usage.output_tokens, null);
  assert.equal(last.usage.runtime_normalized_usage[0].outputTokens, 99999);
  assert.equal(last.usage.host_adapter_handoff_at_ms, 1795280000123);
  const status = await f.http({ path: `${PATH}/requests/request?instanceId=${f.info.body.instanceId}` });
  assert.equal(status.body.dispatched, null, 'finished generic handoff never becomes proven unsent');
  f.state.streamError = Object.assign(new Error('synthetic'), { code: 'MISSING_CREDENTIAL' });
  const uncertain = await f.post({ requestId: 'generic-error' });
  assert.equal(uncertain.body.at(-1).dispatched, null);
});

test('same ID never reissues, conflicting body rejects, and restart cannot prove the old request unsent', async t => {
  const f = await fixture(t);
  await f.post();
  const again = await f.post(); assert.equal(again.status, 409); assert.equal(again.body.dispatched, null);
  assert.equal(again.body.receipt.finish.dispatched, true);
  assert.equal((await f.post({ input: 'changed' })).body.error.code, 'companion/auxiliary-request-conflict');
  const reboot = await f.post({ requestId: 'new-id', instanceId: 'old-bridge' });
  assert.equal(reboot.body.dispatched, null); assert.equal(reboot.body.error.code, 'companion/auxiliary-instance-changed');
  const status = await f.http({ path: `${PATH}/requests/request?instanceId=${f.info.body.instanceId}` });
  assert.equal(status.body.phase, 'finished'); assert.equal(status.body.finish.usage.output_tokens, 7);
  assert(!JSON.stringify(status.body).includes('synthetic versioned source'));
  assert(!JSON.stringify(status.body).includes('{"items":[]}'));
  assert.equal(f.state.invocations, 1);
});

test('a pending request reports unknown, busy rejects another, and model changes before fetch prevent dispatch', async t => {
  const prepareGate = defer(); const f = await fixture(t, { prepareGate });
  const pending = f.post(); await until(() => f.state.prepares === 1);
  const status = await f.http({ path: `${PATH}/requests/request?instanceId=${f.info.body.instanceId}` });
  assert.equal(status.body.dispatched, null);
  const busy = await f.post({ requestId: 'another' }); assert.equal(busy.status, 409); assert.equal(busy.body.dispatched, false);
  f.state.selected = { provider: 'changed', model: 'changed' }; prepareGate.resolve();
  const r = await pending; assert.equal(r.body.at(-1).dispatched, false); assert.equal(f.state.invocations, 0);

  // The provider can finish before the bridge sees its final chunks or a
  // content-only error. Neither observation overrides the current owner guard.
  for (const [change, code] of [['model', undefined], ['model', 'EMPTY_RESPONSE'], ['cancel', 'REFUSAL']]) {
    const completeGate = defer();
    const g = await fixture(t, { completeGate,
      ...(code ? { completeError: Object.assign(new Error('Synthetic completed content'), { code }) } : {}) });
    const late = g.post();
    let response;
    try {
      await until(() => g.state.providerCompleted === true);
      if (change === 'model') g.state.selected = { ...g.state.selected, model: 'changed-after-complete' };
      else g.listeners.get('session/event')(g.agent.session, { type: 'model/selection' });
    } finally {
      completeGate.resolve();
      response = await late;
    }
    const last = response.body.at(-1);
    assert.equal(last.complete, false); assert.equal(last.usage.complete, false);
    assert.equal(last.terminal, change === 'cancel' ? 'cancelled' : 'provider_error');
    assert.equal(last.error.code, 'companion/auxiliary-selection-changed');
    assert.equal(last.dispatched, true); assert.equal(last.dispatchAtMs, 1795280000123);
    assert.equal(last.usage.start_usage.input_tokens, 51); assert.equal(last.usage.output_tokens, 7);
    assert.equal(g.state.invocations, 1);
    const saved = await g.http({ path: `${PATH}/requests/request?instanceId=${g.info.body.instanceId}` });
    assert.deepEqual(saved.body.finish, last);
  }

  // Hold the actual resolver after acceptance, before record.agent can bind.
  // A -> B -> A events must latch cancellation even though final values match.
  const h = await fixture(t);
  const resolveGate = defer(); h.state.resolveGate = resolveGate;
  const originalSelection = { ...h.state.selected };
  const beforeResolve = { resolves: h.state.resolves, prepares: h.state.prepares, invocations: h.state.invocations };
  const receiptPath = `${PATH}/requests/resolve-aba?instanceId=${h.info.body.instanceId}`;
  const resolving = h.post({ requestId: 'resolve-aba' });
  let resolved;
  try {
    await until(() => h.state.resolves === beforeResolve.resolves + 1);
    const accepted = await h.http({ path: receiptPath });
    assert.equal(accepted.status, 200); assert.equal(accepted.body.phase, 'accepted');
    assert.equal(accepted.body.dispatched, null); assert.equal(Object.hasOwn(accepted.body, 'finish'), false);
    assert.equal(h.state.prepares, beforeResolve.prepares); assert.equal(h.state.invocations, beforeResolve.invocations);
    h.state.selected = { ...originalSelection, model: 'changed-during-resolve' };
    h.listeners.get('session/event')(h.agent.session, { type: 'model/selection' });
    h.state.selected = originalSelection;
    h.listeners.get('session/event')(h.agent.session, { type: 'model/selection' });
    // abort does not settle the unresolved controller or prove not-sent yet.
    assert.deepEqual((await h.http({ path: receiptPath })).body, accepted.body);
    assert.equal(h.state.prepares, beforeResolve.prepares); assert.equal(h.state.invocations, beforeResolve.invocations);
  } finally {
    resolveGate.resolve();
    resolved = await resolving;
  }
  h.state.resolveGate = undefined;
  const cancelled = resolved.body.at(-1);
  assert.equal(resolved.status, 200); assert.equal(cancelled.terminal, 'cancelled');
  assert.equal(cancelled.complete, false); assert.equal(cancelled.usage.complete, false);
  assert.equal(cancelled.error.code, 'companion/auxiliary-selection-changed');
  assert.equal(cancelled.dispatched, false); assert.equal(cancelled.dispatchAtMs, null);
  assert.equal(h.state.prepares, beforeResolve.prepares); assert.equal(h.state.invocations, beforeResolve.invocations);
  const cancelledReceipt = await h.http({ path: receiptPath });
  assert.equal(cancelledReceipt.body.phase, 'finished'); assert.deepEqual(cancelledReceipt.body.finish, cancelled);
  const used = await h.post({ requestId: 'resolve-aba' });
  assert.equal(used.status, 409); assert.equal(used.body.error.code, 'companion/auxiliary-request-used');
  assert.equal(used.body.dispatched, null); assert.deepEqual(used.body.receipt.finish, cancelled);
  assert.equal(h.state.resolves, beforeResolve.resolves + 1);
  const fresh = await h.post({ requestId: 'resolve-after-aba' });
  assert.equal(fresh.body.at(-1).terminal, 'complete'); assert.equal(fresh.body.at(-1).dispatched, true);
  assert.equal(h.state.invocations, beforeResolve.invocations + 1);

  // A different Session's event must not cancel this accepted resolver.
  const j = await fixture(t);
  const otherGate = defer(); j.state.resolveGate = otherGate;
  const otherBaseline = { resolves: j.state.resolves, prepares: j.state.prepares, invocations: j.state.invocations };
  const otherReceiptPath = `${PATH}/requests/resolve-other-event?instanceId=${j.info.body.instanceId}`;
  const otherPending = j.post({ requestId: 'resolve-other-event' });
  let otherResponse;
  try {
    await until(() => j.state.resolves === otherBaseline.resolves + 1);
    const accepted = await j.http({ path: otherReceiptPath });
    assert.equal(accepted.body.phase, 'accepted'); assert.equal(accepted.body.dispatched, null);
    j.listeners.get('session/event')({ id: 'another-session' }, { type: 'model/selection' });
    assert.deepEqual((await j.http({ path: otherReceiptPath })).body, accepted.body);
    assert.equal(j.state.prepares, otherBaseline.prepares); assert.equal(j.state.invocations, otherBaseline.invocations);
  } finally {
    otherGate.resolve();
    otherResponse = await otherPending;
  }
  const unaffected = otherResponse.body.at(-1);
  assert.equal(unaffected.terminal, 'complete'); assert.equal(unaffected.complete, true);
  assert.equal(unaffected.dispatched, true); assert.equal(j.state.prepares, otherBaseline.prepares + 1);
  assert.equal(j.state.invocations, otherBaseline.invocations + 1);
  assert.deepEqual((await j.http({ path: otherReceiptPath })).body.finish, unaffected);

});

test('auth preflight failure is unsent; HTTP error and transport loss after invocation retain a sent unknown-usage receipt', async t => {
  const f = await fixture(t, { prepareError: Object.assign(new Error('synthetic credential unavailable'), { code: 'MISSING_CREDENTIAL' }) });
  const unsent = await f.post(); assert.equal(unsent.body.at(-1).dispatched, false);
  f.state.prepareError = undefined;
  f.state.httpStatus = 401; f.state.streamError = Object.assign(new Error('synthetic'), { code: 'AUTH' });
  const auth = await f.post({ requestId: 'auth-http' });
  assert.equal(auth.body.at(-1).dispatched, true); assert.equal(auth.body.at(-1).terminal, 'http_error');
  assert.equal(auth.body.at(-1).httpStatus, 401); assert.equal(auth.body.at(-1).usage.output_tokens, null);
  f.state.httpStatus = 200; f.state.streamError = Object.assign(new Error('synthetic'), { code: 'TRANSPORT' });
  const loss = await f.post({ requestId: 'loss' });
  assert.equal(loss.body.at(-1).dispatched, true); assert.equal(loss.body.at(-1).terminal, 'network_error');
  assert.equal(f.state.invocations, 2);
});

test('disconnect after fetch keeps the metadata receipt, including known start usage, with no replay', async t => {
  const outputGate = defer(); const f = await fixture(t, { outputGate });
  const abort = new AbortController();
  const pending = f.http({ method: 'POST', body: f.body(), signal: abort.signal }).catch(error => error);
  await until(() => f.state.invocations === 1);
  abort.abort(); await pending; await until(() => f.state.signal.aborted); outputGate.resolve();
  let status;
  for (let i = 0; i < 20; i++) {
    status = await f.http({ path: `${PATH}/requests/request?instanceId=${f.info.body.instanceId}` });
    if (status.body.phase === 'finished') break;
  }
  assert.equal(status.body.finish.dispatched, true); assert.equal(status.body.finish.terminal, 'cancelled');
  assert.equal(status.body.finish.usage.start_usage.input_tokens, 51); assert.equal(status.body.finish.usage.final_usage, null);
  assert.equal((await f.post()).status, 409); assert.equal(f.state.invocations, 1);
});

test('tool output is never executed and length termination remains distinguishable from successful extraction', async t => {
  const f = await fixture(t, { tool: true });
  const tool = await f.post(); assert.equal(tool.body.at(-1).error.code, 'companion/auxiliary-tool-output');
  assert.equal(tool.body.at(-1).complete, false); assert.equal(tool.body.at(-1).dispatched, true);
  f.state.tool = false; f.state.stopReason = 'max_tokens'; f.state.finishKind = 'max-tokens';
  const length = await f.post({ requestId: 'length' });
  assert.equal(length.body.at(-1).complete, true); assert.equal(length.body.at(-1).terminal, 'max_tokens');

  f.state.stopReason = 'end_turn'; f.state.finishKind = 'aborted';
  const aborted = await f.post({ requestId: 'aborted-finish' });
  assert.equal(aborted.body.at(-1).complete, false); assert.equal(aborted.body.at(-1).terminal, 'cancelled');
  assert.equal(aborted.body.at(-1).usage.output_tokens, 7);

  // Preserve complete empty/refusal outcomes while the bridge still accepts
  // the attempt; these content failures are not a successful model answer.
  for (const code of ['EMPTY_RESPONSE', 'REFUSAL']) {
    f.state.output = ''; f.state.stopReason = code === 'REFUSAL' ? 'refusal' : 'end_turn';
    f.state.finishKind = 'stop';
    f.state.completeError = Object.assign(new Error('Synthetic completed content'), { code });
    const content = await f.post({ requestId: `completed-${code}` });
    const last = content.body.at(-1);
    assert.equal(last.complete, true); assert.equal(last.usage.complete, true);
    assert.equal(last.error.code, code); assert.equal(last.terminal, 'provider_error');
    assert.equal(last.dispatched, true); assert.equal(last.usage.output_tokens, 7);
  }

  // Only this phase advertises the new runtime contract. Keep every old
  // fixture default above, including extract's prohibition on tool output.
  const g = await fixture(t, { generic: true });
  const llm = g.agent.ctx.get('llm');
  const agentCapability = { v: 1, tools: 'return-only', streaming: true };
  llm.companionAuxiliaryCapability = () => ({ ...genericCapability, agent: agentCapability });
  const source = { kind: 'model', provider: 'selected-provider', model: 'selected-model' };
  const completedContent = [
    { type: 'reasoning', text: 'Private planning.' },
    { type: 'text', text: 'Planning. Complete details.' },
    { type: 'tool-call', id: 'phone-call', name: 'sample', arguments: '{"n":1}' },
  ];
  llm.prepareCompanionAuxiliaryCall = async (config, signal, observer) => {
    g.state.prepares++; g.state.config = config; g.state.signal = signal;
    observer.guard();
    let message;
    return { config, get agentMessage() { return message; }, stream: async function* (payload) {
      g.state.payload = payload;
      observer.guard(); signal.throwIfAborted();
      g.state.invocations++;
      observer.observe({ type: 'handoff', atMs: 1795280000123, boundary: 'adapter-invoked' });
      yield { type: 'reasoning-delta', index: 0, text: 'Private planning.' };
      yield { type: 'text-delta', index: 1, text: 'Planning.' };
      yield { type: 'block-end', index: 1, block: completedContent[1] };
      yield { type: 'block-start', index: 2, blockType: 'tool-call' };
      yield { type: 'tool-call-delta', index: 2, id: 'phone-call', name: 'sample', argumentsDelta: '{"n":' };
      yield { type: 'tool-call-delta', index: 2, id: 'phone-call', argumentsDelta: '1}' };
      yield { type: 'block-end', index: 2, block: completedContent[2] };
      yield { type: 'usage', usage: { inputTokens: 12, outputTokens: 4 } };
      yield { type: 'finish', reason: { kind: 'tool-calls' } };
      // Same completed neutral shape as the runtime getter; this adapter
      // double does not stand in for the pinned BlockAssembler/provider hook.
      message = { id: 'model-message', role: 'assistant', source, content: completedContent };
    } };
  };
  const info = await g.http();
  assert.deepEqual(info.body.agent, agentCapability);
  assert.equal(info.body.capability.noTools, true, 'the old auxiliary contract stays separate');
  const previous = [
    { type: 'thinking', thinking: 'Earlier private planning.' },
    { type: 'text', text: 'I will check.' },
    { type: 'tool_use', id: 'previous-call', name: 'sample', input: { n: 0 } },
  ];
  const tools = [{ name: 'sample', description: 'Executed by the phone.',
    input_schema: { type: 'object', properties: { n: { type: 'integer' } }, required: ['n'] } }];
  const { input, ...body } = g.body({ requestId: 'agent-round', kind: 'agent', maxTokens: 4000 });
  const response = await g.http({ method: 'POST', body: { ...body, messages: [
    { role: 'user', content: 'Check the next item.' },
    { role: 'assistant', source, content: previous },
    { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'previous-call', is_error: true,
      content: [{ type: 'text', text: 'Not applied.' }] }] },
  ], tools } });
  assert.equal(response.status, 200);
  assert.equal(g.state.prepares, 1); assert.equal(g.state.invocations, 1);
  assert.deepEqual(g.state.config, { provider: source.provider, model: source.model, maxTokens: 4000 });
  assert.equal(Object.hasOwn(g.state.payload, 'input'), false);
  assert.deepEqual(g.state.payload.tools, [{ name: 'sample', description: 'Executed by the phone.', parameters: tools[0].input_schema }]);
  assert.deepEqual(g.state.payload.messages.map(({ id, ...message }) => message), [
    { role: 'user', source: { kind: 'user' }, content: [{ type: 'text', text: 'Check the next item.' }] },
    { role: 'assistant', source, content: [
      { type: 'reasoning', text: 'Earlier private planning.' }, { type: 'text', text: 'I will check.' },
      { type: 'tool-call', id: 'previous-call', name: 'sample', arguments: '{"n":0}' },
    ] },
    { role: 'tool', source: { kind: 'tool', callId: 'previous-call' }, toolCallId: 'previous-call',
      content: [{ type: 'text', text: 'Not applied.' }], isError: true },
  ]);
  assert.deepEqual(response.body.map(event => event.type), ['accepted', 'text', 'runtime-usage', 'message', 'finish']);
  assert.equal(response.body.find(event => event.type === 'text').text, 'Planning.');
  assert.deepEqual(response.body.find(event => event.type === 'message').message, {
    content: [{ type: 'thinking', thinking: 'Private planning.' },
      { type: 'text', text: 'Planning. Complete details.' },
      { type: 'tool_use', id: 'phone-call', name: 'sample', input: { n: 1 } }],
    stopReason: 'tool_use', source,
  });
  const finished = response.body.at(-1);
  assert.equal(finished.terminal, 'tool-calls'); assert.equal(finished.complete, true);
  assert.equal(finished.dispatched, null); assert.equal(finished.usage.usage_semantics, 'unknown');
  assert.equal(finished.usage.output_tokens, null);
  assert.equal(finished.usage.runtime_normalized_usage[0].outputTokens, 4);
  // The real route returned calls without a Host executor or Session history
  // access. Actual phone execution/continuation is exercised in the Dart case.

  // Form feeds are data in Agent content and descriptions, including complete
  // text/reasoning output. They do not loosen the separate strict system rule.
  const ffContent = [
    { type: 'reasoning', text: 'Private before\fafter.' },
    { type: 'text', text: 'Visible before\fafter.' },
  ];
  llm.prepareCompanionAuxiliaryCall = async (config, signal, observer) => {
    g.state.prepares++; g.state.config = config; g.state.signal = signal;
    observer.guard();
    let message;
    return { config, get agentMessage() { return message; }, stream: async function* (payload) {
      g.state.payload = payload;
      observer.guard(); signal.throwIfAborted();
      g.state.invocations++;
      observer.observe({ type: 'handoff', atMs: 1795280000123, boundary: 'adapter-invoked' });
      yield { type: 'reasoning-delta', index: 0, text: ffContent[0].text };
      yield { type: 'text-delta', index: 1, text: ffContent[1].text };
      yield { type: 'usage', usage: { inputTokens: 8, outputTokens: 3 } };
      yield { type: 'finish', reason: { kind: 'stop' } };
      message = { id: 'form-feed-message', role: 'assistant', source, content: ffContent };
    } };
  };
  const ffMessages = [
    { role: 'user', content: 'History before\fafter.' },
    { role: 'assistant', source, content: [
      { type: 'thinking', thinking: 'Earlier private before\fafter.' },
      { type: 'text', text: 'Earlier answer before\fafter.' },
      { type: 'tool_use', id: 'ff-string-call', name: 'sample', input: { n: 2 } },
      { type: 'tool_use', id: 'ff-list-call', name: 'sample', input: { n: 3 } },
    ] },
    { role: 'user', content: [
      { type: 'tool_result', tool_use_id: 'ff-string-call', content: 'String result before\fafter.' },
      { type: 'tool_result', tool_use_id: 'ff-list-call', content: [{ type: 'text', text: 'List result before\fafter.' }] },
      { type: 'text', text: 'Current before\fafter.' },
    ] },
  ];
  const ffTools = [{ ...tools[0], description: 'Phone tool before\fafter.' }];
  const ffBefore = { prepares: g.state.prepares, invocations: g.state.invocations };
  const formFeed = await g.http({ method: 'POST', body: { ...body, requestId: 'agent-form-feed', messages: ffMessages, tools: ffTools } });
  assert.equal(formFeed.status, 200); assert.equal(g.state.prepares, ffBefore.prepares + 1);
  assert.equal(g.state.invocations, ffBefore.invocations + 1);
  assert.deepEqual(g.state.payload.tools, [{ name: 'sample', description: ffTools[0].description, parameters: tools[0].input_schema }]);
  assert.deepEqual(g.state.payload.messages.map(({ id, ...message }) => message), [
    { role: 'user', source: { kind: 'user' }, content: [{ type: 'text', text: 'History before\fafter.' }] },
    { role: 'assistant', source, content: [
      { type: 'reasoning', text: 'Earlier private before\fafter.' },
      { type: 'text', text: 'Earlier answer before\fafter.' },
      { type: 'tool-call', id: 'ff-string-call', name: 'sample', arguments: '{"n":2}' },
      { type: 'tool-call', id: 'ff-list-call', name: 'sample', arguments: '{"n":3}' },
    ] },
    { role: 'tool', source: { kind: 'tool', callId: 'ff-string-call' }, toolCallId: 'ff-string-call',
      content: [{ type: 'text', text: 'String result before\fafter.' }] },
    { role: 'tool', source: { kind: 'tool', callId: 'ff-list-call' }, toolCallId: 'ff-list-call',
      content: [{ type: 'text', text: 'List result before\fafter.' }] },
    { role: 'user', source: { kind: 'user' }, content: [{ type: 'text', text: 'Current before\fafter.' }] },
  ]);
  assert.equal(formFeed.body.find(event => event.type === 'text').text, ffContent[1].text);
  assert.deepEqual(formFeed.body.find(event => event.type === 'message').message, {
    content: [{ type: 'thinking', thinking: ffContent[0].text }, { type: 'text', text: ffContent[1].text }],
    stopReason: 'end_turn', source,
  });
  const ffFinished = formFeed.body.at(-1);
  assert.equal(ffFinished.terminal, 'complete'); assert.equal(ffFinished.complete, true);
  assert.equal(ffFinished.dispatched, null); assert.equal(ffFinished.usage.usage_semantics, 'unknown');
  assert.equal(ffFinished.usage.runtime_normalized_usage[0].outputTokens, 3);

  const invalidSystem = await g.http({ method: 'POST', body: { ...body, requestId: 'agent-system-form-feed',
    system: 'Strict instructions\fwith a page break.', messages: ffMessages, tools: ffTools } });
  assert.equal(invalidSystem.status, 400); assert.equal(invalidSystem.body.dispatched, false);
  assert.equal(invalidSystem.body.error.code, 'companion/auxiliary-invalid-request');
  const invalidControl = await g.http({ method: 'POST', body: { ...body, requestId: 'agent-forbidden-control',
    messages: [{ role: 'user', content: 'Still forbidden\u000bcontrol.' }], tools: ffTools } });
  assert.equal(invalidControl.status, 400); assert.equal(invalidControl.body.dispatched, false);
  assert.equal(invalidControl.body.error.code, 'companion/auxiliary-invalid-request');
  assert.equal(g.state.prepares, ffBefore.prepares + 1); assert.equal(g.state.invocations, ffBefore.invocations + 1);

});

// The adapter above is explicit: this proves route behavior and exact payload,
// not the pinned engine's provider hook or generated language quality.
test('followup uses one selected auxiliary call with exact supplied material and bounded output', async t => {
  const output = JSON.stringify({ action: 'line', text: '周四的面试，今天想聊聊吗？' });
  const f = await fixture(t, { output });
  const system = 'Synthetic one-line followup instruction. The phone owns eligibility.';
  const input = JSON.stringify({
    persona: { name: '小棠', style: '简短温和' },
    card: { text: '你打算周四去面试。' },
    invitation: { message_id: 'source', source_rev: 1, said_at_utc: '2026-11-18T02:00:00Z',
      offset_minutes: 480, quote: '周四打算去面试。周五你可以问问我。' },
    support: [], now_utc: '2026-11-20T02:00:00Z', offset_minutes: 480,
  });
  const response = await f.post({ kind: 'followup', system, input, maxTokens: 128 });
  assert.equal(response.status, 200);
  assert.deepEqual(f.state.payload, { system, input });
  assert.deepEqual(f.state.config, { provider: 'selected-provider', model: 'selected-model',
    reasoningEffort: 'off', maxTokens: 128 });
  assert.equal(response.body.filter(event => event.type === 'text').map(event => event.text).join(''), output);
  assert.equal(response.body.at(-1).complete, true);
  assert.equal(response.body.at(-1).dispatched, true);
  assert.equal(response.body.at(-1).usage.output_tokens, 7);
  assert.equal(f.state.invocations, 1);
  const repeat = await f.post({ kind: 'followup', system, input, maxTokens: 128 });
  assert.equal(repeat.status, 409);
  assert.equal(f.state.invocations, 1);
  const receipt = await f.http({ path: `${PATH}/requests/request?instanceId=${f.info.body.instanceId}` });
  assert.equal(receipt.body.finish.complete, true);
  assert(!JSON.stringify(receipt.body).includes('周四'));
});

test('full receipt FIFO stays available past 4096 accepted attempts without admitting an evicted ID again', async t => {
  const f = await fixture(t, { prepareError: Object.assign(new Error('synthetic credential unavailable'), { code: 'MISSING_CREDENTIAL' }) });
  const status = id => f.http({ path: `${PATH}/requests/${id}?instanceId=${f.info.body.instanceId}` });
  // Use the real limit and HTTP acceptance path, including finished preflight
  // failures. No private cache mutation or smaller production limit is used.
  for (let i = 0; i < 4096; i++) {
    const response = await f.post({ requestId: `cached-${i}` });
    assert.equal(response.status, 200);
    assert.equal(response.body[0].type, 'accepted');
    assert.equal(response.body.at(-1).terminal, 'preflight_error');
    assert.equal(response.body.at(-1).dispatched, false);
  }
  assert.equal(f.state.prepares, 4096); assert.equal(f.state.invocations, 0);
  assert.equal((await status('cached-0')).status, 200);
  const retained = await status('cached-4095');
  assert.equal(retained.status, 200); assert.equal(retained.body.phase, 'finished');

  const prepareGate = defer();
  f.state.prepareError = undefined; f.state.prepareGate = prepareGate;
  const pending = f.post({ requestId: 'after-capacity' });
  let response;
  try {
    await until(() => f.state.prepares === 4097);
    const active = await status('after-capacity');
    assert.equal(active.status, 200); assert.equal(active.body.phase, 'accepted');
    assert.equal(active.body.dispatched, null); assert.equal(Object.hasOwn(active.body, 'finish'), false);
    const missing = await status('cached-0');
    assert.equal(missing.status, 404); assert.equal(missing.body.error.code, 'companion/auxiliary-request-unknown');
    assert.equal(missing.body.dispatched, null);
    // Reading the next oldest detail does not promote it out of FIFO order.
    assert.equal((await status('cached-1')).status, 200);
    assert.deepEqual((await status('cached-4095')).body, retained.body);

    const resolves = f.state.resolves;
    for (const [extra, code] of [[{}, 'request-used'], [{ input: 'changed body' }, 'request-conflict']]) {
      const replay = await f.post({ requestId: 'cached-0', ...extra });
      assert.equal(replay.status, 409); assert.equal(replay.body.error.code, `companion/auxiliary-${code}`);
      assert.equal(replay.body.dispatched, null); assert.equal(Object.hasOwn(replay.body, 'receipt'), false);
    }
    const busy = await f.post({ requestId: 'waiting-for-slot' });
    assert.equal(busy.status, 409); assert.equal(busy.body.error.code, 'companion/auxiliary-busy');
    assert.equal(busy.body.dispatched, false);
    assert.equal(f.state.resolves, resolves); assert.equal(f.state.prepares, 4097); assert.equal(f.state.invocations, 0);
    assert.deepEqual((await status('after-capacity')).body, active.body);
  } finally {
    prepareGate.resolve();
    response = await pending;
  }
  assert.equal(response.status, 200); assert.equal(response.body.at(-1).terminal, 'complete');
  assert.equal(response.body.at(-1).dispatched, true); assert.equal(f.state.invocations, 1);
  const finished = await status('after-capacity');
  assert.equal(finished.body.phase, 'finished'); assert.deepEqual(finished.body.finish, response.body.at(-1));

  const next = await f.post({ requestId: 'waiting-for-slot' });
  assert.equal(next.status, 200); assert.equal(next.body.at(-1).terminal, 'complete');
  assert.equal(f.state.invocations, 2, 'busy did not consume the new ID');
  const secondEvicted = await status('cached-1');
  assert.equal(secondEvicted.status, 404); assert.equal(secondEvicted.body.dispatched, null);
  assert.deepEqual((await status('cached-4095')).body, retained.body);
  assert.deepEqual((await status('after-capacity')).body, finished.body);
});

test('Agent retirement keeps instance-wide used IDs and a new route rejects the old generation', async t => {
  const f = await fixture(t);
  const original = f.body();
  const response = await f.http({ method: 'POST', body: original });
  assert.equal(response.status, 200); assert.equal(f.state.invocations, 1);
  const receiptPath = `${PATH}/requests/request?instanceId=${f.info.body.instanceId}`;
  const saved = await f.http({ path: receiptPath });
  f.state.retired = true;
  f.listeners.get('agent/disposed')({ agent: f.agent });
  assert.deepEqual((await f.http({ path: receiptPath })).body, saved.body);
  const resolves = f.state.resolves;
  const same = await f.http({ method: 'POST', body: original });
  assert.equal(same.status, 409); assert.equal(same.body.error.code, 'companion/auxiliary-request-used');
  assert.equal(same.body.dispatched, null); assert.deepEqual(same.body.receipt, saved.body);
  const changedSession = await f.post({ sessionId: 'another-session' });
  assert.equal(changedSession.status, 409); assert.equal(changedSession.body.error.code, 'companion/auxiliary-request-conflict');
  assert.equal(changedSession.body.dispatched, null);
  assert.equal(f.state.resolves, resolves); assert.equal(f.state.prepares, 1); assert.equal(f.state.invocations, 1);
  // This is the existing controlled context, not an engine cold-resume claim.
  f.state.retired = false;
  assert.equal((await f.http()).body.instanceId, f.info.body.instanceId);
  assert.equal((await f.post({ requestId: 'fresh-in-instance' })).body.at(-1).terminal, 'complete');
  assert.equal(f.state.invocations, 2);

  f.route.dispose();
  const reopened = await fixture(t);
  assert.notEqual(reopened.info.body.instanceId, f.info.body.instanceId);
  const reopenedResolves = reopened.state.resolves;
  const old = await reopened.http({ method: 'POST', body: original });
  assert.equal(old.status, 409); assert.equal(old.body.error.code, 'companion/auxiliary-instance-changed');
  assert.equal(old.body.dispatched, null);
  assert.equal(reopened.state.resolves, reopenedResolves); assert.equal(reopened.state.prepares, 0);
  assert.equal(reopened.state.invocations, 0);
  const fresh = await reopened.post({ requestId: 'new-generation-request' });
  assert.equal(fresh.status, 200); assert.equal(fresh.body.at(-1).terminal, 'complete');
  assert.equal(reopened.state.invocations, 1);
});
