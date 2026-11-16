// Exact classes extracted from the PATCHED candidate; no user sessions or live Host.
// INPUT_RECOVERY_MODULE=/tmp/.../candidate/node_modules/@deepseek-ai/dsh-agent-loop/lib/index.js \
// INPUT_RECOVERY_DEPS_PREFIX=/opt/dsh node --test runtime/tests/input-recovery.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { resolve, join, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';

const prefix = process.env.DSH_PREFIX;
const modulePath = process.env.INPUT_RECOVERY_MODULE
  ?? (prefix && join(prefix, 'node_modules/@deepseek-ai/dsh-agent-loop/lib/index.js'));
if (!modulePath) throw Error('Set INPUT_RECOVERY_MODULE or DSH_PREFIX to the patched candidate');
const source = readFileSync(modulePath, 'utf8');
assert.match(source, /settledIds: messageIds/, 'tests require the applied recovery patch');
const deps = process.env.INPUT_RECOVERY_DEPS_PREFIX ?? prefix;
if (!deps) throw Error('Set INPUT_RECOVERY_DEPS_PREFIX to an isolated or installed dependency tree');
const require = createRequire(resolve(deps, 'package.json'));
const { z } = require('zod');
const { AgentModel, modelSelectionProjectionDefinition } = await import(pathToFileURL(join(deps, 'node_modules/@deepseek-ai/dsh-agent/lib/index.js')));
const { ToolActivationError } = await import(pathToFileURL(join(deps, 'node_modules/@deepseek-ai/dsh-tools/lib/index.js')));
const sessionApi = await import(pathToFileURL(join(deps, 'node_modules/@deepseek-ai/dsh-session/lib/index.js')));
// The companion recall gates (runtime/patches/*-companion-recall-gates.diff)
// add an import of dshGoRecall to the agent loop; the extracted classes need it
// in scope. With no recall module registered its gates let everything through.
// From the dependency tree, else from the patched candidate itself (a separate
// deps prefix may be an older, unpatched install).
async function recallBinding() {
  for (const llm of [
    join(deps, 'node_modules/@deepseek-ai/dsh-llm/lib/index.js'),
    resolve(dirname(modulePath), '../../dsh-llm/lib/index.js'),
  ]) {
    try {
      const { dshGoRecall: binding } = await import(pathToFileURL(llm));
      if (binding !== undefined) return binding;
    } catch {
      // Not there: try the next tree.
    }
  }
  throw Error('no patched @deepseek-ai/dsh-llm with dshGoRecall in the deps prefix or beside the candidate');
}
const dshGoRecall = await recallBinding();

function region(name) {
  const start = source.indexOf(`//#region lib/types/${name}.js`);
  const end = source.indexOf('//#endregion', start);
  assert(start >= 0 && end > start, `candidate region ${name}`);
  return source.slice(start, end);
}

class LlmError extends Error {}
const bindings = {
  z$1: z, AgentModel, ToolActivationError, dshGoRecall,
  agentEvents: (ctx, agent) => { ctx.constructingAgent = agent; return ctx.dispatch; },
  createScope: ctx => ({ ctx }),
  assembleContextFor: (agent, signal) => ({ agent, signal }),
  renderContextSections: () => [],
  joinContextSections: () => '',
  renderPrompt: () => 'synthetic prompt',
  createSystemMessage: text => ({ role: 'system', content: [{ type: 'text', text }] }),
  ToolCallRecovery: sessionApi.ToolCallRecovery,
  LlmError,
  errorChain: error => error.message,
  deepFreeze: value => value,
  assertNever: value => { throw Error(`Unexpected ${value}`); },
};
// The OHOS agent calls this module-local helper before claiming input.
const lifecycleHelper = source.match(/^function ohosLifecycle\(\) \{[\s\S]*?^\}/m)?.[0] ?? '';
const api = Function(...Object.keys(bindings), [
  lifecycleHelper,
  region('inbox'), region('runtime-context'), region('agent'),
  'return {ReactLoopInbox, ReactLoopAgent, inboxProjectionDefinition};',
].join('\n'))(...Object.values(bindings));
const definition = api.inboxProjectionDefinition;
const ids = messages => messages.map(message => message.id);
const message = (id, attachment = false) => ({
  id, role: 'user', source: { kind: 'user', rpcId: `rpc-${id}` },
  content: [{ type: 'text', text: `synthetic input ${id}` },
    ...(attachment ? [{ type: 'image', mimeType: 'image/png', data: 'c3ludGhldGlj' },
      { type: 'file', path: '/synthetic/attachment.txt', name: 'attachment.txt' }] : [])],
});

function fixture({ events = [], assemble, preStep, prepareCall, failAppend, notify } = {}) {
  let state = definition.init();
  const log = [];
  const listeners = new Set();
  const notifications = [];
  const counters = { assembly: 0, preparation: 0, wake: 0 };
  let session;
  function observe(event) {
    state = definition.stateSchema.parse(definition.apply(state, event));
    log.push(structuredClone(event));
  }
  for (const event of events) observe(event);
  session = {
    id: 'synthetic-session',
    surface: { contentGeneration: 0, nodes: [] },
    append(type, data, intent = {}) {
      if (failAppend?.(type, data, log)) throw Error('synthetic storage failure');
      const event = { type, data: structuredClone(data), seq: log.length, time: '2026-01-01T00:00:00Z', ...intent };
      observe(event);
      if (intent.surfaceOp === 'append') session.surface.nodes.push(event.seq);
      for (const listener of listeners) listener(session, event);
      return event;
    },
    snapshotEvents: () => [...log],
    eventAt: seq => log[seq],
    requestHeader: () => undefined,
  };
  const projections = {
    stateOf(_session, key) {
      if (key === 'inbox') return state;
      if (key === 'turnBoundary') return { lastTurn: log.findLast(e => e.type === 'turn/start')?.data.turn ?? 0 };
      throw Error(`Unexpected projection ${key}`);
    },
  };
  const dispatch = {
    emit: (type, data) => { notifications.push({ type, data }); notify?.(type, data, ctx.constructingAgent); },
    serial: async () => {},
    waterfall: async (type, args, fallback) => {
      if (type === 'agent/pre-step' && preStep) return preStep(args, fallback);
      return fallback();
    },
  };
  const ctx = {
    dispatch, sessionProjections: projections,
    tools: { resolve: async () => ({ dispose() {} }) },
    get: () => undefined,
    on: (type, listener) => { assert.equal(type, 'session/event'); listeners.add(listener); return () => listeners.delete(listener); },
    agents: { withInitiator: (_agent, fn) => fn() },
    systemPrompt: {
      async assemble(context) { counters.assembly++; return assemble ? assemble(context) : { tools: [] }; },
      refreshContext: assembly => assembly,
    },
    llm: {
      async prepareCall(config, signal) {
        counters.preparation++;
        return prepareCall ? prepareCall(config, signal) : { config };
      },
    },
  };
  const agent = new api.ReactLoopAgent(ctx, session.id, { provider: 'synthetic', model: 'test', reasoningEffort: 'max' }, session, { modelSelection: () => modelSelectionProjectionDefinition.init(), inbox: () => state }, log.findLast(e => e.type === 'turn/start')?.data.turn ?? 0);
  // The factory now calls recovery after SessionStore announcement; this isolated class fixture models that handoff.
  agent.inbox.recover();
  // Exercise the real step/admission path, then stop before starting any real model request.
  agent.buildRequest = () => { throw Error('synthetic post-admission failure'); };
  const originalWake = agent.wakeDriver;
  agent.wakeDriver = function (...args) { counters.wake++; return originalWake.apply(this, args); };
  return { agent, session, log, notifications, counters, state: () => state };
}
function running(f) {
  f.agent.phase = { kind: 'running', turn: 1, step: 0, abort: new AbortController(), wakeRequested: false };
  f.session.append('turn/start', { turn: 1 });
}
function cold(events, options = {}) {
  const committed = structuredClone(events);
  const closers = sessionApi.interruptedTurnClosers(committed);
  return fixture({ ...options, events: [...committed, ...closers] });
}
function clientInbox(events) {
  const pending = { 'next-turn': [], 'next-step': [] };
  for (const event of events) if (event.type === 'agent/inbox/spliced') {
    const data = event.data;
    pending[data.target].splice(data.start, data.removedCount ?? 0, ...data.inserted);
  }
  return pending;
}
function assertClientSees(f) {
  const view = definition.wire.viewSchema.parse(definition.wire.view(f.state()));
  assert.deepEqual(Object.keys(view).sort(), ['next-step', 'next-turn']);
  assert.deepEqual(clientInbox(f.log), view);
}

for (const stage of ['assemble', 'prepare']) test(`real class ${stage} failure restores input once without automatic retry`, async () => {
  const fault = Error(`synthetic ${stage} failure`);
  const f = fixture(stage === 'assemble' ? { assemble: async () => { throw fault; } }
    : { prepareCall: async config => { assert.equal(config.reasoningEffort, 'max'); throw fault; } });
  const original = message('a', true);
  f.agent.followup(original);
  await f.agent.whenIdle();
  assert.equal(f.agent.status, 'idle');
  assert.deepEqual(f.agent.inbox.nextTurn, [original]);
  assert.deepEqual(f.state().inFlight, []);
  assert.equal(f.counters.wake, 1);
  assert.equal(f.counters.assembly, 1);
  assert.equal(f.log.filter(e => e.type === 'turn/end').length, 1);
  assert.equal(f.notifications.filter(e => e.type === 'agent/error').length, 1);
  assert.equal(f.log.find(e => e.type === 'turn/end').data.reason.kind, 'error');
  const endIndex = f.log.findIndex(e => e.type === 'turn/end');
  const claimIndex = f.log.findIndex(e => e.type === 'agent/inbox/spliced' && e.data.removedCount);
  assert(f.log.slice(claimIndex + 1, endIndex).some(e => e.type === 'agent/inbox/spliced' && e.data.inserted[0]?.id === 'a'));
  assertClientSees(f);
  const count = f.log.length;
  assert.equal(f.agent.inbox.recover(), false);
  await Promise.resolve();
  assert.equal(f.log.length, count);
});

for (const stage of ['pre-step', 'refresh-context', 'system-message']) test(`all preparation boundaries recover: ${stage}`, async () => {
  const f = fixture({
    preStep: stage === 'pre-step' ? async () => { throw Error('synthetic plugin failure'); } : undefined,
    failAppend: stage === 'system-message' ? type => type === 'system/message' : undefined,
  });
  if (stage === 'refresh-context') f.agent.loopCtx.systemPrompt.refreshContext = () => { throw Error('synthetic refresh failure'); };
  f.agent.followup(message('a', true));
  await f.agent.whenIdle();
  assert.deepEqual(f.agent.inbox.nextTurn, [message('a', true)]);
  assert.equal(f.counters.wake, 1);
  assert.equal(f.log.filter(e => e.type === 'user/message').length, 0);
  // Every physical crash cut of the real failure sequence remains idempotent.
  const firstClaim = f.log.findIndex(e => e.type === 'agent/inbox/spliced' && e.data.removedCount);
  for (let cut = firstClaim + 1; cut <= f.log.length; cut++) {
    const resumed = cold(f.log.slice(0, cut));
    assert.deepEqual(resumed.agent.inbox.nextTurn, [message('a', true)]);
    assertClientSees(resumed);
  }
});

test('real prepareRequest preserves route and effort; explicit resume does not require resending original text', async () => {
  let fail = true;
  const f = fixture({ prepareCall: async config => {
    assert.deepEqual(config, { provider: 'synthetic', model: 'test', reasoningEffort: 'max' });
    if (fail) throw Error('unsupported synthetic configuration');
    return { config };
  } });
  f.agent.followup(message('a'));
  await f.agent.whenIdle();
  fail = false;
  f.agent.wakeDriver();
  await f.agent.whenIdle();
  assert.deepEqual(f.agent.inbox.nextTurn, []);
  assert.deepEqual(ids(f.log.filter(e => e.type === 'user/message').map(e => e.data)), ['a']);
  assert.equal(f.counters.preparation, 2);
});

test('crash at every claim/admission/restore prefix replays original targets, order, identity and attachments', () => {
  const f = fixture();
  for (const id of ['s1', 's2']) f.agent.inbox.append('next-step', message(id, id === 's2'));
  for (const id of ['t1', 't2']) f.agent.inbox.append('next-turn', message(id));
  running(f);
  f.agent.inbox.claim('next-turn', 1);
  f.session.append('user/message', message('s1'), { surfaceOp: 'append' });
  f.session.append('step/end', { turn: 1, step: 1 });
  f.session.append('turn/end', { turn: 1, reason: { kind: 'error', error: { code: 'UNKNOWN', message: 'synthetic' } } });
  f.agent.inbox.recover();
  const start = f.log.findIndex(e => e.type === 'turn/start');
  for (let cut = start + 1; cut <= f.log.length; cut++) {
    const prefixLog = f.log.slice(0, cut);
    const admitted = prefixLog.some(e => e.type === 'user/message' && e.data.id === 's1');
    const resumed = cold(prefixLog);
    assert.deepEqual(ids(resumed.agent.inbox.nextStep), admitted ? ['s2'] : ['s1', 's2'], `cut ${cut}`);
    assert.deepEqual(ids(resumed.agent.inbox.nextTurn), ['t1', 't2'], `cut ${cut}`);
    assert.deepEqual(resumed.agent.inbox.nextStep.find(m => m.id === 's2'), message('s2', true));
    assert.equal(resumed.counters.wake, 0);
    assertClientSees(resumed);
    const again = cold(resumed.log);
    assert.deepEqual(again.log, resumed.log, `second replay cut ${cut}`);
  }
});

test('cold recovery insertion observers see a fully initialized idle agent', () => {
  const f = fixture();
  f.agent.inbox.append('next-turn', message('held'));
  running(f);
  f.agent.inbox.claim('next-turn', 1);
  let observed = 0;
  const resumed = cold(f.log, { notify: (type, data, agent) => {
    if (type !== 'agent/inbox/inserted') return;
    observed++;
    assert.equal(data.message.id, 'held');
    assert.equal(agent.status, 'idle');
    assert.equal(agent.phase.lastTurn, 1);
    assert(agent.runtimeContext);
    assert(agent.systemPrompt);
    assert.deepEqual(ids(agent.inbox.nextTurn), ['held']);
  } });
  assert.equal(observed, 1);
  assert.equal(resumed.counters.wake, 0);
});

test('partially admitted messages are never reinserted or admitted twice after a real step append failure', async () => {
  let fail = true;
  const f = fixture({ failAppend: (type, data) => type === 'user/message' && data.id === 's2' && fail });
  f.agent.inject(message('s1'));
  f.agent.inject(message('s2', true));
  f.agent.followup(message('t1'));
  await f.agent.whenIdle();
  assert.deepEqual(ids(f.agent.inbox.nextStep), ['s2']);
  assert.deepEqual(ids(f.agent.inbox.nextTurn), ['t1']);
  assert.deepEqual(ids(f.log.filter(e => e.type === 'user/message').map(e => e.data)), ['s1']);
  fail = false;
  f.agent.wakeDriver();
  await f.agent.whenIdle();
  assert.deepEqual(ids(f.log.filter(e => e.type === 'user/message').map(e => e.data)), ['s1', 's2', 't1']);
  assert.deepEqual(f.state().inFlight, []);
  assertClientSees(f);
});

test('restoration prepends before arrivals and next-step claim never steals a queued turn', () => {
  const f = fixture();
  f.agent.inbox.append('next-step', message('s1'));
  f.agent.inbox.append('next-step', message('s2'));
  f.agent.inbox.append('next-turn', message('t1'));
  f.agent.inbox.append('next-turn', message('t2'));
  running(f);
  assert.deepEqual(ids(f.agent.inbox.claim('next-turn', 1)), ['s1', 's2', 't1']);
  f.agent.inbox.append('next-step', message('s3'));
  f.agent.inbox.append('next-turn', message('t3'));
  f.agent.inbox.recover();
  assert.deepEqual(ids(f.agent.inbox.claim('next-step', 1)), ['s1', 's2', 's3']);
  assert.deepEqual(ids(f.agent.inbox.nextTurn), ['t1', 't2', 't3']);
});

test('blocked and deliberately filtered plugin input is settled durably, not restored on later failure', async () => {
  const blocked = fixture({ preStep: async () => ({ kind: 'reject' }) });
  blocked.agent.followup(message('pwd'));
  await blocked.agent.whenIdle();
  assert.deepEqual(blocked.agent.inbox.nextTurn, []);
  assert.equal(blocked.log.find(e => e.type === 'turn/end').data.reason.kind, 'blocked');
  assert.equal(blocked.log.some(e => e.type === 'user/message'), false);
  assert.deepEqual(cold(blocked.log).agent.inbox.nextTurn, []);

  const filtered = fixture({
    preStep: async ({ messages }) => ({ kind: 'enter', messages: messages.filter(m => m.id !== 'consumed') }),
    prepareCall: async () => { throw Error('synthetic preparation failure'); },
  });
  filtered.agent.inject(message('consumed'));
  filtered.agent.followup(message('retained'));
  await filtered.agent.whenIdle();
  assert.deepEqual(filtered.agent.inbox.nextStep, []);
  assert.deepEqual(ids(filtered.agent.inbox.nextTurn), ['retained']);
  const marker = filtered.log.findIndex(e => e.data.settledIds?.includes('consumed'));
  const resumed = cold(filtered.log.slice(0, marker + 1));
  assert.deepEqual(resumed.agent.inbox.nextStep, []);
  assert.deepEqual(ids(resumed.agent.inbox.nextTurn), ['retained']);
});

test('plugin replacement is intentional consumption even if the replacement request fails', async () => {
  const f = fixture({ preStep: async () => ({ kind: 'enter', messages: [message('replacement')] }),
    prepareCall: async () => { throw Error('synthetic failure'); } });
  f.agent.followup(message('consumed'));
  await f.agent.whenIdle();
  assert.deepEqual(f.agent.inbox.nextTurn, []);
  assert.deepEqual(cold(f.log).agent.inbox.nextTurn, []);
});

for (const kind of ['user', 'disposed']) test(`cancel ${kind} recovers unadmitted claim but not explicitly canceled pending input`, async () => {
  let release;
  let entered;
  const inside = new Promise(resolve => { entered = resolve; });
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture({ assemble: async () => { entered(); await gate; return { tools: [] }; } });
  f.agent.followup(message('claimed', true));
  await inside;
  f.agent.inbox.append('next-turn', message('pending'));
  f.agent.cancel({ kind });
  release();
  await f.agent.whenIdle();
  assert.deepEqual(ids(f.agent.inbox.nextTurn), ['claimed']);
  assert.equal(f.log.find(e => e.type === 'turn/end').data.reason.kind, 'aborted');
  assert.equal(f.counters.wake, 1);
  assert.deepEqual(ids(cold(f.log).agent.inbox.nextTurn), ['claimed']);
  assertClientSees(f);
});

test('an explicit inbox remove/clear is not a claim and is never resurrected', async () => {
  const f = fixture();
  f.agent.inject(message('s'));
  f.agent.inbox.append('next-turn', message('t'));
  f.agent.cancel({ kind: 'user' });
  assert.equal(f.agent.inbox.hasPending, false);
  assert.equal(cold(f.log).agent.inbox.hasPending, false);
  await f.agent.runMaintenance(async () => {});
  assert.equal(f.agent.inbox.hasPending, false);
});

test('cancel followed by a new wake cannot turn recovered input into an automatic error storm', async () => {
  let release;
  let entered;
  const inside = new Promise(resolve => { entered = resolve; });
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture({ assemble: async () => { entered(); await gate; return { tools: [] }; } });
  f.agent.followup(message('claimed'));
  await inside;
  f.agent.cancel({ kind: 'user' });
  f.agent.followup(message('new'));
  release();
  await f.agent.whenIdle();
  assert.deepEqual(ids(f.agent.inbox.nextTurn), ['claimed', 'new']);
  assert.equal(f.counters.assembly, 1);
  assert.equal(f.agent.status, 'idle');
});

test('failed restore append is contained once and cold resume can finish the durable claim', async () => {
  let rejectRestore = false;
  const f = fixture({ assemble: async () => { rejectRestore = true; throw Error('synthetic assemble failure'); },
    failAppend: (type, data) => rejectRestore && type === 'agent/inbox/spliced' && data.inserted.length > 0 });
  f.agent.followup(message('a'));
  await f.agent.whenIdle();
  assert.equal(f.agent.status, 'idle');
  assert.equal(f.counters.assembly, 1);
  assert.equal(f.log.find(e => e.type === 'turn/end').data.reason.error.message, 'synthetic assemble failure');
  assert.deepEqual(f.notifications.filter(e => e.type === 'agent/error').map(e => e.data.error.message),
    ['synthetic assemble failure', 'synthetic storage failure']);
  assert.deepEqual(ids(f.state().inFlight.map(claim => claim.message)), ['a']);
  assert.deepEqual(ids(cold(f.log).agent.inbox.nextTurn), ['a']);
});

test('failed live restore blocks a new turn until the held input can be recovered', async () => {
  let failPrepare = true;
  let failRestore = true;
  const f = fixture({
    prepareCall: async config => { if (failPrepare) throw Error('synthetic prepare failure'); return { config }; },
    failAppend: (type, data, log) => failRestore && type === 'agent/inbox/spliced' && data.inserted.length > 0
      && log.some(e => e.type === 'turn/start'),
  });
  f.agent.followup(message('held'));
  await f.agent.whenIdle();
  assert.deepEqual(ids(f.agent.inbox.claimed), ['held']);
  const turns = f.log.filter(e => e.type === 'turn/start').length;
  assert.throws(() => f.agent.wakeDriver(), /synthetic storage failure/);
  assert.equal(f.agent.status, 'idle');
  assert.equal(f.log.filter(e => e.type === 'turn/start').length, turns);
  assert.deepEqual(ids(f.agent.inbox.claimed), ['held']);
  assert.throws(() => f.agent.followup(message('new')), /synthetic storage failure/);
  assert.deepEqual(f.agent.inbox.nextTurn, [], 'a rejected admission must not leave its new input queued');
  assert.equal(f.log.some(e => e.type === 'agent/inbox/spliced' && e.data.inserted.some(m => m.id === 'new')), false);
  failPrepare = false;
  failRestore = false;
  f.agent.followup(message('new'));
  await f.agent.whenIdle();
  assert.deepEqual(f.agent.inbox.claimed, []);
  assert.deepEqual(ids(f.agent.inbox.nextTurn), ['new']);
  f.agent.wakeDriver();
  await f.agent.whenIdle();
  assert.deepEqual(ids(f.log.filter(e => e.type === 'user/message').map(e => e.data)), ['held', 'new']);
});

test('real controller prompt retries are idempotent while claimed, restored and admitted', async () => {
  const controllerPath = process.env.INPUT_RECOVERY_CONTROLLER_MODULE
    ?? resolve(dirname(modulePath), '../../dsh-api-session-controller/lib/index.js');
  const controllerSource = readFileSync(controllerPath, 'utf8');
  const start = controllerSource.indexOf('//#region lib/types/commands.js');
  const end = controllerSource.indexOf('//#endregion', start);
  assert(start >= 0 && end > start);
  assert.match(controllerSource.slice(start, end), /agent\.inbox\.claimed\?\.some\(matches\)/);
  let nextId = 0;
  class RemoteError extends Error {}
  const { SessionCommandController, hasPromptRequest } = Function('createUserMessage', 'RemoteError', 'remoteErrorOf', 'AttachmentError',
    controllerSource.slice(start, end) + '\nreturn {SessionCommandController, hasPromptRequest};')
    (input => ({ ...input, id: `synthetic-rpc-${++nextId}`, role: 'user' }), RemoteError, () => undefined, class extends Error {});
  let release;
  let entered;
  let failPrepare = true;
  const inside = new Promise(resolve => { entered = resolve; });
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture({
    assemble: async () => { entered(); await gate; return { tools: [] }; },
    prepareCall: async config => { if (failPrepare) throw Error('synthetic prepare failure'); return { config }; },
  });
  let admissions = 0;
  const ctx = {
    agents: { get: () => f.agent },
    attachments: { admitPromptContent: async content => { admissions++; return content; } },
    fileUploads: {
      resolve: () => undefined,
      bindPrompt: () => ({ commit() {}, [Symbol.dispose]() {} }),
    },
  };
  const controller = new SessionCommandController(ctx, {}, '/synthetic');
  controller.resolveAgent = async () => f.agent;
  const request = (requestId, text) => ({ sessionId: f.agent.id, requestId, mode: 'followup', content: [{ type: 'text', text }] });
  const submit = (requestId, text) => controller.prompt(request(requestId, text), { kind: 'user', rpcId: requestId });
  await submit('rpc-a', 'original A');
  await inside;
  assert.equal(hasPromptRequest(f.agent, 'rpc-a'), true);
  await submit('rpc-a', 'transport retry B must not replace A');
  assert.equal(admissions, 1);
  assert.equal(nextId, 1);
  // Identical text with a different identity is a distinct prompt, not a duplicate.
  await submit('rpc-b', 'original A');
  assert.equal(admissions, 2);
  release();
  await f.agent.whenIdle();
  assert.deepEqual(f.agent.inbox.nextTurn.map(m => m.source.rpcId), ['rpc-a', 'rpc-b']);
  await submit('rpc-a', 'retry after restored');
  assert.equal(admissions, 2);
  failPrepare = false;
  f.agent.wakeDriver();
  await f.agent.whenIdle();
  await submit('rpc-a', 'retry after admitted');
  assert.equal(admissions, 2);
  f.agent.wakeDriver();
  await f.agent.whenIdle();
  const admitted = f.log.filter(e => e.type === 'user/message').map(e => e.data);
  assert.deepEqual(admitted.map(m => m.source.rpcId), ['rpc-a', 'rpc-b']);
  assert.deepEqual(admitted.map(m => m.content[0].text), ['original A', 'original A']);
  // Older Agent drivers without the optional claimed view remain supported.
  assert.equal(hasPromptRequest({ inbox: { nextTurn: [], nextStep: [] }, session: { snapshotEvents: () => [] } }, 'rpc-a'), false);
});

test('real JSONL backend preserves explicit consumption markers and recovered splice identity', async t => {
  const { Context } = await import(pathToFileURL(join(deps, 'node_modules/@deepseek-ai/cordis/lib/index.js')));
  const { apply } = await import(pathToFileURL(join(deps, 'node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js')));
  const ctx = new Context();
  const root = await mkdtemp(join(tmpdir(), 'dsh-input-codec-'));
  t.after(async () => { await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }); });
  await apply(ctx, { root, compression: 'none', listConcurrency: 1 });
  const projectionOf = session => session.snapshotEvents().reduce((state, event) => definition.apply(state, event), definition.init());
  const live = sessionApi.Session.create('synthetic-jsonl-recovery');
  const inbox = new api.ReactLoopInbox(() => projectionOf(live), live, { emit() {} });
  inbox.append('next-step', message('consumed'));
  inbox.append('next-turn', message('retained'));
  live.append('turn/start', { turn: 1 });
  inbox.claim('next-turn', 1);
  inbox.settle(['consumed']);
  const writer = await ctx.sessionPersistence.create(live.header);
  await writer.append(live.snapshotEvents()); await writer.flush(); await writer.close();
  const reader = await ctx.sessionPersistence.open(live.id, 'read');
  const loaded = await reader.read(); await reader.close();
  assert.deepEqual(loaded.events.find(event => event.data.settledIds)?.data.settledIds, ['consumed']);
  const recovered = cold(loaded.events);
  assert.deepEqual(ids(recovered.agent.inbox.nextTurn), ['retained']);
  assert.deepEqual(recovered.agent.inbox.nextStep, []);
  assert.deepEqual(cold(recovered.log).log, recovered.log, 'second reconstruction preserves identities without another splice');
});

test('real buildForkSeed preserves claims at every prefix and never restores admitted identities twice', () => {
  const projectionOf = session => session.snapshotEvents().reduce((state, event) => definition.apply(state, event), definition.init());
  const ctx = {
    dispatch: { emit() {} },
    sessionProjections: { stateOf: (session, key) => key === 'inbox' ? projectionOf(session) : { lastTurn: 1 } },
    on: () => () => {},
  };
  const live = sessionApi.Session.create('synthetic-fork-parent');
  const inbox = new api.ReactLoopInbox(() => projectionOf(live), live, ctx.dispatch);
  inbox.append('next-step', message('s1'));
  inbox.append('next-step', message('s2', true));
  inbox.append('next-turn', message('t1'));
  inbox.append('next-turn', message('t2'));
  live.append('turn/start', { turn: 1 });
  inbox.claim('next-turn', 1);
  live.append('user/message', message('s1'), { surfaceOp: 'append' });
  live.append('user/message', message('t1'), { surfaceOp: 'append' });
  const events = live.snapshotEvents();
  const firstTurn = events.findIndex(e => e.type === 'turn/start');
  for (let boundary = firstTurn; boundary < events.length; boundary++) {
    const seed = sessionApi.buildForkSeed(events, boundary);
    assert.equal(seed.at(-1).data.reason.kind, 'forked');
    const header = { ...live.header, id: 'synthetic-fork-child', isSeeded: true, parentSession: live.id };
    const child = sessionApi.Session.create(header.id, seed, header, boundary + 1);
    const agent = new api.ReactLoopAgent(ctx, header.id, {}, child, { modelSelection: () => modelSelectionProjectionDefinition.init(), inbox: () => projectionOf(child) }, 1);
    agent.inbox.recover();
    const admitted = new Set(events.slice(0, boundary + 1).filter(e => e.type === 'user/message').map(e => e.data.id));
    assert.deepEqual(ids(agent.inbox.nextStep), ['s1', 's2'].filter(id => !admitted.has(id)), `fork boundary ${boundary}`);
    assert.deepEqual(ids(agent.inbox.nextTurn), ['t1', 't2'].filter(id => !admitted.has(id)), `fork boundary ${boundary}`);
    assert.deepEqual(agent.inbox.nextStep.find(m => m.id === 's2'), message('s2', true));
    assert.equal(agent.status, 'idle');
    const replay = sessionApi.Session.create(header.id, child.snapshotEvents(), header, boundary + 1);
    const before = replay.snapshotEvents();
    const resumed = new api.ReactLoopAgent(ctx, header.id, {}, replay, { modelSelection: () => modelSelectionProjectionDefinition.init(), inbox: () => projectionOf(replay) }, 1);
    resumed.inbox.recover();
    assert.deepEqual(ids(resumed.inbox.nextStep), ids(agent.inbox.nextStep));
    assert.deepEqual(ids(resumed.inbox.nextTurn), ids(agent.inbox.nextTurn));
    assert.deepEqual(replay.snapshotEvents(), before, 'second attachment must not emit duplicate recovery splices');
  }
});

test('real buildForkSeed never revives blocked or explicitly consumed plugin input', () => {
  for (const kind of ['blocked', 'settled-before-terminal']) {
    const f = fixture();
    f.agent.inbox.append('next-turn', message('consumed'));
    running(f);
    f.agent.inbox.claim('next-turn', 1);
    if (kind === 'blocked') f.session.append('turn/end', { turn: 1, reason: { kind: 'blocked' } });
    else f.agent.inbox.settle(['consumed']);
    const seed = sessionApi.buildForkSeed(f.log, f.log.length - 1);
    const forked = fixture({ events: seed });
    assert.equal(forked.agent.inbox.hasPending, false);
    assert.deepEqual(forked.state().inFlight, []);
  }
});

test('unrecognized terminal reasons retain claims rather than silently declaring consumption', () => {
  for (const reason of [null, { kind: 'future-non-success-terminal' }]) {
    const f = fixture();
    f.agent.inbox.append('next-turn', message('retained'));
    running(f);
    f.agent.inbox.claim('next-turn', 1);
    f.session.append('turn/end', { turn: 1, reason });
    assert.deepEqual(ids(cold(f.log).agent.inbox.nextTurn), ['retained']);
  }
});

test('successful no-echo consumption from old histories stays consumed; wire schema remains unchanged', () => {
  for (const kind of ['blocked', 'completed', 'max-tokens']) {
    const f = fixture();
    f.agent.inbox.append('next-turn', message('consumed'));
    running(f);
    f.agent.inbox.claim('next-turn', 1);
    f.session.append('turn/end', { turn: 1, reason: { kind } });
    assert.equal(cold(f.log).agent.inbox.hasPending, false);
  }
  assert.equal(definition.stateVersion, 2);
});

// OHOS-only integration: the real module helper and coordinator own admission.
// The existing fixture retains the real ReactLoopAgent/inbox and synthetic LLM.
if (globalThis[Symbol.for('dsh.go.ohos.sim')] === true) {
  try {
    assert.equal(source.match(/^function ohosLifecycle\(\) \{[\s\S]*?^\}/gm)?.length, 1,
      'OHOS simulation requires the unique real lifecycle helper');
    const { BoundaryCoordinator, lifecycleSymbol } = await import('../ohos/lifecycle/coordinator.mjs');
    const { openBoundaryJournal } = await import('../ohos/lifecycle/journal.mjs');
    const fs = await import('node:fs/promises');
    const { tmpdir } = await import('node:os');
    const { setImmediate: nextTurn } = await import('node:timers/promises');
    const binding = process._linkedBinding('dsh_ohos_publication');
    async function lifecycleFixture(t, f, directory) {
      const root = directory ?? await fs.mkdtemp(join(tmpdir(), 'input-lifecycle-'));
      const journal = await openBoundaryJournal({ directory: root, lockExclusive: binding.lockExclusive });
      const owner = new BoundaryCoordinator({ journal, bootId: 'input-test',
        flushSession: async () => true, readEvents: async () => f.log,
        resolveAgent: id => id === f.session.id ? f.agent : undefined });
      assert.equal(globalThis[lifecycleSymbol], undefined);
      globalThis[lifecycleSymbol] = owner;
      t.after(async () => {
        delete globalThis[lifecycleSymbol];
        await owner.close();
        if (!directory) await fs.rm(root, { recursive: true, force: true });
      });
      return { owner, journal, root };
    }
    function assertUnclaimed(f, original) {
      assert.deepEqual(f.agent.inbox.nextTurn, [original]);
      assert.deepEqual(f.state().inFlight, []);
      assert.equal(f.counters.assembly, 0);
      assert.equal(f.log.filter(e => e.type === 'user/message').length, 0);
      assert.equal(f.log.filter(e => e.type === 'agent/inbox/spliced' && e.data.removedCount).length, 0);
    }
    test('OHOS actual background gate keeps input unclaimed until foreground, then admits once', async t => {
      const f = fixture(), original = message('background', true);
      const { owner } = await lifecycleFixture(t, f);
      await owner.observeHost({ revision: 1, foreground: false });
      f.agent.followup(original); await nextTurn();
      assertUnclaimed(f, original);
      await owner.observeHost({ revision: 2, foreground: true });
      await f.agent.whenIdle();
      assert.equal(f.counters.assembly, 1);
      assert.deepEqual(ids(f.log.filter(e => e.type === 'user/message').map(e => e.data)), ['background']);
      assert.deepEqual(f.agent.inbox.nextTurn, []);
      await owner.observeHost({ revision: 3, foreground: true });
      await nextTurn();
      assert.equal(f.counters.assembly, 1);
    });
    test('OHOS actual paused cancellation consumes pending input without resurrection on resume', async t => {
      const f = fixture(), original = message('cancelled', true);
      const { owner } = await lifecycleFixture(t, f);
      await owner.pause(); f.agent.followup(original); await nextTurn();
      assertUnclaimed(f, original);
      await owner.cancel(f.session.id); await f.agent.whenIdle();
      assert.deepEqual(f.agent.inbox.nextTurn, []);
      assert.equal(f.counters.assembly, 0);
      assert.deepEqual(cold(f.log).agent.inbox.nextTurn, []);
      await owner.resume(); await nextTurn();
      assert.equal(f.counters.assembly, 0, 'resume alone must not restart the cancelled turn');
      f.agent.followup(message('fresh')); await f.agent.whenIdle();
      assert.deepEqual(ids(f.log.filter(e => e.type === 'user/message').map(e => e.data)), ['fresh']);
    });
    test('OHOS actual closed gate reports its error before claiming input', async t => {
      const f = fixture(), original = message('closed');
      const { owner } = await lifecycleFixture(t, f);
      await owner.close(); f.agent.followup(original); await f.agent.whenIdle();
      assertUnclaimed(f, original);
      assert.equal(f.notifications.find(e => e.type === 'agent/error').data.error.code, 'ERR_OHOS_LIFECYCLE_CLOSED');
    });
    test('OHOS actual resumed preparation failure cold-recovers original input without duplication', async t => {
      const f = fixture({ prepareCall: async () => { throw Error('OHOS preparation failed'); } });
      const original = message('cold', true);
      const { owner } = await lifecycleFixture(t, f);
      await owner.pause(); f.agent.followup(original); await nextTurn(); assertUnclaimed(f, original);
      await owner.resume(); await f.agent.whenIdle();
      assert.equal(f.counters.preparation, 1);
      assert.deepEqual(f.agent.inbox.nextTurn, [original]);
      const recovered = cold(f.log);
      assert.deepEqual(recovered.agent.inbox.nextTurn, [original]);
      recovered.agent.wakeDriver(); await recovered.agent.whenIdle();
      assert.deepEqual(ids(recovered.log.filter(e => e.type === 'user/message').map(e => e.data)), ['cold']);
      assert.deepEqual(recovered.state().inFlight, []);
    });
  } catch (error) {
    // Node --test-isolation=none can otherwise lose a top-level import failure.
    test('OHOS lifecycle fixture dependencies initialize', () => { throw error; });
  }
}
