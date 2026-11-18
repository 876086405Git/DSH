import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join } from 'node:path';
import { LinuxInstallationOwner } from '../../ohos/linux/owner.mjs';
import { discardLinuxInstance, openLinuxInstance } from '../../ohos/linux/instance.mjs';
import { ownerFixture, until } from './linux-control-fixture.mjs';

const record = active => join(active.directory, 'instance.json');
const read = async active => JSON.parse(await fs.readFile(record(active), 'utf8'));
async function installed(t) {
  const f = await ownerFixture(t), owner = f.createOwner(), { active } = await owner.install();
  return { f, owner, active };
}
async function next(t, f, extra = {}) {
  const g = await ownerFixture(t, extra); let downloads = 0;
  g.internals.download.fetch = () => { downloads++; throw new Error('resume must not download'); };
  const owner = g.createOwner({ directory: f.data });
  return { g, owner, downloads: () => downloads };
}
function failDirectorySync(state) {
  let hit = false;
  return { fs: { ...fs, async open(path, ...args) {
    const handle = await fs.open(path, ...args);
    if (!/\.installation-[^/]+$/.test(path)) return handle;
    return new Proxy(handle, { get(object, key) {
      if (key === 'sync') return async () => {
        const current = JSON.parse(await fs.readFile(join(path, 'instance.json'), 'utf8'));
        if (!hit && current.state === state) { hit = true; throw Object.assign(new Error('explicit directory fsync failure after rename'), { code: 'EIO' }); }
        return object.sync();
      };
      const value = Reflect.get(object, key, object); return typeof value === 'function' ? value.bind(object) : value;
    } });
  } }, hit: () => hit };
}

test('normal controlled close reopens the same real target with fresh epoch and a separate directboot config', async t => {
  const { f, owner, active } = await installed(t), before = await fs.stat(active.target), original = await fs.readFile(active.target);
  const first = await owner.dispose(); assert.equal(first.cleanCheckpoint, true);
  assert.deepEqual(first.guestClose, { epoch: active.epoch, rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' });
  const saved = await read(active); assert.equal(saved.state, 'clean');
  const { g, owner: second, downloads } = await next(t, f), reopened = await second.install();
  assert.equal(second.bootMode, 'resume'); assert.equal(second.persistentInstanceId, owner.persistentInstanceId);
  assert.equal(reopened.active.target, active.target); assert.notEqual(reopened.active.epoch, active.epoch);
  assert.equal((await fs.stat(active.target)).ino, before.ino); assert.deepEqual(await fs.readFile(active.target), original);
  assert.equal(downloads(), 0); assert.equal(g.counts().created, 1);
  const config = JSON.parse(await fs.readFile(join(active.directory, 'resume.cfg'), 'utf8'));
  assert.deepEqual(Object.keys(config).filter(key => /^drive/.test(key)), ['drive0']);
  assert.deepEqual(config.drive0, { file: active.target }); assert.match(config.cmdline, /root=\/dev\/vda rw init=\/sbin\/dsh-init/);
  assert.match(config.cmdline, new RegExp('dsh.epoch=' + reopened.active.epoch));
  assert.equal((await read(active)).state, 'active');
  assert.equal((await second.dispose()).cleanCheckpoint, true);
  assert.equal((await read(active)).guestClose.epoch, reopened.active.epoch);
});

test('dirty consume directory sync failure prevents native create and retains the visible booting record', async t => {
  const { f, owner, active } = await installed(t); await owner.dispose();
  const { g, owner: second, downloads } = await next(t, f), fault = failDirectorySync('booting');
  g.internals.instance = fault;
  await assert.rejects(second.install(), { code: 'EIO' });
  assert.equal(fault.hit(), true); assert.equal(g.counts().created, 0); assert.equal(downloads(), 0);
  assert.equal((await read(active)).state, 'booting'); await fs.access(active.target);
  const retired = await second.dispose(); assert.equal(retired.resourcesRetired, true); assert.equal(retired.cleanCheckpoint, false); assert.equal(retired.dataRetained, true);
  const { owner: third, g: h } = await next(t, f);
  await assert.rejects(third.install(), { code: 'ERR_OHOS_LINUX_RECOVERY_REQUIRED' }); assert.equal(h.counts().created, 0);
});

test('clean rename then directory sync failure is unconfirmed now; a fresh owner validates the visible new clean', async t => {
  const f = await ownerFixture(t), fault = failDirectorySync('clean'); f.internals.instance = fault;
  const owner = f.createOwner(), { active } = await owner.install();
  const retired = await owner.dispose();
  assert.equal(fault.hit(), true); assert.equal(retired.cleanCheckpoint, false); assert.equal(retired.releaseError.code, 'EIO');
  assert.equal(retired.resourcesRetired, true); assert.equal(retired.dataRetained, true); assert.equal(retired.guestClose.epoch, active.epoch);
  const visible = await read(active); assert.equal(visible.state, 'clean'); assert.equal(visible.epoch, active.epoch);
  const { owner: second, downloads } = await next(t, f); const resumed = await second.install();
  assert.notEqual(resumed.active.epoch, visible.epoch); assert.equal(downloads(), 0);
  assert.equal((await second.dispose()).cleanCheckpoint, true);
});

test('failure before consuming clean does not delete or invent dirty state', async t => {
  const { f, owner, active } = await installed(t); await owner.dispose(); const before = await fs.readFile(record(active));
  const { g, owner: second } = await next(t, f);
  g.internals.instance = { fs: { ...fs, async open(path, ...args) {
    if (path.endsWith('/instance.json.pending')) throw Object.assign(new Error('explicit pre-write failure'), { code: 'ENOSPC' });
    return fs.open(path, ...args);
  } } };
  await assert.rejects(second.install(), { code: 'ENOSPC' }); assert.equal(g.counts().created, 0);
  assert.deepEqual(await fs.readFile(record(active)), before); await fs.access(active.target);
});

test('sync observation followed by controlled native join failure cannot grant clean', async t => {
  const f = await ownerFixture(t, { retirementError: true }), owner = f.createOwner(), { active } = await owner.install();
  const retired = await owner.dispose();
  assert.equal(retired.resourcesRetired, false); assert.equal(retired.cleanCheckpoint, false); assert.equal(retired.guestClose, null);
  assert.equal((await read(active)).state, 'active'); await fs.access(active.target);
  const { owner: other } = await next(t, f); await assert.rejects(other.install(), { code: 'ERR_OHOS_LINUX_BUSY' });
});

test('valid sync frame followed by a real protocol fault before join keeps the historical getter out of clean', async t => {
  const latch = Promise.withResolvers(), f = await ownerFixture(t, { joinBarrier: latch.promise });
  t.after(() => latch.resolve()); const owner = f.createOwner(), { active, backend } = await owner.install(), closing = owner.dispose();
  await until(() => f.counts().joined === 1); assert.equal(backend.guestClose.rootfsSync, true);
  f.peer.frame('closed', { rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' });
  await until(() => backend.state === 'quarantined'); latch.resolve();
  const retired = await closing; assert.equal(retired.resourcesRetired, true); assert.equal(retired.cleanCheckpoint, false); assert.equal(retired.guestClose, null);
  assert.equal((await read(active)).state, 'active'); assert.equal(backend.guestClose.epoch, active.epoch);
});

test('cancel before resumed opened retains the old disk and a dirty record', async t => {
  const { f, owner, active } = await installed(t); await owner.dispose(); const bytes = await fs.readFile(active.target);
  const { g, owner: second } = await next(t, f, { open: false }), controller = new AbortController();
  const installing = second.install({ signal: controller.signal }); await until(() => g.counts().created === 1);
  controller.abort(Object.assign(new Error('explicit cancellation'), { code: 'ABORT_ERR' }));
  await assert.rejects(installing, { code: 'ABORT_ERR' }); const retired = await second.dispose();
  assert.equal(retired.resourcesRetired, true); assert.equal(retired.cleanCheckpoint, false); assert.equal(retired.dataRetained, true);
  assert.deepEqual(await fs.readFile(active.target), bytes); assert.equal((await read(active)).state, 'booting');
});

for (const mutation of ['old-v1', 'missing', 'corrupt', 'id-array', 'dirty', 'assets', 'multiple', 'target-replaced', 'target-size', 'boot-copy']) {
  test('retained ' + mutation + ' is refused before download or native create, with no fallback deletion', async t => {
    const { f, owner, active } = await installed(t); await owner.dispose();
    const value = await read(active);
    if (mutation === 'old-v1') await fs.writeFile(record(active), JSON.stringify({ version: 1, state: 'retired-private-guest', target: active.target }) + '\n');
    if (mutation === 'missing') await fs.unlink(record(active));
    if (mutation === 'corrupt') await fs.writeFile(record(active), '{not-json');
    if (mutation === 'id-array') { value.persistentInstanceId = [value.persistentInstanceId]; await fs.writeFile(record(active), JSON.stringify(value) + '\n'); }
    if (mutation === 'dirty') { value.state = 'booting'; await fs.writeFile(record(active), JSON.stringify(value) + '\n'); }
    if (mutation === 'assets') { value.assetIdentity = '0'.repeat(64); await fs.writeFile(record(active), JSON.stringify(value) + '\n'); }
    if (mutation === 'multiple') await fs.mkdir(join(f.data, '.installation-unrelated'));
    if (mutation === 'target-replaced') { await fs.rename(active.target, active.target + '.original'); await fs.copyFile(active.target + '.original', active.target); }
    if (mutation === 'target-size') await fs.truncate(active.target, 1);
    if (mutation === 'boot-copy') await fs.writeFile(join(active.directory, 'kernel.bin'), 'bad');
    const before = await fs.readFile(active.target), { owner: second, g, downloads } = await next(t, f);
    await assert.rejects(second.install()); assert.equal(g.counts().created, 0); assert.equal(downloads(), 0);
    assert.deepEqual(await fs.readFile(active.target), before);
    const retired = await second.dispose(); assert.equal(retired.filesRemoved, false); assert.equal(retired.dataRetained, true); assert.equal(retired.cleanCheckpoint, false);
  });
}

test('real directory name/FD replacement is detected before tightening a different inode or creating a VM', async t => {
  const { f, owner, active } = await installed(t); await owner.dispose();
  const moved = f.data + '.moved', oldBytes = await fs.readFile(active.target), { g, owner: second } = await next(t, f);
  g.internals.instance = { fs: { ...fs, async open(path, ...args) {
    const handle = await fs.open(path, ...args);
    if (path === f.data) { await fs.rename(f.data, moved); await fs.mkdir(f.data, { mode: 0o755 }); }
    return handle;
  } } };
  await assert.rejects(second.install(), { code: 'ERR_OHOS_LINUX_DIRECTORY_IDENTITY' }); assert.equal(g.counts().created, 0);
  assert.equal((await fs.stat(f.data)).mode & 0o777, 0o755);
  assert.deepEqual(await fs.readFile(active.target.replace(f.data, moved)), oldBytes);
});

test('replacement of the fixed lock name after a genuine flock is detected before selecting data', async t => {
  const { f, owner, active } = await installed(t); await owner.dispose();
  const { g, owner: second } = await next(t, f), nativeLock = g.internals.lockExclusive;
  // This test uses a real asynchronous file operation at the next lstat boundary;
  // it does not replace the native lock implementation or invent an inode.
  let changed = false;
  g.internals.instance = { fs: { ...fs, async lstat(path, ...args) {
    if (path === join(f.data, '.lock') && !changed) {
      changed = true; await fs.rename(path, path + '.original'); await fs.writeFile(path, '', { mode: 0o600 });
    }
    return fs.lstat(path, ...args);
  } } };
  assert.equal(typeof nativeLock, 'function');
  await assert.rejects(second.install(), { code: 'ERR_OHOS_LINUX_LOCK_IDENTITY' }); assert.equal(g.counts().created, 0);
  await fs.access(active.target); assert.equal((await read(active)).state, 'clean');
});

// 重新安装 Linux: the explicit, user-confirmed discard under the real flock.
const discard = (f, extra) => discardLinuxInstance({ directory: f.data, lockExclusive: f.internals.lockExclusive }, extra);
const entries = async f => (await fs.readdir(f.data)).sort();
async function opensFresh(f) {
  const store = await openLinuxInstance({ directory: f.data, manifest: f.manifest, lockExclusive: f.internals.lockExclusive });
  try { return store.existing; } finally { await store.removeUnpublished(); await store.release(); }
}

test('discard of a clean retained instance keeps the root and lock inode, and the next owner installs afresh', async t => {
  const { f, owner, active } = await installed(t); await owner.dispose();
  const root = await fs.stat(f.data), lock = await fs.stat(join(f.data, '.lock'));
  assert.deepEqual(await discard(f), { removed: 1 });
  assert.deepEqual(await entries(f), ['.lock']);
  for (const [before, after] of [[root, await fs.stat(f.data)], [lock, await fs.stat(join(f.data, '.lock'))]]) {
    assert.equal(after.ino, before.ino); assert.equal(after.dev, before.dev);
  }
  assert.equal((await fs.stat(f.data)).mode & 0o777, 0o700);
  await assert.rejects(fs.access(active.target), { code: 'ENOENT' });
  const g = await ownerFixture(t), fresh = g.createOwner({ directory: f.data }), reopened = await fresh.install();
  assert.equal(fresh.bootMode, 'install'); assert.notEqual(fresh.persistentInstanceId, owner.persistentInstanceId);
  assert.notEqual(reopened.active.directory, active.directory); assert.equal(g.counts().created, 1);
  assert.equal((await fresh.dispose()).cleanCheckpoint, true);
});

for (const [mutation, code] of [['assets', 'ERR_OHOS_LINUX_ASSET_GENERATION'], ['dirty', 'ERR_OHOS_LINUX_RECOVERY_REQUIRED'], ['multiple', 'ERR_OHOS_LINUX_RETAINED_INSTANCE']]) {
  test('discard clears a retained root refused as ' + code + ' and the next open is a fresh install', async t => {
    const { f, owner, active } = await installed(t); await owner.dispose();
    const value = await read(active);
    if (mutation === 'assets') { value.assetIdentity = '0'.repeat(64); await fs.writeFile(record(active), JSON.stringify(value) + '\n'); }
    if (mutation === 'dirty') { value.state = 'booting'; await fs.writeFile(record(active), JSON.stringify(value) + '\n'); }
    if (mutation === 'multiple') { await fs.mkdir(join(f.data, '.installation-unrelated')); await fs.writeFile(join(f.data, '.installation-unrelated', 'note'), 'x'); }
    const { owner: refused, g } = await next(t, f);
    await assert.rejects(refused.install(), { code }); assert.equal(g.counts().created, 0);
    assert.equal((await refused.dispose()).dataRetained, true);
    assert.deepEqual(await discard(f), { removed: mutation === 'multiple' ? 2 : 1 });
    assert.deepEqual(await entries(f), ['.lock']);
    assert.equal(await opensFresh(f), false);
  });
}

test('discard is refused while a live owner holds the real flock, and deletes nothing', async t => {
  const { f, active } = await installed(t), before = await fs.readFile(active.target);
  await assert.rejects(discard(f), { code: 'ERR_OHOS_LINUX_BUSY' });
  assert.deepEqual(await fs.readFile(active.target), before); assert.equal((await read(active)).state, 'active');
  assert.equal((await entries(f)).length, 2);
});

test('a discard interrupted between rename and delete leaves garbage the next open deletes and never resumes', async t => {
  const { f, owner, active } = await installed(t); await owner.dispose();
  // The instance is clean and of this asset generation: resumable, were it not renamed.
  const fault = { fs: { ...fs, async rm() { throw Object.assign(new Error('explicit interruption after rename'), { code: 'EIO' }); } } };
  await assert.rejects(discard(f, fault), { code: 'EIO' });
  const [left] = (await entries(f)).filter(name => name !== '.lock');
  assert.match(left, /^\.discard-[a-f0-9]{32}$/); await fs.access(join(f.data, left, 'target.ext4'));
  const g = await ownerFixture(t), fresh = g.createOwner({ directory: f.data }); await fresh.install();
  assert.equal(fresh.bootMode, 'install'); assert.notEqual(fresh.persistentInstanceId, owner.persistentInstanceId);
  const names = await entries(f);
  assert.equal(names.length, 2); assert.equal(names.some(name => name.startsWith('.discard-')), false);
  assert.notEqual(join(f.data, names.find(name => name.startsWith('.installation-'))), active.directory);
});

test('a second discard finishes the garbage of an interrupted one', async t => {
  const { f, owner } = await installed(t); await owner.dispose();
  await assert.rejects(discard(f, { fs: { ...fs, async rm() { throw Object.assign(new Error('interrupted'), { code: 'EIO' }); } } }), { code: 'EIO' });
  assert.deepEqual(await discard(f), { removed: 1 });
  assert.deepEqual(await entries(f), ['.lock']);
  assert.deepEqual(await discard(f), { removed: 0 });
});
