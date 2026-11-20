// Internal private staging only: no media validation, publication, index or Session effects.
import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { lookup as dnsLookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import { constants } from 'node:fs';
import { open, lstat, realpath, unlink } from 'node:fs/promises';
import { join, isAbsolute, dirname } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { parseMediaUrl, isPublicAddress } from './http.js';
import { MediaError, checkAbort, fail } from './errors.js';

export const MAX_STAGED_DOWNLOAD_BYTES = 300 * 1024 * 1024;
const same = (a, b) => typeof a?.ino === 'bigint' && a.ino !== 0n && a.dev === b?.dev && a.ino === b?.ino;
function abortable(promise, signal) {
  checkAbort(signal);
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason);
    signal.addEventListener('abort', abort, { once: true });
    promise.then(resolve, reject).finally(() => signal.removeEventListener('abort', abort)).catch(() => {});
    if (signal.aborted) abort();
  });
}

// Classify only calls to the local file handle, not HTTP/response failures.
async function storageOperation(operation) {
  try {
    return await operation;
  } catch (error) {
    throw error instanceof MediaError ? error : new MediaError('storage');
  }
}

/** Bounded sequential writes; exported solely for internal reuse/partial-write regression. */
export async function writeStagedChunk(handle, chunk, hash, signal) {
  let offset = 0;
  while (offset < chunk.length) {
    checkAbort(signal);
    const { bytesWritten } = await storageOperation(handle.write(chunk, offset, chunk.length - offset, null));
    if (!Number.isInteger(bytesWritten) || bytesWritten <= 0 || bytesWritten > chunk.length - offset) fail('storage');
    hash.update(chunk.subarray(offset, offset + bytesWritten));
    offset += bytesWritten;
  }
}

/** Factory test option permits only literal loopback HTTP, never a hostname resolving to loopback. */
export function createStreamStager({ allowLoopback = false, lookup = dnsLookup } = {}) {
  return async function stageDownload(urlValue, { directory, maxBytes = MAX_STAGED_DOWNLOAD_BYTES, timeoutMs = 120_000, signal, ownDownload } = {}) {
    if (typeof urlValue !== 'string' || typeof directory !== 'string' || !isAbsolute(directory) || !Number.isSafeInteger(maxBytes) || maxBytes < 1 || maxBytes > MAX_STAGED_DOWNLOAD_BYTES
      || !Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 1_800_000) fail('invalid_request');
    checkAbort(signal);
    const url = parseMediaUrl(urlValue, { allowLoopback });
    const host = url.hostname.replace(/^\[/, '').replace(/\]$/, '');
    const control = new AbortController();
    const abort = () => control.abort(new MediaError('cancelled'));
    signal?.addEventListener('abort', abort, { once: true });
    const timer = setTimeout(() => control.abort(new MediaError('timeout')), timeoutMs);
    let handle, directoryHandle, identity, dirIdentity, path, req, response, created = false, success = false;
    const active = () => { if (control.signal.aborted) throw control.signal.reason; };
    async function guardDirectory() {
      active();
      const current = await lstat(directory, { bigint: true });
      if (!current.isDirectory() || current.isSymbolicLink() || !same(current, dirIdentity) || await realpath(directory) !== directory) fail('permission');
      active();
    }
    async function guardFile() {
      await guardDirectory();
      const current = await lstat(path, { bigint: true });
      if (!current.isFile() || current.isSymbolicLink() || !same(current, identity)) fail('storage');
      active();
    }
    async function removeOwn() {
      if (!created) return true;
      // Never unlink through a replaced parent or remove a foreign inode.
      try {
        let parent;
        try { parent = await lstat(directory, { bigint: true }); } catch { return false; }
        if (!same(parent, dirIdentity) || !parent.isDirectory() || parent.isSymbolicLink() || await realpath(directory) !== directory) return false;
        const current = await lstat(path, { bigint: true });
        if (!identity || !same(current, identity) || !current.isFile() || current.isSymbolicLink()) return false;
        await unlink(path);
        await directoryHandle.sync();
        return true;
      } catch (error) { return error?.code === 'ENOENT'; }
    }
    try {
      dirIdentity = await lstat(directory, { bigint: true });
      if (!dirIdentity.isDirectory() || dirIdentity.isSymbolicLink() || await realpath(directory) !== directory) fail('permission');
      directoryHandle = await open(directory, constants.O_RDONLY | (constants.O_DIRECTORY ?? 0));
      if (!same(await directoryHandle.stat({ bigint: true }), dirIdentity)) fail('permission');
      // Probe/sync even an existing directory. Existence is not a durability receipt.
      await storageOperation(directoryHandle.sync());
      // The installed Direct root already has a durability barrier. Repair every
      // ancestor below it, including entries another creator left unsynced.
      // Paths outside that root retain the full filesystem-root barrier.
      const directRoot = globalThis[Symbol.for('dsh.go.direct')]?.root;
      for (let ancestor = directory; ancestor !== directRoot && dirname(ancestor) !== ancestor;) {
        ancestor = dirname(ancestor);
        const parent = await storageOperation(open(ancestor, constants.O_RDONLY | (constants.O_DIRECTORY ?? 0)));
        try {
          await storageOperation(parent.sync());
        } finally {
          await storageOperation(parent.close());
        }
        active();
      }
      await guardDirectory();
      const literal = isIP(host);
      const addresses = literal ? [{ address: host, family: literal }]
        : await abortable(Promise.resolve().then(() => lookup(host, { all: true, verbatim: true })), control.signal);
      active();
      if (!Array.isArray(addresses) || !addresses.length || addresses.some(entry => {
        if (allowLoopback && ['127.0.0.1', '::1'].includes(entry.address)) return !literal;
        return !isPublicAddress(entry.address);
      })) fail('unsafe_url');
      const selected = addresses[0];
      await guardDirectory();
      path = join(directory, '.media-download-' + randomUUID() + '.part');
      handle = await storageOperation(open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600));
      created = true;
      identity = await handle.stat({ bigint: true });
      await guardFile();
      response = await new Promise((resolve, reject) => {
        const send = url.protocol === 'https:' ? httpsRequest : httpRequest;
        req = send(url, { method: 'GET', headers: { 'Accept-Encoding': 'identity' }, agent: false,
          family: 0, servername: literal ? undefined : host, autoSelectFamily: true,
          maxHeaderSize: 16384, signal: control.signal,
          lookup: (_hostname, options, callback) => {
            if (typeof options === 'function') { callback = options; options = {}; }
            callback(null, options?.all ? addresses : selected.address, selected.family);
          },
        }, resolve);
        req.on('error', reject);
        req.on('upgrade', (_res, socket) => { socket.destroy(); reject(new MediaError('response')); });
        req.on('connect', (_res, socket) => { socket.destroy(); reject(new MediaError('response')); });
        req.end();
      });
      active();
      if (response.statusCode !== 200 || (response.headers['content-encoding'] && response.headers['content-encoding'] !== 'identity')) fail('response');
      const declared = response.headers['content-length'];
      if (declared !== undefined && (!/^\d+$/.test(declared) || Number(declared) > maxBytes)) fail('too_large');
      const hash = createHash('sha256');
      let bytes = 0;
      for await (const chunk of response) {
        active();
        if (chunk.length > maxBytes - bytes) fail('too_large');
        await writeStagedChunk(handle, chunk, hash, control.signal);
        bytes += chunk.length;
      }
      active();
      if (!response.complete || bytes === 0 || (declared !== undefined && bytes !== Number(declared))) fail('response');
      await guardFile();
      await storageOperation(handle.sync());
      await storageOperation(handle.close());
      handle = undefined;
      await storageOperation(directoryHandle.sync());
      await guardFile();
      const receipt = { kind: 'private-download', path, bytes, sha256: hash.digest('hex') };
      // Keep cleanup ownership and the directory handle until the store accepts
      // this download. Cancellation or a failed claim must not orphan its file.
      await ownDownload?.(receipt);
      active();
      // Close failures are not silently turned into a successful receipt.
      await storageOperation(directoryHandle.close());
      directoryHandle = undefined;
      active();
      success = true;
      return receipt;
    } catch (error) {
      req?.destroy(); response?.destroy();
      try { await handle?.close(); handle = undefined; } catch { /* removal still required */ }
      if (!await removeOwn()) throw new MediaError('cleanup_failed');
      if (control.signal.aborted) throw control.signal.reason;
      throw error instanceof MediaError ? error : new MediaError('network');
    } finally {
      clearTimeout(timer); signal?.removeEventListener('abort', abort);
      if (!success) { req?.destroy(); response?.destroy(); }
      await handle?.close().catch(() => {});
      await directoryHandle?.close().catch(() => {});
    }
  };
}
