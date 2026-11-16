// Test-only platform setup and transparent public provider observations.
// No private probe, Node fs, method return, grant, path or intent is replaced.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const config = JSON.parse(readFileSync(process.env.OHOS_278_EDIT_CONFIG, 'utf8'));
process.env.DSH_GO_OHOS_SIM_ADDONS = JSON.stringify([
  'libdsh_flock.so', 'libdsh_require_builtin.so',
  'libdsh_workspace_grants.so', 'workspace-publisher.node',
].map(name => join(config.nativeDirectory, name)));
await import(pathToFileURL(join(config.source, 'runtime/ohos/sim/preload.mjs')));

export function observeProviderReadPatch(LocalFileSystem) {
  const calls = [], restorers = [];
  try {
    for (const method of ['readText', 'patchText']) {
      const descriptor = Object.getOwnPropertyDescriptor(LocalFileSystem.prototype, method);
      assert.equal(typeof descriptor?.value, 'function');
      const original = descriptor.value;
      const wrapper = function (...args) {
        const record = { method, targetKey: String(args[0].targetKey), displayPath: args[0].displayPath };
        if (method === 'patchText') {
          record.hunks = args[1];
          record.intent = args[2] === undefined ? { present: false } : {
            present: true, kind: args[2]?.kind ?? null, version: args[2]?.version ?? null,
          };
        }
        calls.push(record);
        return Reflect.apply(original, this, args); // Exact original return, including Promise identity.
      };
      Object.defineProperty(LocalFileSystem.prototype, method, { ...descriptor, value: wrapper });
      restorers.push(() => {
        assert.equal(Object.getOwnPropertyDescriptor(LocalFileSystem.prototype, method)?.value, wrapper);
        Object.defineProperty(LocalFileSystem.prototype, method, descriptor);
      });
    }
  } catch (error) {
    for (const restore of restorers.reverse()) restore();
    throw error;
  }
  return Object.freeze({
    mark: () => calls.length,
    since: start => calls.slice(start),
    restore() { for (const restore of restorers.reverse()) restore(); },
  });
}
