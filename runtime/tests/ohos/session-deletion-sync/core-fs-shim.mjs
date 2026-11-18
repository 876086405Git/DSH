// This module is selected only for the one deletion core import by the test hook.
// Node builtins, other importers, and product source are never modified.
import * as fs from 'node:fs/promises';
export * from 'node:fs/promises';
let observe = () => {};
export function setObserver(value) { observe = value; }
export async function open(path, ...args) {
  const handle = await fs.open(path, ...args);
  if (args[0] !== 'r') return handle;
  return new Proxy(handle, { get(target, name) {
    if (name === 'sync') return async () => {
      await observe('sync-before', path);
      await target.sync();
      await observe('sync-done', path);
    };
    const value = Reflect.get(target, name, target);
    return typeof value === 'function' ? value.bind(target) : value;
  } });
}
export async function rm(path, options) {
  await observe('rm', path);
  return fs.rm(path, options);
}
// The old core's earlier OH link failure is already an actual Host observation.
// For this isolated retry comparison both inputs receive the same atomic link
// contract, implemented by the real new service; no hard links are enabled.
export async function link(source, target) {
  await observe('legacy-link', target);
  await globalThis[Symbol.for('dsh.go.ohos.publication')].publishAtomic(source, target);
}
