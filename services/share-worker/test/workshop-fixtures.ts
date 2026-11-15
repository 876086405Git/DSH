// Original synthetic pixels/archives only; these fixtures carry no licensed
// model data, real credentials, user settings, or real account identities.
import { randomBytes } from 'node:crypto';
import { deflateRawSync, deflateSync } from 'node:zlib';
import { crc32 } from '../src/workshop-archive';
import type { SubmissionMeta } from '../src/workshop-common';
import { sha } from './pet-market-fakes';
export const BASE_META = { kind: 'pet', id: 'sample', version: '1.0.0', minApp: '1.0.13', title: { zh: '合成示例', en: 'Synthetic sample' }, author: 'Synthetic author', license: 'CC0-1.0', source: 'https://example.org/synthetic', rightsConfirmed: true } as const;
export function chunk(type: string, data: Uint8Array): Buffer {
  const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type), data]), crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}
export function png(width = 1, height = 1, color: [number, number, number, number] = [255, 0, 0, 255]): Buffer {
  const head = Buffer.alloc(13); head.writeUInt32BE(width); head.writeUInt32BE(height, 4); head[8] = 8; head[9] = 6;
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) raw.set(color, y * (width * 4 + 1) + x * 4 + 1);
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', head), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
export function zip(members: [string, Uint8Array][], compressed = true): Buffer {
  const files: Buffer[] = [], central: Buffer[] = []; let offset = 0;
  for (const [path, data] of members) {
    const name = Buffer.from(path), packed = compressed ? deflateRawSync(data) : data, head = Buffer.alloc(30);
    head.writeUInt32LE(0x04034b50); head.writeUInt16LE(20, 4); head.writeUInt16LE(0x800, 6); head.writeUInt16LE(compressed ? 8 : 0, 8);
    head.writeUInt32LE(crc32(data), 14); head.writeUInt32LE(packed.length, 18); head.writeUInt32LE(data.length, 22); head.writeUInt16LE(name.length, 26);
    const directory = Buffer.alloc(46); directory.writeUInt32LE(0x02014b50); directory.writeUInt16LE(0x314, 4); head.copy(directory, 6, 4, 30);
    directory.writeUInt32LE(path.endsWith('/') ? 0x41ed0000 : 0x81a40000, 38); directory.writeUInt32LE(offset, 42);
    const file = Buffer.concat([head, name, packed]); files.push(file); central.push(Buffer.concat([directory, name])); offset += file.length;
  }
  const table = Buffer.concat(central), end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50); end.writeUInt16LE(members.length, 8); end.writeUInt16LE(members.length, 10); end.writeUInt32LE(table.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...files, table, end]);
}
export function petManifest() {
  return { schema: 1, id: BASE_META.id, author: BASE_META.author, license: BASE_META.license, source: BASE_META.source,
    canvas: { w: 1, h: 1 }, contentBox: { x: 0, y: 0, w: 1, h: 1 },
    animations: { idle: { sheet: 'idle.png', frameW: 1, frameH: 1, cols: 1, box: { x: 0, y: 0, w: 1, h: 1 }, frames: [{ i: 0, ms: 100 }] } }, states: { idle: ['idle'] } };
}
export function pet(pack: object = petManifest(), extras: [string, Uint8Array][] = []) { return zip([['pack.json', Buffer.from(JSON.stringify(pack))], ['idle.png', png()], ...extras]); }
export function companion(options: { version?: number; runtime?: boolean; reference?: string } = {}) {
  const meta = { ...BASE_META, kind: 'companion' as const };
  return zip([
    ['character/character.json', Buffer.from(JSON.stringify({ schema: 1, name: 'Synthetic model', model: 'sample.model3.json', author: meta.author, license: meta.license, source: meta.source }))],
    ['character/sample.model3.json', Buffer.from(JSON.stringify({ Version: 3, FileReferences: { Moc: options.reference ?? 'sample.moc3', Textures: ['texture.png'] } }))],
    ['character/sample.moc3', Buffer.from([77, 79, 67, 51, options.version ?? 6, 0, 0, 0])],
    ['character/texture.png', png()],
    ...(options.runtime ? [['runtime/script.js', Buffer.from('synthetic runtime must be rejected')]] as [string, Uint8Array][] : []),
  ]);
}
/** A companion over the old 20 MiB cap: textures of incompressible noise,
 *  stored, each under the 8 MiB PNG limit. */
export function largeCompanion(textures: number, side = 1400) {
  const meta = { ...BASE_META, kind: 'companion' as const }, names = Array.from({ length: textures }, (_, i) => `t${i}.png`);
  const noise = () => {
    const head = Buffer.alloc(13); head.writeUInt32BE(side); head.writeUInt32BE(side, 4); head[8] = 8; head[9] = 6;
    const raw = randomBytes((side * 4 + 1) * side); for (let y = 0; y < side; y++) raw[y * (side * 4 + 1)] = 0;
    return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', head), chunk('IDAT', deflateSync(raw, { level: 0 })), chunk('IEND', Buffer.alloc(0))]);
  };
  return zip([
    ['character/character.json', Buffer.from(JSON.stringify({ schema: 1, name: 'Synthetic model', model: 'sample.model3.json', author: meta.author, license: meta.license, source: meta.source }))],
    ['character/sample.model3.json', Buffer.from(JSON.stringify({ Version: 3, FileReferences: { Moc: 'sample.moc3', Textures: names } }))],
    ['character/sample.moc3', Buffer.from([77, 79, 67, 51, 6, 0, 0, 0])],
    ...names.map(name => [`character/${name}`, noise()] as [string, Uint8Array]),
  ], false);
}
export function metaFor(bytes: Uint8Array, overrides: Partial<SubmissionMeta> = {}): SubmissionMeta { return { ...BASE_META, sha256: sha(bytes), size: bytes.length, ...overrides }; }
