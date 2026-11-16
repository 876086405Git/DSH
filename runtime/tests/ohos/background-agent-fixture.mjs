// Exact classes extracted from the PATCHED candidate; no user sessions or live Host.
// INPUT_RECOVERY_MODULE=/tmp/.../candidate/node_modules/@deepseek-ai/dsh-agent-loop/lib/index.js \
// INPUT_RECOVERY_DEPS_PREFIX=/opt/dsh node --test runtime/tests/input-recovery.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { appendFile, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { resolve, join, isAbsolute, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';

const prefix = process.env.DSH_LIFECYCLE_TEST_PREFIX;
const modulePath = process.env.DSH_BACKGROUND_AGENT_BEFORE
  ?? (prefix && join(prefix, 'node_modules/@deepseek-ai/dsh-agent-loop/lib/index.js'));
if (!modulePath) throw Error('Set INPUT_RECOVERY_MODULE or DSH_PREFIX to the patched candidate');
const source = readFileSync(modulePath, 'utf8');
assert.equal(source.match(/^function ohosLifecycle\(\) \{[\s\S]*?^\}/gm)?.length, 1, 'unique actual lifecycle helper is required');
const deps = prefix;
if (!deps) throw Error('Set INPUT_RECOVERY_DEPS_PREFIX to an isolated or installed dependency tree');
const require = createRequire(resolve(deps, 'package.json'));
const { z } = require('zod');
const sessionApi = await import(pathToFileURL(join(deps, 'node_modules/@deepseek-ai/dsh-session/lib/index.js')));
const { AgentModel, modelSelectionProjectionDefinition } = await import(pathToFileURL(join(deps, 'node_modules/@deepseek-ai/dsh-agent/lib/index.js')));
const { ToolActivationError } = await import(pathToFileURL(join(deps, 'node_modules/@deepseek-ai/dsh-tools/lib/index.js')));
// The companion recall gates (runtime/patches/*-companion-recall-gates.diff)
// import dshGoRecall into the agent loop; the extracted classes need it in
// scope, as in runtime/tests/input-recovery.test.mjs. With no recall service
// registered on the context its gates let everything through. From the
// dependency tree, else from beside the candidate module.
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

export { fixture, message, modulePath, source };
