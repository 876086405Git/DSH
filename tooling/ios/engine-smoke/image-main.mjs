// The real attachment store from the runtime archive, on Apple's real decoder and encoder. Each
// image goes in the way a screenshot or an attached photo would, and comes back out the way a
// model request would read it.
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { crc32, deflateSync } from 'node:zlib';
import { createRequire } from 'node:module';

const runtime = process.env.DSH_IOS_IMAGE_RUNTIME;
const library = join(runtime, 'node_modules/@deepseek-ai/dsh-attachment-local/lib');
const store = await import(pathToFileURL(join(library, 'index.js')).href);
const { inspect, bare } = createRequire(import.meta.url)(join(library, 'ios-sharp.cjs'));
const native = process._linkedBinding('dsh_ios_image');
const note = row => console.log(JSON.stringify(row));

const limits = { maxImageBytes: 20971520, maxImagePixels: 100000000, maxImageDimension: 12000, maxPixels: 100000000, maxDimension: 12000 };
const policy = {
  maxPixels: store.DEFAULT_NORMALIZED_IMAGE_MAX_PIXELS,
  maxDimension: store.DEFAULT_NORMALIZED_IMAGE_MAX_DIMENSION,
  maxBytes: store.DEFAULT_NORMALIZED_IMAGE_MAX_BYTES,
};

const chunk = (type, body) => {
  const name = Buffer.from(type, 'latin1');
  const size = Buffer.alloc(4);
  size.writeUInt32BE(body.length);
  const check = Buffer.alloc(4);
  check.writeUInt32BE(crc32(Buffer.concat([name, body])));
  return Buffer.concat([size, name, body, check]);
};
// A real PNG: stripes, so a resize or a turn shows up in the pixels' size if nothing else.
const png = (width, height, channels) => {
  const head = Buffer.alloc(13);
  head.writeUInt32BE(width, 0);
  head.writeUInt32BE(height, 4);
  head[8] = 8;
  head[9] = channels === 4 ? 6 : 2;
  const row = Buffer.alloc(1 + width * channels);
  for (let x = 0; x < width; x++) {
    row[1 + x * channels] = x & 0xff;
    row[2 + x * channels] = 0x40;
    row[3 + x * channels] = 0x80;
    if (channels === 4) row[4 + x * channels] = x % 2 ? 0x80 : 0xff;
  }
  const raw = Buffer.concat(Array.from({ length: height }, () => row));
  return Buffer.concat([
    Buffer.from('\x89PNG\r\n\x1a\n', 'latin1'), chunk('IHDR', head), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ]);
};
const exifSegment = orientation => {
  const tiff = Buffer.alloc(26);
  tiff.write('II', 0, 'latin1');
  tiff.writeUInt16LE(42, 2);
  tiff.writeUInt32LE(8, 4);
  tiff.writeUInt16LE(1, 8);
  tiff.writeUInt16LE(0x0112, 10);
  tiff.writeUInt16LE(3, 12);
  tiff.writeUInt32LE(1, 14);
  tiff.writeUInt16LE(orientation, 18);
  const body = Buffer.concat([Buffer.from('Exif\0\0', 'latin1'), tiff]);
  const head = Buffer.from([0xff, 0xe1, 0, 0]);
  head.writeUInt16BE(body.length + 2, 2);
  return Buffer.concat([head, body]);
};

// In the app the attachments live under DSH_HOME, on the same volume as the publisher's ledger.
const root = mkdtempSync(join(process.env.DSH_HOME, 'attachments-'));
let failures = 0;

async function flow(name, data, mediaType, expect) {
  const started = Date.now();
  try {
    const prepared = await store.prepareImageFile({ data: new Uint8Array(data), mediaType, name: 'x' }, limits, policy);
    await store.commitPreparedImageFile(root, prepared);
    const read = await store.readImageFile(root, prepared.ref);
    const request = await store.readRequestImageFile(join(root, 'cache'), read, { width: 64, height: 64, maxBytes: 200000 });
    const cached = await store.readRequestImageFile(join(root, 'cache'), read, { width: 64, height: 64, maxBytes: 200000 });
    assert.equal(cached.bytes, request.bytes);
    assert.ok(Math.max(request.width, request.height) <= 64, 'request size');
    const stored = inspect(Buffer.from(prepared.data));
    for (const key of ['exif', 'icc', 'xmp', 'iptc', 'comments', 'orientation']) assert.equal(stored[key], undefined, key);
    assert.equal(stored.depth, 'uchar');
    assert.equal(stored.space, 'srgb');
    expect?.(prepared.ref, request);
    note({ name, pass: true, ms: Date.now() - started, in: data.length, out: prepared.ref.bytes, stored: prepared.ref.mediaType,
      size: [prepared.ref.width, prepared.ref.height], request: [request.mediaType, request.width, request.height, request.bytes] });
    return prepared;
  } catch (error) {
    failures++;
    note({ name, pass: false, ms: Date.now() - started, code: error?.code, error: String(error?.message ?? error).slice(0, 300), cause: String(error?.cause?.message ?? '').slice(0, 300) });
    return undefined;
  }
}

async function refused(name, data, mediaType) {
  try {
    await store.prepareImageFile({ data: new Uint8Array(data), mediaType }, limits, policy);
    failures++;
    note({ name, pass: false, error: 'accepted' });
  } catch (error) {
    const pass = error?.code === 'INVALID_IMAGE';
    if (!pass) failures++;
    note({ name, pass, code: error?.code });
  }
}

const opaque = png(320, 240, 3);
const clear = png(320, 240, 4);
const big = png(4000, 3000, 3);
const bigClear = png(3000, 2000, 4);

// A real JPEG from Apple's encoder, then the same with an orientation added, as a camera would.
const encoded = await native.encode(opaque, 0, 0, false, false, 0.8);
assert.deepEqual([encoded.width, encoded.height], [320, 240]);
note({ name: 'encoder', raw: inspect(encoded.data).exif === true ? 'writes exif' : 'no exif', icc: inspect(encoded.data).icc === true, bytes: encoded.data.length });
const jpeg = encoded.data;
const clean = bare(jpeg);
const turned = Buffer.concat([clean.subarray(0, 2), exifSegment(6), clean.subarray(2)]);

await flow('opaque png', opaque, 'image/png', ref => assert.equal(ref.mediaType, 'image/png'));
await flow('png with alpha', clear, 'image/png', (ref, request) => {
  assert.equal(ref.mediaType, 'image/png');
  assert.equal(request.mediaType, 'image/png');
  assert.equal(request.hasAlpha, true);
});
await flow('camera jpeg', jpeg, 'image/jpeg', ref => assert.equal(ref.mediaType, 'image/jpeg'));
await flow('turned jpeg', turned, 'image/jpeg', ref => assert.deepEqual([ref.width, ref.height], [240, 320]));
await flow('big png', big, 'image/png', ref => {
  assert.equal(ref.mediaType, 'image/jpeg');
  assert.ok(ref.width * ref.height <= policy.maxPixels);
  assert.deepEqual([ref.originalDimensions?.width, ref.originalDimensions?.height], [4000, 3000]);
});
await flow('big png with alpha', bigClear, 'image/png', ref => {
  assert.equal(ref.mediaType, 'image/png');
  assert.ok(ref.width * ref.height <= policy.maxPixels);
});
await refused('jpeg cut short', jpeg.subarray(0, jpeg.length >> 1), 'image/jpeg');
await refused('png with bad pixels', Buffer.concat([opaque.subarray(0, 41), Buffer.alloc(16, 0x55), opaque.subarray(57)]), 'image/png');
await refused('not an image', Buffer.from('this is not an image at all'), 'image/png');

writeFileSync(join(root, 'done'), '');
note({ name: 'done', failures });
process.exitCode = failures === 0 ? 0 : 1;
// Only fires if something the publisher opened is keeping the loop alive.
setTimeout(() => process.exit(), 5000).unref();
