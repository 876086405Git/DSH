import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'ohos-stream-'));
  const work = join(root, 'work'), temporaryRoot = join(root, 'tmp');
  await mkdir(work); await mkdir(temporaryRoot);
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot });
  t.after(async () => { await runtime.dispose(); await rm(root, { recursive: true, force: true }); });
  const spawn = (source, args = {}) => runtime.spawn({ argv: ['node', '-e', source], cwd: work, graceMs: 200,
    stdio: { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' }, ...args });
  return { runtime, spawn };
}
const write = (stream, bytes) => new Promise((resolve, reject) => stream.write(bytes, error => error ? reject(error) : resolve()));

test('two binary stdio exchanges finish before stdin EOF in actual Node Worker', { timeout: 12000 }, async t => {
  const f = await fixture(t), handle = f.spawn('process.stdin.on("data", b => process.stdout.write(b));');
  const bytes = Buffer.from([0, 255, 128, 10, 195, 169]);
  const errors = []; handle.stderr.on('data', b => errors.push(b));
  assert(handle.stdin, 'a real writable stdin must be exposed');
  let finished = false; handle.done.finally(() => { finished = true; }).catch(() => {});
  for (let i = 0; i < 2; i++) {
    const response = once(handle.stdout, 'data');
    await write(handle.stdin, bytes);
    assert.deepEqual((await response)[0], bytes);
    assert.equal(finished, false, 'reply must not require stdin EOF');
  }
  handle.stdin.end();
  assert.deepEqual(await handle.done, { exitCode: 0, signal: null });
  assert.equal(await handle.waitForExit(), true);
  assert.equal(Buffer.concat(errors).length, 0);
});

test('stream cancellation closes the real Worker and admits the next task', { timeout: 12000 }, async t => {
  const f = await fixture(t), handle = f.spawn('process.stdin.on("data", b=>process.stdout.write(b));setInterval(()=>{},1000);');
  handle.stderr.resume();
  assert(handle.stdin);
  const first = once(handle.stdout, 'data'); await write(handle.stdin, 'ready'); await first;
  handle.terminate(); handle.terminate();
  assert.deepEqual(await handle.done, { exitCode: null, signal: 'SIGTERM' });
  assert.equal(await handle.waitForExit(), true);
  assert.equal(handle.stdin.destroyed, true);
  const next = f.spawn('console.log("next")', { stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
  const chunks = []; next.stdout.on('data', b => chunks.push(b)); next.stderr.resume();
  assert.equal((await next.done).exitCode, 0); assert.equal(Buffer.concat(chunks).toString(), 'next\n');
});

test('queued cancellation never creates a Worker or leaves writable stdin alive', { timeout: 12000 }, async t => {
  const f = await fixture(t), active = f.spawn('setInterval(()=>{},1000);'); active.stdout.resume(); active.stderr.resume();
  const queued = f.spawn('throw Error("must not run")'); queued.stdout.resume(); queued.stderr.resume();
  assert(queued.stdin); queued.terminate();
  assert.equal((await queued.done).signal, 'SIGTERM'); assert(queued.stdin.destroyed);
  active.terminate(); await active.done;
});

test('batch input and normal non-stream child behavior remain compatible', { timeout: 12000 }, async t => {
  const f = await fixture(t);
  const handle = f.spawn('process.exitCode=7', { stdio: { stdin: { data: 'ignored input' }, stdout: 'pipe', stderr: 'pipe' } });
  handle.stdout.resume(); handle.stderr.resume();
  assert.equal((await handle.done).exitCode, 7);
  const invalid = f.spawn('', { argv: ['node', '-'] }); invalid.stdout.resume(); invalid.stderr.resume();
  assert.equal((await invalid.done).exitCode, 2);
});
