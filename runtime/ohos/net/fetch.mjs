import { createHttpDispatcher } from './dispatcher.mjs';

const nodeFetch = globalThis.fetch;

export function createFetch(dispatcher) {
  // Explicit dispatchers carry DNS pins and proxy policy; never discard them.
  return (input, init) => nodeFetch(input, { ...init, dispatcher: init?.dispatcher ?? dispatcher });
}

export function installFetch() {
  if (process.platform !== 'openharmony' && globalThis[Symbol.for('dsh.go.ohos.sim')] !== true) return;
  const key = Symbol.for('dsh.go.ohos.net');
  if (globalThis[key]) return globalThis[key];
  const network = {
    createDispatcher: createHttpDispatcher,
    dispatcher: createHttpDispatcher({ proxyEnv: process.env.NODE_USE_ENV_PROXY === '1' ? process.env : {} }),
    fetch: (input, init) => nodeFetch(input, { ...init, dispatcher: init?.dispatcher ?? network.dispatcher }),
  };
  globalThis[key] = network;
  globalThis.fetch = network.fetch;
  return network;
}
