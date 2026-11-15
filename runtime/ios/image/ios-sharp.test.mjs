import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import test from 'node:test';
import { crc32, deflateSync } from 'node:zlib';

const require = createRequire(import.meta.url);
const sharp = require('./ios-sharp.cjs');
const { inspect, bare } = sharp;

const chunk = (type, body = Buffer.alloc(0)) => {
  const size = Buffer.alloc(4);
  size.writeUInt32BE(body.length);
  const named = Buffer.concat([Buffer.from(type, 'latin1'), body]);
  const check = Buffer.alloc(4);
  check.writeUInt32BE(crc32(named));
  return Buffer.concat([size, named, check]);
};
const png = (width, height, { colour = 6, bits = 8, extra = [] } = {}) => {
  const head = Buffer.alloc(13);
  head.writeUInt32BE(width, 0);
  head.writeUInt32BE(height, 4);
  head[8] = bits;
  head[9] = colour;
  return Buffer.concat([
    Buffer.from('\x89PNG\r\n\x1a\n', 'latin1'), chunk('IHDR', head), ...extra,
    chunk('IDAT', deflateSync(Buffer.alloc(8))), chunk('IEND'),
  ]);
};
const segment = (marker, body) => {
  const head = Buffer.from([0xff, marker, 0, 0]);
  head.writeUInt16BE(body.length + 2, 2);
  return Buffer.concat([head, body]);
};
const frame = (width, height, components = 3, bits = 8) => {
  const body = Buffer.alloc(6 + components * 3);
  body[0] = bits;
  body.writeUInt16BE(height, 1);
  body.writeUInt16BE(width, 3);
  body[5] = components;
  return segment(0xc0, body);
};
const exif = orientation => {
  const tiff = Buffer.alloc(26);
  tiff.write('II', 0, 'latin1');
  tiff.writeUInt16LE(42, 2);
  tiff.writeUInt32LE(8, 4);
  tiff.writeUInt16LE(1, 8);
  tiff.writeUInt16LE(0x0112, 10);
  tiff.writeUInt16LE(3, 12);
  tiff.writeUInt32LE(1, 14);
  tiff.writeUInt16LE(orientation, 18);
  return Buffer.concat([Buffer.from('Exif\0\0', 'latin1'), tiff]);
};
const jpeg = (...segments) => Buffer.concat([
  Buffer.from([0xff, 0xd8]), ...segments, segment(0xda, Buffer.alloc(6)), Buffer.from([0x12, 0x34, 0xff, 0x00, 0x56, 0xff, 0xd9]),
]);

test('reads a plain JPEG', () => {
  const info = inspect(jpeg(segment(0xe0, Buffer.from('JFIF\0')), frame(640, 480)));
  assert.deepEqual([info.format, info.width, info.height, info.depth, info.space, info.hasAlpha, info.pages],
    ['jpeg', 640, 480, 'uchar', 'srgb', false, 1]);
  for (const key of ['exif', 'xmp', 'iptc', 'icc', 'comments', 'orientation']) assert.equal(info[key], undefined, key);
  assert.equal(info.hasProfile, false);
});

test('sees what a JPEG carries besides pixels', () => {
  const info = inspect(jpeg(
    segment(0xe1, exif(6)), segment(0xe1, Buffer.from('http://ns.adobe.com/xap/1.0/\0')), segment(0xe2, Buffer.from('ICC_PROFILE\0')),
    segment(0xed, Buffer.from('Photoshop 3.0\0')), segment(0xfe, Buffer.from('hello')), frame(10, 20),
  ));
  assert.equal(info.orientation, 6);
  for (const key of ['exif', 'xmp', 'iptc', 'icc', 'comments']) assert.equal(info[key], true, key);
  assert.equal(info.hasProfile, true);
});

test('tells grey, CMYK and 16-bit from sRGB', () => {
  assert.equal(inspect(jpeg(frame(1, 1, 1))).space, 'b-w');
  assert.equal(inspect(jpeg(frame(1, 1, 4))).space, 'cmyk');
  assert.equal(inspect(png(1, 1, { bits: 16 })).depth, 'ushort');
  assert.equal(inspect(png(1, 1, { colour: 0 })).space, 'b-w');
});

test('a JPEG cut short is refused, however good its start looks', () => {
  const whole = jpeg(frame(10, 10));
  assert.doesNotThrow(() => inspect(whole));
  assert.throws(() => inspect(whole.subarray(0, whole.length - 2)), { code: 'ERR_IOS_IMAGE' });
  assert.throws(() => inspect(whole.subarray(0, 8)), { code: 'ERR_IOS_IMAGE' });
  assert.throws(() => inspect(Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), segment(0xda, Buffer.alloc(6))])), { code: 'ERR_IOS_IMAGE' });
});

test('reads a PNG and its alpha', () => {
  assert.equal(inspect(png(3, 4)).hasAlpha, true);
  assert.equal(inspect(png(3, 4, { colour: 2 })).hasAlpha, false);
  assert.equal(inspect(png(3, 4, { colour: 3, extra: [chunk('tRNS', Buffer.from([0]))] })).hasAlpha, true);
  const info = inspect(png(3, 4));
  assert.deepEqual([info.width, info.height, info.space, info.depth], [3, 4, 'srgb', 'uchar']);
});

test('sees what a PNG carries, and an animated one', () => {
  const info = inspect(png(1, 1, { extra: [chunk('iCCP', Buffer.from('x')), chunk('eXIf', exif(3).subarray(6)), chunk('tEXt', Buffer.from('a\0b'))] }));
  assert.equal(info.icc, true);
  assert.equal(info.exif, true);
  assert.equal(info.orientation, 3);
  assert.equal(info.comments, true);
  const frames = Buffer.alloc(8);
  frames.writeUInt32BE(5, 0);
  assert.equal(inspect(png(1, 1, { extra: [chunk('acTL', frames)] })).pages, 5);
});

test('a PNG with no end, or a chunk running off the end, is refused', () => {
  const whole = png(1, 1);
  assert.throws(() => inspect(whole.subarray(0, whole.length - 12)), { code: 'ERR_IOS_IMAGE' });
  assert.throws(() => inspect(whole.subarray(0, whole.length - 20)), { code: 'ERR_IOS_IMAGE' });
});

test('a damaged PNG chunk is refused', () => {
  const damaged = Buffer.from(png(1, 1));
  damaged[damaged.length - 16] ^= 0xff;
  assert.throws(() => inspect(damaged), { code: 'ERR_IOS_IMAGE' });
});

test('the first Exif block decides the orientation', () => {
  assert.equal(inspect(jpeg(segment(0xe1, exif(6)), segment(0xe1, exif(1)), frame(1, 1))).orientation, 6);
});

test('reads a GIF: frames and transparency', () => {
  const screen = Buffer.alloc(13);
  screen.write('GIF89a', 0, 'latin1');
  screen.writeUInt16LE(7, 6);
  screen.writeUInt16LE(9, 8);
  const image = Buffer.concat([Buffer.from([0x2c, 0, 0, 0, 0, 7, 0, 9, 0, 0, 2, 1, 0, 0])]);
  const control = Buffer.from([0x21, 0xf9, 4, 1, 0, 0, 0, 0]);
  const info = inspect(Buffer.concat([screen, control, image, image, Buffer.from([0x3b])]));
  assert.deepEqual([info.format, info.width, info.height, info.pages, info.hasAlpha], ['gif', 7, 9, 2, true]);
  assert.throws(() => inspect(Buffer.concat([screen, image])), { code: 'ERR_IOS_IMAGE' });
  assert.throws(() => inspect(Buffer.concat([screen, Buffer.from([0x3b])])), { code: 'ERR_IOS_IMAGE' });
});

test('reads the three kinds of WebP', () => {
  const riff = (...parts) => {
    const body = Buffer.concat([Buffer.from('WEBP'), ...parts]);
    const head = Buffer.alloc(8);
    head.write('RIFF', 0, 'latin1');
    head.writeUInt32LE(body.length, 4);
    return Buffer.concat([head, body]);
  };
  const part = (type, body) => {
    const head = Buffer.alloc(8);
    head.write(type, 0, 'latin1');
    head.writeUInt32LE(body.length, 4);
    return Buffer.concat([head, body, Buffer.alloc(body.length & 1)]);
  };
  const lossy = Buffer.alloc(10);
  lossy.set([0x9d, 0x01, 0x2a], 3);
  lossy.writeUInt16LE(100, 6);
  lossy.writeUInt16LE(50, 8);
  const simple = inspect(riff(part('VP8 ', lossy)));
  assert.deepEqual([simple.format, simple.width, simple.height, simple.hasAlpha], ['webp', 100, 50, false]);
  const lossless = Buffer.alloc(5);
  lossless[0] = 0x2f;
  lossless.writeUInt32LE((1 << 28) | (19 << 14) | 29, 1);
  const alpha = inspect(riff(part('VP8L', lossless)));
  assert.deepEqual([alpha.width, alpha.height, alpha.hasAlpha], [30, 20, true]);
  const extended = Buffer.alloc(10);
  extended[0] = 0x10 | 0x20;
  extended.writeUIntLE(199, 4, 3);
  extended.writeUIntLE(99, 7, 3);
  const full = inspect(riff(part('VP8X', extended), part('ICCP', Buffer.from('x')), part('VP8 ', lossy)));
  assert.deepEqual([full.width, full.height, full.hasAlpha, full.icc], [200, 100, true, true]);
  const whole = riff(part('VP8 ', lossy));
  assert.throws(() => inspect(whole.subarray(0, 20)), { code: 'ERR_IOS_IMAGE' });
});

test('anything else is refused', () => {
  assert.throws(() => inspect(Buffer.from('not an image')), { code: 'ERR_IOS_IMAGE' });
  assert.throws(() => inspect(Buffer.alloc(0)), { code: 'ERR_IOS_IMAGE' });
  assert.throws(() => inspect(png(0, 1)), { code: 'ERR_IOS_IMAGE' });
  assert.throws(() => inspect(jpeg(frame(0, 0))), { code: 'ERR_IOS_IMAGE' });
  const tiff = Buffer.from('II*\0xxxxxxxx', 'latin1');
  assert.throws(() => inspect(tiff), { code: 'ERR_IOS_IMAGE' });
});

test('what comes out carries nothing but pixels', () => {
  const clean = bare(jpeg(segment(0xe0, Buffer.from('JFIF\0')), segment(0xe1, exif(6)), segment(0xe2, Buffer.from('ICC_PROFILE\0')),
    segment(0xfe, Buffer.from('hi')), frame(5, 5)));
  const info = inspect(clean);
  for (const key of ['exif', 'icc', 'comments', 'orientation']) assert.equal(info[key], undefined, key);
  assert.equal(info.width, 5);
  const tidy = bare(png(2, 2, { extra: [chunk('iCCP', Buffer.from('x')), chunk('eXIf', exif(3).subarray(6)), chunk('iDOT', Buffer.alloc(8))] }));
  const facts = inspect(tidy);
  assert.equal(facts.icc, undefined);
  assert.equal(facts.exif, undefined);
  assert.equal(tidy.includes('iDOT'), false);
  assert.equal(facts.hasAlpha, true);
});

test('the pipeline asks the decoder for what the store asked for', async t => {
  const calls = [];
  const original = process._linkedBinding;
  process._linkedBinding = name => {
    assert.equal(name, 'dsh_ios_image');
    return {
      decode: async buffer => { calls.push(['decode', buffer.length]); },
      encode: async (buffer, width, height, orient, usePng, quality) => {
        calls.push(['encode', width, height, orient, usePng, quality]);
        return { data: usePng ? png(4, 3) : jpeg(segment(0xe1, exif(6)), frame(4, 3)), width: 4, height: 3 };
      },
    };
  };
  t.after(() => { process._linkedBinding = original; });
  const source = jpeg(frame(40, 30));
  // A view into something larger, the way the store's Uint8Arrays can be.
  const holder = Buffer.alloc(16 + source.length);
  source.copy(holder, 16);
  const view = new Uint8Array(holder.buffer, holder.byteOffset + 16, source.length);
  assert.equal((await sharp(new Uint8Array(source)).metadata()).width, 40);
  assert.equal((await sharp(view).metadata()).height, 30);
  assert.equal((await sharp(new Uint8Array(source)).raw().toBuffer()).length, 0);
  const prepared = sharp(new Uint8Array(source)).rotate().toColourspace('srgb').resize({ width: 20, height: 15, fit: 'inside', withoutEnlargement: true });
  const first = await prepared.clone().jpeg({ quality: 85 }).toBuffer({ resolveWithObject: true });
  await prepared.clone().jpeg({ quality: 60 }).toBuffer({ resolveWithObject: true });
  const alpha = await sharp(new Uint8Array(source)).toColourspace('srgb').resize({ height: 15, withoutEnlargement: true }).png().toBuffer({ resolveWithObject: true });
  assert.deepEqual(calls, [
    ['decode', source.length],
    ['encode', 20, 15, true, false, 0.85],
    ['encode', 20, 15, true, false, 0.6],
    ['encode', 0, 15, false, true, 0.85],
  ]);
  assert.deepEqual([first.info.width, first.info.height, first.info.format], [4, 3, 'jpeg']);
  assert.equal(inspect(first.data).exif, undefined, 'stripped');
  assert.equal(inspect(first.data).orientation, undefined, 'stripped');
  assert.equal(alpha.info.format, 'png');
  await assert.rejects(sharp(new Uint8Array(source)).toBuffer(), /No undefined encoder/);
});
