// This observer is a test-only import after the product wrapper. It verifies
// pre-entry state using the actual DSH bin for package resolution, then exits;
// it does not claim to have run a complete DSH application round.
import assert from 'node:assert/strict';
import { isMainThread, Worker } from 'node:worker_threads';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
if (isMainThread) {
  const config = JSON.parse(process.env.OHOS_STARTUP_CASE);
  const network = globalThis[Symbol.for('dsh.go.ohos.net')];
  const publication = globalThis[Symbol.for('dsh.go.ohos.publication')];
  const initial = globalThis.__ohosStartupSnapshot;
  if (config.name === 'android-env') {
    assert.equal(network, undefined); assert.equal(publication, undefined);
    assert.equal(globalThis.fetch, initial.fetch);
    assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], undefined);
    console.log(JSON.stringify({ androidGuardOnly: true, network: false, publication: false, fetchSame: true }));
    process.exit(0);
  }
  assert.ok(network?.globalDispatcherApi);
  assert.equal(publication.protocolVersion, 1);
  for (const name of ['Request', 'Response', 'Headers', 'FormData']) assert.equal(globalThis[name], initial[name]);
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
  if (config.strict) assert.equal(typeof WebAssembly, 'undefined');
  const source = join(process.env.DSH_HOME, 'fixture-source');
  const target = join(process.env.DSH_HOME, 'fixture-final');
  await writeFile(source, '完整发布');
  const published = await publication.publish(source, target);
  assert.equal(await readFile(target, 'utf8'), '完整发布');
  assert.equal(published.method, config.strict ? 'rename-noreplace' : 'link');
  const server = createServer((_request, response) => response.end('startup-ready'));
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const url = `http://127.0.0.1:${server.address().port}/`;
  let worker;
  try {
    const body = await (await fetch(url)).text(); assert.equal(body, 'startup-ready');
    worker = new Worker(new URL('./host-preload-worker.mjs', import.meta.url), { workerData: { url, strict: config.strict } });
    const message = once(worker, 'message'); const ended = once(worker, 'exit');
    const [value] = await message; const [exit] = await ended; assert.equal(exit, 0);
    assert.deepEqual(value, { body: 'startup-ready', network: true, publication: false, simulated: true });
    console.log(JSON.stringify({ beforeDshEntry: true, body, publishMethod: published.method,
      publication: true, worker: value, constructorsSame: true, strict: config.strict }));
  } finally {
    if (worker) await worker.terminate();
    await network.dispatcher.destroy();
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
  }
  process.exit(0);
}
