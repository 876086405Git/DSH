// Production ETS + real private Linux files. HUKS/Flutter are explicit host doubles.
// AES-GCM below checks the ciphertext protocol, not a HarmonyOS key service or device.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { promisify } from 'node:util';
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import vm from 'node:vm';

assert(process.env.OHOS_TYPESCRIPT_PREFIX, 'Set OHOS_TYPESCRIPT_PREFIX to the existing TypeScript prefix');
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
const repo = fileURLToPath(new URL('../../../', import.meta.url));
export const deferred = () => Promise.withResolvers();
const plain = value => value instanceof Map ? Object.fromEntries(value) : value;
const nativeError = (code, message = 'controlled platform failure') => Object.assign(new Error(message), { code });

export async function secretsFixture(t, initial = {}) {
  const root = await fsp.mkdtemp(join(tmpdir(), 'dsh-secrets-'));
  const app = { filesDir: join(root, 'files') };
  await fsp.mkdir(app.filesDir);
  let options = initial, nextHandle = 0, pending = 0;
  const unusableKeys = new Set();
  const fds = new Map(), keys = new Map(), sessions = new Map(), events = [], channels = [], modules = new Map();
  const fileError = error => { if (error.code === 'ENOENT') error.code = 13900002; if (error.code === 'EEXIST') error.code = 13900015; throw error; };
  const fdOf = value => typeof value === 'number' ? value : value.fd;
  const stat = value => ({ size: value.size, isFile: () => value.isFile(), isDirectory: () => value.isDirectory(), isSymbolicLink: () => value.isSymbolicLink() });
  const api = {
    OpenMode: { READ_ONLY: fs.constants.O_RDONLY, WRITE_ONLY: fs.constants.O_WRONLY,
      CREATE: fs.constants.O_CREAT, NOFOLLOW: fs.constants.O_NOFOLLOW, NONBLOCK: fs.constants.O_NONBLOCK, DIR: fs.constants.O_DIRECTORY },
    async lstat(path) { try { return stat(await fsp.lstat(path)); } catch (error) { fileError(error); } },
    async stat(value) { return stat(typeof value === 'number' ? await promisify(fs.fstat)(value) : await fsp.stat(value)); },
    async mkdir(path) { try { await fsp.mkdir(path, { mode: 0o700 }); } catch (error) { fileError(error); } },
    async mkdtemp(template) { assert(template.endsWith('XXXXXX')); return fsp.mkdtemp(template.slice(0, -6)); },
    async open(path, flags) { if (options.beforeOpen) await options.beforeOpen(path, flags); const fd = await promisify(fs.open)(path, flags, 0o600); fds.set(fd, path); events.push({ op: 'open', path }); return { fd, path }; },
    async close(file) { const fd = fdOf(file); const path = fds.get(fd); await promisify(fs.close)(fd); fds.delete(fd); if (options.afterClose) await options.afterClose(path); },
    async read(fd, buffer, args) {
      return (await promisify(fs.read)(fd, Buffer.from(buffer), 0, Math.min(args.length, options.maxRead ?? Infinity), args.offset)).bytesRead;
    },
    async write(fd, buffer, args) {
      if (options.beforeWrite) await options.beforeWrite({ fd, path: fds.get(fd), length: buffer.byteLength });
      return (await promisify(fs.write)(fd, Buffer.from(buffer), 0, Math.min(buffer.byteLength, options.maxWrite ?? Infinity), args.offset)).bytesWritten;
    },
    async fsync(fd) { events.push({ op: 'fsync', path: fds.get(fd) }); if (options.beforeSync) await options.beforeSync(fds.get(fd)); await promisify(fs.fsync)(fd); },
    async rename(from, to) { if (options.beforeRename) await options.beforeRename(from, to); await fsp.rename(from, to); events.push({ op: 'publish', path: to }); },
    async unlink(path) { if (options.beforeUnlink) await options.beforeUnlink(path); try { await fsp.unlink(path); } catch (error) { fileError(error); } }, rmdir: path => fsp.rmdir(path),
  };
  for (const [name, operation] of Object.entries(api)) {
    if (typeof operation !== 'function') continue;
    api[name] = async (...args) => { pending++; try { return await operation(...args); } finally { pending--; } };
  }
  // Enum labels are a test boundary; the actual API names/types are also compiled against the fixed public SDK.
  const tags = Object.fromEntries(['ALGORITHM', 'KEY_SIZE', 'PURPOSE', 'PADDING', 'BLOCK_MODE', 'NONCE',
    'ASSOCIATED_DATA', 'AE_TAG', 'KEY_OVERRIDE', 'AUTH_STORAGE_LEVEL'].map(name => ['HUKS_TAG_' + name, name]));
  const values = options => new Map((options.properties ?? []).map(row => [row.tag, row.value]));
  const huks = {
    HuksTag: tags, HuksKeyAlg: { HUKS_ALG_AES: 20 }, HuksKeySize: { HUKS_AES_KEY_SIZE_256: 256 },
    HuksKeyPurpose: { HUKS_KEY_PURPOSE_ENCRYPT: 1, HUKS_KEY_PURPOSE_DECRYPT: 2 },
    HuksKeyPadding: { HUKS_PADDING_NONE: 0 }, HuksCipherMode: { HUKS_MODE_GCM: 32 },
    HuksAuthStorageLevel: { HUKS_AUTH_STORAGE_LEVEL_CE: 1 },
    async isKeyItemExist(alias, supplied) {
      assert.equal(values(supplied).get('AUTH_STORAGE_LEVEL'), 1);
      events.push({ op: 'hasKey', alias });
      if (options.keyQueryError) throw nativeError(options.keyQueryError);
      if (!keys.has(alias)) throw nativeError(12000011);
      return true;
    },
    async generateKeyItem(alias, supplied) {
      const p = values(supplied);
      assert.equal(p.get('KEY_SIZE'), 256); assert.equal(p.get('KEY_OVERRIDE'), false);
      assert.equal(p.get('PURPOSE'), 3); assert.equal(p.get('AUTH_STORAGE_LEVEL'), 1);
      if (keys.has(alias)) throw nativeError(12000017);
      keys.set(alias, randomBytes(32)); events.push({ op: 'generate', alias });
    },
    async deleteKeyItem(alias, supplied) {
      assert.deepEqual([...values(supplied)], [['AUTH_STORAGE_LEVEL', 1]]);
      events.push({ op: 'deleteKey', alias });
      if (options.beforeDeleteKey) await options.beforeDeleteKey(alias);
      if (options.deleteKeyError) throw nativeError(options.deleteKeyError);
      if (!keys.has(alias)) throw nativeError(12000011);
      keys.delete(alias); unusableKeys.delete(alias);
    },
    async initSession(alias, supplied) {
      if (unusableKeys.has(alias)) throw nativeError(12000006);
      const p = values(supplied), key = keys.get(alias);
      assert(key); assert.equal(p.get('KEY_SIZE'), 256); assert.equal(p.get('BLOCK_MODE'), 32);
      assert.equal(p.get('PADDING'), 0); assert.equal(p.get('AUTH_STORAGE_LEVEL'), 1);
      assert.equal(p.get('NONCE').byteLength, 12); assert(p.get('ASSOCIATED_DATA').byteLength > 0);
      const encrypt = p.get('PURPOSE') === 1;
      const cipher = encrypt ? createCipheriv('aes-256-gcm', key, p.get('NONCE')) : createDecipheriv('aes-256-gcm', key, p.get('NONCE'));
      cipher.setAAD(p.get('ASSOCIATED_DATA'));
      if (!encrypt) { assert.equal(p.get('AE_TAG').byteLength, 16); cipher.setAuthTag(p.get('AE_TAG')); }
      const handle = ++nextHandle; sessions.set(handle, { cipher, encrypt });
      events.push({ op: 'init', handle, encrypt }); return { handle };
    },
    async updateSession(handle, supplied) {
      const session = sessions.get(handle); assert(session);
      assert(supplied.inData.byteLength <= 64 * 1024);
      events.push({ op: 'update', handle, bytes: supplied.inData.byteLength });
      return { outData: new Uint8Array(session.cipher.update(supplied.inData)) };
    },
    async finishSession(handle, supplied) {
      const session = sessions.get(handle); assert(session);
      assert(supplied.inData.byteLength <= 64 * 1024);
      if (options.beforeFinish) await options.beforeFinish({ handle, encrypt: session.encrypt });
      if (options.finishFailure) throw nativeError(12000006);
      const parts = [session.cipher.update(supplied.inData), session.cipher.final()];
      if (session.encrypt) parts.push(session.cipher.getAuthTag());
      sessions.delete(handle); events.push({ op: 'finish', handle });
      return { outData: new Uint8Array(Buffer.concat(parts)) };
    },
    async abortSession(handle) { sessions.delete(handle); events.push({ op: 'abort', handle }); },
  };
  class MethodChannel {
    constructor(messenger, name) { this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
  }
  const boundaries = {
    '@ohos.file.fs': { default: api }, '@kit.UniversalKeystoreKit': { huks },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createRandom: () => ({ async generateRandom(length) {
      assert.equal(length, 12); events.push({ op: 'random', bytes: length }); return { data: new Uint8Array(randomBytes(length)) };
    } }) } },
    '@ohos.util': { default: {
      TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
      TextDecoder: { create: (encoding, supplied) => ({ decodeToString: bytes => new TextDecoder(encoding, supplied).decode(bytes) }) },
    } },
    '@ohos/flutter_ohos': { MethodChannel },
    '@ohos.hilog': { default: { warn(domain, tag, message) { events.push({ op: 'warning', domain, tag, message }); } } },
  };
  function load(path) {
    if (modules.has(path)) return modules.get(path).exports;
    const module = { exports: {} }; modules.set(path, module);
    const compiled = ts.transpileModule(fs.readFileSync(path, 'utf8'), {
      reportDiagnostics: true, compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
    });
    assert.deepEqual(compiled.diagnostics.filter(value => value.category === ts.DiagnosticCategory.Error), []);
    try { vm.runInNewContext(compiled.outputText, {
      module, exports: module.exports, Map, Array, Uint8Array, ArrayBuffer, Promise, Error,
      require(name) {
        if (name.startsWith('.')) return load(resolve(dirname(path), name + '.ets'));
        assert(name in boundaries, 'Unadapted platform boundary ' + name); return boundaries[name];
      },
    }, { filename: path }); } catch (error) { modules.delete(path); throw error; }
    return module.exports;
  }
  const Plugin = load(resolve(repo, 'app/ohos/entry/src/main/ets/plugins/SecretsPlugin.ets')).default;
  function attach() {
    const plugin = new Plugin(), engine = { getApplicationContext: () => app, getBinaryMessenger: () => ({}) };
    plugin.onAttachedToEngine(engine); return { plugin, engine, channel: channels.at(-1) };
  }
  function call(channel, method, args = {}) {
    const done = deferred(), replies = [];
    const reply = value => { replies.push(value); done.resolve(value); if (options.replyFailure) throw Error('retired transport'); };
    channel.handler.onMethodCall({ method, argument: name => args[name] }, {
      success: value => reply({ value: plain(value) }), error: (error, message) => reply({ error, message }),
      notImplemented: () => reply({ missing: true }),
    });
    return { done: done.promise, replies };
  }
  const first = attach(), vaultPath = join(app.filesDir, 'dsh-secrets/vault-v1.bin');
  t.after(async () => {
    first.plugin.onDetachedFromEngine(first.engine);
    try { assert.equal(pending, 0); assert.equal(fds.size, 0); assert.equal(sessions.size, 0); }
    finally { for (const fd of fds.keys()) { try { fs.closeSync(fd); } catch {} } await fsp.rm(root, { recursive: true, force: true }); }
  });
  return { root, app, vaultPath, ...first, attach, call, events, keys, unusableKeys, sessions, fds,
    change(next) { options = { ...options, ...next }; },
    request(method, args = {}, channel = first.channel) { return call(channel, method, args).done; },
  };
}
