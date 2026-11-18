import { constants } from 'node:fs';
import { open, mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { Readable, Transform } from 'node:stream';
import { createGunzip } from 'node:zlib';
import { createTarDecoder } from '../process/node_modules/modern-tar/dist/web/index.js';

// Installation policy, not platform limits. The decoder may queue input, so
// expandedBytes also bounds its worst-case retained data, including metadata.
export const ARCHIVE_LIMITS = Object.freeze({
  compressedBytes: 64 * 1024 * 1024,
  expandedBytes: 128 * 1024 * 1024,
  fileBytes: 32 * 1024 * 1024,
  manifestBytes: 1024 * 1024,
  entries: 10000,
});
const failure = (code, message) => Object.assign(new Error(message), { code: `ERR_OHOS_PLUGIN_${code}` });
const invalid = message => failure('ARCHIVE_INVALID', message);
const unsupported = message => failure('UNSUPPORTED', message);
const limit = () => failure('ARCHIVE_LIMIT', '插件归档超过本机安装大小或文件数量限制。');

function expectedDigests(integrity) {
  const lengths = { sha256: 32, sha384: 48, sha512: 64 };
  const groups = new Map();
  for (const token of String(integrity ?? '').trim().split(/\s+/)) {
    const split = token.indexOf('-'), algorithm = token.slice(0, split);
    if (!Object.hasOwn(lengths, algorithm)) continue;
    const encoded = token.slice(split + 1);
    const digest = Buffer.from(encoded, 'base64');
    if (digest.length !== lengths[algorithm] || digest.toString('base64') !== encoded) {
      throw failure('INTEGRITY', '插件归档 integrity 摘要格式无效。');
    }
    if (!groups.has(algorithm)) groups.set(algorithm, []);
    groups.get(algorithm).push(digest);
  }
  for (const algorithm of ['sha512', 'sha384', 'sha256']) {
    if (groups.has(algorithm)) return { algorithm, digests: groups.get(algorithm) };
  }
  throw failure('INTEGRITY', '插件归档缺少受支持的 SHA-256/384/512 integrity。');
}

function entryPath(header) {
  const name = header.name;
  if (name.includes('\0') || name.includes('\\') || !name.startsWith('package/')) throw invalid('插件归档路径越界。');
  const relative = name.slice(8).replace(/\/$/, '');
  if (relative === '' && header.type === 'directory') return '';
  const parts = relative.split('/');
  if (parts.some(part => part === '' || part === '.' || part === '..')) throw invalid('插件归档路径无效。');
  if (parts.includes('node_modules')) throw unsupported('插件归档内置 node_modules，无法核对锁定依赖；请发布不含内置依赖的纯 JS 包。');
  if (parts.some(part => part.endsWith('.node') || part.endsWith('.wasm') || part === 'binding.gyp')) {
    throw unsupported('插件包含原生 addon、binding.gyp 或 WebAssembly；鸿蒙本机仅支持纯 JS 包。');
  }
  return relative;
}

const binaryMagic = new Set([
  '7f454c46', '0061736d', // ELF and WebAssembly.
  'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', // Mach-O, both byte orders.
  'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca', // Universal Mach-O (32/64).
]);
async function rejectBinary(file, size) {
  const prefix = Buffer.alloc(64);
  await file.read(prefix, 0, Math.min(size, prefix.length), 0);
  let binary = size >= 4 && binaryMagic.has(prefix.subarray(0, 4).toString('hex'));
  if (!binary && size >= 64 && prefix[0] === 0x4d && prefix[1] === 0x5a) {
    const offset = prefix.readUInt32LE(0x3c);
    // MZ alone also occurs in ordinary text. Require an in-file PE/COFF header,
    // PE32/PE32+ optional header and section table before classifying the image.
    if (offset >= 64 && offset <= size - 26) {
      const pe = Buffer.alloc(26);
      await file.read(pe, 0, pe.length, offset);
      const sections = pe.readUInt16LE(6), optionalBytes = pe.readUInt16LE(20);
      binary = pe.readUInt32LE(0) === 0x00004550 && pe.readUInt16LE(4) !== 0 && sections > 0 &&
        optionalBytes >= 2 && [0x10b, 0x20b].includes(pe.readUInt16LE(24)) &&
        offset + 24 + optionalBytes + sections * 40 <= size;
    }
  }
  if (binary) throw unsupported('插件文件包含 ELF、Mach-O、PE 或 WebAssembly 二进制；鸿蒙本机仅支持纯 JS 包。');
}

/** Extract one locked package into a newly owned directory; never publish or execute it. */
export async function extractPackage({ archivePath, integrity, stagingRoot, name, version, signal }) {
  signal?.throwIfAborted();
  const { algorithm, digests } = expectedDigests(integrity);
  const file = await open(archivePath, constants.O_RDONLY | constants.O_NOFOLLOW);
  let directory, input, pipe, pipeError;
  const controller = new AbortController();
  const abort = () => controller.abort(signal.reason);
  signal?.addEventListener('abort', abort, { once: true });
  try {
    signal?.throwIfAborted();
    const stat = await file.stat();
    if (!stat.isFile()) throw invalid('插件归档必须是普通文件。');
    if (stat.size > ARCHIVE_LIMITS.compressedBytes) throw limit();
    const hash = createHash(algorithm);
    let compressed = 0;
    for await (const chunk of file.createReadStream({ start: 0, autoClose: false, signal })) {
      compressed += chunk.length;
      if (compressed > ARCHIVE_LIMITS.compressedBytes) throw limit();
      hash.update(chunk);
    }
    const actual = hash.digest();
    if (!digests.some(digest => digest.equals(actual))) throw failure('INTEGRITY', '插件归档 integrity 校验失败。');
    signal?.throwIfAborted();
    directory = await mkdtemp(join(stagingRoot, '.package-'));
    const decoder = createTarDecoder({ strict: true });
    let expanded = 0;
    const counter = new Transform({ transform(chunk, encoding, callback) {
      expanded += chunk.length;
      callback(expanded > ARCHIVE_LIMITS.expandedBytes ? limit() : null, chunk);
    } });
    input = file.createReadStream({ start: 0, autoClose: false, signal: controller.signal });
    const gunzip = createGunzip();
    // Propagate errors in both directions; destroy this private pipeline on any failure.
    input.on('error', error => gunzip.destroy(error));
    gunzip.on('error', error => counter.destroy(error));
    counter.on('error', () => { input.destroy(); gunzip.destroy(); });
    const source = input.pipe(gunzip).pipe(counter);
    pipe = Readable.toWeb(source).pipeTo(decoder.writable, { signal: controller.signal })
      .catch(error => { pipeError = error; });
    const entries = new Set();
    let count = 0;
    for await (const { header, body } of decoder.readable) {
      signal?.throwIfAborted();
      if (++count > ARCHIVE_LIMITS.entries) throw limit();
      if (!['file', 'directory'].includes(header.type)) throw unsupported('插件归档不支持链接、设备或管道条目。');
      if (Object.keys(header.pax ?? {}).some(key => key.startsWith('GNU.sparse.'))) throw unsupported('插件归档不支持 GNU sparse 文件。');
      const relative = entryPath(header);
      if (relative === '') continue;
      if (!Number.isSafeInteger(header.size) || header.size < 0) throw invalid('插件文件长度无效。');
      if (header.size > ARCHIVE_LIMITS.fileBytes || (relative === 'package.json' && header.size > ARCHIVE_LIMITS.manifestBytes)) throw limit();
      const destination = join(directory, relative);
      if (header.type === 'directory') {
        await mkdir(destination, { recursive: true, mode: 0o700 });
        continue;
      }
      if (entries.has(relative)) throw invalid('插件归档包含重复文件。');
      entries.add(relative);
      await mkdir(join(destination, '..'), { recursive: true, mode: 0o700 });
      const output = await open(destination, constants.O_RDWR | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      try {
        let written = 0;
        for await (const chunk of body) {
          signal?.throwIfAborted();
          written += chunk.length;
          if (written > header.size) throw invalid('插件文件长度与归档不符。');
          await output.writeFile(chunk);
        }
        if (written !== header.size) throw invalid('插件文件已截断。');
        await rejectBinary(output, written);
      } finally { await output.close(); }
    }
    await pipe;
    if (pipeError) throw pipeError;
    signal?.throwIfAborted();
    const manifestText = await readFile(join(directory, 'package.json'), 'utf8');
    // Match Node's package reader: npm archives can preserve one leading UTF-8 BOM.
    const manifest = JSON.parse(manifestText.replace(/^\uFEFF/, ''));
    if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest) || manifest.name !== name || manifest.version !== version) {
      throw invalid('插件 package.json 的名称或版本与锁定版本不符。');
    }
    if (manifest.gypfile === true) throw unsupported('插件需要 node-gyp 原生构建，鸿蒙本机仅支持纯 JS 包。');
    if (['preinstall', 'install', 'postinstall'].some(key => Object.hasOwn(manifest.scripts ?? {}, key))) {
      throw unsupported('插件需要安装生命周期脚本；鸿蒙本机不会运行这些脚本，请使用预构建的纯 JS 包。');
    }
    return { directory, manifest };
  } catch (error) {
    controller.abort(error);
    input?.destroy();
    await pipe;
    if (directory) {
      try { await rm(directory, { recursive: true, force: true }); }
      catch (cleanupError) { throw new AggregateError([error, cleanupError], '插件解包失败且临时目录清理失败。', { cause: error }); }
    }
    throw error;
  } finally {
    signal?.removeEventListener('abort', abort);
    await file.close();
  }
}
