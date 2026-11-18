// Calls the installed DSH methods. A context tripwire proves refusal precedes
// profile access/control allocation, without replacing any global builtins.
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
const accessed = new Error('context was touched before refusal');
const blockedContext = new Proxy({}, { get() { throw accessed; }, set() { throw accessed; } });
const matches = message => /\[OHOS_PLUGIN_INSTALL_UNAVAILABLE\].*随包插件.*连接电脑/.test(message);
function checkWireSchema(method, result) {
  const descriptor = TYPERT.invocations.find(item => item.method === method);
  assert.deepEqual(descriptor.result.create().parse(JSON.parse(JSON.stringify(result))), result);
}
async function check(name, run) {
  try { await run(); rows.push({ name, passed: true }); }
  catch (error) { rows.push({ name, passed: false, error: { name: error.name, message: error.message, code: error.code } }); }
}
if (mode === 'ohos') {
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  for (const options of [undefined, { enabled: false }, { enabled: true, requestId: 'local-fixture', approvedBuilds: ['fixture'] }]) {
    await check('install structured failure ' + JSON.stringify(options), async () => {
      const result = await PluginManager.prototype.installBundle.call(blockedContext, 'fixture@1', options);
      assert.equal(result.application, 'failed');
      assert.equal(result.changed, false);
      assert.equal(result.stage, 'install');
      assert.equal(result.target, 'fixture@1');
      assert.equal(result.enabled, options?.enabled !== false);
      assert.equal(result.error.code, 'operation-error');
      assert(matches(result.error.diagnostic));
      assert.equal(result.packageResult, undefined);
      checkWireSchema('installBundle', result);
      // This is a resolved existing ChangeResult, so the real client's
      // settleInstall branch is 'failed', not the transport-error 'unconfirmed'.
      assert.deepEqual(JSON.parse(JSON.stringify(result)), result);
    });
  }
  for (const name of ['fixture-installed', '@fixture/installed', 'fixture-missing']) {
    await check('remove refuses before deselection ' + name, async () => {
      const result = await PluginManager.prototype.removeBundle.call(blockedContext, name);
      assert.equal(result.application, 'failed');
      assert.equal(result.changed, false);
      assert.equal(result.stage, 'remove');
      assert.equal(result.target, name);
      assert.equal(result.error.code, 'operation-error');
      assert(matches(result.error.diagnostic));
      assert.equal(result.packageResult, undefined);
      checkWireSchema('removeBundle', result);
    });
  }
  await check('inspection refuses before disk/network access', async () => {
    const result = await PluginManager.prototype.inspect.call(blockedContext, 'fixture@1', {}, new AbortController().signal);
    assert.equal(result.status, 'refused'); assert.equal(result.problem, 'unknown'); assert(matches(result.reason));
    checkWireSchema('inspect', result);
  });
  await check('registry dialog reads configured values without invoking pnpm', async () => {
    const configuredRegistries = { registry: null, fallbackRegistries: ['https://registry.npmjs.org'] };
    const context = new Proxy({}, { get(_target, key) { if (key === 'configuredRegistries') return configuredRegistries; throw accessed; } });
    const result = await PluginManager.prototype.registries.call(context);
    assert.equal(result.resolved, null);
    assert.deepEqual(result.fallbackRegistries, configuredRegistries.fallbackRegistries);
    assert.notEqual(result.fallbackRegistries, configuredRegistries.fallbackRegistries);
    checkWireSchema('registries', result);
  });
  for (const name of ['runPluginCommand', 'runProfilePnpm']) {
    await check(name + ' refuses before creating profile or lock', async () => {
      await assert.rejects(operations[name](blockedContext, ['add', 'fixture@1'], {}),
        error => error.code === 'ERR_OHOS_PLUGIN_INSTALL_UNAVAILABLE' && matches(error.message));
    });
  }
} else {
  assert.equal(mode, 'native'); assert.equal(process.platform, 'linux');
  for (const name of ['installBundle', 'removeBundle', 'inspect', 'registries']) {
    await check(name + ' keeps existing non-OH path', async () => {
      await assert.rejects(async () => PluginManager.prototype[name].call(blockedContext, 'fixture@1', {}), error => error === accessed);
    });
  }
  for (const name of ['runPluginCommand', 'runProfilePnpm']) {
    await check(name + ' keeps existing non-OH path', async () => {
      await assert.rejects(operations[name](blockedContext, ['add', 'fixture@1'], {}), error => error === accessed);
    });
  }
}
await writeFile(process.argv[3], JSON.stringify({ scope: 'actual fixed DSH exported methods, no global mocks; Linux, not Ark/device', mode, rows }, null, 2) + '\n');
console.log(JSON.stringify({ mode, passed: rows.filter(row => row.passed).length, total: rows.length }));
if (rows.some(row => !row.passed)) process.exitCode = 1;
