import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { performance } from 'node:perf_hooks';
import OhSubprocessRuntime from '../../ohos/process/index.mjs';
import { ActiveBudgetClock } from '../../ohos/lifecycle/budget.mjs';

const require = createRequire(join(resolve(process.env.DSH_LIFECYCLE_TEST_PREFIX), 'package.json'));
const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
const [{ Context }, { SystemPrompt }, { ToolRuntime }, { LocalBashExecutor }, { Session }, { SessionProjectionRegistry },
  { LocalFileSystem }, { WorkingDirectoryService }, timeoutPolicy, search, nativeExecutor] = await Promise.all([
  'cordis', 'dsh-system-prompt', 'dsh-tools', 'dsh-bash-local', 'dsh-session', 'dsh-session-projection',
  'dsh-fs-local', 'dsh-working-directory', 'dsh-tool-call-timeout-policy', 'dsh-tool-fs-search', 'dsh-tool-executor-native',
].map(load));
const key = Symbol.for('dsh.go.ohos.lifecycle');
async function fixture(t, enabled) {
  const root = await fs.mkdtemp(join(tmpdir(), 'lifecycle-tool-budget-'));
  const work = join(root, 'work'), temp = join(root, 'temp');
  await fs.mkdir(work); await fs.mkdir(temp);
  await fs.writeFile(join(work, '中文.txt'), 'needle 中文\n');
  const ctx = new Context(), clock = new ActiveBudgetClock('actual-tool-budget');
  clock.pause();
  if (enabled) { assert.equal(globalThis[key], undefined); globalThis[key] = { clock }; }
  await ctx.plugin(SystemPrompt, {}); await ctx.plugin(ToolRuntime, {});
  await ctx.plugin(nativeExecutor);
  await ctx.plugin(SessionProjectionRegistry);
  await ctx.plugin(LocalFileSystem, { cwd: work }); await ctx.plugin(WorkingDirectoryService, { defaultDirectory: work });
  await ctx.plugin(OhSubprocessRuntime, { workspaceRoots: [work], temporaryRoot: temp });
  await ctx.plugin(LocalBashExecutor, { cwd: work, timeoutMs: 80, maxTimeoutMs: 30000, maxOutputBytes: 65536, maxSpillBytes: 1048576, graceMs: 100 });
  await ctx.plugin(timeoutPolicy);
  await ctx.plugin(search, { sampleOverCapGlobResults: false, timeoutMs: 80 });
  const session = Session.create('tool-budget-session', undefined, { version: 4, id: 'tool-budget-session', createdAt: Date.now(), isSeeded: false, cwd: work });
  session.append('turn/start', { turn: 1 });
  const agent = { id: session.id, session, ctx, inject() {} };
  t.after(async () => { await ctx.fiber.dispose(); clock.dispose(); if (enabled) delete globalThis[key]; await fs.rm(root, { recursive: true, force: true }); });
  return { ctx, clock, work, agent };
}

for (const enabled of [false, true]) test(`actual LocalBashExecutor BASH_TIMEOUT ${enabled ? 'uses logical pause' : 'original wall-time control times out'}`, async t => {
  const { ctx, clock, work } = await fixture(t, enabled);
  const start = performance.now();
  const handle = await ctx.shell.execute(ctx.shell.resolve({ command: 'sleep 0.2; printf complete > marker; cat marker' }));
  const result = await handle.result();
  assert.equal(result.timedOut, !enabled);
  assert.equal(ctx.subprocess.backend.live.size, 0);
  assert.equal(clock.pendingCount, 0);
  if (enabled) {
    assert(performance.now() - start > 80);
    assert.equal(result.stdout.text, 'complete', JSON.stringify(result)); assert.equal(result.exitCode, 0);
    assert.equal(await fs.readFile(join(work, 'marker'), 'utf8'), 'complete');
  } else assert.equal(await fs.stat(join(work, 'marker')).then(() => true, () => false), false);
});

for (const enabled of [false, true]) test(`actual fs-search and timeout policy TOOL_TIMEOUT ${enabled ? 'uses the same logical clock' : 'original wall-time control times out'}`, async t => {
  const { ctx, clock, agent } = await fixture(t, enabled);
  assert.equal(ctx.tools.get('grep').timeoutMs, 80);
  const batch = await ctx.tools.execute({
    calls: [{ type: 'tool-call', name: 'grep', id: 'grep-budget', arguments: JSON.stringify({ pattern: 'needle', path: '中文.txt' }) }],
    agent, signal: new AbortController().signal,
  });
  assert.equal(batch.results.length, 1);
  assert.equal(batch.results[0].callId, 'grep-budget');
  const result = batch.results[0].result;
  assert.equal(result.isError, !enabled, JSON.stringify(result));
  if (enabled) assert.match(JSON.stringify(result), /needle 中文/);
  else assert.equal(result.error.info.code, 'TOOL_TIMEOUT');
  assert.equal(ctx.subprocess.backend.live.size, 0); assert.equal(clock.pendingCount, 0);
});
