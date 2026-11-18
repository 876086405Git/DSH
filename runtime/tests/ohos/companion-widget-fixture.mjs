// Actual ETS bodies and Entry registration. Real Linux files/flock; explicit
// FormKit, UTF-8 and Flutter messenger boundaries. Never a simulated data store.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
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
export const running = (formId = 'own-1', fields = {}) => ({ formId, bundleName: 'ccchimneyyy.dsh.go',
  moduleName: 'entry', abilityName: 'CompanionFormAbility', formName: 'companion_room', ...fields });

export async function widgetFixture(t, options = {}) {
  const repo = process.env.OHOS_WIDGET_SOURCE_ROOT ?? fileURLToPath(new URL('../../../', import.meta.url));
  const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
  assert(ts.version.startsWith('5.9.'));
  const { assertEntryAbilityImports, createEntryAbilityImports, entryAbilityImports } = await import(
    pathToFileURL(resolve(repo, 'runtime/tests/ohos/entry-ability-fixture.mjs')).href);
  const temporary = !options.root;
  const root = options.root ?? await fsp.mkdtemp(resolve(os.tmpdir(), 'dsh-widget-'));
  const opt = { ...options }, channels = [], calls = [], updates = [], errors = [], fds = new Map(), instances = [];
  const application = { filesDir: root + '/application', applicationInfo: { name: 'ccchimneyyy.dsh.go' } };
  application.getApplicationContext = () => application;
  const context = { filesDir: root + '/module', getApplicationContext: () => application };
  await fsp.mkdir(application.filesDir, { recursive: true });
  const stat = value => ({ size: value.size, isFile: () => value.isFile(),
    isDirectory: () => value.isDirectory(), isSymbolicLink: () => value.isSymbolicLink() });
  const translate = error => { if (error.code === 'ENOENT') error.code = 13900002; if (error.code === 'EEXIST') error.code = 13900015; throw error; };
  const io = {
    OpenMode: { CREATE: fs.constants.O_CREAT, WRITE_ONLY: fs.constants.O_WRONLY, READ_ONLY: fs.constants.O_RDONLY,
      READ_WRITE: fs.constants.O_RDWR, NOFOLLOW: fs.constants.O_NOFOLLOW, TRUNC: fs.constants.O_TRUNC, DIR: fs.constants.O_DIRECTORY },
    async mkdir(path) { await fsp.mkdir(path).catch(translate); },
    async lstat(path) { return stat(await fsp.lstat(path).catch(translate)); },
    async stat(fd) { return stat(await promisify(fs.fstat)(fd)); },
    async open(path, flags) {
      calls.push(['open', path, flags]); await opt.open?.(path);
      const fd = await promisify(fs.open)(path, flags, 0o600).catch(translate); fds.set(fd, path);
      return { fd, path, tryLock(exclusive) {
        assert.equal(exclusive, true); calls.push(['tryLock', fd]);
        // The inherited descriptor shares the same open file description. flock
        // survives this helper's exit until the product closes its real FD.
        const held = spawnSync('python3', ['-c', 'import fcntl; fcntl.flock(3, fcntl.LOCK_EX | fcntl.LOCK_NB)'],
          { stdio: ['ignore', 'pipe', 'pipe', fd], timeout: 5000 });
        if (held.status !== 0) throw Error('Linux flock busy: ' + held.stderr);
      } };
    },
    async read(fd, buffer, config) {
      calls.push(['read', fd, config.offset]); await opt.read?.(fd);
      if (opt.zeroRead) return 0;
      return (await promisify(fs.read)(fd, Buffer.from(buffer), 0,
        Math.min(buffer.byteLength, opt.maxRead ?? Infinity), config.offset)).bytesRead;
    },
    async write(fd, buffer, config) {
      calls.push(['write', fd, buffer.byteLength, config.offset]); await opt.write?.(fd);
      if (opt.zeroWrite) return 0;
      return (await promisify(fs.write)(fd, Buffer.from(buffer), 0,
        Math.min(buffer.byteLength, opt.maxWrite ?? Infinity), config.offset)).bytesWritten;
    },
    async fsync(fd) { calls.push(['fsync', fd]); await opt.fsync?.(fd); await promisify(fs.fsync)(fd); },
    async close(file) {
      assert.equal(typeof file, 'object'); const fd = file.fd;
      calls.push(['close', fd, fds.get(fd)]); await opt.close?.(fd, fds.get(fd));
      await promisify(fs.close)(fd); fds.delete(fd);
    },
    async rename(from, to) { calls.push(['rename', from, to]); await opt.rename?.(from, to); await fsp.rename(from, to); },
  };
  const kit = {
    FormExtensionAbility: class { constructor() { this.context = context; } },
    formInfo: { FormParam: { IDENTITY_KEY: 'ohos.extra.param.key.form_identity' } },
    formBindingData: { createFormBindingData: data => ({ data: JSON.parse(JSON.stringify(data)) }) },
    formProvider: {
      async getPublishedRunningFormInfos() { calls.push(['list']); await opt.list?.(); return opt.forms ?? [running()]; },
      async updateForm(id, binding) {
        const update = { id, data: binding.data, completed: false }; updates.push(update);
        await opt.update?.(update); update.completed = true;
      },
    },
  };
  class Channel {
    constructor(messenger, name) { this.messenger = messenger; this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
  }
  class FlutterAbility { configureFlutterEngine() {} onBackground() {} }
  function processLoader() {
    const cache = new Map();
    const overrides = { '../runtime/NativeHost': () => ({ async loadNativeHost() { assert.fail('widget must not start Node'); } }) };
    if (Object.hasOwn(entryAbilityImports, '../plugins/CompanionWidgetPlugin')) {
      overrides['../plugins/CompanionWidgetPlugin'] = () => load(resolve(repo, 'app/ohos/entry/src/main/ets/plugins/CompanionWidgetPlugin.ets'));
    }
    const entries = createEntryAbilityImports(overrides);
    class Clock extends Date { constructor(...args) { super(...(args.length ? args : [opt.now ?? Date.now()])); } }
    function load(path) {
      if (cache.has(path)) return cache.get(path).exports;
      const source = fs.readFileSync(path, 'utf8');
      if (path.endsWith('/entryability/EntryAbility.ets')) assertEntryAbilityImports(source);
      const module = { exports: {} }; cache.set(path, module);
      const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022,
        module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
      assert(!compiled.diagnostics?.some(d => d.category === ts.DiagnosticCategory.Error));
      vm.runInNewContext(compiled.outputText, { module, exports: module.exports, Map, Set, Error, Promise,
        ArrayBuffer, Uint8Array, Date: Clock, console: { error: message => errors.push(message) },
        require(name) {
          if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel, FlutterAbility };
          if (name === '@ohos.file.fs') return { default: io };
          if (name === '@ohos.util') return { default: {
            TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
            TextDecoder: { create: (encoding, config) => ({ decodeToString: bytes => new TextDecoder(encoding, config).decode(bytes) }) },
          } };
          if (name === '@kit.FormKit') return kit;
          if (name.startsWith('.')) {
            if (path.endsWith('/entryability/EntryAbility.ets')) return entries(name);
            return load(resolve(dirname(path), name + '.ets'));
          }
          throw Error('unadapted import ' + name);
        },
      }, { filename: path }); return module.exports;
    }
    return load;
  }
  const load = processLoader();
  const ets = path => resolve(repo, 'app/ohos/entry/src/main/ets', path + '.ets');
  const Entry = load(ets('entryability/EntryAbility')).default;
  function attach() {
    const ui = new Entry(), messenger = {}, plugins = []; ui.context = context;
    const binding = { getApplicationContext: () => context, getBinaryMessenger: () => messenger };
    ui.configureFlutterEngine({ getPlugins: () => ({ add(plugin) { plugins.push(plugin); plugin.onAttachedToEngine?.(binding); } }) });
    const instance = { ui, plugins, binding, methods: channels.findLast(c => c.name === 'dsh/companion_widget' && c.messenger === messenger),
      detach() { for (const plugin of plugins) plugin.onDetachedFromEngine?.(binding); } };
    instances.push(instance); return instance;
  }
  const first = attach();
  function call(args = new Map([['name', '鲸鱼娘']]), method = 'update', target = first) {
    if (!target.methods?.handler) return { done: Promise.resolve({ missing: true }), replies: [{ missing: true }] };
    const done = deferred(), replies = [];
    const reply = value => { replies.push(value); done.resolve(value); };
    target.methods.handler.onMethodCall({ method, args, argument: name => args instanceof Map ? args.get(name) : args?.[name] }, {
      success: value => reply({ value }), error: (code, message) => reply({ error: code, message }),
      notImplemented: () => reply({ missing: true }),
    }); return { done: done.promise, replies };
  }
  t?.after(async () => {
    for (const instance of instances) instance.detach(); await settle();
    for (const fd of fds.keys()) { try { fs.closeSync(fd); } catch {} }
    if (temporary) await fsp.rm(root, { force: true, recursive: true });
  });
  return { ...first, root, context, application, channels, calls, updates, errors, fds, call, attach,
    snapshot: () => fsp.readFile(application.filesDir + '/companion-widget/snapshot.json', 'utf8').then(JSON.parse),
    change: values => Object.assign(opt, values),
    data: () => load(ets('companion/CompanionWidgetData')),
    form() { const independent = processLoader(); const Form = independent(ets('formability/CompanionFormAbility')).default; return new Form(); },
  };
}
