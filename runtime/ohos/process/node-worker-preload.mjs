import { workerData } from 'node:worker_threads';
import { Readable } from 'node:stream';
import { installNodeWorkerPaths } from './node-worker-paths.mjs';

// The host still has one --import. Its inherited Worker branch runs before
// Node's native CJS/ESM entry loader; ordinary Workers get no path/stdin changes here.
if (workerData?.dshOhosNodeScript?.protocol === 1) {
  const config = workerData.dshOhosNodeScript;
  if (!(config.stdin instanceof Uint8Array)) throw new TypeError('Node script batch input must be bytes');
  // Worker stdin's message acknowledgements otherwise keep an unread batch
  // alive. This private finite stream has no application-level fd or handle.
  Object.defineProperty(process, 'stdin', { value: Readable.from([Buffer.from(config.stdin)], { objectMode: false }),
    configurable: true, enumerable: true });
  installNodeWorkerPaths(config);
}
Object.defineProperty(globalThis, Symbol.for('dsh.go.ohos.nodeWorker.preload'), { value: 1 });
