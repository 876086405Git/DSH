// Transparent PUBLIC provider observations and existing OH test-platform setup only.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
const config = JSON.parse(readFileSync(process.env.OHOS_WHOLE_WRITE_CONFIG, 'utf8'));
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
    cause: error?.cause === undefined ? null : errorValue(error.cause),
    ...(error?.workspaceWholeEffect !== undefined ? { workspaceWholeEffect: error.workspaceWholeEffect } : {}),
    ...(error?.workspaceEditState !== undefined ? { workspaceEditState: error.workspaceEditState } : {}),
    ...(error?.workspaceEditCleanupFailed !== undefined ? { workspaceEditCleanupFailed: error.workspaceEditCleanupFailed } : {}),
    ...(Array.isArray(error?.errors) ? { errors: error.errors.map(errorValue) } : {}) };
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

// A transparent observation of the real new Native group, installed before
// the sole production preload captures the five methods. No fabricated result.
const require = createRequire(join(config.payload, 'package.json'));
const native = require('@dsh-go/ohos-native').load('workspace-grants').binding;
const wholeMethods = ['beginWholeOutput', 'writeWholeOutput', 'closeWholeOutput', 'stepWholeOutput', 'abortWholeOutput'];
const nativeCalls = [], nativeRestores = [], leaseIds = new Map();
function nativeInput(method, args) {
  if (!leaseIds.has(args[0])) leaseIds.set(args[0], leaseIds.size + 1);
  const input = { leaseId: leaseIds.get(args[0]) }; // opaque ordinal, never a host FD
  if (method === 'beginWholeOutput') Object.assign(input, { relative: args[1], policy: args[2], priorMode: args[3], createIfAbsent: args[4] });
  if (method === 'writeWholeOutput') Object.assign(input, { bytes: args[1].length, hex: args[1].toString('hex') });
  return input;
}
try {
  for (const method of wholeMethods) {
    const descriptor = Object.getOwnPropertyDescriptor(native, method);
    assert.equal(typeof descriptor?.value, 'function', 'new WHOLE_WRITE_V1 method missing: ' + method);
    const original = descriptor.value;
    const wrapper = function (...args) {
      const row = { method, input: nativeInput(method, args) }; nativeCalls.push(row);
      let value;
      try { value = Reflect.apply(original, this, args); }
      catch (error) { row.outcome = { status: 'threw', error: errorValue(error) }; throw error; }
      row.outcome = { status: 'returned', value: plain(value) };
      return value; // original result object/receiver/arguments, no return-value stub
    };
    Object.defineProperty(native, method, { ...descriptor, value: wrapper });
    nativeRestores.push(() => { assert.equal(native[method], wrapper); Object.defineProperty(native, method, descriptor); });
  }
} catch (error) { for (const restore of nativeRestores.reverse()) restore(); throw error; }
export const wholeObserver = Object.freeze({
  mark: () => nativeCalls.length,
  since: start => nativeCalls.slice(start),
  all: () => nativeCalls.slice(),
  restore() { for (const restore of nativeRestores.reverse()) restore(); leaseIds.clear(); },
});
