import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Worker } from 'node:worker_threads';
import { spawnSync } from 'node:child_process';

// The Linux test launcher registers the module before Node initializes. There is
// deliberately no require('.node') fallback: this probe verifies the linked path.
assert.equal(process.version, 'v24.22.1');
const strict = process.argv.includes('--strict');
if (strict) {
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true, 'M3-3 simulation marker is required');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.throws(() => spawnSync(process.execPath, ['--version']), { code: 'ERR_OHOS_SIM_SPAWN' });
  assert.throws(() => fs.linkSync('/dsh-probe-no-source', '/dsh-probe-no-target'), { code: 'EACCES' });
  assert.throws(() => process.dlopen({}, '/dsh-probe-no-addon.node'), { code: 'ERR_OHOS_SIM_DLOPEN' });
}
const binding = process._linkedBinding('dsh_ohos_publication');
assert.deepEqual(Object.keys(binding), ['clearOwnedClone', 'bindPhoneEngine', 'getPhoneSnapshot', 'claimPhonePermit', 'revokePhonePermit', 'completePhonePermit', 'renameNoReplace', 'lockExclusive', 'setOwnershipMarker', 'getOwnershipMarker', 'getSystemBuildIdentity', 'getHostLifecycleSnapshot']);
assert.equal(process._linkedBinding('dsh_ohos_publication'), binding);
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-linked-publication-'));
try {
  const temporary = path.join(directory, '临时-😀');
  const destination = path.join(directory, '最终-中');
  fs.writeFileSync(temporary, 'complete');
  assert.equal(binding.renameNoReplace(temporary, destination), undefined);
  assert.equal(fs.readFileSync(destination, 'utf8'), 'complete');
  assert.equal(fs.existsSync(temporary), false);
  fs.writeFileSync(temporary, 'competitor');
  assert.throws(() => binding.renameNoReplace(temporary, destination), {
    code: 'EEXIST', syscall: 'renameat2', errno: -17,
  });
  assert.equal(fs.readFileSync(destination, 'utf8'), 'complete');
  assert.equal(fs.readFileSync(temporary, 'utf8'), 'competitor');
  const worker = new Worker(new URL('./publication-linked-worker.mjs', import.meta.url), {
    workerData: { strict },
  });
  const workerResult = await new Promise((resolve, reject) => {
    let result;
    worker.on('message', value => { result = value; });
    worker.on('error', reject);
    worker.on('exit', code => code === 0 && result
      ? resolve(result) : reject(new Error(`worker exited ${code}`)));
  });
  assert.equal(workerResult.type, 'function');
  assert.equal(workerResult.lockType, 'function');
  assert.equal(workerResult.markerSetType, 'function');
  assert.equal(workerResult.markerGetType, 'function');
  assert.equal(workerResult.version, process.version);
  assert.equal(workerResult.wasm, typeof WebAssembly);
  assert.equal(workerResult.marker, globalThis[Symbol.for('dsh.go.ohos.sim')] === true);
  assert.equal(workerResult.strictConstraintsVerified, strict);
  console.log(JSON.stringify({ status: 'PASS_SCOPED', version: process.version,
    platform: process.platform, wasm: typeof WebAssembly,
    strictConstraintsVerified: strict,
    linkedInMainAndWorker: true, nativeNoReplace: true,
    filesystemType: fs.statfsSync(directory).type, worker: workerResult,
    scope: 'Linux fixture only; no OHOS loader, ABI, seccomp or target filesystem claim' }));
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
