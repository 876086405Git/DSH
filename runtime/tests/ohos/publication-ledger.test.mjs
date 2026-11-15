import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { openOwnershipLedger } from '../../ohos/publication/ledger.mjs';

const native = process._linkedBinding('dsh_ohos_publication');
const nativeOptions = { lockExclusive: native.lockExclusive,
  setOwnershipMarker: native.setOwnershipMarker, getOwnershipMarker: native.getOwnershipMarker };
const absent = path => assert.rejects(fs.lstat(path), { code: 'ENOENT' });
const disk = f => fs.readFile(join(f.directory, 'ledger.json'), 'utf8').then(JSON.parse,
  error => { if (error.code === 'ENOENT') return { schema: 2, entries: [] }; throw error; });
const receipt = info => ({ dev: String(info.dev), ino: String(info.ino) });
const error = (code, message = code) => Object.assign(new Error(message), { code });

async function fixture(t) {
  const root = await fs.mkdtemp(join(tmpdir(), 'dsh-ledger-boundary-'));
  const directory = join(root, 'ownership'), finalPath = join(root, 'final');
  const ledgers = [], handles = [];
  t.after(async () => {
    await Promise.allSettled(handles.map(f => f.close()));
    await Promise.allSettled(ledgers.map(l => l.close()));
    await fs.rm(root, { recursive: true, force: true });
  });
  const f = { root, directory, finalPath,
    async open(options = {}) {
      const ledger = await openOwnershipLedger({ directory, ownerId: randomUUID(), ...nativeOptions, ...options });
      ledgers.push(ledger); return ledger;
    },
    async create(ledger, name = 'temporary') {
      const path = join(root, name), token = await ledger.reserve(path, finalPath);
      await absent(path);
      const file = await fs.open(path, 'wx', 0o600); handles.push(file);
      const info = receipt(await file.stat({ bigint: true }));
      await ledger.identify(token, info);
      return { path, token, file, info };
    },
  };
  return f;
}

function wrappedFs(intercept) {
  return { ...fs,
    async open(path, ...args) {
      const handle = await fs.open(path, ...args);
      return new Proxy(handle, { get(target, key) {
        const value = Reflect.get(target, key, target);
        if (typeof value !== 'function') return value;
        return (...callArgs) => intercept(String(path), key, callArgs, () => value.apply(target, callArgs));
      } });
    },
    rename: (source, target) => intercept(String(source), 'rename', [target], () => fs.rename(source, target)),
  };
}

test('persistent reservation, marker, current owner preservation and foreign owner cleanup', async t => {
  const f = await fixture(t), ledger = await f.open();
  await fs.writeFile(f.finalPath, 'existing-final');
  const own = await f.create(ledger);
  assert.equal(native.getOwnershipMarker(own.file.fd), own.token);
  await own.file.write('half-copy');
  assert.equal((await disk(f)).entries[0].state, 'identified');
  await assert.rejects(ledger.release(own.token), { code: 'ERR_OHOS_LEDGER_RESOURCE_PRESENT' });
  assert.deepEqual(await ledger.recover(), { removed: [], missing: [], unresolved: [] });
  await own.file.close(); await ledger.close();
  const next = await f.open(), report = await next.recover();
  assert.equal(report.removed.length, 1); assert.equal(report.unresolved.length, 0);
  await absent(own.path); assert.equal(await fs.readFile(f.finalPath, 'utf8'), 'existing-final');
  assert.deepEqual((await disk(f)).entries, []);
});

test('reserved unknowns and unregistered matching prefixes are preserved; absent intents clear', async t => {
  const f = await fixture(t), ledger = await f.open();
  const unknown = join(f.root, 'unknown'), missing = join(f.root, 'absent');
  const unregistered = join(f.root, '.dsh-ohos-publish-unregistered.tmp');
  await ledger.reserve(unknown, f.finalPath); await fs.writeFile(unknown, 'unknown-owner');
  await ledger.reserve(missing, f.finalPath); await fs.writeFile(unregistered, 'unregistered');
  await ledger.close(); const next = await f.open(), result = await next.recover();
  assert.equal(result.missing.length, 1); assert.equal(result.unresolved.length, 1);
  assert.equal(result.removed.length, 0); assert.equal((await disk(f)).entries.length, 1);
  assert.equal(await fs.readFile(unknown, 'utf8'), 'unknown-owner');
  assert.equal(await fs.readFile(unregistered, 'utf8'), 'unregistered');
});

test('reservation collision may be withdrawn without deleting the preexisting file', async t => {
  const f = await fixture(t), ledger = await f.open(), path = join(f.root, 'foreign');
  await fs.writeFile(path, 'foreign'); const token = await ledger.reserve(path, f.finalPath);
  await assert.rejects(fs.open(path, 'wx'), { code: 'EEXIST' });
  assert.equal(await ledger.release(token), true); assert.equal(await ledger.release(token), false);
  assert.equal(await fs.readFile(path, 'utf8'), 'foreign'); assert.deepEqual((await disk(f)).entries, []);
});

test('real flock excludes another ledger and the fixed lock inode survives close/reopen', async t => {
  const f = await fixture(t), first = await f.open(), path = join(f.directory, '.lock');
  const before = receipt(await fs.stat(path, { bigint: true }));
  await assert.rejects(f.open(), { code: 'ERR_OHOS_LEDGER_BUSY' });
  await first.close(); const second = await f.open();
  assert.deepEqual(receipt(await fs.stat(path, { bigint: true })), before);
  await second.close();
});

test('eight interleaved owners of resources do not lose serialized reservations or releases', async t => {
  const f = await fixture(t), ledger = await f.open();
  await Promise.all(Array.from({ length: 8 }, async (_, i) => {
    const own = await f.create(ledger, `temporary-${i}`);
    await own.file.write(`part-${i}`); await fs.unlink(own.path); await own.file.close();
    assert.equal(await ledger.release(own.token), true);
  }));
  assert.deepEqual((await disk(f)).entries, []);
});

test('a replaced inode or missing creation marker preserves the named foreign file', async t => {
  const f = await fixture(t), ledger = await f.open(), own = await f.create(ledger);
  await own.file.close(); await ledger.close(); await fs.unlink(own.path);
  const replacement = await fs.open(own.path, 'wx', 0o600);
  await replacement.writeFile('replacement');
  assert.equal(native.getOwnershipMarker(replacement.fd), undefined); await replacement.close();
  const next = await f.open(), result = await next.recover();
  assert.equal(result.removed.length, 0); assert.equal(result.unresolved.length, 1);
  assert.equal(await fs.readFile(own.path, 'utf8'), 'replacement'); assert.equal((await disk(f)).entries.length, 1);
});

test('ledger files, subpaths and parent aliases cannot be registered as resources or targets', async t => {
  const f = await fixture(t), ledger = await f.open(), external = join(f.root, 'external');
  const alias = join(f.root, 'alias'); await fs.symlink(f.directory, alias);
  for (const path of [f.directory, join(f.directory, '.lock'), join(f.directory, 'ledger.json'),
    join(f.directory, 'ledger.pending'), join(f.directory, 'sub/file'), join(alias, '.lock')]) {
    await assert.rejects(ledger.reserve(path, f.finalPath), { code: 'ERR_OHOS_LEDGER_RESOURCE' });
    await assert.rejects(ledger.reserve(external, path), { code: 'ERR_OHOS_LEDGER_RESOURCE' });
  }
  assert.deepEqual((await disk(f)).entries, []);
});

test('corrupt ledger preserves the committed and pending evidence and releases its lock', async t => {
  const f = await fixture(t), first = await f.open(); await first.close();
  const book = join(f.directory, 'ledger.json'), pending = join(f.directory, 'ledger.pending');
  await fs.writeFile(book, '{broken'); await fs.writeFile(pending, 'evidence');
  await assert.rejects(f.open(), { code: 'ERR_OHOS_LEDGER_CORRUPT' });
  assert.equal(await fs.readFile(book, 'utf8'), '{broken'); assert.equal(await fs.readFile(pending, 'utf8'), 'evidence');
  await fs.writeFile(book, JSON.stringify({ schema: 2, entries: [] }));
  const next = await f.open(); await absent(pending); await next.close();
});

test('a corrupt record naming the lock is rejected before any recovery mutation', async t => {
  const f = await fixture(t), first = await f.open(); await first.close();
  const lock = join(f.directory, '.lock'), info = receipt(await fs.stat(lock, { bigint: true }));
  const token = randomUUID();
  await fs.writeFile(join(f.directory, 'ledger.json'), JSON.stringify({ schema: 2, entries: [{
    token, marker: token, ownerId: 'old-process', pid: 123, state: 'identified', path: lock,
    finalPath: f.finalPath, ...info,
  }] }));
  await assert.rejects(f.open(), { code: 'ERR_OHOS_LEDGER_CORRUPT' });
  assert.deepEqual(receipt(await fs.stat(lock, { bigint: true })), info);
});

test('a symbolic link in the fixed pending slot is refused without touching its victim', async t => {
  const f = await fixture(t), first = await f.open(); await first.close();
  const victim = join(f.root, 'victim'), pending = join(f.directory, 'ledger.pending');
  await fs.writeFile(victim, 'keep'); await fs.symlink(victim, pending);
  await assert.rejects(f.open(), { code: 'ERR_OHOS_LEDGER_PENDING' });
  assert.equal(await fs.readFile(victim, 'utf8'), 'keep'); assert.equal((await fs.lstat(pending)).isSymbolicLink(), true);
});

for (const phase of ['writeFile', 'pending-sync', 'rename', 'directory-sync']) {
  test(`atomic persistence failure at ${phase} poisons the instance; restart reconciles exact pending slot`, async t => {
    const f = await fixture(t); let armed = false, fired = false;
    const injected = error('EIO', `injected-${phase}`);
    const wrapped = wrappedFs((path, op, args, run) => {
      const pending = path === join(f.directory, 'ledger.pending');
      const hit = (phase === 'writeFile' && pending && op === 'writeFile')
        || (phase === 'pending-sync' && pending && op === 'sync')
        || (phase === 'rename' && pending && op === 'rename')
        || (phase === 'directory-sync' && path === f.directory && op === 'sync');
      if (armed && !fired && hit) { fired = true; throw injected; }
      return run();
    });
    const ledger = await f.open({ fs: wrapped }), temporary = join(f.root, 'never-created');
    armed = true;
    await assert.rejects(ledger.reserve(temporary, f.finalPath), e => e === injected);
    assert.equal(fired, true); await absent(temporary);
    await assert.rejects(ledger.reserve(join(f.root, 'also-not-created'), f.finalPath), { code: 'ERR_OHOS_LEDGER_POISONED' });
    await ledger.close(); const next = await f.open(), result = await next.recover();
    assert.equal(result.removed.length, 0); assert.equal(result.unresolved.length, 0);
    assert.equal(result.missing.length, phase === 'directory-sync' ? 1 : 0);
    assert.deepEqual((await disk(f)).entries, []); await absent(join(f.directory, 'ledger.pending'));
  });
}

test('unsupported file markers fail before identified state; no inode-only recovery fallback', async t => {
  const f = await fixture(t), ledger = await f.open({ setOwnershipMarker() { throw error('ENOTSUP'); } });
  const path = join(f.root, 'unsupported'), token = await ledger.reserve(path, f.finalPath);
  const file = await fs.open(path, 'wx', 0o600);
  try {
    await assert.rejects(ledger.identify(token, receipt(await file.stat({ bigint: true }))), { code: 'ENOTSUP' });
    assert.equal((await disk(f)).entries[0].state, 'reserved'); assert.equal((await file.stat()).size, 0);
  } finally { await file.close(); }
  await ledger.close(); const next = await f.open(), result = await next.recover();
  assert.equal(result.unresolved.length, 1); assert.equal(result.removed.length, 0); await fs.stat(path);
});

test('failure syncing the actual marker never commits an identified record', async t => {
  const f = await fixture(t), path = join(f.root, 'marker-sync-failure');
  const ledger = await f.open({ fs: wrappedFs((p, op, args, run) => {
    if (p === path && op === 'sync') throw error('EIO', 'injected-file-sync'); return run();
  }) });
  const token = await ledger.reserve(path, f.finalPath), file = await fs.open(path, 'wx', 0o600);
  try {
    await assert.rejects(ledger.identify(token, receipt(await file.stat({ bigint: true }))), { code: 'EIO' });
    assert.equal(native.getOwnershipMarker(file.fd), token); assert.equal((await disk(f)).entries[0].state, 'reserved');
  } finally { await file.close(); }
  await ledger.close(); const next = await f.open(), result = await next.recover();
  assert.equal(result.unresolved.length, 1); assert.equal(result.removed.length, 0);
});

for (const mode of ['unsupported', 'mismatch']) {
  test(`recovery with ${mode} marker read retains the exact entry and file`, async t => {
    const f = await fixture(t), ledger = await f.open(), own = await f.create(ledger);
    await own.file.write('owned'); await own.file.close(); await ledger.close();
    const next = await f.open({ getOwnershipMarker() { if (mode === 'unsupported') throw error('ENOTSUP'); return 'wrong-marker'; } });
    const result = await next.recover(); assert.equal(result.unresolved.length, 1); assert.equal(result.removed.length, 0);
    assert.equal(await fs.readFile(own.path, 'utf8'), 'owned'); assert.equal((await disk(f)).entries.length, 1);
  });
}

test('committed rename without release clears only its absent old name on restart', async t => {
  const f = await fixture(t), ledger = await f.open(), own = await f.create(ledger);
  await own.file.write('complete'); await own.file.sync(); native.renameNoReplace(own.path, f.finalPath);
  await own.file.close(); await ledger.close(); const next = await f.open(), result = await next.recover();
  assert.equal(result.missing.length, 1); assert.equal(result.removed.length, 0);
  assert.equal(await fs.readFile(f.finalPath, 'utf8'), 'complete'); assert.deepEqual((await disk(f)).entries, []);
});

test('close rejects new operations, waits for an in-flight durable write, then releases flock', async t => {
  const f = await fixture(t), entered = Promise.withResolvers(), unblock = Promise.withResolvers();
  let blocked = false;
  const ledger = await f.open({ fs: wrappedFs(async (path, op, args, run) => {
    if (!blocked && path === join(f.directory, 'ledger.pending') && op === 'writeFile') {
      blocked = true; entered.resolve(); await unblock.promise;
    }
    return run();
  }) });
  const reservation = ledger.reserve(join(f.root, 'queued'), f.finalPath); await entered.promise;
  let closed = false; const closing = ledger.close().then(() => { closed = true; });
  await assert.rejects(ledger.reserve(join(f.root, 'too-late'), f.finalPath), { code: 'ERR_OHOS_LEDGER_CLOSED' });
  await assert.rejects(f.open(), { code: 'ERR_OHOS_LEDGER_BUSY' }); assert.equal(closed, false);
  unblock.resolve(); await reservation; await closing; assert.equal(closed, true);
  const next = await f.open(); assert.equal((await next.recover()).missing.length, 1);
});
