import test from 'node:test';
import assert from 'node:assert/strict';
import { createHook } from 'node:async_hooks';
import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setImmediate as immediate, setTimeout as delay } from 'node:timers/promises';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';

async function fixture(run) {
  const base = await mkdtemp(join(tmpdir(), 'ohos-cancel-before-start-'));
  const work = join(base, 'work'), temp = join(base, 'temp');
  await mkdir(work); await mkdir(temp);
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot: temp });
  let starts = 0;
  // Observe real Node Worker creation; do not replace Worker or its scheduler.
  const hook = createHook({ init(_id, type) { if (type === 'WORKER') starts++; } });
  const spawn = (file, signal) => runtime.spawn({ argv: ['bash', '-c', `printf complete > ${file}`],
    cwd: work, signal, graceMs: 100, env: {},
    stdio: { stdin: 'ignore', stdout: { maxBytes: 1000 }, stderr: { maxBytes: 1000 } } });
  try {
    hook.enable();
    await run({ runtime, work, spawn, starts: () => starts });
  } finally {
    hook.disable();
    await runtime.dispose();
    // A broken before-image can have an orphan whose handle already settled.
    // Let that actual Worker exit before removing this test's private files.
    if (starts && runtime.live.size === 0) await delay(200);
    await rm(base, { recursive: true, force: true });
  }
}

for (const action of ['terminate', 'abort', 'dispose']) {
  test(`same-stack ${action} creates no Worker after termination is acknowledged`, async () => fixture(async f => {
    const controller = new AbortController();
    const handle = f.spawn('canceled.txt', controller.signal);
    let disposed;
    // Deliberately no await between spawn and cancellation.
    if (action === 'terminate') handle.terminate();
    else if (action === 'abort') controller.abort();
    else disposed = f.runtime.dispose();
    assert.deepEqual(await handle.done, { exitCode: null, signal: 'SIGTERM' });
    assert.equal(await handle.waitForExit(), true);
    await disposed;
    await immediate(); await immediate();
    assert.equal(f.starts(), 0, 'a canceled queued job must never construct a real Worker');
    await assert.rejects(readFile(join(f.work, 'canceled.txt')), { code: 'ENOENT' });
    assert.equal(f.runtime.live.size, 0);
  }));
}

test('same-stack cancel leaves the following writer live until its actual Worker finishes', async () => fixture(async f => {
  const canceled = f.spawn('canceled.txt');
  canceled.terminate();
  const following = f.spawn('following.txt');
  assert.deepEqual(await canceled.done, { exitCode: null, signal: 'SIGTERM' });
  assert.equal(await canceled.waitForExit(), true);
  assert.deepEqual(await following.done, { exitCode: 0, signal: null });
  assert.equal(await following.waitForExit(), true);
  assert.equal(f.starts(), 1, 'only the non-canceled following job may create a Worker');
  assert.equal(await readFile(join(f.work, 'following.txt'), 'utf8'), 'complete');
  await assert.rejects(readFile(join(f.work, 'canceled.txt')), { code: 'ENOENT' });
  assert.equal(f.runtime.live.size, 0);
}));
