import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, open, readFile, rm, stat, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

// This coordinator runs outside O0 so it can launch/kill real isolated actors.
// --strict is passed to the actors; they verify all four O0 constraints.
const strict = process.env.DSH_TEST_LOCK_STRICT === '1';
if (strict) assert.ok(process.env.DSH_TEST_SIM_PRELOAD);
assert.equal(process.version, 'v24.22.1');
const binding = process._linkedBinding('dsh_ohos_publication');
const childScript = fileURLToPath(new URL('./publication-lock-child.mjs', import.meta.url));
const records = [];

function actor(lockPath) {
  const argv = strict ? ['--jitless', '--import', process.env.DSH_TEST_SIM_PRELOAD, childScript, lockPath, '--strict'] : [childScript, lockPath];
  const child = spawn(process.execPath, argv, {
    env: { ...process.env, DSH_GO_OHOS_SIM_PLATFORM: 'openharmony', DSH_GO_OHOS_SIM_ADDONS: '[]' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const messages = [], waits = [];
  let buffer = '', stderr = '', exitResult;
  const exited = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      exitResult = { code, signal };
      for (const waiter of waits.splice(0)) { clearTimeout(waiter.timer); waiter.reject(new Error(`Actor exited before ${waiter.event}: ${JSON.stringify(exitResult)} ${stderr}`)); }
      resolve(exitResult);
    });
  });
  child.stderr.setEncoding('utf8'); child.stderr.on('data', data => { stderr += data; });
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', data => {
    buffer += data;
    for (;;) {
      const end = buffer.indexOf('\n');
      if (end === -1) break;
      const value = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
      records.push(value);
      const index = waits.findIndex(waiter => waiter.event === value.event);
      if (index === -1) messages.push(value);
      else { const [waiter] = waits.splice(index, 1); clearTimeout(waiter.timer); waiter.resolve(value); }
    }
  });
  const next = event => {
    const index = messages.findIndex(value => value.event === event);
    if (index !== -1) return Promise.resolve(messages.splice(index, 1)[0]);
    if (exitResult) return Promise.reject(new Error(`Actor already exited: ${JSON.stringify(exitResult)} ${stderr}`));
    return new Promise((resolve, reject) => {
      const waiter = { event, resolve, reject };
      waiter.timer = setTimeout(() => {
        waits.splice(waits.indexOf(waiter), 1); child.kill('SIGKILL');
        reject(new Error(`Actor timeout at ${event}: ${stderr}`));
      }, 10000);
      waits.push(waiter);
    });
  };
  return { child, next, exited, command: value => child.stdin.write(value + '\n'), close: async () => {
    if (!exitResult) { child.kill('SIGKILL'); await exited; }
  } };
}

async function fixture(fn) {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-publication-flock-'));
  const lockPath = join(directory, '.lock');
  const actors = [];
  await writeFile(lockPath, 'persistent lock inode\n', { mode: 0o600 });
  const initial = await stat(lockPath, { bigint: true });
  const start = () => { const value = actor(lockPath); actors.push(value); return value; };
  try { await fn({ lockPath, initial, start }); }
  finally {
    await Promise.all(actors.map(value => value.close()));
    await rm(directory, { recursive: true, force: true });
  }
}

const ready = async value => {
  const result = await value.next('ready');
  assert.equal(result.strictConstraintsVerified, strict);
};
const attempt = async value => { value.command('go'); return value.next('attempt'); };
const contention = result => {
  assert.equal(result.acquired, false);
  assert.deepEqual(result.error, { name: 'Error', code: 'EAGAIN', errno: -11, syscall: 'flock' });
};

test('fd validation is exact; invalid real descriptor retains EBADF/negative errno/flock', async () => {
  for (const value of [undefined, null, '1', 1n, {}, true]) {
    assert.throws(() => binding.lockExclusive(value), { name: 'TypeError', code: 'ERR_INVALID_ARG_TYPE' });
  }
  for (const value of [-1, NaN, Infinity, -Infinity, 1.5, 2 ** 31, 2 ** 32]) {
    assert.throws(() => binding.lockExclusive(value), { name: 'TypeError', code: 'ERR_INVALID_ARG_VALUE' });
  }
  assert.throws(() => binding.lockExclusive(), { code: 'ERR_INVALID_ARG_TYPE' });
  assert.throws(() => binding.lockExclusive(2 ** 31 - 1), { code: 'EBADF', errno: -9, syscall: 'flock' });
  await fixture(async ({ lockPath }) => {
    const first = await open(lockPath, 'a+'), second = await open(lockPath, 'a+');
    try {
      assert.equal(binding.lockExclusive(first.fd), undefined);
      assert.equal(binding.lockExclusive(first.fd), undefined);
      assert.throws(() => binding.lockExclusive(second.fd), { code: 'EAGAIN', errno: -11, syscall: 'flock' });
    } finally { await first.close(); await second.close(); }
  });
});

test('two live processes race at a barrier: one lock; close releases while winner stays alive', { timeout: 20000 }, async () => {
  await fixture(async ({ lockPath, initial, start }) => {
    const first = start(), second = start();
    await Promise.all([ready(first), ready(second)]);
    first.command('go'); second.command('go');
    const [a, b] = await Promise.all([first.next('attempt'), second.next('attempt')]);
    assert.notEqual(a.pid, b.pid);
    assert.equal(Number(a.acquired) + Number(b.acquired), 1);
    contention(a.acquired ? b : a);
    const winner = a.acquired ? first : second;
    winner.command('close'); await winner.next('closed');
    assert.equal(winner.child.exitCode, null);
    const next = start(); await ready(next);
    assert.equal((await attempt(next)).acquired, true);
    assert.equal((await stat(lockPath, { bigint: true })).ino, initial.ino);
    assert.equal(await readFile(lockPath, 'utf8'), 'persistent lock inode\n');
  });
});

test('SIGKILL of holder releases kernel lock without deleting or replacing the fixed lock file', { timeout: 20000 }, async () => {
  await fixture(async ({ lockPath, initial, start }) => {
    const owner = start(); await ready(owner); assert.equal((await attempt(owner)).acquired, true);
    const loser = start(); await ready(loser); contention(await attempt(loser));
    assert.equal(owner.child.kill('SIGKILL'), true);
    assert.deepEqual(await owner.exited, { code: null, signal: 'SIGKILL' });
    const successor = start(); await ready(successor); assert.equal((await attempt(successor)).acquired, true);
    assert.equal((await stat(lockPath, { bigint: true })).ino, initial.ino);
    assert.equal(await readFile(lockPath, 'utf8'), 'persistent lock inode\n');
  });
});

test('protocol negative control: replacing a held lock pathname creates a different lock domain', { timeout: 20000 }, async () => {
  await fixture(async ({ lockPath, initial, start }) => {
    const owner = start(); await ready(owner); assert.equal((await attempt(owner)).acquired, true);
    // Deliberate fault only in this owned fixture. Production must never do it.
    await unlink(lockPath); await writeFile(lockPath, 'foreign replacement\n', { mode: 0o600 });
    const replacement = await stat(lockPath, { bigint: true });
    assert.notEqual(replacement.ino, initial.ino);
    const other = start(); await ready(other); assert.equal((await attempt(other)).acquired, true);
    assert.equal(owner.child.exitCode, null);
  });
});

test.after(() => {
  console.log(JSON.stringify({ evidence: 'flock-real-processes', strictActors: strict,
    coordinatorOutsideO0: true, events: records,
    scope: 'Linux x64 fixture only; OHOS ABI/seccomp/filesystem not run' }));
});
