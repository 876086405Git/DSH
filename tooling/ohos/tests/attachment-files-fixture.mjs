// Production ETS executes against real Linux files. Picker/URI grants, Flutter
// and OH metadata are explicit API doubles; this is not a device picker test.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { promisify } from 'node:util';

const repository = fileURLToPath(new URL('../../../', import.meta.url));
export const deferred = () => Promise.withResolvers();
export const plain = value => value instanceof Map
  ? Object.fromEntries([...value].map(([key, item]) => [key, plain(item)]))
  : Array.isArray(value) ? Array.from(value, plain) : value;
export async function until(check) {
  const end = Date.now() + 5000;
  while (!await check()) {
    if (Date.now() > end) throw new Error('fixture condition did not settle');
    await new Promise(resolve => setImmediate(resolve));
  }
}

export async function attachmentFixture(t, initial = {}) {
  assert(process.env.OHOS_TYPESCRIPT_PREFIX, 'use the fixed SDK TypeScript adapter');
  const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
  const root = await fsp.mkdtemp(join(tmpdir(), 'dsh-attachment-picker-'));
  const context = { cacheDir: join(root, 'cache'), filesDir: join(root, 'files') };
  await fsp.mkdir(context.cacheDir); await fsp.mkdir(context.filesDir);
  const options = { ...initial }, channels = [], pickers = [], operations = [];
  const descriptors = new Set(), uris = new Map(), modules = new Map();
  let fileNumber = 0;
  const mapped = path => {
    if (path.startsWith('file:')) {
      assert(uris.has(path), 'only the system fixture grants an external URI');
      return uris.get(path);
    }
    assert(path === context.cacheDir || path.startsWith(context.cacheDir + '/'), 'private cache only');
    return path;
  };
  const business = error => {
    if (error.code === 'ENOENT') error.code = 13900002;
    if (error.code === 'EEXIST') error.code = 13900015;
    return error;
  };
  const api = {
    OpenMode: { READ_ONLY: fs.constants.O_RDONLY, WRITE_ONLY: fs.constants.O_WRONLY,
      CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC,
      NOFOLLOW: fs.constants.O_NOFOLLOW, NONBLOCK: fs.constants.O_NONBLOCK },
    async open(path, flags) {
      operations.push({ op: 'open', path, flags });
      await options.open?.(path);
      const fd = await promisify(fs.open)(mapped(path), flags, 0o600);
      descriptors.add(fd); return { fd };
    },
    async stat(fd) {
      const actual = await promisify(fs.fstat)(fd);
      return { size: options.reportedSize ?? actual.size, isFile: () => actual.isFile(),
        isDirectory: () => actual.isDirectory(), isSymbolicLink: () => false };
    },
    async lstat(path) {
      try { return await fsp.lstat(mapped(path)); } catch (error) { throw business(error); }
    },
    async read(fd, buffer, args) {
      operations.push({ op: 'read', fd, offset: args.offset, length: args.length });
      await options.read?.(fd, buffer, args);
      return (await promisify(fs.read)(fd, Buffer.from(buffer), 0,
        Math.min(args.length ?? buffer.byteLength, options.maxRead ?? Infinity), args.offset)).bytesRead;
    },
    async write(fd, buffer, args) {
      operations.push({ op: 'write', fd, offset: args.offset, length: buffer.byteLength });
      await options.write?.(fd, buffer, args);
      return (await promisify(fs.write)(fd, Buffer.from(buffer), 0,
        Math.min(args.length ?? buffer.byteLength, options.maxWrite ?? Infinity), args.offset)).bytesWritten;
    },
    async close(file) {
      const fd = typeof file === 'number' ? file : file.fd;
      operations.push({ op: 'close', fd });
      await promisify(fs.close)(fd); descriptors.delete(fd);
    },
    async mkdir(path) { try { await fsp.mkdir(mapped(path)); } catch (error) { throw business(error); } },
    async mkdtemp(path) {
      assert(path.endsWith('XXXXXX'), 'SDK mkdtemp requires a six-X template');
      return fsp.mkdtemp(mapped(path).slice(0, -6));
    },
    async listFile(path) { return fsp.readdir(mapped(path)); },
    async unlink(path) {
      operations.push({ op: 'unlink', path });
      await options.unlink?.(path);
      try { await fsp.unlink(mapped(path)); } catch (error) { throw business(error); }
    },
    async rmdir(path) {
      operations.push({ op: 'rmdir', path });
      await options.rmdir?.(path);
      try { await fsp.rmdir(mapped(path)); } catch (error) { throw business(error); }
    },
  };
  class MethodChannel {
    constructor(messenger, name) { this.messenger = messenger; this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
  }
  class DocumentViewPicker {
    constructor(actual) { assert.equal(actual, context); }
    select(selection) {
      const wait = deferred();
      const request = { options: { ...selection }, wait, settled: false };
      pickers.push(request);
      return wait.promise.finally(() => { request.settled = true; });
    }
  }
  const boundaries = {
    '@ohos.file.fs': { default: api },
    '@ohos.file.picker': { default: { DocumentViewPicker, DocumentSelectOptions: class {}, DocumentSelectMode: { FILE: 0 } } },
    '@ohos.file.fileuri': { default: { FileUri: class {
      constructor(value) { this.name = decodeURIComponent(new URL(value).pathname.split('/').at(-1)); }
    } } },
    '@ohos/flutter_ohos': { MethodChannel },
    '@ohos.app.ability.common': { default: {} },
    '@ohos.hilog': { default: { warn() { operations.push({ op: 'cleanup-warning' }); } } },
  };
  function load(path) {
    if (modules.has(path)) return modules.get(path).exports;
    const module = { exports: {} }; modules.set(path, module);
    const compiled = ts.transpileModule(fs.readFileSync(path, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
    }).outputText;
    vm.runInNewContext(compiled, { module, exports: module.exports, Map, Set, ArrayBuffer, Uint8Array,
      Promise, Error, canIUse: () => !options.unavailable,
      require(name) {
        if (name.startsWith('.')) return load(resolve(dirname(path), name + '.ets'));
        assert(name in boundaries, 'unadapted boundary: ' + name); return boundaries[name];
      },
    }, { filename: path });
    return module.exports;
  }
  const Plugin = load(resolve(repository, 'app/ohos/entry/src/main/ets/plugins/AttachmentFilesPlugin.ets')).default;
  function attach(plugin = new Plugin()) {
    const engine = { getApplicationContext: () => context, getBinaryMessenger: () => ({}) };
    const ability = { getAbility: () => ({ context }) };
    plugin.onAttachedToEngine(engine); plugin.onAttachedToAbility(ability);
    const channel = channels.at(-1); assert.equal(channel.name, 'dsh/attachment-files');
    return { plugin, engine, ability, channel };
  }
  await options.seedCache?.(context.cacheDir);
  const attached = attach();
  function invoke(method, arguments_ = {}, channel = attached.channel) {
    const result = deferred(), replies = [], args = new Map(Object.entries(arguments_));
    channel.handler.onMethodCall({ method, args, argument: key => args.get(key) }, {
      success(value) { replies.push({ value: plain(value) }); result.resolve(replies.at(-1)); },
      error(code, message) { replies.push({ error: code, message }); result.resolve(replies.at(-1)); },
      notImplemented() { replies.push({ notImplemented: true }); result.resolve(replies.at(-1)); },
    });
    return { done: result.promise, replies };
  }
  async function file(name, bytes) {
    const number = fileNumber++, local = join(context.filesDir, String(number));
    await fsp.writeFile(local, bytes);
    const uri = 'file://docs/' + number + '/' + encodeURIComponent(name); uris.set(uri, local); return uri;
  }
  async function cached() {
    // Recursive readdir can observe a directory removed during traversal.
    // Retry the observation; do not turn a failed snapshot into an empty cache.
    for (let attempt = 0; ; attempt++) {
      try { return (await fsp.readdir(context.cacheDir, { recursive: true })).sort(); }
      catch (error) {
        if (attempt === 4 || error.code !== 'ENOENT' || !error.path?.startsWith(context.cacheDir + '/')) throw error;
      }
    }
  }
  t.after(async () => {
    for (const picker of pickers) if (!picker.settled) picker.wait.resolve([]);
    attached.plugin.onDetachedFromEngine(attached.engine);
    await new Promise(resolve => setImmediate(resolve));
    try { assert.equal(descriptors.size, 0, 'production must close its descriptors before fixture cleanup'); }
    finally {
      for (const fd of descriptors) await promisify(fs.close)(fd).catch(() => {});
      await fsp.rm(root, { recursive: true, force: true });
    }
  });
  return { ...attached, root, context, operations, descriptors, pickers, uris, file, cached, invoke, attach,
    change: changes => Object.assign(options, changes),
    select: async values => {
      await until(() => pickers.some(picker => !picker.settled));
      pickers.at(-1).wait.resolve(values);
    },
  };
}
