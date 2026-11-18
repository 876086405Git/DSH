import test from 'node:test';
import assert from 'node:assert/strict';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { fixture } from './plugin-package-harness.mjs';
const { runtimeCapabilities } = await import(pathToFileURL(resolve(process.env.DSH_PLUGIN_CAPABILITIES_MODULE)));
const key = Symbol.for('dsh.go.ohos.plugins');

if (process.platform === 'openharmony') {
test('capability GET reports live OH package management without invoking it or writing profile files', async t => {
  const f = await fixture(t);
  const backend = globalThis[key];
  assert(backend, 'the real backend factory must be installed by the fixture');
  assert(f.ctx.get('pluginManager'), 'real boot owns the manager service');
  const before = await f.snapshot(true);
  // Preserve the actual backend as target; any backend method read is a GET-side-effect tripwire.
  globalThis[key] = new Proxy(backend, { get() { throw new Error('capability GET must not call the backend'); } });
  try {
    const capabilities = runtimeCapabilities(f.ctx, 'owned-capabilities');
    f.facts.capabilities = capabilities.plugins;
    assert.equal(capabilities.plugins.marketInstall, 'supported', 'a live supported installer must not be hidden by the UI capability');
  } finally { globalThis[key] = backend; }
  assert.deepEqual(await f.snapshot(true), before);
  assert.deepEqual(f.facts.requests, []);
});

test('without registered backend the real OH manager still reports unsupported and GET is read-only', async t => {
  const f = await fixture(t), before = await f.snapshot(true), backend = globalThis[key];
  delete globalThis[key];
  try { assert.equal(runtimeCapabilities(f.ctx, 'owned-no-backend').plugins.marketInstall, 'unsupported'); }
  finally { globalThis[key] = backend; }
  assert.deepEqual(await f.snapshot(true), before);
  assert.deepEqual(f.facts.requests, []);
});


test('registered backend without a real manager stays unsupported on an empty Cordis context', async t => {
  const f = await fixture(t), backend = globalThis[key], before = await f.snapshot(true);
  const { Context } = await import(pathToFileURL(join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai/cordis/lib/index.js')));
  const empty = new Context();
  globalThis[key] = new Proxy(backend, { get() { throw new Error('capability GET must not read backend methods'); } });
  try {
    assert.equal(empty.get('pluginManager'), undefined);
    assert.equal(runtimeCapabilities(empty, 'owned-no-manager').plugins.marketInstall, 'unsupported');
  } finally { globalThis[key] = backend; await empty.fiber.dispose(); }
  assert.deepEqual(await f.snapshot(true), before); assert.deepEqual(f.facts.requests, []);
});
} else {
  test('native platform does not claim OH installer support even with a real backend and manager', async t => {
    const f = await fixture(t, {}, { requireOhos: false }), before = await f.snapshot(true);
    assert(f.ctx.get('pluginManager')); assert(globalThis[key]);
    assert.equal(runtimeCapabilities(f.ctx, 'owned-native-context').plugins.marketInstall, 'unsupported');
    assert.deepEqual(await f.snapshot(true), before); assert.deepEqual(f.facts.requests, []);
  });
}
