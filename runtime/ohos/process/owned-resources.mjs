import { constants, lstatSync, readlinkSync, realpathSync, mkdirSync, openSync, fstatSync, closeSync, readdirSync, chmodSync, renameSync } from 'node:fs';
import * as promises from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { isMainThread } from 'node:worker_threads';
import { cleanupOwnedTemporary } from '../publication/atomic.mjs';
import { borrowInstalledOwnership } from '../publication/index.mjs';

const maximumContentBytes = 64 * 1024 * 1024;
const ownedPaths = new Map();
const inside = (root, path) => path === root || path.startsWith(root + sep);
const fail = (code, message, cause) => Object.assign(new Error(message, { cause }), { code });
const denied = () => fail('EACCES', 'EACCES: OHOS_SANDBOX_DENIED: Git metadata is outside this job authority');
const identityOf = info => ({ dev: String(info.dev), ino: String(info.ino) });
const sameIdentity = (a, b) => String(a.dev) === String(b.dev) && String(a.ino) === String(b.ino);
const absolute = value => {
  if (typeof value !== 'string' || !isAbsolute(value) || value.includes('\0')) {
    throw new TypeError('Git resource paths must be absolute strings without NUL');
  }
  return resolve(value);
};
const bytesOf = content => {
  if (!(content instanceof Uint8Array)
      || content.buffer instanceof SharedArrayBuffer
      || content.byteLength > maximumContentBytes) {
    throw fail('ERR_OHOS_GIT_RESOURCE_CONTENT', 'Git metadata requires a non-shared Uint8Array of at most 64 MiB');
  }
  // Own the exact view, including its byteOffset/byteLength, before queuing.
  return Buffer.from(content);
};
const modeOf = (value = 0o644) => {
  if (!Number.isInteger(value) || value < 0 || value > 0o777) throw new TypeError('Invalid Git metadata file mode');
  return value;
};

/**
 * A main-thread resource owner for exactly one Worker/job. roots are the
 * already-narrowed cwd/session-ticket roots, not all host workspace roots.
 * fs/onStage are explicit factory-test seams, never Worker message fields.
 */
export function createOwnedGitResources({ roots, policy, getOwnership = borrowInstalledOwnership,
  fs = promises, onStage = () => {}, clearOwnedClone } = {}) {
  if (!isMainThread) throw fail('ERR_OHOS_OWNERSHIP_MAIN_THREAD', 'Git resources must be owned by the main engine');
  if (!Array.isArray(roots) || roots.length === 0) throw new TypeError('Explicit job roots are required');
  roots = Object.freeze([...new Set(roots.map(path => {
    path = absolute(path);
    if (path === '/' || realpathSync(path) !== path || !lstatSync(path).isDirectory()) {
      throw new TypeError('Git job roots must be canonical directories other than filesystem root');
    }
    return path;
  }))]);
  const readOnly = policy?.mode === 'read-only';
  const resources = new Map();
  const clones = new Map();
  const providerFailures = new Set();
  const pending = new Set();
  let ownership, accepting = true, stopped = false, tail = Promise.resolve(), finalization;
  const checkRunning = () => {
    if (providerFailures.size) {
      throw fail('ERR_OHOS_GIT_RESOURCE_POISONED', 'Git ownership operation failed; this job cannot continue',
        [...providerFailures][0]);
    }
    if (stopped) throw fail('ERR_OHOS_GIT_RESOURCE_STOPPED', 'Git resource operation was cancelled');
  };
  const owner = () => {
    if (!ownership) {
      const value = getOwnership();
      if (!value || ['reserve', 'identify', 'release'].some(name => typeof value[name] !== 'function')) {
        throw fail('ERR_OHOS_OWNERSHIP_UNAVAILABLE', 'A durable main-engine ownership service is required');
      }
      ownership = value;
    }
    return ownership;
  };
  const ledgerCall = async (method, ...args) => {
    try { return await owner()[method](...args); }
    catch (error) { providerFailures.add(error); throw error; }
  };
  // Walk symlinks explicitly so an outward dangling link is an authority
  // violation, not merely ENOENT. Internal symlinks may resolve within either
  // root already granted to this job. No environment value extends these roots.
  const physical = (input, allowMissingLeaf = true, depth = 0) => {
    const path = absolute(input);
    const root = roots.find(value => inside(value, path));
    if (!root || readOnly) throw denied();
    if (depth > 40) throw fail('ELOOP', 'Too many symbolic links in Git metadata path');
    if (realpathSync(root) !== root || !lstatSync(root).isDirectory()) throw denied();
    const parts = relative(root, path).split(sep).filter(Boolean);
    let current = root;
    for (let i = 0; i < parts.length; i++) {
      current = join(current, parts[i]);
      let info;
      try { info = lstatSync(current); }
      catch (error) {
        if (error.code === 'ENOENT' && allowMissingLeaf && i === parts.length - 1) return current;
        throw error;
      }
      if (info.isSymbolicLink()) {
        const target = resolve(dirname(current), readlinkSync(current));
        if (!roots.some(value => inside(value, target))) throw denied();
        return physical(join(target, ...parts.slice(i + 1)), allowMissingLeaf, depth + 1);
      }
      if (i < parts.length - 1 && !info.isDirectory()) throw fail('ENOTDIR', 'Git metadata parent is not a directory');
    }
    return current;
  };
  const targetPath = input => {
    const path = physical(input);
    const parent = physical(dirname(path), false);
    if (path === parent || roots.includes(path)) throw denied();
    const info = (() => { try { return lstatSync(path); } catch (error) { if (error.code !== 'ENOENT') throw error; } })();
    if (info && !info.isFile()) throw fail('ERR_OHOS_GIT_RESOURCE_TARGET', 'Git metadata target must be a regular file or absent');
    if (!lstatSync(parent).isDirectory()) throw fail('ENOTDIR', 'Git metadata parent is not a directory');
    if (ownedPaths.has(path)) throw fail('ERR_OHOS_GIT_RESOURCE_TARGET', 'An owned resource must be updated through its job-local id');
    return path;
  };
  const stage = (name, resource) => onStage(name, Object.freeze({
    id: resource.id, path: resource.path, target: resource.target,
    token: resource.token, receipt: resource.receipt && Object.freeze({ ...resource.receipt }),
  }));
  const existing = id => {
    const resource = typeof id === 'string' && resources.get(id);
    if (!resource) throw fail('ERR_OHOS_GIT_RESOURCE_ID', 'Git resource id does not belong to this job');
    return resource;
  };
  const verifyResource = resource => {
    if (!resource.file || !resource.receipt) throw fail('ERR_OHOS_GIT_RESOURCE_UNIDENTIFIED', 'Git resource has no live identity');
    if (physical(resource.targetInput) !== resource.target || physical(resource.path) !== resource.path) {
      throw fail('ERR_OHOS_GIT_RESOURCE_TARGET_CHANGED', 'Git metadata path resolution changed');
    }
    const named = lstatSync(resource.path, { bigint: true });
    if (!named.isFile() || !sameIdentity(named, resource.receipt)) {
      throw fail('ERR_OHOS_PUBLICATION_TEMP_REPLACED', 'Owned Git temporary was replaced');
    }
  };
  const write = async (resource, content) => {
    checkRunning(); verifyResource(resource);
    const opened = await resource.file.stat({ bigint: true });
    if (!opened.isFile() || !sameIdentity(opened, resource.receipt)) throw fail('ERR_OHOS_GIT_RESOURCE_IDENTITY', 'Git resource handle identity changed');
    // Rewriting the held inode can fail after modifying real bytes. Only a
    // complete positional write + truncate + sync makes it committable again.
    resource.ready = false;
    await stage('before-write', resource);
    for (let offset = 0; offset < content.byteLength;) {
      checkRunning();
      const count = Math.min(65536, content.byteLength - offset);
      const result = await resource.file.write(content, offset, count, offset);
      if (!Number.isInteger(result.bytesWritten) || result.bytesWritten <= 0 || result.bytesWritten > count) {
        throw fail('ERR_OHOS_GIT_RESOURCE_WRITE', 'Git metadata write made invalid progress');
      }
      offset += result.bytesWritten;
    }
    checkRunning();
    await resource.file.truncate(content.byteLength);
    await resource.file.chmod(resource.mode);
    await resource.file.sync();
    await stage('after-write', resource);
    checkRunning();
    resource.ready = true;
  };
  const allocate = async ({ target, content, mode }) => {
    checkRunning();
    const targetInput = absolute(target), final = targetPath(targetInput);
    owner();
    for (let attempt = 0; attempt < 32; attempt++) {
      checkRunning();
      const resource = { id: randomUUID(), path: join(dirname(final), '.dsh-ohos-git-' + randomUUID() + '.tmp'),
        target: final, targetInput, mode, openStarted: false, knownNotCreated: false };
      resources.set(resource.id, resource); ownedPaths.set(resource.path, resource);
      resource.token = await ledgerCall('reserve', resource.path, final);
      await stage('reserved', resource);
      checkRunning();
      // Recheck the actual job authority after waiting for durable reserve.
      if (targetPath(targetInput) !== final || physical(resource.path) !== resource.path) throw denied();
      resource.openStarted = true;
      try {
        resource.file = await fs.open(resource.path,
          constants.O_RDWR | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
        resource.knownNotCreated = true;
        await clean(resource);
        continue;
      }
      await stage('created', resource);
      const info = await resource.file.stat({ bigint: true });
      if (!info.isFile()) throw fail('ERR_OHOS_GIT_RESOURCE_IDENTITY', 'Git temporary is not a regular file');
      resource.receipt = Object.freeze({ path: resource.path, ...identityOf(info) });
      if (info.size !== 0n) throw fail('ERR_OHOS_GIT_RESOURCE_IDENTITY', 'New Git temporary is not empty');
      await ledgerCall('identify', resource.token, identityOf(info));
      resource.identified = true;
      await stage('identified', resource);
      await write(resource, content);
      return resource;
    }
    throw fail('ERR_OHOS_GIT_RESOURCE_COLLISION', 'Could not allocate an exclusive Git temporary');
  };
  const clean = async resource => {
    const failures = [];
    let cleared = false;
    try {
      await stage('before-cleanup', resource);
      if (resource.receipt) {
        if (physical(resource.path) !== resource.path) throw denied();
        if (!resource.file || resource.file.fd < 0) {
          // A previous failed cleanup may already have closed this handle.
          // Never retry unlink from a dev/ino receipt alone: inode numbers can
          // be reused. Existing entries remain for marker-checked restart.
          try { lstatSync(resource.path); }
          catch (error) { if (error.code !== 'ENOENT') throw error; cleared = true; }
          if (!cleared) throw fail('ERR_OHOS_GIT_RESOURCE_HANDLE_CLOSED',
            'A Git temporary without its live handle is preserved for recovery');
        } else {
          const opened = await resource.file.stat({ bigint: true });
          if (!opened.isFile() || !sameIdentity(opened, resource.receipt)) {
            throw fail('ERR_OHOS_GIT_RESOURCE_IDENTITY', 'Git cleanup handle identity changed');
          }
          // The opened inode remains alive throughout the synchronous identity
          // check and unlink. No filename-prefix scan or dev/ino-only restart.
          cleanupOwnedTemporary(resource.receipt);
          cleared = true;
        }
      } else if (!resource.openStarted || resource.knownNotCreated) {
        cleared = true; // This process never created the path; preserve others.
      } else {
        try { lstatSync(resource.path); }
        catch (error) { if (error.code !== 'ENOENT') throw error; cleared = true; }
        if (!cleared) throw fail('ERR_OHOS_GIT_RESOURCE_UNIDENTIFIED', 'An unidentified Git temporary is preserved with its reservation');
      }
    } catch (error) { failures.push(error); }
    if (resource.file) {
      try { await resource.file.close(); resource.file = undefined; }
      catch (error) { failures.push(error); }
    }
    if (cleared && failures.length === 0) {
      try {
        if (resource.token !== undefined) await ledgerCall('release', resource.token);
        resources.delete(resource.id); ownedPaths.delete(resource.path);
        await stage('after-release', resource);
      } catch (error) { failures.push(error); }
    }
    if (failures.length) {
      const error = failures.length === 1 ? failures[0]
        : new AggregateError(failures, 'Git resource cleanup failed', { cause: failures[0] });
      providerFailures.add(error);
      throw error;
    }
  };
  const commit = async resource => {
    checkRunning(); verifyResource(resource);
    if (!resource.ready) throw fail('ERR_OHOS_GIT_RESOURCE_DIRTY', 'Git resource has no complete durable write to commit');
    await stage('before-commit', resource);
    checkRunning(); verifyResource(resource);
    // These entries share the same resolved parent. Use real rename, never
    // the virtual fs.mv EXDEV copy fallback. An issued call must settle even
    // after cancellation; a completed final file is not rolled back.
    await fs.rename(resource.path, resource.target);
    resource.committed = true;
    try {
      await stage('after-commit', resource);
      await clean(resource);
    } catch (error) {
      const failure = Object.assign(fail('ERR_OHOS_GIT_COMMITTED_CLEANUP',
        'Git metadata committed but resource cleanup failed', error), { committed: true });
      providerFailures.add(failure);
      throw failure;
    }
  };
  // Clone work trees are private job directories, never the user's destination.
  // Unlike Worker finally blocks, finish runs after hard termination and all
  // accepted parent I/O has settled. File-ledger cleanup must precede this tree.
  const cloneRemover = () => {
    if (clearOwnedClone !== undefined) {
      if (typeof clearOwnedClone !== 'function') throw new TypeError('Invalid native clone cleanup seam');
      return clearOwnedClone;
    }
    const binding = process._linkedBinding('dsh_ohos_publication');
    if (typeof binding.clearOwnedClone !== 'function') throw fail('ERR_OHOS_GIT_CLONE_CLEANUP_UNAVAILABLE', 'Native descriptor-anchored clone cleanup is required');
    return binding.clearOwnedClone;
  };
  const cloneTarget = input => {
    const target = physical(input);
    if (target !== input || roots.includes(target)) throw denied();
    const parent = physical(dirname(target), false);
    let info;
    try { info = lstatSync(target, { bigint: true }); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (info && (!info.isDirectory() || readdirSync(target).length)) {
      throw fail('ENOTEMPTY', 'Clone destination is not empty or is not a directory');
    }
    return { target, parent, info };
  };
  const verifyClone = resource => {
    if (physical(resource.parent, false) !== resource.parent
        || !sameIdentity(lstatSync(resource.parent, { bigint: true }), resource.parentIdentity)
        || physical(resource.path, false) !== resource.path) {
      throw fail('ERR_OHOS_GIT_CLONE_REPLACED', 'Clone staging parent changed');
    }
    const named = lstatSync(resource.path, { bigint: true });
    if (!named.isDirectory() || !sameIdentity(named, resource.receipt)
        || !sameIdentity(fstatSync(resource.fd, { bigint: true }), resource.receipt)) {
      throw fail('ERR_OHOS_GIT_CLONE_REPLACED', 'Clone staging directory changed');
    }
  };
  const closeClone = resource => {
    try { closeSync(resource.fd); }
    finally { try { closeSync(resource.parentFd); } finally { clones.delete(resource.id); } }
  };
  const cleanClone = async resource => {
    try {
      if (!resource.committed) {
        verifyClone(resource);
        resource.remove(resource.fd, resource.parentFd, basename(resource.path), resource.receipt.dev, resource.receipt.ino);
      }
    } catch (error) { providerFailures.add(error); throw error; }
    finally { closeClone(resource); }
  };
  const createClone = async payload => {
    const remove = cloneRemover();
    const { target, parent, info } = cloneTarget(payload.target);
    const id = randomUUID(), path = join(parent, `.dsh-git-clone-${id}`);
    // No await between exclusive creation and opening/recording its identity.
    // The fd is retained until cleanup or successful publication.
    const parentFd = openSync(parent, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    let fd;
    try {
      mkdirSync(path, { mode: 0o700 });
      try { fd = openSync(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW); }
      catch (error) { throw error; } // Preserve an empty shell if opening its identity fails.
    } catch (error) { closeSync(parentFd); throw error; }
    const resource = { id, target, parent, path, fd, parentFd, remove, receipt: identityOf(fstatSync(fd, { bigint: true })),
      parentIdentity: identityOf(fstatSync(parentFd, { bigint: true })), initial: info && identityOf(info),
      mode: info ? Number(info.mode & 0o777n) : (0o777 & ~process.umask()) };
    clones.set(id, resource);
    await stage('clone-created', resource);
    checkRunning(); verifyClone(resource);
    return { id, path };
  };
  const commitClone = async resource => {
    await stage('clone-before-commit', resource);
    checkRunning(); verifyClone(resource);
    const { info } = cloneTarget(resource.target);
    if (resource.initial ? !info || !sameIdentity(info, resource.initial) : info) {
      throw fail('ERR_OHOS_GIT_CLONE_REPLACED', 'Clone destination changed during clone');
    }
    chmodSync(resource.path, resource.mode);
    // Same-parent rename has no EXDEV copy fallback. A user file added to an
    // existing empty destination makes rename fail; it is never recursively removed.
    renameSync(resource.path, resource.target);
    resource.committed = true;
    await cleanClone(resource);
  };
  const normalize = (operation, payload) => {
    if (operation === 'createClone') return { target: absolute(payload?.target) };
    if (operation === 'commitClone' || operation === 'releaseClone') return { id: payload?.id };
    if (operation === 'createIndex' || operation === 'writeMetadata') {
      return { target: absolute(payload?.target), content: bytesOf(payload?.content), mode: modeOf(payload?.mode) };
    }
    if (operation === 'writeIndex') return { id: payload?.id, content: bytesOf(payload?.content) };
    if (operation === 'commitIndex' || operation === 'releaseIndex') return { id: payload?.id };
    throw fail('ERR_OHOS_GIT_RESOURCE_OPERATION', 'Unknown Git resource operation');
  };
  const execute = async (operation, payload) => {
    checkRunning();
    if (readOnly) throw denied();
    if (operation === 'createClone') return createClone(payload);
    if (operation === 'commitClone' || operation === 'releaseClone') {
      const resource = clones.get(payload.id);
      if (!resource) throw fail('ERR_OHOS_GIT_RESOURCE_ID', 'Clone id does not belong to this job');
      if (operation === 'commitClone') return commitClone(resource);
      for (const file of [...resources.values()]) {
        if (inside(resource.path, file.path)) await clean(file);
      }
      checkRunning();
      return cleanClone(resource);
    }
    if (operation === 'createIndex') {
      const resource = await allocate(payload);
      return Object.freeze({ id: resource.id, path: resource.path });
    }
    if (operation === 'writeMetadata') {
      const resource = await allocate(payload);
      await commit(resource);
      return;
    }
    const resource = existing(payload.id);
    if (operation === 'writeIndex') return write(resource, payload.content);
    if (operation === 'commitIndex') return commit(resource);
    await clean(resource);
    return true;
  };
  const accept = (operation, payload) => {
    if (!accepting) return Promise.reject(fail('ERR_OHOS_GIT_RESOURCE_STOPPED', 'Git resource owner is no longer accepting requests'));
    let input;
    try { input = normalize(operation, payload); }
    catch (error) { return Promise.reject(error); }
    // Register before the first asynchronous action can run. The caught tail
    // preserves serialization while the caller retains its original failure.
    const result = tail.then(() => execute(operation, input));
    pending.add(result);
    tail = result.catch(() => {});
    result.then(() => pending.delete(result), () => pending.delete(result));
    return result;
  };
  const stop = () => { accepting = false; stopped = true; };
  return Object.freeze({
    accept,
    createClone: payload => accept('createClone', payload),
    commitClone: id => accept('commitClone', { id }),
    releaseClone: id => accept('releaseClone', { id }),
    createIndex: payload => accept('createIndex', payload),
    writeIndex: (id, content) => accept('writeIndex', { id, content }),
    writeMetadata: payload => accept('writeMetadata', payload),
    commitIndex: id => accept('commitIndex', { id }),
    releaseIndex: id => accept('releaseIndex', { id }),
    stop,
    get pendingCount() { return pending.size; },
    get resourceCount() { return resources.size + clones.size; },
    finish() {
      if (finalization) return finalization;
      stop();
      finalization = (async () => {
        await tail;
        for (const resource of [...resources.values()]) {
          try { await clean(resource); } catch {}
        }
        for (const resource of [...clones.values()]) {
          try {
            if (providerFailures.size) closeClone(resource);
            else await cleanClone(resource);
          } catch (error) { providerFailures.add(error); }
        }
        if (providerFailures.size === 1) throw [...providerFailures][0];
        if (providerFailures.size) throw new AggregateError([...providerFailures], 'Git resources did not cleanly finish');
      })();
      return finalization;
    },
  });
}
