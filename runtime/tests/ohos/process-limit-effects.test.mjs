import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const runtimeURL = process.env.M4_PROCESS_RUNTIME
  ? pathToFileURL(process.env.M4_PROCESS_RUNTIME)
  : new URL('../../ohos/process/runtime.mjs', import.meta.url);
const { VirtualSubprocessRuntime } = await import(runtimeURL);

test('the real command budget returns 126, preserves completed writes, stops later writes, and releases the lane', { timeout: 30000 }, async t => {
  const root = await mkdtemp(join(tmpdir(), 'ohos-limit-effects-'));
  const work = join(root, 'work'), temporaryRoot = join(root, 'temporary');
  await Promise.all([mkdir(work), mkdir(temporaryRoot)]);
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot });
  t.after(async () => { await runtime.dispose(); await rm(root, { recursive: true, force: true }); });
  const run = command => runtime.spawn({ argv: ['bash', '-c', command], cwd: work,
    graceMs: 200, stdio: { stdin: 'ignore', stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } } });
  const start = performance.now();
  const limited = run("printf before > before; for ((i=0; i<100001; i++)); do :; done; printf after > after");
  const result = await limited.done;
  assert.equal(result.exitCode, 126);
  assert.match(limited.collected.stderr.readFrom(0).text, /too many commands executed \(>100000\)/);
  assert.equal(await readFile(join(work, 'before'), 'utf8'), 'before');
  await assert.rejects(stat(join(work, 'after')), { code: 'ENOENT' });
  assert.equal(runtime.live.size, 0);
  const followup = run('cat before');
  assert.equal((await followup.done).exitCode, 0);
  assert.equal(followup.collected.stdout.readFrom(0).text, 'before');
  assert.equal(runtime.live.size, 0);
  t.diagnostic(JSON.stringify({ elapsedMs: performance.now() - start, processPeakRSSKiB: process.resourceUsage().maxRSS,
    simulationMarker: globalThis[Symbol.for('dsh.go.ohos.sim')] === true,
    noWasm: typeof WebAssembly === 'undefined', scope: 'single Linux run; no target-device latency bound' }));
});
