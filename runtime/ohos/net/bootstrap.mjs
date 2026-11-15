import { readFileSync, realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve, sep } from 'node:path';
import { installFetch } from './fetch.mjs';

const failure = (code, message) => Object.assign(new Error(message), { code });
const readManifest = path => JSON.parse(readFileSync(path, 'utf8'));

function hasDispatcherApi(exports) {
  if (exports === null || !['object', 'function'].includes(typeof exports)) return false;
  return typeof Object.getOwnPropertyDescriptor(exports, 'getGlobalDispatcher')?.value === 'function'
    && typeof Object.getOwnPropertyDescriptor(exports, 'setGlobalDispatcher')?.value === 'function';
}

// Dedicated DSH startup seam. Independent transport factories do not change globals.
export function bootstrapDshNetwork(entry) {
  if (process.platform !== 'openharmony' && globalThis[Symbol.for('dsh.go.ohos.sim')] !== true) return;
  let require, binary, undiciPath, undiciRoot;
  try {
    if (typeof entry !== 'string' || entry.length === 0) throw new Error('missing DSH binary');
    binary = realpathSync(resolve(entry));
    require = createRequire(binary);
    const packagePath = require.resolve('@deepseek-ai/dsh/package.json');
    const dsh = readManifest(packagePath);
    if (dsh.name !== '@deepseek-ai/dsh' || dsh.version !== '0.2.2-rc.1'
      || typeof dsh.bin?.dsh !== 'string' || realpathSync(join(dirname(packagePath), dsh.bin.dsh)) !== binary) {
      throw new Error('unexpected DSH entry');
    }
    undiciPath = require.resolve('undici');
    const manifestPath = require.resolve('undici/package.json');
    const undici = readManifest(manifestPath);
    if (undici.name !== 'undici' || undici.version !== '8.11.2') throw new Error('unexpected Undici version');
    undiciRoot = dirname(manifestPath);
  } catch {
    throw failure('ERR_OHOS_NET_DSH_ENTRY', 'OHOS network bootstrap requires the locked DSH 0.2.2-rc.1 entry with Undici 8.11.2');
  }

  const existing = globalThis[Symbol.for('dsh.go.ohos.net')];
  if (existing?.globalDispatcherApi) {
    if (existing.globalDispatcherApi.module !== undiciPath || existing.globalDispatcherApi.entry !== binary) {
      throw failure('ERR_OHOS_NET_DSH_ENTRY', 'OHOS network bootstrap was initialized for another DSH entry');
    }
    return existing; // A later explicit custom dispatcher must remain untouched.
  }
  const loaded = Object.entries(require.cache).some(([path, module]) =>
    (path.startsWith(undiciRoot + sep) && path !== join(undiciRoot, 'package.json'))
    || hasDispatcherApi(module.exports));
  if (loaded) {
    throw failure('ERR_OHOS_NET_BOOTSTRAP_ORDER', 'OHOS DSH network preload must run before the first Undici/global-dispatcher API import');
  }
  const network = installFetch();
  const { getGlobalDispatcher, setGlobalDispatcher } = require('undici');
  setGlobalDispatcher(network.dispatcher);
  Object.defineProperty(network, 'globalDispatcherApi', { value: Object.freeze({
    getGlobalDispatcher, setGlobalDispatcher, module: undiciPath, entry: binary,
    baseDispatcher: network.dispatcher,
  }) });
  return network;
}
