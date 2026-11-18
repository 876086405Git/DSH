import fs from 'node:fs';
import promises from 'node:fs/promises';
import childProcess from 'node:child_process';
import { isMainThread } from 'node:worker_threads';
import { dirname, isAbsolute, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isUtf8 } from 'node:buffer';
import { syncBuiltinESMExports } from 'node:module';
import { assertNodeFsInventory, fdOperations, fsPathTable, pathOperations, promisesPathTable } from './node-path-table.mjs';

const failure = (code, message) => Object.assign(new Error(message), { code });
const inside = (root, path) => path === root || path.startsWith(root + '/');
const installed = Symbol.for('dsh.go.ohos.nodeWorker.paths');

/** Install only inside one dedicated script Worker, before its entry loads. */
export function installNodeWorkerPaths(config) {
  if (isMainThread) throw failure('ERR_OHOS_NODE_WORKER_ONLY', 'Node script path rebasing is confined to its dedicated Worker');
  if (globalThis[installed]) throw failure('ERR_OHOS_NODE_WORKER_DUPLICATE', 'Worker path rebasing was already installed');
  assertNodeFsInventory(fs, promises);
  const original = Object.fromEntries(Object.keys(fs).map(name => [name, fs[name]]));
  const actualRealpath = original.realpathSync.native;
  const denied = () => failure('EACCES', 'EACCES: OHOS_SANDBOX_DENIED: Node script path is outside its authorized workspace or the operation is read-only');
  const canonicalDirectory = value => {
    if (typeof value !== 'string' || !isAbsolute(value) || value.includes('\0')) throw new TypeError('Node Worker roots must be absolute directory strings');
    const path = actualRealpath(value);
    if (path === '/' || !original.statSync(path).isDirectory()) throw denied();
    return path;
  };
  if (!Array.isArray(config.roots) || !config.roots.length || !Array.isArray(config.workspaceRoots) || !config.workspaceRoots.length) throw new TypeError('Node Worker requires explicit roots');
  const roots = config.roots.map(canonicalDirectory), workspaces = config.workspaceRoots.map(canonicalDirectory);
  if (workspaces.some(path => !roots.some(root => inside(root, path)))) throw denied();
  let cwd = canonicalDirectory(config.cwd);
  if (!workspaces.some(root => inside(root, cwd))) throw denied();
  const readOnly = config.readOnly === true;
  const descriptors = new Map();
  const descriptorError = () => failure('ERR_OHOS_NODE_FD_UNAVAILABLE', 'Only file descriptors opened by this Node Worker are available; use process.stdin/stdout/stderr for its private streams');
  const requireDescriptor = value => {
    const fd = typeof value === 'number' ? value : value?.fd;
    const owned = descriptors.get(fd);
    if (!owned || (owned.handle && owned.handle.fd !== fd) || (typeof value !== 'number' && owned.handle !== value)) {
      if (owned?.handle?.fd !== undefined && owned.handle.fd !== fd) descriptors.delete(fd);
      throw descriptorError();
    }
    return owned;
  };
  const rememberDescriptor = (fd, handle) => {
    const owned = { fd, handle }; descriptors.set(fd, owned);
    // Keep a strong FileHandle reference until close/transfer or Worker exit.
    // GC closing an unreferenced handle must not leave an authorized old fd.
    if (handle) handle.once('close', () => { if (descriptors.get(fd) === owned) descriptors.delete(fd); });
    return owned;
  };
  const permitted = path => roots.some(root => inside(root, path));
  const pathString = value => {
    if (typeof value === 'string') return value;
    if (value instanceof URL) return fileURLToPath(value);
    if (Buffer.isBuffer(value)) {
      if (!isUtf8(value)) throw failure('ERR_OHOS_NODE_PATH_ENCODING', 'Node Worker path rebasing supports UTF-8 file names');
      return value.toString('utf8');
    }
    throw failure('ERR_INVALID_ARG_TYPE', 'A path must be a string, Buffer or file URL');
  };
  // Check existing ancestors against actual symlink resolution. This is a
  // compatibility boundary, not an atomic OS sandbox against path replacement.
  const checkPath = (path, noFollow = false, ancestor = false) => {
    // Node's public realpath walks ancestor lstat entries. Permit only that
    // metadata view of known root ancestors, never directory reads or writes.
    const allowed = value => permitted(value) || (ancestor && (value === '/' || roots.some(root => inside(value, root))));
    const normalized = resolve(path);
    if (!allowed(normalized)) throw denied();
    let parent = noFollow && !roots.includes(normalized) ? dirname(path) : path;
    for (;;) {
      try {
        if (!allowed(actualRealpath(parent))) throw denied();
        return;
      } catch (error) {
        if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
        const next = dirname(parent);
        if (next === parent) throw denied();
        parent = next;
      }
    }
  };
  const rebase = (value, { fd = false, prefix = false, noFollow = false, ancestor = false } = {}) => {
    if (fd && (typeof value === 'number' || (value && typeof value === 'object' && typeof value.fd === 'number' && !(value instanceof URL) && !Buffer.isBuffer(value)))) {
      requireDescriptor(value); return value;
    }
    const text = pathString(value);
    if (text.includes('\0')) throw failure('ERR_INVALID_ARG_VALUE', 'A path must not contain NUL');
    // An empty ordinary path remains invalid independently of either cwd.
    if (!text && !prefix) return value;
    const path = isAbsolute(text) ? text : cwd + '/' + text;
    checkPath(path, noFollow, ancestor);
    return Buffer.isBuffer(value) ? Buffer.from(path) : path;
  };
  const flagsWrite = flags => typeof flags === 'number'
    ? !!(flags & (fs.constants.O_WRONLY | fs.constants.O_RDWR | fs.constants.O_CREAT | fs.constants.O_TRUNC | fs.constants.O_APPEND))
    : flags !== undefined && !['r', 'rs', 'sr'].includes(flags);
  const protectFileHandle = handle => {
    rememberDescriptor(handle.fd, handle);
    if (!readOnly) return handle;
    for (const name of ['appendFile', 'chmod', 'chown', 'datasync', 'sync', 'truncate', 'utimes', 'write', 'writeFile', 'writev', 'createWriteStream', 'writer']) {
      if (typeof handle[name] !== 'function') continue;
      Object.defineProperty(handle, name, { configurable: true, writable: true, value: ['createWriteStream', 'writer'].includes(name)
        ? function () { throw denied(); }
        : async function () { throw denied(); } });
    }
    return handle;
  };
  const globArgs = (args, completion) => {
    let options = args[1];
    if (completion === 'callback' && typeof options === 'function') { args.splice(1, 0, undefined); options = undefined; }
    if (options !== undefined && (options === null || typeof options !== 'object' || Array.isArray(options))) throw failure('ERR_INVALID_ARG_TYPE', 'Glob options must be an object');
    const base = options?.cwd === undefined ? cwd : pathString(rebase(options.cwd));
    checkPath(base);
    if (options?.followSymlinks === true) throw failure('ERR_OHOS_NODE_GLOB_SYMLINKS', 'Following glob symlinks is outside the Node Worker path boundary');
    const patterns = Array.isArray(args[0]) ? args[0] : [args[0]];
    for (const pattern of patterns) {
      if (typeof pattern !== 'string') throw failure('ERR_INVALID_ARG_TYPE', 'Glob patterns must be strings');
      const full = isAbsolute(pattern) ? pattern : base + '/' + pattern;
      if (!permitted(resolve(full))) throw denied();
      const magic = full.search(/[*?\[\]{}]/);
      if (magic !== -1 && /(?:^|\/)\.\.(?:\/|$)/.test(full.slice(magic))) throw failure('ERR_OHOS_NODE_GLOB_PARENT', 'Parent traversal after a glob wildcard is unavailable');
      checkPath(magic === -1 ? full : dirname(full.slice(0, magic) + '_'));
    }
    args[1] = { ...options, cwd: base, followSymlinks: false };
  };
  const transform = (operation, values, completion) => {
    const rule = pathOperations[operation], args = [...values];
    if (readOnly && (rule.write || (rule.open && flagsWrite(args[1])) || (rule.stream && flagsWrite(args[1]?.flags)))) throw denied();
    if (rule.glob) { globArgs(args, completion); return args; }
    if (rule.utf8Stream) {
      if (args[0]?.fd !== undefined) requireDescriptor(args[0].fd);
      if (args[0] && typeof args[0] === 'object' && args[0].dest !== undefined) args[0] = { ...args[0], dest: rebase(args[0].dest) };
      return args;
    }
    for (const index of rule.paths) {
      // Stream constructors intentionally ignore path when an fd is supplied.
      if (rule.stream && args[1]?.fd !== undefined && args[1]?.fd !== null) { requireDescriptor(args[1].fd); continue; }
      args[index] = rebase(args[index], rule);
    }
    if (rule.symlink) {
      const target = pathString(args[0]);
      checkPath(isAbsolute(target) ? target : dirname(pathString(args[1])) + '/' + target);
      // POSIX relative symlink targets are relative to the link, never cwd.
      if (args[0] instanceof URL) args[0] = target;
    }
    if (operation === 'cp') {
      let options = args[2];
      if (completion === 'callback' && typeof options === 'function') { args.splice(2, 0, undefined); options = undefined; }
      if (options === undefined || (options && typeof options === 'object' && (options.filter === undefined || typeof options.filter === 'function'))) {
        const filter = options?.filter;
        args[2] = { ...options, filter: (source, dest) => {
          checkPath(source); checkPath(dest, true);
          return filter ? filter(source, dest) : true;
        } };
      }
    }
    return args;
  };
  const wrap = (originalFunction, entry) => {
    const { operation, completion } = entry;
    const invoke = (receiver, args) => {
      const transformed = transform(operation, args, completion);
      if (operation === 'open' && completion === 'callback' && typeof transformed.at(-1) === 'function') {
        const callback = transformed.at(-1);
        transformed[transformed.length - 1] = function (error, fd) {
          if (!error) rememberDescriptor(fd);
          return Reflect.apply(callback, this, [error, fd]);
        };
      }
      const result = Reflect.apply(originalFunction, receiver, transformed);
      if (operation === 'open' && completion === 'sync') rememberDescriptor(result);
      return result;
    };
    if (completion === 'promise') return async function (...args) {
      const value = await invoke(this, args);
      return operation === 'open' ? protectFileHandle(value) : value;
    };
    if (completion === 'iterator') return async function* (...args) { yield* invoke(this, args); };
    return new Proxy(originalFunction, {
      apply(target, receiver, args) {
        try { return invoke(receiver, args); }
        catch (error) {
          const callback = args.at(-1);
          if (completion !== 'callback' || typeof callback !== 'function') throw error;
          queueMicrotask(() => operation === 'exists' ? callback(false) : callback(error));
        }
      },
      construct(target, args, newTarget) {
        return Reflect.construct(target, transform(operation, args, completion), newTarget);
      },
    });
  };
  // Build every wrapper before replacing an export; validation above leaves
  // main/ordinary Workers untouched, including if the fixed surface changed.
  const replacements = new Map();
  for (const [name, entry] of Object.entries(fsPathTable)) {
    const value = original[name];
    if (value === undefined && ['lchmod', 'lchmodSync'].includes(name)) continue;
    if (typeof value !== 'function') throw failure('ERR_OHOS_NODE_FS_SURFACE_CHANGED', 'Node path export changed type: ' + name);
    const replacement = wrap(value, entry);
    if (name === 'realpath' || name === 'realpathSync') {
      // Proxy property definition would mutate the original function itself.
      const native = wrap(value.native, entry);
      replacements.set(name, new Proxy(replacement, { get(target, key, receiver) {
        return key === 'native' ? native : Reflect.get(target, key, receiver);
      } }));
    } else replacements.set(name, replacement);
  }
  const promiseReplacements = new Map(Object.entries(promisesPathTable).map(([name, entry]) => [name, wrap(promises[name], entry)]));
  for (const [name, write] of Object.entries(fdOperations)) {
    const value = original[name];
    // Preserve Node's own symbol metadata, especially customPromisifyArgs on
    // read/write/readv/writev; replacing them with plain functions loses the
    // original multi-value Promise result even when callbacks still work.
    replacements.set(name, new Proxy(value, { apply(target, receiver, args) {
        try {
          const owned = requireDescriptor(args[0]);
          if (readOnly && write) throw denied();
          // Revoke before handing close to libuv. Waiting for its callback leaves
          // a real interval where another thread can already reuse the number.
          if (name === 'close' || name === 'closeSync') {
            if (descriptors.get(owned.fd) === owned) descriptors.delete(owned.fd);
          }
          return Reflect.apply(target, receiver, args);
        } catch (error) {
          const callback = args.at(-1);
          if (!name.endsWith('Sync') && typeof callback === 'function') { queueMicrotask(() => callback(error)); return; }
          throw error;
        }
      } }));
  }
  for (const [name, value] of replacements) Object.defineProperty(fs, name, { value, writable: true, configurable: true, enumerable: true });
  for (const [name, value] of promiseReplacements) promises[name] = value;
  const reopen = original.Utf8Stream.prototype.reopen;
  original.Utf8Stream.prototype.reopen = function (path) {
    if (readOnly) throw denied();
    return Reflect.apply(reopen, this, path === undefined ? [] : [rebase(path)]);
  };
  process.cwd = () => cwd;
  process.chdir = directory => {
    if (typeof directory !== 'string') throw failure('ERR_INVALID_ARG_TYPE', 'chdir requires a directory string');
    if (!directory) throw failure('ENOENT', 'chdir target is empty');
    const path = pathString(rebase(directory));
    const next = actualRealpath(path);
    if (!workspaces.some(root => inside(root, next))) throw denied();
    if (!original.statSync(next).isDirectory()) throw failure('ENOTDIR', 'chdir target is not a directory');
    cwd = next;
  };
  const unavailable = () => { throw failure('ERR_OHOS_CHILD_PROCESS_UNAVAILABLE', 'child_process is unavailable in the OHOS Node script Worker'); };
  for (const name of ['exec', 'execSync', 'execFile', 'execFileSync', 'fork', 'spawn', 'spawnSync']) childProcess[name] = unavailable;
  childProcess.ChildProcess.prototype.spawn = unavailable;
  syncBuiltinESMExports();
  Object.defineProperty(globalThis, installed, { value: Object.freeze({ protocol: 1, nodeVersion: process.versions.node }) });
}
