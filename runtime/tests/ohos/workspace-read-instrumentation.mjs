// Test-only platform/DSO setup and transparent provider-call observations.
// This module adds no product entry point, grants, fallback path or fault mode.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const config = JSON.parse(readFileSync(process.env.OHOS_936_READ_CONFIG, 'utf8'));
process.env.DSH_GO_OHOS_SIM_ADDONS = JSON.stringify([
  'libdsh_flock.so', 'libdsh_require_builtin.so',
  'libdsh_workspace_grants.so', 'workspace-publisher.node',
].map(name => join(config.nativeDirectory, name)));
await import(pathToFileURL(join(config.source, 'runtime/ohos/sim/preload.mjs')));

// Preserve the actual method, receiver, arguments and return value, including
// the production async iterator. No method body or returned bytes are replaced.
export function observeProviderReads(LocalFileSystem) {
  const calls = [], originals = new Map(), wrappers = new Map();
  for (const name of ['readText', 'streamText']) {
    const descriptor = Object.getOwnPropertyDescriptor(LocalFileSystem.prototype, name);
    assert.equal(typeof descriptor?.value, 'function');
    originals.set(name, descriptor);
    const original = descriptor.value;
    const wrapper = function (...args) {
      calls.push({ method: name, targetKey: String(args[0].targetKey),
        displayPath: args[0].displayPath });
      return Reflect.apply(original, this, args);
    };
    wrappers.set(name, wrapper);
    Object.defineProperty(LocalFileSystem.prototype, name, { ...descriptor, value: wrapper });
  }
  return Object.freeze({
    mark: () => calls.length,
    since: start => calls.slice(start),
    restore() {
      for (const [name, descriptor] of originals) {
        assert.equal(Object.getOwnPropertyDescriptor(LocalFileSystem.prototype, name)?.value, wrappers.get(name));
        Object.defineProperty(LocalFileSystem.prototype, name, descriptor);
      }
    },
  });
}
