// Actual product ETS after TypeScript erasure, real Linux files and the production
// C++ descriptor opener. Flutter, picker and album services are explicit doubles.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';
import test from 'node:test';
import vm from 'node:vm';
import { shareFixture, until as shareUntil } from './hms-share-fixture.mjs';

assert(process.env.OHOS_TYPESCRIPT_PREFIX, 'Set OHOS_TYPESCRIPT_PREFIX to the locked process npm-ci directory');
assert(process.env.OHOS_USER_FILE_ADDON, 'Build user-file-access-addon.cc and set OHOS_USER_FILE_ADDON');
const require = createRequire(import.meta.url);
const native = require(resolve(process.env.OHOS_USER_FILE_ADDON));
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
const source = fs.readFileSync(new URL('../../../app/ohos/entry/src/main/ets/plugins/FilesMediaPlugin.ets', import.meta.url), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} });
const pathModule = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(new URL(
  '../../../app/ohos/entry/src/main/ets/runtime/RuntimePaths.ets', import.meta.url), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
}).outputText, { module: pathModule, exports: pathModule.exports });
const { RuntimePaths } = pathModule.exports;
const plain = value => Object.prototype.toString.call(value) === '[object Map]'
  ? Object.fromEntries([...value].map(([k, v]) => [k, plain(v)]))
  : Array.isArray(value) ? Array.from(value, plain) : value;
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

async function fixture(t, options = {}) {
  const root = await fsp.mkdtemp(join(tmpdir(), 'dsh-files-'));
  const context = { filesDir: join(root, 'files'), cacheDir: join(root, 'cache'), tempDir: join(root, 'temp') };
  const paths = new RuntimePaths(context.filesDir);
  const workspace = paths.workspace;
  for (const path of [workspace, context.cacheDir, context.tempDir, join(root, 'selected'), join(root, 'album')]) {
    await fsp.mkdir(path, { recursive: true });
  }
  const channels = [], starts = [], dialogs = [], photos = [], warnings = [], fds = new Set(), opened = [];
  const documentOpened = deferred(), photoOpened = deferred();
  const destination = join(root, 'selected', '导出.bin'), imageDestination = join(root, 'album', '图片.bin');
  await fsp.writeFile(destination, 'old'); await fsp.writeFile(imageDestination, 'old');
  let releases = 0, reads = 0, writes = 0;
  const mapped = path => path === 'content://picker/one' ? destination : path === 'file://media/one' ? imageDestination : path;
  const fdOf = file => typeof file === 'number' ? file : file.fd;
  const stat = value => ({
    size: value.size, mtime: Math.floor(value.mtimeMs / 1000),
    isDirectory: () => value.isDirectory(), isSymbolicLink: () => value.isSymbolicLink(), isFile: () => value.isFile(),
  });
  const api = {
    OpenMode: {
      READ_WRITE: fs.constants.O_RDWR, CREATE: fs.constants.O_CREAT,
      TRUNC: fs.constants.O_TRUNC, NOFOLLOW: fs.constants.O_NOFOLLOW,
    },
    async mkdir(path) { try { await fsp.mkdir(path); } catch (error) { if (error.code === 'EEXIST') error.code = 13900015; throw error; } },
    async mkdtemp(template) {
      assert(template.endsWith('XXXXXX'), 'OH uv_fs_mkdtemp requires six terminal X characters');
      if (options.mkdtempFail) throw new Error('simulated directory allocation failure');
      const path = await fsp.mkdtemp(template.slice(0, -6));
      if (options.afterMkdtemp) await options.afterMkdtemp(path);
      return path;
    },
    async lstat(path) { return stat(await fsp.lstat(path)); },
    async stat(path) { return stat(typeof path === 'number' ? await promisify(fs.fstat)(path) : await fsp.stat(mapped(path))); },
    async access(path) { try { await fsp.access(path); return true; } catch { return false; } },
    listFile: path => fsp.readdir(path),
    async open(path, mode) {
      const fd = await promisify(fs.open)(mapped(path), mode, 0o600);
      fds.add(fd); opened.push(path); return { fd, path };
    },
    async close(file) { const fd = fdOf(file); await promisify(fs.close)(fd); fds.delete(fd); },
    async read(fd, buffer, opts) {
      reads++;
      if (options.beforeRead) await options.beforeRead({ fd, reads, plugin, context, workspace });
      if (options.zeroRead) return 0;
      const length = Math.min(opts.length, options.maxRead ?? Infinity);
      return (await promisify(fs.read)(fd, Buffer.from(buffer), 0, length, opts.offset)).bytesRead;
    },
    async write(fd, buffer, opts) {
      writes++;
      if (options.beforeWrite) await options.beforeWrite({ fd, writes, plugin, context, workspace });
      if (options.zeroWrite) return 0;
      const length = Math.min(buffer.byteLength, options.maxWrite ?? Infinity);
      return (await promisify(fs.write)(fd, Buffer.from(buffer), 0, length, opts.offset)).bytesWritten;
    },
    fsync: fd => promisify(fs.fsync)(fd), rename: fsp.rename, unlink: fsp.unlink,
    // Public OH rmdir recursively removes contents; Node rmdir does not.
    rmdir: path => fsp.rm(path, { recursive: true }),
  };
  class Channel {
    constructor(_messenger, name) { this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
  }
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, {
    module, exports: module.exports, ArrayBuffer, Uint8Array,
    require(name) {
      if (name === '@ohos.file.fs') return { default: api };
      if (name === '@ohos.file.picker') return { default: { DocumentViewPicker: class {
        async save(args) { dialogs.push(args); documentOpened.resolve(); return options.pick ? await options.pick(args) : ['content://picker/one']; }
      } } };
      if (name === '@ohos.file.fileuri') return { default: { getUriFromPath: path => pathToFileURL(path).href } };
      if (name === '@ohos.file.photoAccessHelper') return { default: {
        PhotoType: { IMAGE: 1 }, getPhotoAccessHelper: () => ({
          async showAssetsCreationDialog(uris, configs) {
            photos.push({ uris: Array.from(uris), configs: JSON.parse(JSON.stringify(configs)) });
            photoOpened.resolve();
            return options.photo ? await options.photo(uris, configs) : ['file://media/one'];
          },
          async release() { releases++; },
        }),
      } };
      if (name === '@ohos.app.ability.wantConstant') return { default: { Flags: { FLAG_AUTH_READ_URI_PERMISSION: 1 } } };
      if (name === '@ohos.security.cryptoFramework') return { default: { createMd: algorithm => {
        assert.equal(algorithm, 'SHA256'); const hash = createHash('sha256');
        return { async update({ data }) { hash.update(data); }, async digest() { return { data: hash.digest() }; } };
      } } };
      if (name === '@ohos.util') return { default: {
        generateRandomUUID: randomUUID,
        TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
      } };
      if (name === '@ohos.hilog') return { default: { warn: (...args) => warnings.push(args) } };
      if (name === '../runtime/NativeHost') return { async loadNativeHost() {
        if (options.beforeNativeLoad) await options.beforeNativeLoad();
        return { openUserFile(root, relative) {
          const fd = native.openUserFile(root, relative); fds.add(fd); return fd;
        } };
      } };
      if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel };
      // PDF page behaviour has its own suite, files-pdf-channel.test.mjs.
      if (name === './HmsPdfPages') return { HmsPdfPages: class { async close() {} } };
      if (name === './PdfInput') return { PdfChannelError: class extends Error { constructor(code, message) { super(message); this.code = code; } } };
      // The controller's path derivation is actual product code. Its native
      // lifecycle is independently exercised by runtime-channel.test.mjs.
      if (name === '../runtime/RuntimeController') return { RuntimeController: {
        get(actual) { assert.equal(actual, context); return { paths }; },
      } };
      throw new Error(`Unexpected runtime import ${name}`);
    },
  });
  const engine = { getApplicationContext: () => context, getBinaryMessenger: () => ({}) };
  const ability = { context: { ...context, async startAbility(want) {
    starts.push(JSON.parse(JSON.stringify(want))); if (options.start) await options.start(want);
  } } };
  const plugin = new module.exports.default();
  plugin.onAttachedToEngine(engine);
  const binding = { getAbility: () => ability };
  if (options.attached !== false) plugin.onAttachedToAbility(binding);
  t.after(async () => {
    try { assert.equal(fds.size, 0, `Leaked descriptors: ${[...fds]}`); }
    finally {
      for (const fd of fds) { try { fs.closeSync(fd); } catch {} }
      await fsp.rm(root, { recursive: true, force: true });
    }
  });
  const call = (channel, method, args = {}) => new Promise(resolve => {
    const handler = channels.find(c => c.name === channel).handler;
    handler.onMethodCall({ method, argument: name => args[name] }, {
      success: value => resolve({ value: plain(value) }), error: (error, message) => resolve({ error, message }),
      notImplemented: () => resolve({ missing: true }),
    });
  });
  return { root, context, workspace, paths, plugin, binding, engine, call, channels, fds, opened, starts, dialogs, photos, warnings, documentOpened, photoOpened,
    destination, imageDestination, get releases() { return releases; },
    async file(name = '中文 空格.txt', bytes = 'hello') { const path = join(workspace, name); await fsp.mkdir(resolve(path, '..'), { recursive: true }); await fsp.writeFile(path, bytes); return path; },
    async cacheFiles() { return await fsp.readdir(context.cacheDir, { recursive: true }); },
  };
}

test('wire names, missing methods, documented unsupported preview and settings', async t => {
  const f = await fixture(t, { attached: false });
  assert.deepEqual(f.channels.map(c => c.name), ['dsh/files', 'dsh/media']);
  assert.deepEqual(await f.call('dsh/files', 'unknown'), { missing: true });
  assert.deepEqual(await f.call('dsh/media', 'unknown'), { missing: true });
  assert.deepEqual(await f.call('dsh/media', 'openSettings'), { value: false });
  assert.deepEqual(await f.call('dsh/files', 'pdfClose'), { value: null });
  assert.equal((await f.call('dsh/files', 'pdfInfo')).error, 'no_ability');
  assert.equal((await f.call('dsh/files', 'pdfPage')).error, 'no_ability');
  assert.equal((await f.call('dsh/files', 'open')).error, 'no_ability');
  assert.deepEqual(await f.call('dsh/files', 'resolveGuest', { path: '/etc/passwd' }), { value: null });
});

test('snapshot uses real descriptors, bounded chunks and partial reads/writes with Chinese names', async t => {
  const f = await fixture(t, { maxRead: 19001, maxWrite: 7003 });
  const bytes = Buffer.from(Array.from({ length: 700003 }, (_, i) => i % 251));
  const path = await f.file('子目录/中文 空格\'双引号".bin', bytes);
  const result = await f.call('dsh/files', 'resolveGuest', { path });
  assert(result.value.startsWith(f.context.cacheDir + '/dsh-exports/'));
  assert(result.value.endsWith('中文 空格_双引号_.bin'));
  assert.deepEqual(await fsp.readFile(result.value), bytes);
  assert.equal(f.fds.size, 0);
  assert(!(await f.cacheFiles()).some(name => name.endsWith('.tmp')));
});

test('real native opener rejects symlink escape and traversal; an already opened source survives path replacement', async t => {
  let replaced = false;
  const f = await fixture(t, { beforeRead: async ({ reads, workspace }) => {
    if (reads === 1 && !replaced) {
      replaced = true;
      await fsp.rename(join(workspace, 'source.txt'), join(workspace, 'retired.txt'));
      await fsp.symlink(join(f.root, 'outside.txt'), join(workspace, 'source.txt'));
    }
  } });
  await fsp.writeFile(join(f.root, 'outside.txt'), 'outside-secret');
  await fsp.symlink(join(f.root, 'outside.txt'), join(f.workspace, 'escape.txt'));
  assert.deepEqual(await f.call('dsh/files', 'resolveGuest', { path: join(f.workspace, 'escape.txt') }), { value: null });
  assert.deepEqual(await f.call('dsh/files', 'resolveGuest', { path: f.workspace + '/../outside.txt' }), { value: null });
  const path = await f.file('source.txt', 'inside');
  const result = await f.call('dsh/files', 'resolveGuest', { path });
  assert.equal(await fsp.readFile(result.value, 'utf8'), 'inside');
});

test('zero writes and source truncation fail without leaving temporary files or descriptors', async t => {
  for (const option of [{ zeroWrite: true }, { zeroRead: true }]) {
    const f = await fixture(t, option); const path = await f.file();
    assert.deepEqual(await f.call('dsh/files', 'resolveGuest', { path }), { value: null });
    assert.equal(f.fds.size, 0);
    assert(!(await f.cacheFiles()).some(name => name.endsWith('.tmp')));
  }
});

test('detach during copying cancels, closes descriptors and removes the uncommitted cache file', async t => {
  const f = await fixture(t, { maxRead: 2, beforeRead: ({ reads, plugin }) => { if (reads === 1) plugin.onDetachedFromAbility(); } });
  const path = await f.file();
  assert.equal((await f.call('dsh/files', 'resolveGuest', { path })).error, 'cancelled');
  assert.equal(f.fds.size, 0);
  assert(!(await f.cacheFiles()).some(name => name.endsWith('.tmp')));
});

test('listOutputs depth, hidden files, symlink exclusion and seconds to milliseconds match Dart', async t => {
  const f = await fixture(t);
  const path = await f.file('DSH-Go/top.txt', '1234');
  await f.file('DSH-Go/.private.txt'); await f.file('DSH-Go/one/two/three.txt');
  await fsp.symlink(path, join(f.paths.outputs, 'link.txt'));
  await f.file('package.json', '{"name":"project"}');
  await f.file('node_modules/package/index.js', 'project dependency');
  await f.file('project/ordinary.txt', 'not a deliverable');
  const r = await f.call('dsh/files', 'listOutputs', { depth: 1 });
  assert.deepEqual(r.value, [{ path, bytes: 4, modified: Math.floor((await fsp.stat(path)).mtimeMs / 1000) * 1000 }]);
  const all = await f.call('dsh/files', 'listOutputs', { depth: 3 });
  assert.equal(all.value.length, 2);
  assert.equal(f.fds.size, 0);
});

test('output listing refuses a replaced root symlink and exporting still excludes DSH_HOME', async t => {
  const f = await fixture(t);
  const secret = join(f.paths.dshHome, 'secret.txt');
  await fsp.mkdir(f.paths.dshHome, { recursive: true });
  await fsp.writeFile(secret, 'private fixture');
  assert.deepEqual(await f.call('dsh/files', 'listOutputs'), { value: [] });
  await fsp.symlink(f.paths.dshHome, f.paths.outputs);
  assert.equal((await f.call('dsh/files', 'listOutputs')).error, 'outside_workspace');
  assert.deepEqual(await f.call('dsh/files', 'resolveGuest', { path: secret }), { value: null });
  assert.deepEqual(await f.call('dsh/files', 'resolveGuest', { path: join(f.paths.outputs, 'secret.txt') }), { value: null });
  assert.equal(f.fds.size, 0);
});

test('save returns the actual selected URI and preserves all bytes through short writes', async t => {
  const f = await fixture(t, { maxWrite: 3 }); const path = await f.file('a.txt', '中文 bytes');
  assert.deepEqual(await f.call('dsh/files', 'saveToDownloads', { path, name: '../chosen.txt' }), { value: 'content://picker/one' });
  assert.equal(await fsp.readFile(f.destination, 'utf8'), '中文 bytes');
  assert.deepEqual(JSON.parse(JSON.stringify(f.dialogs)), [{ newFileNames: ['chosen.txt'] }]);
  assert.equal(f.fds.size, 0);
});

test('two concurrent saves open only one picker and the loser gets busy', async t => {
  const pending = deferred();
  const f = await fixture(t, { pick: () => pending.promise }); const path = await f.file();
  const first = f.call('dsh/files', 'saveToDownloads', { path });
  const second = f.call('dsh/files', 'saveToDownloads', { path });
  await f.documentOpened.promise;
  pending.resolve([]);
  const results = await Promise.all([first, second]);
  assert.equal(f.dialogs.length, 1);
  assert.deepEqual(results.map(r => r.error).sort(), ['busy', 'cancelled']);
});

test('picker cancellation and ability loss do not modify the chosen destination', async t => {
  const pending = deferred(); const f = await fixture(t, { pick: () => pending.promise }); const path = await f.file();
  const work = f.call('dsh/files', 'saveToDownloads', { path });
  await f.documentOpened.promise;
  f.plugin.onDetachedFromAbility(); pending.resolve(['content://picker/one']);
  assert.equal((await work).error, 'cancelled');
  assert.equal(await fsp.readFile(f.destination, 'utf8'), 'old');
  assert.equal(f.fds.size, 0);
});

test('system open grants read only access to the copied cache; 打开方式 is the same Want; OS rejection stays explicit', async t => {
  const f = await fixture(t); const path = await f.file();
  assert.deepEqual(await f.call('dsh/files', 'open', { path, mime: 'text/plain' }), { value: null });
  assert.equal(f.starts[0].action, 'ohos.want.action.viewData');
  assert.equal(f.starts[0].flags, 1); assert.equal(f.starts[0].type, 'text/plain');
  assert(f.starts[0].uri.startsWith(pathToFileURL(f.context.cacheDir).href + '/'));
  assert.deepEqual(await f.call('dsh/files', 'open', { path, mime: 'text/plain', chooser: true }), { value: null });
  assert.equal(f.starts[1].action, f.starts[0].action); assert.equal(f.starts[1].flags, 1);
  const denied = await fixture(t, { start: () => { throw new Error('No handler'); } });
  const other = await denied.file();
  assert.equal((await denied.call('dsh/files', 'open', { path: other })).error, 'failed');
});

test('album save preserves a byte subview through short writes, sanitizes names and releases all resources', async t => {
  const f = await fixture(t, { maxWrite: 4093 });
  const parent = new Uint8Array(600019); for (let i = 0; i < parent.length; i++) parent[i] = i % 251;
  const bytes = parent.subarray(7, 600010);
  assert.deepEqual(await f.call('dsh/media', 'saveImage', { bytes, name: '../中文\'{}[图].png', mime: 'image/png' }), { value: 'file://media/one' });
  assert.deepEqual(await fsp.readFile(f.imageDestination), Buffer.from(bytes));
  assert.deepEqual(f.photos[0].configs, [{ title: '中文____图_', fileNameExtension: 'png', photoType: 1 }]);
  assert.equal(f.releases, 1); assert.equal(f.fds.size, 0);
  assert.deepEqual(await f.cacheFiles(), ['dsh-exports']);
});

test('album rejection, empty input and unsupported MIME do not claim permission failure or success', async t => {
  const f = await fixture(t, { photo: () => [] });
  const args = { bytes: new Uint8Array([1, 2]), name: 'a.png', mime: 'image/png' };
  assert.equal((await f.call('dsh/media', 'saveImage', args)).error, 'cancelled');
  assert.equal(f.releases, 1);
  assert.equal((await f.call('dsh/media', 'saveImage', { ...args, bytes: new Uint8Array() })).error, 'invalid');
  assert.equal((await f.call('dsh/media', 'saveImage', { ...args, mime: 'image/svg+xml' })).error, 'invalid');
  assert.equal(f.photos.length, 1);
  assert.equal(await fsp.readFile(f.imageDestination, 'utf8'), 'old');
  assert.deepEqual(await f.cacheFiles(), ['dsh-exports']);
});

test('a pending media dialog excludes document pickers and detach cancels its late result', async t => {
  const pending = deferred(); const f = await fixture(t, { photo: () => pending.promise }); const path = await f.file();
  const work = f.call('dsh/media', 'saveImage', { bytes: new Uint8Array([1]), name: 'a.jpg', mime: 'image/jpeg' });
  await f.photoOpened.promise;
  assert.equal((await f.call('dsh/files', 'saveToDownloads', { path })).error, 'busy');
  f.plugin.onDetachedFromEngine(f.engine); pending.resolve(['file://media/one']);
  assert.equal((await work).error, 'cancelled');
  assert.equal(f.releases, 1); assert(f.channels.every(channel => channel.handler === null));
  assert.equal(await fsp.readFile(f.imageDestination, 'utf8'), 'old');
});

test('simultaneous snapshots use distinct temp files and commit a complete consistent cache object', async t => {
  const f = await fixture(t, { maxWrite: 997 }); const bytes = Buffer.alloc(70001, 63); const path = await f.file('a.bin', bytes);
  const results = await Promise.all(Array.from({ length: 8 }, () => f.call('dsh/files', 'resolveGuest', { path })));
  assert.equal(new Set(results.map(r => r.value)).size, 1);
  assert.equal(new Set(f.opened.filter(path => path.endsWith('/payload.tmp'))).size, 8);
  assert.deepEqual(await fsp.readFile(results[0].value), bytes);
  assert(!(await f.cacheFiles()).some(name => name.endsWith('.tmp')));
  assert.equal(f.fds.size, 0);
});

test('public mkdtemp failure closes the source and never falls back to a shared filename', async t => {
  const f = await fixture(t, { mkdtempFail: true });
  const path = await f.file();
  assert.deepEqual(await f.call('dsh/files', 'resolveGuest', { path }), { value: null });
  assert.equal(f.fds.size, 0);
  assert.equal(f.opened.length, 0);
  assert.equal((await f.call('dsh/media', 'saveImage', {
    bytes: new Uint8Array([1, 2, 3]), name: '图.png', mime: 'image/png',
  })).error, 'failed');
  assert.equal(f.photos.length, 0);
});

test('recursive OH rmdir is never called on a temporary directory containing unknown data', async t => {
  const directories = [];
  const f = await fixture(t, { afterMkdtemp: async directory => {
    directories.push(directory);
    await fsp.writeFile(join(directory, 'unknown.txt'), 'preserve');
  } });
  const path = await f.file();
  const result = await f.call('dsh/files', 'resolveGuest', { path });
  assert.equal(await fsp.readFile(result.value, 'utf8'), 'hello');
  await f.call('dsh/media', 'saveImage', { bytes: new Uint8Array([1, 2, 3]), name: '图.png', mime: 'image/png' });
  assert.equal(directories.length, 2);
  for (const directory of directories) {
    assert.deepEqual(await fsp.readdir(directory), ['unknown.txt']);
    assert.equal(await fsp.readFile(join(directory, 'unknown.txt'), 'utf8'), 'preserve');
  }
});

test('a symlink at the new staging leaf is rejected and its target is never opened or modified', async t => {
  const f = await fixture(t, { afterMkdtemp: async directory => {
    await fsp.symlink(join(f.root, 'secret.txt'), join(directory, 'payload.tmp'));
  } });
  const secret = join(f.root, 'secret.txt'); await fsp.writeFile(secret, 'untouched');
  const path = await f.file();
  assert.deepEqual(await f.call('dsh/files', 'resolveGuest', { path }), { value: null });
  assert.equal(await fsp.readFile(secret, 'utf8'), 'untouched');
  assert.equal(f.fds.size, 0);
});

test('UTF-8 filename truncation preserves complete code points within the filesystem byte limit', async t => {
  const f = await fixture(t); const path = await f.file();
  const result = await f.call('dsh/files', 'resolveGuest', { path, name: '文😀'.repeat(100) });
  const name = result.value.substring(result.value.lastIndexOf('/') + 1);
  assert(Buffer.byteLength(name) <= 240); assert(!name.includes('\uFFFD'));
  assert.equal(await fsp.readFile(result.value, 'utf8'), 'hello');
});


test('detach while native import is pending cannot open a source or display a picker', async t => {
  const entered = deferred(), release = deferred();
  const f = await fixture(t, { beforeNativeLoad: () => { entered.resolve(); return release.promise; } });
  const path = await f.file();
  const pending = f.call('dsh/files', 'saveToDownloads', { path });
  await entered.promise;
  f.plugin.onDetachedFromAbility();
  release.resolve();
  assert.equal((await pending).error, 'cancelled');
  assert.equal(f.fds.size, 0); assert.equal(f.opened.length, 0); assert.equal(f.dialogs.length, 0);
});


function invokeSaved(handler, method, args = {}) {
  return new Promise(resolve => handler.onMethodCall({ method, argument: key => args[key] }, {
    success: value => resolve({ value: plain(value) }), error: (error, message) => resolve({ error, message }),
    notImplemented: () => resolve({ missing: true }),
  }));
}

test('retired engine handler cannot copy through a newly attached engine', async t => {
  const f = await fixture(t); const path = await f.file();
  const oldHandler = f.channels.find(c => c.name === 'dsh/files').handler;
  const next = { getApplicationContext: () => f.context, getBinaryMessenger: () => ({}) };
  f.plugin.onAttachedToEngine(next);
  assert.equal((await invokeSaved(oldHandler, 'resolveGuest', { path })).error, 'cancelled');
  assert.equal(f.opened.length, 0); assert.equal(f.fds.size, 0);
});

test('late old engine detach cannot remove the current file channel owner', async t => {
  const f = await fixture(t); const path = await f.file();
  const next = { getApplicationContext: () => f.context, getBinaryMessenger: () => ({}) };
  f.plugin.onAttachedToEngine(next); f.plugin.onAttachedToAbility(f.binding);
  const handler = f.channels.filter(c => c.name === 'dsh/files').at(-1).handler;
  f.plugin.onDetachedFromEngine(f.engine);
  const result = await invokeSaved(handler, 'resolveGuest', { path });
  assert.equal(typeof result.value, 'string');
  assert.equal(await fsp.readFile(result.value, 'utf8'), 'hello');
});

// 125: real source file -> production resolveGuest snapshot, not a private helper mirror.
test('valid long Chinese export retains the dshgo routing extension', async t => {
  const f = await fixture(t);
  const original = '文'.repeat(81) + '.dshgo';
  const bytes = Buffer.from('{"dshgo":1,"code":"fixture"}\n');
  const source = await f.file(original, bytes);
  const reply = await f.call('dsh/files', 'resolveGuest', { path: source });
  assert.equal(typeof reply.value, 'string', JSON.stringify(reply));
  const name = reply.value.slice(reply.value.lastIndexOf('/') + 1);
  assert.deepEqual(await fsp.readFile(reply.value), bytes);
  console.log('ACTUAL_125_EXPORT', JSON.stringify({ original, originalBytes: Buffer.byteLength(original), name, bytes: Buffer.byteLength(name), copiedBytes: bytes.length }));
  assert(name.endsWith('.dshgo'), 'A valid exported share-code file must retain its routing extension');
  assert(Buffer.byteLength(name) <= 240);
});

test('actual outgoing share wire retains extension after local export', async t => {
  const f = await fixture(t);
  const source = await f.file('文'.repeat(81) + '.dshgo', 'actual-export-payload');
  const reply = await f.call('dsh/files', 'resolveGuest', { path: source });
  assert.equal(typeof reply.value, 'string');
  const share = await shareFixture(t);
  // Same application cache Context across the two actual platform consumers.
  share.app.cacheDir = f.context.cacheDir;
  const call = share.call(share.outgoing, 'share', { paths: [reply.value], mimeTypes: ['application/octet-stream'] });
  await shareUntil(() => share.panels.some(p => p.visible), 'actual HMS adapter received exported path');
  const panel = share.panels[0], record = panel.data.records[0];
  const sharedPath = decodeURIComponent(new URL(record.uri).pathname);
  assert.equal(await fsp.readFile(sharedPath, 'utf8'), 'actual-export-payload');
  console.log('ACTUAL_125_SHARE_WIRE', JSON.stringify({ inputPath: reply.value, record }));
  panel.emit('dismiss'); await call.done;
  assert(record.title.endsWith('.dshgo'), 'The actual outgoing record must retain the suffix consumed by incoming share-code routing');
  assert(sharedPath.endsWith('.dshgo'));
});


test('export preserves literal percent sequences, Chinese spaces and one file URI encoding', async t => {
  const f = await fixture(t), name = '中文 50% %2F 文件.dshgo';
  const source = await f.file(name, 'literal-percent-payload');
  const reply = await f.call('dsh/files', 'resolveGuest', { path: source });
  assert(reply.value.endsWith('/' + name));
  assert.equal(await fsp.readFile(reply.value, 'utf8'), 'literal-percent-payload');
  await f.call('dsh/files', 'open', { path: source, name, mime: 'application/octet-stream' });
  const uri = f.starts[0].uri;
  assert(uri.includes('%252F'), 'literal percent escape is encoded as data exactly once');
  assert(decodeURIComponent(new URL(uri).pathname).endsWith('/' + name));
});

test('real export keeps bounded suffix and full Unicode code points at the 240-byte budget', async t => {
  const f = await fixture(t);
  for (const name of ['文'.repeat(78) + '.dshgo', '😀'.repeat(60) + '.dshgo']) {
    const source = await f.file(name, name);
    const reply = await f.call('dsh/files', 'resolveGuest', { path: source });
    assert.equal(typeof reply.value, 'string');
    const exported = reply.value.slice(reply.value.lastIndexOf('/') + 1);
    assert(exported.endsWith('.dshgo')); assert(Buffer.byteLength(exported) <= 240);
    assert(!exported.includes('\uFFFD'));
    assert.equal(await fsp.readFile(reply.value, 'utf8'), name);
    if (Buffer.byteLength(name) === 240) assert.equal(exported, name);
  }
});
