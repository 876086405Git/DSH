import { isMainThread } from 'node:worker_threads';
import { posix } from 'node:path';
import { loadGrantBinding } from './authority.mjs';
import { NativeGrantFs, grantFileObservation as entryObservation } from './grant-fs.mjs';
import { borrowProcessGrantAuthority, processWorkspaceGrant, isLogicalWorkspacePath,
  quarantineProcessGrantRetirement } from './process-authority.mjs';

const rootPattern = /^\/workspaces\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const fail = code => Object.assign(new Error(code), { code });

// DSH-only path operations. Node's filesystem functions remain untouched.
// Capture native methods in the sole preload, before plugins are admitted.
if (isMainThread && process.platform === 'openharmony') {
  let binding, unavailable;
  try {
    borrowProcessGrantAuthority();
    const loaded = loadGrantBinding();
    binding = Object.freeze(Object.fromEntries(['consume', 'stat', 'statExact', 'read', 'readdir', 'close'].map(name => {
      if (typeof loaded[name] !== 'function') throw fail('ERR_WORKSPACE_HOST_ABI');
      return [name, loaded[name].bind(loaded)];
    })));
  } catch (error) { unavailable = error; }

  function location(value) {
    if (!isLogicalWorkspacePath(value) || value.includes('\0')) throw fail('ERR_WORKSPACE_SCOPE_UNSUPPORTED');
    const canonical = posix.resolve(value);
    const root = canonical.split('/').slice(0, 3).join('/');
    if (!rootPattern.test(root)) throw fail('ERR_WORKSPACE_SCOPE_UNSUPPORTED');
    return { canonical, root, relative: canonical.slice(root.length) || '/' };
  }

  async function stat(value, signal) {
    signal?.throwIfAborted();
    const { root, relative } = location(value);
    if (unavailable) throw unavailable;
    let grant;
    try { grant = processWorkspaceGrant(root); }
    catch (error) {
      if (error.code !== 'ERR_WORKSPACE_UNAVAILABLE') throw error;
      throw Object.assign(new Error('文件夹授权当前不可用，请在系统选择器中重新选择该文件夹。', { cause: error }),
        { code: 'ENOENT', reason: 'ERR_WORKSPACE_REAUTHORIZATION_REQUIRED' });
    }
    const lease = borrowProcessGrantAuthority().issue([grant], { readOnly: true, workspaceRoot: root });
    let fs;
    try {
      fs = new NativeGrantFs(binding, lease.mounts[0].ticket);
      const info = await fs.stat(relative);
      signal?.throwIfAborted();
      return { ...info, isDirectory: () => info.isDirectory, isFile: () => info.isFile };
    } finally {
      try { fs?.close(); }
      finally {
        let drained = false;
        try { drained = lease.retire(); }
        catch (error) {
          quarantineProcessGrantRetirement();
          throw Object.assign(fail('ERR_WORKSPACE_DRAIN'), { cause: error });
        }
        if (!drained) {
          quarantineProcessGrantRetirement();
          throw fail('ERR_WORKSPACE_DRAIN');
        }
      }
    }
  }

  async function realpath(value) {
    const { canonical, root } = location(value);
    if (canonical !== root) throw fail('ERR_WORKSPACE_SCOPE_UNSUPPORTED');
    if (!(await stat(root)).isDirectory()) throw fail('ENOTDIR');
    return root;
  }

  async function directory(value, cwd, signal) {
    const target = location(posix.resolve(cwd, value));
    if (isLogicalWorkspacePath(cwd) && target.root !== location(cwd).root) throw fail('ERR_WORKSPACE_SCOPE_UNSUPPORTED');
    if (!(await stat(target.canonical, signal)).isDirectory()) throw Object.assign(
      new Error(`工作目录不是文件夹：${JSON.stringify(value)}`), { code: 'ENOTDIR' });
    return target.canonical;
  }

  // File-provider operations keep logical coordinates. Targets own no native
  // resource: each primitive closes and confirms its own read-only lease.
  async function resolveFile(value, cwd, signal) {
    signal?.throwIfAborted();
    const target = location(posix.resolve(cwd, value));
    if (isLogicalWorkspacePath(cwd) && target.root !== location(cwd).root) throw fail('ERR_WORKSPACE_SCOPE_UNSUPPORTED');
    return target.canonical;
  }

  function fileLease(value, signal) {
    signal?.throwIfAborted();
    const target = location(value);
    if (unavailable) throw unavailable;
    let grant;
    try { grant = processWorkspaceGrant(target.root); }
    catch (error) {
      if (error.code !== 'ERR_WORKSPACE_UNAVAILABLE') throw error;
      throw Object.assign(new Error('文件夹授权当前不可用，请在系统选择器中重新选择该文件夹。', { cause: error }),
        { code: 'ENOENT', reason: 'ERR_WORKSPACE_REAUTHORIZATION_REQUIRED' });
    }
    return { ...target, grant,
      lease: borrowProcessGrantAuthority().issue([grant], { readOnly: true, workspaceRoot: target.root }) };
  }

  function closeFileLease(fs, lease) {
    let closed = true, drained = false, failure;
    try { fs?.close(); }
    catch (error) { closed = false; failure = error; }
    try { drained = lease.retire() === true; }
    catch (error) { failure ??= error; }
    if (!closed || !drained) {
      quarantineProcessGrantRetirement();
      throw Object.assign(fail('ERR_WORKSPACE_DRAIN'), { cause: failure });
    }
  }

  async function withFileLease(value, signal, action) {
    const scope = fileLease(value, signal);
    let fs;
    try {
      fs = new NativeGrantFs(binding, scope.lease.mounts[0].ticket);
      const result = await action(fs, scope);
      signal?.throwIfAborted();
      return result;
    } finally { closeFileLease(fs, scope.lease); }
  }

  // Exact metadata is an opaque observation, not a content hash or a lock.
  async function lstatFile(value, signal) {
    return withFileLease(value, signal, async (fs, { relative, grant }) => {
      let info;
      try { info = await fs.lstatExact(relative); }
      catch (error) {
        if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return undefined;
        throw error;
      }
      return entryObservation(info, grant);
    });
  }

  async function listDirectory(value, signal) {
    return withFileLease(value, signal, async (fs, { canonical, relative, grant }) => {
      if (!(await fs.stat(relative)).isDirectory) throw fail('ERR_WORKSPACE_NOT_DIRECTORY');
      signal?.throwIfAborted();
      const names = await fs.readdir(relative);
      signal?.throwIfAborted();
      const entries = [];
      for (const name of names.sort((left, right) => left.localeCompare(right))) {
        signal?.throwIfAborted();
        const logicalPath = posix.join(canonical, name);
        let info;
        try { info = await fs.statExact(posix.join(relative, name)); }
        catch (error) {
          if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
        }
        signal?.throwIfAborted();
        const observed = info ? entryObservation(info, grant) : undefined;
        entries.push({ name, logicalPath, type: observed?.type ?? 'other',
          ...observed ? { version: observed.version } : {},
          ...info?.isFile ? { size: Number(info.size) } : {} });
      }
      return entries;
    });
  }

  async function statFile(value, signal) {
    return withFileLease(value, signal, async (fs, { relative, grant }) => {
      let info;
      try { info = await fs.statExact(relative); }
      catch (error) {
        if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return undefined;
        throw error;
      }
      return entryObservation(info, grant);
    });
  }

  async function requireRegularFile(fs, relative) {
    if (!(await fs.stat(relative)).isFile) throw fail('ERR_WORKSPACE_NOT_REGULAR_FILE');
  }

  async function readBuffer(value, signal) {
    return withFileLease(value, signal, async (fs, { relative }) => {
      await requireRegularFile(fs, relative);
      return fs.readFileBuffer(relative);
    });
  }

  async function readWindow(value, range, signal) {
    return withFileLease(value, signal, async (fs, { relative }) => {
      await requireRegularFile(fs, relative);
      return fs.readFileWindow(relative, range, signal);
    });
  }

  // The generator acquires nothing until first next(). EOF, an error and
  // iterator return all run the same real close/retire barrier.
  async function* readChunks(value, signal) {
    const scope = fileLease(value, signal);
    let fs;
    try {
      fs = new NativeGrantFs(binding, scope.lease.mounts[0].ticket);
      await requireRegularFile(fs, scope.relative);
      yield* fs.readFileChunks(scope.relative, signal);
    } finally { closeFileLease(fs, scope.lease); }
  }

  Object.defineProperty(globalThis, Symbol.for('dsh.go.ohos.workspace-paths'), {
    value: Object.freeze({ handles: isLogicalWorkspacePath, isRoot: value => rootPattern.test(value),
      stat, realpath, directory, resolveFile, statFile, readBuffer, readWindow, readChunks, lstatFile, listDirectory }), writable: false, configurable: false,
  });
}
