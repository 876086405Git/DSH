import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, lstat } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { fixture, name, executeTool, selectedPackage } from './plugin-package-harness.mjs';
import { toolSource } from './plugin-package-fixture.mjs';

const { Context } = await import(pathToFileURL(join(process.env.DSH_PREFIX,
  'node_modules/@deepseek-ai/cordis/lib/index.js')));
function context(t) {
  const ctx = new Context();
  t.after(() => ctx.fiber.dispose());
  return ctx;
}

test('OH effect keeps successful synchronous cleanup synchronous and LIFO', t => {
  const ctx = context(t), order = [];
  const dispose = ctx.effect(function* () {
    yield () => { order.push('first'); };
    yield () => { order.push('last'); };
  });
  assert.equal(dispose(), undefined);
  assert.deepEqual(order, ['last', 'first']);
  assert.equal(dispose(), undefined);
  assert.deepEqual(order, ['last', 'first'], 'cleanup must not repeat');
});

test('OH effect completes synchronous cleanup before throwing the first value', t => {
  const ctx = context(t), order = [], later = new Error('later failure');
  const dispose = ctx.effect(function* () {
    yield () => { order.push('first'); };
    yield () => { order.push('middle'); throw later; };
    yield () => { order.push('last'); throw undefined; };
  });
  let threw = false;
  try { dispose(); } catch (error) { threw = true; assert.equal(error, undefined); }
  assert.equal(threw, true, 'even an undefined thrown value must stay a synchronous throw');
  assert.deepEqual(order, ['last', 'middle', 'first']);
  assert.equal(dispose(), undefined);
  assert.deepEqual(order, ['last', 'middle', 'first']);
});

test('OH effect waits for an async rejection before remaining LIFO cleanup and preserves its error', async t => {
  const ctx = context(t), order = [], first = new Error('first failure'), later = new Error('later failure');
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const dispose = ctx.effect(function* () {
    yield () => { order.push('first'); };
    yield () => { order.push('middle'); throw later; };
    yield async () => { order.push('last-start'); await gate; order.push('last-end'); throw first; };
  });
  const pending = dispose();
  assert.equal(typeof pending.then, 'function');
  const rejected = assert.rejects(pending, error => error === first);
  try {
    await Promise.resolve();
    assert.deepEqual(order, ['last-start'], 'earlier cleanup must wait for the pending disposer');
  } finally { release(); }
  await rejected;
  assert.deepEqual(order, ['last-start', 'last-end', 'middle', 'first']);
  assert.equal(dispose(), undefined);
  assert.deepEqual(order, ['last-start', 'last-end', 'middle', 'first']);
});

test('OH effect preserves an earlier synchronous error through a later rejecting thenable', async t => {
  const ctx = context(t), order = [], first = new Error('sync first'), later = new Error('thenable later');
  const dispose = ctx.effect(function* () {
    yield () => { order.push('first'); };
    yield () => ({ then(resolve, reject) { order.push('middle'); reject(later); } });
    yield () => { order.push('last'); throw first; };
  });
  const pending = dispose();
  assert.equal(typeof pending.then, 'function');
  await assert.rejects(pending, error => error === first);
  assert.deepEqual(order, ['last', 'middle', 'first']);
});

function groupedToolSource(reject) {
  const original = toolSource('1.0.0'), end = '  });\n}\n';
  assert.equal(original.split(end).length, 2);
  return original.replace('export const inject', 'export const disposalTrace = [];\nexport const inject')
    .replace('  ctx.tools.register({', '  ctx.effect(function* () {\n    yield ctx.tools.register({')
    .replace(end, `    });
    yield () => { disposalTrace.push('sibling-cleanup-ran'); };
    yield async () => {
      disposalTrace.push('last-disposer-entered');
      await Promise.resolve();
      ${reject ? "disposalTrace.push('intentional-rejection'); throw new Error('OH_GROUPED_DISPOSE_REJECT');" : "disposalTrace.push('normal-disposer-returned');"}
    };
  }, 'installed-grouped-tool');
}
`);
}

for (const reject of [false, true]) {
  test(`OH installed tool is revoked after grouped cleanup ${reject ? 'rejects' : 'succeeds'} and can reinstall`,
    { timeout: 30000 }, async t => {
      const yaml = JSON.stringify([{ insert: [{ id: 'owned-tool', name }] }]);
      const f = await fixture(t, { '1.0.0': { yaml, source: groupedToolSource(reject) }, '2.0.0': { yaml } }, { hmr: true });
      const events = [];
      f.ctx.on('plugin-manager/operation', event => { events.push(event); });
      const installed = await f.invoke('installBundle', `${name}@1.0.0`, { registry: f.registry, enabled: true });
      assert.equal(installed.application, 'applied', JSON.stringify(installed));
      await executeTool(f.ctx, '1.0.0');
      const entry = [...f.ctx.loader.entries()].find(row => row.options.id === 'owned-tool');
      assert.ok(entry?.fiber);
      const fiber = entry.fiber, namespace = entry.moduleNamespace;
      const removed = await f.invoke('removeBundle', name);
      const manifest = JSON.parse(await readFile(f.manifestPath, 'utf8'));
      const batch = await f.ctx.tools.execute({ calls: [{ id: 'after-remove', name: 'ohos_installed_echo',
        arguments: JSON.stringify({ text: 'real post-remove call' }) }], signal: new AbortController().signal });
      const observed = { removed, manifest, batch, fiber: { uid: fiber.uid, state: fiber.state },
        trace: [...namespace.disposalTrace], listed: f.ctx.tools.get('ohos_installed_echo') !== undefined,
        loaderRowPresent: [...f.ctx.loader.entries()].some(row => row.options.id === 'owned-tool'),
        pending: f.manager.installs.size };
      t.diagnostic(JSON.stringify(observed));
      assert.equal(removed.application, 'applied', JSON.stringify(removed));
      const started = events.filter(event => event.reason === 'remove' && event.phase === 'started');
      assert.equal(started.length, 1);
      const settled = events.filter(event => event.id === started[0].id && event.phase === 'settled');
      assert.equal(settled.length, 1);
      assert.equal(settled[0].application, removed.application);
      assert.equal(settled[0].changed, removed.changed);
      assert.deepEqual(observed.trace, ['last-disposer-entered', reject ? 'intentional-rejection' : 'normal-disposer-returned', 'sibling-cleanup-ran']);
      assert.equal(manifest.dependencies?.[name], undefined);
      assert.equal(manifest.dsh.profile.bundles.includes(name), false);
      assert.equal(selectedPackage(f.dir), undefined);
      await assert.rejects(lstat(join(f.dir, '.plugin-manager/ohos/transaction.json')), { code: 'ENOENT' });
      assert.deepEqual(observed.fiber, { uid: null, state: 4 });
      assert.equal(observed.loaderRowPresent, false);
      assert.equal(observed.pending, 0);
      assert.equal(observed.listed, false, 'successful removal must revoke the contribution');
      assert.equal(batch.results[0].result.isError, true, 'the removed tool must not still execute');
      assert.equal(batch.results[0].result.error.info.code, 'UNKNOWN_TOOL');
      const reinstalled = await f.invoke('installBundle', `${name}@2.0.0`, { registry: f.registry, enabled: true });
      assert.equal(reinstalled.application, 'applied', JSON.stringify(reinstalled));
      await executeTool(f.ctx, '2.0.0');
    });
}
