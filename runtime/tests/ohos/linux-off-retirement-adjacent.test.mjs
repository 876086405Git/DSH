import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { LinuxControl } from '../../ohos/linux/control.mjs';
import * as installation from '../../ohos/linux/owner.mjs';
import { ownerFixture, until } from './linux-control-fixture.mjs';

const out = process.env.DSH_1289_CASES;
assert(out, 'explicit private case output is required'); mkdirSync(out, { recursive: true });
const save = (name, value) => writeFileSync(join(out, name + '.json'), JSON.stringify(value, null, 2) + '\n');
const snapshot = f => ({ status: f.control.status(), counts: f.counts(), commands: structuredClone(f.peer.commands) });
async function fixture(t, options = {}) {
  const f = await ownerFixture(t, options); let owner;
  if (options.joinReject) {
    const create = f.internals.createSession;
    f.internals.createSession = config => {
      const raw = create(config);
      return { ...raw, async join() { await raw.join(); throw Object.assign(new Error('explicit native join rejection boundary'), { code: 'ERR_NATIVE_JOIN_TEST' }); } };
    };
  }
  const control = new LinuxControl({ hostPaths: { directory: f.data, nativeLibraryDirectory: '/trusted/native' }, assetsDirectory: f.assets }, {
    async loadModule() { return { loadLinuxInstallationManifest: installation.loadLinuxInstallationManifest,
      createLinuxInstallationOwner(input) { owner = f.createOwner(input); return owner; } }; },
  });
  const command = (action, fields = {}) => { const s = control.status(); return control.command({ v: 1, instanceId: s.instanceId,
    attemptId: s.attemptId, action, ...fields }); };
  const enable = async () => { command('setEnabled', { enabled: true }); await until(() => control.status().admission); };
  const active = async () => (await owner.install()).active;
  return { ...f, control, command, enable, active };
}

test('A1 ordinary off waits the held join and duplicate commands cannot start another retirement', { timeout: 5000 }, async t => {
  const hold = Promise.withResolvers(), f = await fixture(t, { joinBarrier: hold.promise }); const record = {};
  try {
    await f.enable(); record.accepted = f.command('setEnabled', { enabled: false });
    const one = f.control.shutdown(), two = f.control.shutdown(); assert.equal(one, two);
    await until(() => f.counts().joined === 1); record.held = snapshot(f); save('A1-held', record);
    assert.equal(record.held.status.state, 'stopping'); assert.equal(record.held.status.shutdownComplete, false);
    assert.equal(record.held.status.restartRequired, true);
    assert.throws(() => f.command('setEnabled', { enabled: false }), { code: 'ERR_OHOS_LINUX_CLOSED' });
    assert.throws(() => f.command('setEnabled', { enabled: true }), { code: 'ERR_OHOS_LINUX_CLOSED' });
    assert.equal(f.counts().joined, 1);
    hold.resolve(); record.done = await one; record.after = snapshot(f); save('A1-done', record);
    assert.equal(record.done.shutdownComplete, true); assert.equal(record.done.retirement.cleanCheckpoint, true);
    assert.equal(record.after.commands.filter(c => c.op === 'close').length, 1);
    assert.equal(record.after.counts.joined, 1);
  } finally { hold.resolve(); await f.control.shutdown(); }
});

test('A2 a real routed job must release before ordinary off sends guest close or calls join', { timeout: 5000 }, async t => {
  const f = await fixture(t); const record = {};
  try {
    await f.enable();
    const handle = await f.control.spawnRouted({ argv: ['python3', '-c', 'pass'], cwd: '/workspace', env: {}, graceMs: 1000,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 16384 }, stderr: { maxBytes: 16384 } } }, { label: 'explicit routed fixture' });
    const start = await f.peer.admitted(); await handle.started;
    f.command('setEnabled', { enabled: false }); await until(() => f.peer.commands.some(c => c.op === 'cancel'));
    record.beforeRelease = snapshot(f); save('A2-before-release', record);
    assert.equal(record.beforeRelease.status.shutdownComplete, false);
    assert.equal(record.beforeRelease.counts.joined, 0);
    assert.equal(record.beforeRelease.commands.filter(c => c.op === 'close').length, 0);
    await f.peer.complete(start.job, { cancelled: true }); record.outcome = await handle.done;
    record.done = await f.control.shutdown(); record.after = snapshot(f); save('A2-after-release', record);
    assert.equal(record.outcome.cancelled, true); assert.equal(record.done.shutdownComplete, true);
    assert.equal(record.after.counts.joined, 1);
  } finally { await f.control.shutdown(); }
});

test('A3 unconfirmed native join after ordinary off remains unknown and cannot write clean', { timeout: 5000 }, async t => {
  const f = await fixture(t, { nativeResult: { joined: false, ownerQuarantined: true, retirementError: null, apiResult: null, ramRetirement: null } });
  try {
    await f.enable(); const active = await f.active(); f.command('setEnabled', { enabled: false });
    const done = await f.control.shutdown(), disk = JSON.parse(await readFile(join(active.directory, 'instance.json'), 'utf8'));
    save('A3-unconfirmed', { done, disk, counts: f.counts() });
    assert.equal(done.state, 'unknown'); assert.equal(done.shutdownComplete, false);
    assert.equal(done.retirement.resourcesRetired, false); assert.equal(done.retirement.cleanCheckpoint, false);
    assert.equal(done.retirement.native.joined, false); assert.equal(done.retirement.native.ramRetirement, null);
    assert.equal(disk.state, 'active'); assert.equal(f.counts().joined, 1);
  } finally { await f.control.shutdown(); }
});

test('A4 rejected native join after ordinary off is not promoted to success or retried', { timeout: 5000 }, async t => {
  const f = await fixture(t, { joinReject: true });
  try {
    await f.enable(); const active = await f.active(); f.command('setEnabled', { enabled: false });
    const done = await f.control.shutdown(), disk = JSON.parse(await readFile(join(active.directory, 'instance.json'), 'utf8'));
    save('A4-rejected', { done, disk, counts: f.counts() });
    assert.equal(done.state, 'unknown'); assert.equal(done.shutdownComplete, false);
    assert.equal(done.retirement.native, null); assert.equal(done.retirement.cleanCheckpoint, false);
    // Backend quarantine deliberately exposes UNKNOWN and retains the original join error as its cause.
    assert.equal(done.retirement.releaseErrorCode, 'ERR_OHOS_LINUX_UNKNOWN');
    assert.equal(disk.state, 'active'); assert.equal(f.counts().joined, 1);
  } finally { await f.control.shutdown(); }
});

test('A5 advice failure stays visible while a real protocol close and confirmed join keep their clean predicate', { timeout: 5000 }, async t => {
  const ramRetirement = { eligible: true, attempted: true, trackedBytes: 16777216, eligibleBytes: 16773120, advisedBytes: 0, errorCode: 5 };
  const f = await fixture(t, { nativeResult: { joined: true, ownerQuarantined: true, retirementError: false, apiResult: -4,
    fdRetirement: { retired: true, consoleError: 0, wakeReadError: 0, wakeWriteError: 0 }, ramRetirement } });
  try {
    await f.enable(); const active = await f.active(); f.command('setEnabled', { enabled: false });
    const done = await f.control.shutdown(), disk = JSON.parse(await readFile(join(active.directory, 'instance.json'), 'utf8'));
    save('A5-advice-failure', { done, disk, counts: f.counts(), nativeBoundary: 'explicit result; no actual madvise or RSS observation' });
    assert.deepEqual(done.retirement.native.ramRetirement, ramRetirement);
    assert.equal(done.shutdownComplete, true); assert.equal(done.retirement.cleanCheckpoint, true);
    assert.deepEqual(disk.native, { joined: true, retirementError: false, apiResult: -4 });
    assert.equal(done.ownerRetained, true); assert.equal(done.restartRequired, true); assert.equal(done.nativeMemoryRelease, 'process-exit');
    assert.throws(() => f.command('setEnabled', { enabled: true }), { code: 'ERR_OHOS_LINUX_CLOSED' });
  } finally { await f.control.shutdown(); }
});
