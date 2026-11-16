// Actual EntryAbility and ETS bodies. Linux files are real; image codecs,
// AppGallery user decisions and Flutter messenger are explicit SDK boundaries.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import vm from 'node:vm';

export const deferred = () => Promise.withResolvers();
export const settle = async () => { for (let i = 0; i < 8; i++) await new Promise(resolve => setImmediate(resolve)); };
export async function until(check) {
  const deadline = Date.now() + 5000;
  while (!check()) { assert(Date.now() < deadline, 'fixture observation timed out'); await settle(); }
}
const plain = value => value instanceof Map ? Object.fromEntries(value) : value;

export async function shortcutFixture(t, options = {}) {
  const repo = process.env.OHOS_SHORTCUT_SOURCE_ROOT ?? fileURLToPath(new URL('../../../', import.meta.url));
  const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
  assert(ts.version.startsWith('5.9.'));
  const { assertEntryAbilityImports, createEntryAbilityImports, entryAbilityImports } = await import(
    pathToFileURL(resolve(repo, 'runtime/tests/ohos/entry-ability-fixture.mjs')).href);
  const root = await fsp.mkdtemp(resolve(os.tmpdir(), 'dsh-shortcut-'));
  const context = { filesDir: root + '/files', cacheDir: root + '/cache', tempDir: root + '/temp',
    abilityInfo: { bundleName: 'ccchimneyyy.dsh.go', moduleName: 'entry', name: 'EntryAbility' } };
  for (const path of [context.filesDir, context.cacheDir, context.tempDir]) await fsp.mkdir(path);
  const calls = [], channels = [], events = [], objects = [], fds = new Set(), opt = { ...options };
  let kitLoads = 0;
  const stat = value => ({ size: value.size, mtime: value.mtimeMs,
    isFile: () => value.isFile(), isDirectory: () => value.isDirectory(), isSymbolicLink: () => value.isSymbolicLink() });
  const translate = error => { if (error.code === 'ENOENT') error.code = 13900002; if (error.code === 'EEXIST') error.code = 13900015; throw error; };
  const io = {
    OpenMode: { CREATE: fs.constants.O_CREAT, WRITE_ONLY: fs.constants.O_WRONLY,
      NOFOLLOW: fs.constants.O_NOFOLLOW, TRUNC: fs.constants.O_TRUNC },
    async mkdir(path) { calls.push(['mkdir', path]); await opt.mkdir?.(path); await fsp.mkdir(path).catch(translate); },
    async lstat(path) { return stat(await fsp.lstat(path).catch(translate)); },
    listFile: path => fsp.readdir(path),
    async open(path, flags) {
      calls.push(['open', path, flags]); await opt.open?.(path);
      const fd = await promisify(fs.open)(path, flags, 0o600); fds.add(fd); return { fd, path };
    },
    async write(fd, buffer, config) {
      calls.push(['write', fd, buffer.byteLength, config.offset]); await opt.write?.(fd);
      if (opt.zeroWrite) return 0;
      return (await promisify(fs.write)(fd, Buffer.from(buffer), 0,
        Math.min(buffer.byteLength, opt.maxWrite ?? Infinity), config.offset)).bytesWritten;
    },
    async fsync(fd) { calls.push(['fsync', fd]); await opt.fsync?.(fd); await promisify(fs.fsync)(fd); },
    async close(fd) { calls.push(['close', fd]); await opt.close?.(fd); await promisify(fs.close)(fd); fds.delete(fd); },
    async unlink(path) { calls.push(['unlink', path]); await opt.unlink?.(path); await fsp.unlink(path).catch(translate); },
    async rmdir(path) { calls.push(['rmdir', path]); await opt.rmdir?.(path); await fsp.rmdir(path).catch(translate); },
  };
  function resource(kind) {
    const value = { kind, released: false, async release() {
      calls.push([kind + '.release']); await opt[kind + 'Release']?.(this); this.released = true;
    } }; objects.push(value); return value;
  }
  const image = {
    PixelMapFormat: { RGBA_8888: 3 },
    createImageSource(buffer) {
      calls.push(['source.create', buffer.byteLength]);
      if (opt.sourceError) throw Error('fixture decode rejected');
      const source = resource('source');
      source.getImageInfo = async () => { await opt.info?.(); return { size: opt.size ?? { width: 432, height: 432 } }; };
      source.createPixelMap = async config => {
        calls.push(['pixels.create', config]); await opt.decode?.(config);
        const pixels = resource('pixels'); pixels.size = { ...config.desiredSize };
        pixels.getImageInfo = async () => ({ size: opt.decodedSize ?? pixels.size }); return pixels;
      }; return source;
    },
    createImagePacker() {
      calls.push(['packer.create']); const packer = resource('packer');
      packer.packToData = async (pixels, config) => {
        calls.push(['pack', { ...pixels.size }, { ...config }]); await opt.pack?.(pixels, config);
        const length = opt.packSize ? opt.packSize(pixels.size) : 120;
        const output = new Uint8Array(length); output.set([137, 80, 78, 71, 13, 10, 26, 10].slice(0, length));
        return output.buffer;
      }; return packer;
    },
  };
  const api = {
    async getPinShortcutInfos() { calls.push(['list']); await opt.list?.(); return opt.pinned ?? []; },
    async checkPinShortcutPermitted(ui, id, want, label, foreground, background) {
      const stored = await fsp.readFile(foreground);
      calls.push(['check', { ui, id, want, label, foreground, background, stored }]);
      await opt.check?.({ ui, id, want, label, foreground, background });
      return opt.checkResult ?? { code: 0, tid: 'tid:' + id, expired: 30000, limit: 2 };
    },
    async requestNewPinShortcut(ui, tid) {
      calls.push(['request', { ui, tid }]); await opt.request?.({ ui, tid });
    },
  };
  class Channel {
    constructor(messenger, name) { this.messenger = messenger; this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, value) {
      if (opt.eventError) throw Error('fixture messenger closed');
      events.push({ channel: this, method, value: plain(value) });
    }
  }
  class FlutterAbility { configureFlutterEngine() {} onForeground() {} onBackground() {} onDestroy() {} }
  const cache = new Map();
  const overrides = { '../runtime/NativeHost': () => ({ async loadNativeHost() { assert.fail('shortcut must not load Node'); } }) };
  if (Object.hasOwn(entryAbilityImports, '../plugins/PictureShortcutPlugin')) {
    overrides['../plugins/PictureShortcutPlugin'] = () => load(resolve(repo, 'app/ohos/entry/src/main/ets/plugins/PictureShortcutPlugin.ets'));
  }
  const entries = createEntryAbilityImports(overrides);
  function load(path) {
    if (cache.has(path)) return cache.get(path).exports;
    const source = fs.readFileSync(path, 'utf8');
    if (path.endsWith('/entryability/EntryAbility.ets')) assertEntryAbilityImports(source);
    const module = { exports: {} }; cache.set(path, module);
    const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
    assert(!compiled.diagnostics?.some(d => d.category === ts.DiagnosticCategory.Error));
    vm.runInNewContext(compiled.outputText, { module, exports: module.exports, console, Map, Set, WeakSet, Error,
      Promise, ArrayBuffer, Uint8Array, setTimeout, clearTimeout,
      canIUse: capability => { assert.equal(capability, 'SystemCapability.AppGalleryService.Distribution.Recommendations'); return opt.capability !== false; },
      require(name) {
        if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel, FlutterAbility };
        if (name === '@ohos.file.fs') return { default: io };
        if (name === '@ohos.multimedia.image') return { default: image };
        if (name === '@ohos.deviceInfo') return { default: { sdkApiVersion: opt.sdk ?? 26, deviceType: 'phone' } };
        if (name === '@ohos.util') return { default: { generateRandomUUID: () => randomUUID() } };
        if (name === '@kit.AppGalleryKit') { kitLoads++; if (opt.kitError) throw Error('fixture missing kit'); return { productViewManager: api }; }
        if (name.startsWith('.')) {
          if (path.endsWith('/entryability/EntryAbility.ets')) return entries(name);
          return load(resolve(dirname(path), name + '.ets'));
        }
        throw Error('unadapted import ' + name);
      },
    }, { filename: path }); return module.exports;
  }
  const Entry = load(resolve(repo, 'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets')).default;
  function attach() {
    const ui = new Entry(); ui.context = context;
    const messenger = {}, plugins = [];
    const binding = { getApplicationContext: () => context, getBinaryMessenger: () => messenger };
    const ability = { getAbility: () => ui };
    ui.configureFlutterEngine({ getPlugins: () => ({ add(plugin) { plugins.push(plugin); plugin.onAttachedToEngine?.(binding); plugin.onAttachedToAbility?.(ability); } }) });
    ui.onForeground();
    return { ui, binding, plugins,
      methods: channels.findLast(c => c.name === 'dsh/picture_shortcut' && c.messenger === messenger),
      background: () => ui.onBackground(), foreground: () => ui.onForeground(),
      detach: () => { for (const plugin of plugins) plugin.onDetachedFromEngine?.(binding); },
      detachAbility: () => { for (const plugin of plugins) plugin.onDetachedFromAbility?.(); },
    };
  }
  const first = attach(), attached = [first];
  function call(method = 'pin', args = { label: 'DSH Go', png: new Uint8Array([137, 80, 78, 71]) }, target = first) {
    if (!target.methods?.handler) return { done: Promise.resolve({ missing: true }), replies: [{ missing: true }] };
    const result = deferred(), replies = [];
    const reply = value => { replies.push(value); result.resolve(value); };
    target.methods.handler.onMethodCall({ method, argument: name => args[name] }, {
      success: value => reply({ value: plain(value) }), error: (code, message) => reply({ error: code, message }),
      notImplemented: () => reply({ missing: true }),
    }); return { done: result.promise, replies };
  }
  t.after(async () => {
    for (const item of attached) item.detach(); await settle();
    for (const fd of fds) { try { fs.closeSync(fd); } catch {} }
    await fsp.rm(root, { force: true, recursive: true });
  });
  return { ...first, root, context, calls, channels, events, objects, fds, call,
    attach: () => { const item = attach(); attached.push(item); return item; },
    get kitLoads() { return kitLoads; }, change: values => Object.assign(opt, values) };
}
