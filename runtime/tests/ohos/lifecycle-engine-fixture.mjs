import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { openBoundaryJournal } from '../../ohos/lifecycle/journal.mjs';
import { BoundaryCoordinator, lifecycleSymbol } from '../../ohos/lifecycle/coordinator.mjs';

const prefix = resolve(process.env.DSH_LIFECYCLE_TEST_PREFIX);
const require = createRequire(join(prefix, 'package.json'));
export const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
const [{ Context }, { SystemPrompt }, { ToolRuntime, defineContentToolFixture }, { SessionStore, interruptedTurnClosers }, { AgentRegistry }, jsonl] = await Promise.all([
  'cordis', 'dsh-system-prompt', 'dsh-tools', 'dsh-session', 'dsh-agent', 'dsh-session-persistence-jsonl',
].map(load));
const { createAssistantMessage, LlmRuntime } = await load('dsh-llm');
const checkpointPolicy = await load('dsh-session-checkpoint-policy');

/** Export the exact pinned scheduler in a private copy; no algorithm replacement. */
export async function loadActualScheduler({ sourcePath, beforeResultAppend = '' } = {}) {
  const path = sourcePath ?? require.resolve('@deepseek-ai/dsh-agent-loop');
  let source = await fs.readFile(path, 'utf8');
  assert(source.includes('async function executeToolCalls('));
  if (beforeResultAppend) {
    const marker = source.includes('callSeqs[committed], durableSessionData);')
      ? '\t\t\tappendToolResult(session, turn, step, call.block, result, callSeqs[committed], durableSessionData);'
      : '\t\t\tappendToolResult(session, turn, step, call.block, result, callSeqs[committed]);';
    assert.equal(source.split(marker).length, 2);
    source = source.replace(marker, beforeResultAppend + '\n' + marker);
  }
  const exported = join(dirname(require.resolve('@deepseek-ai/dsh-agent-loop')), `.lifecycle-fixture-${randomUUID()}.mjs`);
  await fs.writeFile(exported, source + '\nexport { executeToolCalls as fixtureExecuteToolCalls };\n', { flag: 'wx' });
  try { return await import(pathToFileURL(exported)); }
  finally { await fs.unlink(exported); }
}

export async function engineFixture({ root, bootId = randomUUID(), journalOptions, onStage, existing = false,
  sourcePath, beforeResultAppend, useLifecycle = true, flushSession, revalidateTransport } = {}) {
  assert(root);
  await fs.mkdir(join(root, 'workspace'), { recursive: true });
  const ctx = new Context();
  await ctx.plugin(SystemPrompt, {});
  await ctx.plugin(ToolRuntime, { mode: 'native' });
  await ctx.plugin(SessionStore);
  await ctx.plugin(AgentRegistry);
  await ctx.plugin(jsonl, { root: join(root, 'sessions'), compression: 'none' });
  await ctx.plugin(LlmRuntime);
  await ctx.plugin(checkpointPolicy);
  const removeSchedulerConfig = ctx.provide('agentLoop', { config: { maxParallelToolCalls: { get: () => 2 } } });
  const { fixtureExecuteToolCalls } = await loadActualScheduler({ sourcePath, beforeResultAppend });
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
    resolveAgent: id => owners.get(id), onStage, revalidateTransport });
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
      active = Promise.resolve(ctx.agents.withInitiator(agent, () => fixtureExecuteToolCalls(ctx, turn, step,
        blocks, signal.signal, () => {})))
        .finally(() => { agent.status = 'idle'; });
      return active;
    };
    owners.set(id, agent);
    return { agent, session, handle, signal, run };
  };
  const register = (name, execute, options = {}) => ctx.tools.register(defineContentToolFixture({
    name, description: 'Real lifecycle fixture tool', parameters: { label: { type: 'string' } },
    execute, ...options,
  }));
  const recover = async (id = 'session-A', { originalOnly = false, onFlushed, publicFactory = false } = {}) => {
    if (publicFactory) {
      const persisted = await readEvents(id);
      const originalClosers = interruptedTurnClosers(persisted);
      await removeSchedulerConfig();
      const [{ AgentLoop }, { SessionProjectionRegistry }] = await Promise.all(['dsh-agent-loop', 'dsh-session-projection'].map(load));
      await ctx.plugin(SessionProjectionRegistry);
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
