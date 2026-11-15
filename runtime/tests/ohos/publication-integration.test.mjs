import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { link, mkdir, mkdtemp, open, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, test } from 'node:test';
import { loadInternals } from './load-internals.mjs';

const attachment = await loadInternals('@deepseek-ai/dsh-attachment-local', ['publishImmutableAlias', 'publishStagedObject']);
const session = await loadInternals('@deepseek-ai/dsh-session-persistence-jsonl', ['publishCurrentExclusive', 'JsonlSessionPersistence', 'SessionWriteLease']);
const hash = (data) => createHash('sha256').update(data).digest('hex');
let directory;
let root;

beforeEach(async () => {
  assert.equal(process.platform, 'openharmony', 'run this suite under the O0 simulator');
  directory = await mkdtemp(join(tmpdir(), 'dsh-ohos-publish-'));
  root = join(directory, 'home', 'attachments', 'v1');
  await mkdir(root, { recursive: true });
});

afterEach(async () => {
  await rm(directory, { recursive: true, force: true });
});

test('attachment aliases retain their content-addressed source and become read-only', async () => {
  const data = Buffer.from('附件源不能丢失\n');
  const source = join(root, 'object');
  const target = join(root, 'aliases', '中文 名称.txt');
  await writeFile(source, data);
  await attachment.publishImmutableAlias(root, source, target, hash(data));
  assert.deepEqual(await readFile(source), data);
  assert.deepEqual(await readFile(target), data);
  assert.equal((await stat(target)).mode & 0o777, 0o400);
});

test('attachment alias never overwrites a pre-existing different object', async () => {
  const source = join(root, 'source');
  const target = join(root, 'target');
  await writeFile(source, 'ours');
  await writeFile(target, 'competitor');
  await assert.rejects(attachment.publishImmutableAlias(root, source, target, hash('ours')), { code: 'ATTACHMENT_CORRUPT' });
  assert.equal(await readFile(target, 'utf8'), 'competitor');
  assert.equal(await readFile(source, 'utf8'), 'ours');
});

test('concurrent same-content aliases both succeed after the complete copy', async () => {
  const data = Buffer.alloc(512 * 1024, 0xa5);
  const source = join(root, 'object');
  const target = join(root, 'shared');
  await writeFile(source, data);
  await Promise.all(Array.from({ length: 4 }, () => attachment.publishImmutableAlias(root, source, target, hash(data))));
  assert.deepEqual(await readFile(source), data);
  assert.deepEqual(await readFile(target), data);
});

test('staged attachment publication preserves existing digest verification and cleanup', async () => {
  const data = Buffer.from('中文附件');
  const staged = join(root, 'stage');
  const target = join(root, 'files', 'object');
  await writeFile(staged, data);
  await attachment.publishStagedObject(root, target, { path: staged, boundary: directory, sha256: hash(data) });
  assert.deepEqual(await readFile(target), data);
  assert.equal((await stat(target)).mode & 0o777, 0o400);
  await assert.rejects(stat(staged), { code: 'ENOENT' });
});

test('session migration preserves its stage and rejects an existing current generation', async () => {
  const staged = join(directory, 'migration-stage');
  const current = join(directory, 'current');
  const fs = { link, open };
  await writeFile(staged, 'complete generation');
  assert.equal(await session.publishCurrentExclusive(staged, current, { platform: 'openharmony', fs }), true);
  assert.equal(await readFile(staged, 'utf8'), 'complete generation');
  assert.equal(await readFile(current, 'utf8'), 'complete generation');
  await writeFile(staged, 'another generation');
  assert.equal(await session.publishCurrentExclusive(staged, current, { platform: 'openharmony', fs }), false);
  assert.equal(await readFile(current, 'utf8'), 'complete generation');
});

test('session materialization uses the second patched publication site', async () => {
  const storage = Object.create(session.JsonlSessionPersistence.prototype);
  storage.root = join(directory, 'sessions');
  const project = join(storage.root, 'project');
  const dir = join(project, 'session');
  const finalPath = join(dir, 'session.v4.jsonl');
  await storage.materializePosix(project, dir, finalPath, 'session', Buffer.from('durable first log\n'));
  assert.equal(await readFile(finalPath, 'utf8'), 'durable first log\n');
  assert.deepEqual(await readdir(dir), ['session.v4.jsonl']);
  await assert.rejects(storage.materializePosix(project, dir, finalPath, 'session', Buffer.from('overwrite')));
  assert.equal(await readFile(finalPath, 'utf8'), 'durable first log\n');
});

test('real session leases reject a second owner and release on close', async () => {
  const first = await session.SessionWriteLease.acquire(join(directory, 'lease'), 'id');
  try {
    await assert.rejects(session.SessionWriteLease.acquire(join(directory, 'lease'), 'id'), { name: 'SessionAlreadyOwnedError' });
  } finally {
    await first.release();
  }
  const next = await session.SessionWriteLease.acquire(join(directory, 'lease'), 'id');
  await next.release();
  await next.release();
});
