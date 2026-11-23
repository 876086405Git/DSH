// Strictly local import fixture. No node:fs export or global builtin is replaced.
import { watch as nativeWatch, renameSync, mkdirSync, symlinkSync } from 'node:fs';
import { stat as nativeStat } from 'node:fs/promises';
export { lstatSync, watchFile, unwatchFile } from 'node:fs';
export { access, lstat, readFile, readdir, realpath } from 'node:fs/promises';

export const boundary = {
  mode: 'none', allowedRoot: '', attempts: [], records: [], injected: false, loopTarget: undefined, statGate: undefined,
  reset(mode, allowedRoot) {
    this.mode = mode; this.allowedRoot = allowedRoot;
    this.attempts = []; this.records = []; this.injected = false; this.loopTarget = undefined; this.statGate = undefined;
  },
  holdNextStat(path) {
    if (!path.startsWith(this.allowedRoot + '/')) throw new Error('non-owned stat gate');
    const entered = Promise.withResolvers(), released = Promise.withResolvers();
    this.statGate = { path, captured: false, entered, released };
    return { entered: entered.promise, release: error => released.resolve(error) };
  },
};
export async function stat(path, options) {
  const gate = boundary.statGate;
  if (gate?.path === path && !gate.captured) {
    gate.captured = true;
    gate.entered.resolve();
    const error = await gate.released.promise;
    if (error) throw error;
  }
  return nativeStat(path, options);
}
const failure = () => Object.assign(new Error('local fs import fixture: ENOSPC'), { code: 'ENOSPC' });
export function watch(path, options, listener) {
  if (!boundary.allowedRoot || !(path === boundary.allowedRoot || path.startsWith(boundary.allowedRoot + '/'))) throw new Error('fixture attempted a non-owned watch path');
  boundary.attempts.push(path);
  if (boundary.mode === 'sync-error') throw failure();
  if (boundary.mode === 'ancestor-moves-before-open' && !boundary.injected) {
    boundary.injected = true;
    renameSync(path, path + '.moved');
    // The real fs.watch below now throws ENOENT; no fabricated missing-path result.
  }
  const aba = boundary.mode === 'ancestor-ABA-around-open' && !boundary.injected;
  if (aba) {
    boundary.injected = true;
    renameSync(path, path + '.original');
    mkdirSync(path);
  }
  const watcher = nativeWatch(path, options, listener);
  const record = { path, watcher, closed: false, events: [] };
  boundary.records.push(record);
  watcher.on('close', () => { record.closed = true; });
  watcher.on('change', (event, filename) => { record.events.push({ event, filename }); });
  if (aba) {
    renameSync(path, path + '.temporary');
    renameSync(path + '.original', path);
    // Both probes see A, while this actual native handle watches moved B.
  }
  if (boundary.mode === 'ancestor-replaced-after-open' && !boundary.injected) {
    boundary.injected = true;
    renameSync(path, path + '.moved');
    mkdirSync(path);
    // The real handle is still bound to the former inode at the same path.
  }
  if (boundary.mode === 'loop-after-open' && !boundary.injected) {
    boundary.injected = true;
    if (!boundary.loopTarget?.startsWith(boundary.allowedRoot + '/')) throw new Error('non-owned loop target');
    symlinkSync(boundary.loopTarget, boundary.loopTarget);
  }
  if (boundary.mode === 'early-async-error' && !boundary.injected) {
    boundary.injected = true;
    queueMicrotask(() => watcher.emit('error', failure()));
  }
  return watcher;
}
