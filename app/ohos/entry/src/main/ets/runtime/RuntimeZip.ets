import util from '@ohos.util';
import { RuntimeChannelError, RuntimeFile, RuntimeManifest, validateManifest } from './RuntimeCore';

// Deliberately a bounded ZIP32 profile, not a general-purpose archive extractor.
export interface RuntimeArchiveSource {
  length: number;
  read(offset: number, length: number): Promise<ArrayBuffer>;
}

export class RuntimeZipEntry {
  name: string = '';
  version: number = 0;
  flags: number = 0;
  method: number = 0;
  crc: number = 0;
  packedSize: number = 0;
  size: number = 0;
  headerOffset: number = 0;
  dataOffset: number = 0;
  nameLength: number = 0;
  time: number = 0;
  date: number = 0;
  sha256: string = '';
}

const MAX_ARCHIVE: number = 0x7fffffff;
const MAX_DIRECTORY: number = 32 * 1024 * 1024;
const MAX_MANIFEST: number = 16 * 1024 * 1024;
const MAX_NAME: number = 4096;
const MAX_FILE: number = 512 * 1024 * 1024;

function invalid(): never {
  throw new RuntimeChannelError('ohos_archive_invalid', '随包运行时归档的格式、索引或清单不一致。');
}

function bounds(offset: number, length: number, end: number): void {
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 ||
      offset > end || length > end - offset) invalid();
}

function decode(bytes: Uint8Array): string {
  try {
    return util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(bytes);
  } catch (error) {
    invalid();
  }
}

const CRC_TABLE: Uint32Array = makeCrcTable();
function makeCrcTable(): Uint32Array {
  const table = new Uint32Array(256);
  for (let i = 0; i < table.length; i++) {
    let value = i;
    for (let bit = 0; bit < 8; bit++) value = (value >>> 1) ^ ((value & 1) === 0 ? 0 : 0xedb88320);
    table[i] = value >>> 0;
  }
  return table;
}

// The SHA256 check in RuntimeInstaller remains the content authority. ZIP CRC
// additionally detects malformed archive metadata and the stored manifest.
export function runtimeCrc32(bytes: Uint8Array, previous: number = 0): number {
  let crc = previous ^ 0xffffffff;
  for (let i = 0; i < bytes.length; i++) crc = CRC_TABLE[(crc ^ bytes[i]) & 255] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

export class RuntimeZip {
  readonly manifest: RuntimeManifest;
  readonly length: number;
  private entries: Map<string, RuntimeZipEntry>;

  private constructor(manifest: RuntimeManifest, length: number, entries: Map<string, RuntimeZipEntry>) {
    this.manifest = manifest;
    this.length = length;
    this.entries = entries;
  }

  file(file: RuntimeFile): RuntimeZipEntry {
    const entry = this.entries.get('files/' + file.path);
    if (entry === undefined || entry.size !== file.size || entry.sha256 !== file.sha256) invalid();
    return entry;
  }

  static async read(source: RuntimeArchiveSource): Promise<RuntimeZip> {
    if (!Number.isSafeInteger(source.length) || source.length < 22 || source.length > MAX_ARCHIVE) invalid();
    const footer = new DataView(await source.read(source.length - 22, 22));
    if (footer.byteLength !== 22 || footer.getUint32(0, true) !== 0x06054b50 ||
        footer.getUint16(4, true) !== 0 || footer.getUint16(6, true) !== 0 || footer.getUint16(20, true) !== 0) invalid();
    const count = footer.getUint16(10, true);
    const directorySize = footer.getUint32(12, true);
    const directoryOffset = footer.getUint32(16, true);
    if (count < 2 || count === 0xffff || footer.getUint16(8, true) !== count ||
        directorySize > MAX_DIRECTORY || directorySize < count * 46) invalid();
    bounds(directoryOffset, directorySize, source.length - 22);
    if (directoryOffset + directorySize !== source.length - 22) invalid();
    const centralBytes = new Uint8Array(await source.read(directoryOffset, directorySize));
    if (centralBytes.byteLength !== directorySize) invalid();
    const central = new DataView(centralBytes.buffer);
    const ordered: RuntimeZipEntry[] = [];
    const entries: Map<string, RuntimeZipEntry> = new Map<string, RuntimeZipEntry>();
    let cursor = 0;
    let nextHeader = 0;
    let expanded = 0;
    for (let i = 0; i < count; i++) {
      bounds(cursor, 46, directorySize);
      if (central.getUint32(cursor, true) !== 0x02014b50 || central.getUint16(cursor + 6, true) > 20 ||
          central.getUint16(cursor + 30, true) !== 0 || central.getUint16(cursor + 32, true) !== 0 ||
          central.getUint16(cursor + 34, true) !== 0 || central.getUint16(cursor + 36, true) !== 0) invalid();
      const entry = new RuntimeZipEntry();
      entry.version = central.getUint16(cursor + 6, true);
      entry.flags = central.getUint16(cursor + 8, true);
      entry.method = central.getUint16(cursor + 10, true);
      entry.time = central.getUint16(cursor + 12, true);
      entry.date = central.getUint16(cursor + 14, true);
      entry.crc = central.getUint32(cursor + 16, true);
      entry.packedSize = central.getUint32(cursor + 20, true);
      entry.size = central.getUint32(cursor + 24, true);
      entry.nameLength = central.getUint16(cursor + 28, true);
      entry.headerOffset = central.getUint32(cursor + 42, true);
      const mode = central.getUint32(cursor + 38, true) >>> 16;
      if ((central.getUint16(cursor + 4, true) >>> 8) !== 3 || mode !== 0o100644 ||
          (entry.flags !== 0 && entry.flags !== 0x800) || entry.nameLength === 0 || entry.nameLength > MAX_NAME ||
          entry.headerOffset !== nextHeader || entry.size > MAX_FILE || entry.packedSize > MAX_ARCHIVE) invalid();
      bounds(cursor + 46, entry.nameLength, directorySize);
      const nameBytes = centralBytes.subarray(cursor + 46, cursor + 46 + entry.nameLength);
      if (entry.flags === 0 && nameBytes.some((byte: number) => byte > 127)) invalid();
      entry.name = decode(nameBytes);
      if (entries.has(entry.name) || entry.name.includes('\0') || entry.name.includes('\\') ||
          (i === 0 ? entry.name !== 'manifest.json' || entry.method !== 0 :
            !entry.name.startsWith('files/') || entry.method !== 8)) invalid();
      if (i === 0 && (entry.size > MAX_MANIFEST || entry.size !== entry.packedSize)) invalid();
      entry.dataOffset = entry.headerOffset + 30 + entry.nameLength;
      bounds(entry.headerOffset, 30 + entry.nameLength, directoryOffset);
      bounds(entry.dataOffset, entry.packedSize, directoryOffset);
      nextHeader = entry.dataOffset + entry.packedSize;
      expanded += entry.size;
      if (expanded > MAX_ARCHIVE) invalid();
      entries.set(entry.name, entry);
      ordered.push(entry);
      cursor += 46 + entry.nameLength;
    }
    if (cursor !== directorySize || nextHeader !== directoryOffset) invalid();

    // Check every local header, including files that an incremental install will
    // skip. There can be no hidden prefix, gaps, duplicate local records or extras.
    for (const entry of ordered) {
      const headerBytes = new Uint8Array(await source.read(entry.headerOffset, 30 + entry.nameLength));
      if (headerBytes.byteLength !== 30 + entry.nameLength) invalid();
      const header = new DataView(headerBytes.buffer);
      if (header.getUint32(0, true) !== 0x04034b50 || header.getUint16(4, true) !== entry.version ||
          header.getUint16(6, true) !== entry.flags || header.getUint16(8, true) !== entry.method ||
          header.getUint16(10, true) !== entry.time || header.getUint16(12, true) !== entry.date ||
          header.getUint32(14, true) !== entry.crc || header.getUint32(18, true) !== entry.packedSize ||
          header.getUint32(22, true) !== entry.size || header.getUint16(26, true) !== entry.nameLength ||
          header.getUint16(28, true) !== 0 || decode(headerBytes.subarray(30)) !== entry.name) invalid();
    }
    const manifestEntry = ordered[0];
    const manifestBytes = new Uint8Array(await source.read(manifestEntry.dataOffset, manifestEntry.size));
    if (manifestBytes.byteLength !== manifestEntry.size || runtimeCrc32(manifestBytes) !== manifestEntry.crc) invalid();
    let manifest: RuntimeManifest;
    try {
      manifest = validateManifest(JSON.parse(decode(manifestBytes)) as RuntimeManifest);
    } catch (error) {
      invalid();
    }
    if (manifest.files.length !== count - 1) invalid();
    for (let i = 0; i < manifest.files.length; i++) {
      const file = manifest.files[i];
      const entry = ordered[i + 1];
      if (entry.name !== 'files/' + file.path || entry.size !== file.size) invalid();
      entry.sha256 = file.sha256;
    }
    return new RuntimeZip(manifest, source.length, entries);
  }
}
