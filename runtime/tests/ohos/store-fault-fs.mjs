// Test-only imported-fs boundary. It never changes node:fs exports or globals.
import * as real from 'node:fs';
import { resolve, sep } from 'node:path';
export * from 'node:fs';

let root, callback, trace = [];
const descriptors = new Map();
export function arm(directory, observer) {
  root = real.realpathSync(directory); callback = observer; trace = [];
}
export function disarm() { root = undefined; callback = undefined; }
export function events() { return structuredClone(trace); }
function event(op, phase, path, extra = {}) {
  if (typeof path !== 'string' || !root) return;
  path = resolve(path);
  if (path !== root && !path.startsWith(root + sep)) return;
  const value = { op, phase, path, ...extra };
  trace.push(value); callback?.(value);
}
export function openSync(path, flags, ...rest) {
  event('open', 'before', path, { flags });
  const fd = real.openSync(path, flags, ...rest);
  descriptors.set(fd, path); event('open', 'after', path, { flags }); return fd;
}
export function closeSync(fd) { descriptors.delete(fd); return real.closeSync(fd); }
export function writeFileSync(file, bytes, ...rest) {
  const path = typeof file === 'number' ? descriptors.get(file) : file;
  event('write', 'before', path);
  const result = real.writeFileSync(file, bytes, ...rest);
  event('write', 'after', path); return result;
}
export function fsyncSync(fd) {
  const path = descriptors.get(fd);
  event('fsync', 'before', path);
  const result = real.fsyncSync(fd);
  event('fsync', 'after', path); return result;
}
export function renameSync(from, to) {
  event('rename', 'before', from, { to });
  const result = real.renameSync(from, to);
  event('rename', 'after', from, { to }); return result;
}
export function rmSync(path, options) {
  event('rm', 'before', path);
  const result = real.rmSync(path, options);
  event('rm', 'after', path); return result;
}
export function unlinkSync(path) {
  event('unlink', 'before', path);
  const result = real.unlinkSync(path);
  event('unlink', 'after', path); return result;
}
