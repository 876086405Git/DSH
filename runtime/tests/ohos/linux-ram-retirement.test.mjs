import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { LinuxControl } from '../../ohos/linux/control.mjs';
import * as installation from '../../ohos/linux/owner.mjs';
import { ownerFixture, until, tick } from './linux-control-fixture.mjs';

async function fixture(t, nativeResult) {
  const f = await ownerFixture(t, { nativeResult }); let owner;
  const control = new LinuxControl({ hostPaths: { directory: f.data, nativeLibraryDirectory: '/trusted/native' },
    assetsDirectory: f.assets }, { async loadModule() {
    return { loadLinuxInstallationManifest: installation.loadLinuxInstallationManifest,
      createLinuxInstallationOwner(input) { owner = f.createOwner(input); return owner; } };
  } });
  const state = control.status();
  control.command({ v: 1, instanceId: state.instanceId, attemptId: state.attemptId,
    action: 'setEnabled', enabled: true });
  await until(() => control.status().admission);
  const { active } = await owner.install();
  return { ...f, control, owner, active };
}

for (const errorCode of [0, 5]) {
  test(`RAM observation error ${errorCode} is visible without changing the exact clean record or resume`, async t => {
    const ramRetirement = { eligible: true, attempted: true, trackedBytes: 16777216,
      eligibleBytes: 16773120, advisedBytes: errorCode ? 0 : 16773120, errorCode };
    const f = await fixture(t, { joined: true, ownerQuarantined: true, retirementError: false,
      apiResult: -4, ramRetirement });
    await f.control.shutdown();
    const state = f.control.status();
    assert.deepEqual(state.retirement.native.ramRetirement, ramRetirement);
    assert.equal(state.retirement.resourcesRetired, true);
    assert.equal(state.retirement.cleanCheckpoint, true);
    assert.equal(state.retirement.native.retirementError, false);
    assert.equal(state.nativeMemoryRelease, 'process-exit');
    const record = JSON.parse(await readFile(join(f.active.directory, 'instance.json'), 'utf8'));
    assert.equal(record.state, 'clean');
    assert.deepEqual(record.native, { joined: true, retirementError: false, apiResult: -4 });
    state.retirement.native.ramRetirement.errorCode = 999;
    assert.equal(f.control.status().retirement.native.ramRetirement.errorCode, errorCode,
      'status snapshots must not mutate the stored retirement observation');
    const next = await ownerFixture(t);
    next.internals.download.fetch = () => { throw new Error('clean resume must not download'); };
    const owner = next.createOwner({ directory: f.data }), reopened = await owner.install();
    assert.equal(owner.bootMode, 'resume');
    assert.equal(reopened.active.target, f.active.target);
    assert.notEqual(reopened.active.epoch, f.active.epoch);
    assert.equal((await owner.dispose()).cleanCheckpoint, true);
    t.diagnostic('Native/guest boundary is explicit test data; real TCP, production controller/owner/record and native flock are used.');
  });
}

test('unknown join preserves null RAM observation and cannot grant clean', async t => {
  const f = await fixture(t, { joined: false, ownerQuarantined: true,
    retirementError: null, apiResult: null, ramRetirement: null });
  await f.control.shutdown();
  const state = f.control.status();
  assert.equal(state.retirement.native.ramRetirement, null);
  assert.equal(state.retirement.resourcesRetired, false);
  assert.equal(state.retirement.cleanCheckpoint, false);
  assert.equal(JSON.parse(await readFile(join(f.active.directory, 'instance.json'), 'utf8')).state, 'active');
});

test('older native reports without the optional observation retain their exact status shape', async t => {
  const f = await fixture(t, { joined: true, ownerQuarantined: true, retirementError: false, apiResult: -4 });
  await f.control.shutdown();
  assert.deepEqual(f.control.status().retirement.native, { joined: true, retirementError: false, apiResult: -4 });
  assert.equal(f.control.status().retirement.cleanCheckpoint, true);
});

test('ordinary switch-off joins once and observes RAM retirement without making the owner reusable', async t => {
  const ramRetirement = { eligible: true, attempted: true, trackedBytes: 16777216,
    eligibleBytes: 16773120, advisedBytes: 16773120, errorCode: 0 };
  const f = await fixture(t, { joined: true, ownerQuarantined: true, retirementError: false,
    apiResult: -4, ramRetirement });
  const command = enabled => {
    const state = f.control.status();
    return f.control.command({ v: 1, instanceId: state.instanceId, attemptId: state.attemptId,
      action: 'setEnabled', enabled });
  };
  const attempt = f.control.status().attemptId;
  command(false);
  await until(() => f.control.status().state === 'stopped'); await tick();
  assert.equal(f.control.status().admission, false);
  assert.equal(f.control.status().guestOpened, false);
  assert.equal(f.control.status().shutdownComplete, true);
  assert.equal(f.control.status().restartRequired, true);
  assert.equal(f.counts().created, 1); assert.equal(f.counts().joined, 1);
  assert.throws(() => command(true), { code: 'ERR_OHOS_LINUX_CLOSED' });
  assert.equal(f.control.status().attemptId, attempt);
  await f.control.shutdown();
  assert.equal(f.counts().created, 1); assert.equal(f.counts().joined, 1);
  assert.ok(f.counts().stopped > 0, 'ordinary off requests the idempotent native stop');
  assert.deepEqual(f.control.status().retirement.native.ramRetirement, ramRetirement);
});
