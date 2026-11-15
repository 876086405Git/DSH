// Real LinuxControl/InstallationOwner/backend/TCP protocol, with explicit native and archive boundaries.
import test from 'node:test';
import assert from 'node:assert/strict';
import { LinuxControl } from '../../ohos/linux/control.mjs';
import * as installation from '../../ohos/linux/owner.mjs';
import { ownerFixture, until, tick } from './linux-control-fixture.mjs';

async function fixture(t, options = {}) {
  const f = await ownerFixture(t, options);
  const control = new LinuxControl({ hostPaths: { directory: f.data, nativeLibraryDirectory: '/trusted/native' },
    assetsDirectory: f.assets }, { async loadModule() {
    await options.moduleBarrier;
    return { loadLinuxInstallationManifest: installation.loadLinuxInstallationManifest,
      createLinuxInstallationOwner: input => f.createOwner(input),
      async discardLinuxInstallation(input) {
        await options.discardBarrier;
        return installation.discardLinuxInstallation(input, { lockExclusive: f.internals.lockExclusive });
      } };
  } });
  const command = (action, fields = {}) => { const s = control.status();
    return control.command({ v: 1, instanceId: s.instanceId, attemptId: s.attemptId, action, ...fields }); };
  const enable = async () => { command('setEnabled', { enabled: true }); await until(() => control.status().admission); };
  return { ...f, control, command, enable };
}

test('installation work differs from retained idle guest and cancelled pre-owner history', async t => {
  const barrier = Promise.withResolvers(), f = await fixture(t, { moduleBarrier: barrier.promise });
  try {
    assert.equal(f.control.hasActiveWork(), false);
    f.command('setEnabled', { enabled: true }); await tick();
    assert.equal(f.control.hasActiveWork(), true); assert.equal(f.counts().created, 0);
    f.command('setEnabled', { enabled: false }); assert.equal(f.control.hasActiveWork(), true);
    barrier.resolve(); await until(() => f.control.status().state === 'disabled');
    assert.equal(f.control.status().restartRequired, true);
    assert.equal(f.control.hasActiveWork(), false, 'settled failure without VM is only retained history');
  } finally { barrier.resolve(); await f.control.shutdown(); }
});

test('discard and shutdown stay active until real no-VM storage work finishes', async t => {
  const barrier = Promise.withResolvers(), f = await fixture(t, { discardBarrier: barrier.promise });
  try {
    const discard = f.command('discardRetained'); await tick();
    assert.equal(f.control.hasActiveWork(), true);
    const shutdown = f.control.shutdown(); await tick();
    assert.equal(f.control.hasActiveWork(), true); assert.equal(f.control.status().shutdownComplete, false);
    barrier.resolve(); await discard; await shutdown;
    assert.equal(f.control.hasActiveWork(), false); assert.equal(f.control.status().shutdownComplete, true);
  } finally { barrier.resolve(); await f.control.shutdown(); }
});

test('ordinary off stays active through command cancellation and becomes idle after final join', async t => {
  const f = await fixture(t); await f.enable();
  assert.equal(f.control.hasActiveWork(), false);
  f.command('runPrivateGuest', { requestId: 1, argv: ['true'], cwd: '/workspace' });
  const start = await f.peer.admitted();
  try {
    assert.equal(f.control.hasActiveWork(), true);
    f.command('setEnabled', { enabled: false });
    await until(() => f.peer.commands.some(command => command.op === 'cancel'));
    assert.equal(f.control.hasActiveWork(), true);
  } finally { await f.peer.complete(start.job, { cancelled: true }); }
  await until(() => f.control.status().state === 'stopped');
  assert.equal(f.control.status().shutdownComplete, true);
  assert.equal(f.control.hasActiveWork(), false);
  // Backend and owner both request stop; their shared session joins once.
  assert.deepEqual(f.counts(), { created: 1, stopped: 2, joined: 1 });
});

test('socket loss is uncertain work until confirmed join, then UNKNOWN history is idle', async t => {
  const release = Promise.withResolvers(), f = await fixture(t, { joinBarrier: release.promise });
  try {
    await f.enable(); f.peer.socket.end();
    await until(() => f.control.status().state === 'unknown');
    assert.equal(f.control.hasActiveWork(), true);
    const closing = f.control.shutdown(); await until(() => f.counts().joined === 1);
    assert.equal(f.control.hasActiveWork(), true); assert.equal(f.control.status().shutdownComplete, false);
    release.resolve(); await closing;
    assert.equal(f.control.status().state, 'unknown', 'protocol history remains honest');
    assert.equal(f.control.status().shutdownComplete, true);
    assert.equal(f.control.hasActiveWork(), false, 'confirmed thread/resource retirement ends live work');
  } finally { release.resolve(); await f.control.shutdown(); }
});

test('unconfirmed native retirement remains active even after shutdown promise settles', async t => {
  const f = await fixture(t, { nativeResult: { joined: false, retirementError: null, apiResult: null } });
  await f.enable(); await f.control.shutdown();
  assert.equal(f.control.status().state, 'unknown'); assert.equal(f.control.status().shutdownComplete, false);
  assert.equal(f.control.hasActiveWork(), true);
});
