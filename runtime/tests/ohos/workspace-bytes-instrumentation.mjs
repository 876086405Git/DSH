// Test-only platform setup and transparent public-method observation.
// Exact original arguments, receiver and return value/promise are preserved.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const config = JSON.parse(readFileSync(process.env.OHOS_939_BYTES_CONFIG, 'utf8'));
process.env.DSH_GO_OHOS_SIM_ADDONS = JSON.stringify([
  'libdsh_flock.so', 'libdsh_require_builtin.so',
  'libdsh_workspace_grants.so', 'workspace-publisher.node',
].map(name => join(config.nativeDirectory, name)));
await import(pathToFileURL(join(config.source, 'runtime/ohos/sim/preload.mjs')));

const errorInfo = error => ({ name: error?.name ?? null, code: error?.code ?? null,
  message: error?.message ?? String(error), stack: error?.stack ?? null });
function valueEvidence(value) {
  if (value === undefined) return { kind: 'undefined' };
  if (value instanceof Uint8Array) return { kind: 'bytes', isBuffer: Buffer.isBuffer(value),
    byteLength: value.byteLength, hex: Buffer.from(value).toString('hex'), data: Array.from(value) };
  // Complete JSON representation of these ordinary public return objects.
  // API byte JSON retains Buffer's type/data or Uint8Array indices; the actor
  // separately checks the actual Uint8Array before any serialization.
  return { kind: value === null ? 'null' : typeof value,
    value: JSON.parse(JSON.stringify(value)) };
}
export function observeBytesCalls(LocalFileSystem, WorkspaceFiles) {
  const calls = [], restorers = [];
  let sequence = 0;
  function observe(prototype, layer, method, details) {
    const descriptor = Object.getOwnPropertyDescriptor(prototype, method);
    assert.equal(typeof descriptor?.value, 'function');
    const original = descriptor.value;
    const wrapper = function (...args) {
      const call = { layer, method, ...details(args), entryOrder: ++sequence,
        outcome: 'pending', returned: false, rejected: false };
      calls.push(call);
      const settle = (outcome, value) => {
        // Observation never changes the original fulfillment/rejection.
        try {
          call.outcome = outcome;
          call.settleOrder = ++sequence;
          call.returned = outcome === 'fulfilled';
          call.rejected = outcome !== 'fulfilled';
          if (outcome === 'fulfilled') call.returnValue = valueEvidence(value);
          else call.error = errorInfo(value);
        } catch (error) { call.observationError = errorInfo(error); }
      };
      let returned;
      try { returned = Reflect.apply(original, this, args); }
      catch (error) { settle('threw', error); throw error; }
      if (returned instanceof Promise) {
        // Return the original Promise, not the observation child. Both handlers
        // catch their own evidence errors and never throw or replace a value.
        returned.then(value => settle('fulfilled', value), error => settle('rejected', error));
      } else settle('fulfilled', returned);
      return returned;
    };
    Object.defineProperty(prototype, method, { ...descriptor, value: wrapper });
    restorers.push(() => {
      assert.equal(Object.getOwnPropertyDescriptor(prototype, method)?.value, wrapper);
      Object.defineProperty(prototype, method, descriptor);
    });
  }
  try {
    for (const method of ['stat', 'inspect', 'locateFile']) {
      observe(WorkspaceFiles.prototype, 'api', method, args => ({
        sessionId: args[0].sessionId, workspaceRoot: args[0].workspaceRoot, path: args[1] }));
    }
    observe(WorkspaceFiles.prototype, 'api', 'readBytes', args => ({
      sessionId: args[0].sessionId, workspaceRoot: args[0].workspaceRoot, path: args[1],
      options: JSON.parse(JSON.stringify(args[2])) }));
    for (const method of ['resolve', 'lstat']) observe(LocalFileSystem.prototype, 'provider', method,
      args => ({ path: args[0], cwd: args[1]?.cwd ?? null }));
    for (const method of ['stat', 'readBytes']) observe(LocalFileSystem.prototype, 'provider', method,
      args => ({ targetKey: String(args[0].targetKey), displayPath: args[0].displayPath }));
    observe(LocalFileSystem.prototype, 'provider', 'readByteRange', args => ({
      targetKey: String(args[0].targetKey), displayPath: args[0].displayPath,
      range: { offset: args[1].offset, length: args[1].length } }));
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
