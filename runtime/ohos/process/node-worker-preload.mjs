import { workerData } from 'node:worker_threads';
import { Readable } from 'node:stream';
import { registerHooks } from 'node:module';
import { pathToFileURL } from 'node:url';
import { installNodeWorkerPaths } from './node-worker-paths.mjs';

// The host still has one --import. Its inherited Worker branch runs before
// Node's native CJS/ESM entry loader; ordinary Workers get no path/stdin changes here.
if (workerData?.dshOhosNodeScript?.protocol === 1) {
  const config = workerData.dshOhosNodeScript;
  if (!(config.stdin instanceof Uint8Array)) throw new TypeError('Node script batch input must be bytes');
  // Worker stdin's message acknowledgements otherwise keep an unread batch
  // alive. This private finite stream has no application-level fd or handle.
  if (!config.streamStdin) Object.defineProperty(process, 'stdin', {
    value: Readable.from([Buffer.from(config.stdin)], { objectMode: false }), configurable: true, enumerable: true });
  installNodeWorkerPaths(config);
  if (config.inline !== undefined) {
    // A file base gives inline ESM normal neighboring-resource URLs. The private
    // query identity must not shadow a real [eval].mjs or [stdin].mjs file.
    const { randomUUID } = await import('node:crypto');
    const inlineURL = pathToFileURL(config.inline.base + '.mjs');
    inlineURL.searchParams.set('dsh-ohos-inline', randomUUID());
    const identity = inlineURL.href;
    registerHooks({
      resolve(specifier, context, nextResolve) {
        if (specifier === 'dsh-ohos-inline:source') return { url: identity, shortCircuit: true };
        return nextResolve(specifier, context);
      },
      load(url, context, nextLoad) {
        if (url === identity) return { format: 'module', source: config.inline.source, shortCircuit: true };
        return nextLoad(url, context);
      },
    });
  }
}
Object.defineProperty(globalThis, Symbol.for('dsh.go.ohos.nodeWorker.preload'), { value: 1 });
