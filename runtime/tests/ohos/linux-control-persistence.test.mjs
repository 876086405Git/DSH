import test from 'node:test';
import assert from 'node:assert/strict';
import { LinuxControl } from '../../ohos/linux/control.mjs';

const instance = '2f887aa7-437e-49b6-bbde-4e30d899d3cc';
const guestClose = { epoch: 'b'.repeat(64), rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' };
const disposed = (extra = {}) => ({ resourcesRetired: true, filesRemoved: false, dataRetained: true,
  ownerQuarantined: true, native: { joined: true, retirementError: false, apiResult: -4 },
  releaseError: null, guestClose, cleanCheckpoint: true, ...extra });

// Actual App controller; the already tested owner/native boundary is explicit.
function fixture(bootMode, result = disposed()) {
  const backend = { state: 'opened', closed: false };
  const owner = { state: 'active', persistentInstanceId: instance, bootMode,
    async install() { return { backend }; }, async dispose() { return result; } };
  const control = new LinuxControl({ hostPaths: { directory: '/private/test', nativeLibraryDirectory: '/native/test' } },
    { async loadModule() { return { async loadLinuxInstallationManifest() { return {}; },
      createLinuxInstallationOwner() { return owner; } }; } });
  const enable = async () => {
    const current = control.status();
    control.command({ v: 1, instanceId: current.instanceId, attemptId: current.attemptId, action: 'setEnabled', enabled: true });
    for (let n = 0; n < 20 && !control.status().admission; n++) await new Promise(resolve => setImmediate(resolve));
    assert.equal(control.status().admission, true);
  };
  return { control, enable };
}

test('persistence identity and boot mode distinguish disk identity from this service attempt', async () => {
  const first = fixture('install'), second = fixture('resume');
  assert.equal(first.control.status().persistentInstanceId, null);
  assert.equal(first.control.status().bootMode, null);
  await first.enable(); await second.enable();
  for (const value of [first.control.status(), second.control.status()]) assert.equal(value.persistentInstanceId, instance);
  assert.notEqual(first.control.status().instanceId, second.control.status().instanceId);
  assert.equal(first.control.status().bootMode, 'install'); assert.equal(second.control.status().bootMode, 'resume');
  const closed = await second.control.shutdown();
  assert.equal(closed.persistentInstanceId, instance); assert.equal(closed.bootMode, 'resume');
  assert.deepEqual(closed.retirement.guestClose, guestClose); assert.equal(closed.retirement.cleanCheckpoint, true);
  closed.retirement.guestClose.rootfsSync = false;
  assert.equal(second.control.status().retirement.guestClose.rootfsSync, true);
  await first.control.shutdown();
});

test('guest sync and native retirement do not manufacture checkpoint commit success', async () => {
  const f = fixture('resume', disposed({ cleanCheckpoint: false,
    releaseError: Object.assign(new Error('checkpoint directory sync failed'), { code: 'EIO' }) }));
  await f.enable(); const value = await f.control.shutdown();
  assert.equal(value.shutdownComplete, true); assert.deepEqual(value.retirement.guestClose, guestClose);
  assert.equal(value.retirement.cleanCheckpoint, false); assert.equal(value.retirement.releaseErrorCode, 'EIO');
});

test('no owner retirement has no persistent disk or clean checkpoint', async () => {
  const value = await new LinuxControl().shutdown();
  assert.equal(value.shutdownComplete, true); assert.equal(value.persistentInstanceId, null);
  assert.equal(value.bootMode, null); assert.equal(value.retirement.guestClose, null);
  assert.equal(value.retirement.cleanCheckpoint, false);
});
