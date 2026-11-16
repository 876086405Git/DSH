import { symlinkFixture } from './host-link-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { createAtomicPublisher, cleanupOwnedTemporary } from '../../ohos/publication/atomic.mjs';
import { openOwnershipLedger } from '../../ohos/publication/ledger.mjs';

// This suite requires the real native syscall fixture or the target linked
// module. Missing native support is a failure, never a skipped test.
const native = process._linkedBinding('dsh_ohos_publication');
assert.equal(typeof native.renameNoReplace, 'function');
const denyLink = async () => { throw Object.assign(new Error('test: link unavailable'), { code: 'EACCES' }); };
const io = { ...fs, link: denyLink };
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const systemError = (code, syscall = 'renameat2') => Object.assign(new Error(`${syscall}: ${code}`), { code, syscall });
async function fixture(t, data = Buffer.alloc(3 * 65536 + 17, 97)) {
  const directory = await fs.mkdtemp(join(tmpdir(), 'dsh-publication-native-'));
  let ledger;
  t.after(async () => {
    try { await ledger?.close(); }
    finally { await fs.rm(directory, { recursive: true, force: true }); }
  });
  ledger = await openOwnershipLedger({
    directory: join(directory, 'ownership'), ownerId: randomUUID(),
    lockExclusive: native.lockExclusive,
    setOwnershipMarker: native.setOwnershipMarker,
    getOwnershipMarker: native.getOwnershipMarker,
  });
  const source = join(directory, 'source'), target = join(directory, 'final');
  await fs.writeFile(source, data);
  return { directory, source, target, data, ledger };
}
async function absent(path) { await assert.rejects(fs.lstat(path), { code: 'ENOENT' }); }
async function noTemporary(directory) {
  assert.deepEqual((await fs.readdir(directory)).filter(name => name.startsWith('.dsh-ohos-publish-')), []);
}
function publisher(f, options = {}) {
  return createAtomicPublisher({ fs: io, renameNoReplace: native.renameNoReplace, ledger: f.ledger, ...options });
}
async function sourceUnchanged(f) { assert.equal(digest(await fs.readFile(f.source)), digest(f.data)); }
function interceptOpen(intercept) {
  return { ...io, async open(path, ...args) {
    const handle = await fs.open(path, ...args);
    if (args[0] === 'wx') await intercept(handle, path);
    return handle;
  } };
}

test('real NOREPLACE publishes all bytes, preserves source and removes its temporary', async t => {
  const f = await fixture(t);
  assert.deepEqual(await publisher(f)(f.source, f.target), { method: 'rename-noreplace' });
  assert.equal(digest(await fs.readFile(f.target)), digest(f.data));
  await sourceUnchanged(f); await noTemporary(f.directory);
});

test('zero-byte source remains a valid complete publication', async t => {
  const f = await fixture(t, Buffer.alloc(0));
  assert.deepEqual(await publisher(f)(f.source, f.target), { method: 'rename-noreplace' });
  assert.equal((await fs.stat(f.target)).size, 0);
  await sourceUnchanged(f); await noTemporary(f.directory);
});

for (const bytes of [Buffer.alloc(0), Buffer.from('existing complete target')]) {
  test(`real existing final of length ${bytes.length} is EEXIST and remains unchanged`, async t => {
    const f = await fixture(t); await fs.writeFile(f.target, bytes);
    let fallback = false;
    await assert.rejects(publisher(f, { onFallback() { fallback = true; } })(f.source, f.target), { code: 'EEXIST' });
    assert.equal(fallback, false); assert.deepEqual(await fs.readFile(f.target), bytes);
    await sourceUnchanged(f); await noTemporary(f.directory);
  });
}

test('dangling final symlink is EEXIST; its entry and absent destination are preserved', async t => {
  const f = await fixture(t), missing = join(f.directory, 'not-created');
  await symlinkFixture(missing, f.target);
  await assert.rejects(publisher(f)(f.source, f.target), { code: 'EEXIST' });
  assert.equal(await fs.readlink(f.target), missing); await absent(missing);
  await sourceUnchanged(f); await noTemporary(f.directory);
});

test('source equal to target cannot be overwritten or removed', async t => {
  const f = await fixture(t);
  await assert.rejects(publisher(f)(f.source, f.source), { code: 'EEXIST' });
  await sourceUnchanged(f); await noTemporary(f.directory);
});

test('two callers for the same final preserve exactly one complete winner', async t => {
  const f = await fixture(t), source2 = join(f.directory, 'source2');
  const other = Buffer.alloc(2 * 65536 + 31, 98); await fs.writeFile(source2, other);
  const publish = publisher(f);
  const outcomes = await Promise.allSettled([publish(f.source, f.target), publish(source2, f.target)]);
  assert.equal(outcomes[0].status, 'fulfilled');
  assert.equal(outcomes[1].status, 'rejected'); assert.equal(outcomes[1].reason.code, 'EEXIST');
  assert.deepEqual(await fs.readFile(f.target), f.data);
  await sourceUnchanged(f); assert.deepEqual(await fs.readFile(source2), other); await noTemporary(f.directory);
});

test('only an injected native renameat2 EINVAL invokes the documented risky fallback', async t => {
  const f = await fixture(t); const records = [];
  const publish = publisher(f, { renameNoReplace() { throw systemError('EINVAL'); }, onFallback: event => records.push(event) });
  assert.deepEqual(await publish(f.source, f.target), { method: 'exclusive-copy-fallback' });
  assert.equal(records.length, 1); assert.match(records[0].risk, /partial final/);
  assert.deepEqual(await fs.readFile(f.target), f.data);
  await sourceUnchanged(f); await noTemporary(f.directory);
});

test('injected unsupported fallback still uses wx and preserves an existing empty final', async t => {
  const f = await fixture(t); await fs.writeFile(f.target, '');
  const publish = publisher(f, { renameNoReplace() { throw systemError('EINVAL'); } });
  await assert.rejects(publish(f.source, f.target), { code: 'EEXIST' });
  assert.equal((await fs.stat(f.target)).size, 0);
  await sourceUnchanged(f); await noTemporary(f.directory);
});

for (const [code, syscall] of [['EINVAL', 'fsync'], ['ENOSYS', 'renameat2'], ['EACCES', 'renameat2'], ['EXDEV', 'renameat2']]) {
  test(`${syscall} ${code} is propagated without a copy fallback`, async t => {
    const f = await fixture(t); let fallback = false;
    const error = systemError(code, syscall);
    await assert.rejects(publisher(f, { renameNoReplace() { throw error; }, onFallback() { fallback = true; } })(f.source, f.target), e => e === error);
    assert.equal(fallback, false); await absent(f.target); await sourceUnchanged(f); await noTemporary(f.directory);
  });
}

test('injected file sync EINVAL is outside the native EINVAL fallback gate', async t => {
  const f = await fixture(t); let commits = 0, fallbacks = 0;
  const error = systemError('EINVAL', 'fsync');
  const fsWithError = interceptOpen(handle => { handle.sync = async () => { throw error; }; });
  await assert.rejects(publisher(f, { fs: fsWithError, renameNoReplace() { commits++; }, onFallback() { fallbacks++; } })(f.source, f.target), e => e === error);
  assert.equal(commits, 0); assert.equal(fallbacks, 0);
  await absent(f.target); await sourceUnchanged(f); await noTemporary(f.directory);
});

test('abort while real fsync completion is held prevents the subsequent commit', async t => {
  const f = await fixture(t), controller = new AbortController();
  const reason = new Error('cancelled at fsync return boundary'); let commits = 0;
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  const delayed = interceptOpen(handle => {
    const sync = handle.sync.bind(handle);
    handle.sync = async () => { await sync(); entered.resolve(); await release.promise; };
  });
  const result = publisher(f, { fs: delayed, renameNoReplace(...args) { commits++; return native.renameNoReplace(...args); } })(f.source, f.target, { signal: controller.signal });
  await entered.promise; controller.abort(reason); release.resolve();
  await assert.rejects(result, e => e === reason);
  assert.equal(commits, 0); await absent(f.target); await sourceUnchanged(f); await noTemporary(f.directory);
});

test('a failed registration cleans only the already identified temporary', async t => {
  const f = await fixture(t); const error = new Error('record could not be persisted');
  await assert.rejects(publisher(f, { ledger: { ...f.ledger, identify() { throw error; } } })(f.source, f.target), e => e === error);
  await absent(f.target); await sourceUnchanged(f); await noTemporary(f.directory);
});

test('replaced temporary is not committed and cleanup preserves the replacement', async t => {
  const f = await fixture(t); let receipt;
  const replacement = Buffer.from('foreign replacement');
  const swapping = interceptOpen(async (handle, path) => {
    const info = await handle.stat({ bigint: true });
    receipt = { path, dev: String(info.dev), ino: String(info.ino) };
    const sync = handle.sync.bind(handle);
    handle.sync = async () => { await sync(); await fs.unlink(path); await fs.writeFile(path, replacement, { flag: 'wx' }); };
  });
  await assert.rejects(publisher(f, { fs: swapping })(f.source, f.target), e => {
    assert(e instanceof AggregateError);
    assert.equal(e.cause.code, 'ERR_OHOS_PUBLICATION_TEMP_REPLACED');
    return true;
  });
  assert.deepEqual(await fs.readFile(receipt.path), replacement);
  assert.throws(() => cleanupOwnedTemporary(receipt), { code: 'ERR_OHOS_PUBLICATION_TEMP_REPLACED' });
  await absent(f.target); await sourceUnchanged(f);
});

test('a close failure after commit cannot delete the complete final or source', async t => {
  const f = await fixture(t), error = new Error('injected close report');
  const badClose = interceptOpen(handle => {
    const close = handle.close.bind(handle);
    handle.close = async () => { await close(); throw error; };
  });
  await assert.rejects(publisher(f, { fs: badClose })(f.source, f.target), e => e === error);
  assert.deepEqual(await fs.readFile(f.target), f.data);
  await sourceUnchanged(f); await noTemporary(f.directory);
});

// Control records opt out of the legacy partial-final fallback; default calls above retain it.
test('requireAtomic uses real no-replace and refuses both native/fuse unsupported paths', async t => {
  const f = await fixture(t);
  assert.deepEqual(await publisher(f)(f.source, f.target, { requireAtomic: true }), { method: 'rename-noreplace' });
  await assert.rejects(publisher(f)(f.source, f.target, { requireAtomic: true }), { code: 'EEXIST' });
  assert.deepEqual(await fs.readFile(f.target), f.data);
  for (const reason of ['unsupported', 'disabled-after-crash']) {
    const target = join(f.directory, reason); let fallbacks = 0;
    const publish = publisher(f, { atomicFuse: { async run() { return { atomic: false, reason }; } },
      onFallback() { fallbacks++; } });
    await assert.rejects(publish(f.source, target, { requireAtomic: true }),
      { code: 'ERR_OHOS_PUBLICATION_ATOMIC_REQUIRED', reason });
    assert.equal(fallbacks, 0); await absent(target);
  }
  await sourceUnchanged(f); await noTemporary(f.directory);
});
