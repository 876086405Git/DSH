// Exact pinned-engine bridge. A provider name or client-supplied session id is
// never enough to certify a recall route. Unrecognized compositions stay off.
import { createRequire } from 'node:module';
import { isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';
import { fields } from './schema.js';
import { canonicalUuid, recallError, validRecallSessionId } from './recall-schema.js';

const RECORD = 'plugin:dsh-go/companion-recall';
const FULL_PRESET = 'dsh-go-companion-full';
const CONFIG_RECORDS = new Set(['agent-preset/selected', 'model/selection',
  'subagent/model-selection-policy',
  'permission/preset', 'approval/policy', 'sandbox/mode', 'plan/mode']);
const unavailable = () => recallError(503, 'adapter-unavailable', 'Automatic recall is unavailable for this engine route');
const denied = (reason) => ({ supported: false, reason });
const sameList = (left, right) => left.length === right.length && left.every((value, index) => value === right[index]);
const liveFiber = (fiber) => fiber?.state === 2 && fiber.uid !== null && fiber.uid !== undefined;

async function loadEngine(ctx) {
  const anchor = ctx.get('profileContext')?.installAnchor;
  if (typeof anchor !== 'string' || !isAbsolute(anchor)) throw unavailable();
  const require = createRequire(anchor);
  const names = ['@deepseek-ai/cordis', '@deepseek-ai/dsh-session', '@deepseek-ai/dsh-scope',
    '@deepseek-ai/dsh-llm', '@deepseek-ai/dsh-llm-deepseek', '@deepseek-ai/dsh-tool-executor-native',
    '@deepseek-ai/dsh-tools/pipeline', '@deepseek-ai/dsh-permission-presets',
    '@deepseek-ai/dsh-session-title-llm', '@deepseek-ai/dsh-compaction-basic',
    '@deepseek-ai/dsh-subagent-fork-in-process'];
  const [cordis, session, scope, llm, deepseek, native, pipeline, permissions, title, compaction, fork] =
    await Promise.all(names.map((name) => import(pathToFileURL(require.resolve(name)).href)));
  if (typeof session.Session !== 'function' || typeof session.appendPluginRecord !== 'function'
    || typeof scope.scopeOf !== 'function' || typeof scope.scopeChainOf !== 'function'
    || llm.dshGoRecall?.version !== 1 || typeof llm.dshGoRecall.isDriver !== 'function'
    || typeof deepseek.DeepSeekAdapter !== 'function' || typeof native.NativeToolExecutor !== 'function'
    || typeof pipeline.ToolExecutionPipeline !== 'function' || typeof permissions.AUTO_PRESET !== 'string'
    || !cordis.symbols?.original || [title, compaction, fork].some((module) => module.dshGoRecallVersion !== 1)) throw unavailable();
  return { ...session, ...scope, dshGoRecall: llm.dshGoRecall,
    DeepSeekAdapter: deepseek.DeepSeekAdapter, NativeToolExecutor: native.NativeToolExecutor,
    ToolExecutionPipeline: pipeline.ToolExecutionPipeline, AUTO_PRESET: permissions.AUTO_PRESET,
    original: cordis.symbols.original };
}

/** Uses the current installation anchor; never imports another Host's engine. */
export async function createRecallEngineAdapter(ctx, { contexts } = {}) {
  if (typeof contexts?.registerContext !== 'function' || typeof contexts?.current !== 'function') throw unavailable();
  let closed = false;
  let projection;
  let marked;
  let engine;
  const records = new WeakMap();
  const sessionOwners = new WeakMap();
  const coordinator = () => ctx.get('dshGoCompanionRecall');
  const retire = (record, reason) => {
    if (!record) return;
    record.invalidated = true;
    if (marked === record) marked = undefined;
    coordinator()?.retireAgent(record.agent, reason);
  };
  // Register disposal BEFORE either module loading or projection backfill awaits.
  ctx.effect(() => () => {
    closed = true;
    if (marked) marked.invalidated = true;
    marked = undefined;
    coordinator()?.retireAll('adapter-disposed');
    return projection?.dispose();
  }, 'dsh-go-bridge: recall engine owner');
  engine = await loadEngine(ctx);
  if (closed) throw unavailable();
  const projectionRegistry = ctx.get('sessionProjections');
  if (typeof projectionRegistry?.register !== 'function') throw unavailable();
  const definition = {
    // v1 checkpoints treated C740 persona records as clean. Refold their full
    // history under this stricter policy; an old eligible:true is not evidence.
    key: 'dshGoCompanionRecallClean', stateVersion: 2,
    stateSchema: { parse(value) {
      if (!fields(value, ['v', 'sessionId', 'eligible']) || value.v !== 1
        || !validRecallSessionId(value.sessionId) || typeof value.eligible !== 'boolean') throw unavailable();
      return value;
    } },
    init: (header) => ({ v: 1, sessionId: header.id,
      eligible: header.isSeeded === false && header.parentSession === undefined }),
    apply(state, event) {
      if (!state.eligible || CONFIG_RECORDS.has(event.type)) return state;
      // Persona/profile is owned by the existing context provider. Legacy
      // C740 plugin records and unknown history do not make a clean session.
      return { ...state, eligible: false };
    },
  };
  projection = await projectionRegistry.register(definition);
  if (closed) { await projection.dispose(); throw unavailable(); }

  const originals = new Map([
    [engine.DeepSeekAdapter, ['prepareCall', 'stream', 'generate', 'request', 'connection']],
    [engine.NativeToolExecutor, ['describe', 'execute']],
    [engine.ToolExecutionPipeline, ['prepare', 'dispatch', 'dispatchToolBody']],
  ].map(([type, names]) => [type, Object.fromEntries(names.map((key) => [key, type.prototype[key]]))]));
  function exact(value, type) {
    const methods = originals.get(type);
    return value != null && Object.getPrototypeOf(value) === type.prototype && value.dshGoRecallVersion === 1
      && Object.entries(methods).every(([key, method]) => typeof method === 'function'
        && type.prototype[key] === method && value[key] === method);
  }
  const raw = (value) => value?.[engine.original] ?? value;
  function services(from = ctx) {
    return Object.fromEntries(['agentLoop', 'llm', 'systemPrompt', 'agents', 'sessions', 'agentPresets',
      'tools', 'permissionPresets', 'sessionController', 'sessionProjections', 'dshGoCompanionRecall']
      .map((name) => [name, from.get(name)]));
  }
  function baseCapability(from = ctx) {
    if (closed || !liveFiber(ctx.fiber) || !projection) return denied('adapter-unavailable');
    const service = services(from);
    if (['agentLoop', 'llm', 'systemPrompt'].some((name) => service[name]?.dshGoRecallVersion !== 1
      || !liveFiber(raw(service[name])?.ctx?.fiber))) return denied('engine-unpatched');
    if (typeof service.agents?.get !== 'function' || typeof service.sessions?.get !== 'function'
      || typeof service.agentPresets?.presetForSession !== 'function' || typeof service.agentPresets?.composedPreset !== 'function'
      || typeof service.tools?.selectExecutor !== 'function' || typeof service.llm?.registration !== 'function'
      || typeof service.permissionPresets?.current !== 'function' || typeof service.sessionController?.resolveAgent !== 'function'
      || raw(service.dshGoCompanionRecall)?.registerContext !== contexts.registerContext
      || raw(service.sessionProjections) !== raw(projectionRegistry)) return denied('engine-unavailable');
    return { supported: true, reason: null, service };
  }
  function inspect(agent, scope, previous) {
    if (!agent || scope !== agent || !engine.dshGoRecall.isDriver(agent)
      || agent.dshGoDeleting || !liveFiber(agent.ctx?.fiber) || !liveFiber(agent.loopCtx?.fiber)) return denied('agent-unavailable');
    const base = baseCapability(agent.loopCtx);
    if (!base.supported) return base;
    const { service } = base;
    if (service.agents.get(agent.id) !== agent || service.sessions.get(agent.id) !== agent.session
      || !(agent.session instanceof engine.Session) || agent.session.id !== agent.id
      || agent.session.dshGoRecallVersion !== 1 || engine.scopeOf(agent.ctx) !== agent) return denied('agent-changed');
    if (service.agentPresets.presetForSession(agent.session) !== FULL_PRESET
      || service.agentPresets.composedPreset(agent.ctx) !== FULL_PRESET) return denied('wrong-preset');
    const chain = engine.scopeChainOf(agent);
    const contextMount = contexts.current(chain, engine.scopeOf, raw(service.systemPrompt), raw);
    if (!contextMount) return denied('context-unmounted');
    const permission = service.permissionPresets.current(agent.session);
    if (typeof permission !== 'string' || permission.length === 0) return denied('permissions-unavailable');
    if (permission === engine.AUTO_PRESET) return denied('auto-review-unsupported');
    const selection = agent.model.current();
    if (!selection || typeof selection.provider !== 'string' || !selection.provider
      || typeof selection.model !== 'string' || !selection.model) return denied('provider-unavailable');
    const registration = service.llm.registration(selection.provider);
    if (!exact(registration.adapter, engine.DeepSeekAdapter)) return denied('provider-unsupported');
    const executor = service.tools.selectExecutor(agent);
    if (!exact(executor, engine.NativeToolExecutor) || !exact(executor.pipeline, engine.ToolExecutionPipeline)
      || !liveFiber(executor.pipeline.ctx?.fiber)) return denied('executor-unsupported');
    if (previous && (previous.invalidated || previous.session !== agent.session || previous.ctx !== agent.ctx
      || previous.loopCtx !== agent.loopCtx || previous.registration !== registration || previous.executor !== executor
      || previous.contextMount !== contextMount
      || !sameList(previous.chain, chain)
      || Object.keys(service).some((key) => raw(service[key]) !== previous.service[key]))) return denied('engine-changed');
    return { supported: true, reason: null, agent, scope, session: agent.session, ctx: agent.ctx, loopCtx: agent.loopCtx,
      chain: [...chain], contextMount, registration, executor,
      service: Object.fromEntries(Object.entries(service).map(([key, value]) => [key, raw(value)])) };
  }
  function current(target) {
    const record = target?.agent && records.get(target.agent);
    if (!record || record.invalidated) return false;
    try {
      const result = inspect(target.agent, target.scope, record);
      if (result.supported) return true;
    } catch { /* The current runtime identity can no longer be proved. */ }
    retire(record, 'engine-changed');
    return false;
  }
  function clean(target) {
    if (!current(target)) return false;
    try {
      const { agent } = target;
      const state = projection.stateOf(agent.session);
      const history = agent.session.toolHistory();
      return state.sessionId === agent.id && state.eligible && !agent.session.dshGoRecallHistory
        && agent.status === 'idle' && agent.phase.kind === 'idle' && agent.session.inheritedEventCount === 0
        && agent.inbox.nextTurn.length === 0 && agent.inbox.nextStep.length === 0 && agent.inbox.claimed.length === 0
        && agent.session.requestHeader() === undefined && history.tools.length === 0 && history.updates.length === 0;
    } catch { return false; }
  }
  ctx.on('agent/disposed', ({ agent }) => retire(records.get(agent), 'agent-disposed'), { global: true });
  ctx.on('session/disposed', (session) => retire(sessionOwners.get(session), 'session-disposed'), { global: true });
  ctx.on('internal/status', (fiber) => {
    if (!marked || fiber.state === 2) return;
    const key = engine.scopeOf(fiber.ctx);
    if (key !== undefined && marked.chain.includes(key)
      || Object.values(marked.service).some((service) => service?.ctx?.fiber === fiber)) retire(marked, 'engine-changed');
  }, { global: true });
  if (closed) throw unavailable();
  return Object.freeze({
    version: 1,
    capability(target) {
      try {
        const result = target ? inspect(target.agent, target.scope, records.get(target.agent)) : baseCapability();
        return result.supported ? { supported: true, reason: null, coverage: {
          engineProtocol: 1, provider: 'pinned-direct-deepseek', executor: 'pinned-native', auxiliary: 'denied',
        } } : denied(result.reason);
      } catch { return denied('engine-unavailable'); }
    },
    async resolveTarget(sessionId) {
      if (!validRecallSessionId(sessionId) || !baseCapability().supported) throw unavailable();
      const controller = ctx.get('sessionController');
      const resolved = await controller.resolveAgent(sessionId);
      if (closed || resolved?.error !== undefined || !resolved?.agent || resolved.agent.id !== sessionId
        || raw(ctx.get('sessionController')) !== raw(controller)) throw unavailable();
      const agent = resolved.agent;
      const previous = records.get(agent);
      const result = inspect(agent, agent, previous);
      if (!result.supported) { retire(previous, 'engine-changed'); throw unavailable(); }
      if (!previous) {
        const record = { ...result, invalidated: false };
        records.set(agent, record); sessionOwners.set(agent.session, record);
      }
      return { agent, scope: agent };
    },
    isCurrent: current,
    isClean: clean,
    markBound(target) {
      if (!clean(target) || target.sessionId !== target.agent.id || !canonicalUuid(target.storeId)) throw unavailable();
      marked = records.get(target.agent);
      engine.appendPluginRecord(target.agent.session, RECORD, { v: 1, sessionId: target.sessionId, storeId: target.storeId });
    },
    async stop({ agent, scope }) {
      const record = agent && records.get(agent);
      if (!record || scope !== agent || !engine.dshGoRecall.isDriver(agent)) return;
      record.invalidated = true;
      if (marked === record) marked = undefined;
      agent.cancel({ kind: 'user' }, { keepInbox: true });
      await agent.whenIdle();
    },
  });
}
