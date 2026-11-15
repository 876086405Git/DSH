import test from 'node:test';
import assert from 'node:assert/strict';
import { access, readFile, readdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { LinuxControl } from '../../ohos/linux/control.mjs';
import { discardLinuxInstallation, loadLinuxInstallationManifest } from '../../ohos/linux/owner.mjs';
import { openLinuxInstance } from '../../ohos/linux/instance.mjs';
import { ownerFixture, until } from './linux-control-fixture.mjs';

// Native outcomes are an explicit boundary here. Actual NAPI/FD/VM failures are
// exercised separately; these tests use real sockets, files and native flock.
const notification = { attempted: true, notified: true, unnecessary: false, errorCode: 0 };
const retiredFds = { retired: true, consoleError: 0, wakeReadError: 0, wakeWriteError: 0 };
const fdDebt = () => ({ joined: true, joinAttempted: true, joinError: 0,
  ownerQuarantined: true, retirementError: false, apiResult: -4, waitError: 0,
  stopNotification: { ...notification },
  fdRetirement: { ...retiredFds, retired: false, wakeWriteError: 4 } });
const unknown = () => ({ joined: false, joinAttempted: false, joinError: null,
  ownerQuarantined: true, retirementError: null, apiResult: null, waitError: null,
  stopNotification: { attempted: true, notified: false, unnecessary: false, errorCode: 5 },
  fdRetirement: null, ramRetirement: null });

async function retained(f, result, state) {
  assert.equal(result.resourcesRetired, false);
  assert.equal(result.filesRemoved, false);
  assert.equal(result.dataRetained, true);
  assert.equal(result.cleanCheckpoint, false);
  assert.equal(result.ownerQuarantined, true);
  const names = (await readdir(f.data)).filter(name => name !== '.lock');
  assert.equal(names.length, 1);
  const path = join(f.data, names[0]);
  assert.equal(JSON.parse(await readFile(join(path, 'instance.json'), 'utf8')).state, state);
  await access(join(path, 'target.ext4'));
  await assert.rejects(discardLinuxInstallation({ directory: f.data },
    { lockExclusive: f.internals.lockExclusive }), { code: 'ERR_OHOS_LINUX_BUSY' });
  return path;
}

test('joined VM with a failed waker close cannot clean a published instance or release its flock', async t => {
  const f = await ownerFixture(t, { nativeResult: fdDebt() });
  const owner = f.createOwner(), { active } = await owner.install();
  const before = await readFile(active.target), result = await owner.dispose();
  assert.equal(result.native.joined, true);
  assert.equal(result.native.fdRetirement.retired, false);
  await retained(f, result, 'active');
  assert.deepEqual(await readFile(active.target), before);
  assert.equal(result.releaseError.code, 'ERR_OHOS_LINUX_UNKNOWN');
  assert.equal(result.releaseError.cause.code, 'ERR_OHOS_LINUX_NATIVE_RELEASE');
  assert.deepEqual(f.counts(), { created: 1, stopped: 2, joined: 1 });
});

test('failed waker close preserves an unpublished timed-out installation and its flock', async t => {
  const f = await ownerFixture(t, { open: false, nativeResult: fdDebt() });
  const owner = f.createOwner({ bootTimeoutMs: 25 });
  await assert.rejects(owner.install(), { code: 'ERR_OHOS_LINUX_INSTALL_TIMEOUT' });
  await retained(f, await owner.dispose(), 'booting');
});

test('unrecovered native startup (-2) remains unknown and cannot delete partial installation data', async t => {
  const native = { ...fdDebt(), retirementError: null, apiResult: -2,
    fdRetirement: { ...retiredFds } };
  const f = await ownerFixture(t, { open: false, nativeResult: native });
  const owner = f.createOwner({ bootTimeoutMs: 25 });
  await assert.rejects(owner.install(), { code: 'ERR_OHOS_LINUX_INSTALL_TIMEOUT' });
  const result = await owner.dispose();
  await retained(f, result, 'booting');
  assert.equal(result.native.retirementError, null);
});

for (const [name, makeNative] of [['notification failure', unknown], ['post-join FD debt', fdDebt]]) {
  test(`Control keeps ${name} visible and refuses discard`, async t => {
    const native = makeNative(), f = await ownerFixture(t, { open: false, nativeResult: native });
    const control = new LinuxControl({ hostPaths: { directory: f.data, nativeLibraryDirectory: '/trusted/native' },
      assetsDirectory: f.assets }, { async loadModule() {
      return { loadLinuxInstallationManifest, createLinuxInstallationOwner: input => f.createOwner({ ...input, bootTimeoutMs: 25 }),
        discardLinuxInstallation: input => discardLinuxInstallation(input, { lockExclusive: f.internals.lockExclusive }) };
    } });
    const command = (action, fields = {}) => {
      const { instanceId, attemptId } = control.status();
      return control.command({ v: 1, instanceId, attemptId, action, ...fields });
    };
    command('setEnabled', { enabled: true });
    await until(() => control.status().retirement !== null);
    await until(() => control.status().state === 'unknown');
    const state = control.status();
    assert.equal(state.state, 'unknown');
    assert.equal(state.restartRequired, true);
    assert.equal(state.shutdownComplete, false);
    assert.equal(state.admission, false);
    await retained(f, state.retirement, 'booting');
    assert.deepEqual(state.retirement.native.stopNotification, native.stopNotification);
    assert.deepEqual(state.retirement.native.fdRetirement, native.fdRetirement);
    for (const key of ['joined', 'joinAttempted', 'joinError', 'waitError', 'retirementError', 'apiResult']) {
      assert.equal(state.retirement.native[key], native[key]);
    }
    state.retirement.native.stopNotification.errorCode = 999;
    if (state.retirement.native.fdRetirement) state.retirement.native.fdRetirement.wakeWriteError = 999;
    assert.deepEqual(control.status().retirement.native.stopNotification, native.stopNotification);
    assert.deepEqual(control.status().retirement.native.fdRetirement, native.fdRetirement);
    await assert.rejects(command('discardRetained'), { code: 'ERR_OHOS_LINUX_RESTART_REQUIRED' });
    assert.equal((await control.shutdown()).shutdownComplete, false);
  });
}

test('instance clean itself rejects FD debt even if its caller supplies guest sync and joined true', async t => {
  const f = await ownerFixture(t);
  const store = await openLinuxInstance({ directory: f.data, manifest: f.manifest,
    lockExclusive: f.internals.lockExclusive });
  t.after(() => store.release());
  const target = join(store.directory, 'fixture-target');
  await writeFile(target, Buffer.alloc(1024), { mode: 0o600 }); await store.prepared(target);
  await store.booting(store.epoch); await store.active();
  const guestClose = { epoch: store.epoch, rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' };
  await assert.rejects(store.clean({ closed: true, guestClose, native: fdDebt() }),
    { code: 'ERR_OHOS_LINUX_CLEAN_UNCONFIRMED' });
  const read = async () => JSON.parse(await readFile(join(store.directory, 'instance.json'), 'utf8'));
  assert.equal((await read()).state, 'active');
  await store.clean({ closed: true, guestClose, native: { ...fdDebt(), fdRetirement: { ...retiredFds } } });
  const record = await read();
  assert.equal(record.state, 'clean');
  assert.deepEqual(record.native, { joined: true, retirementError: false, apiResult: -4 });
});
