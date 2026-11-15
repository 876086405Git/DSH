// Actual product ETS after TypeScript erasure; OS and Flutter are explicit test doubles.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { resolve, join, basename } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
assert(prefix, 'Set OHOS_TYPESCRIPT_PREFIX to the locked process npm-ci directory');
const ts = createRequire(resolve(prefix, 'package.json'))('typescript');
const text = readFileSync(process.env.OHOS_APP_LINKS_SOURCE ?? new URL('../../../app/ohos/entry/src/main/ets/plugins/AppLinksPlugin.ets', import.meta.url), 'utf8');
const compiled = ts.transpileModule(text, { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} });
const plain = value => value instanceof Map || Object.prototype.toString.call(value) === '[object Map]'
  ? Object.fromEntries(value) : value;
const view = uri => ({ action: 'ohos.want.action.viewData', uri });

function fixture({ start = () => Promise.resolve(), zone = () => 'Asia/Shanghai', fsApi = {}, cacheDir = '' } = {}) {
  const channels = [], sent = [], starts = [], listeners = new Set(), waiting = [];
  class Channel {
    constructor(_messenger, name) { this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, args) {
      sent.push({ channel: this.name, method, args: plain(args) });
      for (const done of waiting.splice(0)) done();
    }
  }
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, {
    module, exports: module.exports,
    require(name) {
      if (name === '@ohos.i18n') return { default: { getTimeZone: () => ({ getID: zone }) } };
      if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel };
      if (name === '@ohos.file.fs') return { default: fsApi };
      if (name === '@ohos.app.ability.wantConstant') return { default: { Flags: { FLAG_AUTH_READ_URI_PERMISSION: 1 } } };
      if (name === '@ohos.file.fileuri') return { default: { FileUri: class {
        constructor(value) { this.name = decodeURIComponent(new URL(value).pathname.split('/').at(-1)); }
      } } };
      if (name === '@ohos.util') return { default: { TextEncoder: class {
        encodeInto(value) { return new TextEncoder().encode(value); }
      } } };
      throw new Error(`Unexpected runtime import ${name}`);
    },
  });
  const engine = { getBinaryMessenger: () => ({}) };
  const ability = {
    launchWant: view('dshgo://forum/auth?payload=cold-secret'),
    context: {
      cacheDir,
      abilityInfo: { name: 'EntryAbility', bundleName: 'io.github.ccch1mneyyy.dsh_app' },
      startAbility(want) { starts.push(plain(want)); return start(); },
    },
  };
  const binding = {
    getAbility: () => ability,
    addOnNewWantListener: listener => listeners.add(listener),
    removeOnNewWantListener: listener => listeners.delete(listener),
  };
  const make = () => {
    const plugin = new module.exports.default();
    plugin.onAttachedToEngine(engine);
    return plugin;
  };
  const plugin = make();
  function call(channel, method, args = {}) {
    const handler = channels.filter(c => c.name === channel).at(-1).handler;
    return new Promise(resolve => handler.onMethodCall({ method, argument: name => args[name] }, {
      success: value => resolve({ value: plain(value) }),
      error: (code, message) => resolve({ error: code, message }),
      notImplemented: () => resolve({ missing: true }),
    }));
  }
  async function waitSent(count) {
    while (sent.length < count) await new Promise(resolve => waiting.push(resolve));
  }
  return { plugin, make, engine, channels, sent, starts, listeners, ability, binding, call, waitSent };
}

test('exact channel names, IANA timezone and missing methods', async () => {
  const f = fixture();
  assert.deepEqual(f.channels.map(c => c.name), ['dsh/app', 'dsh/links']);
  assert.deepEqual(await f.call('dsh/app', 'getTimeZoneId'), { value: 'Asia/Shanghai' });
  assert.deepEqual(await f.call('dsh/app', 'unknown'), { missing: true });
  assert.deepEqual(await f.call('dsh/links', 'unknown'), { missing: true });
});

test('cold and warm links wait for ready, use the actual Dart map contract and keep arrival order', async () => {
  const f = fixture();
  f.plugin.onAttachedToAbility(f.binding);
  f.plugin.onNewWant(view('dshgo://open/new'), {});
  assert.deepEqual(f.sent, []);
  assert.deepEqual(await f.call('dsh/links', 'ready'), { value: true });
  assert.deepEqual(f.sent.map(v => v.args), [
    { uri: 'dshgo://forum/auth?payload=cold-secret' }, { uri: 'dshgo://open/new' },
  ]);
  assert(f.sent.every(v => v.channel === 'dsh/links' && v.method === 'link'));
  await f.call('dsh/links', 'ready');
  assert.equal(f.sent.length, 2);
});

test('ability reattach consumes the launch once but intentional repeated warm URLs remain separate arrivals', async () => {
  const f = fixture();
  await f.call('dsh/links', 'ready');
  f.plugin.onAttachedToAbility(f.binding);
  f.plugin.onDetachedFromAbility();
  f.plugin.onAttachedToAbility(f.binding);
  assert.equal(f.sent.length, 1);
  f.plugin.onNewWant(view('https://go.dshtui.com/c/123'), {});
  f.plugin.onNewWant(view('https://go.dshtui.com/c/123'), {});
  assert.equal(f.sent.length, 3);
  assert.equal(f.listeners.size, 1);
});

test('engine replacement before ready preserves the unconsumed launch without replaying it twice', async () => {
  const f = fixture();
  f.plugin.onAttachedToAbility(f.binding);
  f.plugin.onDetachedFromEngine(f.engine);
  const replacement = f.make();
  replacement.onAttachedToAbility(f.binding);
  await f.call('dsh/links', 'ready');
  assert.deepEqual(f.sent.map(v => v.args), [{ uri: 'dshgo://forum/auth?payload=cold-secret' }]);
  replacement.onDetachedFromEngine(f.engine);
  f.plugin.onAttachedToEngine(f.engine);
  f.plugin.onAttachedToAbility(f.binding);
  await f.call('dsh/links', 'ready');
  assert.equal(f.sent.length, 1);
});

test('detach unregisters listeners and method handlers; retired arrivals cannot reach Dart', async () => {
  const f = fixture();
  f.plugin.onAttachedToAbility(f.binding);
  await f.call('dsh/links', 'ready');
  f.plugin.onDetachedFromEngine(f.engine);
  f.plugin.onNewWant(view('dshgo://ignored'), {});
  assert.equal(f.sent.length, 1);
  assert.equal(f.listeners.size, 0);
  assert(f.channels.every(c => c.handler === null));
});

test('ignores non-view intents, unknown schemes, missing colon and oversize input; external files fail explicitly', async () => {
  const f = fixture();
  f.ability.launchWant = {};
  f.plugin.onAttachedToAbility(f.binding);
  await f.call('dsh/links', 'ready');
  for (const want of [{ uri: 'dshgo://x' }, view('javascript:alert(1)'), view('dshgoX'), view('httpsX'), view('dshgo:' + 'x'.repeat(65536))]) {
    f.plugin.onNewWant(want, {});
  }
  assert.deepEqual(f.sent, []);
  f.plugin.onNewWant(view('file://external/not-owned.dshgo'), {});
  await f.waitSent(1);
  assert.deepEqual(f.sent.map(v => v.args), [{ error: 'unreadable', name: null }]);
});

test('foreground launch targets only the attached own ability and reports platform rejection', async () => {
  const f = fixture();
  assert.equal((await f.call('dsh/app', 'bringToFront')).error, 'no_ability');
  f.plugin.onAttachedToAbility(f.binding);
  assert.deepEqual(await f.call('dsh/app', 'bringToFront', { bundleName: 'attacker' }), { value: null });
  assert.deepEqual(JSON.parse(JSON.stringify(f.starts)), [{ bundleName: 'io.github.ccch1mneyyy.dsh_app', abilityName: 'EntryAbility' }]);
  const denied = fixture({ start: () => Promise.reject(new Error('background start denied')) });
  denied.plugin.onAttachedToAbility(denied.binding);
  assert.equal((await denied.call('dsh/app', 'bringToFront')).error, 'ohos_foreground');
});

test('synchronous platform foreground and timezone exceptions become stable channel errors', async () => {
  const f = fixture({ start: () => { throw new Error('context invalid'); }, zone: () => { throw new Error('service unavailable'); } });
  f.plugin.onAttachedToAbility(f.binding);
  assert.equal((await f.call('dsh/app', 'bringToFront')).error, 'ohos_foreground');
  assert.equal((await f.call('dsh/app', 'getTimeZoneId')).error, 'ohos_timezone');
});

test('system refresh strategy is explicit; unsupported force modes are errors, not fabricated success', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('dsh/app', 'setRefreshRateMode', { mode: 'system' }), { value: null });
  for (const mode of ['auto', 'max', 'bad']) {
    assert.equal((await f.call('dsh/app', 'setRefreshRateMode', { mode })).error, 'ohos_unsupported');
  }
  assert.deepEqual(await f.call('dsh/app', 'setFrameActive', { active: false }), { value: null });
});

const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

async function fileFixture(t, options = {}) {
  const root = await fsp.mkdtemp(join(tmpdir(), 'dsh-link-files-'));
  const cacheDir = join(root, '缓存'); await fsp.mkdir(cacheDir);
  const mapped = new Map(), fds = new Set(), opens = [];
  let reads = 0, writes = 0;
  const api = {
    OpenMode: { READ_ONLY: fs.constants.O_RDONLY, WRITE_ONLY: fs.constants.O_WRONLY,
      CREATE: fs.constants.O_CREAT, NOFOLLOW: fs.constants.O_NOFOLLOW, NONBLOCK: fs.constants.O_NONBLOCK },
    async open(path, flags) {
      opens.push({ path, flags });
      if (path.startsWith('file:') && !mapped.has(path)) throw new Error('OS denied URI grant');
      const fd = await promisify(fs.open)(mapped.get(path) ?? path, flags, 0o600);
      fds.add(fd); return { fd };
    },
    async close(file) { const fd = typeof file === 'number' ? file : file.fd; await promisify(fs.close)(fd); fds.delete(fd); },
    stat: fd => promisify(fs.fstat)(fd), lstat: fsp.lstat, listFile: fsp.readdir,
    async mkdtemp(template) { assert(template.endsWith('XXXXXX')); return fsp.mkdtemp(template.slice(0, -6)); },
    async read(fd, buffer, args) {
      reads++;
      if (options.beforeRead) await options.beforeRead({ fd, reads, root });
      if (options.zeroRead) return 0;
      return (await promisify(fs.read)(fd, Buffer.from(buffer), 0,
        Math.min(args.length, options.maxRead ?? Infinity), args.offset)).bytesRead;
    },
    async write(fd, buffer, args) {
      writes++;
      if (options.beforeWrite) await options.beforeWrite({ fd, writes, root });
      if (options.zeroWrite) return 0;
      return (await promisify(fs.write)(fd, Buffer.from(buffer), 0,
        Math.min(buffer.byteLength, options.maxWrite ?? Infinity), args.offset)).bytesWritten;
    },
    async fsync(fd) { if (options.fsyncFail) throw new Error('fsync failure'); await promisify(fs.fsync)(fd); },
    unlink: fsp.unlink, rmdir: path => fsp.rm(path, { recursive: true }),
  };
  const f = fixture({ fsApi: api, cacheDir });
  f.ability.launchWant = {};
  f.plugin.onAttachedToAbility(f.binding);
  t.after(async () => {
    try { assert.equal(fds.size, 0, `FD leak: ${[...fds]}`); }
    finally { for (const fd of fds) { try { fs.closeSync(fd); } catch {} } await fsp.rm(root, { recursive: true, force: true }); }
  });
  return { ...f, root, cacheDir, opens, fds, mapped,
    async source(name = '中文 空格.dshgo', contents = '原始内容') {
      const path = join(root, name); await fsp.writeFile(path, contents);
      const uri = 'file://sender.example/files/' + encodeURIComponent(name); mapped.set(uri, path);
      return { uri, path, want: { ...view(uri), flags: 1 } };
    },
  };
}

test('incoming copied file is a real stable local file URI with original Chinese extension and bounded short IO', async t => {
  const f = await fileFixture(t, { maxRead: 14003, maxWrite: 7001 });
  const bytes = Buffer.alloc(700003, 42); const source = await f.source('中文 空格.dshgo', bytes);
  f.plugin.onNewWant(source.want, {});
  await f.call('dsh/links', 'ready'); await f.waitSent(1);
  assert.equal(typeof f.sent[0].args.uri, 'string', 'must deliver a copied local file, not unreadable');
  const output = new URL(f.sent[0].args.uri);
  assert.equal(output.protocol, 'file:'); assert.equal(output.host, '');
  const path = fileURLToPath(output);
  assert(path.startsWith(f.cacheDir + '/dsh-incoming-')); assert.equal(basename(path), '中文 空格.dshgo');
  await fsp.unlink(source.path);
  assert.deepEqual(await fsp.readFile(path), bytes);
  assert.equal(f.fds.size, 0);
  assert.equal(f.opens[0].flags, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
});

test('slow incoming file keeps link arrival order across engine replacement', { timeout: 10000 }, async t => {
  const entered = deferred(), release = deferred();
  const f = await fileFixture(t, { beforeRead: async ({ reads }) => { if (reads === 1) { entered.resolve(); await release.promise; } } });
  const source = await f.source();
  f.ability.launchWant = source.want;
  f.plugin.onDetachedFromAbility(); f.plugin.onAttachedToAbility(f.binding);
  f.plugin.onNewWant(view('dshgo://open/new'), {});
  await f.call('dsh/links', 'ready'); await entered.promise;
  assert.deepEqual(f.sent, []);
  f.plugin.onDetachedFromEngine(f.engine);
  const replacement = f.make(); replacement.onAttachedToAbility(f.binding);
  await f.call('dsh/links', 'ready'); release.resolve(); await f.waitSent(2);
  assert.equal(await fsp.readFile(fileURLToPath(f.sent[0].args.uri), 'utf8'), '原始内容');
  assert.deepEqual(f.sent[1].args, { uri: 'dshgo://open/new' });
  assert.equal(f.sent.length, 2); assert.equal(f.fds.size, 0);
});

test('own, empty, encoded and credential-bearing authorities and missing read grants never reach fs.open', async t => {
  const f = await fileFixture(t); await f.call('dsh/links', 'ready');
  let count = 0;
  for (const uri of [
    'file:///data/private', 'file://io.github.ccch1mneyyy.dsh_app/data/private',
    'file://' + f.ability.context.abilityInfo.bundleName.toUpperCase() + '/data/private', 'file://%73ender.example/private',
    'file://user@sender.example/private', 'file://sender.example:99/private',
    'file://../data/private', 'file://sender.example/data/%2e%2e/private', 'file://sender.example/data/a%00b',
    'file://sender.example/data/a?query=x', 'file://sender.example/data/a#fragment',
  ]) {
    f.plugin.onNewWant({ ...view(uri), flags: 1 }, {});
    await f.waitSent(++count);
  }
  const source = await f.source(); f.plugin.onNewWant(view(source.uri), {});
  await f.waitSent(12); assert(f.sent.every(x => x.args.error === 'unreadable')); assert.equal(f.opens.length, 0);
});

test('OS grant denial, oversized file, directory, early EOF, zero write and fsync failure produce no successful or partial cache', async t => {
  for (const failure of ['grant', 'oversize', 'directory', 'zeroRead', 'zeroWrite', 'fsyncFail']) {
    const f = await fileFixture(t, { [failure]: true }); await f.call('dsh/links', 'ready');
    const source = await f.source();
    if (failure === 'grant') f.mapped.clear();
    if (failure === 'oversize') await fsp.truncate(source.path, 30 * 1024 * 1024 + 1);
    if (failure === 'directory') f.mapped.set(source.uri, f.root);
    f.plugin.onNewWant(source.want, {}); await f.waitSent(1);
    assert.equal(f.sent[0].args.error, 'unreadable', failure);
    assert.deepEqual(await fsp.readdir(f.cacheDir), [], failure); assert.equal(f.fds.size, 0);
  }
});

test('at most four external file copies hold descriptors and later ordinary links still arrive in order', { timeout: 10000 }, async t => {
  const entered = deferred(), release = deferred(); let started = 0;
  const f = await fileFixture(t, { beforeRead: async () => { if (++started === 4) entered.resolve(); await release.promise; } });
  const source = await f.source(); await f.call('dsh/links', 'ready');
  for (let i = 0; i < 5; i++) f.plugin.onNewWant(source.want, {});
  f.plugin.onNewWant(view('dshgo://open/last'), {});
  await entered.promise; assert.equal(f.opens.filter(x => x.path.startsWith('file:')).length, 4);
  release.resolve(); await f.waitSent(6);
  assert(f.sent.slice(0, 4).every(x => x.args.uri.startsWith('file:///')));
  assert.equal(f.sent[4].args.error, 'unreadable');
  assert.equal(f.sent[5].args.uri, 'dshgo://open/last'); assert.equal(f.fds.size, 0);
});

test('empty files remain valid and a source growing during copying is rejected', async t => {
  const empty = await fileFixture(t); const zero = await empty.source('空文件.txt', '');
  await empty.call('dsh/links', 'ready'); empty.plugin.onNewWant(zero.want, {}); await empty.waitSent(1);
  assert.equal((await fsp.stat(fileURLToPath(empty.sent[0].args.uri))).size, 0);
  const growing = await fileFixture(t, { beforeWrite: async ({ writes }) => {
    if (writes === 1) await fsp.appendFile(source.path, 'tail');
  } });
  const source = await growing.source(); await growing.call('dsh/links', 'ready');
  growing.plugin.onNewWant(source.want, {}); await growing.waitSent(1);
  assert.equal(growing.sent[0].args.error, 'unreadable'); assert.deepEqual(await fsp.readdir(growing.cacheDir), []);
});

test('a valid long Chinese filename keeps its routing extension after UTF-8 truncation', async t => {
  const f = await fileFixture(t); const source = await f.source('文'.repeat(80) + '.dshgo', 'archive');
  await f.call('dsh/links', 'ready'); f.plugin.onNewWant(source.want, {}); await f.waitSent(1);
  const path = fileURLToPath(f.sent[0].args.uri), name = basename(path);
  assert(name.endsWith('.dshgo')); assert(Buffer.byteLength(name) <= 240); assert(!name.includes('\uFFFD'));
  assert.equal(await fsp.readFile(path, 'utf8'), 'archive');
});
