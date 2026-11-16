// Transparent PUBLIC provider observations and existing OH test-platform setup only.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const config = JSON.parse(readFileSync(process.env.OHOS_WHOLE_WRITE_EXISTING_CONFIG, 'utf8'));
process.env.DSH_GO_OHOS_SIM_ADDONS = JSON.stringify([
  'libdsh_flock.so', 'libdsh_require_builtin.so', 'libdsh_workspace_grants.so', 'workspace-publisher.node',
].map(name => join(config.nativeDirectory, name)));
await import(pathToFileURL(join(config.source, 'runtime/ohos/sim/preload.mjs')));
export function plain(value) {
  if (value === undefined) return { valueIsUndefined: true };
  if (value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map(plain);
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, plain(item)]));
}
export function errorValue(error) {
  return { name: error?.name ?? null, code: error?.code ?? null, message: error?.message ?? String(error),
    cause: error?.cause === undefined ? null : errorValue(error.cause) };
}
export function observeWrite(LocalFileSystem, SandboxedFileSystem) {
  const calls = [], restorers = [];
  try {
    for (const [owner, layer, methods] of [[SandboxedFileSystem, 'sandbox', ['writeText']],
      [LocalFileSystem, 'local', ['readText', 'writeText']]]) for (const method of methods) {
      const descriptor = Object.getOwnPropertyDescriptor(owner.prototype, method);
      assert.equal(typeof descriptor?.value, 'function'); const original = descriptor.value;
      const wrapper = function (...args) {
        const input = { target: { displayPath: args[0].displayPath, targetKey: String(args[0].targetKey) } };
        if (method === 'writeText') {
          input.content = args[1]; input.intent = args[2] === undefined ? { present: false } : { present: true, value: plain(args[2]) };
          if (layer === 'sandbox') input.policy = plain(args[4]);
        }
        const row = { layer, method, input }; calls.push(row);
        let returned;
        try { returned = Reflect.apply(original, this, args); }
        catch (error) { row.outcome = { status: 'threw', error: errorValue(error) }; throw error; }
        row.originalPromiseReturned = true;
        returned.then(value => { try { row.outcome = { status: 'fulfilled', value: plain(value) }; }
          catch (error) { row.observationError = errorValue(error); } },
          error => { try { row.outcome = { status: 'rejected', error: errorValue(error) }; }
            catch (failure) { row.observationError = errorValue(failure); } });
        return returned; // Preserve original receiver, arguments, Promise, body and result.
      };
      Object.defineProperty(owner.prototype, method, { ...descriptor, value: wrapper });
      restorers.push(() => { assert.equal(Object.getOwnPropertyDescriptor(owner.prototype, method)?.value, wrapper);
        Object.defineProperty(owner.prototype, method, descriptor); });
    }
  } catch (error) { for (const restore of restorers.reverse()) restore(); throw error; }
  return Object.freeze({ mark: () => calls.length, since: n => calls.slice(n),
    restore() { for (const restore of restorers.reverse()) restore(); } });
}
