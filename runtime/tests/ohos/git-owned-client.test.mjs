import assert from 'node:assert/strict';
import test from 'node:test';
import * as fs from 'node:fs/promises';
import { basename, join } from 'node:path';
import { fixture, executeGit, createGitFs } from './git-owned-fixture.mjs';

const bytes = value => Buffer.from(value);
const missing = path => assert.rejects(fs.lstat(path), { code: 'ENOENT' });
async function seed(f) {
  await f.run(['init']);
  await fs.writeFile(join(f.dir, 'tracked.txt'), 'base\n');
  await f.run(['add', '--all']);
  await f.run(['commit', '-m', 'base']);
}

test('real common Git operations delegate every metadata payload and create no worker temporary', async t => {
  const f = await fixture(t); await seed(f);
  await f.run(['config', 'user.name', '中文用户']);
  await f.run(['branch', 'topic']); await f.run(['checkout', 'topic']);
  await fs.writeFile(join(f.dir, 'tracked.txt'), 'next\n'); await f.run(['add', '--all']);
  await f.run(['commit', '-m', 'next']); await f.run(['checkout', 'main']); await f.run(['branch', '-D', 'topic']);
  assert.equal(await fs.readFile(join(f.dir, 'tracked.txt'), 'utf8'), 'base\n');
  assert(f.calls.some(row => row.operation === 'writeMetadata' && row.target.endsWith('/config')));
  assert(f.calls.some(row => row.operation === 'writeMetadata' && row.target.includes('/objects/')));
  assert(f.calls.some(row => row.operation === 'createIndex'));
  const illegal = f.trace.filter(row => ['createExclusive', 'mv'].includes(row.operation)
    || (row.operation === 'writeFile' && row.path.startsWith(join(f.dir, '.git') + '/')));
  assert.deepEqual(illegal, [], 'metadata must not create or move a Worker-owned temporary');
  assert.deepEqual(f.trace.filter(row => row.path?.endsWith('/index.lock')), [], 'pinned library never accesses index.lock');
  assert.deepEqual(await f.records(), []);
});

test('real isomorphic-git add preserves the outer resource inode through all index rewrites and commit', async t => {
  const observed = [], f = await fixture(t, { async onStage(stage, row) {
    if (row.target.endsWith('/.git/index') && ['identified', 'after-write', 'before-commit', 'after-commit'].includes(stage)) {
      const info = await fs.stat(stage === 'after-commit' ? row.target : row.path, { bigint: true });
      observed.push({ stage, dev: String(info.dev), ino: String(info.ino) });
    }
  } });
  await f.run(['init']);
  for (const name of ['one', 'two', '中文']) await fs.writeFile(join(f.dir, name), name + '\n');
  await f.run(['add', '--all']);
  assert(observed.some(row => row.stage === 'identified'));
  assert(observed.filter(row => row.stage === 'after-write').length >= 4);
  assert.equal(new Set(observed.map(row => row.dev + ':' + row.ino)).size, 1);
  assert.deepEqual((await f.run(['ls-files', '-z'])).stdout.split('\0').filter(Boolean).sort(), ['one', 'two', '中文']);
  assert.equal(f.owner.resourceCount, 0); assert.deepEqual(await f.records(), []);
});

test('metadata strings, exact byte views and modes use actual parent commits', async t => {
  const f = await fixture(t); await f.run(['init']); f.calls.length = 0;
  const gitdir = join(f.dir, '.git'), adapter = createGitFs(f.ctx, { gitdir }).promises;
  await adapter.writeFile(join(gitdir, 'utf8'), '中文✓', 'utf8');
  await adapter.writeFile(join(gitdir, 'latin1'), 'ÿé', { encoding: 'latin1', mode: 0o640 });
  const all = bytes('xxABCDEyy'); await adapter.writeFile(join(gitdir, 'view'), all.subarray(2, 7));
  assert.deepEqual(await fs.readFile(join(gitdir, 'utf8')), bytes('中文✓'));
  assert.deepEqual(await fs.readFile(join(gitdir, 'latin1')), Buffer.from([255, 233]));
  assert.equal(await fs.readFile(join(gitdir, 'view'), 'utf8'), 'ABCDE');
  assert.equal((await fs.stat(join(gitdir, 'view'))).mode & 0o777, 0o600);
  assert.equal((await fs.stat(join(gitdir, 'latin1'))).mode & 0o777, 0o640);
  assert.equal(f.calls.filter(row => row.operation === 'writeMetadata').length, 3);
  assert.deepEqual(await f.records(), []);
});

test('read-only commands need no owner while an add without ownership fails before index mutation', async t => {
  const f = await fixture(t); await seed(f); const ctx = { ...f.ctx, ownedGit: undefined };
  const original = await fs.readFile(join(f.dir, '.git/index'));
  assert.equal((await executeGit(['status', '--porcelain'], ctx)).exitCode, 0);
  assert.equal((await executeGit(['rev-parse', 'HEAD'], ctx)).exitCode, 0);
  await fs.writeFile(join(f.dir, 'tracked.txt'), 'changed\n');
  const result = await executeGit(['add', '--all'], ctx);
  assert.equal(result.exitCode, 128); assert.match(result.stderr, /ownership service/);
  assert.deepEqual(await fs.readFile(join(f.dir, '.git/index')), original);
  assert.deepEqual(await f.records(), []);
});

test('a custom index in the work tree excludes only its exact live owned temp, not foreign matching prefixes', async t => {
  const resources = [], f = await fixture(t, { onStage(stage, row) { if (stage === 'identified') resources.push(row.path); } });
  await f.run(['init']);
  await fs.writeFile(join(f.dir, 'normal.txt'), 'normal\n');
  const foreign = '.dsh-ohos-git-foreign.tmp'; await fs.writeFile(join(f.dir, foreign), 'foreign\n');
  const env = { ...f.ctx.env, GIT_INDEX_FILE: join(f.dir, 'private.index') };
  await f.run(['add', '--all'], { env });
  const names = (await f.run(['ls-files', '-z'], { env })).stdout.split('\0').filter(Boolean);
  assert.deepEqual(names.sort(), [foreign, 'normal.txt'].sort());
  assert(resources.some(path => path.startsWith(f.dir + '/') && !path.startsWith(join(f.dir, '.git') + '/')));
  for (const resource of resources) assert(!names.includes(basename(resource)));
  assert.equal(await fs.readFile(join(f.dir, foreign), 'utf8'), 'foreign\n');
  assert.deepEqual(await f.records(), []);
});

test('index.lock mutation is explicitly unsupported, and cannot overwrite or delete a foreign lock', async t => {
  const f = await fixture(t); await f.run(['init']); const gitdir = join(f.dir, '.git');
  const resource = await f.owner.createIndex({ target: join(gitdir, 'index'), content: bytes('seed'), mode: 0o600 });
  const lock = resource.path + '.lock'; await fs.writeFile(lock, 'foreign-lock');
  const adapter = createGitFs(f.ctx, { gitdir, indexFile: resource.path, ownedIndex: resource }).promises;
  for (const path of [join(gitdir, 'index.lock'), lock]) {
    await assert.rejects(adapter.writeFile(path, bytes('bad')), { code: 'ENOTSUP' });
    await assert.rejects(adapter.unlink(path), { code: 'ENOTSUP' });
    await assert.rejects(adapter.rm(path), { code: 'ENOTSUP' });
  }
  await assert.rejects(adapter.unlink(join(gitdir, 'index')), { code: 'ENOTSUP' });
  assert.equal(await fs.readFile(resource.path, 'utf8'), 'seed');
  assert.equal(await fs.readFile(lock, 'utf8'), 'foreign-lock');
  await f.owner.releaseIndex(resource.id); await missing(resource.path);
  assert.equal(await fs.readFile(lock, 'utf8'), 'foreign-lock');
});

test('cooperative abort after a real owned index rewrite preserves the original and releases the exact temp', async t => {
  let armed = false, writes = 0; const controller = new AbortController(), reason = new Error('cancelled real owned-index fixture');
  const f = await fixture(t, { onStage(stage, row) {
    if (armed && stage === 'after-write' && row.target.endsWith('/.git/index') && ++writes === 2) controller.abort(reason);
  } });
  await seed(f); const original = await fs.readFile(join(f.dir, '.git/index'));
  await fs.writeFile(join(f.dir, 'tracked.txt'), 'changed\n'); armed = true;
  await assert.rejects(executeGit(['add', '--all'], { ...f.ctx, signal: controller.signal }), error => error === reason);
  assert.equal(writes, 2); assert.deepEqual(await fs.readFile(join(f.dir, '.git/index')), original);
  assert.equal(f.owner.resourceCount, 0); assert.deepEqual(await f.records(), []);
});

test('add --ignore-errors cannot hide an injected ownership RPC error', async t => {
  const f = await fixture(t); await seed(f); const original = await fs.readFile(join(f.dir, '.git/index'));
  await fs.writeFile(join(f.dir, 'tracked.txt'), 'changed\n');
  const ownedGit = { ...f.ctx.ownedGit, writeIndex() { throw Object.assign(new Error('injected ownership transport failure'), { code: 'ERR_OHOS_GIT_RESOURCE_TEST' }); } };
  const result = await executeGit(['add', '--all', '--ignore-errors'], { ...f.ctx, ownedGit });
  assert.equal(result.exitCode, 128); assert.match(result.stderr, /ownership transport failure/);
  assert.deepEqual(await fs.readFile(join(f.dir, '.git/index')), original);
  assert.equal(f.owner.resourceCount, 0); assert.deepEqual(await f.records(), []);
});

test('a client release failure is visible, and parent finish still cleans its owned resource', async t => {
  const f = await fixture(t); await seed(f); const original = await fs.readFile(join(f.dir, '.git/index'));
  const ownedGit = { ...f.ctx.ownedGit, releaseIndex() { throw Object.assign(new Error('injected release RPC failure'), { code: 'ERR_OHOS_GIT_RESOURCE_TEST' }); } };
  const result = await executeGit(['add'], { ...f.ctx, ownedGit });
  assert.equal(result.exitCode, 128); assert.match(result.stderr, /release RPC failure/);
  assert.equal(f.owner.resourceCount, 1); assert.deepEqual(await fs.readFile(join(f.dir, '.git/index')), original);
  await f.owner.finish(); assert.equal(f.owner.resourceCount, 0); assert.deepEqual(await f.records(), []);
});

test('an adapter without explicit metadata context remains readable but refuses writes', async t => {
  const f = await fixture(t); await f.run(['init']); const target = join(f.dir, '.git/config');
  const original = await fs.readFile(target), adapter = createGitFs(f.ctx).promises;
  assert.deepEqual(await adapter.readFile(target), original);
  await assert.rejects(adapter.writeFile(target, bytes('bad')), { code: 'ERR_OHOS_GIT_METADATA_CONTEXT' });
  assert.deepEqual(await fs.readFile(target), original);
});
