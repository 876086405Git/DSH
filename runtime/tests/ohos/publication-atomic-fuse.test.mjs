import { symlinkFixture } from './host-link-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { setImmediate as turn } from 'node:timers/promises';
import { openOwnershipLedger } from '../../ohos/publication/ledger.mjs';
import { createAtomicPublisher } from '../../ohos/publication/atomic.mjs';
import { openAtomicFuse, readSystemBuildIdentity } from '../../ohos/publication/atomic-fuse.mjs';

// This suite uses the actual pre-Start linked Linux fixture for flock/xattr and
// the real publication test. Injected commit callbacks below test state/error
// routing; they are not reported as target renameat2 capability measurements.
const native = process._linkedBinding('dsh_ohos_publication');
const systemVersion = 'explicit-test-build-A';
const record = (state, version = systemVersion, ownerId = 'old-process') =>
  ({ schema: 1, systemVersion: version, state, ownerId });
const systemError = (code, syscall = 'renameat2') => Object.assign(new Error('injected system result'), { code, syscall });
const containsCode = (error, code) => error?.code === code || (error?.cause && containsCode(error.cause, code))
  || (Array.isArray(error?.errors) && error.errors.some(item => containsCode(item, code)));

async function fixture(t, { onEvent = () => {}, initial } = {}) {
  const root = await fs.mkdtemp(join(tmpdir(), 'dsh-atomic-fuse-'));
  const directory = join(root, 'ownership');
  await fs.mkdir(directory, { mode: 0o700 });
  const statePath = join(directory, 'atomic-state.json');
  if (initial !== undefined) await fs.writeFile(statePath, JSON.stringify(initial) + '\n', { mode: 0o600 });
  const pendingPath = join(directory, 'atomic-state.pending');
  const events = [], ledgers = [];
  let round = 0, atomicDirectorySync = false, lockCalls = 0;
  const hit = async (stage, details = {}) => {
    const value = { stage, round, ...details }; events.push(value); await onEvent(value);
  };
  const instrumented = {
    ...fs,
    async open(path, ...args) {
      const isPending = path === pendingPath;
      if (isPending) { round++; await hit('state-open'); }
      const handle = await fs.open(path, ...args);
      return new Proxy(handle, {
        get(target, name) {
          const value = Reflect.get(target, name, target);
          if (isPending && ['writeFile', 'sync', 'close'].includes(name)) {
            return async (...parameters) => {
              if (name !== 'close') await hit('state-' + (name === 'writeFile' ? 'write' : name));
              const result = await value.apply(target, parameters);
              if (name === 'close') await hit('state-close');
              else events.push({ stage: 'state-' + (name === 'writeFile' ? 'write' : name) + '-done', round });
              return result;
            };
          }
          if (path === directory && name === 'sync') {
            return async () => {
              const atomic = atomicDirectorySync;
              try {
                await hit('directory-sync', { atomic });
                const result = await value.call(target);
                events.push({ stage: 'directory-sync-done', round, atomic });
                return result;
              } finally { if (atomic) atomicDirectorySync = false; }
            };
          }
          return typeof value === 'function' ? value.bind(target) : value;
        },
      });
    },
    async rename(from, to) {
      if (from === pendingPath && to === statePath) {
        await hit('state-rename');
        await fs.rename(from, to);
        atomicDirectorySync = true;
        return;
      }
      return fs.rename(from, to);
    },
  };
  const openLedger = async () => {
    const ledger = await openOwnershipLedger({ directory, ownerId: randomUUID(), fs: instrumented,
      lockExclusive(fd) { lockCalls++; return native.lockExclusive(fd); },
      setOwnershipMarker: native.setOwnershipMarker, getOwnershipMarker: native.getOwnershipMarker });
    ledgers.push(ledger); return ledger;
  };
  const ledger = await openLedger();
  t.after(async () => {
    for (const item of ledgers) await item.close();
    await fs.rm(root, { recursive: true, force: true });
  });
  return { root, directory, statePath, pendingPath, events, ledger, instrumented, openLedger,
    read: () => JSON.parse(readFileSync(statePath, 'utf8')),
    get round() { return round; }, get lockCalls() { return lockCalls; },
    open: (item = ledger, version = systemVersion) => openAtomicFuse({ storage: item.publicationAtomicState,
      ownerId: item.ownerId, systemVersion: version }) };
}

test('system identity uses four exact fields, fixed JSON order and two stable reads', () => {
  let calls = 0;
  const values = { osFullName: 'OpenHarmony test', displayVersion: '6.1', incrementalVersion: '42', securityPatchTag: '2026-10' };
  const a = readSystemBuildIdentity(() => { calls++; return { ...values }; });
  const b = readSystemBuildIdentity(() => ({ securityPatchTag: '2026-10', incrementalVersion: '42', displayVersion: '6.1', osFullName: 'OpenHarmony test' }));
  assert.equal(calls, 2); assert.equal(a.systemVersion, b.systemVersion);
  assert.match(a.systemVersion, /^ohos-build-v1:[0-9a-f]{64}$/);
  assert(Object.isFrozen(a.identity));
  assert.notEqual(a.systemVersion, readSystemBuildIdentity(() => ({ ...values, incrementalVersion: '43' })).systemVersion);
  assert.doesNotThrow(() => readSystemBuildIdentity(() => ({ ...values, osFullName: 'a'.repeat(1024) })));
  for (const invalid of [null, [], {}, { ...values, extra: 'x' }, { ...values, osFullName: '' },
    { ...values, osFullName: ' \t\n' }, { ...values, osFullName: 'x\0y' },
    { ...values, osFullName: '中'.repeat(342) }, { ...values, osFullName: '\ud800' }]) {
    assert.throws(() => readSystemBuildIdentity(() => invalid), { code: 'ERR_OHOS_PUBLICATION_SYSTEM_BUILD' });
  }
  let epoch = 0;
  assert.throws(() => readSystemBuildIdentity(() => ({ ...values, incrementalVersion: String(++epoch) })),
    { code: 'ERR_OHOS_PUBLICATION_SYSTEM_BUILD' });
});

test('first call sees durable trying; normal subsequent successes do not rewrite; next process re-arms', async t => {
  const f = await fixture(t); const fuse = await f.open();
  assert.equal(fuse.atomic, 'untried'); await assert.rejects(fs.stat(f.statePath), { code: 'ENOENT' });
  const invoke = () => {
    assert.equal(f.read().state, 'trying');
    assert(f.events.some(event => event.stage === 'directory-sync-done' && event.atomic));
  };
  assert.deepEqual(await fuse.run(invoke), { atomic: true });
  assert.equal(fuse.atomic, 'available'); assert.equal(f.round, 2);
  const old = await fs.readFile(f.statePath);
  await fuse.run(() => {}); assert.equal(f.round, 2); assert.deepEqual(await fs.readFile(f.statePath), old);
  await f.ledger.close();
  const next = await f.openLedger(), restarted = await f.open(next);
  assert.equal(restarted.atomic, 'available'); assert.equal(f.round, 2);
  await restarted.run(() => { assert.equal(f.read().state, 'trying'); assert.equal(f.read().ownerId, next.ownerId); });
  assert.equal(f.round, 4); assert.equal(restarted.atomic, 'available');
});

test('interrupted same-build trial becomes durable disabled; new system build may try again', async t => {
  const f = await fixture(t, { initial: record('trying') }); const fuse = await f.open();
  assert.equal(fuse.atomic, 'disabled-after-crash'); assert.equal(f.read().state, 'disabled-after-crash');
  let calls = 0;
  assert.deepEqual(await fuse.run(() => { calls++; }), { atomic: false, reason: 'disabled-after-crash' });
  assert.equal(calls, 0);
  await f.ledger.close(); const next = await f.openLedger();
  const changed = await f.open(next, 'explicit-test-build-B');
  assert.equal(changed.atomic, 'untried');
  await changed.run(() => { calls++; assert.equal(f.read().systemVersion, 'explicit-test-build-B'); });
  assert.equal(calls, 1); assert.equal(changed.atomic, 'available');
});

test('true native EINVAL is persistent unsupported, including after earlier available on another target', async t => {
  const f = await fixture(t); const fuse = await f.open();
  await fuse.run(() => {});
  assert.deepEqual(await fuse.run(() => { throw systemError('EINVAL'); }), { atomic: false, reason: 'unsupported' });
  assert.equal(f.read().state, 'unsupported');
  let calls = 0; await fuse.run(() => { calls++; }); assert.equal(calls, 0);
  await f.ledger.close(); const next = await f.openLedger(); const restarted = await f.open(next);
  await restarted.run(() => { calls++; }); assert.equal(calls, 0); assert.equal(restarted.atomic, 'unsupported');
});

for (const code of ['EEXIST', 'EXDEV', 'EACCES', 'EPERM', 'ENOSYS']) {
  test(`returned ${code} is exact original error, untried, never unsupported`, async t => {
    const f = await fixture(t); const fuse = await f.open(); const original = systemError(code);
    await assert.rejects(fuse.run(() => { throw original; }), error => error === original);
    assert.equal(fuse.atomic, 'untried'); assert.equal(f.read().state, 'untried');
    await fuse.run(() => {}); assert.equal(fuse.atomic, 'available');
  });
}

test('pre-commit EINVAL and a different syscall EINVAL cannot claim native unsupported', async t => {
  const f = await fixture(t); const fuse = await f.open(); let calls = 0;
  const checkError = systemError('EINVAL');
  await assert.rejects(fuse.run(() => { calls++; }, { beforeCommit() { throw checkError; } }), error => error === checkError);
  assert.equal(calls, 0); assert.equal(fuse.atomic, 'untried');
  const other = systemError('EINVAL', 'fsync');
  await assert.rejects(fuse.run(() => { throw other; }), error => error === other);
  assert.equal(fuse.atomic, 'untried');
});

test('asynchronous or invalid commit return does not establish available', async t => {
  const f = await fixture(t); const fuse = await f.open();
  await assert.rejects(fuse.run(() => Promise.resolve()), TypeError);
  assert.equal(f.read().state, 'untried');
  await assert.rejects(fuse.run(() => {}, { beforeCommit: () => Promise.resolve() }), TypeError);
  assert.equal(f.read().state, 'untried');
});

for (const stage of ['state-open', 'state-write', 'state-sync', 'state-close', 'state-rename', 'directory-sync']) {
  test(`trial persistence failure at ${stage} makes no native call and poisons later operations`, async t => {
    const injected = systemError(stage === 'state-sync' ? 'EINVAL' : 'EIO', stage);
    const f = await fixture(t, { onEvent(event) {
      if (event.stage === stage && (stage !== 'directory-sync' || event.atomic)) throw injected;
    } });
    const fuse = await f.open(); let calls = 0;
    await assert.rejects(fuse.run(() => { calls++; }), error => containsCode(error, 'ERR_OHOS_PUBLICATION_ATOMIC_STATE_WRITE'));
    assert.equal(calls, 0);
    await assert.rejects(fuse.run(() => { calls++; }), { code: 'ERR_OHOS_LEDGER_POISONED' });
    assert.equal(calls, 0);
  });
}

test('non-EINVAL plus failure to clear trying preserves original error and reports state failure', async t => {
  const f = await fixture(t, { onEvent(event) { if (event.stage === 'state-open' && event.round === 2) throw systemError('EIO', 'open'); } });
  const fuse = await f.open(); const original = systemError('EEXIST');
  await assert.rejects(fuse.run(() => { throw original; }), error => {
    assert(error instanceof AggregateError); assert.equal(error.cause, original);
    assert(error.errors.includes(original)); assert(containsCode(error, 'ERR_OHOS_PUBLICATION_ATOMIC_STATE_WRITE'));
    return true;
  });
  assert.equal(f.read().state, 'trying');
});

test('actual successful rename followed by state failure preserves final and never copies fallback', async t => {
  const f = await fixture(t, { onEvent(event) { if (event.stage === 'state-open' && event.round === 2) throw systemError('EIO', 'open'); } });
  const fuse = await f.open(); let nativeCalls = 0, fallbackCalls = 0;
  const source = join(f.root, 'source'), target = join(f.root, 'final');
  const payload = Buffer.alloc(130031, 0x5a); await fs.writeFile(source, payload);
  const publish = createAtomicPublisher({ ledger: f.ledger, atomicFuse: fuse,
    renameNoReplace(from, to) { nativeCalls++; return native.renameNoReplace(from, to); },
    fs: { ...fs, async link() { throw systemError('EACCES', 'link'); } },
    onFallback() { fallbackCalls++; } });
  await assert.rejects(publish(source, target), error => containsCode(error, 'ERR_OHOS_PUBLICATION_COMMITTED_STATE'));
  assert.equal(nativeCalls, 1); assert.equal(fallbackCalls, 0);
  assert.deepEqual(await fs.readFile(target), payload); assert.deepEqual(await fs.readFile(source), payload);
  assert.equal(f.read().state, 'trying'); assert.equal(publish.pendingCount, 0);
});

test('same ledger queue serializes first trial, and close waits accepted native/state work', async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  const f = await fixture(t, { async onEvent(event) {
    if (event.stage === 'state-write' && event.round === 1) { entered.resolve(); await release.promise; }
  } });
  const fuse = await f.open(); let calls = 0, closed = false;
  const first = fuse.run(() => { calls++; }); await entered.promise;
  const second = fuse.run(() => { calls++; });
  const closing = f.ledger.close().then(() => { closed = true; });
  await turn(); assert.equal(closed, false); assert.equal(calls, 0);
  await assert.rejects(fuse.run(() => { calls++; }), { code: 'ERR_OHOS_LEDGER_CLOSED' });
  release.resolve(); await Promise.all([first, second, closing]);
  assert.equal(closed, true); assert.equal(calls, 2); assert.equal(f.round, 2);
});

test('fuse shares the already-held flock; a second live ledger cannot enter', async t => {
  const f = await fixture(t); await f.open(); assert.equal(f.lockCalls, 1);
  await assert.rejects(f.openLedger(), { code: 'ERR_OHOS_LEDGER_BUSY' });
});

test('a state transaction drains accidentally unawaited IO and revokes its IO handles', async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  const f = await fixture(t, { async onEvent(event) { if (event.stage === 'state-write') { entered.resolve(); await release.promise; } } });
  let saved, ended = false;
  const writing = f.ledger.publicationAtomicState.transaction(io => {
    saved = io; io.commit(record('untried', systemVersion, f.ledger.ownerId)); return 'return-before-IO';
  }).then(value => { ended = true; return value; });
  await entered.promise; await turn(); assert.equal(ended, false);
  release.resolve(); assert.equal(await writing, 'return-before-IO');
  assert.equal(f.read().state, 'untried');
  await assert.rejects(saved.read(), { code: 'ERR_OHOS_PUBLICATION_ATOMIC_TRANSACTION' });
});

test('corrupt committed state preserves pending evidence, never silently resets build', async t => {
  const f = await fixture(t); await fs.writeFile(f.statePath, '{broken'); await fs.writeFile(f.pendingPath, 'pending-evidence');
  await assert.rejects(f.open(), { code: 'ERR_OHOS_PUBLICATION_ATOMIC_STATE_CORRUPT' });
  assert.equal(await fs.readFile(f.pendingPath, 'utf8'), 'pending-evidence');
  assert.equal(await fs.readFile(f.statePath, 'utf8'), '{broken');
});

test('valid committed state clears only the exact orphan pending slot under the held lock', async t => {
  const f = await fixture(t, { initial: record('unsupported') });
  await fs.writeFile(f.pendingPath, 'interrupted-atomic-write');
  const neighbour = f.pendingPath + '.foreign'; await fs.writeFile(neighbour, 'keep');
  const fuse = await f.open(); assert.equal(fuse.atomic, 'unsupported');
  await assert.rejects(fs.stat(f.pendingPath), { code: 'ENOENT' });
  assert.equal(await fs.readFile(neighbour, 'utf8'), 'keep');
});

for (const shape of ['symlink', 'directory', 'oversized']) {
  test(`invalid ${shape} state fails closed without replacing the entry`, async t => {
    const f = await fixture(t);
    if (shape === 'symlink') {
      const outside = join(f.root, 'untouched'); await fs.writeFile(outside, 'untouched'); await symlinkFixture(outside, f.statePath);
    } else if (shape === 'directory') await fs.mkdir(f.statePath);
    else await fs.writeFile(f.statePath, 'x'.repeat(32769));
    await assert.rejects(f.open());
    const info = await fs.lstat(f.statePath);
    if (shape === 'symlink') { assert(info.isSymbolicLink()); assert.equal(await fs.readFile(join(f.root, 'untouched'), 'utf8'), 'untouched'); }
    else if (shape === 'directory') assert(info.isDirectory());
    else assert.equal(info.size, 32769);
  });
}

test('only one live fuse may own the ledger transaction endpoint', async t => {
  const f = await fixture(t); await f.open();
  await assert.rejects(f.open(), { code: 'ERR_OHOS_PUBLICATION_ATOMIC_FUSE_DUPLICATE' });
});
