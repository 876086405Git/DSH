import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { npmBomGraphArchive, npmBomDependencyArchive } from './plugin-archive-fixture.mjs';
import { realpath, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { fixture, name, executeTool, selectedPackage } from './plugin-package-harness.mjs';
import { toolSource } from './plugin-package-fixture.mjs';

test('OH HMR removal and reinstallation load each new physical generation', { timeout: 30000 }, async t => {
  const { Context: HostContext } = await import(pathToFileURL(join(process.env.DSH_PREFIX, 'node_modules/@deepseek-ai/cordis/lib/index.js')));
  const versions = ['1.0.0', '2.0.0', '3.0.0'];
  const yaml = JSON.stringify([{ insert: [{ id: 'owned-tool', name }] }]);
  const definitions = Object.fromEntries(versions.map(version => [version, {
    yaml,
    manifest: { peerDependencies: { '@deepseek-ai/cordis': '^4.1.0' } },
    source: toolSource(version) + '\nexport { Context as PeerContext } from "@deepseek-ai/cordis";\nexport const loadedUrl = import.meta.url;\nexport const readRelative = () => import("./relative.mjs");\n',
    files: { 'relative.mjs': `export const version = ${JSON.stringify(version)};` },
  }]));
  const f = await fixture(t, definitions, { hmr: true });
  const namespaces = new Set(), urls = new Set();
  for (const version of versions) {
    const installed = await f.invoke('installBundle', `${name}@${version}`, { registry: f.registry, enabled: true });
    assert.equal(installed.application, 'applied', JSON.stringify(installed));
    await executeTool(f.ctx, version);
    const row = [...f.ctx.loader.entries()].find(entry => entry.options.id === 'owned-tool');
    assert.ok(row?.moduleNamespace, 'actual Loader entry must expose its loaded namespace');
    const namespace = row.moduleNamespace;
    assert.equal(namespace.PeerContext, HostContext, 'declared core peer must retain the actual Host singleton');
    const root = selectedPackage(f.dir);
    assert.equal(namespace.loadedUrl, pathToFileURL(join(root, 'index.mjs')).href);
    assert.equal(namespaces.has(namespace), false, 'reinstall must not reuse the removed module namespace');
    assert.equal(urls.has(namespace.loadedUrl), false, 'reinstall must load a new generation URL');
    assert.equal((await namespace.readRelative()).version, version, 'relative import must resolve inside the active generation');
    namespaces.add(namespace); urls.add(namespace.loadedUrl);
    const removed = await f.invoke('removeBundle', name);
    assert.equal(removed.application, 'applied', JSON.stringify(removed));
    assert.equal(f.ctx.tools.get('ohos_installed_echo'), undefined, 'removal must revoke the executable contribution');
    assert.equal(row.fiber.state, 4, 'removed Loader fiber must be disposed');
  }
});

test('OH installed update keeps old live module and its first late relative import until restart', { timeout: 30000 }, async t => {
  const yaml = JSON.stringify([{ insert: [{ id: 'owned-tool', name }] }]);
  const definitions = Object.fromEntries(['1.0.0', '2.0.0'].map(version => [version, {
    yaml,
    source: toolSource(version) + '\nexport const loadedUrl = import.meta.url;\nexport const readLate = () => import("./late.mjs");\n',
    files: { 'late.mjs': `export const version = ${JSON.stringify(version)};` },
  }]));
  const f = await fixture(t, definitions, { hmr: true });
  const installed = await f.invoke('installBundle', `${name}@1.0.0`, { registry: f.registry, enabled: true });
  assert.equal(installed.application, 'applied');
  const oldRow = [...f.ctx.loader.entries()].find(entry => entry.options.id === 'owned-tool');
  const oldModule = oldRow.moduleNamespace;
  const updated = await f.invoke('updateBundle', name, '2.0.0', { registry: f.registry });
  assert.equal(updated.result.application, 'restart-required', JSON.stringify(updated));
  const current = [...f.ctx.loader.entries()].find(entry => entry.options.id === 'owned-tool');
  assert.equal(current.moduleNamespace, oldModule);
  assert.equal(current.fiber, oldRow.fiber);
  assert.notEqual(pathToFileURL(join(selectedPackage(f.dir), 'index.mjs')).href, oldModule.loadedUrl);
  assert.equal((await oldModule.readLate()).version, '1.0.0', 'first late import after update must still resolve old files');
  await executeTool(f.ctx, '1.0.0');
});


test('real npm BOM bundle activates, lists without metadata error and removes', { timeout: 30000 }, async t => {
  const dependency = { name: 'fixture-bom-dependency', version: '1.0.0', type: 'module', exports: './index.js',
    dist: { integrity: 'sha512-' + createHash('sha512').update(npmBomDependencyArchive).digest('base64'),
      tarball: 'https://registry.ohos-fixture.test/bom-dependency.tgz' } };
  const f = await fixture(t, { '1.0.0': { archive: npmBomGraphArchive,
    manifest: { dependencies: { [dependency.name]: dependency.version } } } }, { hmr: true, network: {
      onRequest(req, res) {
        if (req.url === '/bom-dependency.tgz') res.end(npmBomDependencyArchive);
        else if (req.url === '/' + dependency.name) res.end(JSON.stringify({ name: dependency.name, versions: { '1.0.0': dependency } }));
        else return false;
        return true;
      },
    } });
  const installed = await f.invoke('installBundle', `${name}@1.0.0`, { registry: f.registry, enabled: true });
  assert.equal(installed.application, 'applied', JSON.stringify(installed));
  await executeTool(f.ctx, '1.0.0');
  const row = (await f.manager.listBundles()).find(item => item.name === name);
  assert.equal(row?.installed, true);
  assert.equal(row.enabled, true);
  assert.equal(row.meta?.error, undefined);
  for (const item of row.rows) assert.equal(item.meta?.error, undefined);
  assert.equal((await readFile(join(selectedPackage(f.dir), 'package.json'))).subarray(0, 3).toString('hex'), 'efbbbf');
  const packageRequire = createRequire(join(selectedPackage(f.dir), 'package.json'));
  const dependencyEntry = packageRequire.resolve('fixture-bom-dependency');
  assert.equal((await readFile(join(dependencyEntry, '..', 'package.json'))).subarray(0, 3).toString('hex'), 'efbbbf');
  const removed = await f.invoke('removeBundle', name);
  assert.equal(removed.application, 'applied', JSON.stringify(removed));
  assert.equal(f.ctx.tools.get('ohos_installed_echo'), undefined);
});
