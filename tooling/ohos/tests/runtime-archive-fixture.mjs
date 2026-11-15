import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { crc32, deflateRawSync } from 'node:zlib';

const require = createRequire(import.meta.url);
const backend = require(process.env.OHOS_TEST_ZLIB_ADDON);
export const observation = {
  reads: 0, readBytes: 0, maxRead: 0, writes: 0, writeBytes: 0,
  opens: 0, closes: 0, inflates: 0, initialized: 0, ended: 0,
  fd: new Set(), maxInput: 0, maxOutput: 0, beforeRead: null, beforeWrite: null,
  maxReadChunk: Infinity, maxWriteChunk: Infinity, failEnd: 0,
};
export function resetObservation() {
  for (const key of ['reads','readBytes','maxRead','writes','writeBytes','opens','closes','inflates','initialized','ended','maxInput','maxOutput']) observation[key] = 0;
  observation.beforeRead = null; observation.beforeWrite = null;
  observation.maxReadChunk = Infinity; observation.maxWriteChunk = Infinity;
}

export const fileIo = {
  OpenMode: { CREATE: fs.constants.O_CREAT, READ_WRITE: fs.constants.O_RDWR, TRUNC: fs.constants.O_TRUNC,
    NOFOLLOW: fs.constants.O_NOFOLLOW, READ_ONLY: fs.constants.O_RDONLY, DIR: fs.constants.O_DIRECTORY },
  async access(name) { try { await fsp.access(name); return true; } catch (e) { if (['ENOENT','ENOTDIR'].includes(e.code)) return false; throw e; } },
  lstat: fsp.lstat, rename: fsp.rename, unlink: fsp.unlink,
  async mkdir(name) { try { await fsp.mkdir(name); } catch (e) { if (e.code === 'EEXIST') e.code = 13900015; throw e; } },
  readText: name => fsp.readFile(name, 'utf8'),
  async open(name, flags) { const handle = await fsp.open(name, flags, 0o600); observation.fd.add(handle.fd); return { fd: handle.fd, handle }; },
  async close(file) { await file.handle.close(); observation.fd.delete(file.fd); },
  async fsync(fd) { await promisify(fs.fsync)(fd); },
  async read(fd, arrayBuffer, options) {
    if (observation.beforeRead) await observation.beforeRead(fd, options);
    const length = Math.min(options.length ?? arrayBuffer.byteLength, observation.maxReadChunk);
    const {bytesRead} = await promisify(fs.read)(fd, Buffer.from(arrayBuffer), 0, length, options.offset);
    observation.reads++; observation.readBytes += bytesRead; observation.maxRead = Math.max(observation.maxRead, arrayBuffer.byteLength);
    return bytesRead;
  },
  async write(fd, arrayBuffer, options) {
    if (observation.beforeWrite) await observation.beforeWrite(fd, arrayBuffer, options);
    const {bytesWritten} = await promisify(fs.write)(fd, Buffer.from(arrayBuffer), 0,
      Math.min(arrayBuffer.byteLength, observation.maxWriteChunk), options.offset);
    observation.writes++; observation.writeBytes += bytesWritten; return bytesWritten;
  },
  async listFile(name, options) { return (await fsp.readdir(name)).slice(0, options.listNum || undefined); },
  // The public OH rmdir can recursively delete. Preserve this stronger behavior
  // in the fixture so the product must check that an owned directory is empty.
  async rmdir(name) { await fsp.rm(name, { recursive: true }); },
};
export const fileHash = {
  async hash(name, algorithm) {
    const hash = createHash(algorithm);
    for await (const chunk of createReadStream(name)) hash.update(chunk);
    return hash.digest('hex');
  },
};
export const util = {
  TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
  TextDecoder: class { static create(encoding, options) { const decoder = new TextDecoder(encoding, options); return { decodeToString: bytes => decoder.decode(bytes) }; } },
};

export const nativeZlib = {
  ReturnStatus: { OK: 0, STREAM_END: 1, NEED_DICT: 2 }, CompressFlushMode: { NO_FLUSH: 0 },
  async createZip() {
    const handle = backend.create();
    return {
      async inflateInit2(stream, bits) { const result = backend.init(handle, stream, bits); observation.initialized++; return result; },
      async inflate(stream, flush) {
        observation.inflates++;
        observation.maxInput = Math.max(observation.maxInput, stream.nextIn?.byteLength ?? 0);
        observation.maxOutput = Math.max(observation.maxOutput, stream.nextOut?.byteLength ?? 0);
        // Like the official NAPI, update only the native stream, never the JS
        // request object. Returning that object's counters would make tests fail.
        return backend.inflate(handle, stream, flush);
      },
      async getZStream() { return backend.state(handle); },
      async inflateEnd(stream) {
        if (observation.failEnd > 0) { observation.failEnd--; throw Object.assign(new Error('injected inflateEnd failure'), {code:17800004}); }
        const result = backend.end(handle, stream); observation.ended++; return result;
      },
    };
  },
};
export function activeInflaters() { return backend.active(); }
export function nativeZlibVersion() { return backend.version(); }

export class ArchiveResources {
  constructor(name, offset, length) { this.name = name; this.offset = offset; this.length = length; this.opened = null; this.assets = []; this.failClose = 0; }
  async getRawFd(asset) {
    if (asset !== 'dsh-runtime/runtime.zip') throw new Error(`unexpected rawfile: ${asset}`);
    if (this.opened !== null) throw new Error('fixture: overlapping raw descriptor');
    this.opened = await fsp.open(this.name, 'r'); observation.opens++; this.assets.push(asset);
    observation.fd.add(this.opened.fd);
    return { fd: this.opened.fd, offset: this.offset, length: this.length };
  }
  async closeRawFd(asset) {
    if (asset !== 'dsh-runtime/runtime.zip' || this.opened === null) throw new Error('fixture: invalid raw close');
    if (this.failClose > 0) { this.failClose--; throw new Error('injected raw close failure'); }
    const fd = this.opened.fd; await this.opened.close(); this.opened = null;
    observation.fd.delete(fd); observation.closes++;
  }
}

// Independent writer uses Node's real zlib CRC and Deflate implementation.
export function zipBytes(items) {
  const chunks = [], central = [], rows = [];
  let offset = 0;
  for (const item of items) {
    const name = Buffer.from(item.name, 'utf8');
    const bytes = Buffer.from(item.bytes);
    const packed = item.method === 0 ? bytes : deflateRawSync(bytes, {level: 9});
    const flag = [...name].some(byte => byte > 127) ? 0x800 : 0;
    const crc = crc32(bytes);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4); local.writeUInt16LE(flag, 6);
    local.writeUInt16LE(item.method, 8); local.writeUInt16LE(23585, 12);
    local.writeUInt32LE(crc, 14); local.writeUInt32LE(packed.length, 18); local.writeUInt32LE(bytes.length, 22); local.writeUInt16LE(name.length, 26);
    const header = Buffer.alloc(46);
    header.writeUInt32LE(0x02014b50); header.writeUInt16LE((3 << 8) | 20, 4); header.writeUInt16LE(20, 6);
    local.copy(header, 8, 6, 28); header.writeUInt32LE((0o100644 << 16) >>> 0, 38); header.writeUInt32LE(offset, 42);
    const row = {name:item.name, localOffset:offset, dataOffset:offset+30+name.length, packedSize:packed.length,
      size:bytes.length, centralRelative:central.reduce((n, b) => n + b.length, 0), nameLength:name.length};
    rows.push(row); chunks.push(local, name, packed); central.push(header, name); offset += local.length + name.length + packed.length;
  }
  const centralBytes = Buffer.concat(central);
  for (const row of rows) row.centralOffset = offset + row.centralRelative;
  const footer = Buffer.alloc(22); footer.writeUInt32LE(0x06054b50);
  footer.writeUInt16LE(items.length, 8); footer.writeUInt16LE(items.length, 10);
  footer.writeUInt32LE(centralBytes.length, 12); footer.writeUInt32LE(offset, 16);
  return {bytes: Buffer.concat([...chunks, centralBytes, footer]), rows};
}

export async function makeArchive(name, files, version = 'v1', adjustManifest) {
  const sorted = Object.keys(files).sort();
  const manifest = {schema:1, runtimeVersion:version, dshVersion:'0.2.1-rc.4', nodeVersion:'24.22.1',
    files:sorted.map(key => ({path:key, size:Buffer.byteLength(files[key]), sha256:createHash('sha256').update(files[key]).digest('hex')}))};
  if (adjustManifest) adjustManifest(manifest);
  const inner = zipBytes([{name:'manifest.json', bytes:Buffer.from(JSON.stringify(manifest)), method:0},
    ...sorted.map(key => ({name:'files/'+key, bytes:files[key], method:8}))]);
  const outer = zipBytes([{name:'prefix.txt', bytes:Buffer.from('raw descriptor must respect a nonzero HAP offset'), method:0},
    {name:'resources/rawfile/dsh-runtime/runtime.zip', bytes:inner.bytes, method:0},
    {name:'suffix.txt', bytes:Buffer.from('raw descriptor must not consume the HAP suffix'), method:0}]);
  await fsp.writeFile(name, outer.bytes);
  const slot = outer.rows[1];
  return {manifest, inner, outer, resources:new ArchiveResources(name, slot.dataOffset, slot.size)};
}

export async function prepareArchiveModules(root, directory) {
  await fsp.mkdir(directory, {recursive:true});
  const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
  if (!prefix) throw new Error('OHOS_TYPESCRIPT_PREFIX is required');
  const ts = createRequire(path.join(prefix, 'package.json'))('typescript');
  const fixture = pathToFileURL(fileURLToPath(import.meta.url)).href;
  const source = path.join(root, 'app/ohos/entry/src/main/ets/runtime');
  const sourceHashes = [];
  for (const name of ['RuntimeCore','RuntimeZip','OhosRuntimeArchive','OhosRuntimeStorage']) {
    const input = await fsp.readFile(path.join(source, name+'.ets'), 'utf8');
    sourceHashes.push({name:name+'.ets', sha256:createHash('sha256').update(input).digest('hex')});
    let text = input.replace("import fs from '@ohos.file.fs';", `import {fileIo as fs} from '${fixture}';`)
      .replace("import fileHash from '@ohos.file.hash';", `import {fileHash} from '${fixture}';`)
      .replace("import util from '@ohos.util';", `import {util} from '${fixture}';`)
      .replace("import zlib from '@ohos.zlib';", `import {nativeZlib as zlib} from '${fixture}';`)
      .replace("import resourceManager from '@ohos.resourceManager';", '')
      .replace("import { BusinessError } from '@ohos.base';", '')
      .replace(/from '(\.\/[^']+)'/g, "from '$1.mjs'");
    text = ts.transpileModule(text, {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText;
    await fsp.writeFile(path.join(directory, name+'.mjs'), text);
  }
  await fsp.writeFile(path.join(directory,'sources.json'), JSON.stringify(sourceHashes,null,2)+'\n');
  return {
    ...await import(pathToFileURL(path.join(directory,'RuntimeCore.mjs'))),
    ...await import(pathToFileURL(path.join(directory,'RuntimeZip.mjs'))),
    ...await import(pathToFileURL(path.join(directory,'OhosRuntimeArchive.mjs'))),
    ...await import(pathToFileURL(path.join(directory,'OhosRuntimeStorage.mjs'))),
  };
}
