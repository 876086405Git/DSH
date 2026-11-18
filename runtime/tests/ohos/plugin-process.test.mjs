import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { once } from 'node:events';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { CommandRouter, bindPluginCommands } from '../../ohos/process/command-router.mjs';
import { createChildProcessFacade } from '../../ohos/process/plugin-process.mjs';
import { installPluginResolution } from '../../ohos/plugins/resolution.mjs';
import { profileDirectories } from '../../ohos/plugins/store.mjs';

async function setup(t, backends) {
  const base = await mkdtemp(join(tmpdir(), 'ohos-plugin-cp-'));
  const work = join(base, 'work'), tmp = join(base, 'tmp'); await mkdir(work); await mkdir(tmp);
  const router = new CommandRouter({ workspaceRoots: [work], temporaryRoot: tmp }, backends);
  t.after(async () => { await router.dispose(); await rm(base, { recursive: true, force: true }); });
  return { base, work, router, cp: createChildProcessFacade(spec => router.spawnPlugin(spec)) };
}
const closed = child => new Promise(resolve => child.once('close', (code, signal) => resolve({ code, signal })));

test('plugin facade uses actual Node Worker with full duplex stdio and ordered lifecycle', { timeout: 10000 }, async t => {
  const f = await setup(t), child = f.cp.spawn('node', ['-e', 'process.stdin.on("data",b=>process.stdout.write(b));'], { cwd: f.work });
  const order = []; for (const name of ['spawn', 'exit', 'close']) child.on(name, () => order.push(name));
  child.on('error', error => assert.fail(error)); child.stderr.resume(); const done = closed(child);
  for (const message of ['first\n', '第二轮\n']) {
    const data = once(child.stdout, 'data'); child.stdin.write(message);
    assert.equal((await data)[0].toString(), message);
  }
  child.stdin.end(); assert.deepEqual(await done, { code: 0, signal: null });
  assert.deepEqual(order, ['spawn', 'exit', 'close']); assert.equal(child.pid, undefined);
});

test('execFile callback and promisify preserve stdout/stderr, arguments, errors and maxBuffer', { timeout: 10000 }, async t => {
  const f = await setup(t), exec = promisify(f.cp.execFile);
  const success = await exec('node', ['-e', 'console.log(process.argv[1]);console.error("error-output")', 'a b'], { cwd: f.work });
  assert.deepEqual(success, { stdout: 'a b\n', stderr: 'error-output\n' });
  await assert.rejects(exec('node', ['-e', 'console.log("before");process.exitCode=23'], { cwd: f.work }), error => error.code === 23 && error.stdout === 'before\n');
  await assert.rejects(exec('node', ['-e', 'process.stdout.write("0123456789")'], { cwd: f.work, maxBuffer: 4 }), error => error.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER' && error.stdout === '0123');
  assert.throws(() => f.cp.spawnSync('node'), { code: 'ERR_OHOS_SYNC_PROCESS_UNAVAILABLE' });
  assert.throws(() => f.cp.fork('server.js'), { code: 'ERR_OHOS_PROCESS_OPTION' });
});

test('non-Node commands fail clearly without Linux and failed spawn emits no spawn/exit', async t => {
  const f = await setup(t), child = f.cp.spawn('gh', ['--version'], { cwd: f.work }), order = [];
  let error; child.on('error', e => { error = e; order.push('error'); });
  for (const name of ['spawn', 'exit', 'close']) child.on(name, () => order.push(name));
  await closed(child); assert.equal(error.code, 'ERR_OHOS_NO_SPAWN'); assert.deepEqual(order, ['error', 'close']);
});

test('consumed prepare policy never enters native Python without confinement', async t => {
  let calls = 0;
  const backend = { capabilities: { confinement: 'none', trustedOnly: true }, spawn() { calls++; throw Error('must not call'); }, dispose() {} };
  const f = await setup(t, { nativePython: backend });
  for (const mode of ['read-only', 'workspace-write']) {
    const argv = f.router.prepare(['python3', '-c', 'print(1)'], { mode, workspaceRoot: f.work });
    assert.throws(() => f.router.spawn({ argv, cwd: f.work, graceMs: 1000, stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } }), { code: 'ERR_OHOS_BACKEND_CONFINEMENT' });
  }
  assert.equal(calls, 0);
});

test('only managed CJS/ESM plugin imports receive the facade; builtin guard stays unchanged', { timeout: 10000 }, async t => {
  const f = await setup(t), unbind = bindPluginCommands(f.router); t.after(unbind);
  profileDirectories.add(f.work); t.after(() => profileDirectories.delete(f.work));
  const platform = Object.getOwnPropertyDescriptor(process, 'platform');
  Object.defineProperty(process, 'platform', { value: 'openharmony' }); t.after(() => Object.defineProperty(process, 'platform', platform));
  await import('../../ohos/process/child-process.mjs');
  const original = process.getBuiltinModule('child_process').spawn;
  installPluginResolution();
  await writeFile(join(f.work, 'plugin.cjs'), 'module.exports=require("node:child_process");');
  await writeFile(join(f.work, 'plugin.mjs'), 'export {default} from "child_process";');
  const require = createRequire(import.meta.url);
  for (const facade of [require(join(f.work, 'plugin.cjs')), (await import(pathToFileURL(join(f.work, 'plugin.mjs')))).default]) {
    const value = await promisify(facade.execFile)('node', ['-p', 'require("node:worker_threads").isMainThread'], { cwd: f.work });
    assert.equal(value.stdout, 'false\n');
  }
  assert.equal(process.getBuiltinModule('child_process').spawn, original);
  assert.equal(require('node:child_process').spawn, original);
  assert.throws(() => original('node'), { code: 'ERR_OHOS_NO_SPAWN' });
});

test('Node command failures keep spawn and close ordering, including unread output', async t => {
  const f = await setup(t);
  for (const args of [['missing.js'], ['-e', 'process.stdout.write("tail");']]) {
    const child = f.cp.spawn('node', args, { cwd: f.work }), order = [];
    child.on('error', error => assert.fail(error));
    for (const name of ['spawn', 'exit', 'close']) child.on(name, () => order.push(name));
    child.stdout.on('end', () => order.push('stdout:end'));
    const result = await closed(child);
    assert.equal(result.code, args[0] === 'missing.js' ? 1 : 0);
    assert(order.indexOf('spawn') < order.indexOf('exit'));
    assert(order.indexOf('stdout:end') < order.indexOf('close'));
  }
});

test('same-stack cancellation needs no hidden startup-error listener and executes no script', async t => {
  const f = await setup(t);
  const child = f.cp.spawn('node', ['-e', 'throw Error("must not start")'], { cwd: f.work });
  const done = closed(child); assert.equal(child.kill('SIGKILL'), true);
  assert.deepEqual(await done, { code: null, signal: 'SIGKILL' });
  assert.equal(f.router.pluginNode.live.size, 0);
});

test('long-lived plugin Node commands start concurrently and one failure leaves its peer alive', { timeout: 10000 }, async t => {
  const f = await setup(t);
  const a = f.cp.spawn('node', ['-e', 'setInterval(()=>{},1000);'], { cwd: f.work });
  const b = f.cp.spawn('node', ['-e', 'process.stdin.on("data",b=>process.stdout.write(b));'], { cwd: f.work });
  const aDone = closed(a), bDone = closed(b);
  a.on('error', error => assert.fail(error)); b.on('error', error => assert.fail(error));
  await Promise.all([once(a, 'spawn'), once(b, 'spawn')]);
  a.kill('SIGKILL'); assert.deepEqual(await aDone, { code: null, signal: 'SIGKILL' });
  const failed = await promisify(f.cp.execFile)('node', ['-e', 'throw Error("one worker only")'], { cwd: f.work }).catch(error => error);
  assert.equal(failed.code, 1);
  const data = once(b.stdout, 'data'); b.stdin.write('peer-alive'); assert.equal((await data)[0].toString(), 'peer-alive');
  b.stdin.end(); assert.deepEqual(await bDone, { code: 0, signal: null });
});

test('dispose closes all admissions synchronously while a provider still owns resources', async t => {
  const closing = Promise.withResolvers();
  const f = await setup(t, { linux: { dispose: () => closing.promise } });
  const done = f.router.dispose();
  assert.throws(() => f.router.prepare(['node', '-e', '1'], { mode: 'read-only', workspaceRoot: f.work }), { code: 'ERR_OHOS_PROCESS_CLOSED' });
  assert.throws(() => f.router.spawn({}), { code: 'ERR_OHOS_PROCESS_CLOSED' });
  assert.throws(() => f.router.spawnPlugin({ argv: ['node'] }), { code: 'ERR_OHOS_PROCESS_CLOSED' });
  assert.throws(() => f.router.spawnTerminal(), { code: 'ERR_OHOS_PROCESS_CLOSED' });
  closing.resolve(); await done;
  assert.equal(f.router.virtual.live.size + f.router.pluginNode.live.size, 0);
});
