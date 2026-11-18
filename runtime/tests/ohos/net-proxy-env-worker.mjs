import { parentPort, workerData } from 'node:worker_threads';
import { once } from 'node:events';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';

const { installFetch, createFetch } = await import(pathToFileURL(join(workerData.netRoot, 'fetch.mjs')));
const { createHttpDispatcher } = await import(pathToFileURL(join(workerData.netRoot, 'dispatcher.mjs')));
let dispatcher, lookupCalls = 0, outcome;
try {
  let fetch;
  if (workerData.explicit) {
    dispatcher = createHttpDispatcher({
      proxyEnv: workerData.proxyEnv, ca: workerData.ca,
      lookup: workerData.lookup ? (_host, options, callback) => {
        lookupCalls++;
        if (workerData.lookup === 'deny') return callback(new Error('origin DNS must stay at the proxy'));
        callback(null, options.all ? [{ address: '127.0.0.1', family: 4 }] : '127.0.0.1', 4);
      } : undefined,
    });
    if (workerData.mutateProxyAfterCreation) workerData.proxyEnv.HTTP_PROXY = 'http://127.0.0.1:1';
    fetch = createFetch(dispatcher);
  } else {
    const network = installFetch();
    if (!network) throw new Error('explicit simulation preload was not inherited');
    dispatcher = network.dispatcher;
    fetch = network.fetch;
  }
  const bodies = [];
  for (const url of workerData.urls) bodies.push(await (await fetch(url, { signal: AbortSignal.timeout(3000) })).text());
  await dispatcher.close();
  outcome = { bodies, lookupCalls, simulated: globalThis[Symbol.for('dsh.go.ohos.sim')] === true };
} catch (error) {
  outcome = { error: { name: error.name, code: error.code, message: error.message, cause: error.cause?.code }, lookupCalls };
} finally { await dispatcher?.destroy(); }
parentPort.postMessage(outcome);
// Keep this isolate alive until the parent has observed transport socket closure.
await once(parentPort, 'message');
parentPort.close();
