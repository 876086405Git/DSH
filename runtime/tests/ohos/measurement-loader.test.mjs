import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const runtime = fileURLToPath(new URL('../../', import.meta.url));
const observer = join(runtime, 'ohos/sim/observe-loader.mjs');
const preload = join(runtime, 'ohos/sim/preload.mjs');
const round = join(runtime, 'ohos/sim/round.mjs');
const prefix = resolve(process.env.DSH_TEST_PREFIX || 'missing-required-DSH_TEST_PREFIX');
const env = { PATH: process.env.PATH, LANG: 'C.UTF-8' };
const execute = (args, extra = {}) => spawnSync(process.execPath, args, {
  encoding: 'utf8', timeout: 20000, maxBuffer: 1024 * 1024, env: { ...env, ...extra },
});
const observations = (result) => result.stderr.split('\n')
  .filter((line) => line.startsWith('[dsh-ohos-loader] '))
  .map((line) => JSON.parse(line.slice('[dsh-ohos-loader] '.length)));

test('measurement observer is inert without its explicit test opt-in', () => {
  const code = `const before = process.dlopen; await import(${JSON.stringify(new URL('../../ohos/sim/observe-loader.mjs', import.meta.url).href)}); if (process.dlopen !== before) throw new Error('unexpected instrumentation');`;
  const result = execute(['--input-type=module', '-e', code]);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(observations(result), []);
});

test('observer reports a successful real native load and its on-disk file hash', () => {
  assert.equal(process.version, 'v24.22.1');
  const fromPrefix = createRequire(join(prefix, 'package.json'));
  const info = fromPrefix('node-addon-require-builtin').getBindingInfo();
  const addon = realpathSync(join(prefix, 'node_modules', info.optionalPackageName, info.optionalBinaryRelativePath));
  const sha256 = createHash('sha256').update(readFileSync(addon)).digest('hex');
  const code = `const {createRequire}=require('node:module'); const r=createRequire(${JSON.stringify(join(prefix, 'package.json'))}); const a=r('node-addon-require-builtin'); if(typeof a.requireBuiltin('internal/modules/helpers').getCjsConditions!=='function') throw new Error('missing real member'); if(typeof WebAssembly!=='undefined') throw new Error('missing O0'); try {require('node:child_process').spawnSync('never-run'); throw new Error('spawn escaped');} catch(e) {if(e.code!=='ERR_OHOS_SIM_SPAWN') throw e;} console.log('native-body-ok');`;
  const result = execute(['--jitless', '--import', preload, '--import', observer, '-e', code], {
    DSH_OHOS_MEASURE_LOADER: '1', NARB_DISABLE_NATIVE_CACHE: '1',
    DSH_GO_OHOS_SIM_ADDONS: JSON.stringify([addon]),
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /native-body-ok/u);
  const rows = observations(result);
  assert.equal(rows[0].kind, 'observer-ready');
  assert.equal(rows[0].noWasm, true);
  assert.equal(rows[0].nativeCacheDisabled, true);
  const native = rows.filter((row) => row.kind === 'native-load');
  assert.equal(native.length, 1);
  assert.equal(native[0].path, addon);
  assert.equal(native[0].sha256, sha256);
  assert.deepEqual(native[0].binding, { product: 'require-builtin', backend: 'napi', abi: 'napi-v9', mode: 'napi' });
});

test('observer cannot turn O0 denied addon loading into successful telemetry', () => {
  const fromPrefix = createRequire(join(prefix, 'package.json'));
  const info = fromPrefix('node-addon-require-builtin').getBindingInfo();
  const addon = realpathSync(join(prefix, 'node_modules', info.optionalPackageName, info.optionalBinaryRelativePath));
  // Exercise the real .node load directly so the upstream package's aggregate
  // "no usable binding" error cannot replace the original O0 error code.
  const code = `require(${JSON.stringify(addon)});`;
  const result = execute(['--jitless', '--import', preload, '--import', observer, '-e', code], {
    DSH_OHOS_MEASURE_LOADER: '1', NARB_DISABLE_NATIVE_CACHE: '1', DSH_GO_OHOS_SIM_ADDONS: '[]',
  });
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /ERR_OHOS_SIM_DLOPEN/u);
  assert.equal(observations(result).filter((row) => row.kind === 'native-load').length, 0);
});

test('allow-addon rejects malformed paths before a case, server or engine is created', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-measure-addon-paths-'));
  const text = join(dir, 'not-an-addon.txt');
  writeFileSync(text, 'only a path validation fixture');
  try {
    const invalid = ['relative.node', join(dir, 'missing.node'), dir, text];
    for (const [index, path] of invalid.entries()) {
      const out = join(dir, `case-${index}`);
      const result = execute([round, '--prefix', prefix, '--out', out, '--mode', 'sim', '--allow-addon', path]);
      assert.equal(result.status, 1, result.stderr);
      assert.equal(existsSync(out), false, `created output for invalid path ${index}`);
      assert.equal(observations(result).length, 0);
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
