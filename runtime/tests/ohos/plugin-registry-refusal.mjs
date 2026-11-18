// Actual rc.1 public methods; fixture boundaries are installed inventory and
// an I/O tripwire. No pnpm/network/registry implementation is substituted.
import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const require = createRequire(join(resolve(process.argv[2]), 'package.json'));
const mode = process.argv[4];
const load = name => import(pathToFileURL(require.resolve(name)));
const { PluginManager } = await load('@deepseek-ai/dsh-plugin-manager');
const operations = await load('@deepseek-ai/dsh-plugin-manager/operations');
const { TYPERT } = await load('@deepseek-ai/dsh-plugin-manager/typert');
const rows = [];
const accessed = new Error('profile or operation options touched before refusal');
const blockedOptions = new Proxy({}, { get() { throw accessed; } });
const matches = message => /\[OHOS_PLUGIN_INSTALL_UNAVAILABLE\].*随包插件.*连接电脑/.test(message);
function wire(method, result) {
  const descriptor = TYPERT.invocations.find(item => item.method === method);
  assert(descriptor, `missing public wire method ${method}`);
  assert.deepEqual(descriptor.result.create().parse(JSON.parse(JSON.stringify(result))), result);
}
function fixture() {
  const events = [];
  let inventoryReads = 0;
  const manager = Object.create(PluginManager.prototype);
  Object.assign(manager, {
    configuredRegistries: { registry: null, fallbackRegistries: ['https://registry.npmjs.org'] },
    installedFrom: new Map(),
    // Snapshot of an installed third-party registry bundle, before registry I/O.
    listBundles: async () => {
      inventoryReads++;
      return [{ name: 'fixture-plugin', installed: true, availability: 'profile', official: false,
        source: 'fixture-plugin@1.0.0', version: '1.0.0', enabled: true }];
    },
    ownerContext: { emit: (...args) => events.push(args) },
  });
  Object.defineProperty(manager, 'profile', { get() { throw accessed; } });
  return { manager, events, inventoryReads: () => inventoryReads };
}
async function check(name, run) {
  try { await run(); rows.push({ name, passed: true }); }
  catch (error) { rows.push({ name, passed: false, error: { name: error.name, message: error.message, code: error.code } }); }
}
assert.equal(mode === 'ohos' || mode === 'native', true);
assert.equal(process.platform, mode === 'ohos' ? 'openharmony' : 'linux');
if (mode === 'ohos') {
  await check('listVersions resolves wire refusal before pnpm query', async () => {
    const f = fixture();
    const result = await f.manager.listVersions('fixture-plugin', {}, new AbortController().signal);
    assert.equal(f.inventoryReads(), 1);
    assert.equal(result.status, 'refused'); assert.equal(result.problem, 'unknown');
    assert(matches(result.reason)); assert.deepEqual(result.attempts, []);
    wire('listVersions', result);
  });
  await check('updateBundle refuses during check without install/remove/restore', async () => {
    const f = fixture();
    const result = await f.manager.updateBundle('fixture-plugin', '1.1.0', { requestId: 'registry-fixture' });
    assert.equal(f.inventoryReads(), 1);
    assert.equal(result.from, '1.0.0'); assert.equal(result.to, '1.1.0'); assert.equal(result.step, 'check');
    assert.deepEqual(f.events, [['plugin-manager/update-state', { requestId: 'registry-fixture', step: 'checking' }]]);
    assert.equal(result.result.changed, false); assert.equal(result.result.application, 'failed');
    assert.equal(result.result.stage, 'install'); assert.equal(result.result.target, 'fixture-plugin');
    assert.equal(result.result.error.code, 'operation-error'); assert(matches(result.result.error.diagnostic));
    assert.equal(result.restore, undefined); assert.equal(result.result.packageResult, undefined);
    wire('updateBundle', result);
  });
} else {
  for (const method of ['listVersions', 'updateBundle']) await check(method + ' preserves non-OH registry path', async () => {
    const f = fixture();
    await assert.rejects(() => method === 'listVersions'
      ? f.manager.listVersions('fixture-plugin', {}, new AbortController().signal)
      : f.manager.updateBundle('fixture-plugin', '1.1.0', {}), error => error === accessed);
    assert.equal(f.inventoryReads(), 1);
  });
}
for (const method of ['readProfileRegistry', 'viewProfilePackage']) await check(method + ' exported operation boundary', async () => {
  const invoke = () => method === 'readProfileRegistry'
    ? operations.readProfileRegistry('/fixture/not-accessed', blockedOptions)
    : operations.viewProfilePackage('/fixture/not-accessed', 'fixture-plugin', blockedOptions);
  await assert.rejects(invoke, error => mode === 'ohos'
    ? error.code === 'ERR_OHOS_PLUGIN_INSTALL_UNAVAILABLE' && matches(error.message)
    : error === accessed);
});
await writeFile(process.argv[3], JSON.stringify({ scope: 'actual rc.1 public methods and wire parser; no pnpm/network; Linux, not Ark/device', mode, rows }, null, 2) + '\n');
console.log(JSON.stringify({ mode, passed: rows.filter(row => row.passed).length, total: rows.length }));
if (rows.some(row => !row.passed)) process.exitCode = 1;
