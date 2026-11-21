// Controlled source tests. Real patched driver / approval / gateway methods;
// Cordis ownership, durable store and Remote delivery adapters are explicit peers.
// No engine boot, mobile UI, real user files or permission grant is implied.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { join } from 'node:path';
import test from 'node:test';

const root = process.env.COMPANION_TASK_SOURCE_ROOT
  ?? (process.env.DSH_PREFIX && join(process.env.DSH_PREFIX, 'node_modules/@deepseek-ai'));
if (!root) throw new Error('Set COMPANION_TASK_SOURCE_ROOT or DSH_PREFIX; this test must not silently skip');
const pins = JSON.parse(await readFile(new URL('../patches/pins.json', import.meta.url), 'utf8'));
const target = process.env.COMPANION_TASK_TARGET ?? 'android';
assert.ok(['android', 'ohos'].includes(target), 'explicit supported source target');
function finalHash(name, fallback) {
  let expected = fallback;
  for (const patch of pins.targetSets[target]) {
    expected = pins.patches[patch]['0.2.2-rc.1']?.[`node_modules/@deepseek-ai/${name}/lib/index.js`]?.after ?? expected;
  }
  assert.ok(expected, `known source identity for ${name}`);
  return expected;
}
const code = {};
for (const name of ['dsh-agent-loop', 'dsh-user-approval', 'dsh-api-gateway']) {
  code[name] = await readFile(join(root, name, 'lib/index.js'), 'utf8');
  assert.equal(createHash('sha256').update(code[name]).digest('hex'),
    finalHash(name));
}
const protocol = await readFile(join(root, 'dsh-typert-protocol/lib/index.js'), 'utf8');
assert.equal(createHash('sha256').update(protocol).digest('hex'), finalHash('dsh-typert-protocol', '8d48ddbb4bbc62585ce5a4d3a7f53b39f55581b5320c1cae681766edd15ff8af'));
const remotes = await readFile(join(root, 'dsh-api-remotes/lib/index.js'), 'utf8');
assert.equal(createHash('sha256').update(remotes).digest('hex'), finalHash('dsh-api-remotes', '719d9ad01bb3066ab84ecd824f30d630871ed0edcf1ff32df4d6931a553fc3f5'));
const sessionCode = await readFile(join(root, 'dsh-session/lib/index.js'), 'utf8');
assert.equal(createHash('sha256').update(sessionCode).digest('hex'), finalHash('dsh-session'));
const sandboxCode = await readFile(join(root, 'dsh-sandbox/lib/index.js'), 'utf8');
assert.equal(createHash('sha256').update(sandboxCode).digest('hex'), finalHash('dsh-sandbox'));
function region(source, name) {
  const start = source.indexOf(`//#region lib/types/${name}.js`);
  const end = source.indexOf('//#endregion', start);
  assert(start >= 0 && end > start, `real source region ${name}`);
  return source.slice(start, end);
}
const schema = new Proxy(() => schema, { get: () => schema });
class Service { static init = Symbol('service-init'); constructor(ctx) { this.ctx = ctx; } }
const globals = {
  Service, z: schema, z$1: schema, randomUUID, MAX_TIMER_DELAY_MS: 2147483647,
  RemoteError: Error, scopeTarget: agent => agent,
  dshGoRecall: { guardSession() {} }, errorChain: e => String(e.message ?? e),
  SessionSeq: value => value,
  assertNever: value => { throw new Error(`unexpected ${value}`); },
};
const api = Function(...Object.keys(globals), [
  region(protocol, 'json-value'),
  region(sessionCode, 'repair'),
  region(sandboxCode, 'locales'), region(sandboxCode, 'escalation'),
  remotes.slice(remotes.indexOf('function forwardWaterfall('), remotes.indexOf('/** Reject an allowlisted event')),
  region(code['dsh-agent-loop'], 'agent'),
  region(code['dsh-user-approval'], 'types'), region(code['dsh-user-approval'], 'index'),
  region(code['dsh-api-gateway'], 'stream-protocol'), region(code['dsh-api-gateway'], 'index'),
  'return { ReactLoopAgent, ApprovalService, approvalStateDefinition, TypertGatewayService, projectRemoteEventRequest, forwardWaterfall, interruptedTurnClosers, approveEscalation, validateEscalationArgs };',
].join('\n'))(...Object.values(globals));
const tick = () => new Promise(resolve => setImmediate(resolve));

function fixture({ policy = 'ask', flush = async () => true } = {}) {
  const events = [], frames = [], status = [], durable = [];
  let projection = api.approvalStateDefinition.init();
  const session = { id: 'notes-room', append(type, data) {
    const event = { seq: events.length + 1, type, data: structuredClone(data) };
    events.push(event); projection = api.approvalStateDefinition.apply(projection, event);
  } };
  const ctx = {
    get: name => name === 'approval' ? approval : undefined,
    sessions: { async flush(s) {
      assert.equal(s, session); const result = await flush(events);
      if (result) durable.splice(0, durable.length, ...structuredClone(events));
      return result;
    } },
    agents: { withInitiator(agent, fn) { assert.equal(agent, driver); return fn(); } },
    waterfall(_scope, type, req) {
      assert.equal(type, 'approval/request');
      return api.forwardWaterfall({ push(source) { gateway.startRemoteEvent(source); return true; } }, type, req,
        { agentId: driver.id, subject: driver, value: { effect() { return () => {}; } } },
        () => Promise.resolve('unavailable'));
    },
  };
  const approval = new api.ApprovalService(ctx, { policy });
  approval.approvalProjectionHandle = { stateOf: () => projection };
  const gateway = Object.assign(Object.create(api.TypertGatewayService.prototype), {
    ctx, pendingRemoteEvents: new Map(), remoteEventClients: new Map(),
  });
  function client(id = randomUUID()) {
    const value = { id, answers: true, deliveries: new Map(), queue: { push: frame => frames.push({ id, frame }) } };
    gateway.remoteEventClients.set(id, value);
    // Actual subscribeRemoteEvents uses this same retained-pending delivery path.
    for (const pending of gateway.pendingRemoteEvents.values()) gateway.deliverRemoteEvent(pending, value);
    return value;
  }
  const owner = client('owner');
  const inbox = { hasPending: false, clear() { this.hasPending = false; }, recover() {} };
  const driver = Object.assign(Object.create(api.ReactLoopAgent.prototype), {
    id: session.id, session, loopCtx: ctx, phase: { kind: 'idle', lastTurn: 7 },
    activityDone: Promise.resolve(), inbox,
    dispatch: { emit: (name, data) => status.push({ name, ...data }) },
  });
  const approved = async (signal, observers = {}) => {
    const binding = await approval.dshGoRequestTask({ agent: driver, toolName: 'companion.notes-to-todos.publish', reason: '固定笔记步骤', signal }, {
      asked: observers.asked ?? (async () => { assert.equal(await ctx.sessions.flush(session), true); }),
      remote: observers.remote ?? (async () => {}),
    });
    assert.equal(await ctx.sessions.flush(session), true);
    signal.throwIfAborted();
    return binding;
  };
  function answer(eventId, outcome = 'allowed-once', who = owner) {
    gateway.receiveRemoteEventResult(who, { eventId, outcome: { kind: 'result', value: outcome } });
  }
  return { ctx, driver, approval, gateway, session, events, durable, frames, status, owner, client, approved, answer };
}

test('fixed notes step owns a real turn; approval audit id differs from the exact wire id', async () => {
  const f = fixture(); const identity = { taskId: 'notes-1', taskRev: 2, step: 'publish', callId: null };
  let mapped, effects = 0;
  const running = f.driver.dshGoRunTaskTurn(async signal => {
    const grant = await f.approved(signal, { remote: async value => { mapped = { ...identity, ...value }; } });
    if (grant.outcome === 'allowed-once') effects++;
    return grant;
  });
  assert.equal(f.driver.status, 'running');
  await tick();
  const frame = f.frames.find(x => x.frame.type === 'waterfall').frame;
  assert.equal(mapped.eventId, frame.eventId);
  assert.notEqual(mapped.approvalId, frame.eventId);
  assert.equal(mapped.taskRev, 2); assert.equal(mapped.callId, null);
  assert.deepEqual(Object.keys(frame.request).sort(), ['reason', 'toolName']);
  assert.equal(effects, 0);
  f.answer(frame.eventId);
  const outcome = await running;
  assert.equal(outcome.approvalId, mapped.approvalId); assert.equal(outcome.outcome, 'allowed-once');
  assert.equal(effects, 1); assert.equal(f.driver.status, 'idle');
  assert.deepEqual(f.events.map(e => e.type), ['turn/start', 'approval/asked', 'approval/decided', 'turn/end']);
  assert.deepEqual(f.durable, f.events);
  assert.deepEqual(f.status.map(e => e.status), ['running', 'idle']);
});

test('existing ordinary running turn or maintenance rejects before task / audit writes', async () => {
  for (const kind of ['running', 'maintenance', 'companion-task']) {
    const f = fixture(); f.driver.phase = { kind, abort: new AbortController(), lastTurn: 7, turn: 8 };
    assert.throws(() => f.driver.dshGoRunTaskTurn(() => assert.fail('must not enter')), /active work/);
    assert.equal(f.events.length, 0);
  }
});

test('idle approval still fails closed; this seam does not weaken existing policy', async () => {
  const f = fixture();
  await assert.rejects(f.approval.dshGoRequestTask({ agent: f.driver, toolName: 'fixed' }, { asked() {}, remote() {} }), /outside an open turn/);
  assert.equal(f.events.length, 0);
  const never = fixture({ policy: 'never' });
  const result = await never.driver.dshGoRunTaskTurn(signal => never.approved(signal));
  assert.equal(result.outcome, 'rejected'); assert.equal(never.frames.length, 0);
});

test('wire card and reconnect both wait for durable task / revision / event binding', async () => {
  const f = fixture(); const barrier = Promise.withResolvers();
  const running = f.driver.dshGoRunTaskTurn(signal => f.approved(signal, { remote: async () => barrier.promise }));
  await tick(); assert.equal(f.gateway.pendingRemoteEvents.size, 1); assert.equal(f.frames.length, 0);
  f.client('reconnected'); assert.equal(f.frames.length, 0);
  barrier.resolve(); await tick();
  const cards = f.frames.filter(x => x.frame.type === 'waterfall');
  assert.equal(cards.length, 2); assert.equal(cards[0].frame.eventId, cards[1].frame.eventId);
  f.answer(cards[0].frame.eventId); assert.equal((await running).outcome, 'allowed-once');
});

test('binding persistence failure never delivers or grants; audit closes unavailable', async () => {
  for (const phase of ['asked', 'remote']) {
    const f = fixture();
    const observers = { [phase]: async () => { throw new Error('disk unavailable'); } };
    const result = f.driver.dshGoRunTaskTurn(signal => f.approved(signal, observers));
    if (phase === 'asked') await assert.rejects(result, /disk unavailable/);
    else assert.equal((await result).outcome, 'unavailable');
    assert.equal(f.frames.filter(x => x.frame.type === 'waterfall').length, 0);
    assert.equal(f.gateway.pendingRemoteEvents.size, 0);
    assert.equal(f.events.find(e => e.type === 'approval/decided').data.outcome, 'unavailable');
    assert.equal(f.events.at(-1).type, 'turn/end');
  }
});

test('cancel while binding is pending cannot be undone by late completion', async () => {
  const f = fixture(); const barrier = Promise.withResolvers();
  const running = f.driver.dshGoRunTaskTurn(signal => f.approved(signal, { remote: () => barrier.promise }));
  await tick(); f.driver.cancel({ kind: 'user' });
  await assert.rejects(running);
  barrier.resolve(); await tick();
  assert.equal(f.frames.filter(x => x.frame.type === 'waterfall').length, 0);
  assert.equal(f.gateway.pendingRemoteEvents.size, 0);
  assert.equal(f.events.at(-1).data.reason.kind, 'aborted');
});

test('already decided old wire id cannot settle another task approval', async () => {
  const f = fixture();
  const first = f.driver.dshGoRunTaskTurn(signal => f.approved(signal));
  await tick(); const oldId = f.frames.find(x => x.frame.type === 'waterfall').frame.eventId;
  f.answer(oldId, 'rejected'); assert.equal((await first).outcome, 'rejected');
  const second = f.driver.dshGoRunTaskTurn(signal => f.approved(signal));
  await tick(); const newId = f.frames.filter(x => x.frame.type === 'waterfall').at(-1).frame.eventId;
  assert.notEqual(oldId, newId); f.answer(oldId);
  assert.equal(f.gateway.pendingRemoteEvents.size, 1);
  f.answer(newId, 'rejected'); assert.equal((await second).outcome, 'rejected');
});

test('host restart has no old Remote grant; a new explicit attempt gets fresh ids', async () => {
  const old = fixture(), barrier = Promise.withResolvers(); let oldBinding;
  const oldTurn = old.driver.dshGoRunTaskTurn(signal => old.approved(signal, { remote: value => { oldBinding = value; return barrier.promise; } }));
  await tick();
  // Real Session recovery closes the interrupted zero-model-step turn. It
  // does not turn approval/asked into approval/decided or a file effect.
  const closers = api.interruptedTurnClosers(old.durable);
  assert.deepEqual(closers.map(e => e.type), ['turn/end']);
  assert.equal(closers[0].data.reason.kind, 'interrupted');
  assert.equal(old.durable.some(e => e.type === 'approval/decided'), false);
  // The new gateway is the actual empty pending map a fresh instance starts with.
  const restarted = fixture(); restarted.answer(oldBinding.eventId);
  assert.equal(restarted.gateway.pendingRemoteEvents.size, 0);
  const next = restarted.driver.dshGoRunTaskTurn(signal => restarted.approved(signal));
  await tick(); const newFrame = restarted.frames.find(x => x.frame.type === 'waterfall').frame;
  assert.notEqual(newFrame.eventId, oldBinding.eventId);
  assert.notEqual(restarted.events.find(e => e.type === 'approval/asked').data.id, oldBinding.approvalId);
  restarted.answer(newFrame.eventId, 'rejected'); await next;
  old.driver.cancel({ kind: 'disposed' }); await assert.rejects(oldTurn); barrier.resolve();
});

test('task slot queues ordinary wake without consuming or fabricating model history', async () => {
  const f = fixture(); const hold = Promise.withResolvers(); let kicks = 0;
  f.driver.kick = async function () { kicks++; this.setPhase({ kind: 'idle', lastTurn: this.phase.turn }); };
  const task = f.driver.dshGoRunTaskTurn(async () => hold.promise);
  await tick(); f.driver.inbox.hasPending = true; f.driver.wakeDriver();
  assert.equal(kicks, 0); assert.equal(f.driver.phase.wakeRequested, true);
  hold.resolve('done'); assert.equal(await task, 'done'); await f.driver.whenIdle();
  assert.equal(kicks, 1); assert.deepEqual(f.events.map(e => e.type), ['turn/start', 'turn/end']);
});

test('missing durability listener prevents entering the fixed effect callback', async () => {
  const f = fixture({ flush: async () => false }); let effects = 0;
  await assert.rejects(f.driver.dshGoRunTaskTurn(() => { effects++; }), /durabl/);
  assert.equal(effects, 0); assert.equal(f.driver.status, 'idle'); await f.driver.whenIdle();
});

test('ordinary approval still projects exactly its existing optional real call id', async () => {
  const f = fixture();
  const running = f.driver.dshGoRunTaskTurn(signal => f.approval.request({ agent: f.driver, toolName: 'existing.tool', callId: 'real-model-call', signal }));
  await tick(); const frame = f.frames.find(x => x.frame.type === 'waterfall').frame;
  assert.deepEqual({ ...frame.request }, { toolName: 'existing.tool', callId: 'real-model-call' });
  f.answer(frame.eventId, 'rejected'); assert.equal(await running, 'rejected');
});

test('real gateway projector still rejects task functions and symbols in the wire request', () => {
  const f = fixture();
  assert.throws(() => api.projectRemoteEventRequest({ agent: f.driver, observer() {} }, f.driver), /lossless JSON/);
  assert.throws(() => api.projectRemoteEventRequest({ agent: f.driver, [Symbol('task')]: 'never wire' }, f.driver), /non-JSON/);
});

test('ordinary wake after disposed fixed work stays stopped, and whenIdle waits for the callback', async () => {
  const f = fixture(); const hold = Promise.withResolvers(); let idle = false, kicks = 0;
  f.driver.kick = async () => { kicks++; };
  const task = f.driver.dshGoRunTaskTurn(() => hold.promise);
  await tick(); const idleWait = f.driver.whenIdle().then(() => { idle = true; });
  f.driver.inbox.hasPending = true; f.driver.wakeDriver(); f.driver.cancel({ kind: 'disposed' }, { keepInbox: true });
  await tick(); assert.equal(idle, false);
  hold.resolve(); await assert.rejects(task); await idleWait;
  assert.equal(kicks, 0); assert.equal(f.driver.status, 'idle');
});

test('revision owner guard can reject a stale grant before the fixed effect', async () => {
  const f = fixture(); let currentRev = 2, effects = 0;
  const captured = Object.freeze({ taskId: 'notes-1', taskRev: 2, step: 'publish' });
  const guard = () => { if (currentRev !== captured.taskRev) throw new Error('task revised'); };
  const task = f.driver.dshGoRunTaskTurn(async signal => {
    guard(); const grant = await f.approved(signal, {
      asked: async () => { guard(); assert.equal(await f.ctx.sessions.flush(f.session), true); },
      remote: async () => { guard(); },
    });
    // The concrete task-store owner must repeat this CAS at the effect claim;
    // an allowed-once answer alone is never a current task revision receipt.
    guard(); if (grant.outcome === 'allowed-once') effects++;
  });
  await tick(); const frame = f.frames.find(x => x.frame.type === 'waterfall').frame;
  currentRev = 3; f.answer(frame.eventId);
  await assert.rejects(task, /task revised/); assert.equal(effects, 0);
});

test('real sandbox escalation delegates the fixed operation through the original approval policy', async () => {
  const f = fixture(); let binding;
  const standing = Object.freeze({ mode: 'read-only', workspaceRoot: '/synthetic/notes' });
  const task = f.driver.dshGoRunTaskTurn(async signal => {
    api.validateEscalationArgs('workspace-write', '在已选笔记目录发布本次待办');
    const mode = await api.approveEscalation({ requestedMode: 'workspace-write', effectiveMode: standing.mode,
      justification: '在已选笔记目录发布本次待办', subject: 'operation' }, {
      agent: f.driver, toolName: 'companion.notes-to-todos.publish', signal,
      // Actual public EscalationApprover structural interface: no fake tool/call.
      approver: { async request(req) {
        binding = await f.approval.dshGoRequestTask(req, {
          asked: async () => { assert.equal(await f.ctx.sessions.flush(f.session), true); },
          remote: async () => {},
        });
        assert.equal(await f.ctx.sessions.flush(f.session), true);
        signal.throwIfAborted(); return binding.outcome;
      } },
    });
    return { ...standing, mode };
  });
  await tick(); const frame = f.frames.find(x => x.frame.type === 'waterfall').frame;
  assert.equal(Object.hasOwn(frame.request, 'callId'), false);
  assert.match(frame.request.reason, /^escalate sandbox to workspace-write:/);
  assert.ok(frame.request.displayReason.zh);
  f.answer(frame.eventId);
  assert.deepEqual(await task, { ...standing, mode: 'workspace-write' });
  assert.equal(standing.mode, 'read-only'); assert.ok(binding.approvalId);
});

test('real escalation rejects a narrower mode and non-grant outcomes without effect', async () => {
  let asks = 0;
  await assert.rejects(api.approveEscalation({ requestedMode: 'read-only', effectiveMode: 'workspace-write', subject: 'operation' },
    { agent: {}, approver: { request() { asks++; } } }), /not strictly wider/);
  assert.equal(asks, 0);
  for (const result of ['rejected', 'cancelled', 'unavailable']) {
    await assert.rejects(api.approveEscalation({ requestedMode: 'workspace-write', effectiveMode: 'read-only', justification: '固定步骤', subject: 'operation' },
      { agent: {}, approver: { request: async () => result } }));
  }
});
