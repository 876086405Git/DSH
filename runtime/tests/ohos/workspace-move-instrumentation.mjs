// Test-only setup and transparent public method observations. No fs/private probe override.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const config = JSON.parse(readFileSync(process.env.OHOS_294_MOVE_CONFIG, 'utf8'));
process.env.DSH_GO_OHOS_SIM_ADDONS = JSON.stringify([
  'libdsh_flock.so', 'libdsh_require_builtin.so', 'libdsh_workspace_grants.so', 'workspace-publisher.node',
].map(name => join(config.nativeDirectory, name)));
await import(pathToFileURL(join(config.source, 'runtime/ohos/sim/preload.mjs')));
export function observeProviderReadMove(LocalFileSystem) {
  const calls = [], restorers = [];
  try {
    for (const method of ['readText', 'moveFile']) {
      const descriptor = Object.getOwnPropertyDescriptor(LocalFileSystem.prototype, method);
      assert.equal(typeof descriptor?.value, 'function');
      const original = descriptor.value;
      const wrapper = function (...args) {
        const record = { method, targetKey: String(args[0].targetKey), displayPath: args[0].displayPath };
        if (method === 'moveFile') {
          record.destinationKey = String(args[1].targetKey); record.destinationPath = args[1].displayPath;
          record.intent = {
            source: args[2].expectedSource === undefined ? { present: false } : { present: true, value: args[2].expectedSource },
            destination: args[2].expectedDestination === undefined ? { present: false } : { present: true, value: args[2].expectedDestination },
          };
          record.hunks = structuredClone(args[2].hunks);
        }
        calls.push(record);
        const returned = Reflect.apply(original, this, args);
        if (method === 'moveFile') returned.then(
          value => { record.outcome = { status: 'fulfilled', value: structuredClone(value) }; },
          error => { record.outcome = { status: 'rejected', error: { name: error.name, code: error.code, message: error.message } }; });
        return returned; // The original Promise is returned unchanged.
      };
      Object.defineProperty(LocalFileSystem.prototype, method, { ...descriptor, value: wrapper });
      restorers.push(() => {
        assert.equal(Object.getOwnPropertyDescriptor(LocalFileSystem.prototype, method)?.value, wrapper);
        Object.defineProperty(LocalFileSystem.prototype, method, descriptor);
      });
    }
  } catch (error) { for (const restore of restorers.reverse()) restore(); throw error; }
  return Object.freeze({ mark: () => calls.length, since: start => calls.slice(start),
    restore() { for (const restore of restorers.reverse()) restore(); } });
}
