// Test-only Cordis plugin. The package fixtures have empty YAML, never execute
// code, and are written only inside the fresh disposable profile used by round.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const name = 'ohos-plugin-install-observer';
export const inject = ['pluginManager'];
export async function apply(ctx, config) {
  const require = createRequire(join(config.prefix, 'package.json'));
  const entry = require.resolve('@deepseek-ai/dsh-plugin-manager');
  const hash = bytes => createHash('sha256').update(bytes).digest('hex');
  const sha256 = hash(readFileSync(entry));
  assert.equal(sha256, config.sha256);
  const { PluginManager } = await import(pathToFileURL(entry));
  const { readProfileManifest } = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-app-boot')));
  const { TYPERT } = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-plugin-manager/typert')));
  const manager = ctx.pluginManager;
  assert(manager instanceof PluginManager);
  assert.equal(process.platform, 'openharmony');

  const names = ['dsh-ohos-remove-fixture', 'dsh-ohos-update-fixture'];
  const files = ['package.json', 'pnpm-lock.yaml', 'cordis.patch.yml', 'pnpm-workspace.yaml'];
  const manifestPath = join(manager.profile.dir, 'package.json');
  const manifest = readProfileManifest('dsh', manager.profile.dir);
  manifest.dependencies = { ...manifest.dependencies };
  const selected = [...(manifest.dsh?.profile?.bundles ?? [])];
  for (const name of names) {
    const directory = join(manager.profile.dir, 'node_modules', name);
    assert(!existsSync(directory));
    mkdirSync(directory, { recursive: true });
    const packagePath = 'node_modules/' + name + '/package.json';
    const patchPath = 'node_modules/' + name + '/cordis.patch.yml';
    writeFileSync(join(manager.profile.dir, packagePath), JSON.stringify({
      name, version: '1.0.0', type: 'module', dsh: { bundle: { patch: 'cordis.patch.yml' } }
    }, null, 2) + '\n', { flag: 'wx' });
    writeFileSync(join(manager.profile.dir, patchPath), '[]\n', { flag: 'wx' });
    files.push(packagePath, patchPath);
    manifest.dependencies[name] = '1.0.0';
    selected.push(name);
  }
  manifest.dsh = { ...manifest.dsh, profile: { ...manifest.dsh?.profile, bundles: selected } };
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
  const bundles = async () => (await manager.listBundles()).filter(bundle => names.includes(bundle.name));
  const bundleBefore = await bundles();
  assert.equal(bundleBefore.length, names.length);
  for (const bundle of bundleBefore) {
    assert(bundle.installed && bundle.enabled && bundle.removable);
    assert.equal(bundle.error, undefined);
  }
  const snapshot = () => Object.fromEntries(files.map(name => {
    const file = join(manager.profile.dir, name);
    return [name, existsSync(file) ? hash(readFileSync(file)) : null];
  }));
  const before = snapshot();
  const pending = manager.installs.size;
  const installedFrom = [...manager.installedFrom];
  const events = [];
  const disposers = ['install-state', 'install-log', 'changed'].map(type =>
    ctx.on('plugin-manager/' + type, value => { events.push({ type, value }); }));
  const calls = [];
  const violations = [];
  function check(name, run) {
    try { run(); }
    catch (error) { violations.push({ name, message: error.message }); }
  }
  async function invoke(method, ...args) {
    const result = await manager[method](...args);
    calls.push({ method, result });
    check(method + ' wire schema', () => {
      const descriptor = TYPERT.invocations.find(item => item.method === method);
      assert.deepEqual(descriptor.result.create().parse(JSON.parse(JSON.stringify(result))), result);
    });
    return result;
  }
  function refused(result, stage, target) {
    assert.equal(result.application, 'failed');
    assert.equal(result.changed, false);
    assert.equal(result.stage, stage);
    assert.equal(result.target, target);
    assert.equal(result.error.code, 'operation-error');
    assert.match(result.error.diagnostic, /OHOS_PLUGIN_INSTALL_UNAVAILABLE.*连接电脑/);
    assert.equal(result.packageResult, undefined);
  }
  try {
    const inspection = await invoke('inspect', 'fixture-never-download@1', {}, new AbortController().signal);
    check('inspection refused', () => assert.equal(inspection.status, 'refused'));
    const registries = await invoke('registries');
    check('registry no pnpm resolution', () => assert.equal(registries.resolved, null));
    const install = await invoke('installBundle', 'fixture-never-download@1', {
      requestId: 'ohos-fixture-refusal', enabled: false, approvedBuilds: ['fixture-never-run'] });
    check('installation refusal', () => refused(install, 'install', 'fixture-never-download@1'));
    const remove = await invoke('removeBundle', names[0]);
    check('installed enabled removable bundle refusal', () => refused(remove, 'remove', names[0]));
    check('remove profile/files unchanged', () => assert.deepEqual(snapshot(), before));

    // Fixed Web client update first calls removeBundle, then opens the install
    // dialog even after a failed ChangeResult. Exercise those actual service
    // entries in that order; this is not a browser/UI execution claim.
    const updateRemove = await invoke('removeBundle', names[1]);
    check('update removal refusal', () => refused(updateRemove, 'remove', names[1]));
    const updateInspection = await invoke('inspect', names[1] + '@2.0.0', {}, new AbortController().signal);
    check('update inspection refusal', () => assert.equal(updateInspection.status, 'refused'));
    const updateInstall = await invoke('installBundle', names[1] + '@2.0.0', {
      requestId: 'ohos-update-refusal', enabled: true });
    check('update installation refusal', () => refused(updateInstall, 'install', names[1] + '@2.0.0'));
  } finally {
    for (const dispose of disposers) dispose();
  }
  const after = snapshot();
  const bundleAfter = await bundles();
  check('profile/dependency/file bytes unchanged', () => assert.deepEqual(after, before));
  check('installed/enabled/removable states unchanged', () => assert.deepEqual(bundleAfter, bundleBefore));
  check('install controls unchanged', () => assert.equal(manager.installs.size, pending));
  check('installed registry origins unchanged', () => assert.deepEqual([...manager.installedFrom], installedFrom));
  check('no install or changed events', () => assert.deepEqual(events, []));
  const record = { status: violations.length === 0 ? 'PASS' : 'FAIL', entry, sha256,
    scope: 'actual fixed DSH service and disposable profile filesystem; no method replacement; Linux not Ark/device/UI',
    actualServiceInstance: true, before, after, bundleBefore, bundleAfter,
    pendingBefore: pending, pendingAfter: manager.installs.size,
    calls, events, violations };
  if (config.output !== undefined) writeFileSync(config.output, JSON.stringify(record, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  console.log('[OHOS-MARKET-PROBE] ' + JSON.stringify(record));
}
