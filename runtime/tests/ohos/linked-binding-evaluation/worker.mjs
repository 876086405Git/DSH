import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { Worker, parentPort, workerData } from 'node:worker_threads';

const missing = (name) => {
  try { process._linkedBinding(name); return false; }
  catch (error) { assert.equal(error.code, 'ERR_INVALID_MODULE'); return true; }
};
const finish = (value) => { parentPort.postMessage(value); parentPort.close(); };

if (workerData.scenario === 'read') {
  const binding = process._linkedBinding(workerData.name);
  finish({ registration: binding.registration, serial: binding.initializationSerial,
    wasmAbsent: typeof WebAssembly === 'undefined', sim: globalThis[Symbol.for('dsh.go.ohos.sim')] === true });
} else if (workerData.scenario === 'missing') {
  finish({ missing: missing(workerData.name) });
} else if (workerData.scenario === 'late') {
  assert.equal(missing('dsh_m6_late'), true);
  parentPort.once('message', () => {
    const binding = process._linkedBinding('dsh_m6_late');
    finish({ after: binding.registration, serial: binding.initializationSerial });
  });
  parentPort.postMessage({ before: 'missing' });
} else if (workerData.scenario === 'local') {
  const bootstrap = createRequire(import.meta.url)(workerData.addon);
  bootstrap.registerModern('dsh_m6_worker');
  const local = process._linkedBinding('dsh_m6_worker');
  const nested = new Worker(new URL(import.meta.url), {
    workerData: { scenario: 'read', name: 'dsh_m6_worker' },
  });
  const exit = new Promise((resolve, reject) => {
    nested.once('error', reject);
    nested.once('exit', (code) => code === 0 ? resolve(code) : reject(new Error(`nested exit ${code}`)));
  });
  const reply = await new Promise((resolve, reject) => {
    nested.once('message', resolve); nested.once('error', reject);
  });
  await exit;
  parentPort.once('message', () => finish({ complete: true }));
  parentPort.postMessage({ local: local.registration, serial: local.initializationSerial, nested: reply });
} else if (workerData.scenario === 'publication') {
  const binding = process._linkedBinding('dsh_ohos_publication');
  const members = ['renameNoReplace', 'lockExclusive', 'setOwnershipMarker', 'getOwnershipMarker'];
  assert(members.every((name) => typeof binding[name] === 'function'));
  finish({ members, publicationServiceInWorker: Object.hasOwn(globalThis, Symbol.for('dsh.go.ohos.publication')),
    sim: globalThis[Symbol.for('dsh.go.ohos.sim')] === true, wasmAbsent: typeof WebAssembly === 'undefined' });
} else {
  throw new Error('Unknown fixed worker experiment');
}
