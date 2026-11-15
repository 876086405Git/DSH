import assert from 'node:assert/strict';
import { mkdtemp, open, readFile, rename, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Worker } from 'node:worker_threads';
import { afterEach, beforeEach, test } from 'node:test';
import { loadInternals } from './load-internals.mjs';

const attachment = await loadInternals('@deepseek-ai/dsh-attachment-local', ['publishOhosExclusive']);
const session = await loadInternals('@deepseek-ai/dsh-session-persistence-jsonl', ['publishOhosExclusive', 'tryLockOhos', 'ohosWriteLocks']);
const errno = (code) => Object.assign(new Error(code), { code });
const denied = async () => { throw errno('EACCES'); };
const deferred = () => { let resolve; return { promise: new Promise((r) => { resolve = r; }), resolve }; };
let directory;
let handles;

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'dsh-ohos-locks-'));
  handles = [];
});

afterEach(async () => {
  await Promise.allSettled(handles.map((handle) => handle.close()));
  assert.equal(session.ohosWriteLocks.size, 0, 'no lock remains after its owner closes');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.publication')].pendingCount, 0, 'the shared publication queue has drained');
  await rm(directory, { recursive: true, force: true });
});

async function handleAt(path) {
  const handle = await open(path, 'a+');
  handles.push(handle);
  return handle;
}

for (const [name, module] of [['attachment', attachment], ['session', session]]) {
  test(`${name}: multi-chunk atomic publication retains bytes and source`, async () => {
    const source = join(directory, '中文 源文件');
    const target = join(directory, '目的文件');
    const bytes = Buffer.alloc(200_000, 0xc3);
    await writeFile(source, bytes);
    await module.publishOhosExclusive(source, target, { link: denied, open });
    assert.deepEqual(await readFile(source), bytes);
    assert.deepEqual(await readFile(target), bytes);
    assert.equal((await stat(target)).mode & 0o777, 0o600);
  });

  test(`${name}: EEXIST preserves a competing target without even opening source`, async () => {
    const target = join(directory, 'target');
    await writeFile(target, 'competitor');
    await assert.rejects(module.publishOhosExclusive(join(directory, 'absent source'), target, {
      link: async () => { throw errno('EEXIST'); },
      open: async () => { assert.fail('link collision must propagate'); },
    }), { code: 'EEXIST' });
    assert.equal(await readFile(target, 'utf8'), 'competitor');
  });

  test(`${name}: rejected hard link cannot follow a competing target symlink`, async () => {
    const source = join(directory, 'source');
    const target = join(directory, 'alias');
    const precious = join(directory, 'precious');
    await writeFile(source, 'ours');
    await writeFile(precious, 'keep');
    await symlink(precious, target);
    await assert.rejects(module.publishOhosExclusive(source, target, { link: denied, open }), { code: 'EEXIST' });
    assert.equal(await readFile(precious, 'utf8'), 'keep');
    assert.equal(await readFile(source, 'utf8'), 'ours');
  });

  test(`${name}: partial failure closes both handles and never unlinks a replacement`, async () => {
    const source = join(directory, 'source');
    const target = join(directory, 'target');
    const opened = [];
    await writeFile(source, 'complete source');
    await assert.rejects(module.publishOhosExclusive(source, target, {
      link: denied,
      async open(path, ...args) {
        const handle = await open(path, ...args);
        opened.push(handle);
        if (args[0] === 'wx') handle.writeFile = async () => {
          await handle.write('partial');
          await writeFile(target, 'replacement', { flag: 'wx' });
          throw errno('ENOSPC');
        };
        return handle;
      },
    }), { code: 'ENOSPC' });
    assert.ok(opened.every((handle) => handle.fd === -1));
    assert.equal(await readFile(source, 'utf8'), 'complete source');
    assert.equal(await readFile(target, 'utf8'), 'replacement');
  });

  test(`${name}: unrelated I/O failures never trigger a copy`, async () => {
    const failure = errno('EIO');
    await assert.rejects(module.publishOhosExclusive(join(directory, 'source'), join(directory, 'target'), {
      link: async () => { throw failure; },
      open: async () => { assert.fail('no copy for EIO'); },
    }), (error) => error === failure);
  });
}

test('lock identity follows the opened file through an alias, not path spelling', async () => {
  const path = join(directory, 'lock');
  const first = await handleAt(path);
  await symlink(path, join(directory, 'alias'));
  const second = await handleAt(join(directory, 'alias'));
  await session.tryLockOhos(first);
  await session.tryLockOhos(first);
  await assert.rejects(session.tryLockOhos(second), { code: 'EAGAIN' });
  await first.close();
  await session.tryLockOhos(second);
});

test('replacing a pathname creates a different inode and does not inherit its old lock', async () => {
  const path = join(directory, 'lock');
  const first = await handleAt(path);
  await session.tryLockOhos(first);
  await rename(path, join(directory, 'old-inode'));
  const second = await handleAt(path);
  assert.notEqual((await first.stat()).ino, (await second.stat()).ino);
  await session.tryLockOhos(second);
  assert.equal(session.ohosWriteLocks.size, 2);
});

test('close releases only after its promise settles, even if close event fired earlier', async () => {
  const path = join(directory, 'lock');
  const first = await handleAt(path);
  const second = await handleAt(path);
  const gate = deferred();
  const close = first.close;
  first.close = async () => {
    first.emit('close'); // Node 24 emits this before pending operations drain.
    await gate.promise;
    await close();
  };
  await session.tryLockOhos(first);
  const closing = first.close();
  try {
    await assert.rejects(session.tryLockOhos(second), { code: 'EAGAIN' });
  } finally {
    gate.resolve();
    await closing;
  }
  await session.tryLockOhos(second);
});

test('close errors remain visible but cannot strand a lock on a closed descriptor', async () => {
  const path = join(directory, 'lock');
  const first = await handleAt(path);
  const second = await handleAt(path);
  const close = first.close;
  first.close = async () => { await close(); throw errno('EIO'); };
  await session.tryLockOhos(first);
  await assert.rejects(first.close(), { code: 'EIO' });
  assert.equal(first.fd, -1);
  await session.tryLockOhos(second);
});

test('closing during stat cannot install a stale lock', async () => {
  const path = join(directory, 'lock');
  const first = await handleAt(path);
  const second = await handleAt(path);
  const started = deferred();
  const gate = deferred();
  const inspect = first.stat.bind(first);
  first.stat = async (...args) => {
    const result = await inspect(...args);
    started.resolve();
    await gate.promise;
    return result;
  };
  const acquisition = session.tryLockOhos(first);
  await started.promise;
  await first.close();
  gate.resolve();
  await assert.rejects(acquisition, { code: 'EBADF' });
  await session.tryLockOhos(second);
});

test('repeated close/open cycles do not leak locks or confuse reused descriptor numbers', async () => {
  const path = join(directory, 'lock');
  for (let i = 0; i < 32; i++) {
    const handle = await handleAt(path);
    await session.tryLockOhos(handle);
    await handle.close();
    await handle.close();
    assert.equal(session.ohosWriteLocks.size, 0);
  }
});

test('a worker cannot create an independent lock table for the same engine store', async () => {
  const worker = new Worker(`
    const { parentPort, workerData } = require('node:worker_threads');
    (async () => {
      const { loadInternals } = await import(workerData.helper);
      const { tryLockOhos } = await loadInternals('@deepseek-ai/dsh-session-persistence-jsonl', ['tryLockOhos']);
      try { await tryLockOhos(null); parentPort.postMessage('unexpected-success'); }
      catch (error) { parentPort.postMessage(error.code); }
    })().catch((error) => { throw error; });
  `, { eval: true, workerData: { helper: new URL('./load-internals.mjs', import.meta.url).href } });
  try {
    const code = await new Promise((resolve, reject) => {
      worker.once('message', resolve);
      worker.once('error', reject);
    });
    assert.equal(code, 'ERR_OHOS_LOCK_MAIN_THREAD_ONLY');
  } finally {
    await worker.terminate();
  }
});
