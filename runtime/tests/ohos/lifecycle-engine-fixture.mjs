import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { openBoundaryJournal } from '../../ohos/lifecycle/journal.mjs';
import { lifecycleSymbol } from '../../ohos/lifecycle/coordinator.mjs';
const { BoundaryCoordinator } = await import(process.env.DSH_BACKGROUND_COORDINATOR_BEFORE ?? new URL('../../ohos/lifecycle/coordinator.mjs', import.meta.url));

const prefix = resolve(process.env.DSH_LIFECYCLE_TEST_PREFIX);
const require = createRequire(join(prefix, 'package.json'));
export const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
const [{ Context }, { SystemPrompt }, { ToolRuntime, defineTool, ToolBatchExecutionError }, { SessionStore, interruptedTurnClosers }, { AgentRegistry }, jsonl] = await Promise.all([
  'cordis', 'dsh-system-prompt', 'dsh-tools', 'dsh-session', 'dsh-agent', 'dsh-session-persistence-jsonl',
].map(load));
const { createAssistantMessage, LlmRuntime } = await load('dsh-llm');
const checkpointPolicy = await load('dsh-session-checkpoint-policy');
const { SessionProjectionRegistry } = await load('dsh-session-projection');

/** Load the real rc.1 executor; observer copies change only the append probe/import. */
export async function loadActualScheduler({ sourcePath, beforeResultAppend = '' } = {}) {
  if (sourcePath === undefined && !beforeResultAppend) return load('dsh-tool-executor-native');
  const pipelinePath = require.resolve('@deepseek-ai/dsh-tools/pipeline');
  let source = await fs.readFile(sourcePath ?? pipelinePath, 'utf8');
  assert(source.includes('async function executeToolBatch('), 'sourcePath must be an rc.1 public pipeline');
  if (beforeResultAppend) {
    const marker = source.includes('callSeqs[committed], durableSessionData);')
      ? '\t\t\tsettlement.commit(call.block, result, callSeqs[committed], durableSessionData);'
      : '\t\t\tsettlement.commit(call.block, result, callSeqs[committed]);';
    assert.equal(source.split(marker).length, 2);
    source = source.replace(marker, beforeResultAppend + '\n' + marker);
  }
  const executorPath = require.resolve('@deepseek-ai/dsh-tool-executor-native');
  const originalExecutor = await fs.readFile(executorPath, 'utf8');
  const importSpecifier = '"@deepseek-ai/dsh-tools/pipeline"';
  assert.equal(originalExecutor.split(importSpecifier).length, 2);
  const suffix = `.lifecycle-fixture-${randomUUID()}.mjs`;
  const exportedPipeline = join(dirname(pipelinePath), suffix);
  const exportedExecutor = join(dirname(executorPath), suffix);
  await fs.writeFile(exportedPipeline, source, { flag: 'wx' });
  try {
    await fs.writeFile(exportedExecutor, originalExecutor.replace(importSpecifier,
      JSON.stringify(pathToFileURL(exportedPipeline).href)), { flag: 'wx' });
    try { return await import(pathToFileURL(exportedExecutor)); }
    finally { await fs.unlink(exportedExecutor); }
  } finally { await fs.unlink(exportedPipeline); }
}

// Unit/engine fixture injects a trusted foreground snapshot explicitly. The
// product DSO integration separately exercises the unmodified native default.
export async function engineFixture({ root, bootId = randomUUID(), journalOptions, onStage, existing = false,
  sourcePath, beforeResultAppend, useLifecycle = true, flushSession, revalidateTransport, readHost = () => ({ version: 1, engineGeneration: 1, ownerGeneration: 1, revision: 1,
    grantGeneration: 0, nowMs: 1000, deadlineMs: 0, drainAtMs: 0, phase: 0, available: 1, foreground: 1, clockFailed: 0 }) } = {}) {
  assert(root);
  await fs.mkdir(join(root, 'workspace'), { recursive: true });
  const ctx = new Context();
  await ctx.plugin(SystemPrompt, {});
  await ctx.plugin(ToolRuntime, {});
  await ctx.plugin(SessionStore);
  await ctx.plugin(SessionProjectionRegistry);
  await ctx.plugin(AgentRegistry);
  await ctx.plugin(jsonl, { root: join(root, 'sessions'), compression: 'none' });
  await ctx.plugin(LlmRuntime);
  await ctx.plugin(checkpointPolicy);
  const removeSchedulerConfig = ctx.provide('agentLoop', { config: { maxParallelToolCalls: { get: () => 2 } } });
  const { NativeToolExecutor } = await loadActualScheduler({ sourcePath, beforeResultAppend });
  ctx.tools.setExecutor(new NativeToolExecutor(ctx, () => 2));
  const readEvents = async (id, from = 0, to) => {
    const handle = await ctx.sessionPersistence.open(id, 'read');
    try { return (await handle.read(from, to)).events; }
    finally { await handle.close(); }
  };
  const owners = new Map(), attachments = [], handles = [];
  const journal = await openBoundaryJournal({ directory: join(root, 'boundary'),
    lockExclusive: process._linkedBinding('dsh_ohos_publication').lockExclusive, ...journalOptions });
  const coordinator = new BoundaryCoordinator({ journal, bootId,
    flushSession: flushSession ?? (session => ctx.sessions.flush(session)), readEvents,
    resolveAgent: id => owners.get(id), onStage, revalidateTransport, readHost });
  if (useLifecycle) {
    assert.equal(globalThis[lifecycleSymbol], undefined);
    globalThis[lifecycleSymbol] = coordinator;
  }
  const create = async (id = 'session-A') => {
    const session = ctx.sessions.prepare(id, { meta: { cwd: join(root, 'workspace') } });
    const handle = await ctx.sessionPersistence.create(session.header); handles.push(handle);
    attachments.push(ctx.sessions.enter(session)); ctx.sessions.announce(session);
    session.append('turn/start', { turn: 1 });
    session.append('step/start', { turn: 1, step: 1 });
    const signal = new AbortController();
    let active = Promise.resolve();
    const agent = { id, ctx, session, status: 'idle', inject() {},
      cancel(reason) { signal.abort(reason); }, whenIdle: () => active.catch(() => {}) };
    const run = (calls, { turn = 1, step = 1 } = {}) => {
      agent.status = 'running';
      const blocks = calls.map((call, index) => ({ type: 'tool-call', id: call.id ?? `call-${index}`, name: call.name ?? 'effect',
        arguments: JSON.stringify(call.arguments ?? {}) }));
      session.append('assistant/message', { turn, step, stream: [], message: createAssistantMessage({ content: blocks,
        source: { provider: 'lifecycle-fixture', model: 'actual-scheduler-fixture' } }) }, { surfaceOp: 'append' });
      active = Promise.resolve(ctx.agents.withInitiator(agent, () => ctx.tools.execute({
        calls: blocks, signal: signal.signal, agent, log: { turn, step }, maxParallelToolCalls: 2,
      })))
        // AgentLoop exposes the underlying failure after accepting partial context.
        // These fixture tools produce no additional context; keep original error assertions.
        .catch(error => { if (error instanceof ToolBatchExecutionError) throw error.cause; throw error; })
        .finally(() => { agent.status = 'idle'; });
      return active;
    };
    owners.set(id, agent);
    return { agent, session, handle, signal, run };
  };
  const register = (name, execute, options = {}) => ctx.tools.register(defineTool({
    name, description: 'Real lifecycle fixture tool', parameters: { label: { type: 'string' } },
    output: {
      schema: { type: 'array', items: { type: 'object', additionalProperties: false,
        properties: { type: { type: 'string', const: 'text', required: true }, text: { type: 'string', required: true } } } },
      render: (_args, value) => value,
    },
    execute, ...options,
  }));
  const recover = async (id = 'session-A', { originalOnly = false, onFlushed, publicFactory = false } = {}) => {
    if (publicFactory) {
      const persisted = await readEvents(id);
      const originalClosers = interruptedTurnClosers(persisted);
      await removeSchedulerConfig();
      const { AgentLoop } = await load('dsh-agent-loop');
      await ctx.plugin(AgentLoop, { agents: [], maxParallelToolCalls: 2 });
      const restored = await ctx.agents.resume({ resumeSessionId: id });
      owners.set(id, restored.agent);
      await restored.agent.whenIdle();
      const events = await readEvents(id);
      return { header: restored.agent.session.header, events, originalClosers,
        closers: events.slice(persisted.length), status: coordinator.status(id), publicAgentFactoryResume: true };
    }
    const handle = await ctx.sessionPersistence.open(id, 'write'); handles.push(handle);
    const persisted = (await handle.read(0)).events;
    const originalClosers = interruptedTurnClosers(persisted);
    const closers = originalOnly ? originalClosers : await coordinator.reconcileCold(id, persisted, originalClosers);
    if (closers.length) await handle.append(closers);
    await handle.flush();
    const events = (await handle.read(0)).events;
    await onFlushed?.(events);
    const status = originalOnly ? null : await coordinator.recoveredCommitted(id, events);
    return { header: handle.header, events, originalClosers, closers, status };
  };
  return { root, ctx, journal, coordinator, create, register, readEvents, recover,
    async close() {
      await coordinator.close();
      if (globalThis[lifecycleSymbol] === coordinator) delete globalThis[lifecycleSymbol];
      for (const detach of attachments) detach();
      for (const handle of handles) await handle.close();
      await ctx.fiber.dispose();
    } };
}
