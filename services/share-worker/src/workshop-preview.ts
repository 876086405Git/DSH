// Public previews are an explicit submission choice, never an arbitrary
// archive-member endpoint. The old package acceptance domain stays unchanged
// when metadata does not request a preview.
import { PET_LIMITS } from './generated/workshop-data';
import { record } from './pet-catalog';
import { crc32, strictJson, WorkshopArchive } from './workshop-archive';
import { PREVIEW_CONTRACT, previewDimensions, previewUrl, requireWorkshop as need, sha256, whole,
  type PublicPreview, type SubmissionMeta } from './workshop-common';
import { cropPng, validatePng, type PngInfo, type PngRegion } from './workshop-png';

const SIGNATURE = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
const COMPANION_PREVIEW = 'character/preview.png';
const THEME_PREVIEW = 'preview.png';
function previewHeader(bytes: Uint8Array): void {
  need(bytes.length <= PREVIEW_CONTRACT.maxBytes, 'preview_size');
  need(bytes.length >= 33 && SIGNATURE.every((b, i) => bytes[i] === b), 'png_header');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.length);
  need(view.getUint32(8) === 13 && String.fromCharCode(...bytes.subarray(12, 16)) === 'IHDR', 'png_header');
  need(previewDimensions(view.getUint32(16), view.getUint32(20)), 'preview_dimensions');
}
export function validatePublicPng(bytes: Uint8Array): PngInfo {
  // The smaller public-image envelope is checked before image/metadata inflate.
  // Header checks alone never confer validity: the complete PNG gate follows.
  previewHeader(bytes); return validatePng(bytes);
}
function companionBytes(zip: WorkshopArchive): Uint8Array {
  const member = zip.files.get(COMPANION_PREVIEW); need(member, 'preview_missing');
  need(member.size <= PREVIEW_CONTRACT.maxBytes, 'preview_size');
  return zip.read(COMPANION_PREVIEW, PREVIEW_CONTRACT.maxBytes);
}
function themeBytes(zip: WorkshopArchive): Uint8Array {
  const member = zip.files.get(THEME_PREVIEW); need(member, 'preview_missing');
  need(member.size <= PREVIEW_CONTRACT.maxBytes, 'preview_size');
  return zip.read(THEME_PREVIEW, PREVIEW_CONTRACT.maxBytes);
}
function petCell(zip: WorkshopArchive): { path: string; region: PngRegion } {
  const candidates = [...zip.files.keys()].filter(name => /^(?:[^/]+\/)?pack\.json$/.test(name));
  need(candidates.length === 1, 'archive_pack_count');
  const manifest = candidates[0]!, pack = strictJson(zip.read(manifest, PET_LIMITS.packJsonBytes), PET_LIMITS.packJsonBytes, 60);
  need(record(pack) && record(pack.states) && Array.isArray(pack.states.idle) && pack.states.idle.length > 0, 'pack_idle');
  const name = pack.states.idle[0];
  need(typeof name === 'string' && record(pack.animations) && Object.hasOwn(pack.animations, name), 'pack_reference');
  const animation = pack.animations[name]; need(record(animation) && typeof animation.sheet === 'string', 'pack_animations');
  const { frameW: width, frameH: height } = animation;
  need(whole(width, 1, PET_LIMITS.sheetSide) && whole(height, 1, PET_LIMITS.sheetSide) && width * height * 4 <= PET_LIMITS.sheetDecodedBytes, 'preview_dimensions');
  need(whole(animation.cols, 1, PET_LIMITS.sheetSide) && Array.isArray(animation.frames) && record(animation.frames[0]) && whole(animation.frames[0].i, 0, 1 << 30), 'pack_frames');
  const first = animation.frames[0].i;
  return { path: manifest.slice(0, -'pack.json'.length) + animation.sheet,
    region: { x: first % animation.cols * width, y: Math.floor(first / animation.cols) * height, width, height } };
}
export function checkPreviewRequest(bytes: Uint8Array, meta: SubmissionMeta): void {
  if (meta.previewSource === undefined) return;
  const zip = new WorkshopArchive(bytes, meta.kind === 'pet' ? PET_LIMITS.archiveEntries : 1000);
  if (meta.kind === 'pet') petCell(zip);
  else if (meta.kind === 'theme') previewHeader(themeBytes(zip));
  else previewHeader(companionBytes(zip));
}
export async function derivePreview(bytes: Uint8Array, meta: SubmissionMeta): Promise<{ bytes: Uint8Array; descriptor: PublicPreview } | undefined> {
  if (meta.previewSource === undefined) return undefined;
  const zip = new WorkshopArchive(bytes, meta.kind === 'pet' ? PET_LIMITS.archiveEntries : 1000);
  let image: Uint8Array;
  if (meta.kind === 'pet') {
    const { path, region } = petCell(zip);
    const longest = Math.max(region.width, region.height);
    const limit = PREVIEW_CONTRACT.maxWidth; // Both public sides have the same cap.
    const fit = (size: number) => longest <= limit ? size : Math.max(1, Math.round(size * limit / longest));
    const width = fit(region.width), height = fit(region.height);
    const rgba = cropPng(zip.read(path, PET_LIMITS.sheetBytes), region, width, height);
    image = encodePreviewPng(rgba, width, height);
  } else if (meta.kind === 'theme') {
    image = themeBytes(zip);
  } else image = companionBytes(zip);
  const info = validatePublicPng(image), sha = await sha256(image);
  return { bytes: image, descriptor: { path: previewUrl(meta, sha), sha256: sha, size: image.length, width: info.width, height: info.height } };
}

// RGBA8, filter 0, noninterlaced, one IDAT. RFC 1950/1951 stored blocks avoid
// an encoder dependency and make the worst-case encoded size deterministic:
// N = h*(4*w+1), total = N + 5*ceil(N/65535) + 6 + 57 <= 1,049,236.
// This byte bound is not an assertion about isolate peak memory or frame time.
export function encodePreviewPng(rgba: Uint8Array, width: number, height: number): Uint8Array {
  need(previewDimensions(width, height), 'preview_dimensions');
  need(rgba.length === width * height * 4, 'png_decode');
  const stride = width * 4 + 1, raw = new Uint8Array(stride * height);
  for (let y = 0; y < height; y++) raw.set(rgba.subarray(y * width * 4, (y + 1) * width * 4), y * stride + 1);
  const compressed = new Uint8Array(raw.length + 5 * Math.ceil(raw.length / 65535) + 6);
  const zview = new DataView(compressed.buffer); compressed[0] = 0x78; compressed[1] = 0x01;
  let at = 2;
  for (let start = 0; start < raw.length;) {
    const length = Math.min(65535, raw.length - start);
    compressed[at++] = start + length === raw.length ? 1 : 0;
    zview.setUint16(at, length, true); zview.setUint16(at + 2, length ^ 0xffff, true); at += 4;
    compressed.set(raw.subarray(start, start + length), at); at += length; start += length;
  }
  let a = 1, b = 0;
  for (let start = 0; start < raw.length; start += 5552) {
    for (let i = start; i < Math.min(start + 5552, raw.length); i++) { a += raw[i]!; b += a; }
    a %= 65521; b %= 65521;
  }
  zview.setUint32(at, (b << 16 | a) >>> 0);
  const output = new Uint8Array(compressed.length + 57), view = new DataView(output.buffer); output.set(SIGNATURE);
  let write = 8;
  const chunk = (name: string, data: Uint8Array) => {
    view.setUint32(write, data.length);
    for (let i = 0; i < 4; i++) output[write + 4 + i] = name.charCodeAt(i);
    output.set(data, write + 8); view.setUint32(write + 8 + data.length, crc32(output.subarray(write + 4, write + 8 + data.length)));
    write += data.length + 12;
  };
  const header = new Uint8Array(13), hview = new DataView(header.buffer);
  hview.setUint32(0, width); hview.setUint32(4, height); header[8] = 8; header[9] = 6;
  chunk('IHDR', header); chunk('IDAT', compressed); chunk('IEND', new Uint8Array());
  need(write === output.length && output.length <= PREVIEW_CONTRACT.maxBytes, 'preview_size'); return output;
}
