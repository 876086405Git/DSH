import test from 'node:test';
import assert from 'node:assert/strict';
import { writeFile, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setImmediate as immediate } from 'node:timers/promises';
import { fixture, name, hash, runInstalledTool, selectedEntry } from './plugin-package-harness.mjs';

test('real OH PluginManager inspects, installs, updates and removes a registry JS bundle', { timeout: 30000 }, async t => {
  const f = await fixture(t);
  const { manager, invoke, manifestPath, registry, facts, dir } = f;
  const before = await readFile(manifestPath, 'utf8');
  const inspection = await invoke('inspect', name + '@1.0.0', { registry }, new AbortController().signal);
  // Make the actual installation call even if inspection was refused, preserving business-red evidence.
  const installed = await invoke('installBundle', name + '@1.0.0', { registry, enabled: false, requestId: 'ohos-own-install' });
  facts.beforeManifest = hash(before);
  facts.afterInstallManifest = hash(await readFile(manifestPath, 'utf8'));
  assert.equal(inspection.status, 'accepted', 'pure JS registry package must be inspectable on OH');
  assert.equal(installed.changed, true);
  assert.equal(installed.application, 'restart-required');
  assert.equal(installed.error, undefined);
  let bundle = (await manager.listBundles()).find(item => item.name === name);
  assert(bundle?.installed); assert.equal(bundle.version, '1.0.0'); assert.equal(bundle.enabled, false); assert.equal(bundle.error, undefined);
  facts.tool = await runInstalledTool(dir, '1.0.0');
  const updated = await invoke('updateBundle', name, '2.0.0', { registry, requestId: 'ohos-own-update' });
  assert.equal(updated.result.changed, true); assert.equal(updated.result.application, 'restart-required');
  bundle = (await manager.listBundles()).find(item => item.name === name);
  assert.equal(bundle.version, '2.0.0'); assert.equal(bundle.enabled, false);
  const removed = await invoke('removeBundle', name);
  assert.equal(removed.changed, true); assert.equal(removed.application, 'restart-required');
  assert.equal((await manager.listBundles()).some(item => item.name === name && item.installed), false);
  assert(facts.requests.includes('/tar/1.0.0')); assert(facts.requests.includes('/tar/2.0.0'));
});


for (const [label, definition, code] of [
  ['no bundle declaration', { manifest: { dsh: {} } }, 'not-bundle'],
  ['invalid bundle YAML', { yaml: '[invalid: [\n' }, 'operation-error'],
  ['incompatible DSH engine', { manifest: { engines: { dsh: '>=999.0.0' } } }, 'incompatible-version'],
]) test(`post-install ${label} restores profile files and root links`, { timeout: 30000 }, async t => {
  const f = await fixture(t, { '1.0.0': definition });
  await writeFile(join(f.dir, 'user-note.txt'), 'keep existing user data');
  const before = await f.snapshot();
  const result = await f.invoke('installBundle', name + '@1.0.0', { registry: f.registry, enabled: true });
  assert.equal(result.application, 'failed'); assert.equal(result.changed, false);
  assert.equal(result.error.code, code);
  assert.equal(result.packageResult.exitCode, 0, 'failure follows successful download/extract/publication');
  assert(f.facts.requests.includes('/tar/1.0.0'));
  assert.deepEqual(await f.snapshot(), before);
  assert.equal((await f.manager.listBundles()).some(row => row.name === name && row.installed), false);
});

test('failed update preserves old root, package files and enabled selection', { timeout: 30000 }, async t => {
  const f = await fixture(t);
  const installed = await f.invoke('installBundle', name + '@1.0.0', { registry: f.registry, enabled: true });
  assert.equal(installed.application, 'restart-required');
  const before = await f.snapshot();
  const oldEntry = selectedEntry(f.dir), oldBytes = await readFile(oldEntry);
  f.corruptTar('2.0.0');
  const update = await f.invoke('updateBundle', name, '2.0.0', { registry: f.registry });
  assert.equal(update.result.application, 'failed'); assert.equal(update.result.changed, false);
  assert.deepEqual(await f.snapshot(), before);
  assert.deepEqual(await readFile(oldEntry), oldBytes);
  const row = (await f.manager.listBundles()).find(row => row.name === name);
  assert.equal(row.version, '1.0.0'); assert.equal(row.enabled, true);
});

test('cancelInstall waits for a held tar download to stop and restores the profile', { timeout: 30000 }, async t => {
  const f = await fixture(t), id = 'owned-cancel-download';
  const before = await f.snapshot(); f.holdTar('1.0.0');
  const pending = f.invoke('installBundle', name + '@1.0.0', { registry: f.registry, enabled: true, requestId: id });
  // Fail promptly if installation ends before it can reach the real held response.
  await Promise.race([f.tarEntered.promise, pending.then(result => { throw new Error('Install ended before held tar: ' + JSON.stringify(result)); })]);
  const cancelled = await f.invoke('cancelInstall', id);
  assert.equal(cancelled.status, 'cancelled');
  const result = await pending;
  assert.equal(result.application, 'cancelled'); assert.equal(result.changed, false);
  assert.equal(f.manager.installs.size, 0);
  await immediate();
  assert.deepEqual(await f.snapshot(), before);
  assert.equal((await f.manager.listBundles()).some(row => row.name === name && row.installed), false);
});

test('approvedBuilds is refused before network or any profile file changes', { timeout: 30000 }, async t => {
  const f = await fixture(t), before = await f.snapshot(true);
  const result = await f.invoke('installBundle', name + '@1.0.0', { registry: f.registry, approvedBuilds: [name] });
  assert.equal(result.application, 'failed'); assert.equal(result.changed, false);
  assert.deepEqual(await f.snapshot(true), before); assert.deepEqual(f.facts.requests, []);
});

test('actually loaded startup bundle removal reports stop-profile and keeps its root', { timeout: 30000 }, async t => {
  const f = await fixture(t);
  const installed = await f.invoke('installBundle', name + '@1.0.0', { registry: f.registry, enabled: true });
  assert.equal(installed.application, 'restart-required');
  await f.restartActive();
  assert(f.ctx.tools.get('ohos_installed_echo'), 'installed module actually started in the profile loader');
  const before = await f.snapshot();
  const result = await f.invoke('removeBundle', name);
  assert.equal(result.application, 'failed'); assert.equal(result.changed, false);
  assert.equal(result.error.code, 'stop-profile');
  assert.deepEqual(await f.snapshot(), before);
});
