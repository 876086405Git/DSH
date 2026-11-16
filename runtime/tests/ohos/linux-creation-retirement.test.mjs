import test from 'node:test';
import assert from 'node:assert/strict';
import { readdir } from 'node:fs/promises';
import { ownerFixture, until } from './linux-control-fixture.mjs';
import { LinuxControl } from '../../ohos/linux/control.mjs';
import * as installation from '../../ohos/linux/owner.mjs';
import { loadLinuxNative } from '../../ohos/linux/native-session.mjs';

const mode = process.env.DSH_TEST_OWNER_FAULT;
assert.ok(['rollback-close', 'create-eagain'].includes(mode));

test(`actual native construction ${mode} reaches actual Owner and Control`, async t => {
  const f = await ownerFixture(t);
  const native = loadLinuxNative({ nativeLibraryDirectory: process.env.DSH_REVIEW_NATIVE_DIRECTORY });
  let owner, config, creationCause;
  f.internals.createSession = path => {
    config = path;
    try { return native.create(path); }
    catch (cause) { creationCause = cause; throw cause; }
  };
  const control = new LinuxControl({
    hostPaths: { directory: f.data, nativeLibraryDirectory: process.env.DSH_REVIEW_NATIVE_DIRECTORY },
    assetsDirectory: f.assets,
  }, { async loadModule() {
    return {
      loadLinuxInstallationManifest: installation.loadLinuxInstallationManifest,
      createLinuxInstallationOwner(options) { owner = f.createOwner(options); return owner; },
      discardLinuxInstallation: options => installation.discardLinuxInstallation(options, {
        lockExclusive: process._linkedBinding('dsh_ohos_publication').lockExclusive,
      }),
    };
  } });
  const command = (action, fields = {}) => {
    const status = control.status();
    return control.command({ v: 1, instanceId: status.instanceId,
      attemptId: status.attemptId, action, ...fields });
  };
  command('setEnabled', { enabled: true });
  await until(() => owner && ['failed', 'unknown'].includes(control.status().state));
  const retirement = await owner.dispose();
  const stateBeforeDiscard = control.status();
  const namesBeforeDiscard = await readdir(f.data);
  let nativeReadmissionError = null;
  if (mode === 'rollback-close') {
    try { native.create(config); }
    catch (cause) { nativeReadmissionError = cause.code; }
  }
  let discardError = null;
  try { await command('discardRetained'); }
  catch (cause) { discardError = cause.code; }
  const stateAfterDiscard = control.status();
  console.log('CREATION_DEBT_OBSERVATION ' + JSON.stringify({
    mode, creationError: creationCause?.code,
    nativeOwnerCreated: owner.nativeOwnerCreated,
    ownerState: owner.state, retirement,
    stateBeforeDiscard, stateAfterDiscard, namesBeforeDiscard,
    nativeReadmissionError, discardError,
  }));
  assert.equal(owner.nativeOwnerCreated, false, 'the failed pthread_create never became a VM session');
  assert.equal(retirement.native, undefined, 'construction rollback must not invent a join observation');
  if (mode === 'rollback-close') {
    assert.equal(nativeReadmissionError, 'ERR_OHOS_LINUX_OWNER_QUARANTINED');
    assert.equal(retirement.resourcesRetired, false,
      'native keeps claimed after uncertain close; Owner cannot declare all native resources retired');
    assert.equal(retirement.ownerQuarantined, true);
    assert.equal(retirement.filesRemoved, false);
    assert.equal(retirement.dataRetained, true);
    assert.equal(stateBeforeDiscard.state, 'unknown');
    assert.equal(discardError, 'ERR_OHOS_LINUX_RESTART_REQUIRED');
  } else {
    assert.equal(creationCause.code, 'ERR_OHOS_LINUX_CREATE');
    assert.equal(retirement.resourcesRetired, true);
    assert.equal(retirement.ownerQuarantined, false);
    assert.equal(retirement.filesRemoved, true);
    assert.equal(discardError, null);
    assert.equal(stateAfterDiscard.state, 'disabled');
    assert.equal(stateAfterDiscard.restartRequired, false);
  }
});
