import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join, dirname, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
import { setTimeout as wait } from 'node:timers/promises';
import * as lifecyclePlugin from '../../ohos/lifecycle/index.mjs';

const require = createRequire(join(resolve(process.env.DSH_LIFECYCLE_TEST_PREFIX), 'package.json'));
const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
const [{ Context }, { SystemPrompt }, { ToolRuntime, defineContentToolFixture }, { SessionStore }, { AgentRegistry }, { createAssistantMessage }, timeout] = await Promise.all([
  'cordis', 'dsh-system-prompt', 'dsh-tools', 'dsh-session', 'dsh-agent', 'dsh-llm', 'dsh-timeout',
].map(load));
async function scheduler(path) {
  const source = await fs.readFile(path, 'utf8');
  const temp = join(dirname(require.resolve('@deepseek-ai/dsh-agent-loop')), '.lifecycle-platform-' + randomUUID() + '.mjs');
  await fs.writeFile(temp, source + '\nexport { executeToolCalls };\n');
  try { return (await import(pathToFileURL(temp))).executeToolCalls; }
  finally { await fs.unlink(temp); }
}
const original = await scheduler(resolve(process.env.DSH_LIFECYCLE_BASE_AGENT_LOOP));
const changed = await scheduler(require.resolve('@deepseek-ai/dsh-agent-loop'));
const key = Symbol.for('dsh.go.ohos.lifecycle');
const platform = Object.getOwnPropertyDescriptor(process, 'platform');
assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], undefined, 'platform test must run without the simulation marker');
function normalized(value) {
  if (Array.isArray(value)) return value.map(normalized);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).filter(([key]) => key !== 'time' && key !== 'id').map(([key, child]) => [key, normalized(child)]));
}
async function run(execute) {
  const ctx = new Context(), events = [];
  await ctx.plugin(SystemPrompt, {}); await ctx.plugin(ToolRuntime, { mode: 'native' });
  await ctx.plugin(SessionStore); await ctx.plugin(AgentRegistry);
  ctx.provide('agentLoop', { config: { maxParallelToolCalls: { get: () => 2 } } });
  ctx.on('session/event', (_session, event) => events.push(event));
  ctx.tools.register(defineContentToolFixture({ name: 'echo', description: 'platform path', parameters: {},
    execute: async () => [{ type: 'text', text: 'original behavior 中文' }] }));
  const session = ctx.sessions.create('platform-session', { meta: { cwd: process.cwd() } });
  const agent = { id: session.id, ctx, session, inject() {} };
  const calls = [{ type: 'tool-call', id: 'call', name: 'echo', arguments: '{}' }];
  session.append('turn/start', { turn: 1 }); session.append('step/start', { turn: 1, step: 1 });
  session.append('assistant/message', { turn: 1, step: 1, stream: [], message: createAssistantMessage({ content: calls, source: { provider: 'fixture', model: 'fixture' } }) }, { surfaceOp: 'append' });
  try { await ctx.agents.withInitiator(agent, () => execute(ctx, 1, 1, calls, new AbortController().signal, () => {})); return normalized(events); }
  finally { await ctx.fiber.dispose(); }
}
for (const value of ['linux', 'android']) test(`${value}: environment string cannot install lifecycle; exact scheduler trace and wall timeout stay on original path`, async () => {
  const previousEnv = process.env.DSH_GO_OHOS_SIM;
  Object.defineProperty(process, 'platform', { ...platform, value });
  process.env.DSH_GO_OHOS_SIM = '1';
  globalThis[key] = new Proxy({}, { get() { throw new Error('non-OH path consulted lifecycle'); } });
  try {
    await lifecyclePlugin.apply(new Proxy({}, { get() { throw new Error('non-OH path touched a service'); } }));
    assert.deepEqual(await run(changed), await run(original));
    const d = timeout.deadline(undefined, 20, 'TOOL_TIMEOUT');
    await wait(50); assert.equal(timeout.timeoutOf(d.signal)?.code, 'TOOL_TIMEOUT'); d[Symbol.dispose]();
  } finally {
    delete globalThis[key]; Object.defineProperty(process, 'platform', platform);
    if (previousEnv === undefined) delete process.env.DSH_GO_OHOS_SIM; else process.env.DSH_GO_OHOS_SIM = previousEnv;
  }
});
