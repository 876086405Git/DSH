import { constants, lstatSync, unlinkSync } from 'node:fs';
import * as promises from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { dirname, isAbsolute, join, resolve, sep } from 'node:path';
import { cleanupOwnedTemporary } from './atomic.mjs';
import { decodeAtomicState, encodeAtomicState } from './atomic-fuse.mjs';

const fail = (code, message, cause) => Object.assign(new Error(message, { cause }), { code });
const identity = info => ({ dev: String(info.dev), ino: String(info.ino) });
const sameIdentity = (a, b) => String(a.dev) === String(b.dev) && String(a.ino) === String(b.ino);
const absolute = value => {
  if (typeof value !== 'string' || !isAbsolute(value) || value.includes('\0') || resolve(value) !== value) {
    throw new TypeError('Ownership ledger paths must be canonical absolute paths without NUL');
  }
  return value;
};
const nonempty = value => typeof value === 'string' && value.length > 0 && !value.includes('\0');
const decimal = value => typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value);
const inside = (directory, path) => path === directory || path.startsWith(directory + sep);
const reportsFailure = (error, expected, visited = new Set()) => {
  if (error === expected) return true;
  if (!error || typeof error !== 'object' || visited.has(error)) return false;
  visited.add(error);
  return reportsFailure(error.cause, expected, visited)
    || (Array.isArray(error.errors) && error.errors.some(item => reportsFailure(item, expected, visited)));
};

function decodeLedger(text, directory) {
  let value;
  try { value = JSON.parse(text); }
  catch (cause) { throw fail('ERR_OHOS_LEDGER_CORRUPT', 'Ownership ledger is not valid JSON', cause); }
  if (value?.schema !== 2 || !Array.isArray(value.entries)) {
    throw fail('ERR_OHOS_LEDGER_CORRUPT', 'Unsupported ownership ledger format');
  }
  const entries = new Map(), paths = new Set();
  for (const entry of value.entries) {
    try {
      if (!entry || !nonempty(entry.token) || !nonempty(entry.ownerId)
          || !Number.isSafeInteger(entry.pid) || entry.pid <= 0
          || !['reserved', 'identified'].includes(entry.state)) throw new Error('invalid entry');
      absolute(entry.path); absolute(entry.finalPath);
      if (entry.path === entry.finalPath || entries.has(entry.token) || paths.has(entry.path)
          || inside(directory, entry.path) || inside(directory, entry.finalPath)) {
        throw new Error('duplicate or final-path resource');
      }
      if (entry.state === 'identified' && (!decimal(entry.dev) || !decimal(entry.ino) || entry.marker !== entry.token)) {
        throw new Error('invalid inode identity');
      }
      if (entry.state === 'reserved' && (entry.dev !== undefined || entry.ino !== undefined || entry.marker !== undefined)) {
        throw new Error('reserved entry has ambiguous identity');
      }
    } catch (cause) { throw fail('ERR_OHOS_LEDGER_CORRUPT', 'Invalid ownership ledger entry', cause); }
    entries.set(entry.token, Object.freeze(entry)); paths.add(entry.path);
  }
  return entries;
}

/**
 * One private on-disk resource ledger, protected by a real nonblocking flock.
 * lockExclusive(fd) is the synchronous linked native operation. The fixed lock
 * inode is never unlinked or renamed. Keep this object open for the engine's life.
 * fs injection is for failure tests; the product uses the real Node promises API.
 */
export async function openOwnershipLedger({ directory, ownerId, lockExclusive,
  setOwnershipMarker, getOwnershipMarker, fs = promises }) {
  absolute(directory);
  if (directory === '/' || !nonempty(ownerId)) throw new TypeError('Private ledger directory and process ownerId are required');
  if ([lockExclusive, setOwnershipMarker, getOwnershipMarker].some(fn => typeof fn !== 'function')) {
    throw new TypeError('Native lockExclusive and ownership marker functions are required');
  }
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const directoryInfo = await fs.lstat(directory);
  if (!directoryInfo.isDirectory() || (directoryInfo.mode & 0o077) !== 0) {
    throw fail('ERR_OHOS_LEDGER_DIRECTORY', 'Ownership ledger requires a private, nonsymlink directory');
  }
  directory = await fs.realpath(directory);
  const lockPath = join(directory, '.lock');
  const ledgerPath = join(directory, 'ledger.json');
  const pendingPath = join(directory, 'ledger.pending');
  const atomicStatePath = join(directory, 'atomic-state.json');
  const atomicPendingPath = join(directory, 'atomic-state.pending');
  let lock, directoryHandle, entries;
  try {
    lock = await fs.open(lockPath, constants.O_RDWR | constants.O_CREAT | constants.O_NOFOLLOW, 0o600);
    const lockInfo = await lock.stat({ bigint: true });
    if (!lockInfo.isFile()) throw fail('ERR_OHOS_LEDGER_LOCK', 'Ownership lock must be a regular file');
    try {
      if (lockExclusive(lock.fd) !== undefined) throw new TypeError('lockExclusive must synchronously return undefined');
    } catch (cause) {
      if (['EAGAIN', 'EWOULDBLOCK'].includes(cause.code)) {
        throw fail('ERR_OHOS_LEDGER_BUSY', 'Another process holds the ownership ledger', cause);
      }
      throw cause;
    }
    const namedLock = await fs.lstat(lockPath, { bigint: true });
    if (!namedLock.isFile() || !sameIdentity(namedLock, lockInfo)) {
      throw fail('ERR_OHOS_LEDGER_LOCK', 'Ownership lock path changed during acquisition');
    }
    directoryHandle = await fs.open(directory, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    let file;
    try {
      file = await fs.open(ledgerPath, constants.O_RDONLY | constants.O_NOFOLLOW);
      if (!(await file.stat()).isFile()) throw fail('ERR_OHOS_LEDGER_CORRUPT', 'Ledger is not a regular file');
      entries = decodeLedger(await file.readFile('utf8'), directory);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      entries = new Map();
    } finally { if (file) await file.close(); }

    // This exact slot belongs to the ledger protocol, inside its private
    // directory. It is not a publication orphan and is never prefix-scanned.
    // A corrupt committed ledger above fails before touching this evidence.
    try {
      const pending = lstatSync(pendingPath, { bigint: true });
      if (!pending.isFile()) throw fail('ERR_OHOS_LEDGER_PENDING', 'Ledger pending slot is not a regular file');
      unlinkSync(pendingPath);
      await directoryHandle.sync();
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  } catch (error) {
    const failures = [error];
    for (const file of [directoryHandle, lock]) if (file) {
      try { await file.close(); } catch (closeError) { failures.push(closeError); }
    }
    if (failures.length > 1) throw new AggregateError(failures, 'Ownership ledger startup and close failed', { cause: error });
    throw error;
  }

  let queue = Promise.resolve(), poisoned, closing = false, closePromise;
  function enqueue(operation) {
    if (closing) return Promise.reject(fail('ERR_OHOS_LEDGER_CLOSED', 'Ownership ledger is closing'));
    const result = queue.then(() => {
      if (poisoned) throw fail('ERR_OHOS_LEDGER_POISONED', 'Ownership ledger persistence failed; restart is required', poisoned);
      return operation();
    });
    queue = result.catch(() => {}); // Preserve ordering; callers receive the original rejection.
    return result;
  }
  async function persist(next) {
    let pending;
    try {
      pending = await fs.open(pendingPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      await pending.writeFile(JSON.stringify({ schema: 2, entries: [...next.values()] }) + '\n');
      await pending.sync();
      await pending.close(); pending = undefined;
      await fs.rename(pendingPath, ledgerPath);
      await directoryHandle.sync();
      entries = next;
    } catch (error) {
      poisoned = error;
      if (pending) {
        try { await pending.close(); }
        catch (closeError) { throw new AggregateError([error, closeError], 'Ledger write and close failed', { cause: error }); }
      }
      throw error;
    }
  }
  async function readAtomicState() {
    let file, value = null;
    try {
      try {
        file = await fs.open(atomicStatePath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
        const info = await file.stat();
        if (!info.isFile() || info.size > 32768) {
          throw fail('ERR_OHOS_PUBLICATION_ATOMIC_STATE_CORRUPT', 'Publication atomic state must be a bounded regular file');
        }
        value = decodeAtomicState(await file.readFile('utf8'));
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      finally { if (file) { await file.close(); file = undefined; } }
      // This exact pending slot belongs to the state protocol. Decode the
      // committed record first; preserve evidence if that record is corrupt.
      try {
        const pending = lstatSync(atomicPendingPath, { bigint: true });
        if (!pending.isFile()) {
          throw fail('ERR_OHOS_PUBLICATION_ATOMIC_PENDING', 'Publication atomic pending slot is not a regular file');
        }
        unlinkSync(atomicPendingPath);
        await directoryHandle.sync();
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      return value;
    } catch (error) { poisoned = error; throw error; }
  }
  async function persistAtomicState(text) {
    let pending;
    try {
      pending = await fs.open(atomicPendingPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      await pending.writeFile(text);
      await pending.sync();
      await pending.close(); pending = undefined;
      await fs.rename(atomicPendingPath, atomicStatePath);
      await directoryHandle.sync();
    } catch (error) {
      poisoned = error;
      if (pending) {
        try { await pending.close(); }
        catch (closeError) { throw new AggregateError([error, closeError], 'Publication state write and close failed', { cause: error }); }
      }
      throw error;
    }
  }
  const publicationAtomicState = Object.freeze({
    transaction(operation) {
      if (typeof operation !== 'function') return Promise.reject(new TypeError('A state transaction is required'));
      return enqueue(async () => {
        let active = true, ioQueue = Promise.resolve();
        const accepted = [];
        const submit = action => {
          if (!active) return Promise.reject(fail('ERR_OHOS_PUBLICATION_ATOMIC_TRANSACTION', 'Publication state transaction has ended'));
          const result = ioQueue.then(() => {
            if (poisoned) throw fail('ERR_OHOS_LEDGER_POISONED', 'Ownership ledger persistence failed; restart is required', poisoned);
            return action();
          });
          ioQueue = result.catch(() => {});
          accepted.push(result);
          return result;
        };
        const io = Object.freeze({
          read() { return submit(readAtomicState); },
          commit(value) {
            const text = encodeAtomicState(value);
            if (decodeAtomicState(text).ownerId !== ownerId) throw fail('ERR_OHOS_LEDGER_OWNER', 'Publication state belongs to a different process');
            return submit(() => persistAtomicState(text));
          },
        });
        let result;
        const failures = [];
        try { result = await operation(io); }
        catch (error) { failures.push(error); }
        finally { active = false; }
        // Even an accidentally unawaited accepted state IO must settle before
        // this queue slot, close(), or the following owner operation proceeds.
        for (const settled of await Promise.allSettled(accepted)) {
          if (settled.status === 'rejected' && !failures.some(error => reportsFailure(error, settled.reason))) failures.push(settled.reason);
        }
        if (failures.length === 1) throw failures[0];
        if (failures.length > 1) throw new AggregateError(failures, 'Publication state transaction failed', { cause: failures[0] });
        return result;
      });
    },
  });
  function currentEntry(token) {
    const entry = entries.get(token);
    if (!entry || entry.ownerId !== ownerId) {
      throw fail('ERR_OHOS_LEDGER_OWNER', 'Resource token does not belong to this process');
    }
    return entry;
  }
  async function externalPath(path) {
    absolute(path);
    if (inside(directory, path) || inside(directory, await fs.realpath(dirname(path)))) {
      throw fail('ERR_OHOS_LEDGER_RESOURCE', 'Ledger internals cannot be publication resources');
    }
  }
  return Object.freeze({
    ownerId,
    publicationAtomicState,
    reserve(tempPath, finalPath) {
      return enqueue(async () => {
        await externalPath(tempPath); await externalPath(finalPath);
        if (tempPath === finalPath || [...entries.values()].some(entry => entry.path === tempPath)) {
          throw fail('ERR_OHOS_LEDGER_RESOURCE', 'Temporary path is final or already registered');
        }
        const token = randomUUID();
        if (entries.has(token)) throw fail('ERR_OHOS_LEDGER_RESOURCE', 'Resource token collision');
        const next = new Map(entries);
        next.set(token, { token, ownerId, pid: process.pid, path: tempPath, finalPath, state: 'reserved' });
        await persist(next);
        return token;
      });
    },
    identify(token, receipt) {
      return enqueue(async () => {
        const entry = currentEntry(token);
        if (!decimal(receipt?.dev) || !decimal(receipt?.ino)) throw new TypeError('Inode identity must use decimal strings');
        if (entry.state === 'identified') {
          if (!sameIdentity(entry, receipt)) throw fail('ERR_OHOS_LEDGER_RESOURCE', 'Identified resource cannot change inode');
          return;
        }
        await externalPath(entry.path);
        const file = await fs.open(entry.path, constants.O_RDONLY | constants.O_NOFOLLOW);
        try {
          const info = await file.stat({ bigint: true });
          if (!info.isFile() || !sameIdentity(info, receipt)) {
            throw fail('ERR_OHOS_LEDGER_RESOURCE', 'Temporary changed before ownership marking');
          }
          if (setOwnershipMarker(file.fd, token) !== undefined) throw new TypeError('setOwnershipMarker must be synchronous');
          await file.sync();
          const next = new Map(entries);
          next.set(token, { ...entry, state: 'identified', dev: receipt.dev, ino: receipt.ino, marker: token });
          await persist(next);
        } finally { await file.close(); }
      });
    },
    release(token) {
      return enqueue(async () => {
        if (!entries.has(token)) return false;
        const entry = currentEntry(token);
        if (entry.state === 'identified') {
          try {
            lstatSync(entry.path);
            throw fail('ERR_OHOS_LEDGER_RESOURCE_PRESENT', 'Identified temporary still exists; refusing to unregister it');
          } catch (error) { if (error.code !== 'ENOENT') throw error; }
        }
        const next = new Map(entries); next.delete(token);
        await persist(next);
        return true;
      });
    },
    recover() {
      return enqueue(async () => {
        const result = { removed: [], missing: [], unresolved: [] };
        const next = new Map(entries);
        for (const [token, entry] of entries) {
          if (entry.ownerId === ownerId) continue;
          try {
            if (entry.state === 'reserved') {
              try {
                lstatSync(entry.path, { bigint: true });
                result.unresolved.push({ token, path: entry.path, reason: 'reserved-without-inode' });
                continue;
              } catch (error) { if (error.code !== 'ENOENT') throw error; }
              result.missing.push({ token, path: entry.path });
            } else {
              let file;
              try {
                await externalPath(entry.path);
                file = await fs.open(entry.path, constants.O_RDONLY | constants.O_NOFOLLOW);
                const info = await file.stat({ bigint: true });
                if (!info.isFile() || !sameIdentity(info, entry) || getOwnershipMarker(file.fd) !== token) {
                  result.unresolved.push({ token, path: entry.path, reason: 'ownership-marker-or-inode-mismatch' });
                  continue;
                }
                // Keep the validated inode open while checking/unlinking the
                // named entry. Inode numbers may be reused after a process dies;
                // the creation marker is the additional persistent evidence.
                const removed = cleanupOwnedTemporary(entry);
                result[removed.removed ? 'removed' : 'missing'].push({ token, path: entry.path });
              } catch (error) {
                if (error.code !== 'ENOENT') throw error;
                result.missing.push({ token, path: entry.path });
              } finally { if (file) await file.close(); }
            }
            next.delete(token);
          } catch (error) {
            result.unresolved.push({ token, path: entry.path, reason: error.code || error.name });
          }
        }
        if (next.size !== entries.size) await persist(next);
        return result;
      });
    },
    close() {
      if (closePromise) return closePromise;
      closing = true;
      closePromise = queue.then(async () => {
        const failures = [];
        for (const file of [directoryHandle, lock]) {
          try { await file.close(); } catch (error) { failures.push(error); }
        }
        if (failures.length === 1) throw failures[0];
        if (failures.length > 1) throw new AggregateError(failures, 'Ownership ledger close failed');
      });
      return closePromise;
    },
  });
}
