import { parentPort } from 'node:worker_threads';

const network = globalThis[Symbol.for('dsh.go.ohos.net')];
parentPort.postMessage({
  body: await (await fetch(process.env.OHOS_BOOTSTRAP_TEST_URL)).text(),
  installed: !!network,
  hasDshApi: !!network?.globalDispatcherApi,
  simulated: globalThis[Symbol.for('dsh.go.ohos.sim')] === true,
  workerEntry: process.argv[1].endsWith('net-bootstrap-worker.mjs'),
});
parentPort.close();
