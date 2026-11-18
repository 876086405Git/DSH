// Complete bounded PNG validation and pixel reconstruction; same rendering
// chunks and limits as app/lib/pets/pet_png.dart. Ancillary data is never used
// to render. Rows are decoded one at a time, including all Adam7 passes.
import { crc32, zlib } from './workshop-archive';
import { PET_LIMITS } from './generated/workshop-data';
import { previewDimensions, requireWorkshop as need, whole } from './workshop-common';

const passes = [[0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4], [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2]] as const;
export interface PngInfo { width: number; height: number; pixels: number; rgbaSum: number }
export interface PngRegion { x: number; y: number; width: number; height: number }
export function validatePng(bytes: Uint8Array): PngInfo { return readPng(bytes); }
// A companion texture: a PNG of at most 8192 per side. The WebView decodes
// it, so only the signature and IHDR are read; Live2D textures are commonly
// 4096×4096 and larger than a pet sheet may be.
export function validateTexture(bytes: Uint8Array): void {
  need(bytes.length >= 33, 'png_size');
  need([137, 80, 78, 71, 13, 10, 26, 10].every((b, i) => bytes[i] === b), 'png_header');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.length);
  need(view.getUint32(8) === 13 && String.fromCharCode(...bytes.subarray(12, 16)) === 'IHDR', 'png_header');
  const width = view.getUint32(16), height = view.getUint32(20);
  need(width > 0 && height > 0 && width <= 8192 && height <= 8192, 'png_decoded_size');
}
// Reconstruct every source pixel through the same validator; retain only the
// explicitly requested, bounded cell. No full-source RGBA buffer is created.
export function cropPng(bytes: Uint8Array, region: PngRegion): Uint8Array { return readPng(bytes, region).rgba!; }
function readPng(bytes: Uint8Array, region?: PngRegion): PngInfo & { rgba?: Uint8Array } {
  need(bytes.length >= 33 && bytes.length <= PET_LIMITS.sheetBytes, 'png_size');
  need([137, 80, 78, 71, 13, 10, 26, 10].every((b, i) => bytes[i] === b), 'png_header');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.length);
  const width = view.getUint32(16), height = view.getUint32(20), depth = bytes[24]!, color = bytes[25]!, interlace = bytes[28]!;
  need(view.getUint32(8) === 13 && String.fromCharCode(...bytes.subarray(12, 16)) === 'IHDR', 'png_header');
  need(width > 0 && height > 0 && width <= PET_LIMITS.sheetSide && height <= PET_LIMITS.sheetSide && width * height * 4 <= PET_LIMITS.sheetDecodedBytes, 'png_decoded_size');
  let rgba: Uint8Array | undefined;
  if (region) {
    need(previewDimensions(region.width, region.height) && whole(region.x, 0, width - region.width) && whole(region.y, 0, height - region.height), 'preview_dimensions');
    rgba = new Uint8Array(region.width * region.height * 4);
  }
  const depths: Record<number, number[]> = { 0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16] };
  const channels = ({ 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 } as Record<number, number>)[color];
  need(channels && depths[color]!.includes(depth) && bytes[26] === 0 && bytes[27] === 0 && interlace <= 1, 'png_format');
  let at = 8, ended = false, sawIdat = false, idatEnded = false, metadataBytes = 0, compressedSize = 0;
  let palette: Uint8Array | undefined, transparency: Uint8Array | undefined;
  while (at < bytes.length) {
    need(at + 12 <= bytes.length, 'png_chunk');
    const length = view.getUint32(at); need(length <= bytes.length - at - 12, 'png_chunk');
    const type = String.fromCharCode(...bytes.subarray(at + 4, at + 8)), payload = bytes.subarray(at + 8, at + 8 + length);
    need(/^[A-Za-z]{4}$/.test(type), 'png_chunk_type');
    need(crc32(bytes.subarray(at + 4, at + 8 + length)) === view.getUint32(at + 8 + length), 'png_crc');
    need(!['acTL', 'fcTL', 'fdAT'].includes(type), 'png_animated');
    need(type !== 'IHDR' || at === 8, 'png_duplicate_header');
    need(bytes[at + 4]! & 32 || ['IHDR', 'PLTE', 'IDAT', 'IEND'].includes(type), 'png_critical_chunk');
    if (['iCCP', 'zTXt', 'iTXt', 'tEXt'].includes(type)) metadataBytes += metadataSize(type, payload, PET_LIMITS.pngMetadataTotalBytes - metadataBytes);
    if (type === 'PLTE') {
      need(!sawIdat && !transparency && !palette && color !== 0 && color !== 4 && length > 0 && length <= 768 && length % 3 === 0, 'png_palette');
      need(color !== 3 || length / 3 <= 1 << depth, 'png_palette'); palette = payload;
    }
    if (type === 'tRNS') {
      need(!sawIdat && !transparency && (color === 0 && length === 2 || color === 2 && length === 6 || color === 3 && palette && length > 0 && length <= palette.length / 3), 'png_transparency');
      transparency = payload;
    }
    if (type === 'IDAT') {
      need(!idatEnded && (color !== 3 || palette), 'png_idat_order'); sawIdat = true; compressedSize += length;
    } else if (sawIdat) idatEnded = true;
    at += length + 12;
    if (type === 'IEND') { need(length === 0 && at === bytes.length, 'png_trailing'); ended = true; break; }
  }
  need(ended && sawIdat, 'png_truncated');
  const bits = channels * depth, bpp = Math.max(1, Math.ceil(bits / 8));
  const rows = (interlace ? passes : [[0, 0, 1, 1]]).map(([x, y, dx, dy]) => {
    const w = width <= x! ? 0 : Math.ceil((width - x!) / dx!), h = height <= y! ? 0 : Math.ceil((height - y!) / dy!);
    return { width: w, height: h, stride: Math.ceil(w * bits / 8), x: x!, y: y!, dx: dx!, dy: dy! };
  }).filter(row => row.width > 0 && row.height > 0);
  const expected = rows.reduce((sum, row) => sum + (row.stride + 1) * row.height, 0);
  const compressed = new Uint8Array(compressedSize); let write = 0;
  // A second pass avoids retaining one view per IDAT (including empty
  // chunks). The first pass already proved every boundary, CRC and ordering.
  for (let chunkAt = 8; chunkAt < bytes.length;) {
    const length = view.getUint32(chunkAt);
    if (length && bytes[chunkAt + 4] === 73 && bytes[chunkAt + 5] === 68 && bytes[chunkAt + 6] === 65 && bytes[chunkAt + 7] === 84) {
      compressed.set(bytes.subarray(chunkAt + 8, chunkAt + 8 + length), write); write += length;
    }
    chunkAt += length + 12;
  }
  const raw = zlib(compressed, expected); need(raw.length === expected, 'png_member_size');
  let cursor = 0, pixels = 0, rgbaSum = 0;
  const transparent = transparency && new DataView(transparency.buffer, transparency.byteOffset, transparency.length);
  for (const pass of rows) {
    let previous = new Uint8Array(pass.stride), row = new Uint8Array(pass.stride);
    for (let y = 0; y < pass.height; y++) {
      const filter = raw[cursor++]!; need(filter <= 4, 'png_filter');
      for (let x = 0; x < pass.stride; x++) {
        const left = x < bpp ? 0 : row[x - bpp]!, above = previous[x]!, upperLeft = x < bpp ? 0 : previous[x - bpp]!;
        const prediction = filter === 0 ? 0 : filter === 1 ? left : filter === 2 ? above : filter === 3 ? (left + above) >> 1 : paeth(left, above, upperLeft);
        row[x] = (raw[cursor++]! + prediction) & 255;
      }
      // Decode every sample to RGBA. For packed/16-bit rows, compare tRNS at
      // original precision before reduction. Palette lookup must be in range.
      const sample = (i: number) => depth === 16 ? row[i * 2]! * 256 + row[i * 2 + 1]! : depth === 8 ? row[i]! : row[(i * depth) >> 3]! >> (8 - depth - i * depth % 8) & (1 << depth) - 1;
      const byte = (n: number) => depth === 16 ? n >> 8 : depth === 8 ? n : Math.round(n * 255 / ((1 << depth) - 1));
      for (let x = 0; x < pass.width; x++) {
        let r: number, g: number, b: number, a = 255;
        const base = x * channels, first = sample(base);
        if (color === 3) {
          need(palette && first * 3 + 2 < palette.length, 'png_decode');
          r = palette[first * 3]!; g = palette[first * 3 + 1]!; b = palette[first * 3 + 2]!; a = transparency?.[first] ?? 255;
        } else if (color === 0 || color === 4) {
          r = g = b = byte(first);
          if (color === 4) a = byte(sample(base + 1));
          else if (transparent && first === transparent.getUint16(0)) a = 0;
        } else {
          const second = sample(base + 1), third = sample(base + 2);
          r = byte(first); g = byte(second); b = byte(third);
          if (color === 6) a = byte(sample(base + 3));
          else if (transparent && first === transparent.getUint16(0) && second === transparent.getUint16(2) && third === transparent.getUint16(4)) a = 0;
        }
        rgbaSum = (rgbaSum + r + g + b + a) >>> 0; pixels++;
        if (region && rgba) {
          const imageX = pass.x + x * pass.dx, imageY = pass.y + y * pass.dy;
          if (imageX >= region.x && imageX < region.x + region.width && imageY >= region.y && imageY < region.y + region.height) {
            const target = ((imageY - region.y) * region.width + imageX - region.x) * 4;
            rgba[target] = r; rgba[target + 1] = g; rgba[target + 2] = b; rgba[target + 3] = a;
          }
        }
      }
      [previous, row] = [row, previous];
    }
  }
  need(cursor === raw.length && pixels === width * height, 'png_decode');
  return { width, height, pixels, rgbaSum, ...(rgba ? { rgba } : {}) };
}
function paeth(a: number, b: number, c: number): number {
  const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}
function metadataSize(type: string, data: Uint8Array, remaining: number): number {
  const keyword = data.indexOf(0); need(keyword >= 1 && keyword <= 79, 'png_metadata');
  let start = keyword + 1, compressed = false;
  if (type === 'iCCP' || type === 'zTXt') { need(start < data.length && data[start] === 0, 'png_metadata'); start++; compressed = true; }
  else if (type === 'iTXt') {
    need(start + 2 <= data.length && data[start]! <= 1 && data[start + 1] === 0, 'png_metadata');
    compressed = data[start] === 1; start += 2;
    const language = data.indexOf(0, start), translated = data.indexOf(0, language + 1);
    need(language >= start && translated > language, 'png_metadata'); start = translated + 1;
  }
  const payload = data.subarray(start);
  if (!compressed) { need(payload.length <= remaining, 'png_metadata_total_size'); return payload.length; }
  return zlib(payload, Math.min(remaining, PET_LIMITS.pngMetadataChunkBytes)).length;
}
