// Actual product ETS + EntryAbility + production Linux openUserFile helper.
// Media decoding, audio focus and Flutter texture services are explicit boundaries.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { createHash } from 'node:crypto';

export const deferred = () => Promise.withResolvers();
export const settle = async () => { for (let i = 0; i < 8; i++) await new Promise(resolve => setImmediate(resolve)); };
export async function until(test) {
  const deadline = Date.now() + 5000;
  while (!test()) { assert(Date.now() < deadline, 'fixture condition timed out'); await settle(); }
}
const plain = value => value instanceof Map ? Object.fromEntries([...value].map(([k, v]) => [k, plain(v)])) : value;

export async function videoFixture(t, options = {}) {
  const repo = process.env.OHOS_VIDEO_SOURCE_ROOT ?? fileURLToPath(new URL('../../../', import.meta.url));
  const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
  assert(ts.version.startsWith('5.9.'));
  const native = createRequire(import.meta.url)(resolve(process.env.OHOS_USER_FILE_ADDON));
  const { assertEntryAbilityImports, createEntryAbilityImports, entryAbilityImports } = await import(
    pathToFileURL(resolve(repo, 'runtime/tests/ohos/entry-ability-fixture.mjs')).href);
  const root = fs.mkdtempSync(resolve(os.tmpdir(), 'dsh-video-'));
  const context = { filesDir: root + '/files', cacheDir: root + '/cache', tempDir: root + '/temp' };
  const uiContext = { ...context, cacheDir: root + '/ui-cache', tempDir: root + '/ui-temp' };
  for (const p of [context.filesDir, context.cacheDir, context.tempDir, uiContext.cacheDir, uiContext.tempDir,
    context.filesDir + '/runtime/rootfs/root/workspace']) fs.mkdirSync(p, { recursive: true });
  const path = context.cacheDir + '/movie.mp4';
  fs.writeFileSync(path, 'synthetic media: decoding is the explicitly substituted SDK boundary');
  const opt = { ...options }, calls = [], players = [], objects = [], fds = new Set(), textures = new Set(), channels = [];
  const timers = new Map(); let now = 0, nextTimer = 0, nativeLoads = 0;
  const later = (callback, ms) => { const id = ++nextTimer; timers.set(id, { callback, at: now + ms }); return id; };
  const cancel = id => timers.delete(id);
  async function tick(ms) {
    now += ms;
    for (;;) {
      const due = [...timers].find(([, timer]) => timer.at <= now);
      if (!due) break;
      timers.delete(due[0]); due[1].callback(); await settle();
    }
    await settle();
  }
  const io = {
    async stat(fd) { calls.push(['fd.stat', fd]); await opt.stat?.(fd); return fs.fstatSync(fd); },
    async close(fd) { calls.push(['fd.close', fd]); await opt.fdClose?.(fd); fs.closeSync(fd); fds.delete(fd); },
  };
  const host = { openUserFile(base, relative) {
    calls.push(['fd.open', base, relative]); const fd = native.openUserFile(base, relative); fds.add(fd); return fd;
  } };
  function ownsFd(value, source) {
    assert(fds.has(source.fd), 'media received a live real FD');
    assert(!objects.some(o => o !== value && !o.released && o.source?.fd === source.fd), 'FD has one media-service owner');
    value.source = { ...source };
  }
  function resource(kind) {
    const value = { kind, released: false, source: null,
      set fdSrc(source) { ownsFd(this, source); },
      async release() {
        calls.push([kind + '.release']);
        if (this.source) assert(fds.has(this.source.fd), 'FD retained until media releases');
        await opt[kind + 'Release']?.(this); this.released = true;
      } };
    objects.push(value); return value;
  }
  class Player {
    constructor() {
      this.kind = 'player'; this.state = 'idle'; this.released = false; this.callbacks = new Map(); this.history = new Map();
      this.width = opt.width ?? 1920; this.height = opt.height ?? 1080; this.duration = opt.duration ?? 5000; this.currentTime = 0;
      players.push(this); objects.push(this);
    }
    on(name, callback) { this.callbacks.set(name, callback); this.history.set(name, callback); }
    off(name) { this.callbacks.delete(name); }
    emit(name, value) { if (name === 'stateChange') this.state = value; this.callbacks.get(name)?.(value, 1); }
    late(name, value) { this.history.get(name)?.(value, 1); }
    set fdSrc(source) {
      assert.equal(this.state, 'idle'); ownsFd(this, source); calls.push(['player.source', { ...source }]);
      if (opt.initialize !== false) queueMicrotask(() => this.emit('stateChange', 'initialized'));
    }
    set surfaceId(id) { assert.equal(this.state, 'initialized'); this.surface = id; calls.push(['player.surface', id]); }
    set audioRendererInfo(value) { assert.equal(this.state, 'initialized'); this.renderer = { ...value }; }
    set audioInterruptMode(value) { assert(['prepared', 'playing', 'paused', 'completed'].includes(this.state)); this.interruptMode = value; }
    async prepare() { assert.equal(this.state, 'initialized'); calls.push(['player.prepare']); await opt.prepare?.(this); this.emit('stateChange', 'prepared'); }
    setVolume(value) { this.volume = value; }
    async play() {
      assert(['prepared', 'paused', 'completed'].includes(this.state)); calls.push(['player.play']);
      await opt.play?.(this); this.emit('stateChange', 'playing');
    }
    async pause() {
      assert.equal(this.state, 'playing'); calls.push(['player.pause']); await opt.pause?.(this); this.emit('stateChange', 'paused');
    }
    seek(position, mode) {
      assert(['prepared', 'playing', 'paused', 'completed'].includes(this.state)); calls.push(['player.seek', position, mode]);
      // Submission alone does not prove a frame/position was reached.
    }
    seekDone(position) { this.currentTime = position; this.emit('seekDone', position); }
    interrupt(hintType, forceType = 0) { this.emit('audioInterrupt', { eventType: 1, forceType, hintType }); }
    async release() {
      calls.push(['player.release']); assert(!this.source || fds.has(this.source.fd));
      await opt.playerRelease?.(this); this.released = true; this.emit('stateChange', 'released');
    }
  }
  const media = {
    SeekMode: { SEEK_NEXT_SYNC: 0, SEEK_PREV_SYNC: 1, SEEK_CLOSEST: 2 },
    AVImageQueryOptions: { AV_IMAGE_QUERY_CLOSEST_SYNC: 2 },
    async createAVPlayer() { calls.push(['player.create']); await opt.create?.(); return new Player(); },
    async createAVMetadataExtractor() {
      calls.push(['extractor.create']); await opt.extractorCreate?.();
      const value = resource('extractor');
      value.fetchMetadata = async () => { await opt.metadata?.(); return { videoWidth: String(opt.posterWidth ?? 1920), videoHeight: String(opt.posterHeight ?? 1080) }; };
      return value;
    },
    async createAVImageGenerator() {
      calls.push(['generator.create']); await opt.generatorCreate?.(); const value = resource('generator');
      value.fetchFrameByTime = async (time, mode, size) => {
        calls.push(['generator.frame', time, mode, { ...size }]); await opt.frame?.();
        const pixel = resource('pixels'); pixel.getImageInfo = async () => ({ size: { width: opt.frameWidth ?? size.width, height: opt.frameHeight ?? size.height } });
        return pixel;
      }; return value;
    },
  };
  const image = { createImagePacker() {
    calls.push(['packer.create']); const value = resource('packer');
    value.packToData = async (_pixel, config) => {
      calls.push(['packer.pack', { ...config }]); await opt.pack?.(); return Uint8Array.from([255, 216, 255, 217]).buffer;
    }; return value;
  } };
  const audio = { StreamUsage: { STREAM_USAGE_MOVIE: 10 }, InterruptMode: { SHARE_MODE: 0, INDEPENDENT_MODE: 1 },
    InterruptHint: { INTERRUPT_HINT_NONE: 0, INTERRUPT_HINT_RESUME: 1, INTERRUPT_HINT_PAUSE: 2, INTERRUPT_HINT_STOP: 3,
      INTERRUPT_HINT_DUCK: 4, INTERRUPT_HINT_UNDUCK: 5 } };
  // Entire pinned FlutterRenderer executes below. Its N-API boundary is explicit;
  // no self-declared registry can make deprecated create/release appear to work.
  const napi = {
    registerTexture(id) { textures.add(id); calls.push(['texture.register', id]); return id + 1000; },
    getTextureNativeWindowId() { return 456789; }, getTextureNativeWindowPtr() { return 456789n; },
    setTextureBufferSize(id, width, height) { assert(textures.has(id)); calls.push(['texture.size', id, width, height]); },
    unregisterTexture(id) {
      assert(!players.some(p => p.surface === String(id + 1000) && !p.released), 'surface retained until player release');
      calls.push(['texture.unregister', id]); textures.delete(id);
    },
  };
  class Channel {
    constructor(messenger, name) { this.messenger = messenger; this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod() { assert.fail('Android media_video has no native pushed event contract'); }
  }
  class FlutterAbility { configureFlutterEngine() {} onForeground() {} onBackground() {} onDestroy() {} }
  const cache = new Map();
  const overrides = { '../runtime/NativeHost': () => ({ async loadNativeHost() { nativeLoads++; return host; } }) };
  if (Object.hasOwn(entryAbilityImports, '../plugins/MediaVideoPlugin')) overrides['../plugins/MediaVideoPlugin'] = () => load(resolve(repo, 'app/ohos/entry/src/main/ets/plugins/MediaVideoPlugin.ets'));
  const entries = createEntryAbilityImports(overrides);
  function load(path) {
    if (cache.has(path)) return cache.get(path).exports;
    const source = fs.readFileSync(path, 'utf8');
    if (path.endsWith('/entryability/EntryAbility.ets')) assertEntryAbilityImports(source);
    const module = { exports: {} }; cache.set(path, module);
    const result = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
    assert(!result.diagnostics?.some(d => d.category === ts.DiagnosticCategory.Error));
    vm.runInNewContext(result.outputText, { module, exports: module.exports, Map, Set, WeakSet, Error, Promise, ArrayBuffer, Uint8Array,
      setTimeout: later, clearTimeout: cancel, console,
      require(name) {
        if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel, FlutterAbility };
        if (name === '@ohos.file.fs') return { default: io };
        if (name === '@ohos.multimedia.media') return { default: media };
        if (name === '@ohos.multimedia.image') return { default: image };
        if (name === '@ohos.multimedia.audio') return { default: audio };
        if (name.endsWith('/Log')) return { default: { i() {}, e() {}, w() {}, d() {} } };
        if (name.startsWith('.')) {
          if (path.endsWith('/entryability/EntryAbility.ets')) return entries(name);
          return load(resolve(dirname(path), name + '.ets'));
        }
        throw Error('unadapted import ' + name);
      },
    }, { filename: path }); return module.exports;
  }
  assert(process.env.OHOS_FLUTTER_EMBEDDING, 'fixed OH Flutter embedding package is required');
  const embedding = resolve(process.env.OHOS_FLUTTER_EMBEDDING);
  for (const [name, expected] of [
    ['src/main/ets/view/TextureRegistry.ets', '7beb00448c6b72732c234c662bde8ee893eb1bcdc6875f5333edfbd379e1401a'],
    ['src/main/ets/embedding/engine/renderer/FlutterRenderer.ets', '223a3177c3dc07115c4aa87ebe4261bc86291192588da2fe64d43e0f481b8098'],
  ]) assert.equal(createHash('sha256').update(fs.readFileSync(resolve(embedding, name))).digest('hex'), expected);
  const { FlutterRenderer } = load(resolve(embedding, 'src/main/ets/embedding/engine/renderer/FlutterRenderer.ets'));
  const registry = new FlutterRenderer(napi);
  const Entry = load(resolve(repo, 'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets')).default;
  function attach() {
    const ui = new Entry(); ui.context = uiContext;
    const messenger = {}, plugins = [];
    const binding = { getApplicationContext: () => context, getBinaryMessenger: () => messenger, getTextureRegistry: () => registry };
    const ability = { getAbility: () => ui };
    ui.configureFlutterEngine({ getPlugins: () => ({ add(plugin) { plugins.push(plugin); plugin.onAttachedToEngine?.(binding); plugin.onAttachedToAbility?.(ability); } }) });
    ui.onForeground();
    return { ui, binding, ability, plugins, methods: channels.findLast(c => c.name === 'dsh/media_video' && c.messenger === messenger),
      background: () => ui.onBackground(), foreground: () => ui.onForeground(),
      detach: () => { for (const plugin of plugins) plugin.onDetachedFromEngine?.(binding); } };
  }
  const first = attach();
  const attached = [first];
  function call(method, args = {}, attached = first) {
    if (!attached.methods?.handler) return { done: Promise.resolve({ missing: true }), replies: [{ missing: true }] };
    const result = deferred(), replies = [];
    const reply = value => { replies.push(value); result.resolve(value); };
    attached.methods.handler.onMethodCall({ method, argument: name => args[name] }, {
      success: value => reply({ value: plain(value) ?? null }), error: (code, message) => reply({ error: code, message }),
      notImplemented: () => reply({ missing: true }),
    }); return { done: result.promise, replies };
  }
  t.after(async () => {
    delete opt.playerRelease; delete opt.extractorRelease; delete opt.generatorRelease; delete opt.pixelsRelease; delete opt.packerRelease; delete opt.fdClose;
    for (const item of attached) item.detach(); await settle();
    for (const fd of fds) { try { fs.closeSync(fd); } catch {} }
    fs.rmSync(root, { force: true, recursive: true });
  });
  return { ...first, root, path, context, uiContext, calls, channels, players, objects, fds, textures, timers, tick, call,
    attach: () => { const item = attach(); attached.push(item); return item; },
    get nativeLoads() { return nativeLoads; }, change: value => Object.assign(opt, value) };
}
