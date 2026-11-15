import { parentPort, workerData } from 'node:worker_threads';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { linkSync } from 'node:fs';

if (workerData.strict) {
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true, 'Worker must inherit the M3-3 preload');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.throws(() => spawnSync(process.execPath, ['--version']), { code: 'ERR_OHOS_SIM_SPAWN' });
  assert.throws(() => linkSync('/dsh-probe-no-source', '/dsh-probe-no-target'), { code: 'EACCES' });
  assert.throws(() => process.dlopen({}, '/dsh-probe-no-addon.node'), { code: 'ERR_OHOS_SIM_DLOPEN' });
}

const binding = process._linkedBinding('dsh_ohos_publication');
parentPort.postMessage({ type: typeof binding.renameNoReplace,
  lockType: typeof binding.lockExclusive,
  markerSetType: typeof binding.setOwnershipMarker,
  markerGetType: typeof binding.getOwnershipMarker,
  version: process.version, wasm: typeof WebAssembly,
  strictConstraintsVerified: workerData.strict,
  marker: globalThis[Symbol.for('dsh.go.ohos.sim')] === true });
