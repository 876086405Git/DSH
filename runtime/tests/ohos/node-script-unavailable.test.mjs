// Run without either OHOS product preload or node-worker-preload in execArgv.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';
import { nodeScriptAvailable } from '../../ohos/process/node-script.mjs';

test('without inherited preload the real runtime rejects Node and never runs its script', async t => {
  assert.equal(nodeScriptAvailable(), false);
  const work = await mkdtemp('/tmp/ohos-node-unavailable-');
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work] });
  t.after(async () => { await runtime.dispose(); await rm(work, { recursive: true, force: true }); });
  assert.equal(runtime.capabilities.nodeScripts, 'none'); assert.equal(runtime.capabilities.commands.includes('node'), false);
  await assert.rejects(runtime.resolveExecutable('node', {}));
  await writeFile(join(work, 'script.mjs'), "import{writeFileSync}from'node:fs';writeFileSync('must-not-exist','BAD');");
  for (const argv of [['node', 'script.mjs'], ['bash', '-c', 'node script.mjs']]) {
    const handle = runtime.spawn({ argv, cwd: work, graceMs: 200,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 1024 }, stderr: { maxBytes: 4096 } } });
    assert.equal((await handle.done).exitCode, 127); assert.equal(await handle.waitForExit(), true);
    assert.match(handle.collected.stderr.readFrom(0).text, /ERR_OHOS_NODE_PRELOAD_REQUIRED|这个命令在鸿蒙本机不可用/);
  }
  assert.equal(await stat(join(work, 'must-not-exist')).then(() => true, () => false), false);
  assert.match(await readFile(join(work, 'script.mjs'), 'utf8'), /must-not-exist/);
});

test('a dynamically imported marker alone cannot advertise an inherited Worker preloader', async () => {
  await import('../../ohos/process/node-worker-preload.mjs');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.nodeWorker.preload')], 1);
  assert.equal(nodeScriptAvailable(), false);
});
