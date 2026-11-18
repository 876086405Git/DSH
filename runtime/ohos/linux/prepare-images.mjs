import { constants, createReadStream, createWriteStream } from 'node:fs';
import { mkdir, mkdtemp, open, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join, isAbsolute } from 'node:path';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { createGunzip } from 'node:zlib';

const error = code => Object.assign(new Error(code === 'ERR_OHOS_LINUX_IMAGE_MANIFEST'
  ? 'Linux image preparation requires pinned asset identities and private absolute paths'
  : 'Linux image bytes do not match their pinned identity'), { code });
const valid = (bytes, sha) => Number.isSafeInteger(bytes) && bytes > 0 && /^[a-f0-9]{64}$/.test(sha);
const source = path => createReadStream(path, { flags: constants.O_RDONLY | constants.O_NOFOLLOW });
function checking(bytes, sha, progress = () => {}) {
  const hash = createHash('sha256');
  let done = 0;
  return new Transform({
    transform(chunk, _encoding, callback) {
      try {
        done += chunk.length;
        if (done > bytes) throw error('ERR_OHOS_LINUX_IMAGE_INTEGRITY');
        hash.update(chunk); progress(done); callback(null, chunk);
      } catch (cause) { callback(cause); }
    },
    flush(callback) {
      callback(done !== bytes || hash.digest('hex') !== sha ? error('ERR_OHOS_LINUX_IMAGE_INTEGRITY') : null);
    },
  });
}

// HAP-build-time seeds are plain gzip-compressed disk files. No tar extraction,
// links, executable tools or guest code run in the App's host filesystem.
export async function prepareLinuxImages({ directory, bootstrap, empty, archive, signal, onProgress = () => {} }) {
  if (!isAbsolute(directory) || [bootstrap, empty, archive].some(item =>
    !item || !isAbsolute(item.path) || !valid(item.bytes, item.sha256)) ||
    [bootstrap, empty].some(item => !valid(item.expandedBytes, item.expandedSha256)) ||
    archive.bytes > Number.MAX_SAFE_INTEGER - 511) throw error('ERR_OHOS_LINUX_IMAGE_MANIFEST');
  signal?.throwIfAborted();
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const staging = await mkdtemp(join(directory, '.prepare-'));
  try {
    const paths = { bootstrap: join(staging, 'bootstrap.ext4'), target: join(staging, 'target.ext4'), archive: join(staging, 'archive.block') };
    for (const [stage, item] of [['bootstrap', bootstrap], ['target', empty]]) {
      signal?.throwIfAborted();
      await pipeline(source(item.path), checking(item.bytes, item.sha256), createGunzip(),
        checking(item.expandedBytes, item.expandedSha256, done => onProgress({ stage, done, total: item.expandedBytes })),
        createWriteStream(paths[stage], { flags: 'wx', mode: 0o600 }), { signal });
    }
    await pipeline(source(archive.path), checking(archive.bytes, archive.sha256,
      done => onProgress({ stage: 'archive', done, total: archive.bytes })),
      createWriteStream(paths.archive, { flags: 'wx', mode: 0o600 }), { signal });
    const block = await open(paths.archive, 'r+');
    try { await block.truncate(Math.ceil(archive.bytes / 512) * 512); }
    finally { await block.close(); }
    signal?.throwIfAborted();
    // Ownership passes to the caller, which must retain it while the VM uses
    // these files. Prepared images are not an installed environment or READY.
    return { state: 'prepared-images', directory: staging, ...paths };
  } catch (cause) {
    await rm(staging, { recursive: true, force: true });
    throw cause;
  }
}
