import assert from 'node:assert/strict';
import { selectedPackage } from './plugin-selection-fixture.mjs';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync,
  unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

process.on('SIGXFSZ', () => {});
const storeUrl = process.env.DSH_PLUGIN_STORE_MODULE
  ? pathToFileURL(resolve(process.env.DSH_PLUGIN_STORE_MODULE))
  : new URL('../../ohos/plugins/store.mjs', import.meta.url);
const { beginTransaction, recoverProfile, transactionFor } = await import(storeUrl);

async function setLimit(stage) {
  const acknowledged = new Promise(resolve => process.once('message', resolve));
  process.send({ stage });
  assert.deepEqual(await acknowledged, { stage });
}
function checkWritable(root) {
  const path = join(root, 'writes-restored');
  writeFileSync(path, 'kernel write succeeds again');
  assert.equal(readFileSync(path, 'utf8'), 'kernel write succeeds again');
  unlinkSync(path);
}
function stagePackage(tx, version) {
  const pkg = join(tx.newGeneration(), 'pkg');
  mkdirSync(pkg);
  writeFileSync(join(pkg, 'package.json'), JSON.stringify({ name: 'write-failure-plugin', version }));
  tx.publish('write-failure-plugin', pkg);
  tx.writeManifest({ dependencies: { 'write-failure-plugin': version } });
  return pkg;
}

let cleanup;
try {
  if (process.argv[2] === 'manager-rollback') {
    const { fixture, name, runInstalledTool } = await import('./plugin-package-harness.mjs');
    const f = await fixture({ name: 'write-failure-manager', after(fn) { cleanup = fn; }, diagnostic() {} });
    const initial = await f.invoke('installBundle', name + '@1.0.0', { registry: f.registry, enabled: false });
    assert.equal(initial.application, 'restart-required');
    const before = await f.snapshot(), beforeSelection = selectedPackage(f.dir, name);
    f.holdTar('2.0.0');
    const pending = f.invoke('updateBundle', name, '2.0.0', { registry: f.registry, requestId: 'write-failure-update' });
    await f.tarEntered.promise;
    await setLimit('limit');
    const cancel = await f.invoke('cancelInstall', 'write-failure-update')
      .then(value => ({ value }), error => ({ error }));
    const { result: failed } = await pending;
    assert.equal(failed.application, 'failed');
    assert.match(failed.error.diagnostic, /EFBIG/);
    // The manager's own restore step hit the limit, so cancellation reports
    // that failure instead of acknowledging it (plugin-manager-cancel-tree-confirmation);
    // the journal's final rollback below still restores the profile.
    assert.equal(cancel.error?.code, 'EFBIG', 'cancellation must not acknowledge a failed restore step');
    assert.equal(cancel.error.message, failed.error.diagnostic);
    const journal = join(f.dir, '.plugin-manager/ohos/transaction.json');
    assert.equal(existsSync(join(f.dir, 'package.json.lock')), false);
    // The ordinary beforeimages permit the manager's final rollback while the
    // kernel write limit is still zero. This completed recovery has no journal.
    assert.equal(existsSync(journal), false, 'completed rollback removes its journal without waiting for writable space');
    assert.deepEqual(await f.snapshot(), before, 'profile bytes and active selection are restored before writes resume');
    assert.equal(selectedPackage(f.dir, name), beforeSelection);
    await runInstalledTool(f.dir, '1.0.0');
    process.send({ stage: 'rollback-complete', writesStillLimited: true, cancelError: cancel.error.code,
      journalRemoved: true, restoredVersion: '1.0.0', actualToolVersion: '1.0.0' });
    await setLimit('restore');
    checkWritable(f.root);
    f.holdTar(undefined);
    const { result: retry } = await f.invoke('updateBundle', name, '2.0.0', { registry: f.registry });
    assert.equal(retry.application, 'restart-required', JSON.stringify(retry));
    assert.equal(JSON.parse(readFileSync(f.manifestPath, 'utf8')).dependencies[name], '2.0.0');
    await runInstalledTool(f.dir, '2.0.0');
    assert.equal(existsSync(journal), false);
    process.send({ stage: 'recovered', mode: 'manager-rollback', writesRestored: true,
      journalRemoved: true, initialError: failed.error.diagnostic, application: retry.application });
  } else {
    assert.equal(process.argv[2], 'commit-marker');
    const dir = mkdtempSync(join(tmpdir(), 'plugin-commit-write-failure-'));
    cleanup = () => rmSync(dir, { recursive: true, force: true });
    writeFileSync(join(dir, 'package.json'), '{"dependencies":{}}\n');
    let tx = beginTransaction(dir);
    const old = stagePackage(tx, '1.0.0');
    tx.finish(true);
    const before = readFileSync(join(dir, 'package.json'));
    tx = beginTransaction(dir);
    const newer = stagePackage(tx, '2.0.0');
    await setLimit('limit');
    assert.throws(() => tx.finish(true), { code: 'EFBIG' });
    const journal = join(dir, '.plugin-manager/ohos/transaction.json');
    assert.equal(JSON.parse(readFileSync(journal, 'utf8')).phase, 'pending',
      'the failed commit marker must leave the previous durable pending journal');
    await setLimit('restore');
    checkWritable(dir);
    recoverProfile(dir);
    assert.deepEqual(readFileSync(join(dir, 'package.json')), before);
    assert.equal(selectedPackage(dir, 'write-failure-plugin'), old);
    assert.equal(existsSync(newer), false);
    tx = beginTransaction(dir);
    assert.equal(transactionFor(dir), tx);
    stagePackage(tx, '3.0.0');
    tx.finish(true);
    assert.equal(JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')).dependencies['write-failure-plugin'], '3.0.0');
    assert.equal(existsSync(journal), false);
    process.send({ stage: 'recovered', mode: 'commit-marker', writesRestored: true,
      journalRemoved: true, restoredVersion: '1.0.0', committedRetryVersion: '3.0.0' });
  }
} catch (error) {
  process.send({ stage: 'failure', code: error.code, message: error.message });
  console.error(error);
  process.exitCode = 1;
} finally {
  await cleanup?.();
  process.disconnect();
}
