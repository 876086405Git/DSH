import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { LinuxControl } from '../../ohos/linux/control.mjs';
import * as installation from '../../ohos/linux/owner.mjs';
import { ownerFixture, until } from './linux-control-fixture.mjs';

const out = process.env.DSH_1289_CASES;
assert(out, 'explicit private case output is required');
mkdirSync(out, { recursive: true });
const write = (name, value) => writeFileSync(join(out, `${name}.json`), JSON.stringify(value, null, 2) + '\n');
const snapshot = f => ({ status: f.control.status(), counts: f.counts(), commands: structuredClone(f.peer.commands) });
async function fixture(t, options = {}) {
  const f = await ownerFixture(t, options);
  const control = new LinuxControl({ hostPaths: { directory: f.data, nativeLibraryDirectory: '/trusted/native' }, assetsDirectory: f.assets }, {
    async loadModule() {
      return { loadLinuxInstallationManifest: installation.loadLinuxInstallationManifest,
        createLinuxInstallationOwner: input => f.createOwner(input) };
    },
  });
  const command = (action, fields = {}) => {
    const s = control.status();
    return control.command({ v: 1, instanceId: s.instanceId, attemptId: s.attemptId, action, ...fields });
  };
  const enable = async () => { command('setEnabled', { enabled: true }); await until(() => control.status().admission); };
  return { ...f, control, command, enable };
}
const boundary = 'Real Control/InstallationOwner/Backend and TCP 903 framing/native flock; session join counter and guest are explicit test boundaries; no TinyEMU execution or RAM measurement.';

test('R1 new off target: ordinary off reaches joined owner, before test cleanup', { timeout: 5000 }, async t => {
  const f = await fixture(t); const record = { boundary, contractChange: 'ADD10 requests off->join; old documented contract retains one VM for off/on.' };
  try {
    await f.enable(); record.opened = snapshot(f);
    record.accepted = f.command('setEnabled', { enabled: false });
    await until(() => ['disabled', 'stopped', 'unknown'].includes(f.control.status().state));
    record.afterOffBeforeCleanup = snapshot(f); write('R1-before-cleanup', record);
    assert.equal(record.afterOffBeforeCleanup.counts.joined, 1, 'new ADD10 off target requires a join; old ordinary-off reuse does not request it');
    assert.equal(record.afterOffBeforeCleanup.status.shutdownComplete, true);
    assert.equal(record.afterOffBeforeCleanup.status.retirement?.native?.joined, true);
  } finally {
    const final = await f.control.shutdown();
    record.cleanupAfterAssertion = { returned: final, ...snapshot(f) }; write('R1-all-observations', record);
  }
});

test('C1 existing final shutdown waits the actual session join barrier and joins once', { timeout: 5000 }, async t => {
  const release = Promise.withResolvers(), f = await fixture(t, { joinBarrier: release.promise });
  const record = { boundary };
  try {
    await f.enable(); record.opened = snapshot(f);
    const first = f.control.shutdown(), second = f.control.shutdown();
    assert.equal(first, second, 'same control retirement Promise');
    await until(() => f.counts().joined === 1);
    record.beforeJoinResolution = snapshot(f); write('C1-before-join-resolution', record);
    assert.equal(record.beforeJoinResolution.status.shutdownComplete, false);
    assert.equal(record.beforeJoinResolution.commands.filter(c => c.op === 'close').length, 1);
    release.resolve(); record.returned = await first; record.afterJoin = snapshot(f); write('C1-after-join', record);
    assert.equal(record.returned.shutdownComplete, true);
    assert.equal(record.returned.retirement.native.joined, true);
    assert.equal(record.returned.retirement.cleanCheckpoint, true);
    assert.equal(record.afterJoin.counts.joined, 1);
    assert.equal(record.afterJoin.status.ownerRetained, true);
    assert.equal(record.afterJoin.status.nativeMemoryRelease, 'process-exit');
  } finally { release.resolve(); await f.control.shutdown(); }
});

test('C2 never-enabled off neither loads an owner nor creates a session', { timeout: 5000 }, async t => {
  const f = await fixture(t); const record = { boundary };
  try {
    record.accepted = f.command('setEnabled', { enabled: false });
    record.afterOff = snapshot(f); write('C2-never-enabled', record);
    assert.equal(record.afterOff.status.state, 'disabled');
    assert.equal(record.afterOff.status.ownerRetained, false);
    assert.deepEqual(record.afterOff.counts, { created: 0, stopped: 0, joined: 0 });
  } finally { await f.control.shutdown(); }
});

after(() => {
  const require = createRequire(import.meta.url);
  const files = Object.keys(require.cache).sort().map(path => {
    const bytes = readFileSync(path);
    return { path, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
  });
  write('cjs-loaded-inputs', { scope: 'Actual CommonJS require.cache only; ESM private sources are separately bound by the runner.', files });
});
