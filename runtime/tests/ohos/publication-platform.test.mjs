import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
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
  assert.equal(process.platform, 'linux', 'Linux control suite; do not enable the OHOS simulator');
  directory = await mkdtemp(join(tmpdir(), 'dsh-ohos-control-'));
  root = join(directory, 'home', 'attachments', 'v1');
  await mkdir(root, { recursive: true });
});

afterEach(async () => {
  await rm(directory, { recursive: true, force: true });
});

test('Linux attachment alias still publishes the source inode with a real hard link', async () => {
  const source = join(root, 'object');
  const target = join(root, 'alias');
  await writeFile(source, 'content');
  await attachment.publishImmutableAlias(root, source, target, hash('content'));
  assert.equal((await stat(source)).ino, (await stat(target)).ino);
});

test('Linux staged attachments retain hard-link identity after stage removal', async () => {
  const source = join(root, 'stage');
  const target = join(root, 'object');
  await writeFile(source, 'content');
  const before = await stat(source);
  await attachment.publishStagedObject(root, target, { path: source, boundary: directory, sha256: hash('content') });
  assert.equal((await stat(target)).ino, before.ino);
  await assert.rejects(stat(source), { code: 'ENOENT' });
});

for (const platform of ['linux', 'android']) {
  test(`${platform} migration never converts EACCES into a copy`, async () => {
    const failure = Object.assign(new Error('link denied'), { code: 'EACCES' });
    await assert.rejects(session.publishCurrentExclusive('source', 'target', {
      platform,
      fs: {
        link: async () => { throw failure; },
        open: async () => { assert.fail('non-OHOS path changed'); },
      },
    }), (error) => error === failure);
  });
}

test('Linux session materialization still publishes its synced staging inode', async () => {
  const storage = Object.create(session.JsonlSessionPersistence.prototype);
  storage.root = join(directory, 'sessions');
  let staged;
  storage.writeSyncedTempFile = async (...args) => {
    const path = await session.JsonlSessionPersistence.prototype.writeSyncedTempFile.call(storage, ...args);
    staged = await stat(path);
    return path;
  };
  const project = join(storage.root, 'project');
  const dir = join(project, 'session');
  const path = join(dir, 'session.v4.jsonl');
  await storage.materializePosix(project, dir, path, 'id', Buffer.from('content'));
  assert.equal((await stat(path)).ino, staged.ino);
  assert.equal(await readFile(path, 'utf8'), 'content');
});

test('Linux session leases retain their original native flock path', async () => {
  const lease = await session.SessionWriteLease.acquire(join(directory, 'lease'), 'id');
  try {
    await assert.rejects(session.SessionWriteLease.acquire(join(directory, 'lease'), 'id'), { name: 'SessionAlreadyOwnedError' });
    const child = spawnSync(process.execPath, ['--jitless', '--input-type=module', '-e', `
      import { open } from 'node:fs/promises';
      import { createRequire } from 'node:module';
      import { pathToFileURL } from 'node:url';
      const require = createRequire(process.env.DSH_TEST_PREFIX + '/package.json');
      const { tryLockExclusive } = await import(pathToFileURL(require.resolve('@deepseek-ai/node-addon-system/flock')));
      const handle = await open(process.argv[1], 'a+');
      try { await tryLockExclusive(handle.fd); process.exitCode = 1; }
      catch (error) { if (!['EAGAIN', 'EWOULDBLOCK'].includes(error.code)) throw error; }
      finally { await handle.close(); }
    `, join(directory, 'lease', 'session.lock')], { encoding: 'utf8', timeout: 5000 });
    assert.equal(child.status, 0, child.error?.message ?? child.stderr);
  } finally {
    await lease.release();
  }
  const next = await session.SessionWriteLease.acquire(join(directory, 'lease'), 'id');
  await next.release();
});
