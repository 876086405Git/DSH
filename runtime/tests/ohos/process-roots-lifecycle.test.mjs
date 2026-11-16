import { symlinkFixture } from './host-link-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fsSync from 'node:fs';
import * as fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { syncBuiltinESMExports } from 'node:module';
import { getEventListeners } from 'node:events';

if (!process.env.M4_4_RUNTIME_DIR) throw new Error('M4_4_RUNTIME_DIR must name the exact process source under test');
const runtimeDirectory = resolve(process.env.M4_4_RUNTIME_DIR);
const { VirtualSubprocessRuntime } = await import(pathToFileURL(join(runtimeDirectory, 'runtime.mjs')));

async function fixture(t, owned = false) {
  const root = await fs.mkdtemp(join(tmpdir(), 'dsh-m4-4a-'));
  const [a, b, provided] = ['session-a', 'session-b', 'provided-temp'].map(name => join(root, name));
  await Promise.all([a, b, provided].map(path => fs.mkdir(path)));
  await fs.writeFile(join(a, 'own.txt'), 'SESSION_A\n');
  await fs.writeFile(join(b, 'secret.txt'), 'SESSION_B\n');
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [a, b], ...(owned ? {} : { temporaryRoot: provided }) });
  const allocation = runtime.temporaryRoot;
  t.after(async () => {
    try { await runtime.dispose(); }
    finally {
      // This test also records its allocation so the deliberately failing old
      // implementation cannot leak it. No prefix scanning or guessed path.
      if (owned) await fs.rm(allocation, { recursive: true, force: true });
      await fs.rm(root, { recursive: true, force: true });
    }
  });
  const spawn = (argv, extra = {}, policy) => runtime.spawn({
    argv: policy ? runtime.prepare(argv, policy) : argv,
    cwd: a, graceMs: 100,
    stdio: { stdin: 'ignore', stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } },
    ...extra,
  });
  const result = async handle => ({ ...(await handle.done),
    stdout: handle.collected.stdout.readFrom(0).text,
    stderr: handle.collected.stderr.readFrom(0).text });
  return { root, a, b, provided, temporary: allocation, runtime, spawn, result };
}

async function ready(path) {
  const until = Date.now() + 10000;
  while (!await fs.stat(path).then(() => true, error => {
    if (error.code !== 'ENOENT') throw error;
    return false;
  })) {
    assert(Date.now() < until, `Worker did not reach the real I/O boundary: ${path}`);
    await delay(10);
  }
}

test('direct spawn can read its cwd and can use its private temporary root', async t => {
  const f = await fixture(t);
  const value = await f.result(f.spawn(['bash', '-c', 'cat own.txt; printf temporary > "$TMPDIR/file"; cat "$TMPDIR/file"']));
  assert.equal(value.exitCode, 0);
  assert.equal(value.stdout, 'SESSION_A\ntemporary');
  assert.equal(await fs.readFile(join(f.temporary, 'file'), 'utf8'), 'temporary');
});

test('direct spawn cannot inherit another host-authorized session root', async t => {
  const f = await fixture(t);
  const value = await f.result(f.spawn(['bash', '-c', `cat '${join(f.b, 'secret.txt')}'`]));
  t.diagnostic(JSON.stringify(value));
  assert.notEqual(value.exitCode, 0);
  assert.equal(value.stdout, '');
  assert.doesNotMatch(value.stderr, /SESSION_B/);
  assert.equal(await fs.readFile(join(f.b, 'secret.txt'), 'utf8'), 'SESSION_B\n');
});

test('direct subdirectory access stays narrow; explicit session policy permits its parent', async t => {
  const f = await fixture(t), sub = join(f.a, 'sub');
  await fs.mkdir(sub);
  const direct = await f.result(f.spawn(['bash', '-c', 'cat ../own.txt'], { cwd: sub }));
  assert.notEqual(direct.exitCode, 0);
  assert.equal(direct.stdout, '');
  const prepared = await f.result(f.spawn(['bash', '-c', 'cat ../own.txt'], { cwd: sub }, { mode: 'read-only', workspaceRoot: f.a }));
  assert.equal(prepared.exitCode, 0);
  assert.equal(prepared.stdout, 'SESSION_A\n');
});

test('a session-A ticket cannot be started with host-authorized session-B cwd', async t => {
  const f = await fixture(t);
  const handle = f.spawn(['bash', '-c', 'cat secret.txt'], { cwd: f.b }, { mode: 'read-only', workspaceRoot: f.a });
  await assert.rejects(handle.done, { code: 'EACCES' });
  assert.equal(handle.collected.stdout.readFrom(0).text, '');
  assert.equal(await handle.waitForExit(), true);
});

test('canonical aliases do not grant a different session, and an unauthorized cwd is rejected', async t => {
  const f = await fixture(t), alias = join(f.root, 'alias-a'), unauthorized = join(f.root, 'outside');
  await symlinkFixture(f.a, alias);
  await fs.mkdir(unauthorized);
  const own = await f.result(f.spawn(['bash', '-c', 'cat own.txt'], { cwd: alias }));
  assert.equal(own.stdout, 'SESSION_A\n');
  const denied = f.spawn(['bash', '-c', 'printf forbidden'], { cwd: unauthorized });
  await assert.rejects(denied.done, { code: 'EACCES' });
  assert.equal(denied.collected.stdout.readFrom(0).text, '');
});

test('missing, empty, relative, filesystem-root, nonexistent and file roots reject before allocating temp', async t => {
  const f = await fixture(t);
  const original = fsSync.mkdtempSync, allocations = [], constructed = [];
  fsSync.mkdtempSync = (...args) => { const path = original(...args); allocations.push(path); return path; };
  syncBuiltinESMExports();
  try {
    for (const workspaceRoots of [undefined, [], ['/'], ['relative'], [join(f.a, 'missing')], [join(f.a, 'own.txt')]]) {
      assert.throws(() => constructed.push(new VirtualSubprocessRuntime({ workspaceRoots })));
    }
    for (const temporaryRoot of ['relative', '/', join(f.a, 'missing'), join(f.a, 'own.txt')]) {
      assert.throws(() => constructed.push(new VirtualSubprocessRuntime({ workspaceRoots: [f.a], temporaryRoot })));
    }
    assert.equal(allocations.length, 0);
  } finally {
    fsSync.mkdtempSync = original;
    syncBuiltinESMExports();
    for (const runtime of constructed) await runtime.dispose();
    for (const path of allocations) await fs.rm(path, { recursive: true, force: true });
  }
});

test('dispose removes owned temp and sealed spill output but preserves a linked external target', async t => {
  const f = await fixture(t, true);
  await symlinkFixture(f.b, join(f.temporary, 'external-link'));
  const handle = f.spawn(['bash', '-c', 'printf 0123456789ABCDEFGHIJ'], {
    stdio: { stdin: 'ignore', stdout: { maxBytes: 8, spill: { maxBytes: 100 } }, stderr: { maxBytes: 8 } },
  });
  assert.equal((await handle.done).exitCode, 0);
  const output = handle.collected.stdout.readFrom(0);
  assert.equal(await fs.readFile(output.spillPath, 'utf8'), '0123456789ABCDEFGHIJ');
  await f.runtime.dispose();
  await assert.rejects(fs.lstat(f.temporary), { code: 'ENOENT' });
  assert.equal(await fs.readFile(join(f.b, 'secret.txt'), 'utf8'), 'SESSION_B\n');
});

test('dispose keeps the caller-provided temporary directory and its contents', async t => {
  const f = await fixture(t);
  await fs.writeFile(join(f.provided, 'keep'), 'caller-owned');
  await f.runtime.dispose();
  assert.equal(await fs.readFile(join(f.provided, 'keep'), 'utf8'), 'caller-owned');
});

test('dispose clears unused tickets and abort listeners and rejects new work', async t => {
  const f = await fixture(t), controller = new AbortController();
  const argv = f.runtime.prepare(['bash', '-c', 'printf forbidden'], { mode: 'read-only', workspaceRoot: f.a }, controller.signal);
  assert.equal(getEventListeners(controller.signal, 'abort').length, 1);
  await f.runtime.dispose();
  assert.equal(getEventListeners(controller.signal, 'abort').length, 0);
  assert.throws(() => f.runtime.prepare(['bash', '-c', 'true'], { mode: 'read-only', workspaceRoot: f.a }), /服务已关闭/);
  assert.throws(() => f.spawn(argv), /服务已关闭/);
});

test('dispose waits for both real I/O gates, cancels both queues, then removes owned temp', { timeout: 20000 }, async t => {
  assert.equal(globalThis[Symbol.for('dsh.go.test.m4-4-io-gate')], true, 'start Node with --import process-paths-io-gate.mjs');
  const f = await fixture(t, true), target = join(f.a, 'gated.txt');
  await fs.writeFile(target, 'needle\n');
  const executionReady = join(f.temporary, 'execution-ready'), searchReady = join(f.temporary, 'search-ready');
  const execution = f.spawn(['bash', '-c', 'printf ready > "$TMPDIR/execution-ready"; sleep 30; printf late > late']);
  const search = f.spawn(['rg', '--json', '--regexp=needle', '--', 'gated.txt'], { env: {
    M4_4_SEARCH_FILE: target, M4_4_SEARCH_READY: searchReady,
  } });
  await Promise.all([ready(executionReady), ready(searchReady)]);
  const queued = [f.spawn(['bash', '-c', 'printf late > queued']), f.spawn(['rg', '--json', '--regexp=needle', '--', 'gated.txt'])];
  for (const handle of [execution, search]) assert.equal(await handle.waitForExit(AbortSignal.abort()), false);
  const disposing = f.runtime.dispose();
  await Promise.all([disposing, f.runtime.dispose()]);
  for (const handle of [execution, search, ...queued]) {
    assert.equal(await handle.waitForExit(), true);
    assert.equal((await handle.done).signal, 'SIGTERM');
  }
  for (const handle of queued) assert.equal(handle.collected.stdout.readFrom(0).text, '');
  await assert.rejects(fs.lstat(f.temporary), { code: 'ENOENT' });
  for (const name of ['late', 'queued']) await assert.rejects(fs.lstat(join(f.a, name)), { code: 'ENOENT' });
});

test('an already removed owned temporary root is not recreated by disposal', async t => {
  const f = await fixture(t, true);
  await fs.rm(f.temporary, { recursive: true });
  await f.runtime.dispose();
  await assert.rejects(fs.lstat(f.temporary), { code: 'ENOENT' });
});

test('replacing an owned temp root causes explicit refusal and preserves the replacement', async () => {
  const root = await fs.mkdtemp(join(tmpdir(), 'dsh-m4-4a-replaced-'));
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [root] });
  const original = runtime.temporaryRoot, moved = join(root, 'moved-owned-temp');
  await fs.rename(original, moved);
  await fs.mkdir(original);
  await fs.writeFile(join(original, 'keep'), 'different owner');
  try {
    const result = runtime.dispose();
    await assert.rejects(result, { code: 'ERR_OHOS_TEMP_ROOT_REPLACED' });
    await assert.rejects(runtime.dispose(), { code: 'ERR_OHOS_TEMP_ROOT_REPLACED' });
    assert.equal(await fs.readFile(join(original, 'keep'), 'utf8'), 'different owner');
  } finally {
    await fs.rm(original, { recursive: true, force: true });
    await fs.rm(root, { recursive: true, force: true });
  }
});
