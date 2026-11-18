import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const guard = new URL('../../ohos/process/child-process.mjs', import.meta.url).href;
const setup = `
  import assert from 'node:assert/strict';
  import * as esm from 'node:child_process';
  import { createRequire } from 'node:module';
  const cjs = createRequire(import.meta.url)('node:child_process');
  const names = ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork'];
  const original = Object.fromEntries(names.map(name => [name, cjs[name]]));
  const originalPrototype = cjs.ChildProcess.prototype.spawn;
  const guard = process.argv[1];
`;

// These isolated Linux children test the platform branch and builtin aliases.
// The product's real Host/sole-preload test separately covers startup ordering.
function run(body) {
  const result = spawnSync(process.execPath, ['--input-type=module', '--eval', setup + body, guard], {
    encoding: 'utf8', timeout: 10000, env: { ...process.env, NODE_OPTIONS: '' },
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null, result.stderr);
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

for (const platform of ['linux', 'android']) {
  test(`${platform}: simulator flags do not replace child_process builtins`, () => {
    const result = run(`
      Object.defineProperty(process, 'platform', { value: ${JSON.stringify(platform)} });
      globalThis[Symbol.for('dsh.go.ohos.sim')] = true;
      process.env.DSH_GO_OHOS_SIM = '1';
      await import(guard);
      for (const name of names) {
        assert.equal(cjs[name], original[name]);
        assert.equal(esm[name], original[name]);
        assert.equal(process.getBuiltinModule('child_process')[name], original[name]);
      }
      assert.equal(cjs.ChildProcess.prototype.spawn, originalPrototype);
      console.log(JSON.stringify({ unchanged: names.length, platform: process.platform }));
    `);
    assert.deepEqual(result, { unchanged: 7, platform });
  });
}

test('OHOS: CJS, ESM and getBuiltinModule reject every public spawn entry without exposing arguments', () => {
  const result = run(`
    Object.defineProperty(process, 'platform', { value: 'openharmony' });
    await import(guard);
    const marker = 'private-command-argument-environment-sentinel';
    let callbackCalled = false;
    const denied = error => {
      assert.equal(error.code, 'ERR_OHOS_NO_SPAWN');
      assert.match(error.message, /ERR_OHOS_NO_SPAWN/);
      assert.match(error.message, /OpenHarmony/);
      assert.equal(error.message.includes(marker), false);
      return true;
    };
    let calls = 0;
    for (const api of [cjs, esm, process.getBuiltinModule('node:child_process')]) {
      for (const name of names) {
        assert.equal(api[name], cjs[name]);
        assert.notEqual(api[name], original[name]);
        assert.throws(() => api[name](marker, [marker], { env: { PRIVATE_MARKER: marker } },
          () => { callbackCalled = true; }), denied);
        calls++;
      }
      assert.throws(() => api.ChildProcess.prototype.spawn.call({}, { file: marker }), denied);
      calls++;
    }
    assert.equal(callbackCalled, false);
    console.log(JSON.stringify({ calls, callbackCalled }));
  `);
  assert.deepEqual(result, { calls: 24, callbackCalled: false });
});

test('OHOS: a previously captured asynchronous spawn still reaches the prototype boundary', () => {
  const result = run(`
    Object.defineProperty(process, 'platform', { value: 'openharmony' });
    await import(guard);
    assert.throws(() => original.spawn('must-not-execute', []), { code: 'ERR_OHOS_NO_SPAWN' });
    console.log(JSON.stringify({ denied: true }));
  `);
  assert.deepEqual(result, { denied: true });
});

test('OHOS: credential-provider promisify wrappers retain the explicit error code', () => {
  const result = run(`
    const { promisify } = await import('node:util');
    const capturedExec = promisify(original.exec);
    const capturedExecFile = promisify(original.execFile);
    Object.defineProperty(process, 'platform', { value: 'openharmony' });
    await import(guard);
    for (const invoke of [
      () => promisify(cjs.exec)('must-not-execute'),
      () => promisify(cjs.execFile)('must-not-execute', []),
    ]) await assert.rejects(invoke, { code: 'ERR_OHOS_NO_SPAWN' });
    // Node's previously captured custom wrappers call the original function
    // before returning their Promise; a spawn-boundary throw remains synchronous.
    for (const invoke of [
      () => capturedExec('must-not-execute'),
      () => capturedExecFile('must-not-execute', []),
    ]) assert.throws(invoke, { code: 'ERR_OHOS_NO_SPAWN' });
    console.log(JSON.stringify({ rejectedPromises: 2, synchronousCapturedFailures: 2 }));
  `);
  assert.deepEqual(result, { rejectedPromises: 2, synchronousCapturedFailures: 2 });
});

test('OHOS: installing the boundary still permits a Worker thread and its own boundary', () => {
  const result = run(`
    const { Worker } = await import('node:worker_threads');
    const { once } = await import('node:events');
    Object.defineProperty(process, 'platform', { value: 'openharmony' });
    await import(guard);
    const worker = new Worker(new URL('data:text/javascript,' + encodeURIComponent(
      "import { parentPort, workerData } from 'node:worker_threads';" +
      "import cp from 'node:child_process';" +
      "Object.defineProperty(process, 'platform', { value: 'openharmony' });" +
      "await import(workerData);" +
      "try { cp.spawn('must-not-execute'); parentPort.postMessage('unexpected-success'); }" +
      "catch (error) { parentPort.postMessage(error.code); }"
    )), { workerData: guard, execArgv: [] });
    const exited = once(worker, 'exit');
    const [code] = await once(worker, 'message');
    const [exitCode] = await exited;
    assert.equal(code, 'ERR_OHOS_NO_SPAWN');
    assert.equal(exitCode, 0);
    console.log(JSON.stringify({ code, exitCode }));
  `);
  assert.deepEqual(result, { code: 'ERR_OHOS_NO_SPAWN', exitCode: 0 });
});
