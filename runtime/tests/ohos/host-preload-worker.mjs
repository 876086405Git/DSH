import assert from 'node:assert/strict';
import { parentPort, workerData } from 'node:worker_threads';
import { spawnSync } from 'node:child_process';
import { linkSync } from 'node:fs';
const network = globalThis[Symbol.for('dsh.go.ohos.net')];
const { linuxHostPaths } = await import('../../ohos/linux/host-paths.mjs');
assert.equal(linuxHostPaths(), undefined, 'Workers cannot inherit Linux owner paths');
assert.ok(network);
assert.equal(network.globalDispatcherApi, undefined);
assert.equal(globalThis[Symbol.for('dsh.go.ohos.publication')], undefined);
assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
if (workerData.strict) {
  assert.equal(typeof WebAssembly, 'undefined');
  assert.throws(() => spawnSync('/not-a-real-command'), { code: 'ERR_OHOS_NO_SPAWN' });
  assert.throws(() => linkSync('/missing-source', '/missing-target'), { code: 'EACCES' });
  assert.throws(() => process.dlopen({ exports: {} }, '/missing-addon.node'), { code: 'ERR_OHOS_SIM_DLOPEN' });
}
const body = await (await fetch(workerData.url)).text();
await network.dispatcher.destroy();
parentPort.postMessage({ body, network: true, publication: false, simulated: true, linuxOwnerPaths: false });
