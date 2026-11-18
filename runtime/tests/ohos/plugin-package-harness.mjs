import '../../ohos/plugins/preload.mjs';
import { selectedPackage as readSelectedPackage } from './plugin-selection-fixture.mjs';
import assert from 'node:assert/strict';
import { createServer, request } from 'node:http';
import { Readable } from 'node:stream';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { mkdtemp, mkdir, writeFile, readFile, rm, readdir, lstat, readlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { gzipSync } from 'node:zlib';
import { toolSource, tarFile } from './plugin-package-fixture.mjs';

const prefix = resolve(process.env.DSH_PREFIX);
const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { boot, PluginPackages, createRuntimeResolution, loadProfile } = await load('dsh-app-boot');
const { PluginManager } = await load('dsh-plugin-manager');
const { TYPERT } = await import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai/dsh-plugin-manager/lib/typert.host.js')));
export const name = 'ohos-owned-js-bundle';
export const selectedPackage = (dir, packageName = name) => readSelectedPackage(dir, packageName);
export function selectedEntry(dir, packageName = name) {
  const selected = selectedPackage(dir, packageName);
  assert.equal(typeof selected, 'string', 'the active manifest must select an installed package');
  // The linkless layout has no profile/node_modules alias. Observe the actual
  // selected directory, then let Node resolve its package exports normally.
  return createRequire(join(selected, 'package.json')).resolve(packageName);
}
export async function runInstalledTool(dir, expectedVersion) {
  const [{ Context }, { SystemPrompt }, { ToolRuntime }, native] = await Promise.all([
    'cordis', 'dsh-system-prompt', 'dsh-tools', 'dsh-tool-executor-native',
  ].map(load));
  const ctx = new Context();
  try {
    await ctx.plugin(SystemPrompt, {}); await ctx.plugin(ToolRuntime, {}); await ctx.plugin(native);
    const entry = selectedEntry(dir);
    await ctx.plugin(await import(pathToFileURL(entry)));
    const batch = await ctx.tools.execute({ calls: [{ id: 'installed-echo', name: 'ohos_installed_echo',
      arguments: JSON.stringify({ text: '已安装纯JS工具' }) }], signal: new AbortController().signal });
    const result = batch.results[0].result;
    assert.notEqual(result.isError, true, JSON.stringify(result));
    assert.deepEqual(JSON.parse(result.content[0].text), { text: '已安装纯JS工具', version: expectedVersion });
    return { entry, result };
  } finally { await ctx.fiber.dispose(); }
}
export const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const reports = [];
export async function fixture(t, definitions = {}, { profileName = 'web', requireOhos = true, hmr = false, keepProfile = false, network } = {}) {
  if (requireOhos) assert.equal(process.platform, 'openharmony', 'run with the existing OH simulation preload');
  const root = await mkdtemp(join(tmpdir(), 'ohos-owned-plugin-lifecycle-'));
  let ctx, server;
  const backendKey = Symbol.for('dsh.go.ohos.plugins');
  const previousBackend = globalThis[backendKey];
  const facts = { test: t.name, scope: 'real boot/Loader/PluginManager; HTTPS registry fixture transported to own loopback HTTP server; no manager method replacement', calls: [], requests: [] };
  t.after(async () => {
    t.diagnostic(JSON.stringify(facts));
    reports.push(facts);
    if (process.env.DSH_PLUGIN_CONTRACT_REPORT) await writeFile(process.env.DSH_PLUGIN_CONTRACT_REPORT, JSON.stringify(reports, null, 2) + '\n');
    await ctx?.fiber.dispose();
    if (previousBackend === undefined) delete globalThis[backendKey];
    else globalThis[backendKey] = previousBackend;
    if (server) { server.closeAllConnections(); await new Promise(done => server.close(done)); }
    if (!keepProfile) await rm(root, { recursive: true, force: true });
  });
  const versions = {}, archives = new Map();
  const tarEntered = Promise.withResolvers();
  let heldVersion;
  for (const version of new Set(['1.0.0', '2.0.0', ...Object.keys(definitions)])) {
    const manifest = { name, version, type: 'module', exports: { '.': './index.mjs', './package.json': './package.json' }, dsh: { bundle: { patch: 'cordis.patch.yml' } }, ...definitions[version]?.manifest };
    const bytes = definitions[version]?.archive ?? gzipSync(Buffer.concat([
      tarFile('package.json', JSON.stringify(manifest)), tarFile('index.mjs', definitions[version]?.source ?? toolSource(version)),
      tarFile('cordis.patch.yml', definitions[version]?.yaml ?? '[]\n'),
      ...Object.entries(definitions[version]?.files ?? {}).map(([path, content]) => tarFile(path, content)),
      Buffer.alloc(1024),
    ]));
    archives.set(version, bytes);
    versions[version] = { ...manifest, dist: { integrity: `sha512-${createHash('sha512').update(bytes).digest('base64')}` } };
  }
  server = createServer((req, res) => {
    facts.requests.push(req.url);
    if (network?.onRequest?.(req, res)) return;
    if (req.url.startsWith('/tar/')) {
      const bytes = archives.get(req.url.slice(5));
      if (!bytes) { res.writeHead(404).end(); return; }
      res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': bytes.length });
      if (req.url.slice(5) === heldVersion) { res.write(bytes.subarray(0, 32)); tarEntered.resolve(); }
      else res.end(bytes);
    } else if (decodeURIComponent(req.url) === '/' + name) {
      res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ name, 'dist-tags': { latest: '2.0.0' }, versions }));
    } else res.writeHead(404).end();
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const localOrigin = `http://127.0.0.1:${server.address().port}`;
  const registry = 'https://registry.ohos-fixture.test';
  if (process.env.DSH_PLUGIN_BACKEND_MODULE) {
    const { createPluginBackend } = await import(pathToFileURL(resolve(process.env.DSH_PLUGIN_BACKEND_MODULE)));
    globalThis[backendKey] = createPluginBackend({ fetchImpl: network?.createFetch?.(localOrigin) ?? (async (input, init) => {
      const requested = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
      assert.equal(requested.origin, registry, 'fixture never contacts external providers');
      return new Promise((resolve, reject) => {
        const req = request(localOrigin + requested.pathname + requested.search,
          { method: 'GET', signal: init?.signal, headers: init?.headers }, res => {
            resolve(new Response(Readable.toWeb(res), { status: res.statusCode, headers: res.headers }));
          });
        req.on('error', reject); req.end();
      });
    }) });
  }
  for (const [version, meta] of Object.entries(versions)) meta.dist.tarball = registry + '/tar/' + version;
  const home = join(root, 'home'), dir = join(home, 'profiles', profileName);
  await mkdir(dir, { recursive: true });
  const manifestPath = join(dir, 'package.json'), main = join(dir, 'cordis.yml'), patchPath = join(dir, 'cordis.patch.yml');
  await writeFile(manifestPath, JSON.stringify({ name: 'ohos-owned-profile', private: true, dependencies: {}, dsh: { profile: { bundles: [] } } }));
  await writeFile(main, '[]\n');
  const managerEntry = join(prefix, 'node_modules/@deepseek-ai/dsh-plugin-manager/lib/index.js');
  facts.managerSha256 = hash(await readFile(managerEntry));
  const rows = [{ insert: [{ id: 'manager', name: pathToFileURL(managerEntry).href, config: { registry, fallbackRegistries: network?.fallbackRegistries ?? [], inspectTimeoutMs: 5000 } }] }];
  if (hmr) rows[0].insert.unshift(...[
    ['timer', 'cordis-plugin-timer'], ['hmr', 'dsh-hmr'],
    ['system-prompt', 'dsh-system-prompt'], ['tools', 'dsh-tools'], ['executor', 'dsh-tool-executor-native'],
  ].map(([id, pkg]) => ({ id, name: pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', pkg, 'lib/index.js')).href,
    ...(id === 'hmr' ? { config: { root: [] } } : {}) })));
  await writeFile(patchPath, JSON.stringify(rows));
  const start = async (active = false) => {
    await ctx?.fiber.dispose();
    const activeRows = active ? [{ insert: [
      ...['dsh-system-prompt', 'dsh-tools', 'dsh-tool-executor-native'].map((pkg, i) => ({
        id: 'fixture-service-' + i, name: pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', pkg, 'lib/index.js')).href })),
      { id: 'installed-root', name },
    ] }] : [];
    const listeners = new Set(); let ready = false;
    const installAnchor = join(prefix, 'node_modules/@deepseek-ai/dsh/package.json');
    const resolution = hmr ? await createRuntimeResolution({ installAnchor, home,
      profile: loadProfile('dsh', profileName, installAnchor, home) }) : undefined;
    ctx = await boot('dsh', main, [...rows, ...activeRows], async c => {
      if (hmr) c.provide('appReady', { onReady(listener) {
        if (ready) listener(); else listeners.add(listener);
        return () => listeners.delete(listener);
      } });
      c.provide('profileContext', {
      dir, home, installAnchor: join(prefix, 'node_modules/@deepseek-ai/dsh/package.json'), patchPath,
      overlays: [], startedBundles: active ? [name] : [], telemetryDisabledEnv: '1',
    });
      if (hmr) await c.plugin(PluginPackages, { resolution });
    });
    ready = true; for (const listener of listeners) listener(); listeners.clear();
    assert(ctx.pluginManager instanceof PluginManager);
    facts.actualServiceInstance = true;
  };
  await start();
  const invoke = async (method, ...args) => {
    const result = await ctx.pluginManager[method](...args);
    facts.calls.push({ method, result });
    const descriptor = TYPERT.invocations.find(item => item.method === method);
    assert.deepEqual(descriptor.result.create().parse(JSON.parse(JSON.stringify(result))), result);
    return result;
  };
  async function snapshot(includeStore = false) {
    const result = {};
    async function walk(path, relative = '') {
      for (const file of (await readdir(path)).sort()) {
        if (!includeStore && relative === '' && file === '.plugin-manager') continue;
        const key = relative + file, full = join(path, file), stat = await lstat(full);
        if (stat.isSymbolicLink()) result[key] = { link: await readlink(full) };
        else if (stat.isDirectory()) await walk(full, key + '/');
        else result[key] = { sha256: hash(await readFile(full)) };
      }
    }
    await walk(dir);
    if (!includeStore) {
      const key = '.plugin-manager/ohos/active.json';
      try { result[key] = { sha256: hash(await readFile(join(dir, key))) }; }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    return result;
  }
  return { root, home, dir, manifestPath, facts, invoke, snapshot, registry, tarEntered,
    holdTar: version => { heldVersion = version; },
    corruptTar: version => { archives.set(version, Buffer.from('invalid tarball')); },
    get manager() { return ctx.pluginManager; }, get ctx() { return ctx; }, restartActive: () => start(true) };
}


export async function executeTool(ctx, version) {
  const batch = await ctx.tools.execute({ calls: [{ id: 'hmr-echo', name: 'ohos_installed_echo', arguments: JSON.stringify({ text: 'HMR真实工具' }) }], signal: new AbortController().signal });
  const result = batch.results[0].result;
  assert.notEqual(result.isError, true, JSON.stringify(result));
  assert.deepEqual(JSON.parse(result.content[0].text), { text: 'HMR真实工具', version });
}
