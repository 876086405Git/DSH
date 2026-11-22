import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, rename, stat, symlink, utimes, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { notesFixture } from './fixtures/companion-notes-files-source.mjs';

// Intact, SHA-bound LocalFileSystem/SandboxedFileSystem bodies; actual Node file IO.
// The framework peers are controlled. This is not a runtime engine or device test.
const check = (name, run) => test('SOURCE_IO receipt bytes ' + name, {
  skip: process.platform !== 'linux' && 'anchored receipt IO requires Linux',
}, run);
const MiB = 1024 * 1024;
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
async function selected(f, name, bytes) {
  await writeFile(join(f.root, 'notes', name), bytes);
  const listing = await f.fs.dshGoListNotes(f.directory);
  return listing.entries.find(entry => entry.name === name);
}
async function published(f, name, bytes) {
  const stage = await f.fs.dshGoStageNotesFile(f.directory, name, bytes);
  const artifact = await f.fs.dshGoPublishNotesFile(stage);
  assert.equal(artifact.state, 'verified');
  return { stage, artifact };
}

check('returns complete undecoded binary bytes and their actual version and digest', async t => {
  const f = await notesFixture(t, { injectLocalType: false });
  const bytes = Buffer.from([0x25, 0x50, 0x44, 0x46, 0, 0xff, 0xfe, 0x0d, 0x0a]);
  const entry = await selected(f, 'receipt.pdf', bytes);
  const result = await f.fs.dshGoReadReceipt(f.directory, entry, 4 * MiB);
  assert.deepEqual(Object.keys(result).sort(), ['bytes', 'identity', 'modifiedAtMs', 'sha256', 'size', 'type', 'version']);
  assert(Buffer.isBuffer(result.bytes));
  assert.deepEqual(result.bytes, bytes);
  assert.equal(result.sha256, digest(bytes));
  for (const key of ['type', 'size', 'identity', 'version', 'modifiedAtMs']) assert.equal(result[key], entry[key]);
  await assert.rejects(f.fs.dshGoReadNote(f.directory, entry, 4 * MiB), { code: 'FS_NOT_TEXT' });
});

for (const size of [0, 4 * MiB, 4 * MiB + 1]) {
  check('whole receipt size ' + size, async t => {
    const f = await notesFixture(t, { injectLocalType: false });
    const bytes = Buffer.alloc(size, 0xa5);
    const entry = await selected(f, 'receipt.pdf', bytes);
    const reading = f.fs.dshGoReadReceipt(f.directory, entry, 4 * MiB);
    if (size > 4 * MiB) await assert.rejects(reading, { code: 'FS_TOO_LARGE' });
    else {
      const result = await reading;
      assert.deepEqual(result.bytes, bytes);
      assert.equal(result.sha256, digest(bytes));
    }
  });
}

check('rejects invalid receipt bounds and missing original bindings without opening another file', async t => {
  const f = await notesFixture(t, { injectLocalType: false });
  const entry = await selected(f, 'receipt.pdf', Buffer.from([1]));
  for (const limit of [undefined, null, 0, -1, 1.5, NaN, Infinity, 4 * MiB + 1]) {
    await assert.rejects(f.fs.dshGoReadReceipt(f.directory, entry, limit), { code: 'FS_TOO_LARGE' });
  }
  for (const directory of [{ target: f.target }, { ...f.directory, identity: '' }]) {
    await assert.rejects(f.fs.dshGoReadReceipt(directory, entry, 1), { code: 'FS_NOT_OBSERVED' });
  }
  for (const version of [undefined, null, '']) {
    await assert.rejects(f.fs.dshGoReadReceipt(f.directory, { ...entry, version }, 1), { code: 'FS_NOT_OBSERVED' });
  }
  assert.deepEqual((await f.fs.dshGoReadReceipt(f.directory, entry, 1)).bytes, Buffer.from([1]));
  assert.deepEqual(await readdir(join(f.root, 'notes')), ['receipt.pdf']);
});

check('same name, size and mtime cannot substitute another receipt object', async t => {
  const f = await notesFixture(t, { injectLocalType: false });
  const path = join(f.root, 'notes', 'receipt.pdf');
  await writeFile(path, Buffer.from('first'));
  const instant = new Date('2026-11-21T02:34:56.000Z');
  await utimes(path, instant, instant);
  const entry = (await f.fs.dshGoListNotes(f.directory)).entries[0];
  const original = await stat(path);
  await rename(path, path + '.original');
  await writeFile(path, Buffer.from('other'));
  await utimes(path, original.atime, original.mtime);
  assert.equal((await stat(path)).size, original.size);
  assert.equal((await stat(path)).mtimeMs, original.mtimeMs);
  assert.notEqual((await stat(path)).ino, original.ino);
  await assert.rejects(f.fs.dshGoReadReceipt(f.directory, entry, 5), { code: 'FS_STALE_VERSION' });
  assert.equal(await readFile(path + '.original', 'utf8'), 'first');
});

check('a replaced bound directory cannot redirect receipt or artifact reads', async t => {
  const f = await notesFixture(t);
  const entry = await selected(f, 'receipt.pdf', Buffer.from([0xff]));
  const { artifact } = await published(f, 'result.xlsx', Buffer.from([0xff]));
  await rename(join(f.root, 'notes'), join(f.root, 'original'));
  await mkdir(join(f.root, 'notes'));
  await writeFile(join(f.root, 'notes', 'receipt.pdf'), Buffer.from([0xff]));
  await writeFile(join(f.root, 'notes', 'result.xlsx'), Buffer.from([0xff]));
  await assert.rejects(f.fs.dshGoReadReceipt(f.directory, entry, 1), { code: 'FS_STALE_VERSION' });
  await assert.rejects(f.fs.dshGoReadTaskArtifactBytes(f.directory, 'result.xlsx', artifact), { code: 'FS_STALE_VERSION' });
});

check('receipt and artifact names cannot follow a link or escape the bound directory', async t => {
  const f = await notesFixture(t);
  const entry = await selected(f, 'receipt.pdf', Buffer.from([0xff]));
  const { artifact } = await published(f, 'result.xlsx', Buffer.from([0xff]));
  await symlink(join(f.root, 'notes', 'receipt.pdf'), join(f.root, 'notes', 'link.pdf'));
  for (const name of ['../receipt.pdf', '/receipt.pdf', 'other\\receipt.pdf', '.', '..', 'bad\0.pdf']) {
    await assert.rejects(f.fs.dshGoReadReceipt(f.directory, { ...entry, name }, 1), { code: 'FS_NOT_OBSERVED' });
    await assert.rejects(f.fs.dshGoReadTaskArtifactBytes(f.directory, name, artifact), { code: 'FS_NOT_OBSERVED' });
  }
  await assert.rejects(f.fs.dshGoReadReceipt(f.directory, { ...entry, name: 'link.pdf' }, 1), { code: 'ELOOP' });
  await assert.rejects(f.fs.dshGoReadTaskArtifactBytes(f.directory, 'link.pdf', artifact), { code: 'ELOOP' });
});

check('an aborted read returns no receipt or artifact bytes', async t => {
  const f = await notesFixture(t);
  const entry = await selected(f, 'receipt.pdf', Buffer.from([0xff]));
  const { artifact } = await published(f, 'result.xlsx', Buffer.from([0xff]));
  const abort = new AbortController();
  abort.abort();
  await assert.rejects(f.fs.dshGoReadReceipt(f.directory, entry, 1, abort.signal), { code: 'FS_ABORTED' });
  await assert.rejects(f.fs.dshGoReadTaskArtifactBytes(f.directory, 'result.xlsx', artifact, abort.signal), { code: 'FS_ABORTED' });
});

check('a real XLSX remains exact through retained staging, publication, byte reopen and stage release', async t => {
  const f = await notesFixture(t);
  // Four synthetic rows, generated with locked fflate; this test claims no receipt extraction.
  const bytes = await readFile(new URL('./fixtures/companion-receipt-test.xlsx', import.meta.url));
  assert.equal(digest(bytes), '01ce9b03d8b30466635629e33c98cc3107b7781818bd282cf215c8573a215ed3');
  const { stage, artifact } = await published(f, '差旅小表.xlsx', bytes);
  const before = await f.fs.dshGoReadTaskArtifactBytes(f.directory, stage.outputName, artifact);
  assert.deepEqual(before.bytes, bytes);
  assert.equal(before.identity, artifact.identity);
  assert.equal(before.sha256, artifact.sha256);
  await assert.rejects(f.fs.dshGoReadNotesArtifact(f.directory, stage.outputName, artifact), { code: 'FS_NOT_TEXT' });
  await f.fs.dshGoReleaseNotesStage(stage);
  const after = await f.fs.dshGoReadTaskArtifactBytes(f.directory, stage.outputName, artifact);
  assert.deepEqual(after.bytes, bytes);
  assert.equal(after.identity, artifact.identity);
  assert.equal((await stat(join(f.root, 'notes', stage.outputName))).nlink, 1);
  const plain = await published(f, 'plain.txt', Buffer.from('已有文本接口保持。\r\n'));
  assert.equal((await f.fs.dshGoReadNotesArtifact(f.directory, plain.stage.outputName, plain.artifact)).text, '已有文本接口保持。\r\n');
});

for (const size of [0, 256 * 1024, 256 * 1024 + 1]) {
  check('registered artifact size ' + size, async t => {
    const f = await notesFixture(t);
    const bytes = Buffer.alloc(size, 0xfa);
    const { artifact } = await published(f, 'result.xlsx', bytes);
    const reading = f.fs.dshGoReadTaskArtifactBytes(f.directory, 'result.xlsx', artifact);
    if (size > 256 * 1024) await assert.rejects(reading, { code: 'FS_TOO_LARGE' });
    else {
      const result = await reading;
      assert.deepEqual(result.bytes, bytes);
      assert.equal(result.size, size);
    }
  });
}

check('artifact opens require original identity, exact size, digest and a bound directory', async t => {
  const f = await notesFixture(t);
  const { artifact } = await published(f, 'result.xlsx', Buffer.from([1, 2, 3]));
  for (const size of [undefined, null, -1, 0.5, NaN, Infinity, 256 * 1024 + 1]) {
    await assert.rejects(f.fs.dshGoReadTaskArtifactBytes(f.directory, 'result.xlsx', { ...artifact, size }), { code: 'FS_TOO_LARGE' });
  }
  for (const changes of [{ identity: undefined }, { identity: '' }, { sha256: undefined }, { sha256: '' }]) {
    await assert.rejects(f.fs.dshGoReadTaskArtifactBytes(f.directory, 'result.xlsx', { ...artifact, ...changes }), { code: 'FS_NOT_OBSERVED' });
  }
  await assert.rejects(f.fs.dshGoReadTaskArtifactBytes({ target: f.target }, 'result.xlsx', artifact), { code: 'FS_NOT_OBSERVED' });
  for (const changes of [{ identity: 'another-object' }, { sha256: '0'.repeat(64) }, { size: 4 }]) {
    await assert.rejects(f.fs.dshGoReadTaskArtifactBytes(f.directory, 'result.xlsx', { ...artifact, ...changes }), { code: 'FS_STALE_VERSION' });
  }
  await assert.rejects(f.fs.dshGoReadTaskArtifactBytes(f.directory, 'result.xlsx', { ...artifact, size: 2 }), { code: 'FS_TOO_LARGE' });
  assert.deepEqual((await f.fs.dshGoReadTaskArtifactBytes(f.directory, 'result.xlsx', artifact)).bytes, Buffer.from([1, 2, 3]));
});

check('an altered digest or a different object never becomes the original artifact', async t => {
  const f = await notesFixture(t);
  const bytes = Buffer.from([1, 2, 3]);
  const { artifact } = await published(f, 'result.xlsx', bytes);
  const path = join(f.root, 'notes', 'result.xlsx');
  await writeFile(path, Buffer.from([3, 2, 1]));
  await assert.rejects(f.fs.dshGoReadTaskArtifactBytes(f.directory, 'result.xlsx', artifact), { code: 'FS_STALE_VERSION' });
  await rename(path, path + '.moved');
  await assert.rejects(f.fs.dshGoReadTaskArtifactBytes(f.directory, 'result.xlsx', artifact), { code: 'ENOENT' });
  await writeFile(path, bytes);
  await assert.rejects(f.fs.dshGoReadTaskArtifactBytes(f.directory, 'result.xlsx', artifact), { code: 'FS_STALE_VERSION' });
  assert.deepEqual(await readFile(path), bytes);
});

check('the actual read-only sandbox inherits reads but still denies publication and cleanup', async t => {
  const f = await notesFixture(t);
  const bytes = Buffer.from([0xff, 0, 0xfe]);
  const entry = await selected(f, 'receipt.pdf', bytes);
  const { stage, artifact } = await published(f, 'result.xlsx', bytes);
  const ctx = { sandboxPolicy: { defaultMode: 'read-only', resolve: () => ({ mode: 'read-only', workspaceRoot: join(f.root, 'notes') }) } };
  const readonly = new f.providers.SandboxedFileSystem(ctx, { cwd: f.root, diffBasisMaxBytes: 10 * MiB });
  assert.equal(readonly.sandboxMode, 'read-only');
  assert.deepEqual((await readonly.dshGoReadReceipt(f.directory, entry, 3)).bytes, bytes);
  assert.deepEqual((await readonly.dshGoReadTaskArtifactBytes(f.directory, 'result.xlsx', artifact)).bytes, bytes);
  await assert.rejects(readonly.dshGoStageNotesFile(f.directory, 'other.xlsx', bytes), { code: 'FS_SANDBOX_DENIED' });
  await assert.rejects(readonly.dshGoPublishNotesFile(stage), { code: 'FS_SANDBOX_DENIED' });
  await assert.rejects(readonly.dshGoReleaseNotesStage(stage), { code: 'FS_SANDBOX_DENIED' });
  assert.deepEqual(await readFile(join(f.root, 'notes', stage.stageName, 'content')), bytes);
});
