'use strict';
// What dsh-attachment-local asks of sharp, done with what's already on an iPhone. sharp's native
// library can't load here, and without this the engine refuses every image: photos the user
// attaches and screenshots from the tools alike. The store's own rules (limits, normalizing,
// content addressing, verifying what it wrote) stay as they are and run against this.
//
// The containers are read here so the answers don't depend on what ImageIO chooses to report,
// and pixels go through ImageIO in runtime/ios/host/image_binding.cc. ImageIO can't write WebP,
// so tooling/ios/specialize-runtime.py has the store keep alpha in PNG instead.

const { crc32 } = require('node:zlib');

const invalid = () => Object.assign(new Error('Unsupported or malformed image data.'), { code: 'ERR_IOS_IMAGE' });
const native = () => process._linkedBinding('dsh_ios_image');
const startsWith = (data, at, text) => data.toString('latin1', at, at + text.length) === text;

// The orientation tag from an Exif block, or undefined.
function exifOrientation(data, start, end) {
  if (end - start < 8) return undefined;
  const little = startsWith(data, start, 'II');
  if (!little && !startsWith(data, start, 'MM')) return undefined;
  const u16 = at => (little ? data.readUInt16LE(at) : data.readUInt16BE(at));
  const u32 = at => (little ? data.readUInt32LE(at) : data.readUInt32BE(at));
  const directory = start + u32(start + 4);
  if (directory + 2 > end) return undefined;
  const count = u16(directory);
  for (let index = 0; index < count; index++) {
    const entry = directory + 2 + index * 12;
    if (entry + 12 > end) return undefined;
    if (u16(entry) === 0x0112) {
      const value = u16(entry + 8);
      return value >= 1 && value <= 8 ? value : undefined;
    }
  }
  return undefined;
}

function jpeg(data) {
  const info = { format: 'jpeg', pages: 1, hasAlpha: false, depth: 'uchar', hasProfile: false };
  let at = 2;
  let scan = -1;
  while (at < data.length) {
    if (data[at] !== 0xff) throw invalid();
    while (data[at] === 0xff) at++;
    const marker = data[at++];
    if (marker === undefined || marker === 0x00 || marker === 0xd8 || marker === 0xd9) throw invalid();
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (at + 2 > data.length) throw invalid();
    const size = data.readUInt16BE(at);
    if (size < 2 || at + size > data.length) throw invalid();
    const body = at + 2;
    const end = at + size;
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      if (size < 8) throw invalid();
      if (data[body] !== 8) info.depth = 'ushort';
      info.height = data.readUInt16BE(body + 1);
      info.width = data.readUInt16BE(body + 3);
      const components = data[body + 5];
      info.space = components === 1 ? 'b-w' : components === 4 ? 'cmyk' : 'srgb';
    } else if (marker === 0xe1 && startsWith(data, body, 'Exif\0\0')) {
      // The first one is the one decoders go by.
      if (!info.exif) {
        const orientation = exifOrientation(data, body + 6, end);
        if (orientation !== undefined) info.orientation = orientation;
      }
      info.exif = true;
    } else if (marker === 0xe1 && startsWith(data, body, 'http://ns.adobe.com/xap')) {
      info.xmp = true;
    } else if (marker === 0xe2 && startsWith(data, body, 'ICC_PROFILE\0')) {
      info.icc = true;
      info.hasProfile = true;
    } else if (marker === 0xed && startsWith(data, body, 'Photoshop')) {
      info.iptc = true;
    } else if (marker === 0xfe) {
      info.comments = true;
    }
    at = end;
    if (marker === 0xda) {
      scan = at;
      break;
    }
  }
  // A file cut short has no end marker after its first scan. The decoder can paper over that.
  if (scan < 0 || info.width === undefined || data.lastIndexOf(Buffer.from([0xff, 0xd9])) < scan) throw invalid();
  return info;
}

const PNG = '\x89PNG\r\n\x1a\n';

function png(data) {
  const info = { format: 'png', pages: 1, hasProfile: false };
  let at = 8;
  let ended = false;
  while (at + 12 <= data.length) {
    const size = data.readUInt32BE(at);
    const type = data.toString('latin1', at + 4, at + 8);
    const body = at + 8;
    if (body + size + 4 > data.length) throw invalid();
    if (at === 8 && (type !== 'IHDR' || size !== 13)) throw invalid();
    // ImageIO can return part of an image from a damaged file without saying so.
    if (crc32(data.subarray(at + 4, body + size)) !== data.readUInt32BE(body + size)) throw invalid();
    if (type === 'IHDR') {
      info.width = data.readUInt32BE(body);
      info.height = data.readUInt32BE(body + 4);
      const bits = data[body + 8];
      const colour = data[body + 9];
      info.depth = bits === 16 ? 'ushort' : 'uchar';
      const grey = colour === 0 || colour === 4;
      info.space = bits === 16 ? (grey ? 'grey16' : 'rgb16') : grey ? 'b-w' : 'srgb';
      info.hasAlpha = colour === 4 || colour === 6;
    } else if (type === 'tRNS') {
      info.hasAlpha = true;
    } else if (type === 'acTL') {
      if (size >= 4) info.pages = Math.max(1, data.readUInt32BE(body));
    } else if (type === 'iCCP') {
      info.icc = true;
      info.hasProfile = true;
    } else if (type === 'eXIf') {
      info.exif = true;
      const orientation = exifOrientation(data, body, body + size);
      if (orientation !== undefined) info.orientation = orientation;
    } else if (type === 'iTXt' && startsWith(data, body, 'XML:com.adobe.xmp')) {
      info.xmp = true;
    } else if (type === 'tEXt' || type === 'zTXt' || type === 'iTXt') {
      info.comments = true;
    } else if (type === 'IEND') {
      ended = true;
      break;
    }
    at = body + size + 4;
  }
  if (!ended || info.width === undefined) throw invalid();
  return info;
}

function gif(data) {
  if (data.length < 13) throw invalid();
  const info = {
    format: 'gif', width: data.readUInt16LE(6), height: data.readUInt16LE(8),
    pages: 0, hasAlpha: false, depth: 'uchar', space: 'srgb', hasProfile: false,
  };
  const table = flags => (flags & 0x80 ? 3 * 2 ** ((flags & 7) + 1) : 0);
  const blocks = from => {
    let at = from;
    while (at < data.length && data[at] !== 0) at += data[at] + 1;
    if (at >= data.length) throw invalid();
    return at + 1;
  };
  let at = 13 + table(data[10]);
  for (;;) {
    if (at >= data.length) throw invalid();
    const kind = data[at];
    if (kind === 0x3b) break;
    if (kind === 0x21) {
      if (data[at + 1] === 0xf9 && at + 3 < data.length && data[at + 3] & 1) info.hasAlpha = true;
      at = blocks(at + 2);
    } else if (kind === 0x2c) {
      if (at + 10 > data.length) throw invalid();
      info.pages++;
      at = blocks(at + 10 + table(data[at + 9]) + 1);
    } else {
      throw invalid();
    }
  }
  if (info.pages === 0) throw invalid();
  return info;
}

function webp(data) {
  if (data.length < 16 || data.readUInt32LE(4) + 8 > data.length) throw invalid();
  const info = { format: 'webp', pages: 1, hasAlpha: false, depth: 'uchar', space: 'srgb', hasProfile: false };
  const end = data.readUInt32LE(4) + 8;
  let frames = 0;
  let at = 12;
  while (at + 8 <= end) {
    const type = data.toString('latin1', at, at + 4);
    const size = data.readUInt32LE(at + 4);
    const body = at + 8;
    if (body + size > end) throw invalid();
    if (type === 'VP8X' && size >= 10) {
      if (data[body] & 0x10) info.hasAlpha = true;
      info.width = data.readUIntLE(body + 4, 3) + 1;
      info.height = data.readUIntLE(body + 7, 3) + 1;
    } else if (type === 'VP8 ' && size >= 10 && info.width === undefined) {
      if (data[body + 3] !== 0x9d || data[body + 4] !== 0x01 || data[body + 5] !== 0x2a) throw invalid();
      info.width = data.readUInt16LE(body + 6) & 0x3fff;
      info.height = data.readUInt16LE(body + 8) & 0x3fff;
    } else if (type === 'VP8L' && size >= 5 && info.width === undefined) {
      if (data[body] !== 0x2f) throw invalid();
      const bits = data.readUInt32LE(body + 1);
      info.width = (bits & 0x3fff) + 1;
      info.height = ((bits >>> 14) & 0x3fff) + 1;
      if ((bits >>> 28) & 1) info.hasAlpha = true;
    } else if (type === 'ANMF') {
      frames++;
    } else if (type === 'ICCP') {
      info.icc = true;
      info.hasProfile = true;
    } else if (type === 'EXIF') {
      info.exif = true;
      const start = startsWith(data, body, 'Exif\0\0') ? body + 6 : body;
      const orientation = exifOrientation(data, start, body + size);
      if (orientation !== undefined) info.orientation = orientation;
    } else if (type === 'XMP ') {
      info.xmp = true;
    }
    at = body + size + (size & 1);
  }
  if (frames > 1) info.pages = frames;
  if (info.width === undefined) throw invalid();
  return info;
}

function inspect(data) {
  let info;
  if (data.length >= 3 && data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff) info = jpeg(data);
  else if (startsWith(data, 0, PNG)) info = png(data);
  else if (startsWith(data, 0, 'GIF87a') || startsWith(data, 0, 'GIF89a')) info = gif(data);
  else if (startsWith(data, 0, 'RIFF') && startsWith(data, 8, 'WEBP')) info = webp(data);
  else throw invalid();
  if (!(info.width > 0) || !(info.height > 0)) throw invalid();
  return info;
}

// ImageIO writes its own Exif and colour profile into what it encodes. The pixels are in sRGB
// already, and the store only accepts output that carries nothing but pixels.
function bare(data) {
  const parts = [];
  if (data[0] === 0xff) {
    parts.push(data.subarray(0, 2));
    let at = 2;
    for (;;) {
      if (at + 4 > data.length || data[at] !== 0xff) throw invalid();
      const marker = data[at + 1];
      if (marker === 0xda) {
        parts.push(data.subarray(at));
        return Buffer.concat(parts);
      }
      const end = at + 2 + data.readUInt16BE(at + 2);
      if (end > data.length) throw invalid();
      if (!((marker >= 0xe1 && marker <= 0xef) || marker === 0xfe)) parts.push(data.subarray(at, end));
      at = end;
    }
  }
  parts.push(data.subarray(0, 8));
  const kept = new Set(['IHDR', 'PLTE', 'tRNS', 'IDAT', 'IEND']);
  let at = 8;
  while (at + 12 <= data.length) {
    const end = at + 12 + data.readUInt32BE(at);
    if (end > data.length) throw invalid();
    if (kept.has(data.toString('latin1', at + 4, at + 8))) parts.push(data.subarray(at, end));
    at = end;
  }
  return Buffer.concat(parts);
}

class Pipeline {
  constructor(data, plan) {
    this.data = data;
    this.plan = plan;
  }
  clone() {
    return new Pipeline(this.data, { ...this.plan });
  }
  async metadata() {
    return inspect(this.data);
  }
  rotate() {
    this.plan.orient = true;
    return this;
  }
  // Everything this writes is sRGB.
  toColourspace() {
    return this;
  }
  // Always fit:inside without enlarging, the only way the store resizes.
  resize({ width, height }) {
    this.plan.width = width ?? 0;
    this.plan.height = height ?? 0;
    return this;
  }
  raw() {
    this.plan.output = 'raw';
    return this;
  }
  jpeg({ quality }) {
    this.plan.output = 'jpeg';
    this.plan.quality = quality;
    return this;
  }
  png() {
    this.plan.output = 'png';
    return this;
  }
  async toBuffer(options) {
    const { orient = false, width = 0, height = 0, output, quality = 85 } = this.plan;
    if (output === 'raw') {
      // The store only wants to know that every pixel decodes, so they stay out of the JS heap.
      await native().decode(this.data);
      return Buffer.alloc(0);
    }
    if (output !== 'jpeg' && output !== 'png') throw new Error(`No ${output} encoder on iOS.`);
    const encoded = await native().encode(this.data, width, height, orient, output === 'png', quality / 100);
    const data = bare(encoded.data);
    if (!options?.resolveWithObject) return data;
    return { data, info: { format: output, size: data.length, width: encoded.width, height: encoded.height } };
  }
}

module.exports = data => new Pipeline(Buffer.from(data.buffer, data.byteOffset, data.byteLength), {});
module.exports.inspect = inspect;
module.exports.bare = bare;
