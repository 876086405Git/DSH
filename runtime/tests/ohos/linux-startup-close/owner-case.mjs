import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { access, readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { ownerFixture, until } from '../linux-control-fixture.mjs';
import { LinuxControl } from '../../../ohos/linux/control.mjs';
import * as installation from '../../../ohos/linux/owner.mjs';
import { loadLinuxNative } from '../../../ohos/linux/native-session.mjs';

const fault = process.env.DSH_TEST_STARTUP_CLOSE;
assert(['control', 'retain-eio'].includes(fault));
test('real startup close result controls actual Owner files, flock and Control', async t => {
  const f = await ownerFixture(t);
  const native = loadLinuxNative({ nativeLibraryDirectory: process.env.DSH_TEST_STARTUP_NATIVE });
  let owner;
  // Fault only this private generated config: drive0 actually opens, drive1
  // actually fails ENOENT before guest CPU dispatch. No fake native result.
  f.internals.createSession = path => {
    const config = JSON.parse(readFileSync(path, 'utf8'));
    process.env.DSH_TEST_STARTUP_DISK = config.drive0.file;
    process.env.DSH_TEST_STARTUP_SITE = 'drive';
    config.drive1.file = path + '.missing-drive';
    writeFileSync(path, JSON.stringify(config));
    return native.create(path);
  };
  const control = new LinuxControl({ hostPaths: { directory: f.data,
    nativeLibraryDirectory: process.env.DSH_TEST_STARTUP_NATIVE }, assetsDirectory: f.assets },
  { async loadModule() { return {
    loadLinuxInstallationManifest: installation.loadLinuxInstallationManifest,
    createLinuxInstallationOwner(options) { owner = f.createOwner({ ...options, bootTimeoutMs: 2000 }); return owner; },
    discardLinuxInstallation: options => installation.discardLinuxInstallation(options,
      { lockExclusive: f.internals.lockExclusive }),
  }; } });
  const command = action => { const { instanceId, attemptId } = control.status();
    return control.command({ v: 1, instanceId, attemptId, action,
      ...(action === 'setEnabled' ? { enabled: true } : {}) }); };
  command('setEnabled');
  await until(() => owner && ['failed', 'unknown'].includes(control.status().state));
  const result = await owner.dispose(), state = control.status();
  const names = (await readdir(f.data)).filter(name => name !== '.lock');
  let discardError = null; try { await command('discardRetained'); } catch (error) { discardError = error.code; }
  console.log('STARTUP_OWNER ' + JSON.stringify({ result, state, names, discardError }));
  assert.equal(owner.nativeOwnerCreated, true);
  assert.equal(result.native.joined, true); assert.equal(result.native.fdRetirement.retired, true);
  assert.equal(result.native.apiResult, fault === 'retain-eio' ? -8 : -1);
  assert.equal(result.native.retirementError, fault === 'retain-eio');
  assert.equal(result.resourcesRetired, fault !== 'retain-eio');
  assert.equal(result.filesRemoved, fault !== 'retain-eio');
  assert.equal(result.cleanCheckpoint, false);
  assert.equal(discardError, 'ERR_OHOS_LINUX_RESTART_REQUIRED', 'one actual native lifetime remains quarantined');
  if (fault === 'retain-eio') {
    assert.equal(names.length, 1); assert.equal(result.dataRetained, true);
    const directory = join(f.data, names[0]); await access(join(directory, 'target.ext4'));
    assert.equal(JSON.parse(await readFile(join(directory, 'instance.json'), 'utf8')).state, 'booting');
    await assert.rejects(installation.discardLinuxInstallation({ directory: f.data },
      { lockExclusive: f.internals.lockExclusive }), { code: 'ERR_OHOS_LINUX_BUSY' });
    assert.equal(state.state, 'unknown');
  } else assert.equal(names.length, 0);
  assert.equal((await control.shutdown()).shutdownComplete, fault !== 'retain-eio');
});
