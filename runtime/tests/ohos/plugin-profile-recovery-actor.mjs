// Separate process actor: real manager publishes; public lifecycle event marks crash boundary.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, existsSync, readlinkSync } from 'node:fs';
import { readFile, readdir } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { name, selectedPackage } from './plugin-package-harness.mjs';

const prefix = resolve(process.env.DSH_PREFIX);
const statePath = process.env.DSH_PLUGIN_CRASH_STATE;
const mode = process.argv[2];
const { createPluginBackend } = await import(pathToFileURL(resolve(process.env.DSH_PLUGIN_BACKEND_MODULE)));
const bootPath = join(prefix, 'node_modules/@deepseek-ai/dsh-app-boot/lib/index.js');
const { loadProfileDirectory, loadProfile } = await import(pathToFileURL(bootPath));
const anchor = join(prefix, 'node_modules/@deepseek-ai/dsh/package.json');
const readManifest = dir => JSON.parse(readFileSync(join(dir, 'package.json')));
const link = dir => selectedPackage(dir);
const journal = dir => join(dir, '.plugin-manager/ohos/transaction.json');

if (mode === 'crash' || mode === 'active-read') {
  const { fixture } = await import('./plugin-package-harness.mjs');
  let cleanup;
  const t = { name: mode, after(fn) { cleanup = fn; }, diagnostic() {} };
  const f = await fixture(t, {}, { profileName: 'crash-fixture' });
  const initial = await f.invoke('installBundle', name + '@1.0.0', { registry: f.registry, enabled: true });
  assert.equal(initial.application, 'restart-required');
  const state = { root: f.root, home: f.home, dir: f.dir, oldLink: link(f.dir),
    before: await f.snapshot(), version: '1.0.0', managerSha256: f.facts.managerSha256 };
  writeFileSync(statePath, JSON.stringify(state));
  let applying = false, eventError;
  const dispose = f.ctx.on('plugin-manager/install-state', progress => {
    if (progress.requestId !== 'crash-before-commit' || progress.phase !== 'applying') return;
    applying = true;
    try {
      const current = readManifest(f.dir);
      assert.equal(current.dependencies[name], '2.0.0');
      assert.notEqual(link(f.dir), state.oldLink);
      assert.equal(JSON.parse(readFileSync(journal(f.dir))).phase, 'pending');
      state.afterLink = link(f.dir); state.atCrash = current;
      writeFileSync(statePath, JSON.stringify(state));
      if (mode === 'crash') process.exit(71);
      const loaded = loadProfileDirectory('dsh', f.dir, anchor);
      assert.equal(readManifest(f.dir).dependencies[name], '2.0.0');
      assert.equal(link(f.dir), state.afterLink);
      assert(loaded.layers.some(layer => layer.packageName === name));
      assert(existsSync(journal(f.dir)), 'active read must not remove its owning transaction journal');
    } catch (error) { eventError = error; }
  });
  try {
    const update = await f.invoke('updateBundle', name, '2.0.0', { registry: f.registry, requestId: 'crash-before-commit' });
    assert.ifError(eventError);
    assert.equal(applying, true);
    assert.equal(update.result.application, 'restart-required');
    assert.equal(readManifest(f.dir).dependencies[name], '2.0.0');
    assert.equal(existsSync(journal(f.dir)), false);
    console.log(JSON.stringify({ mode, actualManager: true, activeReadPreserved: true, result: update }));
  } finally { dispose(); await cleanup(); }
} else {
  const state = JSON.parse(await readFile(statePath, 'utf8'));
  // No network is involved in startup recovery or an explicit local reset.
  globalThis[Symbol.for('dsh.go.ohos.plugins')] = createPluginBackend({ fetchImpl() { throw new Error('unexpected recovery network'); } });
  assert.equal(readManifest(state.dir).dependencies[name], '2.0.0', 'child left the published uncommitted version on disk');
  assert.equal(link(state.dir), state.afterLink);
  assert.equal(JSON.parse(readFileSync(journal(state.dir))).phase, 'pending');
  if (mode === 'reset') {
    const lib = join(prefix, 'node_modules/@deepseek-ai/dsh/lib');
    const chunk = (await readdir(lib)).find(file => /^profile-boot-.*\.js$/.test(file));
    const { i: initializeProfileFromDefault } = await import(pathToFileURL(join(lib, chunk)));
    initializeProfileFromDefault('crash-fixture', 'web', state.home);
    const fresh = readFileSync(join(state.dir, 'package.json'), 'utf8');
    loadProfileDirectory('dsh', state.dir, anchor);
    assert.equal(readFileSync(join(state.dir, 'package.json'), 'utf8'), fresh);
    assert.equal(readManifest(state.dir).dependencies?.[name], undefined);
    assert.equal(selectedPackage(state.dir), undefined);
    assert.equal(existsSync(journal(state.dir)), false);
    console.log(JSON.stringify({ mode, explicitResetPreserved: true }));
  } else {
    const loaded = mode === 'named-load'
      ? loadProfile('dsh', 'crash-fixture', anchor, state.home)
      : loadProfileDirectory('dsh', state.dir, anchor);
    console.log(JSON.stringify({ mode, version: readManifest(state.dir).dependencies[name], link: link(state.dir),
      journalExists: existsSync(journal(state.dir)), layers: loaded.layers.map(layer => layer.packageName) }));
    assert.equal(readManifest(state.dir).dependencies[name], '1.0.0', 'real profile loader must recover the old committed version');
    assert.equal(link(state.dir), state.oldLink);
    assert.equal(existsSync(journal(state.dir)), false);
    assert(loaded.layers.some(layer => layer.packageName === name));
    const after = {};
    for (const [file, value] of Object.entries(state.before)) {
      if (value.link) after[file] = { link: readlinkSync(join(state.dir, file)) };
      else {
        const { createHash } = await import('node:crypto');
        after[file] = { sha256: createHash('sha256').update(readFileSync(join(state.dir, file))).digest('hex') };
      }
    }
    assert.deepEqual(after, state.before);
  }
}
