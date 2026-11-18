// Test-only observer exits before the real DSH bin executes; not a full App turn.
import assert from 'node:assert/strict';
import { isMainThread, Worker } from 'node:worker_threads';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
if (isMainThread) {
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
  const service = globalThis[Symbol.for('dsh.go.ohos.publication')];
  assert.equal(service.protocolVersion, 1);
  assert(globalThis[Symbol.for('dsh.go.ohos.net')]);
  assert.equal(await readFile(process.env.DSH_M6_BOOTSTRAP_SENTINEL, 'utf8'), 'modern-bootstrap-ran\n');
  const from = join(process.env.DSH_HOME, 'source'), to = join(process.env.DSH_HOME, 'published');
  await writeFile(from, 'M6 ordered publication');
  const published = await service.publish(from, to);
  assert.equal(published.method, 'rename-noreplace');
  assert.equal(await readFile(to, 'utf8'), 'M6 ordered publication');
  assert.equal(service.pendingCount, 0);
  const worker = new Worker(new URL('./worker.mjs', import.meta.url), { workerData: { scenario: 'publication' } });
  const exit = new Promise((resolve, reject) => {
    worker.once('error', reject);
    worker.once('exit', (code) => code === 0 ? resolve() : reject(new Error(`worker exit ${code}`)));
  });
  const result = await new Promise((resolve, reject) => { worker.once('message', resolve); worker.once('error', reject); });
  await exit;
  assert.equal(result.publicationServiceInWorker, false);
  assert.equal(result.sim, true); assert.equal(result.wasmAbsent, true);
  console.log(JSON.stringify({ scenario: process.env.DSH_M6_TEST_REGISTER === 'modern' ? 'single-import-dynamic-candidate' : 'modern-bootstrap-before-wrapper',
    instrumentation: true, fullDSHMainExecuted: false, published, worker: result }));
  process.exit(0);
}
