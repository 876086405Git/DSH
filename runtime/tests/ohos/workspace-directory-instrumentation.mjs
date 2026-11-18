// Test-only setup and transparent entries: no return/path/grant/error substitution.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const config = JSON.parse(readFileSync(process.env.OHOS_937_DIRECTORY_CONFIG, 'utf8'));
process.env.DSH_GO_OHOS_SIM_ADDONS = JSON.stringify([
  'libdsh_flock.so', 'libdsh_require_builtin.so',
  'libdsh_workspace_grants.so', 'workspace-publisher.node',
].map(name => join(config.nativeDirectory, name)));
await import(pathToFileURL(join(config.source, 'runtime/ohos/sim/preload.mjs')));
export function observeDirectoryCalls(LocalFileSystem, WorkspaceFiles) {
  const calls = [], restorers = [];
  function observe(prototype, layer, method, details) {
    const descriptor = Object.getOwnPropertyDescriptor(prototype, method);
    assert.equal(typeof descriptor?.value, 'function');
    const original = descriptor.value;
    const wrapper = function (...args) {
      calls.push({ layer, method, ...details(args) });
      return Reflect.apply(original, this, args); // Exact original promise/object.
    };
    Object.defineProperty(prototype, method, { ...descriptor, value: wrapper });
    restorers.push(() => {
      assert.equal(Object.getOwnPropertyDescriptor(prototype, method)?.value, wrapper);
      Object.defineProperty(prototype, method, descriptor);
    });
  }
  try {
    for (const method of ['list', 'inspect']) observe(WorkspaceFiles.prototype, 'api', method,
      args => ({ sessionId: args[0].sessionId, workspaceRoot: args[0].workspaceRoot, path: args[1] }));
    observe(WorkspaceFiles.prototype, 'api', 'confine', args => ({ workspaceRoot: args[1], path: args[2] }));
    for (const method of ['resolve', 'lstat']) observe(LocalFileSystem.prototype, 'provider', method,
      args => ({ path: args[0], cwd: args[1]?.cwd ?? null }));
    observe(LocalFileSystem.prototype, 'provider', 'listDir',
      args => ({ targetKey: String(args[0].targetKey), displayPath: args[0].displayPath }));
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
