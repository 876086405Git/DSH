import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { getEventListeners } from 'node:events';
import { Context } from '@deepseek-ai/cordis';
import { SystemPrompt } from '@deepseek-ai/dsh-system-prompt';
import { ToolRuntime } from '@deepseek-ai/dsh-tools';
import { NativeToolExecutor } from '@deepseek-ai/dsh-tool-executor-native';
import { ApprovalService } from '@deepseek-ai/dsh-user-approval';
import { Session } from '@deepseek-ai/dsh-session';
import { SessionProjectionRegistry } from '@deepseek-ai/dsh-session-projection';
import { PhoneQueue, PHONE_PENDING_LIMIT } from '../../ohos/phone/queue.mjs';
import { registerPhoneTools } from '../../ohos/phone/tools.mjs';
import { phoneCatalog } from '../../ohos/phone/catalog.mjs';

const proof = 'a'.repeat(64);
const ok = (effect = 'opened_ui', evidence = effect) => ({ status: 'succeeded', effect, evidence,
  dispatched: true, code: 'ok', message: '系统已接受本次动作。' });

// This is an explicit native-seam unit fixture, not a target-device or real-DSO claim.
function fixture(t) {
  const state = { available: true, engineId: 'unit-engine', bridgeGeneration: 1, foreground: true,
    nowMs: 1000, ownerHash: createHash('sha256').update(proof).digest('hex') };
  const auth = { engineId: state.engineId, bridgeGeneration: 1, owner: proof };
  let permit = null, claims = 0, revokes = 0;
  const native = {
    snapshot: () => ({ ...state }),
    claim(request) {
      if (permit || !state.foreground || request.deadlineMs <= state.nowMs) return false;
      claims++; permit = { ...request, started: false, finished: false, revoked: false }; return true;
    },
    consume(lease) {
      if (!permit || permit.revoked || !state.foreground || state.nowMs >= permit.deadlineMs ||
          permit.executionNonce !== lease.executionNonce || permit.bridgeGeneration !== state.bridgeGeneration) return false;
      permit.started = true; return true;
    },
    finish() { if (permit.revoked) permit = null; else permit.finished = true; },
    revoke(request) {
      revokes++;
      if (!permit || permit.requestId !== request.requestId) return null;
      const started = permit.started; permit.revoked = true;
      if (!started || permit.finished) permit = null;
      return started;
    },
    complete(request) {
      if (!permit || permit.requestId !== request.requestId || permit.executionNonce !== request.executionNonce ||
          request.result.dispatched !== permit.started || (permit.started && !permit.finished)) return false;
      permit = null; return true;
    },
  };
  const queue = new PhoneQueue(native);
  t.after(() => queue.close());
  let calls = 0;
  const enqueue = (tool = 'mcp__phone__open', args = { url: 'https://example.test' }) => {
    const abort = new AbortController();
    const promise = queue.enqueue({ sessionId: 'session', callId: `call-${++calls}`, tool, args, signal: abort.signal });
    return { abort, promise };
  };
  const claim = () => queue.claim(auth, queue.next(auth).requestId);
  return { state, auth, native, queue, enqueue, claim, counts: () => ({ claims, revokes }) };
}

test('cookie-equivalent knowledge without native owner proof cannot read or claim a task', async t => {
  const f = fixture(t), pending = f.enqueue();
  for (const auth of [{ ...f.auth, owner: 'b'.repeat(64) }, { ...f.auth, bridgeGeneration: 2 },
    { ...f.auth, engineId: 'other-engine' }, { ...f.auth, owner: undefined }]) {
    assert.throws(() => f.queue.next(auth), { code: 'wrong_owner' });
  }
  assert.equal(f.counts().claims, 0); pending.abort.abort();
  assert.equal((await pending.promise).dispatched, false);
});

test('claim is single-use and cancellation revokes native permission before promise settlement', async t => {
  const f = fixture(t), pending = f.enqueue(), lease = f.claim();
  assert.throws(() => f.queue.claim(f.auth, lease.request.requestId), { code: 'not_pending' });
  pending.abort.abort();
  assert.equal(f.counts().revokes, 1);
  assert.equal(f.native.consume(lease), false, 'late Dart/Ark invocation must not gain permission');
  const result = await pending.promise;
  assert.equal(result.status, 'cancelled'); assert.equal(result.dispatched, false);
  assert.equal(getEventListeners(pending.abort.signal, 'abort').length, 0);
  assert.equal(f.queue.status().timer, false);
});

test('cancellation after native dispatch is unknown and never requeues the side effect', async t => {
  const f = fixture(t), pending = f.enqueue(), lease = f.claim();
  assert(f.native.consume(lease)); pending.abort.abort();
  const result = await pending.promise;
  assert.equal(result.status, 'unknown'); assert.equal(result.dispatched, true);
  assert.equal(f.queue.next(f.auth), null); assert.equal(f.counts().claims, 1);
  f.native.finish();
  assert.equal(f.queue.result(f.auth, lease.request.requestId, lease.executionNonce, ok()).accepted, false);
});

test('open may background DSH after dispatch while a confirmed native result remains opened_ui', async t => {
  const f = fixture(t), pending = f.enqueue(), lease = f.claim();
  assert(f.native.consume(lease)); f.state.foreground = false; f.native.finish();
  f.queue.result(f.auth, lease.request.requestId, lease.executionNonce, ok());
  assert.deepEqual(await pending.promise, ok());
});

test('queued operations fail immediately on background and are not held until a later foreground', async t => {
  const f = fixture(t), pending = f.enqueue(); f.state.foreground = false;
  assert.throws(() => f.queue.next(f.auth), { code: 'not_foreground' });
  assert.equal((await pending.promise).code, 'not_foreground');
  assert.throws(() => f.enqueue(), { code: 'not_foreground' });
  f.state.foreground = true; assert.equal(f.queue.next(f.auth), null);
});

test('success cannot be accepted before actual native completion or for a different effect', async t => {
  const f = fixture(t), pending = f.enqueue(), lease = f.claim();
  assert.throws(() => f.queue.result(f.auth, lease.request.requestId, lease.executionNonce, ok()), { code: 'not_completed' });
  assert(f.native.consume(lease));
  assert.throws(() => f.queue.result(f.auth, lease.request.requestId, lease.executionNonce, ok()), { code: 'not_completed' });
  f.native.finish();
  assert.throws(() => f.queue.result(f.auth, lease.request.requestId, lease.executionNonce, ok('clipboard_written', 'unknown')), { code: 'bad_result' });
  f.queue.result(f.auth, lease.request.requestId, lease.executionNonce, ok()); await pending.promise;
});

test('identical final result retry is idempotent; a conflicting result is rejected', async t => {
  const f = fixture(t), pending = f.enqueue(), lease = f.claim();
  f.native.consume(lease); f.native.finish();
  const first = f.queue.result(f.auth, lease.request.requestId, lease.executionNonce, ok());
  assert.deepEqual(f.queue.result(f.auth, lease.request.requestId, lease.executionNonce, ok()), first);
  assert.throws(() => f.queue.result(f.auth, lease.request.requestId, lease.executionNonce, { ...ok(), message: 'different' }), { code: 'conflicting_result' });
  await pending.promise; assert.equal(f.counts().claims, 1);
});

test('handoff waits across background, but requires foreground and the current nonce to continue', async t => {
  const f = fixture(t), pending = f.enqueue('mcp__phone__handoff', { reason: '请完成验证' }), lease = f.claim();
  f.native.consume(lease); f.queue.waiting(f.auth, lease.request.requestId, lease.executionNonce);
  f.state.foreground = false;
  assert.throws(() => f.queue.result(f.auth, lease.request.requestId, lease.executionNonce, ok('none', 'user_confirmed')), { code: 'not_foreground' });
  f.state.foreground = true;
  assert.throws(() => f.queue.result(f.auth, lease.request.requestId, 'old-button', ok('none', 'user_confirmed')), { code: 'stale' });
  f.native.finish(); f.queue.result(f.auth, lease.request.requestId, lease.executionNonce, ok('none', 'user_confirmed'));
  assert.equal((await pending.promise).evidence, 'user_confirmed');
});

test('600 seconds includes suspended time and a late handoff button cannot restore success', async t => {
  const f = fixture(t), pending = f.enqueue('mcp__phone__handoff', { reason: '等待' }), lease = f.claim();
  f.native.consume(lease); f.queue.waiting(f.auth, lease.request.requestId, lease.executionNonce);
  f.state.nowMs += 600_000; assert.equal(f.queue.next(f.auth), null);
  assert.equal((await pending.promise).status, 'timed_out'); f.native.finish();
  assert.equal(f.queue.result(f.auth, lease.request.requestId, lease.executionNonce, ok('none', 'user_confirmed')).accepted, false);
});

test('owner rotation retires queued and already-dispatched requests without replay', async t => {
  const f = fixture(t), pending = f.enqueue(), lease = f.claim(); f.native.consume(lease);
  f.state.bridgeGeneration = 2;
  assert.equal(f.queue.next({ ...f.auth, bridgeGeneration: 2 }), null);
  assert.equal((await pending.promise).status, 'unknown'); f.native.finish();
  assert.throws(() => f.queue.result(f.auth, lease.request.requestId, lease.executionNonce, ok()), { code: 'wrong_owner' });
});

test('clock failure settles all promises and leaves no timer or abort listener', async t => {
  const f = fixture(t), pending = [f.enqueue(), f.enqueue()];
  f.state.nowMs = -1;
  assert.throws(() => f.queue.next(f.auth), { code: 'native_unavailable' });
  for (const row of pending) {
    assert.equal((await row.promise).code, 'native_unavailable');
    assert.equal(getEventListeners(row.abort.signal, 'abort').length, 0);
  }
  assert.equal(f.queue.status().timer, false);
});

test('bounded pending admission and close settle every owned promise', async t => {
  const f = fixture(t), pending = Array.from({ length: PHONE_PENDING_LIMIT }, () => f.enqueue());
  assert.throws(() => f.enqueue(), { code: 'busy' }); f.queue.close();
  assert.deepEqual(f.queue.status(), { pending: 0, recent: 0, listeners: 0, timer: false });
  for (const row of pending) assert.equal((await row.promise).status, 'cancelled');
});

test('a throwing subscriber cannot orphan enqueue or interrupt closing the remaining requests', async t => {
  const f = fixture(t);
  f.queue.subscribe(() => { throw new Error('subscriber failure'); });
  const pending = [f.enqueue(), f.enqueue()];
  assert.doesNotThrow(() => f.queue.close());
  for (const row of pending) assert.equal((await row.promise).status, 'cancelled');
  assert.deepEqual(f.queue.status(), { pending: 0, recent: 0, listeners: 0, timer: false });
});

async function registryFixture(t) {
  const f = fixture(t), ctx = new Context();
  await ctx.plugin(SystemPrompt, {}); await ctx.plugin(ToolRuntime, {}); ctx.tools.setExecutor(new NativeToolExecutor(ctx));
  const dispose = registerPhoneTools(ctx, f.queue), agent = { id: 'actual-registry-session', ctx };
  t.after(async () => { dispose(); await ctx.fiber.dispose(); });
  let calls = 0;
  return { ...f, ctx, run: async (name, args, signal = new AbortController().signal) => (await ctx.tools.execute({
    calls: [{ id: `actual-call-${++calls}`, name: `mcp__phone__${name}`, arguments: JSON.stringify(args) }], agent, signal,
  })).results[0].result };
}

test('the real ToolRuntime rejects bad schemas and unsupported actions with isError=true', async t => {
  const f = await registryFixture(t);
  assert.deepEqual(phoneCatalog.map(x => x.name), ['open', 'intent', 'notify', 'clipboard', 'handoff'].map(x => 'mcp__phone__' + x));
  for (const [name, args, code] of [
    ['open', { url: 'https://example.test', extra: true }, 'INVALID_ARGS'],
    ['intent', { kind: 'dial', hour: 1.5 }, 'INVALID_ARGS'],
    ['open', { app: '', url: '' }, 'OHOS_PHONE_INVALID_ARGS'],
    ['open', { app: 'example.app', background: true }, 'OHOS_PHONE_UNSUPPORTED'],
    ['clipboard', { get: true }, 'OHOS_PHONE_UNSUPPORTED'],
    ['clipboard', { set: '', get: true }, 'OHOS_PHONE_INVALID_ARGS'],
    ['notify', { title: ' ', text: 'hello' }, 'OHOS_PHONE_INVALID_ARGS'],
    ['handoff', { reason: '  ' }, 'OHOS_PHONE_INVALID_ARGS'],
  ]) {
    const result = await f.run(name, args);
    assert.equal(result.isError, true, JSON.stringify(result)); assert.equal(result.error.info.code, code);
  }
  assert.equal(f.counts().claims, 0);
});

// The engine's own ApprovalService and session log; only the answerer is a stand-in.
async function approvalFixture(t, policy, { auto = false } = {}) {
  const f = fixture(t), ctx = new Context();
  await ctx.plugin(SystemPrompt, {}); await ctx.plugin(ToolRuntime, {}); ctx.tools.setExecutor(new NativeToolExecutor(ctx));
  await ctx.plugin(SessionProjectionRegistry);
  await ctx.plugin(ApprovalService, { policy });
  await ctx.inject(['approval'], () => {});
  if (auto) ctx.provide('permissionPresets', { current: () => 'auto' });
  const asks = [];
  const session = Session.create('approval-session', undefined, { version: 4, id: 'approval-session', createdAt: Date.now(), isSeeded: false, cwd: process.cwd() });
  session.append('turn/start', { turn: 1 });
  let answer = 'allowed-once';
  ctx.on('approval/request', async request => { asks.push(request); return answer; });
  const dispose = registerPhoneTools(ctx, f.queue), agent = { id: 'approval-session', ctx, session };
  t.after(async () => { dispose(); await ctx.fiber.dispose(); });
  let calls = 0;
  return { ...f, asks, answer: value => { answer = value; }, run: async (name, args) => (await ctx.tools.execute({
    calls: [{ id: `approval-call-${++calls}`, name: `mcp__phone__${name}`, arguments: JSON.stringify(args) }],
    agent, signal: new AbortController().signal })).results[0].result };
}

test('a phone call asks through the engine approval first and a refusal never reaches the queue', async t => {
  const f = await approvalFixture(t, 'ask');
  f.answer('rejected');
  const refused = await f.run('intent', { kind: 'dial', number: '10086' });
  assert.equal(refused.isError, true);
  assert.equal(f.asks.length, 1); assert.equal(f.asks[0].toolName, 'mcp__phone__intent');
  assert.match(f.asks[0].displayReason.zh, /10086/);
  assert.equal(f.queue.status().pending, 0); assert.equal(f.counts().claims, 0);
});

test('a call that cannot run now fails plainly, for the true reason, instead of asking first', async t => {
  const f = await approvalFixture(t, 'ask');
  for (const [change, code] of [[{ available: false, foreground: true }, 'native_unavailable'],
    [{ available: true, foreground: false }, 'not_foreground'], [{ available: false, foreground: false }, 'not_foreground']]) {
    Object.assign(f.state, change);
    const result = await f.run('open', { url: 'https://example.test' });
    assert.equal(result.isError, true); assert.equal(f.asks.length, 0);
    const phone = JSON.parse(result.error.message);
    assert.equal(phone.dispatched, false); assert.equal(phone.code, code);
  }
});

test('an allowed phone call goes on to the queue; handoff is not asked about twice', async t => {
  const f = await approvalFixture(t, 'ask'), call = await executing(f, 'open', { url: 'https://example.test' });
  assert.equal(f.asks.length, 1); assert.equal(call.lease.request.tool, 'mcp__phone__open');
  f.native.consume(call.lease); f.native.finish();
  f.queue.result(f.auth, call.lease.request.requestId, call.lease.executionNonce, ok());
  assert.equal((await call.result).isError, false);
  const handoff = await executing(f, 'handoff', { reason: '请登录' });
  assert.equal(f.asks.length, 1, 'handoff waits for continue or stop instead');
  await f.queue.cancel(f.auth, handoff.lease.request.requestId); await handoff.result;
});

for (const [name, policy, options] of [['full access', 'never', {}], ['Auto review', 'ask', { auto: true }]]) {
  test(`${name} decides by itself: the phone call does not add a prompt`, async t => {
    const f = await approvalFixture(t, policy, options), call = await executing(f, 'open', { url: 'https://example.test' });
    assert.equal(f.asks.length, 0);
    f.native.consume(call.lease); f.native.finish();
    f.queue.result(f.auth, call.lease.request.requestId, call.lease.executionNonce, ok());
    assert.equal((await call.result).isError, false);
  });
}

test('a registration conflict rolls back only this phone plugin contribution', async t => {
  const f = fixture(t), ctx = new Context();
  await ctx.plugin(SystemPrompt, {}); await ctx.plugin(ToolRuntime, {}); ctx.tools.setExecutor(new NativeToolExecutor(ctx));
  const original = { name: 'mcp__phone__notify', description: 'existing', parameters: { type: 'object' },
    output: { schema: { type: 'string' }, render: () => [] }, execute: async () => 'existing' };
  ctx.tools.register(original); t.after(() => ctx.fiber.dispose());
  assert.throws(() => registerPhoneTools(ctx, f.queue), /already registered/);
  assert.equal(ctx.tools.get('mcp__phone__open'), undefined);
  assert.equal(ctx.tools.get('mcp__phone__intent'), undefined);
  assert.equal(ctx.tools.get('mcp__phone__notify').description, 'existing');
});

async function executing(f, name, args, signal) {
  const ready = Promise.withResolvers(), off = f.queue.subscribe(() => { if (f.queue.status().pending) ready.resolve(); });
  const result = f.run(name, args, signal);
  await Promise.race([ready.promise, result.then(value => { throw new Error(`Tool ended before enqueue: ${JSON.stringify(value)}`); })]);
  off(); return { result, lease: f.claim() };
}

test('real ToolRuntime preserves empty clipboard writes and does not claim user confirmation', async t => {
  const f = await registryFixture(t), call = await executing(f, 'clipboard', { set: '' });
  assert.equal(call.lease.request.args.set, ''); f.native.consume(call.lease); f.native.finish();
  f.queue.result(f.auth, call.lease.request.requestId, call.lease.executionNonce, ok('clipboard_written', 'unknown'));
  const result = await call.result;
  assert.equal(result.isError, false); assert.equal(result.value.evidence, 'unknown');
  assert.equal(result.value.effect, 'clipboard_written');
});

test('real ToolRuntime records uncertain cancellation as an error with its effect evidence intact', async t => {
  const f = await registryFixture(t), abort = new AbortController();
  const call = await executing(f, 'open', { app: ' ', url: 'https://example.test' }, abort.signal);
  f.native.consume(call.lease); abort.abort();
  const result = await call.result;
  assert.equal(result.isError, true); assert.equal(result.error.info.code, 'OHOS_PHONE_CANCELLED');
  assert.equal(JSON.parse(result.error.message).status, 'unknown'); f.native.finish();
});

// System reminder acceptance is distinct from presenting an Activity/UI.
test('public queue accepts reminder_scheduled only for dispatched alarm and timer',async t=>{
 for(const kind of ['alarm','timer']){
  const f=fixture(t),p=f.enqueue('mcp__phone__intent',{kind}),lease=f.claim();assert(f.native.consume(lease));f.native.finish();
  const receipt=ok('reminder_scheduled','unknown');assert.equal(f.queue.result(f.auth,lease.request.requestId,lease.executionNonce,receipt).accepted,true);
  assert.deepEqual(await p.promise,receipt);assert.equal(f.counts().claims,1);
 }
});
test('public queue rejects reminder evidence on other requests or before dispatch',async t=>{
 for(const [tool,args,override] of [['mcp__phone__open',{url:'https://example.test'},{}],['mcp__phone__intent',{kind:'calendar'},{}],['mcp__phone__intent',{kind:'alarm'},{evidence:'opened_ui'}],['mcp__phone__intent',{kind:'timer'},{dispatched:false}]]){
  const f=fixture(t),p=f.enqueue(tool,args),lease=f.claim();assert(f.native.consume(lease));f.native.finish();
  assert.throws(()=>f.queue.result(f.auth,lease.request.requestId,lease.executionNonce,{...ok('reminder_scheduled','unknown'),...override}),{code:'bad_result'});
  p.abort.abort();await p.promise;
 }
});
