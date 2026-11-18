// Ordinary controlled cancellation: real Native writes and original public Promises.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { setImmediate, clearImmediate } from 'node:timers';
const config = JSON.parse(readFileSync(process.env.OHOS_WRITE_CANCEL_CONFIG, 'utf8'));
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
export function bytesIdentity(bytes) {
  return { bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
}
let armed;
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
          input.content = bytesIdentity(Buffer.from(args[1], 'utf8'));
          input.intent = args[2] === undefined ? { present: false } : { present: true, value: plain(args[2]) };
          input.signalAtEntry = { aborted: args[3].aborted, originalCaller: args[3] === armed?.signal };
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
        return returned;
      };
      Object.defineProperty(owner.prototype, method, { ...descriptor, value: wrapper });
      restorers.push(() => { assert.equal(Object.getOwnPropertyDescriptor(owner.prototype, method)?.value, wrapper);
        Object.defineProperty(owner.prototype, method, descriptor); });
    }
  } catch (error) { for (const restore of restorers.reverse()) restore(); throw error; }
  return Object.freeze({ mark: () => calls.length, since: n => calls.slice(n),
    restore() { for (const restore of restorers.reverse()) restore(); } });
}

const require = createRequire(join(config.payload, 'package.json'));
const native = require('@dsh-go/ohos-native').load('workspace-grants').binding;
const methods = ['beginWholeOutput', 'writeWholeOutput', 'closeWholeOutput', 'stepWholeOutput', 'abortWholeOutput'];
const calls = [], restorers = [], leaseIds = new Map();
function nativeInput(method, args) {
  if (!leaseIds.has(args[0])) leaseIds.set(args[0], leaseIds.size + 1);
  const input = { leaseId: leaseIds.get(args[0]) }; // opaque ordinal; no FD or ticket exposed
  if (method === 'beginWholeOutput') Object.assign(input, { relative: args[1], policy: args[2], priorMode: args[3], createIfAbsent: args[4] });
  if (method === 'writeWholeOutput') input.content = bytesIdentity(args[1]);
  return input;
}
try {
  for (const method of methods) {
    const descriptor = Object.getOwnPropertyDescriptor(native, method);
    assert.equal(typeof descriptor?.value, 'function', 'WHOLE_WRITE_V1 method missing: ' + method);
    const original = descriptor.value;
    const wrapper = function (...args) {
      const row = { method, input: nativeInput(method, args) }; calls.push(row);
      let value;
      try { value = Reflect.apply(original, this, args); }
      catch (error) { row.outcome = { status: 'threw', error: errorValue(error) }; throw error; }
      row.outcome = { status: 'returned', value: plain(value) };
      // Only after the real first successful write returns, enqueue one ordinary
      // cancellation request. Never replace the original result or native call.
      if (method === 'writeWholeOutput' && armed && !armed.scheduled && Number.isInteger(value) && value > 0) {
        const state = armed;
        state.scheduled = true;
        state.trace.scheduled = true;
        state.trace.trigger = { leaseId: row.input.leaseId, requested: row.input.content, returnedBytes: value,
          nativeMethodsAfterReturn: calls.slice(state.mark).map(item => item.method) };
        state.immediate = setImmediate(() => {
          state.immediate = undefined;
          state.trace.fired = true;
          state.trace.nativeMethodsAtCallback = calls.slice(state.mark).map(item => item.method);
          try { state.callback(state.trace.trigger); }
          catch (error) { state.trace.observationError = errorValue(error); }
        });
      }
      return value;
    };
    Object.defineProperty(native, method, { ...descriptor, value: wrapper });
    restorers.push(() => { assert.equal(native[method], wrapper); Object.defineProperty(native, method, descriptor); });
  }
} catch (error) { for (const restore of restorers.reverse()) restore(); throw error; }
export const wholeObserver = Object.freeze({
  mark: () => calls.length, since: mark => calls.slice(mark), all: () => calls.slice(),
  arm(signal, callback) {
    assert.equal(armed, undefined); assert.equal(signal.aborted, false); assert.equal(typeof callback, 'function');
    const trace = { scheduled: false, fired: false };
    armed = { signal, callback, mark: calls.length, trace, scheduled: false, immediate: undefined };
    return trace;
  },
  disarm() { if (armed?.immediate !== undefined) clearImmediate(armed.immediate); armed = undefined; },
  restore() {
    if (armed?.immediate !== undefined) clearImmediate(armed.immediate);
    armed = undefined;
    for (const restore of restorers.reverse()) restore();
    leaseIds.clear();
  },
});
