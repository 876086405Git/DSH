import { symlinkFixture } from './host-link-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm, readdir, lstat, rename } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { createHash, randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { createServer } from 'node:http';
import * as nodeFs from 'node:fs';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';
import { installPublication } from '../../ohos/publication/index.mjs';
import { createOwnedGitServer } from '../../ohos/process/owned-server.mjs';
await installPublication();

const require = createRequire(join(resolve(process.env.OHOS_TEST_GIT_PREFIX), 'package.json'));
const dependency = createRequire(new URL('../../ohos/process/package.json', import.meta.url));
const isomorphicGit = dependency('isomorphic-git');
const providerPath = require.resolve('@deepseek-ai/dsh-workspace-changes');
const providerSource = await readFile(providerPath, 'utf8');
assert.equal(createHash('sha256').update(providerSource).digest('hex'), '0640af53762c8b2ebbdc5c38412fcd75badfe36edef12875d8d87969415f04ed');
const instrumented = join(dirname(providerPath), `.ohos-worker-test-${randomUUID()}.mjs`);
await writeFile(instrumented, providerSource + '\nexport { GitRunner, TurnRecorder, workspaceTemporaryRoot };\n', { flag: 'wx' });
let provider;
try { provider = await import(pathToFileURL(instrumented)); } finally { await rm(instrumented); }
const author = { GIT_AUTHOR_NAME: '测试作者', GIT_AUTHOR_EMAIL: 'test@example.invalid', GIT_COMMITTER_NAME: '测试作者',
  GIT_COMMITTER_EMAIL: 'test@example.invalid', GIT_AUTHOR_DATE: '1700000000 +0000', GIT_COMMITTER_DATE: '1700000000 +0000' };

async function fixture(fn) {
  const root = await mkdtemp(join(tmpdir(), 'ohos-git-worker-'));
  const work = join(root, '工作区'), temp = join(root, '私有临时'), outside = join(root, '外部');
  await Promise.all([work, temp, outside].map(path => mkdir(path)));
  const hooks = {}, resources = [], servers = new Map();
  let sequence = 0;
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot: temp }, {
    createOwnedGitServer(options) {
      const job = ++sequence;
      const server = createOwnedGitServer({ ...options, async onStage(phase, row) {
        resources.push({ job, phase, ...row });
        await hooks.stage?.(phase, row, job);
      } });
      servers.set(job, server);
      return { handle: server.handle, stop: server.stop, finish(options) {
        hooks.finish?.(job);
        return server.finish(options);
      } };
    },
  });
  const spec = { cwd: work, graceMs: 200, stdio: { stdin: 'ignore', stdout: { maxBytes: 2 * 1024 * 1024 }, stderr: { maxBytes: 65536 } }, env: author };
  const run = async (argv, options = {}) => {
    const handle = runtime.spawn({ ...spec, ...options, argv });
    const outcome = await handle.done;
    return { ...outcome, stdout: handle.collected.stdout.readFrom(0).text, stderr: handle.collected.stderr.readFrom(0).text };
  };
  const git = async (args, options) => { const result = await run(['git', ...args], options); assert.equal(result.exitCode, 0, result.stderr); return result; };
  const records = async () => JSON.parse(await readFile(join(process.env.DSH_HOME, 'ohos-ownership/ledger.json'), 'utf8')).entries;
  try { await fn({ root, work, temp, outside, runtime, spec, run, git, hooks, resources, servers, records }); }
  finally { await runtime.dispose(); await rm(root, { recursive: true, force: true }); }
}
async function hashes(path) {
  const result = {};
  async function visit(directory, prefix = '') {
    for (const name of (await readdir(directory)).sort()) {
      const full = join(directory, name), entry = prefix + name;
      if ((await lstat(full)).isDirectory()) await visit(full, entry + '/');
      else result[entry] = createHash('sha256').update(await readFile(full)).digest('hex');
    }
  }
  await visit(path); return result;
}
async function seed(f) {
  await f.git(['init']);
  await writeFile(join(f.work, '中文.txt'), '第一行\nsecond\n');
  await f.git(['add', '--all']);
  await f.git(['commit', '-m', '初始提交']);
}

test('真实worker的direct git与bash git共享注册，保留中文与NUL字节', async () => fixture(async f => {
  assert.equal(await f.runtime.resolveExecutable('git'), '/dsh-go/ohos/bin/git');
  assert.ok(f.runtime.capabilities.commands.includes('git'));
  await seed(f);
  const log = await f.run(['bash', '-c', 'git log --oneline -1']);
  assert.equal(log.exitCode, 0, log.stderr); assert.match(log.stdout, /初始提交/);
  await writeFile(join(f.work, '新增.txt'), 'new\n');
  const status = await f.git(['status', '--porcelain', '-z']);
  assert.equal(status.stdout, '?? 新增.txt\0');
  const listing = await f.git(['ls-tree', '-r', '-z', 'HEAD']);
  assert.match(listing.stdout, /\t中文\.txt\0$/);
  const oid = listing.stdout.split(' ')[2].split('\t')[0];
  assert.equal((await f.git(['cat-file', 'blob', oid])).stdout, '第一行\nsecond\n');
}));

test('真实GitRunner与TurnRecorder经subprocess/worker完成快照，无file-tool fallback', async () => fixture(async f => {
  await seed(f);
  const original = await hashes(join(f.work, '.git'));
  const executable = await f.runtime.resolveExecutable('git');
  const runner = new provider.GitRunner(f.runtime, executable, { timeoutMs: 30000, outputMaxBytes: 2 * 1024 * 1024 });
  const events = [], warnings = [];
  const session = { append(type, data) { const event = { type, data, seq: events.length + 20 }; events.push(event); return event; } };
  const recorder = new provider.TurnRecorder(session, f.work, { git: Promise.resolve(runner), tempRoot: provider.workspaceTemporaryRoot({ subprocess: f.runtime }),
    maxFiles: 100, maxFileBytes: 2 * 1024 * 1024, diffTimeoutMs: 100, warn: message => warnings.push(message) });
  try {
    recorder.start(1); await recorder.settled();
    assert(recorder.state.baseline?.tree, JSON.stringify(warnings));
    await writeFile(join(f.work, '仅快照可见.txt'), 'external edit\n');
    recorder.observe({ data: { turn: 1 }, seq: 10 }); await recorder.stopping(1);
    assert.deepEqual(warnings, []);
    const event = events.find(event => event.type === 'workspace/changes'); assert(event);
    const summary = recorder.summary(event.seq); assert(summary.snapshot);
    const index = summary.files.findIndex(file => file.path === '仅快照可见.txt'); assert(index >= 0);
    const diff = await recorder.diff(event.seq, index, new AbortController().signal);
    assert.equal(diff.kind, 'text'); assert(diff.hunks.some(hunk => hunk.lines.includes('+external edit')));
    assert.deepEqual(await hashes(join(f.work, '.git')), original);
  } finally { await recorder.dispose(); }
  assert.equal(f.runtime.live.size, 0);
  assert.deepEqual(await readdir(f.temp), []);
}));

test('实际git worker拒绝只读写入和env索引越界，不能借授权模式扩大根', async () => fixture(async f => {
  await seed(f);
  await writeFile(join(f.work, '中文.txt'), 'changed\n');
  const before = await readFile(join(f.work, '.git/index'));
  const confined = f.runtime.prepare(['git', 'add', '--all'], { mode: 'read-only', workspaceRoot: f.work });
  const denied = await f.run(confined);
  assert.equal(denied.exitCode, 128, denied.stderr); assert.match(denied.stderr, /OHOS_SANDBOX_DENIED/);
  assert.deepEqual(await readFile(join(f.work, '.git/index')), before);
  const external = join(f.outside, 'index'); await writeFile(external, 'unchanged');
  const escaped = await f.run(['git', 'add', '--all'], { env: { ...author, GIT_INDEX_FILE: external } });
  assert.equal(escaped.exitCode, 128, escaped.stderr);
  assert.equal(await readFile(external, 'utf8'), 'unchanged');
}));

test('HTTP clone在worker显式走O5传输，jitless/无WASM下读取真实Git pack', async () => fixture(async f => {
  await seed(f);
  const head = (await f.git(['rev-parse', 'HEAD'])).stdout.trim(), oids = [];
  for (const prefix of await readdir(join(f.work, '.git/objects'))) if (/^[a-f0-9]{2}$/.test(prefix))
    for (const suffix of await readdir(join(f.work, '.git/objects', prefix))) if (/^[a-f0-9]{38}$/.test(suffix)) oids.push(prefix + suffix);
  const { packfile } = await isomorphicGit.packObjects({ fs: nodeFs, dir: f.work, oids });
  const packet = content => { const bytes = Buffer.from(content); return Buffer.concat([Buffer.from((bytes.length + 4).toString(16).padStart(4, '0')), bytes]); };
  const calls = [];
  const server = createServer(async (request, response) => {
    calls.push(request.method + ' ' + new URL(request.url, 'http://fixture').pathname);
    for await (const _ of request) { /* consume negotiation */ }
    if (request.url === '/repo/info/refs?service=git-upload-pack') {
      response.writeHead(200, { 'content-type': 'application/x-git-upload-pack-advertisement' });
      response.end(Buffer.concat([packet('# service=git-upload-pack\n'), Buffer.from('0000'),
        packet(`${head} HEAD\0multi_ack_detailed side-band-64k ofs-delta symref=HEAD:refs/heads/main\n`),
        packet(`${head} refs/heads/main\n`), Buffer.from('0000')]));
    } else if (request.url === '/repo/git-upload-pack') {
      response.writeHead(200, { 'content-type': 'application/x-git-upload-pack-result' });
      response.end(Buffer.concat([packet('NAK\n'), packet(Buffer.concat([Buffer.from([1]), Buffer.from(packfile)])), Buffer.from('0000')]));
    } else { response.writeHead(404); response.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const target = join(f.temp, 'clone');
  try {
    await f.git(['clone', `http://127.0.0.1:${server.address().port}/repo`, target]);
    assert.equal((await f.git(['rev-parse', 'HEAD'], { cwd: target })).stdout.trim(), head);
    assert.equal(await readFile(join(target, '中文.txt'), 'utf8'), '第一行\nsecond\n');
    assert.deepEqual(calls, ['GET /repo/info/refs', 'POST /repo/git-upload-pack']);
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}));

test('实际worker取消正在写入的git add后，用户index保持原字节且不留本job临时文件', async t => fixture(async f => {
  await seed(f);
  const original = await readFile(join(f.work, '.git/index'));
  await writeFile(join(f.work, 'large.txt'), Buffer.alloc(16 * 1024 * 1024, 97));
  const handle = f.runtime.spawn({ ...f.spec, argv: ['git', 'add', '--all'] });
  let outcome, temporary;
  const observed = new Map();
  handle.done.then(value => { outcome = value; });
  const deadline = Date.now() + 15000;
  while (!temporary) {
    for (const row of await f.records()) observed.set(row.token, row);
    const row = [...observed.values()].find(row => row.finalPath === join(f.work, '.git/index') && row.state === 'identified');
    if (row && await lstat(row.path).then(info => info.size >= 32, error => {
      if (error.code !== 'ENOENT') throw error;
      return false;
    })) temporary = row.path;
    if (!temporary) {
      assert.equal(outcome, undefined, 'git add completed before the transaction gate');
      assert(Date.now() < deadline, 'git add did not reach its temporary-index gate');
      await new Promise(resolve => setTimeout(resolve, 10));
    }
  }
  handle.terminate();
  assert.equal((await handle.done).signal, 'SIGTERM');
  assert.equal(await handle.waitForExit(), true);
  assert.deepEqual(await readFile(join(f.work, '.git/index')), original);
  await new Promise(resolve => setTimeout(resolve, 100));
  assert.deepEqual(await readFile(join(f.work, '.git/index')), original);
  const leftovers = (await readdir(join(f.work, '.git'))).filter(path => path.startsWith('.dsh-git-index-'));
  t.diagnostic(`hard-termination temporary index files: ${leftovers.length}`);
  assert.equal(leftovers.length, 0, 'worker hard termination must not leave this job temporary index');
  assert(observed.size > 0, 'the gate must observe actual persistent resource records');
  for (const row of observed.values()) await assert.rejects(lstat(row.path), { code: 'ENOENT' });
  const remaining = await f.records();
  assert.deepEqual(remaining.filter(row => observed.has(row.token)), []);
  t.diagnostic(JSON.stringify({ observedReservations: observed.size, targetIndexUnchanged: true,
    remainingOwnedPaths: 0, remainingTokens: 0 }));
}));

for (const stage of ['reserved', 'created', 'identified', 'before-write', 'after-write', 'before-commit', 'after-commit']) {
  test(`真实 git Worker 在 ${stage} 硬终止后，父 I/O 收束与队列放行按序完成`, { timeout: 20000 }, async t => fixture(async f => {
    await seed(f);
    await writeFile(join(f.work, '中文.txt'), 'changed index entry\n');
    const index = join(f.work, '.git/index'), original = await readFile(index);
    const foreign = join(f.work, '.git/.dsh-ohos-git-foreign.tmp');
    await writeFile(foreign, 'user-owned-foreign');
    const entered = Promise.withResolvers(), resume = Promise.withResolvers(), exiting = Promise.withResolvers();
    t.signal.addEventListener('abort', () => resume.resolve(), { once: true });
    let gated = false, job, committed;
    f.hooks.stage = async (phase, row, currentJob) => {
      if (!gated && phase === stage && row.target === index) {
        gated = true; job = currentJob;
        if (stage === 'after-commit') committed = await readFile(index);
        entered.resolve(); await resume.promise;
      }
    };
    f.hooks.finish = currentJob => { if (currentJob === job) exiting.resolve(); };
    const handle = f.runtime.spawn({ ...f.spec, argv: ['git', 'add', '--all'] });
    let settled = false;
    handle.done.then(() => { settled = true; });
    const next = f.runtime.spawn({ ...f.spec, argv: ['bash', '-c', 'printf next > successor'] });
    try {
      await entered.promise;
      handle.terminate();
      await exiting.promise; // Runtime invokes parent finish only after real Worker exit.
      assert.equal(settled, false, 'parent I/O remains held after Worker exit');
      await assert.rejects(lstat(join(f.work, 'successor')), { code: 'ENOENT' });
    } finally { resume.resolve(); }
    assert.equal((await handle.done).signal, 'SIGTERM');
    assert.equal(await handle.waitForExit(), true);
    assert.equal((await next.done).exitCode, 0);
    assert.equal(await readFile(join(f.work, 'successor'), 'utf8'), 'next');
    assert.deepEqual(await readFile(index), committed ?? original);
    if (committed) assert.notDeepEqual(committed, original);
    assert.equal(await readFile(foreign, 'utf8'), 'user-owned-foreign');
    const reserved = f.resources.filter(row => row.job === job && row.phase === 'reserved');
    assert(reserved.length > 0);
    const tokens = new Set(reserved.map(row => row.token));
    for (const row of reserved) await assert.rejects(lstat(row.path), { code: 'ENOENT' });
    assert.deepEqual((await f.records()).filter(row => tokens.has(row.token)), []);
    assert.equal(f.servers.get(job).pendingCount, 0);
    assert.equal(f.servers.get(job).resourceCount, 0);
    t.diagnostic(JSON.stringify({ stage, ownedReservations: reserved.length, committedFinalRetained: Boolean(committed),
      foreignPreserved: true, queueReleasedAfterCleanup: true }));
  }));
}

async function served(f, fn) {
  await seed(f);
  const head = (await f.git(['rev-parse', 'HEAD'])).stdout.trim(), oids = [];
  for (const prefix of await readdir(join(f.work, '.git/objects'))) if (/^[a-f0-9]{2}$/.test(prefix))
    for (const suffix of await readdir(join(f.work, '.git/objects', prefix))) if (/^[a-f0-9]{38}$/.test(suffix)) oids.push(prefix + suffix);
  const { packfile } = await isomorphicGit.packObjects({ fs: nodeFs, dir: f.work, oids });
  const packet = content => { const bytes = Buffer.from(content); return Buffer.concat([Buffer.from((bytes.length + 4).toString(16).padStart(4, '0')), bytes]); };
  const calls = [];
  let interceptor;
  const server = createServer(async (request, response) => {
    calls.push(request.method + ' ' + new URL(request.url, 'http://fixture').pathname);
    for await (const _ of request) { /* consume negotiation */ }
    if (await interceptor?.(request, response)) return;
    if (request.url === '/repo/info/refs?service=git-upload-pack') {
      response.writeHead(200, { 'content-type': 'application/x-git-upload-pack-advertisement' });
      response.end(Buffer.concat([packet('# service=git-upload-pack\n'), Buffer.from('0000'),
        packet(`${head} HEAD\0multi_ack_detailed side-band-64k ofs-delta symref=HEAD:refs/heads/main\n`),
        packet(`${head} refs/heads/main\n`), Buffer.from('0000')]));
    } else if (request.url === '/repo/git-upload-pack') {
      response.writeHead(200, { 'content-type': 'application/x-git-upload-pack-result' });
      response.end(Buffer.concat([packet('NAK\n'), packet(Buffer.concat([Buffer.from([1]), Buffer.from(packfile)])), Buffer.from('0000')]));
    } else { response.writeHead(404); response.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const target = join(f.temp, 'clone'), url = `http://127.0.0.1:${server.address().port}/repo`;
  try { await fn({target, url, head, calls, intercept: value => { interceptor = value; }}); }
  finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}

for (const existing of [false, true]) for (const cancel of ['terminate', 'timeout', 'transport-error']) {
  test(`clone ${cancel} 收束后同目标重试成功 existing=${existing}`, {timeout: 20000}, async () => fixture(async f => served(f, async s => {
    let identity;
    if (existing) { await mkdir(s.target, {mode: 0o700}); identity = await lstat(s.target); }
    const entered = Promise.withResolvers();
    s.intercept((request, response) => { entered.resolve(); if (cancel === 'transport-error') { response.writeHead(500); response.end(); } return true; });
    const handle = f.runtime.spawn({...f.spec, argv: ['git', 'clone', s.url, s.target], ...(cancel === 'timeout' ? {signal: AbortSignal.timeout(1500)} : {})});
    await entered.promise;
    if (cancel === 'terminate') handle.terminate();
    const outcome = await handle.done;
    assert.notEqual(outcome.exitCode, 0);
    assert.equal(await handle.waitForExit(), true);
    for (const name of (await readdir(f.temp)).filter(name=>name !== 'clone')) {
      assert(name.startsWith('.dsh-git-clone-')); assert.deepEqual(await readdir(join(f.temp,name)), []);
    }
    if (existing) {
      assert.equal((await lstat(s.target)).ino, identity.ino);
      assert.deepEqual(await readdir(s.target), []);
    } else await assert.rejects(lstat(s.target), {code: 'ENOENT'});
    s.intercept(undefined);
    await f.git(['clone', s.url, s.target]);
    assert.equal((await f.git(['rev-parse', 'HEAD'], {cwd: s.target})).stdout.trim(), s.head);
    assert.equal(await readFile(join(s.target, '中文.txt'), 'utf8'), '第一行\nsecond\n');
    if (existing) assert.equal((await lstat(s.target)).mode & 0o777, 0o700);
    assert.deepEqual(s.calls.slice(-2), ['GET /repo/info/refs', 'POST /repo/git-upload-pack']);
  })));
}

for (const mutation of ['new-file', 'replace-empty', 'replace-symlink', 'new-directory']) {
  test(`clone commit 拒绝目标变化且保留用户内容 ${mutation}`, {timeout: 20000}, async () => fixture(async f => served(f, async s => {
    if (mutation !== 'new-directory') await mkdir(s.target);
    let saved;
    f.hooks.stage = async phase => {
      if (phase !== 'clone-before-commit') return;
      if (mutation === 'new-file') await writeFile(join(s.target, 'user.txt'), 'user-content');
      else if (mutation === 'new-directory') await mkdir(s.target);
      else {
        saved = s.target + '-original'; await rename(s.target, saved);
        if (mutation === 'replace-empty') await mkdir(s.target);
        else { await writeFile(join(f.outside, 'user.txt'), 'outside-content'); await symlinkFixture(f.outside, s.target); }
      }
    };
    const result = await f.run(['git', 'clone', s.url, s.target]);
    assert.notEqual(result.exitCode, 0);
    assert.equal((await lstat(s.target)).isSymbolicLink(), mutation === 'replace-symlink');
    if (mutation === 'new-file') assert.equal(await readFile(join(s.target, 'user.txt'), 'utf8'), 'user-content');
    else if (mutation === 'replace-symlink') assert.equal(await readFile(join(f.outside, 'user.txt'), 'utf8'), 'outside-content');
    else assert.deepEqual(await readdir(s.target), []);
    for (const name of (await readdir(f.temp)).filter(name=>name.startsWith('.dsh-git-clone-'))) assert.deepEqual(await readdir(join(f.temp,name)), []);
    if (saved) assert.deepEqual(await readdir(saved), []);
  })));
}

test('clone hard terminate 等待在途主线程metadata写入，才清理stage和放行', {timeout: 20000}, async () => fixture(async f => served(f, async s => {
  const entered = Promise.withResolvers(), resume = Promise.withResolvers(); let gated = false, stagePath;
  f.hooks.stage = async (phase, row) => {
    if (phase === 'clone-created') stagePath = row.path;
    if (!gated && phase === 'before-write' && stagePath && row.target.startsWith(stagePath + '/')) {
      gated = true; entered.resolve(); await resume.promise;
    }
  };
  const handle = f.runtime.spawn({...f.spec, argv: ['git', 'clone', s.url, s.target]});
  await entered.promise;
  handle.terminate();
  let done = false; handle.done.then(()=> {done=true;});
  await new Promise(resolve=>setTimeout(resolve, 50));
  assert.equal(done, false, 'owner must join accepted metadata before settlement');
  assert((await lstat(stagePath)).isDirectory());
  resume.resolve();
  assert.equal((await handle.done).signal, 'SIGTERM');
  assert.deepEqual(await readdir(stagePath), []);
  await assert.rejects(lstat(s.target), {code: 'ENOENT'});
  await f.git(['clone', s.url, s.target]);
})));
