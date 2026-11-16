import * as fs from 'node:fs/promises';
export * from 'node:fs/promises';
export const reads = [];
export const realReadFile = fs.readFile;
export function readFile(...args) {
  const promise = fs.readFile(...args);
  void promise.then(value => { reads.push({ path: args[0], value }); }, () => {});
  return promise;
}
