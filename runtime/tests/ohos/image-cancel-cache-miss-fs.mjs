import * as fs from 'node:fs/promises';
export * from 'node:fs/promises';
export const realReadFile = fs.readFile;
let next;
export function arm(path, callbacks) { next = { path, callbacks }; }
export function readFile(...args) {
  const hooks = next && args[0] === next.path ? next.callbacks : undefined;
  if (hooks) { next = undefined; hooks.before(); }
  const promise = fs.readFile(...args);
  if (hooks) hooks.after(promise, args[1]?.signal);
  return promise;
}
