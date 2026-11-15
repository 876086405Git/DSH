import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const preload = fileURLToPath(new URL('../../ohos/sim/preload.mjs', import.meta.url));
const marker = fileURLToPath(new URL('../../ohos/sim/marker.mjs', import.meta.url));
function run(code, overrides = {}, mode = 'strict') {
  const env = { ...process.env };
  for (const key of ['DSH_GO_OHOS_SIM', 'DSH_GO_OHOS_SIM_PLATFORM', 'DSH_GO_OHOS_SIM_ADDONS']) delete env[key];
  Object.assign(env, overrides);
  const flags = mode === 'strict' ? ['--jitless', '--import', preload] : mode === 'marker' ? ['--import', marker] : [];
  return spawnSync(process.execPath, [...flags, '--input-type=module', '-e', code], {
    env, encoding: 'utf8', timeout: 15000,
  });
}
function result(child) {
  assert.equal(child.error, undefined);
  assert.equal(child.status, 0, child.stderr);
  return JSON.parse(child.stdout);
}

test('the obsolete environment switch alone leaves ordinary Node unchanged', () => {
  const value = result(run(`import { spawnSync } from 'node:child_process';
    console.log(JSON.stringify({ wasm: typeof WebAssembly, platform: process.platform,
      simulated: globalThis[Symbol.for('dsh.go.ohos.sim')] === true,
      status: spawnSync(process.execPath, ['-e', '']).status }));`, { DSH_GO_OHOS_SIM: '1' }, 'none'));
  assert.deepEqual(value, { wasm: 'object', platform: process.platform, simulated: false, status: 0 });
});

test('the explicit marker preload preserves JIT and ordinary Node abilities', () => {
  const value = result(run(`import { spawnSync } from 'node:child_process';
    console.log(JSON.stringify({ wasm: typeof WebAssembly, platform: process.platform,
      simulated: globalThis[Symbol.for('dsh.go.ohos.sim')] === true,
      jitless: process.execArgv.includes('--jitless'),
      legacyEnv: Object.hasOwn(process.env, 'DSH_GO_OHOS_SIM'),
      status: spawnSync(process.execPath, ['-e', '']).status }));`, {}, 'marker'));
  assert.deepEqual(value, { wasm: 'object', platform: process.platform, simulated: true, jitless: false, legacyEnv: false, status: 0 });
});

test('a real worker recreates the explicit marker from inherited preloads without environment activation', () => {
  const value = result(run(`import { Worker } from 'node:worker_threads';
    const worker = new Worker(new URL('data:text/javascript,' + encodeURIComponent(
      "import { parentPort } from 'node:worker_threads'; parentPort.postMessage({simulated:globalThis[Symbol.for('dsh.go.ohos.sim')]===true,wasm:typeof WebAssembly,jitless:process.execArgv.includes('--jitless'),legacyEnv:Object.hasOwn(process.env,'DSH_GO_OHOS_SIM')});"
    )));
    const value = await new Promise((resolve, reject) => { worker.once('message',resolve); worker.once('error',reject); });
    await worker.terminate(); console.log(JSON.stringify(value));`, {}, 'marker'));
  assert.deepEqual(value, { simulated: true, wasm: 'object', jitless: false, legacyEnv: false });
});

test('all public child_process execution entrances fail synchronously and record stack only', () => {
  const child = run(`import cp from 'node:child_process';
    import { spawnSync } from 'node:child_process';
    const rows = [];
    for (const name of ['spawn','spawnSync','exec','execSync','execFile','execFileSync','fork']) {
      try { cp[name]('private-command-never-log', ['private-argument']); }
      catch (e) { rows.push([name, e.code]); }
    }
    try { new cp.ChildProcess().spawn({ file: 'private-command-never-log', args: [] }); }
    catch (e) { rows.push(['prototype', e.code]); }
    try { spawnSync('private-command-never-log'); }
    catch (e) { rows.push(['esm', e.code]); }
    console.log(JSON.stringify(rows));`);
  const rows = result(child);
  assert.equal(rows.length, 9);
  assert.ok(rows.every((row) => row[1] === 'ERR_OHOS_SIM_SPAWN'));
  const logs = child.stderr.split('\n').filter((line) => line.startsWith('[ohos-sim] '));
  assert.equal(logs.length, 9);
  assert.ok(logs.every((line) => JSON.parse(line.slice(11)).stack.includes('at ')));
  assert.doesNotMatch(logs.join('\n'), /private-command-never-log|private-argument/);
});

test('callback, promise, named ESM and synchronous links fail without altering source', () => {
  const value = result(run(`import fs from 'node:fs';
    import { link } from 'node:fs/promises';
    import { tmpdir } from 'node:os';
    import { join } from 'node:path';
    const dir = fs.mkdtempSync(join(tmpdir(), 'ohos-sim-link-'));
    const src = join(dir, '中文源'); const dst = join(dir, '目标');
    fs.writeFileSync(src, 'retained'); const codes = [];
    try {
      codes.push(await new Promise((resolve) => fs.link(src, dst, (e) => resolve(e.code))));
      for (const fn of [() => fs.promises.link(src, dst), () => link(src, dst), () => fs.linkSync(src, dst)]) {
        try { await fn(); } catch (e) { codes.push(e.code); }
      }
      console.log(JSON.stringify({ codes, source: fs.readFileSync(src, 'utf8'), target: fs.existsSync(dst) }));
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }`));
  assert.deepEqual(value, { codes: ['EACCES', 'EACCES', 'EACCES', 'EACCES'], source: 'retained', target: false });
});

test('jitless removes wasm and platform override is explicit', () => {
  const code = `console.log(JSON.stringify({ wasm: typeof WebAssembly, platform: process.platform, jitless: process.execArgv.includes('--jitless') }));`;
  assert.deepEqual(result(run(code)), { wasm: 'undefined', platform: process.platform, jitless: true });
  assert.deepEqual(result(run(code, { DSH_GO_OHOS_SIM_PLATFORM: 'openharmony' })), {
    wasm: 'undefined', platform: 'openharmony', jitless: true,
  });
});

test('dlopen denies before touching native code; named file does not grant a basename match', () => {
  const child = run(`let code; try { process.dlopen({ exports: {} }, '/not-present/same-name.node'); }
    catch (e) { code = e.code; } console.log(JSON.stringify(code));`);
  assert.equal(result(child), 'ERR_OHOS_SIM_DLOPEN');
  assert.match(child.stderr, /"category":"dlopen"/);
});

test('invalid whitelist rejects startup rather than weakening the constraint', () => {
  const child = run(`console.log('should not run')`, { DSH_GO_OHOS_SIM_ADDONS: '["relative.node"]' });
  assert.notEqual(child.status, 0);
  assert.equal(child.stdout, '');
  assert.match(child.stderr, /absolute addon paths/);
});

test('an exact whitelisted addon reaches the real loader', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ohos-addon-'));
  const addon = join(dir, '中文.node');
  writeFileSync(addon, 'not an ELF library');
  try {
    const child = run(`let code; try { process.dlopen({ exports: {} }, ${JSON.stringify(addon)}); }
      catch (e) { code = e.code; } console.log(JSON.stringify(code));`, {
      DSH_GO_OHOS_SIM_ADDONS: JSON.stringify([addon]),
    });
    assert.equal(result(child), 'ERR_DLOPEN_FAILED');
    assert.doesNotMatch(child.stderr, /\[ohos-sim\]/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('ordinary worker inherits preload and the process restriction', () => {
  const child = run(`import { Worker } from 'node:worker_threads';
    const worker = new Worker(new URL('data:text/javascript,' + encodeURIComponent(
      "import { parentPort } from 'node:worker_threads'; import { spawnSync } from 'node:child_process'; let code; try { spawnSync('FAKE_SECRET_ARG_6f3d'); } catch (e) { code=e.code; console.error(e); } parentPort.postMessage({wasm:typeof WebAssembly,code,simulated:globalThis[Symbol.for('dsh.go.ohos.sim')]===true,legacyEnv:Object.hasOwn(process.env,'DSH_GO_OHOS_SIM')});"
    )));
    const value = await new Promise((resolve, reject) => { worker.once('message',resolve); worker.once('error',reject); });
    await worker.terminate(); console.log(JSON.stringify(value));`);
  const value = result(child);
  assert.deepEqual(value, { wasm: 'undefined', code: 'ERR_OHOS_SIM_SPAWN', simulated: true, legacyEnv: false });
  assert.doesNotMatch(child.stderr, /FAKE_SECRET_ARG_6f3d|data:text\/javascript|parentPort/);
  assert.match(child.stderr, /<dynamic source>/);
});
