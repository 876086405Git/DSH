import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { gzipSync } from 'node:zlib';
import { mkdtemp, mkdir, writeFile, readFile, rm, readlink, readdir } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';
import { installPluginResolution } from '../../ohos/plugins/resolution.mjs';
installPluginResolution();
import { beginTransaction } from '../../ohos/plugins/store.mjs';
import { runProfileOperation } from '../../ohos/plugins/installer.mjs';

const prefix = resolve(process.env.DSH_PREFIX);
const { Context } = await import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai/cordis/lib/index.js')));
const { PluginPackages, createRuntimeResolution, loadProfileDirectory } = await import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai/dsh-app-boot/lib/index.js')));

function tar(files) {
  return gzipSync(Buffer.concat([...Object.entries(files).flatMap(([name, text]) => {
    const body = Buffer.from(text), header = Buffer.alloc(512);
    header.write('package/' + name);
    for (const [off, len, value] of [[100, 8, 0o600], [108, 8, 0], [116, 8, 0], [124, 12, body.length], [136, 12, 0]])
      header.write(value.toString(8).padStart(len - 1, '0') + '\0', off, len);
    header.fill(32, 148, 156); header.write('0', 156); header.write('ustar\0', 257); header.write('00', 263);
    header.write(header.reduce((a, b) => a + b, 0).toString(8).padStart(6, '0') + '\0 ', 148, 8);
    return [header, body, Buffer.alloc((512 - body.length % 512) % 512)];
  }), Buffer.alloc(1024)]));
}
function packages(definitions) {
  const manifests = {}, archives = {};
  for (const [name, versions] of Object.entries(definitions)) {
    manifests[name] = {};
    for (const [version, value] of Object.entries(versions)) {
      const manifest = { name, version, ...value.manifest };
      const bytes = tar({ 'package.json': JSON.stringify(value.archiveManifest ?? manifest), ...value.files });
      const url = `https://tar.example/${encodeURIComponent(name)}-${version}.tgz`;
      archives[url] = bytes;
      manifests[name][version] = { ...manifest, dist: { tarball: url,
        integrity: 'sha512-' + createHash('sha512').update(bytes).digest('base64') } };
    }
  }
  return async url => {
    if (archives[url]) return new Response(archives[url]);
    const name = decodeURIComponent(new URL(url).pathname.slice(1));
    if (!manifests[name]) return new Response('', { status: 404 });
    return new Response(JSON.stringify({ name, versions: manifests[name], 'dist-tags': { latest: Object.keys(manifests[name]).at(-1) } }));
  };
}
async function fixture(t) {
  const dir = await mkdtemp(join(tmpdir(), 'ohos-installer-'));
  const ctx = new Context();
  t.after(async () => { await ctx.fiber.dispose(); await rm(dir, { recursive: true, force: true }); });
  await writeFile(join(dir, 'package.json'), JSON.stringify({ name: 'profile', dependencies: {} }));
  const installAnchor = join(prefix, 'node_modules/@deepseek-ai/dsh/package.json');
  const resolution = await createRuntimeResolution({ installAnchor, home: dir,
    profile: loadProfileDirectory('dsh', dir, installAnchor) });
  await ctx.plugin(PluginPackages, { resolution });
  return dir;
}
async function selected(dir, name = 'root') {
  const active = JSON.parse(await readFile(join(dir, '.plugin-manager/ohos/active.json')));
  return join(dir, '.plugin-manager/ohos/generations', active.packages[name]);
}
const opts = fetchImpl => ({ fetchImpl, outputBytes: 8192, lookupTimeoutMs: 1000 });

test('installs actual archives, pins conflicts and resolves locked dependencies through Node without links', async t => {
  const dir = await fixture(t);
  const fetchImpl = packages({ root: { '1.0.0': { manifest: { dependencies: { a: '1', b: '2' } },
    files: { 'index.js': "module.exports = [require('a'), require('b')];" } } },
    a: { '1.0.0': { manifest: { dependencies: { b: '1' } }, files: { 'index.js': "module.exports = require('b');" } } },
    b: { '1.0.0': { files: { 'index.js': 'module.exports = 1;' } }, '2.0.0': { files: { 'index.js': 'module.exports = 2;' } } } });
  const tx = beginTransaction(dir);
  const result = await runProfileOperation({ dir }, ['add', 'root@1'], opts(fetchImpl));
  assert.equal(result.exitCode, 0, result.output);
  assert.equal(typeof result.logPath, 'string');
  assert.deepEqual(createRequire(join(dir, 'package.json'))('root'), [1, 2]);
  assert.equal(JSON.parse(await readFile(join(dir, 'package.json'))).dependencies.root, '1.0.0');
  tx.finish(true);
  const target = await selected(dir);
  const lock = JSON.parse(await readFile(join(target, '../../..', 'lock.json')));
  assert.equal(lock.nodes.length, 4);
});

test('update rollback preserves the old physical tree and manifest; remove retains generation', async t => {
  const dir = await fixture(t);
  const fetchImpl = packages({ root: { '1.0.0': { files: { 'index.js': 'module.exports = 1;' } },
    '2.0.0': { files: { 'index.js': 'module.exports = 2;' } } } });
  let tx = beginTransaction(dir);
  assert.equal((await runProfileOperation({ dir }, ['add', 'root@1'], opts(fetchImpl))).exitCode, 0); tx.finish(true);
  const original = await selected(dir);
  tx = beginTransaction(dir);
  assert.equal((await runProfileOperation({ dir }, ['add', 'root@2'], opts(fetchImpl))).exitCode, 0);
  assert.notEqual(await selected(dir), original);
  tx.finish(false);
  assert.equal(await selected(dir), original);
  assert.equal(JSON.parse(await readFile(join(dir, 'package.json'))).dependencies.root, '1.0.0');
  tx = beginTransaction(dir);
  assert.equal((await runProfileOperation({ dir }, ['remove', 'root'], opts(fetchImpl))).exitCode, 0); tx.finish(true);
  assert.equal(JSON.parse(await readFile(join(dir, 'package.json'))).dependencies.root, undefined);
  assert.match(await readFile(join(original, 'index.js'), 'utf8'), /1/);
});

test('archive metadata drift and SRI errors do not publish or leave generation debris', async t => {
  const dir = await fixture(t);
  const fetchImpl = packages({ root: { '1.0.0': { archiveManifest: { name: 'root', version: '1.0.0', dependencies: { hidden: '1' } } } } });
  const tx = beginTransaction(dir);
  const result = await runProfileOperation({ dir }, ['add', 'root'], opts(fetchImpl));
  assert.equal(result.exitCode, 1); assert.match(result.output, /manifest/);
  assert.deepEqual(JSON.parse(await readFile(join(dir, 'package.json'))).dependencies, {});
  assert.deepEqual(await readdir(join(dir, '.plugin-manager/ohos/generations')), []);
  tx.finish(false);
});

test('non-managed removal and cancellation fail with a real diagnostic file', async t => {
  const dir = await fixture(t);
  await mkdir(join(dir, 'node_modules/root'), { recursive: true });
  await writeFile(join(dir, 'node_modules/root/keep'), 'keep');
  let tx = beginTransaction(dir);
  let result = await runProfileOperation({ dir }, ['remove', 'root'], opts(packages({})));
  assert.equal(result.exitCode, 1); assert.equal(await readFile(join(dir, 'node_modules/root/keep'), 'utf8'), 'keep');
  assert.match(await readFile(result.logPath, 'utf8'), /OHOS_PLUGIN_STORE/); tx.finish(false);
  tx = beginTransaction(dir);
  const abort = new AbortController(); abort.abort();
  result = await runProfileOperation({ dir }, ['add', 'root'], { ...opts(packages({})), signal: abort.signal });
  assert.equal(result.exitCode, 1); assert.equal(typeof await readFile(result.logPath, 'utf8'), 'string'); tx.finish(false);
});

test('host peer imports the same singleton while a normal host-named dependency remains private', async t => {
  const dir = await fixture(t), host = join(dir, 'host-core/node_modules/core');
  await mkdir(host, { recursive: true }); await writeFile(join(host, 'package.json'), JSON.stringify({ name: 'core', version: '1.0.0' }));
  await writeFile(join(host, 'index.js'), 'module.exports = { singleton: true };');
  const fetchImpl = packages({ root: { '1.0.0': { manifest: { peerDependencies: { core: '^1' }, dependencies: { helper: '1' } },
    files: { 'index.js': "module.exports = { core: require('core'), helper: require('helper') };" } } },
    helper: { '1.0.0': { files: { 'index.js': 'module.exports = 1;' } } } });
  const hostPackages = new Map([['core', { version: '1.0.0', packageDir: host }],
    ['helper', { version: '2.0.0', packageDir: '/unused-host-helper' }]]);
  const tx = beginTransaction(dir);
  const result = await runProfileOperation({ dir }, ['add', 'root', '--registry=https://registry.example'], { ...opts(fetchImpl), hostPackages });
  assert.equal(result.exitCode, 0, result.output);
  const require = createRequire(join(dir, 'package.json'));
  assert.equal(require('root').core, require(host)); assert.equal(require('root').helper, 1);
  tx.finish(true);
});

test('tampered download and cancellation mid-download restore the entire attempt', async t => {
  const dir = await fixture(t);
  const original = packages({ root: { '1.0.0': { files: { 'index.js': 'module.exports = 1;' } } } });
  for (const mode of ['tamper', 'cancel']) {
    const abort = new AbortController();
    const fetchImpl = async (url, options) => {
      const response = await original(url, options);
      if (!url.startsWith('https://tar.example')) return response;
      if (mode === 'cancel') { abort.abort(); return response; }
      return new Response(Buffer.from('tampered bytes'));
    };
    const tx = beginTransaction(dir);
    const result = await runProfileOperation({ dir }, ['add', 'root'], { ...opts(fetchImpl), signal: abort.signal });
    assert.equal(result.exitCode, 1);
    if (mode === 'tamper') assert.match(result.output, /INTEGRITY/);
    assert.deepEqual(JSON.parse(await readFile(join(dir, 'package.json'))).dependencies, {});
    assert.deepEqual(await readdir(join(dir, '.plugin-manager/ohos/generations')), []);
    tx.finish(false);
  }
});
