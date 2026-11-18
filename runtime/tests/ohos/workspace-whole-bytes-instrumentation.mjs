// Test-only OH platform setup and transparent PUBLIC API/provider observation.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const config = JSON.parse(readFileSync(process.env.OHOS_321_WHOLE_BYTES_CONFIG, 'utf8'));
process.env.DSH_GO_OHOS_SIM_ADDONS = JSON.stringify([
  'libdsh_flock.so', 'libdsh_require_builtin.so', 'libdsh_workspace_grants.so', 'workspace-publisher.node',
].map(name => join(config.nativeDirectory, name)));
await import(pathToFileURL(join(config.source, 'runtime/ohos/sim/preload.mjs')));

export function errorValue(error) {
  return { name: error?.name ?? null, code: error?.code ?? null,
    message: error?.message ?? String(error), details: error?.details ?? null,
    isDSHRemoteError: error?.isDSHRemoteError === true,
    cause: error?.cause === undefined ? null : errorValue(error.cause) };
}
export function plainValue(value) {
  if (value instanceof Uint8Array) return Array.from(value);
  if (value === undefined) return { valueIsUndefined: true };
  if (value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map(plainValue);
  return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, plainValue(entry)]));
}
export function observeWholeBytes(LocalFileSystem, WorkspaceFiles) {
  const calls = [], restores = [];
  try {
    for (const [owner, layer, methods] of [
      [WorkspaceFiles, 'api', ['stat', 'readBytes']],
      [LocalFileSystem, 'provider', ['stat', 'readBytes', 'readByteRange']],
    ]) for (const method of methods) {
      const descriptor = Object.getOwnPropertyDescriptor(owner.prototype, method);
      assert.equal(typeof descriptor?.value, 'function');
      const original = descriptor.value;
      const wrapper = function (...args) {
        const input = layer === 'api'
          ? { scope: { sessionId: args[0].sessionId, workspaceRoot: args[0].workspaceRoot }, path: args[1],
              ...(method === 'readBytes' ? { options: plainValue(args[2]), maxFileBytes: this.config.maxFileBytes } : {}) }
          : { target: { displayPath: args[0].displayPath, targetKey: String(args[0].targetKey) },
              ...(method === 'readBytes' ? { maxBytes: args[2] } : {}),
              ...(method === 'readByteRange' ? { range: plainValue(args[1]) } : {}) };
        const row = { layer, method, input };
        calls.push(row);
        let returned;
        try { returned = Reflect.apply(original, this, args); }
        catch (error) { row.outcome = { status: 'threw', error: errorValue(error) }; throw error; }
        row.originalPromiseReturned = true;
        returned.then(value => {
          try { row.outcome = { status: 'fulfilled', value: plainValue(value) }; }
          catch (error) { row.observationError = errorValue(error); }
        }, error => {
          try { row.outcome = { status: 'rejected', error: errorValue(error) }; }
          catch (failure) { row.observationError = errorValue(failure); }
        });
        return returned; // The original Promise, receiver, arguments and result are preserved.
      };
      Object.defineProperty(owner.prototype, method, { ...descriptor, value: wrapper });
      restores.push(() => {
        assert.equal(Object.getOwnPropertyDescriptor(owner.prototype, method)?.value, wrapper);
        Object.defineProperty(owner.prototype, method, descriptor);
      });
    }
  } catch (error) { for (const restore of restores.reverse()) restore(); throw error; }
  return Object.freeze({ mark: () => calls.length, since: mark => calls.slice(mark),
    restore() { for (const restore of restores.reverse()) restore(); } });
}
