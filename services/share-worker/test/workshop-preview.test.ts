import { deflateSync, inflateSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import { WorkshopArchive } from '../src/workshop-archive';
import { metadata, PREVIEW_CONTRACT, previewUrl, validPreview } from '../src/workshop-common';
import { validatePack } from '../src/workshop-pack';
import { cropPng, validatePng } from '../src/workshop-png';
import { checkPreviewRequest, derivePreview, encodePreviewPng, validatePublicPng } from '../src/workshop-preview';
import { companion, metaFor, petManifest, png, zip } from './workshop-fixtures';
import { expectedCrop, PNG_FORMS, previewChunk, samplePng } from './workshop-preview-fixtures';

describe('public preview pixel reconstruction', () => {
  const region = { x: 2, y: 1, width: 4, height: 5 };
  for (const [color, depth] of PNG_FORMS) for (const interlaced of [false, true]) {
    it(`crops color ${color} depth ${depth} Adam7 ${interlaced} without changing source validation`, () => {
      const image = samplePng(color, depth, interlaced), expected = expectedCrop(image.expected, image.width, region.x, region.y, region.width, region.height);
      expect(validatePng(image.bytes)).toMatchObject({ pixels: 63, rgbaSum: image.expected.reduce((sum, b) => sum + b, 0) });
      expect(cropPng(image.bytes, region)).toEqual(expected);
      const sampled = Uint8Array.from([1, 3, 5].flatMap(y => [3, 5].flatMap(x =>
        [...expectedCrop(image.expected, image.width, x, y, 1, 1)])));
      expect(cropPng(image.bytes, region, 2, 3)).toEqual(sampled);
      // Include the first Adam7 passes and the adjacent 16-bit samples that
      // share an 8-bit value but differ in their exact tRNS comparison.
      expect(cropPng(image.bytes, { x: 0, y: 0, width: image.width, height: 1 })).toEqual(image.expected.subarray(0, image.width * 4));
      const output = encodePreviewPng(expected, region.width, region.height);
      expect(validatePublicPng(output)).toMatchObject({ width: region.width, height: region.height, rgbaSum: expected.reduce((sum, b) => sum + b, 0) });
      expect(cropPng(output, { ...region, x: 0, y: 0 })).toEqual(expected);
    });
  }
  for (const filter of [1, 2, 3, 4]) it(`preserves filter ${filter} and Adam7 absolute coordinates`, () => {
    const image = samplePng(6, 16, true, filter);
    expect(cropPng(image.bytes, region)).toEqual(expectedCrop(image.expected, image.width, region.x, region.y, region.width, region.height));
  });
  for (const height of [255, 256]) it(`encodes complete stored DEFLATE blocks at height ${height}`, () => {
    const width = 64, rgba = Uint8Array.from({ length: width * height * 4 }, (_, i) => i % 251), encoded = encodePreviewPng(rgba, width, height);
    const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength), idat = encoded.subarray(41, 41 + view.getUint32(33));
    const raw = inflateSync(idat);
    expect(raw.length).toBe(height * (4 * width + 1));
    for (let row = 0; row < height; row++) {
      expect(raw[row * (4 * width + 1)]).toBe(0);
      expect(new Uint8Array(raw.subarray(row * (4 * width + 1) + 1, (row + 1) * (4 * width + 1)))).toEqual(rgba.subarray(row * width * 4, (row + 1) * width * 4));
    }
    expect(validatePublicPng(encoded).pixels).toBe(width * height);
  });
});

it('still validates CRC, zlib and unsampled Adam7 rows when downscaling', () => {
  const image = samplePng(6, 16, true).bytes;
  const region = { x: 2, y: 1, width: 4, height: 5 };
  const badCrc = Buffer.from(image); badCrc[badCrc.length - 1] ^= 1;
  expect(() => cropPng(badCrc, region, 2, 3)).toThrow('png_crc');

  const idat = 33, size = image.readUInt32BE(idat);
  const stream = image.subarray(idat + 8, idat + 8 + size);
  const replaceIdat = (data: Uint8Array) => Buffer.concat([
    image.subarray(0, idat), previewChunk('IDAT', data), image.subarray(idat + 12 + size),
  ]);
  const badAdler = Buffer.from(stream); badAdler[badAdler.length - 1] ^= 1;
  expect(() => cropPng(replaceIdat(badAdler), region, 2, 3)).toThrow('zlib_adler');
  const raw = inflateSync(stream); raw[0] = 5; // Pass 1 lies outside the requested rows.
  expect(() => cropPng(replaceIdat(deflateSync(raw)), region, 2, 3)).toThrow('png_filter');
});

it('keeps the full 512-by-512 envelope and rejects larger dimensions before pixel allocation', () => {
  const bytes = encodePreviewPng(new Uint8Array(512 * 512 * 4), 512, 512);
  expect(bytes.length).toBe(1049236); expect(validatePublicPng(bytes).pixels).toBe(PREVIEW_CONTRACT.maxPixels);
  for (const [width, height] of [[513, 1], [1, 513], [0, 1], [1.5, 1]]) expect(() => encodePreviewPng(new Uint8Array(), width!, height!)).toThrow('preview_dimensions');
  const oversized = Buffer.from(png()); oversized.writeUInt32BE(513, 16);
  // This header deliberately has the old CRC: the smaller dimension gate is
  // reached before CRC validation, IDAT inflate or target allocation.
  expect(() => validatePublicPng(oversized)).toThrow('preview_dimensions');
});
it('enforces the exact PNG byte cap without replacing the complete PNG gate', () => {
  const base = png(), padded = Buffer.concat([base.subarray(0, 33), previewChunk('vpAg', Buffer.alloc(PREVIEW_CONTRACT.maxBytes - base.length - 12)), base.subarray(33)]);
  expect(padded.length).toBe(PREVIEW_CONTRACT.maxBytes); expect(validatePublicPng(padded).pixels).toBe(1);
  expect(() => validatePublicPng(Buffer.concat([padded, Buffer.from([0])]))).toThrow('preview_size');
  const badCrc = Buffer.from(base); badCrc[badCrc.length - 1] ^= 1;
  expect(() => validatePublicPng(badCrc)).toThrow('png_crc');
  const animated = Buffer.concat([base.subarray(0, 33), previewChunk('acTL', Buffer.alloc(8)), base.subarray(33)]);
  expect(() => validatePublicPng(animated)).toThrow('png_animated');
  const truncatedStream = Buffer.concat([base.subarray(0, 33), previewChunk('IDAT', Buffer.from([0x78, 0x01, 0, 0, 0, 0])), previewChunk('IEND', Buffer.alloc(0))]);
  expect(() => validatePublicPng(truncatedStream)).toThrow();
});
it('selects idle primary animation and its nonzero first cell in a wrapped multi-sheet pet', async () => {
  const pack = petManifest(), rgba = Uint8Array.from({ length: 4 * 2 * 4 }, (_, i) => i * 7);
  const selected = { sheet: 'chosen.png', frameW: 2, frameH: 1, cols: 2, box: { x: 0, y: 0, w: 2, h: 1 }, frames: [{ i: 3, ms: 100 }, { i: 0, ms: 100 }] };
  const manifest = { ...pack, canvas: { w: 2, h: 1 }, contentBox: selected.box, animations: { other: { ...selected, sheet: 'other.png' }, rest: selected }, states: { idle: ['rest', 'other'] } };
  const bytes = zip([['wrapped/', Buffer.alloc(0)], ['wrapped/pack.json', Buffer.from(JSON.stringify(manifest))],
    ['wrapped/other.png', png(4, 2)], ['wrapped/chosen.png', encodePreviewPng(rgba, 4, 2)]]), meta = metaFor(bytes, { previewSource: 'pet-idle' });
  checkPreviewRequest(bytes, meta); expect(validatePack(bytes, meta, 6).sheets).toBe(2);
  const preview = (await derivePreview(bytes, meta))!;
  expect(preview.descriptor).toMatchObject({ path: previewUrl(meta, preview.descriptor.sha256), size: preview.bytes.length, width: 2, height: 1 });
  expect(cropPng(preview.bytes, { x: 0, y: 0, width: 2, height: 1 })).toEqual(expectedCrop(rgba, 4, 2, 1, 2, 1));
  expect(preview.descriptor.sha256).toBe('0790eeef1af5dc3320901cd078bb1066e4949c29d54265a9884a54c788bdae7a');
});
it.each([[513, 1, 512, 1], [4096, 1, 512, 1], [3, 700, 2, 512], [768, 512, 512, 341]])(
  'fits a %ix%i idle frame to %ix%i without changing the no-preview path', async (frameW, frameH, width, height) => {
    const pack = petManifest(), box = { x: 0, y: 0, w: frameW, h: frameH };
    const manifest = { ...pack, canvas: { w: frameW, h: frameH }, contentBox: box,
      animations: { idle: { ...pack.animations.idle, frameW, frameH, box } } };
    const bytes = zip([['pack.json', Buffer.from(JSON.stringify(manifest))], ['idle.png', png(frameW, frameH)]]), meta = metaFor(bytes);
    expect(validatePack(bytes, meta, 6).sheets).toBe(1);
    checkPreviewRequest(bytes, meta); expect(await derivePreview(bytes, meta)).toBeUndefined();
    const withPreview = { ...meta, previewSource: 'pet-idle' as const };
    checkPreviewRequest(bytes, withPreview);
    expect((await derivePreview(bytes, withPreview))?.descriptor).toMatchObject({ width, height });
  },
);
it('extracts only the explicitly selected fixed companion member, preserving its exact bytes', async () => {
  const original = new WorkshopArchive(companion(), 1000), image = samplePng(3, 4, true).bytes;
  const bytes = zip([...original.files.keys()].map(path => [path, original.read(path, 1024 * 1024)] as [string, Uint8Array]).concat([['character/preview.png', image]]));
  const legacy = metaFor(bytes, { kind: 'companion' }); expect(await derivePreview(bytes, legacy)).toBeUndefined();
  const meta = { ...legacy, previewSource: 'companion-preview' as const }; checkPreviewRequest(bytes, meta); validatePack(bytes, meta, 6);
  const preview = (await derivePreview(bytes, meta))!; expect(preview.bytes).toEqual(image); expect(preview.descriptor.size).toBe(image.length);
});
it('rejects an explicit companion request with no fixed preview before any PNG work', () => {
  const bytes = companion(), meta = metaFor(bytes, { kind: 'companion', previewSource: 'companion-preview' });
  expect(() => checkPreviewRequest(bytes, meta)).toThrow('preview_missing');
});
it('normalizes the choice for idempotency and validates the exact descriptor binding', () => {
  const bytes = png(), base = metaFor(bytes), declared = metadata({ ...base, previewSource: 'pet-idle', preview: { path: '/ignored' } });
  expect(declared.previewSource).toBe('pet-idle'); expect(declared).not.toHaveProperty('preview'); expect(metadata(base)).not.toHaveProperty('previewSource');
  for (const previewSource of [null, '', 'companion-preview', 'future']) expect(() => metadata({ ...base, previewSource })).toThrow('bad_metadata');
  const preview = { path: previewUrl(declared, base.sha256), sha256: base.sha256, size: bytes.length, width: 1, height: 1 };
  expect(validPreview(preview, declared)).toBe(true);
  expect(validPreview({ ...preview, path: preview.path.replace('/pet/', '/companion/') }, declared)).toBe(false);
  expect(validPreview({ ...preview, path: 'https://example.org' + preview.path }, declared)).toBe(false);
  expect(validPreview(preview, base)).toBe(false); expect(validPreview({ ...preview, width: 513 }, declared)).toBe(false);
});
