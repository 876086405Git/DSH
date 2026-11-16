// Complete product ETS and EntryAbility, real Linux private files and valid PNG bytes.
// Only SDK media/image/texture services are doubles: this is not codec/device proof.
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { resolve, dirname } from 'node:path';
import { assertEntryAbilityImports, createEntryAbilityImports } from './entry-ability-fixture.mjs';
import vm from 'node:vm';
import crypto from 'node:crypto';
import zlib from 'node:zlib';

export function barrier() {
  let release; const promise = new Promise(resolve => { release = resolve; });
  return { promise, release };
}
function crc32(bytes) {
  let c = 0xffffffff;
  for (const b of bytes) { c ^= b; for (let i = 0; i < 8; i++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0); }
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(name, data) {
  const type = Buffer.from(name), length = Buffer.alloc(4), crc = Buffer.alloc(4);
  length.writeUInt32BE(data.length); crc.writeUInt32BE(crc32(Buffer.concat([type, data])));
  return Buffer.concat([length, type, data, crc]);
}
function png(width, height) {
  const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 6;
  const scan = Buffer.alloc((width * 4 + 1) * height, 0x80);
  for (let y = 0; y < height; y++) scan[y * (width * 4 + 1)] = 0;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk('IHDR', header),
    chunk('IDAT', zlib.deflateSync(scan)), chunk('IEND', Buffer.alloc(0))]);
}
export function launchFixture(repo, filesDir, options = {}) {
  const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
  const channels = new Map(), plugins = [], loaded = [], isolated = [], calls = [], events = [];
  const fds = new Set(), textures = new Set(), players = [], objects = [];
  const state = { failRelease: false, ...options };
  const record = (kind, value) => calls.push({ kind, value });
  const mapError = error => { if (error.code === 'ENOENT') error.code = 13900002; throw error; };
  const io = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 0o100, NOFOLLOW: 0o400000, NONBLOCK: 0o4000 },
    async lstat(path) { try { return fs.lstatSync(path); } catch (error) { return mapError(error); } },
    async stat(fd) { return fs.fstatSync(fd); },
    async open(path, mode) {
      let flags = mode & 3;
      if (mode & 0o100) flags |= fs.constants.O_CREAT;
      if (mode & 0o400000) flags |= fs.constants.O_NOFOLLOW;
      if (mode & 0o4000) flags |= fs.constants.O_NONBLOCK;
      const fd = fs.openSync(path, flags, 0o600); fds.add(fd); record('fd.open', { path, fd, mode }); return { fd };
    },
    async close(fd) { fs.closeSync(fd); fds.delete(fd); record('fd.close', fd); },
    async mkdtemp(template) { return fs.mkdtempSync(template.replace(/XXXXXX$/, '')); },
    async write(fd, data, opt) { return fs.writeSync(fd, Buffer.from(data), 0, data.byteLength, opt.offset); },
    async fsync(fd) { fs.fsyncSync(fd); },
    async rename(from, to) { fs.renameSync(from, to); record('poster.rename', to); },
    async unlink(path) { try { fs.unlinkSync(path); } catch (error) { return mapError(error); } },
    async rmdir(path) { fs.rmdirSync(path); },
    async listFile(path) { return fs.readdirSync(path); },
  };
  const makeMedia = kind => {
    const object = { fdSrc: null, released: false, async release() {
      record(kind + '.release', this.fdSrc?.fd);
      if (state.failRelease) throw new Error('fixture media release failure');
      this.released = true;
    } };
    objects.push(object); return object;
  };
  const media = {
    AVImageQueryOptions: { AV_IMAGE_QUERY_CLOSEST_SYNC: 2 },
    async createAVMetadataExtractor() {
      record('extractor.create'); await state.extractorGate?.promise;
      const value = makeMedia('extractor');
      value.fetchMetadata = async () => ({ hasVideo: 'yes', duration: '2900', videoWidth: '1080',
        videoHeight: '1920', videoOrientation: '0', ...state.metadata });
      return value;
    },
    async createAVImageGenerator() {
      const value = makeMedia('generator'); record('generator.create');
      value.fetchFrameByTime = async (time, query, params) => {
        record('generator.frame', { time, query, params }); await state.frameGate?.promise;
        if (state.frameError) throw new Error('fixture decoder failure');
        const pixel = { width: params.width, height: params.height, released: false,
          async getImageInfo() { return { size: { width: this.width, height: this.height } }; },
          async release() { this.released = true; record('pixels.release'); } };
        objects.push(pixel); return pixel;
      }; return value;
    },
    async createAVPlayer() {
      record('player.create'); await state.playerGate?.promise;
      const player = makeMedia('player'); players.push(player);
      const handlers = new Map(); let fdSrc, surface;
      Object.defineProperty(player, 'fdSrc', { get: () => fdSrc, set: value => {
        fdSrc = value; queueMicrotask(() => player.emit('stateChange', 'initialized'));
      }});
      Object.defineProperty(player, 'surfaceId', { get: () => surface, set: value => {
        if (player.state !== 'initialized') throw new Error('surface must be initialized');
        surface = value; record('player.surface', value);
      }});
      player.on = (name, handler) => handlers.set(name, handler);
      player.emit = (name, value) => { if (name === 'stateChange') player.state = value; handlers.get(name)?.(value); };
      player.prepare = async () => { record('player.prepare'); await state.prepareGate?.promise;
        player.emit('stateChange', 'prepared'); };
      player.setVolume = value => record('player.volume', value);
      player.width = 1080; player.height = 1920;
      player.play = async () => { record('player.play'); if (state.playError) throw new Error('fixture play failure'); player.emit('startRenderFrame'); };
      return player;
    },
  };
  const image = { createImagePacker() {
    const packer = { released: false, async packToData(pixel, config) {
      record('packer.png', config); const bytes = png(pixel.width, pixel.height);
      return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    }, async release() { this.released = true; record('packer.release'); } };
    objects.push(packer); return packer;
  } };
  // Use the entire fixed public renderer. Only its FlutterNapi boundary is a double.
  // Deprecated createSurfaceTexture/release therefore retain their actual 0/throw behavior.
  const napi = {
    registerTexture(id) { textures.add(id); record('texture.create', id); return state.surface ?? 123456; },
    getTextureNativeWindowId() { return 654321; }, getTextureNativeWindowPtr() { return 654321n; },
    unregisterTexture(id) { textures.delete(id); record('texture.release', id); },
    setTextureBufferSize(id, width, height) { record('texture.size', { id, width, height }); },
  };
  class Channel {
    constructor(_messenger, name) { this.name = name; channels.set(name, this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, value) { events.push({ channel: this.name, method,
      arguments: value instanceof Map ? Object.fromEntries(value) : value }); }
  }
  class FlutterAbility { configureFlutterEngine() {} }
  const entryImports = createEntryAbilityImports({
    '../plugins/LaunchPlugin': () => load(resolve(repo, 'app/ohos/entry/src/main/ets/plugins/LaunchPlugin.ets')),
    '../plugins/LaunchClipPlugin': () => load(resolve(repo, 'app/ohos/entry/src/main/ets/plugins/LaunchClipPlugin.ets')),
    '../runtime/NativeHost': () => ({ nativeHostState: () => ({ phase: 'idle' }) }),
  });
  const cache = new Map();
  function load(path) {
    if (cache.has(path)) return cache.get(path).exports;
    const source = fs.readFileSync(path, 'utf8');
    if (path.endsWith('/entryability/EntryAbility.ets')) assertEntryAbilityImports(source);
    loaded.push({ path, sha256: crypto.createHash('sha256').update(source).digest('hex') });
    const module = { exports: {} }; cache.set(path, module);
    const js = ts.transpileModule(source, { compilerOptions: {
      target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
    }}).outputText;
    vm.runInNewContext(js, { module, exports: module.exports, Map, Set, WeakSet, ArrayBuffer, Uint8Array, Promise, Error,
      setTimeout, clearTimeout, console,
      require(name) {
        if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel, FlutterAbility };
        if (name === '@ohos.deviceInfo') return { default: { sdkApiVersion: 26 } };
        if (name === '@ohos.multimedia.image') return { default: image };
        if (name === '@ohos.multimedia.media') return { default: media };
        if (name === '@ohos.file.fs') return { default: io };
        if (name === '@ohos.resourceManager') return { default: { ColorMode: { DARK: 0 } } };
        if (name === '@ohos.window') return {};
        if (name === '@ohos.hilog') return { default: { info() {}, warn() {} } };
        if (name.endsWith('/Log')) return { default: { i() {}, e() {}, w() {}, d() {} } };
        if (name.endsWith('/FlutterNapi')) return { default: class FlutterNapi {} };
        if (name.endsWith('/FlutterAbility')) return { FlutterAbility };
        if (name.endsWith('/NativeHost')) return { nativeHostState: () => ({ phase: 'idle' }) };
        if (name.startsWith('.')) {
          if (path.endsWith('/entryability/EntryAbility.ets')) {
            if (name !== '../plugins/LaunchPlugin' && name !== '../plugins/LaunchClipPlugin') isolated.push(name);
            return entryImports(name);
          }
          return load(resolve(dirname(path), name + '.ets'));
        }
        throw new Error('Unadapted runtime import: ' + name);
      },
    }, { filename: path });
    return module.exports;
  }
  if (!process.env.OHOS_FLUTTER_EMBEDDING) throw new Error('OHOS_FLUTTER_EMBEDDING must name the fixed flutter/package');
  const { FlutterRenderer } = load(resolve(process.env.OHOS_FLUTTER_EMBEDDING, 'src/main/ets/embedding/engine/renderer/FlutterRenderer.ets'));
  const registry = new FlutterRenderer(napi);
  const Entry = load(resolve(repo, 'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets')).default;
  const binding = { getApplicationContext: () => ({ filesDir, resourceManager: {} }), getBinaryMessenger: () => ({}),
    getTextureRegistry: () => registry };
  const engine = { getPlugins: () => ({ add(plugin) { plugins.push(plugin); plugin.onAttachedToEngine?.(binding); } }) };
  new Entry().configureFlutterEngine(engine);
  return { state, calls, events, fds, textures, players, objects, loaded, isolated, channels,
    attachAbility(root) { for (const plugin of plugins) plugin.onAttachedToAbility?.({ getAbility: () => ({ context: { filesDir: root } }) }); },
    detach() { for (const plugin of [...plugins].reverse()) plugin.onDetachedFromEngine?.(binding); },
    async invoke(method, args, channelName = 'dsh/launch_clip') {
      const channel = channels.get(channelName);
      if (!channel?.handler) return { missing: true };
      return new Promise(resolveResult => channel.handler.onMethodCall({ method, argument: name => args[name] }, {
        success: value => resolveResult({ value: value instanceof Map ? Object.fromEntries(value) : value ?? null }),
        error: (code, message) => resolveResult({ error: code, message }), notImplemented: () => resolveResult({ missing: true }),
      }));
    },
  };
}
