import assert from 'node:assert/strict';
import { existsSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { fixture, name, executeTool, selectedPackage } from './plugin-package-harness.mjs';
import { toolSource } from './plugin-package-fixture.mjs';

// A real kernel EFBIG must be observable instead of terminating this fixture.
process.on('SIGXFSZ', () => {});
async function barrier(stage) {
  const acknowledged = new Promise(resolve => process.once('message', resolve));
  process.send({ stage });
  assert.deepEqual(await acknowledged, { stage });
}
globalThis.__pluginCommitBarrier = () => barrier('limit');

async function assertToolAbsent(ctx) {
  assert.equal(ctx.tools.get('ohos_installed_echo'), undefined);
  const batch = await ctx.tools.execute({ calls: [{ id: 'failed-install-tool',
    name: 'ohos_installed_echo', arguments: '{"text":"failed installation"}' }],
    signal: new AbortController().signal });
  const result = batch.results[0].result;
  assert.equal(result.isError, true);
  assert.equal(result.error.info.code, 'UNKNOWN_TOOL');
}

let cleanup;
try {
  const mode = process.argv[2];
  assert.ok(['direct', 'list-versions', 'load-profile', 'healthy'].includes(mode));
  const yaml = JSON.stringify([{ insert: [{ id: 'owned-tool', name }] }]);
  const source = toolSource('1.0.0')
    .replace('export function apply(ctx)', 'export async function apply(ctx)')
    .replace(/\n}\n$/, '\n  await globalThis.__pluginCommitBarrier();\n}\n');
  const f = await fixture({ name: 'hmr-terminal-write-' + mode,
    after(fn) { cleanup = fn; }, diagnostic() {} }, {
    '1.0.0': { yaml, source },
    '2.0.0': { yaml, source: toolSource('2.0.0') + '\nexport const loadedUrl = import.meta.url;\n' },
  }, { hmr: true, profileName: 'hmr-write-failure' });
  const previous = [...f.ctx.loader.entries()].filter(entry => entry.fiber?.state === 2)
    .map(entry => ({ entry, fiber: entry.fiber }));
  const initial = await f.invoke('installBundle', name + '@1.0.0', { registry: f.registry, enabled: true });
  if (mode === 'healthy') {
    assert.equal(initial.application, 'applied', JSON.stringify(initial));
    await executeTool(f.ctx, '1.0.0');
    process.send({ stage: 'healthy', application: initial.application, toolVersion: '1.0.0' });
  } else {
    assert.equal(initial.application, 'failed', JSON.stringify(initial));
    assert.match(initial.error.diagnostic, /EFBIG/);
    await assertToolAbsent(f.ctx);
    for (const { entry, fiber } of previous) {
      assert.equal(entry.fiber, fiber, 'unchanged active services must retain their fibers');
      assert.equal(fiber.state, 2);
    }
    const journal = join(f.dir, '.plugin-manager/ohos/transaction.json');
    const failedGeneration = selectedPackage(f.dir);
    assert.equal(JSON.parse(readFileSync(journal, 'utf8')).phase, 'pending');
    process.send({ stage: 'failed', application: initial.application,
      error: initial.error, toolCode: 'UNKNOWN_TOOL', journalPhase: 'pending' });
    await barrier('restore');
    const writable = join(f.root, 'writes-restored');
    writeFileSync(writable, 'actual kernel write');
    assert.equal(readFileSync(writable, 'utf8'), 'actual kernel write');
    if (mode === 'list-versions') await f.manager.listVersions(name, { registry: f.registry });
    if (mode === 'load-profile') {
      const { loadProfile } = await import(pathToFileURL(join(process.env.DSH_PREFIX,
        'node_modules/@deepseek-ai/dsh-app-boot/lib/index.js')));
      loadProfile('dsh', 'hmr-write-failure',
        join(process.env.DSH_PREFIX, 'node_modules/@deepseek-ai/dsh/package.json'), f.home);
    }
    if (mode !== 'direct') {
      assert.equal(existsSync(journal), false, 'the real profile read must recover the pending transaction');
      assert.equal(existsSync(failedGeneration), false);
      assert.equal(JSON.parse(readFileSync(f.manifestPath, 'utf8')).dependencies[name], undefined);
    }
    await assertToolAbsent(f.ctx);
    const next = await f.invoke('installBundle', name + '@2.0.0', { registry: f.registry, enabled: true });
    assert.equal(next.application, 'applied', JSON.stringify(next));
    await executeTool(f.ctx, '2.0.0');
    const row = [...f.ctx.loader.entries()].find(entry => entry.options.id === 'owned-tool');
    const generation = selectedPackage(f.dir);
    assert.equal(row.moduleNamespace.loadedUrl, pathToFileURL(join(generation, 'index.mjs')).href);
    assert.notEqual(generation, failedGeneration);
    assert.equal(existsSync(failedGeneration), false);
    assert.equal(existsSync(journal), false);
    assert.equal(JSON.parse(readFileSync(f.manifestPath, 'utf8')).dependencies[name], '2.0.0');
    process.send({ stage: 'recovered', mode, application: next.application,
      writesRestored: true, journalRemoved: true, toolVersion: '2.0.0' });
  }
} catch (error) {
  process.send({ stage: 'failure', code: error.code, message: error.message });
  console.error(error);
  process.exitCode = 1;
} finally {
  // On a red assertion, restore the child's real resource limit before cleanup.
  await barrier('restore');
  await cleanup?.();
  delete globalThis.__pluginCommitBarrier;
  process.disconnect();
}
