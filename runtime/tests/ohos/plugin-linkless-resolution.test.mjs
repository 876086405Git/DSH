import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, writeFile, rm, lstat, readdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, relative, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Worker } from 'node:worker_threads';
import { beginTransaction } from '../../ohos/plugins/store.mjs';
import { installPluginResolution } from '../../ohos/plugins/resolution.mjs';

installPluginResolution();
const prefix = process.env.DSH_PREFIX;
const { PluginPackages, createRuntimeResolution, loadProfileDirectory } = await import(pathToFileURL(
  join(prefix, 'node_modules/@deepseek-ai/dsh-app-boot/lib/index.js')));
const { Context } = await import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai/cordis/lib/index.js')));
const imports = {
  '#dep': 'dep-a', '#relative': './local.cjs', '#invalid-array': ['../outside.cjs', 'dep-a'],
  '#invalid-exports-array': ['bad-exports', 'dep-a'], '#missing-array': ['missing-dep', 'dep-a'],
  '#missing-relative': ['./absent.cjs', 'dep-a'], '#config-array': ['bad-config', 'dep-a'],
  '#nested': { node: { absent: 'dep-b' }, default: 'dep-a' },
  '#condition': { require: 'dep-a', import: 'dep-b' },
  '#numeric': { 1: 'dep-b', default: 'dep-a' },
  '#foo/*-long': 'dep-a', '#foo/bar*': 'dep-b', '#star/*': './star-*.cjs',
  '#external/*': 'plain/*', '#prefix/': 'dep-a/', '#slash/': 'dep-a',
  '#directory': './nested', '#other': 'dep-b', '#recursive': '#other', '#anything/*': '*',
  '#builtin': 'fs', '#builtin-url': 'node:fs', '#null': null,
};
const definitions = {
  fixture: { manifest: { exports: { import: './entry.mjs', require: './entry.cjs' }, imports }, files: {
    'entry.cjs': `module.exports = { lazy: () => require('dep-a'), run(name) {
      try { const value = require(name); return { value: name === '#builtin' ? typeof value.readFile : value }; }
      catch (error) { return { code: error.code }; }
    } };`,
    'entry.mjs': `export const lazy = () => import('dep-a'); export async function run(name) {
      try { const value = await import(name); return { value: name === '#builtin' ? typeof value.readFile : value.default }; }
      catch (error) { return { code: error.code }; }
    }`,
    'nested/package.json': '{"name":"fixture","exports":"./inner.cjs"}',
    'nested/inner.cjs': "module.exports = 'nested-self';",
    'nested/anchor.mjs': "import value from 'fixture'; export default value;",
    'local.cjs': "module.exports = 'relative';", 'star-$&.cjs': "module.exports = 'literal-dollar';",
  } },
  'dep-a': { manifest: { exports: { '.': { import: './i.mjs', require: './c.cjs' }, './hidden': null } }, files: {
    'i.mjs': "export default 'A-import';", 'c.cjs': "module.exports = 'A-require';",
  } },
  'dep-b': { files: { 'index.js': "module.exports = 'B';" } },
  'bad-exports': { manifest: { exports: '../outside.cjs' } },
  'bad-config': { manifest: { exports: { 1: './index.js', default: './index.js' } } },
  plain: { files: { 'index.js': "module.exports = 'plain';", 'sub.js': "module.exports = 'sub';" } },
};

async function writePackage(path, name, definition) {
  await mkdir(path, { recursive: true });
  const manifest = { name, version: '1.0.0', ...definition.manifest };
  await writeFile(join(path, 'package.json'), JSON.stringify(manifest));
  for (const [file, text] of Object.entries(definition.files ?? {})) {
    await mkdir(dirname(join(path, file)), { recursive: true });
    await writeFile(join(path, file), text);
  }
  return manifest;
}

async function stage(dir, values = definitions) {
  const tx = beginTransaction(dir), generation = tx.newGeneration(), nodes = [];
  for (const [id, [name, definition]] of Object.entries(values).entries()) {
    const directory = join(generation, `package-${id}`, 'node_modules', name);
    const manifest = await writePackage(directory, name, definition);
    nodes.push({ id, name, version: '1.0.0', manifest, directory: relative(generation, directory), dependencies: {}, peers: {} });
  }
  for (const node of nodes.slice(1)) nodes[0].dependencies[node.name] = { type: 'node', id: node.id };
  await writeFile(join(generation, 'lock.json'), JSON.stringify({ schema: 1, root: 0, nodes }));
  const root = join(generation, nodes[0].directory);
  tx.publish('fixture', root); tx.finish(true);
  return root;
}

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'ohos-linkless-resolution-'));
  let ctx;
  t.after(async () => { try { await ctx?.fiber.dispose(); } finally { await rm(root, { recursive: true, force: true }); } });
  const managed = join(root, 'profile'), native = join(root, 'native');
  for (const dir of [managed, native]) {
    await mkdir(dir);
    await writeFile(join(dir, 'package.json'), JSON.stringify({ name: 'profile', dependencies: { fixture: '1.0.0' },
      imports: { '#selected': 'fixture', '#relative': './local.cjs' } }));
    await writeFile(join(dir, 'local.cjs'), "module.exports = 'local';");
    await writeFile(join(dir, 'anchor.mjs'), 'export const load = name => import(name);');
  }
  const selected = await stage(managed);
  for (const [name, definition] of Object.entries(definitions)) await writePackage(join(native, 'node_modules', name), name, definition);
  const installAnchor = join(prefix, 'node_modules/@deepseek-ai/dsh/package.json');
  const resolution = await createRuntimeResolution({ installAnchor, home: root,
    profile: loadProfileDirectory('dsh', managed, installAnchor) });
  ctx = new Context();
  await ctx.plugin(PluginPackages, { resolution });
  assert(ctx.pluginPackages instanceof PluginPackages);
  return { root, managed, native, selected };
}

test('linkless CJS and ESM imports agree with native Node across conditions, arrays, patterns and errors', async t => {
  const f = await fixture(t);
  const cjs = [f.managed, f.native].map(dir => createRequire(join(dir, 'package.json'))('fixture'));
  const esm = await Promise.all([f.managed, f.native].map(async dir => (await import(pathToFileURL(join(dir, 'anchor.mjs')))).load('fixture')));
  const cases = ['#directory', '#recursive', '#anything/./local.cjs', '#anything/node:fs', '#anything/#other', '#dep', '#relative', '#invalid-array', '#invalid-exports-array', '#missing-array',
    '#missing-relative', '#config-array', '#nested', '#condition', '#numeric', '#foo/bar-long', '#star/$&',
    '#external/sub', '#external/sub.js', '#prefix/sub', '#slash/', '#builtin', '#builtin-url', '#null', '#absent', '#',
    'dep-a', 'dep-a/hidden', 'dep-a/package.json', 'plain/sub'];
  for (const request of cases) {
    assert.deepEqual(cjs[0].run(request), cjs[1].run(request), `CJS ${request}`);
    assert.deepEqual(await esm[0].run(request), await esm[1].run(request), `ESM ${request}`);
  }
  async function ordinary(path) {
    for (const name of await readdir(path)) {
      const full = join(path, name), info = await lstat(full);
      assert.equal(info.isSymbolicLink(), false, full);
      if (info.isDirectory()) await ordinary(full);
      else assert.equal(info.nlink, 1, full);
    }
  }
  await ordinary(f.managed);
});

test('old lazy CJS and ESM imports keep their generation after active publication changes', async t => {
  const f = await fixture(t), require = createRequire(join(f.managed, 'package.json'));
  const oldCjs = require('fixture'), oldEsm = await import(pathToFileURL(join(f.selected, 'entry.mjs')));
  const changed = structuredClone(definitions);
  changed['dep-a'].files = { 'i.mjs': "export default 'new-import';", 'c.cjs': "module.exports = 'new-require';" };
  const next = await stage(f.managed, changed);
  assert.equal(oldCjs.lazy(), 'A-require');
  assert.equal((await oldEsm.lazy()).default, 'A-import');
  // Node keeps previously required modules cached. Loader selects the new
  // generation through resolve(), without rewriting global require caches.
  assert.equal(require('fixture'), oldCjs);
  assert.equal(require(require.resolve('fixture')).lazy(), 'new-require');
  assert.equal((await (await import(pathToFileURL(join(next, 'entry.mjs')))).lazy()).default, 'new-import');
});

test('Worker preload reads immutable maps with custom import/require conditions and no writer', async t => {
  const f = await fixture(t);
  const entry = join(f.managed, 'worker.mjs');
  await writeFile(entry, `
    import { parentPort, workerData } from 'node:worker_threads';
    import { createRequire } from 'node:module';
    await import(workerData.preload);
    const raw = await createRequire(workerData.anchor)('fixture').lazy();
    const value = typeof raw === 'string' ? raw : raw.default;
    const esm = (await (await import('fixture')).lazy()).default;
    parentPort.postMessage({ value, esm, resolved: import.meta.resolve('fixture'), wasm: typeof WebAssembly,
      hasWriter: !!globalThis[Symbol.for('dsh.go.ohos.plugins')] });
  `);
  for (const condition of [undefined, 'require', 'import']) {
    const worker = new Worker(pathToFileURL(entry), {
      ...(condition ? { execArgv: ['--import', new URL('../../ohos/sim/preload.mjs', import.meta.url).pathname,
        '--conditions=' + condition] } : {}),
      workerData: { preload: new URL('../../ohos/plugins/preload.mjs', import.meta.url).href,
        anchor: join(f.managed, 'package.json') },
    });
    try {
      const result = await new Promise((resolve, reject) => { worker.once('message', resolve); worker.once('error', reject); });
      assert.deepEqual(result, { value: condition === 'import' ? 'A-import' : 'A-require', esm: 'A-import',
        resolved: pathToFileURL(join(f.selected, 'entry.mjs')).href, wasm: typeof WebAssembly, hasWriter: false });
    } finally { await worker.terminate(); }
  }
});


test('ordinary profile packages keep their own private dependencies and nested profiles stay separate', async t => {
  const f = await fixture(t), manual = join(f.managed, 'node_modules/manual');
  await writePackage(manual, 'manual', {});
  await writePackage(join(manual, 'node_modules/fixture'), 'fixture', { files: { 'index.js': "module.exports = 'private';" } });
  assert.equal(createRequire(join(manual, 'package.json'))('fixture'), 'private');
  const nested = join(f.managed, 'nested-profile');
  await mkdir(nested); await writeFile(join(nested, 'package.json'), '{"name":"nested"}');
  const changed = structuredClone(definitions);
  changed['dep-a'].files = { 'i.mjs': "export default 'nested-import';", 'c.cjs': "module.exports = 'nested-require';" };
  await stage(nested, changed);
  assert.equal(createRequire(join(nested, 'package.json'))('fixture').lazy(), 'nested-require');
  const client = join(nested, 'node_modules/client');
  await writePackage(client, 'client', {});
  const entry = join(f.root, 'nested-worker.mjs');
  await writeFile(entry, `
    import { parentPort, workerData } from 'node:worker_threads';
    import { createRequire } from 'node:module';
    await import(workerData.preload);
    parentPort.postMessage(workerData.anchors.map(anchor => createRequire(anchor)('fixture').lazy()));
  `);
  const worker = new Worker(pathToFileURL(entry), { workerData: {
    preload: new URL('../../ohos/plugins/preload.mjs', import.meta.url).href,
    anchors: [join(client, 'package.json'), join(f.managed, 'package.json'), join(nested, 'package.json')],
  } });
  try {
    const result = await new Promise((resolve, reject) => { worker.once('message', resolve); worker.once('error', reject); });
    assert.deepEqual(result, ['nested-require', 'A-require', 'nested-require']);
  } finally { await worker.terminate(); }
});


test('nearest nested package self-reference wins over the immutable outer dependency graph', async t => {
  const f = await fixture(t), nested = join(f.selected, 'nested');
  assert.equal(createRequire(join(nested, 'package.json'))('fixture'), 'nested-self');
  assert.equal((await import(pathToFileURL(join(nested, 'anchor.mjs')))).default, 'nested-self');
});

test('real DSH CommonJS resolver preserves explicit paths and native argument validation', async t => {
  const f = await fixture(t), external = join(f.root, 'external');
  await writePackage(join(external, 'node_modules/fixture'), 'fixture', {
    files: { 'index.js': "module.exports = 'external';" } });
  await writeFile(join(external, 'local.cjs'), "module.exports = 'external-local';");
  const variants = [undefined, {}, { paths: undefined }, { paths: [external] }, { paths: [] },
    { paths: external }, { paths: null }, { paths: 1 }, { paths: {} }, { paths: [1] },
    { paths: [null] }, { paths: [undefined] }, Object.create({ paths: [external] }), 'ignored', null];
  const require = [f.managed, f.native].map(dir => createRequire(join(dir, 'anchor.cjs')));
  const capture = callback => {
    try { return { target: callback().replaceAll(f.selected, '<selected>')
      .replaceAll(join(f.native, 'node_modules/fixture'), '<selected>')
      .replaceAll(f.managed, '<profile>').replaceAll(f.native, '<profile>') }; }
    catch (error) { return { code: error.code, name: error.name }; }
  };
  const mismatches = [];
  for (const request of ['fixture', '#selected', '#relative', './local.cjs', 'fs']) {
    for (const [variant, options] of variants.entries()) {
      const actual = capture(() => require[0].resolve(request, options));
      const native = capture(() => require[1].resolve(request, options));
      if (JSON.stringify(actual) !== JSON.stringify(native)) mismatches.push({ request, variant, actual, native });
    }
  }
  assert.deepEqual(mismatches, []);
});

test('imports keep their locked dependency when native lookup would find a physical profile shadow', async t => {
  const f = await fixture(t);
  await writePackage(join(f.managed, 'node_modules/dep-a'), 'dep-a', {
    files: { 'index.js': "module.exports = 'wrong-physical-host';" } });
  const require = createRequire(join(f.selected, 'entry.cjs'));
  for (const options of [undefined, { paths: [] }, { paths: [f.native] }]) {
    assert.equal(require(require.resolve('#dep', options)), 'A-require');
  }
});
