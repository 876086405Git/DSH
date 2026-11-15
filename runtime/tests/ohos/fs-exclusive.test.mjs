// Run against the pinned, patched prefix; internals.platform is the provider's existing seam.
import assert from 'node:assert/strict';
import { mkdtemp, open, readFile, readdir, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { afterEach, beforeEach, test } from 'node:test';

const require = createRequire(join(resolve(process.env.DSH_TEST_PREFIX ?? process.cwd()), 'package.json'));
const { Context } = await import(pathToFileURL(require.resolve('@deepseek-ai/cordis')));
const { LocalFileSystem } = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-fs-local')));
const errno = (code) => Object.assign(new Error(`injected ${code}`), { code });
let directory;
let contexts;
let fs;

async function provider(platform = 'openharmony') {
  const ctx = new Context();
  contexts.push(ctx);
  await ctx.plugin(LocalFileSystem, { cwd: directory });
  ctx.fs.internals.platform = platform;
  ctx.fs.internals.linkFile = async () => { throw errno('EACCES'); };
  return ctx.fs;
}

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'dsh-ohos-exclusive-'));
  contexts = [];
  fs = await provider();
});

afterEach(async () => {
  for (const ctx of contexts) await ctx.fiber.dispose();
  await rm(directory, { recursive: true, force: true });
});

test('OpenHarmony EACCES creates Chinese text and cleans staging', async () => {
  const target = await fs.resolve('中文 文件.txt');
  await fs.writeText(target, '鸿蒙\r\n', { kind: 'createIfAbsent' });
  assert.equal(await readFile(target.targetKey, 'utf8'), '鸿蒙\r\n');
  assert.equal((await stat(target.targetKey)).mode & 0o777, 0o600);
  assert.deepEqual(await readdir(directory), ['中文 文件.txt']);
});

for (const platform of ['linux', 'android']) {
  test(`${platform} keeps rejecting EACCES without exclusive creation`, async () => {
    const other = await provider(platform);
    const failure = errno('EACCES');
    other.internals.linkFile = async () => { throw failure; };
    other.internals.openPublicationFile = async () => { assert.fail('Android behavior changed'); };
    const target = await other.resolve('unchanged.txt');
    await assert.rejects(other.writeText(target, 'ours', { kind: 'createIfAbsent' }), {
      code: 'FS_IO_ERROR', cause: failure,
    });
    await assert.rejects(stat(target.targetKey), { code: 'ENOENT' });
  });
}

test('OpenHarmony competing creator wins without being overwritten', async () => {
  const target = await fs.resolve('race.txt');
  fs.internals.linkFile = async () => {
    await writeFile(target.targetKey, 'competitor', { flag: 'wx' });
    throw errno('EACCES');
  };
  await assert.rejects(fs.writeText(target, 'ours', { kind: 'createIfAbsent' }), { code: 'FS_NOT_OBSERVED' });
  assert.equal(await readFile(target.targetKey, 'utf8'), 'competitor');
});

test('OpenHarmony EACCES does not follow a competing symlink', async () => {
  const target = await fs.resolve('alias.txt');
  const source = join(directory, 'source.txt');
  await writeFile(source, 'preserve');
  fs.internals.linkFile = async () => {
    await symlink(source, target.targetKey);
    throw errno('EACCES');
  };
  await assert.rejects(fs.writeText(target, 'ours', { kind: 'createIfAbsent' }), { code: 'FS_NOT_REGULAR_FILE' });
  assert.equal(await readFile(source, 'utf8'), 'preserve');
});

test('abort after rejected link does not create a target', async () => {
  const target = await fs.resolve('cancelled.txt');
  const abort = new AbortController();
  fs.internals.linkFile = async () => {
    abort.abort();
    throw errno('EACCES');
  };
  await assert.rejects(fs.writeText(target, 'ours', { kind: 'createIfAbsent' }, abort.signal), { code: 'FS_ABORTED' });
  await assert.rejects(stat(target.targetKey), { code: 'ENOENT' });
});

test('fallback failure closes its handle and preserves an unrelated replacement', async () => {
  const target = await fs.resolve('partial.txt');
  let handle;
  fs.internals.openPublicationFile = async (...args) => {
    handle = await open(...args);
    handle.writeFile = async () => {
      await handle.write('partial');
      await rm(target.targetKey);
      await writeFile(target.targetKey, 'replacement', { flag: 'wx' });
      throw errno('ENOSPC');
    };
    return handle;
  };
  await assert.rejects(fs.writeText(target, 'ours', { kind: 'createIfAbsent' }), { code: 'FS_IO_ERROR' });
  assert.equal(handle.fd, -1);
  assert.equal(await readFile(target.targetKey, 'utf8'), 'replacement');
});

test('other OpenHarmony errors retain the original failure', async () => {
  const target = await fs.resolve('io.txt');
  const failure = errno('EIO');
  fs.internals.linkFile = async () => { throw failure; };
  fs.internals.openPublicationFile = async () => { assert.fail('I/O error is not link rejection'); };
  await assert.rejects(fs.writeText(target, 'ours', { kind: 'createIfAbsent' }), { code: 'FS_IO_ERROR', cause: failure });
});
