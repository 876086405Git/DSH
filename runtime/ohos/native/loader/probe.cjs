'use strict';

const { createRequire } = require('node:module');
const { resolve } = require('node:path');

const NODE_VERSION = 'v24.22.1';
const MODULES = Object.freeze([
  'internal/modules/esm/loader',
  'internal/modules/cjs/loader',
  'internal/modules/helpers',
  'internal/modules/esm/utils',
  'internal/modules/esm/resolve',
]);

function fail(message) {
  throw Object.assign(new Error(`OHOS native loader startup check failed: ${message}`),
    { code: 'ERR_OHOS_NATIVE_LOADER_CHECK' });
}

function checkNativeLoader(prefix) {
  if (process.version !== NODE_VERSION) fail(`requires ${NODE_VERSION}, got ${process.version}`);
  if (process.platform !== 'openharmony') fail('requires the OpenHarmony host or explicit O0 platform simulation');
  // Node/V8 accept underscores as flag-name aliases. A strict O0 preload also
  // removes WebAssembly, so its absence alone cannot prove the engine mode.
  const flags = process.execArgv.map(arg => ({ raw: arg,
    name: arg.split('=', 1)[0].replace(/^-+/, '--').replaceAll('_', '-') }));
  if (flags.some(({ name }) => name === '--expose-internals'))
    fail('native route must run without --expose-internals');
  if (!flags.some(({ raw }) => raw === '--jitless')) fail('host must pass explicit --jitless');
  if (flags.some(({ raw, name }) => name === '--no-jitless' || name === '--nojitless' ||
      (name === '--jitless' && raw !== '--jitless')))
    fail('host must not disable or ambiguously override --jitless');
  if (typeof WebAssembly !== 'undefined') fail('requires the jitless host without WebAssembly');
  for (const id of MODULES) {
    if (process.getBuiltinModule(id) !== undefined) fail(`internal module is publicly exposed: ${id}`);
  }
  if (process.env.NARB_DISABLE_NATIVE_CACHE !== '1') fail('host must disable native cache before requiring the addon');
  if (typeof prefix !== 'string' || !prefix) fail('DSH installation prefix is required');
  const fromPrefix = createRequire(resolve(prefix, 'package.json'));
  const addon = fromPrefix('node-addon-require-builtin');
  const binding = addon.getBindingInfo();
  if (binding.product !== 'require-builtin' || binding.backend !== 'napi' || binding.abi !== 'napi-v9')
    fail('wrong native product/backend/ABI');
  const values = Object.fromEntries(MODULES.map(id => {
    const value = addon.requireBuiltin(id);
    if (!value || typeof value !== 'object') fail(`module is unavailable: ${id}`);
    return [id, value];
  }));
  const esmModule = values[MODULES[0]];
  if (typeof esmModule.getOrInitializeCascadedLoader !== 'function') fail('missing getOrInitializeCascadedLoader');
  const esm = esmModule.getOrInitializeCascadedLoader();
  const members = {
    getOrInitializeCascadedLoader: typeof esmModule.getOrInitializeCascadedLoader,
    resolveSync: typeof esm?.resolveSync,
    getOrCreateModuleJob: typeof esm?.getOrCreateModuleJob,
    _resolveFilename: typeof values[MODULES[1]].Module?._resolveFilename,
    _nodeModulePaths: typeof values[MODULES[1]].Module?._nodeModulePaths,
    getCjsConditions: typeof values[MODULES[2]].getCjsConditions,
    getDefaultConditions: typeof values[MODULES[3]].getDefaultConditions,
    defaultResolve: typeof values[MODULES[4]].defaultResolve,
  };
  for (const [name, type] of Object.entries(members)) if (type !== 'function') fail(`missing member: ${name}`);
  return { status: 'NATIVE_MEMBERS_AVAILABLE', node: process.version, platform: process.platform,
    arch: process.arch, explicitJitless: true, publicInternalsExposed: false,
    noWasm: typeof WebAssembly === 'undefined', binding, members };
}

module.exports = { checkNativeLoader, MODULES, NODE_VERSION };
if (require.main === module) {
  try { process.stdout.write(JSON.stringify(checkNativeLoader(process.argv[2]), null, 2) + '\n'); }
  catch (error) { process.stderr.write(`${error.code ?? 'ERR_OHOS_NATIVE_LOADER_CHECK'}: ${error.message}\n`); process.exitCode = 1; }
}
