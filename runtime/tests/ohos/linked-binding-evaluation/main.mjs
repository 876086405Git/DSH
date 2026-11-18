import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { Worker } from 'node:worker_threads';
import { mkdtemp, open, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';

const scenario = process.argv[2];
const addon = process.env.DSH_M6_TEST_ADDON;
const bootstrap = createRequire(import.meta.url)(addon);
const missing = (name) => {
  try { process._linkedBinding(name); return false; }
  catch (error) { assert.equal(error.code, 'ERR_INVALID_MODULE'); return true; }
};
function startWorker(data) {
  const worker = new Worker(new URL('./worker.mjs', import.meta.url), { workerData: { addon, ...data } });
  const exited = new Promise((resolve, reject) => {
    worker.once('error', reject);
    worker.once('exit', (code) => code === 0 ? resolve(code) : reject(new Error(`worker exit ${code}`)));
  });
  const next = () => new Promise((resolve, reject) => {
    worker.once('message', resolve); worker.once('error', reject);
  });
  return { worker, exited, next };
}
let detail;
if (scenario === 'main') {
  assert.equal(missing('dsh_m6_main'), true);
  bootstrap.registerModern('dsh_m6_main');
  const binding = process._linkedBinding('dsh_m6_main');
  assert.equal(binding.registration, 'public-AddLinkedBinding');
  assert.equal(typeof binding.initializationSerial, 'number');
  detail = { before: 'missing', after: binding.registration, serial: binding.initializationSerial };
} else if (scenario === 'inherit') {
  bootstrap.registerModern('dsh_m6_main');
  const main = process._linkedBinding('dsh_m6_main');
  const child = startWorker({ scenario: 'read', name: 'dsh_m6_main' });
  const result = await child.next(); await child.exited;
  assert.equal(result.registration, main.registration);
  assert.notEqual(result.serial, main.initializationSerial);
  detail = { mainSerial: main.initializationSerial, worker: result,
    workerLoadedBootstrapAddon: false };
} else if (scenario === 'late-parent') {
  const child = startWorker({ scenario: 'late' });
  assert.deepEqual(await child.next(), { before: 'missing' });
  bootstrap.registerModern('dsh_m6_late');
  const result = child.next(); child.worker.postMessage('retry');
  detail = await result; await child.exited;
  assert.equal(detail.after, 'public-AddLinkedBinding');
} else if (scenario === 'worker-local') {
  assert.equal(missing('dsh_m6_worker'), true);
  const child = startWorker({ scenario: 'local' });
  detail = await child.next();
  assert.equal(missing('dsh_m6_worker'), true);
  detail.mainMissingWhileWorkerAlive = true;
  const done = child.next(); child.worker.postMessage('finish');
  assert.deepEqual(await done, { complete: true }); await child.exited;
  assert.equal(detail.local, 'public-AddLinkedBinding');
  assert.equal(detail.nested.registration, 'public-AddLinkedBinding');
  assert.notEqual(detail.serial, detail.nested.serial);
  assert.equal(missing('dsh_m6_worker'), true);
  detail.mainStillMissing = true;
} else if (scenario === 'legacy-late') {
  assert.equal(missing('dsh_m6_legacy_late'), true);
  bootstrap.registerLegacyLate();
  assert.equal(missing('dsh_m6_legacy_late'), true);
  const child = startWorker({ scenario: 'missing', name: 'dsh_m6_legacy_late' });
  const result = await child.next(); await child.exited;
  assert.equal(result.missing, true);
  detail = { kLinkedPassed: true, mainAfter: 'missing', worker: result };
} else if (scenario === 'publication') {
  assert.equal(missing('dsh_ohos_publication'), true);
  bootstrap.registerModern('dsh_ohos_publication');
  const binding = process._linkedBinding('dsh_ohos_publication');
  const root = await mkdtemp(join(tmpdir(), 'dsh-m6-binding-'));
  let handle;
  try {
    handle = await open(join(root, 'owned'), 'wx', 0o600);
    binding.lockExclusive(handle.fd);
    assert.equal(binding.getOwnershipMarker(handle.fd), undefined);
    const token = randomUUID(); binding.setOwnershipMarker(handle.fd, token);
    assert.equal(binding.getOwnershipMarker(handle.fd), token);
    await handle.close(); handle = undefined;
    const from = join(root, 'from'), to = join(root, 'to');
    await writeFile(from, 'M6 linked callback payload');
    binding.renameNoReplace(from, to);
    assert.equal(await readFile(to, 'utf8'), 'M6 linked callback payload');
    const child = startWorker({ scenario: 'publication' });
    const result = await child.next(); await child.exited;
    detail = { fourOriginalCallbacksExecuted: true, worker: result,
      registration: 'public-AddLinkedBinding; exact reviewed Initialize' };
  } finally { if (handle) await handle.close(); await rm(root, { recursive: true, force: true }); }
} else {
  throw new Error('Unknown fixed main experiment');
}
console.log(JSON.stringify({ scenario, platform: process.platform,
  sim: globalThis[Symbol.for('dsh.go.ohos.sim')] === true,
  wasmAbsent: typeof WebAssembly === 'undefined', detail }));
