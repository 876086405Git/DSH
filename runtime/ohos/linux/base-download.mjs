import { createFetch } from '../net/fetch.mjs';
import { createHttpDispatcher } from '../net/dispatcher.mjs';
import { constants } from 'node:fs';
import { mkdir, mkdtemp, open, rename, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isAbsolute, join } from 'node:path';

const fetchImage = createFetch(createHttpDispatcher());

const failure = (code, message) => Object.assign(new Error(message), { code });
const integrity = () => failure('ERR_OHOS_LINUX_IMAGE_INTEGRITY', 'Linux image length or SHA256 does not match the pinned manifest');

async function verify(path, artifact, signal) {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size !== artifact.bytes) throw integrity();
    const hash = createHash('sha256');
    const buffer = Buffer.allocUnsafe(64 * 1024);
    for (;;) {
      signal?.throwIfAborted();
      const { bytesRead } = await file.read(buffer, 0, buffer.length, null);
      if (!bytesRead) break;
      hash.update(buffer.subarray(0, bytesRead));
    }
    if (hash.digest('hex') !== artifact.sha256) throw integrity();
  } finally { await file.close(); }
}

// Caller supplies a trusted, pinned build manifest and an App-private directory.
// A verified base is data only: this does not install, boot or mark Linux READY.
export async function downloadLinuxBase({ directory, artifact, signal, onProgress = () => {} }, internals = {}) {
  let url;
  try { url = new URL(artifact.url); } catch { /* validated below */ }
  if (!url || url.protocol !== 'https:' || url.username || url.password || url.hash ||
      !Number.isSafeInteger(artifact.bytes) || artifact.bytes <= 0 || !/^[a-f0-9]{64}$/.test(artifact.sha256) ||
      !isAbsolute(directory)) {
    throw failure('ERR_OHOS_LINUX_IMAGE_MANIFEST', 'A pinned HTTPS image URL, byte length, SHA256 and private absolute directory are required');
  }
  signal?.throwIfAborted();
  const request = internals.fetch ?? fetchImage;
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const destination = join(directory, artifact.sha256);
  const path = join(destination, 'base.bin');
  try {
    await verify(path, artifact, signal);
    signal?.throwIfAborted();
    onProgress({ stage: 'verified', done: artifact.bytes, total: artifact.bytes });
    return { state: 'verified-base', path, sha256: artifact.sha256 };
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const staging = await mkdtemp(join(directory, '.download-'));
  try {
    const response = await request(url.href, { headers: { 'user-agent': 'dsh-go-ohos-linux/1' }, signal, redirect: 'error' });
    if (!response.ok || !response.body) {
      await response.body?.cancel();
      throw failure('ERR_OHOS_LINUX_DOWNLOAD', `Linux image download failed (HTTP ${response.status})`);
    }
    let file;
    const reader = response.body.getReader();
    let done = 0;
    const hash = createHash('sha256');
    try {
      file = await open(join(staging, 'base.bin'), 'wx', 0o600);
      onProgress({ stage: 'download', done, total: artifact.bytes });
      for (;;) {
        signal?.throwIfAborted();
        const next = await reader.read();
        if (next.done) break;
        const chunk = next.value;
        signal?.throwIfAborted();
        done += chunk.byteLength;
        if (done > artifact.bytes) throw integrity();
        hash.update(chunk);
        let offset = 0;
        while (offset < chunk.byteLength) {
          const { bytesWritten } = await file.write(chunk, offset, chunk.byteLength - offset);
          offset += bytesWritten;
        }
        onProgress({ stage: 'download', done, total: artifact.bytes });
      }
      signal?.throwIfAborted();
      if (done !== artifact.bytes || hash.digest('hex') !== artifact.sha256) throw integrity();
      await file.sync();
    } finally {
      // Cancel on disk/progress failure too; an already failed stream may reject
      // cancellation, which must not replace the original transfer error.
      await reader.cancel().catch(() => {});
      reader.releaseLock();
      await file?.close();
    }
    signal?.throwIfAborted();
    try { await rename(staging, destination); }
    catch (error) {
      // Concurrent preparation may publish the same pinned base first.
      if (!['EEXIST', 'ENOTEMPTY'].includes(error.code)) throw error;
      await verify(path, artifact, signal);
    }
    onProgress({ stage: 'verified', done, total: artifact.bytes });
    return { state: 'verified-base', path, sha256: artifact.sha256 };
  } finally { await rm(staging, { recursive: true, force: true }); }
}
