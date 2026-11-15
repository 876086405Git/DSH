// Production EntryAbility/plugin bodies. SDK, chooser, grants and lifecycle are
// explicit doubles; Preferences flush writes an actual temporary Linux file.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { createRequire } from 'node:module';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import vm from 'node:vm';
import {promisify} from 'node:util';
import { entryAbilityImports } from './entry-ability-fixture.mjs';
const repo = fileURLToPath(new URL('../../../', import.meta.url));
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
assert.match(ts.version, /^5\.9\./);
export const plain = value => value instanceof Map ? Object.fromEntries([...value].map(([key, val]) => [key, plain(val)])) :
  Array.isArray(value) ? Array.from(value, plain) : value;
export const deferred = () => Promise.withResolvers();
export async function until(check) {
  const end = Date.now() + 5000;
  while (!check()) { if (Date.now() > end) throw Error('fixture condition timed out'); await new Promise(resolve => setImmediate(resolve)); }
}
export async function workspaceFixture(t, initial = {}) {
  let opt = initial, modules, channels, timers, sequence;
  const root = await fsp.mkdtemp(join(tmpdir(), 'dsh-workspaces-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const storage = join(root, 'preferences.json'), operations = [], pickers = [], persisted = new Set(), active = new Set();
  const uriPaths=new Map(),fds=new Set(); let nativeLoaded=false;
  const native=process.env.OHOS_WORKSPACE_GRANTS_ADDON ? createRequire(import.meta.url)(process.env.OHOS_WORKSPACE_GRANTS_ADDON) : null;
  t.after(()=>{for(const fd of fds){try{fs.closeSync(fd);}catch{}}});
  const app = { filesDir: root, applicationInfo: { accessTokenId: 805 } };
  class Channel { constructor(messenger, name) { this.name = name; channels.push(this); } setMethodCallHandler(handler) { this.handler = handler; } }
  class FlutterAbility { configureFlutterEngine() {} onForeground() {} onBackground() {} onDestroy() {} }
  class Stub {
    static registerWith() {} static onForeground() {} static onBackground() {} static onDestroy() {}
    static receive() {} static applyFrameCache() {} attach() {} detach() {} setForeground() {}
  }
  class DocumentPicker {
    constructor(context) { assert.equal(context, app); }
    select(options) { operations.push({ op: 'select', options: { ...options } }); if (opt.pickThrow) throw opt.pickThrow;
      const wait = deferred(); pickers.push({ options, wait }); return wait.promise; }
  }
  class Uri { constructor(value) { const uri = new URL(value); this.scheme = uri.protocol.slice(0, -1); this.authority = uri.host;
    this.path = uri.pathname; this.query = uri.search.slice(1); this.fragment = uri.hash.slice(1); } }
  const fileShare = { OperationMode: { READ_MODE: 1, WRITE_MODE: 2 },
    async checkPersistentPermission(policies) { operations.push({ op: 'checkPersistent', policies });
      if (opt.check) await opt.check(policies); return policies.map(policy => persisted.has(policy.uri)); },
    async persistPermission(policies) { operations.push({ op: 'persist', policies }); if (opt.persist) await opt.persist(policies);
      for (const policy of policies) persisted.add(policy.uri); },
    async activatePermission(policies) { operations.push({ op: 'activate', policies }); if (opt.activate) await opt.activate(policies);
      for (const policy of policies) { assert(persisted.has(policy.uri)); active.add(policy.uri); } },
    async deactivatePermission(policies) { operations.push({ op: 'deactivate', policies }); if (opt.deactivate) await opt.deactivate(policies);
      for (const policy of policies) { assert(active.has(policy.uri)); active.delete(policy.uri); } },
    async revokePermission(policies) { operations.push({ op: 'revoke', policies }); if (opt.revoke) await opt.revoke(policies);
      for (const policy of policies) { persisted.delete(policy.uri); active.delete(policy.uri); } }
  };
  const boundaries = {
    '@ohos/flutter_ohos': { MethodChannel: Channel, FlutterAbility },
    '@ohos.file.picker': { default: { DocumentViewPicker: DocumentPicker, DocumentSelectOptions: class {}, DocumentSelectMode: { FOLDER: 1 } } },
    '@ohos.file.fileuri': { default: { FileUri: class { constructor(value) { this.value = value; this.name = decodeURIComponent(new URL(value).pathname.split('/').at(-1)); }
      get path() { if (opt.pathThrow) throw Error('conversion failed'); return decodeURIComponent(new URL(this.value).pathname); } } } },
    '@ohos.file.fs':{default:{OpenMode:{READ_ONLY:fs.constants.O_RDONLY,NONBLOCK:fs.constants.O_NONBLOCK},
      async open(uri,flags){operations.push({op:'openDirectory',uri});if(opt.open)await opt.open(uri);assert(uriPaths.has(uri),'not a picker URI');
        const fd=await promisify(fs.open)(uriPaths.get(uri),flags);fds.add(fd);return {fd};},
      async stat(fd){return await promisify(fs.fstat)(fd);},
      async close(file){operations.push({op:'closeDirectory'});if(opt.close)await opt.close(file);await promisify(fs.close)(file.fd);fds.delete(file.fd);}}},
    '@ohos.fileshare': { default: fileShare },
    '@ohos.data.preferences': { default: { async getPreferences(context, options) { assert.equal(context, app); assert.equal(options.name, 'dsh-authorized-workspaces-v1');
      operations.push({ op: 'preferences' }); if (opt.preferences) await opt.preferences();
      let memory = fs.existsSync(storage) ? JSON.parse(await fsp.readFile(storage, 'utf8')) : {};
      return { async get(key, fallback) { return memory[key] ?? fallback; }, async put(key, value) {
          operations.push({ op: 'put' }); if (opt.put) await opt.put(); memory[key] = value; },
        async flush() { operations.push({ op: 'flush' }); if (opt.flush) await opt.flush(); await fsp.writeFile(storage, JSON.stringify(memory)); } }; } } },
    '@ohos.abilityAccessCtrl': { default: { GrantStatus: { PERMISSION_GRANTED: 0, PERMISSION_DENIED: -1 },
      createAtManager: () => ({ checkAccessTokenSync(id, permission) { assert.equal(id, 805); assert.equal(permission, 'ohos.permission.FILE_ACCESS_PERSIST');
        if (opt.permissionThrow) throw Error('permission unavailable'); return opt.permissionDenied ? -1 : 0; } }) } },
    '@ohos.uri': { default: { URI: Uri } }, '@ohos.util': { default: { generateRandomUUID: () => randomUUID() } }
  };
  function load(path) {
    if (modules.has(path)) return modules.get(path).exports;
    const module = { exports: {} }; modules.set(path, module);
    const result = ts.transpileModule(fs.readFileSync(path, 'utf8'), { fileName: path, reportDiagnostics: true,
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } });
    assert.equal(result.diagnostics?.filter(x => x.category === ts.DiagnosticCategory.Error).length ?? 0, 0);
    vm.runInNewContext(result.outputText, { module, exports: module.exports, Map, Set, WeakSet, WeakMap, Promise, Error, JSON, Array,
      setTimeout(callback, delay) { const id = ++sequence; timers.set(id, { callback, delay }); return id; }, clearTimeout: id => timers.delete(id),
      canIUse: capability => !(opt.missingCaps ?? []).includes(capability), require(name) {
        if(name==='../runtime/NativeHost' && path.endsWith('AuthorizedWorkspacesPlugin.ets'))return {
          loadNativeHost:async()=>{assert(native,'OHOS_WORKSPACE_GRANTS_ADDON required for native attach');nativeLoaded=true;return native;},
          peekNativeHost:()=>nativeLoaded?native:null};
        if (name.startsWith('.')) {
          if (name === '../plugins/AuthorizedWorkspacesPlugin' || name === './NativeFilePolicy') return load(resolve(dirname(path), name + '.ets'));
          assert(Object.hasOwn(entryAbilityImports, name), 'unadapted Entry boundary: ' + name);
          return Object.fromEntries(entryAbilityImports[name].map(key => [key, Stub]));
        }
        assert(Object.hasOwn(boundaries, name), 'unadapted SDK boundary: ' + name); return boundaries[name];
      } }, { filename: path });
    return module.exports;
  }
  function attach() {
    const Entry = load(resolve(repo, 'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets')).default;
    const entry = new Entry(); entry.context = app;
    const binding = { getApplicationContext: () => app, getBinaryMessenger: () => ({}) }, ability = { getAbility: () => entry };
    const plugins = [];
    entry.configureFlutterEngine({ getPlugins: () => ({ add(plugin) { plugins.push(plugin); plugin.onAttachedToEngine?.(binding); plugin.onAttachedToAbility?.(ability); } }) });
    entry.onForeground();
    const channel = channels.findLast(value => value.name === 'dsh/authorized-workspaces');
    const plugin = plugins.find(value => value.getUniqueClassName?.() === 'DshAuthorizedWorkspacesPlugin');
    return { entry, binding, ability, channel, plugin, foreground: () => entry.onForeground(), background: () => entry.onBackground() };
  }
  function boot() {
    modules = new Map(); channels = []; timers = new Map(); sequence = 0;
    return attach();
  }
  function call(boot, method, args = {}) {
    const wait = deferred(), replies = [];
    const respond = value => { replies.push(value); wait.resolve(value); if (opt.replyFailure) throw Error('retired messenger'); };
    if (!boot.channel) { respond({ error: 'missing_plugin' }); return { done: wait.promise, replies }; }
    boot.channel.handler.onMethodCall({ method, args: new Map(Object.entries(args)), argument: key => args[key] },
      { success: value => respond({ value: plain(value) }), error: (error, message, details) => respond({ error, message, details: plain(details) }),
        notImplemented: () => respond({ missing: true }) });
    return { done: wait.promise, replies };
  }
  const current = boot();
  return { ...current, boot, attach, call, operations, pickers, storage, persisted, active, app, native, uriPaths, fds,
    select: values => {for(const uri of values){if(!uriPaths.has(uri)){const path=join(root,'selected-'+uriPaths.size);fs.mkdirSync(path);uriPaths.set(uri,path);}}pickers.at(-1).wait.resolve(values)}, change: next => { opt = { ...opt, ...next }; },
    expire: () => { for (const [id, timer] of timers) { timers.delete(id); timer.callback(); } } };
}
