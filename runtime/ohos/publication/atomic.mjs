import { lstatSync, unlinkSync } from 'node:fs';
import * as promises from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { dirname, isAbsolute, join, resolve } from 'node:path';

const linkFallbackCodes = new Set(['EACCES', 'EPERM', 'EXDEV', 'ENOTSUP', 'EMLINK']);
const identityOf = info => ({ dev: String(info.dev), ino: String(info.ino) });
const sameIdentity = (info, receipt) => String(info.dev) === receipt.dev && String(info.ino) === receipt.ino;
const requirePath = (path, label) => {
  if (typeof path !== 'string' || !isAbsolute(path) || path.includes('\0')) {
    throw new TypeError(`${label} must be an absolute path without NUL`);
  }
  return resolve(path);
};

/**
 * Remove only one explicitly owned temporary entry. A receipt is a trusted
 * caller record, not proof obtainable by scanning a filename prefix.
 * The identity check and unlink share one JS turn. This assumes the application
 * owns this private directory; it is not an atomic compare-inode-and-unlink
 * operation against arbitrary concurrent native/foreign writers.
 */
export function cleanupOwnedTemporary(receipt) {
  requirePath(receipt.path, 'temporary path');
  let info;
  try { info = lstatSync(receipt.path, { bigint: true }); }
  catch (error) {
    if (error.code === 'ENOENT') return { removed: false, absent: true };
    throw error;
  }
  if (!info.isFile() || !sameIdentity(info, receipt)) {
    throw Object.assign(new Error('Owned publication temporary was replaced; refusing to unlink it'),
      { code: 'ERR_OHOS_PUBLICATION_TEMP_REPLACED' });
  }
  unlinkSync(receipt.path);
  return { removed: true, absent: false };
}

const chooseTemporaryPath = ({ parent }) => join(parent, `.dsh-ohos-publish-${randomUUID()}.tmp`);

async function copyStream(input, output, signal) {
  const buffer = Buffer.allocUnsafe(65536);
  for (;;) {
    signal?.throwIfAborted();
    const { bytesRead } = await input.read(buffer, 0, buffer.length, null);
    if (bytesRead === 0) break;
    await output.writeFile(buffer.subarray(0, bytesRead));
  }
  signal?.throwIfAborted();
  await output.sync();
}

// This is deliberately the existing risky fallback: a partial final file may
// remain after failure/SIGKILL. The guarded product also uses it when an earlier
// EINVAL or unfinished trial has durably disabled the native commit.
async function legacyExclusiveCopy(source, target, fs, signal) {
  const input = await fs.open(source, 'r');
  try {
    const output = await fs.open(target, 'wx', 0o600);
    try { await copyStream(input, output, signal); }
    finally { await output.close(); }
  } finally { await input.close(); }
}

/**
 * Build a publisher for one main Node engine. The native function must invoke
 * renameat2(..., RENAME_NOREPLACE), synchronously returning undefined or throwing
 * a system error. No plain rename/copy is a native fallback.
 *
 * The ledger is mandatory: reserve must durably finish before open('wx'), and
 * identify must durably finish before the first write. A crash after creation
 * but before identification leaves an explicitly unresolved reservation. Never
 * infer ownership from a filename or delete a reserved-but-unidentified file.
 * selectTemporaryPath only selects a path; this core owns exclusive creation.
 */
export function createAtomicPublisher({
  renameNoReplace,
  ledger,
  atomicFuse,
  fs = promises,
  selectTemporaryPath = chooseTemporaryPath,
  onFallback = () => {},
} = {}) {
  if (typeof renameNoReplace !== 'function') throw new TypeError('renameNoReplace is required');
  if (!ledger || ['reserve', 'identify', 'release'].some(name => typeof ledger[name] !== 'function')) {
    throw new TypeError('A durable ownership ledger with reserve, identify and release is required');
  }
  if (typeof selectTemporaryPath !== 'function') throw new TypeError('selectTemporaryPath must be a function');
  if (atomicFuse !== undefined && typeof atomicFuse?.run !== 'function') throw new TypeError('Invalid publication atomic fuse');
  const publications = new Map();
  const publish = async function publish(source, target, { signal, fs: callFs, requireAtomic = false } = {}) {
    source = requirePath(source, 'source');
    target = requirePath(target, 'target');
    const activeFs = callFs ? { ...fs, ...callFs } : fs;
    const previous = publications.get(target);
    const completed = Promise.withResolvers();
    publications.set(target, completed.promise);
    if (previous) await previous;
    let input, output, path, token, receipt, method, failure;
    try {
      signal?.throwIfAborted();
      try {
        await activeFs.link(source, target);
        return { method: 'link' };
      } catch (error) {
        if (!linkFallbackCodes.has(error?.code)) throw error;
      }
      input = await activeFs.open(source, 'r');
      for (let attempt = 0; attempt < 32; attempt++) {
        path = requirePath(await selectTemporaryPath({ parent: dirname(target), source, target, attempt }), 'temporary');
        if (dirname(path) !== dirname(target) || path === target || path === source) {
          throw new Error('Publication temporary must be a distinct entry in the final target directory');
        }
        token = await ledger.reserve(path, target);
        if (typeof token !== 'string' || token.length === 0 || token.includes('\0')) {
          throw new TypeError('Ownership ledger reserve must return a nonempty token');
        }
        try {
          output = await activeFs.open(path, 'wx', 0o600);
          break;
        } catch (error) {
          if (error?.code !== 'EEXIST') throw error;
          // wx did not create this entry. Preserve it and remove only our
          // reservation, before selecting another candidate.
          await ledger.release(token);
          token = undefined;
          path = undefined;
        }
      }
      if (!output) {
        throw Object.assign(new Error('Could not allocate an exclusive publication temporary'),
          { code: 'ERR_OHOS_PUBLICATION_TEMP_COLLISION' });
      }
      const info = await output.stat({ bigint: true });
      if (!info.isFile()) throw new Error('Publication temporary must be a regular file');
      receipt = { path, ...identityOf(info) };
      if (BigInt(info.size) !== 0n) throw new Error('Publication temporary must be newly allocated and empty');
      await ledger.identify(token, identityOf(info));
      await copyStream(input, output, signal);
      signal?.throwIfAborted();
      const beforeCommit = () => {
        signal?.throwIfAborted();
        // The fuse invokes this check immediately before the synchronous native
        // call, after its persistent trial marker; no await separates the two.
        const current = lstatSync(path, { bigint: true });
        if (!current.isFile() || !sameIdentity(current, receipt)) {
          throw Object.assign(new Error('Publication temporary changed before atomic commit'),
            { code: 'ERR_OHOS_PUBLICATION_TEMP_REPLACED' });
        }
      };
      let fallback;
      if (atomicFuse) {
        const outcome = await atomicFuse.run(() => renameNoReplace(path, target), { beforeCommit });
        if (outcome?.atomic === true) method = 'rename-noreplace';
        else if (outcome?.atomic === false && ['unsupported', 'disabled-after-crash'].includes(outcome.reason)) {
          fallback = { reason: outcome.reason };
        } else throw new TypeError('Invalid publication atomic fuse result');
      } else {
        // Kept for isolated factory tests; production install always supplies
        // the durable fuse. This path retains the previously reviewed contract.
        beforeCommit();
        try {
          const result = renameNoReplace(path, target);
          if (result !== undefined) throw new TypeError('renameNoReplace must be synchronous and return undefined');
          method = 'rename-noreplace';
        } catch (error) {
          if (error?.code !== 'EINVAL' || error?.syscall !== 'renameat2') throw error;
          fallback = { code: error.code, syscall: error.syscall, reason: 'unsupported' };
        }
      }
      if (fallback) {
        // Durable control records cannot safely use a partial final file.
        if (requireAtomic) throw Object.assign(new Error('Atomic no-replace publication is required'),
          { code: 'ERR_OHOS_PUBLICATION_ATOMIC_REQUIRED', reason: fallback.reason });
        await onFallback({ ...fallback,
          risk: 'partial final file remains possible after failure or process death' });
        await legacyExclusiveCopy(source, target, activeFs, signal);
        method = 'exclusive-copy-fallback';
      }
    } catch (error) { failure = error; }
    finally {
      const failures = failure === undefined ? [] : [failure];
      let cleared = false;
      if (token !== undefined) {
        try {
          if (receipt) {
            // Keep the opened inode alive until the identity check/unlink has
            // completed; closing first would permit inode-number reuse.
            cleanupOwnedTemporary(receipt);
            cleared = true;
          } else {
            try { lstatSync(path, { bigint: true }); }
            catch (error) {
              if (error.code !== 'ENOENT') throw error;
              cleared = true;
            }
            if (!cleared) throw Object.assign(new Error('Unidentified publication temporary is preserved with its ledger reservation'),
              { code: 'ERR_OHOS_PUBLICATION_TEMP_UNIDENTIFIED' });
          }
        } catch (error) { failures.push(error); }
      }
      for (const handle of [output, input]) if (handle) {
        try { await handle.close(); } catch (error) { failures.push(error); }
      }
      if (token !== undefined && cleared) {
        try { await ledger.release(token); } catch (error) { failures.push(error); }
      }
      completed.resolve();
      if (publications.get(target) === completed.promise) publications.delete(target);
      if (failures.length === 1) throw failures[0];
      if (failures.length > 1) throw new AggregateError(failures, 'Publication failed and cleanup reported an additional error', { cause: failures[0] });
    }
    return { method };
  };
  return Object.defineProperty(publish, 'pendingCount', { get: () => publications.size });
}
