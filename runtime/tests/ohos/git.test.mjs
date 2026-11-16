import { symlinkFixture } from './host-link-fixture.mjs';
import assert from 'node:assert/strict';
import test, { after } from 'node:test';
import { execFileSync, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createServer } from 'node:http';
import { createHash, randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { readFile, writeFile, mkdtemp, mkdir, rm, copyFile, readdir, lstat, rename, chmod } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';
import { fixture as ownedFixture } from './git-owned-fixture.mjs';
import { createFilesystem } from '../../ohos/process/filesystem.mjs';
import { createGitFs } from '../../ohos/process/git-fs.mjs';
import { executeGit } from '../../ohos/process/git.mjs';

const require = createRequire(new URL('../../ohos/process/git.mjs', import.meta.url));
const git = require('isomorphic-git');
const nodeRequire = createRequire(join(resolve(process.env.DSH_TEST_PREFIX ?? process.cwd()), 'package.json'));
const providerPath = nodeRequire.resolve('@deepseek-ai/dsh-workspace-changes');
const source = await readFile(providerPath, 'utf8');
assert.equal(createHash('sha256').update(source).digest('hex'), '0640af53762c8b2ebbdc5c38412fcd75badfe36edef12875d8d87969415f04ed');
const providerFixture = await mkdtemp(join(tmpdir(), 'dsh-owned-git-provider-'));
await symlinkFixture(resolve(dirname(providerPath), '../../..'), join(providerFixture, 'node_modules'), 'dir');
const sibling = join(providerFixture, 'index.mjs');
after(() => rm(providerFixture, { recursive: true, force: true }));
await writeFile(sibling, source + '\nexport { locateGitWorkspace, snapshotTree, diffTrees, treeBlob, blobText, gitlinkPaths, ignoredPaths, TurnRecorder, workspaceTemporaryRoot };\n', { flag: 'wx' });
let provider;
provider = await import(pathToFileURL(sibling));

const oraclePath = new URL('./git-native-oracle.json', import.meta.url);
const record = process.env.DSH_GIT_ORACLE === 'record';
// The explicit Node-only linked test fixture must not be loaded into native git.
const nativeEnv = { ...process.env }; delete nativeEnv.LD_PRELOAD;
const oracle = record ? { gitVersion: execFileSync('git', ['--version'], { encoding: 'utf8', env: nativeEnv }).trim(), results: {} }
  : JSON.parse(await readFile(oraclePath, 'utf8'));
if (!record) assert.equal(oracle.testSHA256, createHash('sha256').update(await readFile(fileURLToPath(import.meta.url))).digest('hex'));
if (record) after(async () => {
  oracle.testSHA256 = createHash('sha256').update(await readFile(fileURLToPath(import.meta.url))).digest('hex');
  await writeFile(oraclePath, JSON.stringify(oracle, null, 2) + '\n');
});
function native(key, args, options) {
  if (record) {
    const result = execFileSync('git', args, { ...options, encoding: 'utf8',
      env: { ...nativeEnv, GIT_CONFIG_NOSYSTEM: '1', GIT_OPTIONAL_LOCKS: '0', LC_ALL: 'C', ...options.env } });
    oracle.results[key] = result;
  }
  assert(Object.hasOwn(oracle.results, key), `missing native oracle ${key}`);
  return oracle.results[key];
}
const fixedEnv = { GIT_AUTHOR_NAME: '测试作者', GIT_AUTHOR_EMAIL: 'test@example.invalid', GIT_COMMITTER_NAME: '测试作者',
  GIT_COMMITTER_EMAIL: 'test@example.invalid', GIT_AUTHOR_DATE: '1700000000 +0000', GIT_COMMITTER_DATE: '1700000000 +0000' };
async function fixture(t, fn, options = {}) {
  const f = await ownedFixture(t, options);
  const ctx = f.ctx;
  f.runner = { run: async (args, options) => {
    const result = await executeGit(args, { ...ctx, ...options, env: { ...fixedEnv, ...options.env } });
    if (result.stdoutKind === 'bytes') result.stdout = Buffer.from(result.stdout, 'latin1').toString('utf8');
    return { ...result, truncated: false };
  } };
  await fn(f);
}

async function hashes(directory) {
  const result = {};
  async function visit(path, prefix = '') {
    for (const name of (await readdir(path)).sort()) {
      const full = join(path, name), rel = prefix + name, info = await lstat(full);
      if (info.isDirectory()) await visit(full, rel + '/');
      else result[rel] = createHash('sha256').update(await readFile(full)).digest('hex');
    }
  }
  await visit(directory); return result;
}
async function nativeSnapshot(f, key, excludes = []) {
  if (!record) return native(key, [], {});
  const directory = await mkdtemp(join(f.root, 'native-'));
  const index = join(directory, 'index'), objects = join(directory, 'objects'); await mkdir(objects);
  await copyFile(join(f.dir, '.git/index'), index).catch(error => { if (error.code !== 'ENOENT') throw error; });
  const env = { GIT_INDEX_FILE: index, GIT_OBJECT_DIRECTORY: objects, GIT_ALTERNATE_OBJECT_DIRECTORIES: join(f.dir, '.git/objects') };
  execFileSync('git', ['add', '--all', '--ignore-errors', '--', '.', ...excludes.map(path => `:(exclude)${path}`)], { cwd: f.dir, env: { ...nativeEnv, ...env } });
  const tree = native(key, ['write-tree'], { cwd: f.dir, env });
  native(key + '-ls-tree', ['ls-tree', '-r', '-z', tree.trim()], { cwd: f.dir, env });
  return tree;
}
async function workspace(f) {
  const directory = await mkdtemp(join(f.scratch, 'snapshot-'));
  return provider.locateGitWorkspace(f.runner, f.dir, async () => directory, new AbortController().signal);
}
async function seed(f) {
  await f.run(['init']);
  await writeFile(join(f.dir, 'tracked.txt'), 'base\nline\n');
  await writeFile(join(f.dir, 'delete.txt'), 'removed\n');
  await writeFile(join(f.dir, 'rename.txt'), 'one\ntwo\nthree\nfour\n');
  await writeFile(join(f.dir, '原名.txt'), 'exact rename\n');
  await writeFile(join(f.dir, '.gitignore'), '*.log\n');
  await writeFile(join(f.dir, 'kept.log'), 'tracked despite ignore\n');
  await f.run(['add', '--all']); await f.run(['add', '--force', 'kept.log']); await f.run(['commit', '-m', 'fixture']);
}

test('common init/status/add/commit/log/diff/branch/checkout execute with restricted FS and Unicode paths', async t => fixture(t, async f => {
  await f.run(['init', '-b', 'main']);
  await f.run(['config', 'user.name', '用户']); await f.run(['config', 'user.email', 'user@example.invalid']);
  await writeFile(join(f.dir, '中文.txt'), 'one\ntwo\n');
  assert.equal((await f.run(['status', '--porcelain', '-z'])).stdout, '?? 中文.txt\0');
  await f.run(['add', '中文.txt']); await f.run(['commit', '-m', 'first']);
  assert.equal((await f.run(['status', '--porcelain'])).stdout, '');
  const original = (await f.run(['rev-parse', 'HEAD'])).stdout;
  await f.run(['branch', 'topic']); await f.run(['checkout', 'topic']);
  await writeFile(join(f.dir, '中文.txt'), 'one\nthree\n');
  assert.equal((await f.run(['diff', '--numstat', '-z'])).stdout,
    native('common-diff', ['diff', '--numstat', '-z'], { cwd: f.dir }));
  assert.equal((await f.run(['status', '--porcelain', '-z'])).stdout,
    native('common-status', ['status', '--porcelain', '-z'], { cwd: f.dir }));
  await f.run(['add', '--all']); await f.run(['commit', '-m', 'second']);
  assert.match((await f.run(['log', '--oneline', '-n', '2'])).stdout, /second\n[0-9a-f]{7} first\n$/);
  await f.run(['checkout', 'main']); assert.equal(await readFile(join(f.dir, '中文.txt'), 'utf8'), 'one\ntwo\n');
  assert.equal((await f.run(['rev-parse', 'HEAD'])).stdout, original);
  assert.equal((await executeGit(['add', '*.missing'], f.ctx)).exitCode, 127);
  assert.equal((await executeGit(['add', 'missing-file'], f.ctx)).exitCode, 128);
  await writeFile(join(f.dir, '.gitignore'), 'ignored.txt\n'); await writeFile(join(f.dir, 'ignored.txt'), 'ignored\n');
  assert.equal((await executeGit(['add', 'ignored.txt'], f.ctx)).exitCode, 1);
}));

test('real provider snapshots match native tree OIDs and numstat, preserve all user .git bytes', async t => fixture(t, async f => {
  await seed(f);
  await writeFile(join(f.dir, 'tracked.txt'), 'staged\n'); await f.run(['add', 'tracked.txt']);
  await writeFile(join(f.dir, 'tracked.txt'), 'working\nline\n');
  await writeFile(join(f.dir, 'ignored.log'), 'ignored\n');
  const untouched = await hashes(join(f.dir, '.git')), ws = await workspace(f), signal = new AbortController().signal;
  const before = await provider.snapshotTree(f.runner, ws, signal);
  assert.equal(before + '\n', await nativeSnapshot(f, 'snapshot-before'));
  await writeFile(join(f.dir, 'tracked.txt'), 'working\nchanged\nnew\n');
  await rm(join(f.dir, 'delete.txt'));
  await rename(join(f.dir, 'rename.txt'), join(f.dir, 'renamed.txt'));
  await writeFile(join(f.dir, 'renamed.txt'), 'one\ntwo\nthree\nchanged\n');
  await rename(join(f.dir, '原名.txt'), join(f.dir, '新名.txt'));
  await writeFile(join(f.dir, '中文\t含制表\n换行.txt'), 'added\n');
  await writeFile(join(f.dir, 'new.bin'), Buffer.from([1, 0, 255, 2]));
  await writeFile(join(f.dir, 'kept.log'), 'tracked still\n');
  await chmod(join(f.dir, 'tracked.txt'), 0o755);
  await symlinkFixture('tracked.txt', join(f.dir, 'link'));
  const after = await provider.snapshotTree(f.runner, ws, signal);
  const expectedAfter = await nativeSnapshot(f, 'snapshot-after');
  assert.equal((await f.runner.run(['ls-tree', '-r', '-z', after], { cwd: f.dir, env: ws.env, signal })).stdout,
    oracle.results['snapshot-after-ls-tree']);
  assert.equal(after + '\n', expectedAfter);
  const result = await f.runner.run(['diff-tree', '-r', '-M', '-z', '--numstat', before, after], { cwd: f.dir, env: ws.env, signal });
  assert.equal(result.exitCode, 0, result.stderr);
  assert.equal(result.stdout, native('snapshot-numstat', ['diff-tree', '-r', '-M', '-z', '--numstat', before, after], { cwd: f.dir, env: ws.env }));
  const entries = await provider.diffTrees(f.runner, ws, before, after, signal);
  assert(entries.some(entry => entry.oldPath === '原名.txt' && entry.path === '新名.txt'));
  assert(entries.some(entry => entry.oldPath === 'rename.txt' && entry.path === 'renamed.txt'));
  assert(entries.some(entry => entry.path === 'new.bin' && entry.binary));
  assert(entries.some(entry => entry.path === '中文\t含制表\n换行.txt'));
  assert(!entries.some(entry => entry.path === 'ignored.log'));
  const blob = await provider.treeBlob(f.runner, ws, after, '中文\t含制表\n换行.txt', signal);
  assert.equal(blob.size, 6);
  assert.equal(await provider.blobText(f.runner, ws, blob.oid, 6, signal), 'added\n');
  assert.deepEqual(await provider.ignoredPaths(f.runner, ws, ['ignored.log', 'kept.log', 'tracked.txt'], signal), new Set(['ignored.log']));
  assert.deepEqual(await hashes(join(f.dir, '.git')), untouched);
}));

function mergeIndex(entries) {
  const header = Buffer.alloc(12); header.write('DIRC'); header.writeUInt32BE(2, 4); header.writeUInt32BE(entries.length, 8);
  const body = entries.map(({ path, oid, stage }) => {
    const name = Buffer.from(path), record = Buffer.alloc(Math.ceil((62 + name.length + 1) / 8) * 8);
    record.writeUInt32BE(0o100644, 24); Buffer.from(oid, 'hex').copy(record, 40);
    record.writeUInt16BE((stage << 12) | name.length, 60); name.copy(record, 62); return record;
  });
  const bytes = Buffer.concat([header, ...body]); return Buffer.concat([bytes, createHash('sha1').update(bytes).digest()]);
}
test('real unmerged index stages survive private snapshot staging byte-for-byte', async t => fixture(t, async f => {
  await f.run(['init']);
  const entries = [];
  for (let stage = 1; stage <= 3; ++stage) entries.push({ path: 'conflict.txt', stage,
    oid: await git.writeBlob({ fs: createGitFs(f.ctx, { gitdir: join(f.dir, '.git') }), dir: f.dir, blob: Buffer.from(`stage-${stage}\n`) }) });
  await writeFile(join(f.dir, '.git/index'), mergeIndex(entries));
  await writeFile(join(f.dir, 'conflict.txt'), 'resolved worktree bytes\n');
  const original = await hashes(join(f.dir, '.git'));
  assert.equal((await f.run(['ls-files', '-z', '--stage'])).stdout,
    native('unmerged-ls-stage', ['ls-files', '-z', '--stage'], { cwd: f.dir }));
  assert.equal((await f.run(['status', '--porcelain', '-z'])).stdout,
    native('unmerged-status', ['status', '--porcelain', '-z'], { cwd: f.dir }));
  const ws = await workspace(f), tree = await provider.snapshotTree(f.runner, ws, new AbortController().signal);
  assert.equal(tree + '\n', await nativeSnapshot(f, 'unmerged-snapshot'));
  assert.deepEqual(await hashes(join(f.dir, '.git')), original);
}));

test('private snapshot directory inside workspace excludes its own captures and objects', async t => fixture(t, async f => {
  await seed(f);
  const ws = await workspace(f), signal = new AbortController().signal;
  const before = await provider.snapshotTree(f.runner, ws, signal);
  assert.equal(before + '\n', await nativeSnapshot(f, 'inside-snapshot', ws.excludes));
  const second = await provider.snapshotTree(f.runner, ws, signal);
  assert.equal(before, second);
}, { inside: true }));

test('tracked gitlinks are listed as 160000 and nested worktrees are not traversed', async t => fixture(t, async f => {
  await f.run(['init']); const sub = join(f.dir, 'sub'); await mkdir(sub);
  await f.run(['init'], { cwd: sub }); await writeFile(join(sub, 'sub.txt'), 'nested\n');
  await f.run(['add', '--all'], { cwd: sub }); await f.run(['commit', '-m', 'nested'], { cwd: sub });
  await f.run(['add', '--all']); await f.run(['commit', '-m', 'gitlink']);
  const ws = await workspace(f), signal = new AbortController().signal;
  assert.deepEqual(await provider.gitlinkPaths(f.runner, ws, signal), new Set(['sub']));
  const before = await provider.snapshotTree(f.runner, ws, signal);
  await writeFile(join(sub, 'sub.txt'), 'uncommitted nested change\n');
  const after = await provider.snapshotTree(f.runner, ws, signal);
  assert.equal(before, after);
  assert.equal(after + '\n', await nativeSnapshot(f, 'gitlink-snapshot'));
}));

test('real TurnRecorder reports an external edit without file-tool capture fallback', async t => fixture(t, async f => {
  await seed(f); const original = await hashes(join(f.dir, '.git')), events = [], warnings = [];
  const session = { append(type, data) { const event = { type, data, seq: events.length + 20 }; events.push(event); return event; } };
  const recorder = new provider.TurnRecorder(session, f.dir, { git: Promise.resolve(f.runner), tempRoot: f.scratch,
    maxFiles: 100, maxFileBytes: 2 * 1024 * 1024, diffTimeoutMs: 100, warn: message => warnings.push(message) });
  try {
    recorder.start(1); await recorder.settled();
    assert(recorder.state.baseline?.tree, JSON.stringify(warnings));
    await writeFile(join(f.dir, '仅快照可见.txt'), 'external edit\n');
    recorder.observe({ data: { turn: 1 }, seq: 10 }); await recorder.stopping(1);
    assert.equal(warnings.length, 0, warnings.join('\n'));
    const event = events.find(event => event.type === 'workspace/changes'); assert(event);
    const summary = recorder.summary(event.seq); assert(summary.snapshot);
    const index = summary.files.findIndex(file => file.path === '仅快照可见.txt'); assert(index >= 0);
    const diff = await recorder.diff(event.seq, index, new AbortController().signal);
    assert.equal(diff.kind, 'text'); assert(diff.hunks.some(hunk => hunk.lines.includes('+external edit')));
    assert.deepEqual(await hashes(join(f.dir, '.git')), original);
  } finally { await recorder.dispose(); }
}));

test('GIT env paths never grant extra roots; symlink escape and read-only policy remain denied', async t => fixture(t, async f => {
  await seed(f);
  const neighbor = join(f.root, 'neighbor'); await mkdir(neighbor); await writeFile(join(neighbor, 'index'), 'sentinel');
  let result = await executeGit(['add', '--all'], { ...f.ctx, env: { GIT_INDEX_FILE: join(neighbor, 'index') } });
  assert.equal(result.exitCode, 128); assert.match(result.stderr, /EACCES/);
  assert.equal(await readFile(join(neighbor, 'index'), 'utf8'), 'sentinel');
  await symlinkFixture(neighbor, join(f.dir, 'escape'));
  result = await executeGit(['init', 'escape/repo'], f.ctx);
  assert.notEqual(result.exitCode, 0);
  const readOnly = createFilesystem([f.dir, f.scratch], { mode: 'read-only' }); readOnly.seal();
  result = await executeGit(['add', '--all'], { ...f.ctx, fs: readOnly.fs, ownedGit: f.makeOwner({ policy: { mode: 'read-only' } }) });
  assert.equal(result.exitCode, 128); assert.match(result.stderr, /OHOS_SANDBOX_DENIED/);
}));

test('cancellation during add cannot publish a partly staged user index', async t => fixture(t, async f => {
  await seed(f); const original = await readFile(join(f.dir, '.git/index'));
  await writeFile(join(f.dir, 'tracked.txt'), 'changed\n');
  const controller = new AbortController(); let writes = 0;
  // Cooperative cancellation after one actual parent fd rewrite. The separate
  // Worker.terminate integration retains the hard-cancellation assertion.
  const ownedGit = { ...f.ctx.ownedGit, async writeIndex(...args) {
    const result = await f.ctx.ownedGit.writeIndex(...args);
    if (++writes === 1) controller.abort(new Error('cancelled fixture'));
    return result;
  } };
  await assert.rejects(executeGit(['add', '--all'], { ...f.ctx, ownedGit, signal: controller.signal }), /cancelled fixture/);
  assert.equal(writes, 1);
  assert.deepEqual(await readFile(join(f.dir, '.git/index')), original);
}));

test('workspace temporaryRoot is gated; missing OHOS private root fails explicitly', () => {
  const platform = Object.getOwnPropertyDescriptor(process, 'platform'), sim = process.env.DSH_GO_OHOS_SIM;
  const key = Symbol.for('dsh.go.ohos.sim'), marker = Object.getOwnPropertyDescriptor(globalThis, key);
  try {
    delete globalThis[key];
    process.env.DSH_GO_OHOS_SIM = '1';
    for (const target of ['linux', 'android']) {
      Object.defineProperty(process, 'platform', { ...platform, value: target });
      assert.equal(typeof provider.workspaceTemporaryRoot({ subprocess: {} }), 'string');
    }
    Object.defineProperty(process, 'platform', { ...platform, value: 'openharmony' });
    assert.throws(() => provider.workspaceTemporaryRoot({ subprocess: {} }), /private temporaryRoot/);
    assert.equal(provider.workspaceTemporaryRoot({ subprocess: { temporaryRoot: '/private/granted' } }), '/private/granted');
  } finally {
    Object.defineProperty(process, 'platform', platform);
    if (marker) Object.defineProperty(globalThis, key, marker); else delete globalThis[key];
    if (sim === undefined) delete process.env.DSH_GO_OHOS_SIM; else process.env.DSH_GO_OHOS_SIM = sim;
  }
});

async function allOids(dir) {
  const root = join(dir, '.git/objects'), result = [];
  for (const prefix of await readdir(root)) if (/^[a-f0-9]{2}$/.test(prefix))
    for (const suffix of await readdir(join(root, prefix))) if (/^[a-f0-9]{38}$/.test(suffix)) result.push(prefix + suffix);
  return result.sort();
}
test('private store reads original packed objects without writing original packs/index/refs', async t => fixture(t, async f => {
  await seed(f);
  const options = { fs: createGitFs(f.ctx, { gitdir: join(f.dir, '.git') }), dir: f.dir }, oids = await allOids(f.dir);
  const { filename } = await git.packObjects({ ...options, oids, write: true });
  await git.indexPack({ ...options, filepath: `.git/objects/pack/${filename}` });
  for (const prefix of new Set(oids.map(oid => oid.slice(0, 2)))) await rm(join(f.dir, '.git/objects', prefix), { recursive: true });
  const original = await hashes(join(f.dir, '.git')), ws = await workspace(f), signal = new AbortController().signal;
  const before = await provider.snapshotTree(f.runner, ws, signal);
  await writeFile(join(f.dir, 'tracked.txt'), 'packed base + new private blob\n');
  const after = await provider.snapshotTree(f.runner, ws, signal);
  assert.equal(after + '\n', await nativeSnapshot(f, 'packed-snapshot'));
  const diff = await provider.diffTrees(f.runner, ws, before, after, signal);
  assert.equal(diff.length, 1); assert.equal(diff[0].path, 'tracked.txt');
  assert.deepEqual(await hashes(join(f.dir, '.git')), original);
}));

test('filemode and symlinks config preserve Git index mode semantics', async t => fixture(t, async f => {
  await seed(f); await f.run(['config', 'core.filemode', 'true']);
  await chmod(join(f.dir, 'tracked.txt'), 0o755);
  assert.equal((await f.run(['status', '--porcelain', '-z'])).stdout,
    native('mode-status-work', ['status', '--porcelain', '-z'], { cwd: f.dir }));
  await f.run(['add', 'tracked.txt']);
  assert.equal((await f.run(['status', '--porcelain', '-z'])).stdout,
    native('mode-status-index', ['status', '--porcelain', '-z'], { cwd: f.dir }));
  await symlinkFixture('tracked.txt', join(f.dir, 'link')); await f.run(['add', 'link']); await f.run(['commit', '-m', 'mode and link']);
  await rm(join(f.dir, 'link')); await writeFile(join(f.dir, 'link'), 'tracked.txt');
  const ws = await workspace(f), tree = await provider.snapshotTree(f.runner, ws, new AbortController().signal);
  assert.equal(tree + '\n', await nativeSnapshot(f, 'symlinks-false-snapshot'));
  await writeFile(join(f.dir, 'tracked.txt'), 'restore this\n');
  await f.run(['checkout', '--', 'tracked.txt']); assert.equal(await readFile(join(f.dir, 'tracked.txt'), 'utf8'), 'base\nline\n');
}));

test('HTTP clone uses the reviewed O5 transport and produces the native Git commit/worktree', async t => fixture(t, async f => {
  await seed(f);
  const head = (await f.run(['rev-parse', 'HEAD'])).stdout.trim();
  const { packfile } = await git.packObjects({ fs: createGitFs(f.ctx, { gitdir: join(f.dir, '.git') }), dir: f.dir, oids: await allOids(f.dir) });
  const pkt = value => { const bytes = Buffer.from(value); return Buffer.concat([Buffer.from((bytes.length + 4).toString(16).padStart(4, '0')), bytes]); };
  const calls = [];
  const server = createServer(async (request, response) => {
    calls.push(request.method + ' ' + new URL(request.url, 'http://fixture').pathname);
    for await (const _chunk of request) { /* consume negotiation bytes */ }
    if (request.url === '/repo/info/refs?service=git-upload-pack') {
      response.writeHead(200, { 'content-type': 'application/x-git-upload-pack-advertisement' });
      response.end(Buffer.concat([pkt('# service=git-upload-pack\n'), Buffer.from('0000'),
        pkt(`${head} HEAD\0multi_ack_detailed side-band-64k ofs-delta symref=HEAD:refs/heads/main\n`),
        pkt(`${head} refs/heads/main\n`), Buffer.from('0000')]));
    } else if (request.url === '/repo/git-upload-pack') {
      response.writeHead(200, { 'content-type': 'application/x-git-upload-pack-result' });
      response.end(Buffer.concat([pkt('NAK\n'), pkt(Buffer.concat([Buffer.from([1]), Buffer.from(packfile)])), Buffer.from('0000')]));
    } else { response.writeHead(404); response.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const net = process.env.DSH_OHOS_NET_ROOT ? pathToFileURL(resolve(process.env.DSH_OHOS_NET_ROOT) + '/') : new URL('../../ohos/net/', import.meta.url);
  const { createFetch } = await import(new URL('fetch.mjs', net));
  const { createHttpDispatcher } = await import(new URL('dispatcher.mjs', net));
  const dispatcher = createHttpDispatcher({ proxyEnv: {} }), fetch = createFetch(dispatcher);
  const url = `http://127.0.0.1:${server.address().port}/repo`;
  try {
    if (record) {
      const target = join(f.root, 'native-clone');
      await promisify(execFile)('git', ['clone', url, target], { env: { ...nativeEnv, GIT_CONFIG_NOSYSTEM: '1' } });
      native('clone-head', ['rev-parse', 'HEAD'], { cwd: target });
    }
    const result = await executeGit(['clone', url, join(f.scratch, 'clone')], { ...f.ctx, fetch });
    assert.equal(result.exitCode, 0, result.stderr);
    assert.equal((await f.run(['rev-parse', 'HEAD'], { cwd: join(f.scratch, 'clone') })).stdout, oracle.results['clone-head']);
    assert.equal(await readFile(join(f.scratch, 'clone/tracked.txt'), 'utf8'), 'base\nline\n');
    assert(calls.includes('GET /repo/info/refs')); assert(calls.includes('POST /repo/git-upload-pack'));
  } finally {
    await dispatcher.destroy?.(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
  }
}));
