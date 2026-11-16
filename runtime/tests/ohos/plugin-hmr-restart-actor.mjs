import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { fixture, name, executeTool, selectedPackage } from './plugin-package-harness.mjs';
const statePath = process.env.DSH_PLUGIN_HMR_STATE;
const mode = process.argv[2];
if (mode === 'update') {
  const cleanup = [];
  const t = { name: 'actual HMR update before new process', after: fn => cleanup.push(fn), diagnostic: value => console.log(value) };
  const yaml = JSON.stringify([{ insert: [{ id: 'owned-tool', name }] }]);
  const f = await fixture(t, { '1.0.0': { yaml }, '2.0.0': { yaml } }, { hmr: true, keepProfile: true, profileName: 'hmr-restart' });
  await writeFile(statePath, JSON.stringify({ root: f.root, home: f.home, dir: f.dir }));
  try {
    await f.invoke('installBundle', name + '@1.0.0', { registry: f.registry, enabled: true });
    await executeTool(f.ctx, '1.0.0');
    const update = await f.invoke('updateBundle', name, '2.0.0', { registry: f.registry });
    assert.equal(update.result.application, 'restart-required');
    assert.equal(update.result.changed, true);
    assert.equal(JSON.parse(await readFile(join(selectedPackage(f.dir), 'package.json'))).version, '2.0.0');
    await executeTool(f.ctx, '1.0.0');
    console.log('disk-v2-running-tool-v1');
  } finally { for (const fn of cleanup.reverse()) await fn(); }
} else {
  assert.equal(mode, 'boot');
  const state = JSON.parse(await readFile(statePath));
  const prefix = resolve(process.env.DSH_PREFIX), installAnchor = join(prefix, 'node_modules/@deepseek-ai/dsh/package.json');
  const { boot, loadProfileDirectory, createRuntimeResolution, PluginPackages } = await import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai/dsh-app-boot/lib/index.js')));
  const profile = loadProfileDirectory('dsh', state.dir, installAnchor);
  assert.deepEqual(profile.skippedBundles, []);
  const resolution = await createRuntimeResolution({ installAnchor, home: state.home, profile });
  const listeners = new Set(); let ready = false;
  const ctx = await boot('dsh', join(state.dir, 'cordis.yml'), [...profile.layers.flatMap(layer => layer.patches), ...profile.patches], async c => {
    c.provide('profileContext', { dir: state.dir, home: state.home, installAnchor, patchPath: profile.patchPath,
      overlays: [], startedBundles: profile.layers.map(layer => layer.packageName), telemetryDisabledEnv: '1' });
    c.provide('appReady', { onReady(listener) { if (ready) listener(); else listeners.add(listener); return () => listeners.delete(listener); } });
    await c.plugin(PluginPackages, { resolution });
  });
  ready = true; for (const listener of listeners) listener(); listeners.clear();
  try { await executeTool(ctx, '2.0.0'); console.log('fresh-process-real-boot-tool-v2'); }
  finally { await ctx.fiber.dispose(); }
}
