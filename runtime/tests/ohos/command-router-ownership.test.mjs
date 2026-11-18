import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { promisify } from 'node:util';
import { Context } from '@deepseek-ai/cordis';
import OhSubprocessRuntime from '../../ohos/process/index.mjs';
import { bindPluginCommands, spawnPluginCommand } from '../../ohos/process/command-router.mjs';

async function fixture(t) {
  const base = await mkdtemp(join(tmpdir(), 'ohos-command-owner-'));
  const contexts = [];
  t.after(async () => {
    await Promise.allSettled(contexts.map(ctx => ctx.fiber.dispose()));
    await rm(base, { recursive: true, force: true });
  });
  async function context(name) {
    const work = join(base, name), temporaryRoot = join(base, name + '-tmp');
    await mkdir(work); await mkdir(temporaryRoot);
    const ctx = new Context(); contexts.push(ctx);
    const config = { workspaceRoots: [work], temporaryRoot };
    const fiber = ctx.plugin(OhSubprocessRuntime, config); await fiber;
    return { ctx, fiber, work, config, service: ctx.subprocess };
  }
  return { context };
}
const spec = cwd => ({ argv: ['node', '-p', 'process.cwd()'], cwd, graceMs: 1000,
  stdio: { stdin: 'ignore', stdout: { maxBytes: 8192 }, stderr: { maxBytes: 8192 } } });

test('independent real Cordis contexts retain their own command Workers; unscoped dispatch rejects ambiguity', { timeout: 15000 }, async t => {
  const f = await fixture(t), a = await f.context('a'), b = await f.context('b');
  assert.throws(() => spawnPluginCommand(spec(a.work)), { code: 'ERR_OHOS_PROCESS_OWNER' });
  const [aa, bb] = await Promise.all([a, b].map(x => promisify(x.service.pluginProcess.execFile)(
    'node', ['-p', 'process.cwd()'], { cwd: x.work })));
  assert.equal(aa.stdout, a.work + '\n'); assert.equal(bb.stdout, b.work + '\n');
  await a.fiber.dispose();
  const job = spawnPluginCommand(spec(b.work));
  assert.equal((await job.done).exitCode, 0);
  assert.equal(job.collected.stdout.snapshot().bytes.toString(), b.work + '\n');
  assert.equal(a.service.backend.closed, true); assert.equal(b.service.backend.closed, false);
});

test('binding tickets are independently released and an old disposer cannot revoke a replacement', () => {
  const calls = [];
  const a = { spawnPlugin(value) { calls.push(['a', value]); return 'a'; } };
  const b = { spawnPlugin(value) { calls.push(['b', value]); return 'b'; } };
  const one = bindPluginCommands(a), two = bindPluginCommands(a); let other;
  try {
    assert.equal(spawnPluginCommand('first'), 'a');
    one(); one();
    assert.equal(spawnPluginCommand('still-owned'), 'a');
    a.closed = true;
    assert.throws(() => spawnPluginCommand('none'), { code: 'ERR_OHOS_NO_SPAWN' });
    other = bindPluginCommands(b);
    one(); two();
    assert.equal(spawnPluginCommand('replacement'), 'b');
    assert.deepEqual(calls, [['a', 'first'], ['a', 'still-owned'], ['b', 'replacement']]);
  } finally { one(); two(); other?.(); }
});

test('real Cordis reload can start a replacement while old teardown awaits a provider; Worker and failure ownership stay separate', { timeout: 15000 }, async t => {
  const barrier = Promise.withResolvers(), providerStarted = Promise.withResolvers();
  t.after(() => barrier.resolve());
  const f = await fixture(t), a = await f.context('reload');
  const fault = Object.assign(new Error('controlled provider retirement failure'), { code: 'ERR_TEST_RETIREMENT' });
  a.service.backend.linux = { dispose() { providerStarted.resolve(); return barrier.promise; } };
  const child = a.service.pluginProcess.spawn('node', ['-e', 'process.stdout.write("ready");setInterval(()=>{},1000)'], { cwd: a.work });
  child.on('error', error => assert.fail(error)); child.stderr.resume();
  const closed = once(child, 'close'); await once(child.stdout, 'data');
  let retired = false;
  const disposal = a.fiber.dispose(); disposal.catch(() => {}).finally(() => { retired = true; });
  await providerStarted.promise;
  // Cordis logs effect failures while settling its Fiber; the router's own
  // idempotent disposal promise retains the provider failure for its owner.
  const backendDisposal = a.service.backend.dispose(); backendDisposal.catch(() => {});
  assert.equal(a.service.backend.closed, true, 'owner admission closes before waiting for its provider');
  assert.throws(() => a.service.backend.spawnPlugin(spec(a.work)), { code: 'ERR_OHOS_PROCESS_CLOSED' });
  const b = await f.context('other-context');
  const job = spawnPluginCommand(spec(b.work));
  assert.equal((await job.done).exitCode, 0);
  await closed;
  assert.equal(a.service.backend.pluginNode.live.size, 0, 'old dedicated Worker actually exited');
  assert.equal(retired, false, 'a different provider still controls old teardown completion');
  barrier.reject(fault);
  await assert.rejects(backendDisposal, error => error instanceof AggregateError);
  await disposal;
  const afterFailure = spawnPluginCommand(spec(b.work));
  assert.equal((await afterFailure.done).exitCode, 0);
  assert.equal(b.service.backend.closed, false, 'old failed teardown cannot close the other context');
  await b.fiber.dispose();
  const nextFiber = a.ctx.plugin(OhSubprocessRuntime, a.config); await nextFiber;
  const replacement = a.ctx.subprocess;
  assert.notEqual(replacement, a.service, 'the same real Cordis context can reload its runtime');
  const reloaded = spawnPluginCommand(spec(a.work));
  assert.equal((await reloaded.done).exitCode, 0);
  await nextFiber.dispose();
  assert.throws(() => spawnPluginCommand(spec(a.work)), { code: 'ERR_OHOS_NO_SPAWN' });
});
