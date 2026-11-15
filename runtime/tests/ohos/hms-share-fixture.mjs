// Test boundary only: actual ETS bodies and real Linux FS / production openUserFile.
// HMS events, URI grants, Flutter and display are explicit doubles, never a device proof.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { dirname, join, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
assert(process.env.OHOS_TYPESCRIPT_PREFIX && process.env.OHOS_USER_FILE_ADDON,
  'Set OHOS_TYPESCRIPT_PREFIX and OHOS_USER_FILE_ADDON; see hms-share.md');
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
const native = require(resolve(process.env.OHOS_USER_FILE_ADDON));
const repo = fileURLToPath(new URL('../../../', import.meta.url));
export const deferred = () => Promise.withResolvers();
export const plain = value => value instanceof Map ? Object.fromEntries([...value].map(([k, v]) => [k, plain(v)]))
  : Array.isArray(value) ? Array.from(value, plain) : value;
export async function until(check, description = 'condition') {
  const start = Date.now();
  while (!check()) {
    if (Date.now() - start > 5000) throw new Error('Test observation timed out: ' + description);
    await new Promise(resolve => setImmediate(resolve));
  }
}

export async function shareFixture(t, options = {}) {
  const root = await fsp.mkdtemp(join(tmpdir(), 'hms-share-'));
  const app = { filesDir: join(root, 'files'), cacheDir: join(root, 'cache'), tempDir: join(root, 'temp') };
  const workspace = app.filesDir + '/runtime/rootfs/root/workspace';
  const ui = { ...app, ...(options.separateContexts ? {
    filesDir: join(root, 'haps/entry/files'), cacheDir: join(root, 'haps/entry/cache'),
    tempDir: join(root, 'haps/entry/temp'),
  } : {}), abilityInfo: { bundleName: 'io.dsh.app', name: 'EntryAbility' } };
  for (const path of [workspace, app.cacheDir, app.tempDir, ui.filesDir, ui.cacheDir, ui.tempDir,
    join(root, 'external')]) await fsp.mkdir(path, { recursive: true });
  const channels = [], panels = [], fds = new Set(), opens = [], delivered = [], dataCalls = [], history = [];
  let kitLoads = 0;
  const uris = new Map(), moduleCache = new Map();
  let reads = 0, writes = 0, pendingIO = 0;
  let currentOptions = options;
  const fdOf = value => typeof value === 'number' ? value : value.fd;
  const stat = s => ({ size: s.size, mtime: s.mtimeMs,
    isFile: () => s.isFile(), isDirectory: () => s.isDirectory(), isSymbolicLink: () => s.isSymbolicLink() });
  const api = {
    OpenMode: { READ_ONLY: fs.constants.O_RDONLY, WRITE_ONLY: fs.constants.O_WRONLY, READ_WRITE: fs.constants.O_RDWR,
      CREATE: fs.constants.O_CREAT, NOFOLLOW: fs.constants.O_NOFOLLOW, NONBLOCK: fs.constants.O_NONBLOCK },
    async mkdir(path) { try { await fsp.mkdir(path); } catch (e) { if (e.code === 'EEXIST') e.code = 13900015; throw e; } },
    async mkdtemp(template) {
      assert(template.endsWith('XXXXXX'));
      if (currentOptions.mkdtempFail) throw new Error('fixture mkdtemp failure');
      return fsp.mkdtemp(template.slice(0, -6));
    },
    lstat: async path => stat(await fsp.lstat(path)),
    async stat(path) {
      const result = stat(typeof path === 'number' ? await promisify(fs.fstat)(path) : await fsp.stat(path));
      return currentOptions.stat ? currentOptions.stat(path, result) : result;
    },
    listFile: path => fsp.readdir(path),
    async open(path, flags) {
      opens.push({ path, flags });
      let actual = path;
      if (path.startsWith('file://')) {
        assert.equal(flags & 3, fs.constants.O_RDONLY, 'external URI must only be read');
        actual = uris.get(path);
        if (!actual) throw new Error('fixture external grant missing');
      }
      if (currentOptions.beforeOpen) await currentOptions.beforeOpen(path);
      const fd = await promisify(fs.open)(actual, flags, 0o600); fds.add(fd); return { fd, path };
    },
    async close(value) { const fd = fdOf(value); await promisify(fs.close)(fd); fds.delete(fd); },
    async read(fd, buffer, opts) {
      reads++;
      if (currentOptions.beforeRead) await currentOptions.beforeRead({ fd, reads, buffer, opts });
      if (currentOptions.zeroRead) return 0;
      return (await promisify(fs.read)(fd, Buffer.from(buffer), 0, Math.min(opts.length, currentOptions.maxRead ?? Infinity), opts.offset)).bytesRead;
    },
    async write(fd, buffer, opts) {
      writes++;
      if (currentOptions.beforeWrite) await currentOptions.beforeWrite({ fd, writes, buffer, opts });
      if (currentOptions.zeroWrite) return 0;
      return (await promisify(fs.write)(fd, Buffer.from(buffer), 0, Math.min(buffer.byteLength, currentOptions.maxWrite ?? Infinity), opts.offset)).bytesWritten;
    },
    fsync: fd => promisify(fs.fsync)(fd), unlink: fsp.unlink,
    rmdir: path => fsp.rm(path, { recursive: true }),
  };
  for (const [name, operation] of Object.entries(api)) {
    if (typeof operation !== 'function') continue;
    api[name] = (...args) => {
      pendingIO++;
      try { return Promise.resolve(operation(...args)).finally(() => pendingIO--); }
      catch (error) { pendingIO--; throw error; }
    };
  }
  class Channel {
    constructor(messenger, name) { this.name = name; this.messenger = messenger; this.handler = null; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, value) {
      if (currentOptions.throwDelivery) throw new Error('fixture delivery failure');
      delivered.push({ channel: this, method, value: plain(value) }); history.push('invoke:' + method);
    }
  }
  const kit = {
    SelectionMode: { SINGLE: 0, BATCH: 1 }, SharePreviewMode: { DEFAULT: 0, DETAIL: 1 },
    SharedData: class { constructor(record) { this.records = [record]; } addRecord(record) { this.records.push(record); } getRecords() { return this.records; } },
    ShareController: class {
      constructor(data) {
        if (currentOptions.throwConstruct) throw new Error('fixture controller construction');
        this.data = data; this.listeners = new Map(); this.visible = false; this.showCall = deferred(); panels.push(this);
      }
      on(name, callback) {
        if (currentOptions.throwOn === name) throw new Error('fixture on failure');
        if (!this.listeners.has(name)) this.listeners.set(name, new Set()); this.listeners.get(name).add(callback);
      }
      off(name, callback) { this.listeners.get(name)?.delete(callback); }
      emit(name, value) {
        if (name === 'dismiss') this.visible = false;
        for (const callback of [...(this.listeners.get(name) ?? [])]) callback(value);
      }
      show(context, opts) {
        this.context = context; this.options = opts;
        if (currentOptions.throwShow) throw new Error('fixture synchronous show failure');
        this.visible = true; this.showCall.resolve();
        if (currentOptions.show) return currentOptions.show(this);
        return Promise.resolve();
      }
    },
    getSharedData(want) {
      dataCalls.push(want); history.push('getSharedData');
      if (currentOptions.getSharedData) return currentOptions.getSharedData(want);
      return Promise.resolve({ getRecords: () => want.records ?? [] });
    },
  };
  const utd = {
    UniformDataType: { FILE: 'general.file' },
    getUniformDataTypeByMIMEType(mime) {
      return ({ 'image/png': 'general.png', 'image/jpeg': 'general.jpeg', 'application/pdf': 'com.adobe.pdf',
        'text/plain': 'general.plain-text' })[mime] ?? 'flex.mime';
    },
    getUniformDataTypeByFilenameExtension(ext) {
      return ({ '.png': 'general.png', '.pdf': 'com.adobe.pdf', '.txt': 'general.plain-text', '.zip': 'general.zip-archive' })[ext] ?? 'flex.ext';
    },
    getTypeDescriptor(type) { return { mimeTypes: ({ 'general.png': ['image/png'], 'com.adobe.pdf': ['application/pdf'] })[type] ?? [] }; },
  };
  const boundary = name => {
    if (name === '@kit.ShareKit') {
      if (currentOptions.kitFailure) throw new Error('controlled unavailable Share Kit');
      return { systemShare: kit };
    }
    if (name === '@ohos.file.fs') return { default: api };
    if (name === '@ohos.file.fileuri') return { default: {
      getUriFromPath: path => 'file://io.dsh.app' + path.split('/').map(encodeURIComponent).join('/'),
      FileUri: class { constructor(uri) { this.name = decodeURIComponent(uri.slice(uri.lastIndexOf('/') + 1)); } },
    } };
    if (name === '@ohos.data.uniformTypeDescriptor') return { default: utd };
    if (name === '@ohos.util') return { default: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } } };
    if (name === '@ohos.display') return { default: { getDefaultDisplaySync: () => ({ densityPixels: currentOptions.density ?? 2.5 }) } };
    if (name === 'libdsh_host.so') return Promise.resolve(currentOptions.beforeNativeLoad?.()).then(() => ({ default: {
      openUserFile(root, relative) {
        const fd = native.openUserFile(root, relative); fds.add(fd); opens.push({ root, relative, native: true }); return fd;
      },
    } }));
    if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel,
      FlutterAbility: class { onCreate() { history.push('superCreate'); } onNewWant() { history.push('superNewWant'); } },
    };
    throw new Error('Unadapted platform import: ' + name);
  };
  function load(path) {
    if (moduleCache.has(path)) return moduleCache.get(path).exports;
    const module = { exports: {} }; moduleCache.set(path, module);
    const compiled = ts.transpileModule(fs.readFileSync(path, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
    });
    try { vm.runInNewContext(compiled.outputText, {
      module, exports: module.exports, Map, Set, ArrayBuffer, Uint8Array, Promise,
      canIUse: capability => { assert.equal(capability, 'SystemCapability.Collaboration.SystemShare'); return currentOptions.supported !== false; },
      require(name) {
        if (name === './HmsShareKit') {
          kitLoads++;
          return Promise.resolve(currentOptions.beforeKitLoad?.()).then(() => load(resolve(dirname(path), name + '.ets')));
        }
        if (name.startsWith('.')) {
          if (path.endsWith('EntryAbility.ets') && !name.includes('HmsShare')) {
            return { default: class {}, GeneratedPluginRegistrant: { registerWith() {} }, RuntimePlugin: class {} };
          }
          return load(resolve(dirname(path), name + '.ets'));
        }
        return boundary(name);
      },
    }, { filename: path }); } catch (error) { moduleCache.delete(path); throw error; }
    return module.exports;
  }
  const pluginPath = resolve(repo, 'app/ohos/entry/src/main/ets/plugins/HmsSharePlugin.ets');
  const Plugin = load(pluginPath).default;
  const { HmsShareInbox: inbox } = load(resolve(dirname(pluginPath), 'HmsShareInbox.ets'));
  const policy = load(resolve(dirname(pluginPath), 'HmsSharePolicy.ets'));
  const entry = load(resolve(repo, 'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets')).default;
  function attach(plugin = new Plugin(), attachAbility = true) {
    const engine = { getApplicationContext: () => app, getBinaryMessenger: () => ({}) };
    const ability = { getAbility: () => ({ context: ui }) };
    plugin.onAttachedToEngine(engine); if (attachAbility) plugin.onAttachedToAbility(ability);
    return { plugin, engine, ability, outgoing: channels[channels.length - 2], incoming: channels[channels.length - 1] };
  }
  function call(channel, method, object = {}) {
    const done = deferred(), replies = [];
    const args = object instanceof Map ? object : new Map(Object.entries(object));
    const result = {
      success(value) { replies.push({ value: plain(value) }); history.push('reply:' + method); done.resolve(replies[0]); if (currentOptions.throwReply) throw new Error('fixture retired transport'); },
      error(error, message) { replies.push({ error, message }); done.resolve(replies[0]); if (currentOptions.throwReply) throw new Error('fixture retired transport'); },
      notImplemented() { replies.push({ missing: true }); done.resolve(replies[0]); },
    };
    const handler = channel.handler;
    handler.onMethodCall({ method, args, argument: key => args.get(key) }, result);
    return { done: done.promise, replies, result, handler };
  }
  const first = attach();
  t.after(async () => {
    try {
      for (const panel of panels) panel.emit('dismiss');
      first.plugin.onDetachedFromEngine(first.engine);
      await until(() => fds.size === 0 && pendingIO === 0, 'all real IO closed and settled');
      assert.equal(panels.filter(panel => panel.visible).length, 0);
    } finally {
      for (const fd of fds) { try { fs.closeSync(fd); } catch {} }
      await fsp.rm(root, { recursive: true, force: true });
    }
  });
  return { root, app, ui, workspace, channels, panels, fds, opens, delivered, dataCalls, history, api, policy, kit, inbox,
    ...first, attach, call, change: value => { currentOptions = { ...currentOptions, ...value }; },
    async local(name = '中文 文件.txt', bytes = 'hello', base = workspace) {
      const path = join(base, name); await fsp.mkdir(dirname(path), { recursive: true }); await fsp.writeFile(path, bytes); return path;
    },
    async external(name = '外来.txt', bytes = 'external') {
      const path = join(root, 'external', name); await fsp.mkdir(dirname(path), { recursive: true }); await fsp.writeFile(path, bytes);
      const uri = 'file://other.bundle/' + name.split('/').map(encodeURIComponent).join('/'); uris.set(uri, path); return { uri, path };
    },
    externalTarget(name, path) { const uri = 'file://other.bundle/' + encodeURIComponent(name); uris.set(uri, path); return uri; },
    receive(records, extra = {}) { return inbox.receive(ui, { records, ...extra }, { launchReasonMessage: 'ReasonMessage_SystemShare' }); },
    startEntry() { const value = new entry(); value.context = ui; return value; },
    get reads() { return reads; }, get writes() { return writes; }, get pendingIO() { return pendingIO; }, get kitLoads() { return kitLoads; },
  };
}
