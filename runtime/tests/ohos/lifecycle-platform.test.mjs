import test from 'node:test';
import assert from 'node:assert/strict';
import { join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { setTimeout as wait } from 'node:timers/promises';
import * as lifecyclePlugin from '../../ohos/lifecycle/index.mjs';
import { loadActualScheduler } from './lifecycle-engine-fixture.mjs';

const require = createRequire(join(resolve(process.env.DSH_LIFECYCLE_TEST_PREFIX), 'package.json'));
const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
const [{ Context }, { SystemPrompt }, { ToolRuntime, defineTool }, { SessionStore }, { AgentRegistry }, { createAssistantMessage }, timeout, { SessionProjectionRegistry }] = await Promise.all([
  'cordis', 'dsh-system-prompt', 'dsh-tools', 'dsh-session', 'dsh-agent', 'dsh-llm', 'dsh-timeout', 'dsh-session-projection',
].map(load));
// Same real executor and sibling dependencies, different public pipeline bytes.
const { NativeToolExecutor: original } = await loadActualScheduler({ sourcePath: resolve(process.env.DSH_LIFECYCLE_BASE_PIPELINE) });
const { NativeToolExecutor: changed } = await loadActualScheduler();
const key = Symbol.for('dsh.go.ohos.lifecycle');
const platform = Object.getOwnPropertyDescriptor(process, 'platform');
assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], undefined, 'platform test must run without the simulation marker');
function normalized(value) {
  if (Array.isArray(value)) return value.map(normalized);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).filter(([key]) => key !== 'time' && key !== 'id').map(([key, child]) => [key, normalized(child)]));
}
async function run(NativeToolExecutor) {
  const ctx = new Context(), events = [];
  await ctx.plugin(SystemPrompt, {}); await ctx.plugin(ToolRuntime, {});
  await ctx.plugin(SessionStore); await ctx.plugin(SessionProjectionRegistry); await ctx.plugin(AgentRegistry);
  ctx.tools.setExecutor(new NativeToolExecutor(ctx, () => 2));
  ctx.on('session/event', (_session, event) => events.push(event));
  ctx.tools.register(defineTool({ name: 'echo', description: 'platform path', parameters: {},
    output: {
      schema: { type: 'array', items: { type: 'object', additionalProperties: false,
        properties: { type: { type: 'string', const: 'text', required: true }, text: { type: 'string', required: true } } } },
      render: (_args, value) => value,
    },
    execute: async () => [{ type: 'text', text: 'original behavior 中文' }] }));
  const session = ctx.sessions.create('platform-session', { meta: { cwd: process.cwd() } });
  const agent = { id: session.id, ctx, session, inject() {} };
  const calls = [{ type: 'tool-call', id: 'call', name: 'echo', arguments: '{}' }];
  session.append('turn/start', { turn: 1 }); session.append('step/start', { turn: 1, step: 1 });
  session.append('assistant/message', { turn: 1, step: 1, stream: [], message: createAssistantMessage({ content: calls, source: { provider: 'fixture', model: 'fixture' } }) }, { surfaceOp: 'append' });
  try {
    const result = await ctx.agents.withInitiator(agent, () => ctx.tools.execute({
      calls, signal: new AbortController().signal, agent, log: { turn: 1, step: 1 }, maxParallelToolCalls: 2,
    }));
    assert.equal(result.results.length, 1);
    assert.equal(result.results[0].result.content[0].text, 'original behavior 中文');
    assert.equal(events.filter(event => event.type === 'tool/call').length, 1);
    assert.equal(events.filter(event => event.type === 'tool/result').length, 1);
    return normalized(events);
  }
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
