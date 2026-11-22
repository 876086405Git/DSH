import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdir, readFile, readdir, writeFile, stat, lstat, rename, rm, symlink, link, utimes } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { notesFixture, notesProviders, notesSourceRoot } from './fixtures/companion-notes-files-source.mjs';
const options = { skip: process.platform !== 'linux' ? 'anchored notes IO requires Linux'
  : !notesSourceRoot() && 'verified F filesystem source or DSH_PREFIX required' };
const check = (name, run) => test('SOURCE_IO ' + name, options, run);
const content = '# 今日待办\n- 周五配镜 [一.md:2]\n';
const errno = code => Object.assign(new Error('injected ' + code), { code });
const stage = f => f.fs.dshGoStageNotesFile(f.directory, '今日待办.md', content);
const output = f => join(f.root, 'notes', '今日待办.md');

check('lists actual last-modified metadata without reading or following child links', async t => {
  const f = await notesFixture(t);
  await writeFile(join(f.root, 'notes', '一.md'), 'line1\n- 周五配镜\n');
  const instant = new Date('2026-11-21T02:34:56.000Z');
  await utimes(join(f.root, 'notes', '一.md'), instant, instant);
  await writeFile(join(f.root, 'outside.txt'), 'private outside fixture');
  await symlink(join(f.root, 'outside.txt'), join(f.root, 'notes', 'link.md'));
  const actual = await f.fs.dshGoListNotes(f.directory);
  const entry = actual.entries.find(x => x.name === '一.md');
  assert.equal(entry.modifiedAtMs, instant.getTime());
  assert.equal(entry.size, Buffer.byteLength('line1\n- 周五配镜\n'));
  assert.equal(actual.entries.find(x => x.name === 'link.md').type, 'symlink');
  const read = await f.fs.dshGoReadNote(actual.directory, entry, 65536);
  assert.equal(read.text, 'line1\n- 周五配镜\n');
  assert.equal(read.version, entry.version);
  await assert.rejects(f.fs.dshGoReadNote(actual.directory, actual.entries.find(x => x.name === 'link.md'), 65536), { code: 'ELOOP' });
});
check('selected version changes are rejected and later files do not join the saved list', async t => {
  const f = await notesFixture(t), path = join(f.root, 'notes', 'one.txt');
  await writeFile(path, 'old');
  const selected = await f.fs.dshGoListNotes(f.directory);
  await writeFile(path, 'changed to another length');
  await writeFile(join(f.root, 'notes', 'later.txt'), 'new');
  await assert.rejects(f.fs.dshGoReadNote(selected.directory, selected.entries[0], 65536), { code: 'FS_STALE_VERSION' });
  assert.deepEqual(selected.entries.map(x => x.name), ['one.txt']);
});
check('a directory replaced after binding is rejected before a new selection', async t => {
  const f = await notesFixture(t);
  await rename(join(f.root, 'notes'), join(f.root, 'renamed'));
  await mkdir(join(f.root, 'notes'));
  await writeFile(join(f.root, 'notes', 'replacement-private.txt'), 'must not become selected');
  await assert.rejects(f.fs.dshGoListNotes(f.directory), { code: 'FS_STALE_VERSION' });
  assert.notEqual((await f.fs.dshGoBindNotesDirectory(f.target)).identity, f.directory.identity);
});
check('an unbound path cannot enter selection without its original directory identity', async t => {
  const f = await notesFixture(t);
  await assert.rejects(f.fs.dshGoListNotes({ target: f.target }), { code: 'FS_NOT_OBSERVED' });
});
check('replacing the directory cannot redirect a recorded read', async t => {
  const f = await notesFixture(t);
  await writeFile(join(f.root, 'notes', 'one.txt'), 'original');
  const selected = await f.fs.dshGoListNotes(f.directory);
  await rename(join(f.root, 'notes'), join(f.root, 'renamed'));
  await mkdir(join(f.root, 'notes'));
  await writeFile(join(f.root, 'notes', 'one.txt'), 'replacement');
  await assert.rejects(f.fs.dshGoReadNote(selected.directory, selected.entries[0], 65536), { code: 'FS_STALE_VERSION' });
});
check('a selected directory alias is bound to the original object and cannot redirect publication', async t => {
  const f = await notesFixture(t);
  await mkdir(join(f.root, 'other'));
  const alias = join(f.root, 'selected');
  await symlink(join(f.root, 'notes'), alias);
  const selected = await f.fs.dshGoBindNotesDirectory(await f.fs.resolve(alias));
  assert.equal(selected.identity, f.directory.identity);
  await rm(alias);
  await symlink(join(f.root, 'other'), alias);
  await assert.rejects(f.fs.dshGoStageNotesFile(selected, 'new.md', content), { code: 'FS_STALE_VERSION' });
  assert.deepEqual(await readdir(join(f.root, 'other')), []);
  assert.deepEqual(await readdir(join(f.root, 'notes')), []);
});
for (const [bytes, accepted] of [[65536, true], [65537, false]]) {
  check('whole-file byte bound ' + bytes, async t => {
    const f = await notesFixture(t);
    await writeFile(join(f.root, 'notes', 'one.txt'), 'a'.repeat(bytes));
    const selected = await f.fs.dshGoListNotes(f.directory);
    const operation = f.fs.dshGoReadNote(selected.directory, selected.entries[0], 65536);
    if (accepted) assert.equal((await operation).text.length, bytes);
    else await assert.rejects(operation, { code: 'FS_TOO_LARGE' });
  });
}
for (const bytes of [Buffer.from([0xff, 0xfe]), Buffer.from('hello\0binary')]) {
  check('invalid or binary input is not a partial text note ' + bytes.toString('hex'), async t => {
    const f = await notesFixture(t);
    await writeFile(join(f.root, 'notes', 'one.txt'), bytes);
    const selected = await f.fs.dshGoListNotes(f.directory);
    await assert.rejects(f.fs.dshGoReadNote(selected.directory, selected.entries[0], 65536), { code: 'FS_NOT_TEXT' });
  });
}
check('the real filesystem capability is reported separately from the IO-test injected local type', async t => {
  const f = await notesFixture(t, { injectLocalType: false });
  const support = await f.fs.dshGoNotesPublicationSupport(f.directory);
  assert.equal(support.filesystemType, f.actualFilesystemType);
  if (!['ef53', '58465342', '9123683e'].includes(f.actualFilesystemType)) {
    assert.equal(support.supported, false);
    await assert.rejects(stage(f), { code: 'FS_IO_ERROR' });
    assert.deepEqual(await readdir(join(f.root, 'notes')), []);
  }
});
check('stage alone creates no output; real hardlink/readback retains the same inode until committed cleanup', async t => {
  const f = await notesFixture(t), ref = await stage(f);
  await assert.rejects(stat(output(f)), { code: 'ENOENT' });
  assert.deepEqual(await f.fs.dshGoInspectNotesPublication(ref), { state: 'absent' });
  const result = await f.fs.dshGoPublishNotesFile(ref);
  assert.equal(result.state, 'verified');
  const stagePath = join(f.root, 'notes', ref.stageName, 'content');
  assert.equal((await stat(stagePath)).ino, (await stat(output(f))).ino);
  assert.equal((await stat(output(f))).nlink, 2);
  assert.equal((await f.fs.dshGoReadNotesArtifact(ref.directory, ref.outputName, result)).text, content);
  await f.fs.dshGoReleaseNotesStage(ref);
  assert.equal(await readFile(output(f), 'utf8'), content);
  assert.equal((await stat(output(f))).nlink, 1);
  await assert.rejects(stat(stagePath), { code: 'ENOENT' });
});
check('identical bytes in a competing file cannot be claimed as this publication', async t => {
  const f = await notesFixture(t), ref = await stage(f);
  await writeFile(output(f), content, { flag: 'wx' });
  const old = await stat(output(f));
  await assert.rejects(f.fs.dshGoPublishNotesFile(ref), { code: 'EEXIST' });
  assert.deepEqual(await f.fs.dshGoInspectNotesPublication(ref), { state: 'different_object' });
  assert.equal((await stat(output(f))).ino, old.ino);
  assert.equal(await readFile(output(f), 'utf8'), content);
});
check('two independent providers get exactly one real hardlink publication', async t => {
  const f = await notesFixture(t), first = await stage(f);
  const other = new f.providers.LocalFileSystem({}, { cwd: f.root, diffBasisMaxBytes: 10485760 });
  other.internals.companionStatfs = async () => ({ type: 0xef53n });
  const second = await other.dshGoStageNotesFile(f.directory, '今日待办.md', 'second');
  const results = await Promise.allSettled([f.fs.dshGoPublishNotesFile(first), other.dshGoPublishNotesFile(second)]);
  assert.equal(results.filter(x => x.status === 'fulfilled').length, 1);
  assert.equal(results.find(x => x.status === 'rejected').reason.code, 'EEXIST');
  assert.equal((await readdir(join(f.root, 'notes'))).filter(x => x === '今日待办.md').length, 1);
});
for (const code of ['EPERM', 'EXDEV', 'ENOTSUP']) {
  check('hardlink ' + code + ' never falls back to a partially written target', async t => {
    const f = await notesFixture(t), ref = await stage(f);
    f.fs.internals.linkFile = async () => { throw errno(code); };
    f.fs.internals.openPublicationFile = () => assert.fail('no exclusive-write fallback');
    await assert.rejects(f.fs.dshGoPublishNotesFile(ref), { code });
    await assert.rejects(stat(output(f)), { code: 'ENOENT' });
    assert.equal(await readFile(join(f.root, 'notes', ref.stageName, 'content'), 'utf8'), content);
  });
}
check('actual link followed by lost result recovers the same object, without another write', async t => {
  const f = await notesFixture(t), ref = await stage(f);
  f.fs.internals.linkFile = async (a, b) => { await link(a, b); throw errno('EIO'); };
  await assert.rejects(f.fs.dshGoPublishNotesFile(ref), { code: 'EIO' });
  const other = new f.providers.LocalFileSystem({}, { cwd: f.root, diffBasisMaxBytes: 10485760 });
  other.internals.linkFile = () => assert.fail('reconciliation must never publish');
  assert.equal((await other.dshGoInspectNotesPublication(JSON.parse(JSON.stringify(ref)))).state, 'verified');
});
check('a real child killed after publication leaves an identity that a fresh provider can reconcile', async t => {
  const f = await notesFixture(t), ref = await stage(f), record = join(f.root, 'reference.json');
  await writeFile(record, JSON.stringify(ref));
  const child = spawn(process.execPath, [fileURLToPath(new URL('./fixtures/companion-notes-files-crash.mjs', import.meta.url)), notesSourceRoot(), record], { stdio: ['ignore', 'pipe', 'pipe'] });
  let error = ''; child.stderr.on('data', x => { error += x; });
  const exit = await new Promise((resolve, reject) => { child.on('error', reject); child.on('exit', (code, signal) => resolve({ code, signal })); });
  assert.deepEqual(exit, { code: null, signal: 'SIGKILL' }, error);
  const { LocalFileSystem } = await notesProviders(notesSourceRoot());
  const recovered = new LocalFileSystem({}, { cwd: f.root, diffBasisMaxBytes: 10485760 });
  recovered.internals.linkFile = () => assert.fail('no second publication after process death');
  assert.equal((await recovered.dshGoInspectNotesPublication(JSON.parse(await readFile(record, 'utf8')))).state, 'verified');
  assert.equal(await readFile(output(f), 'utf8'), content);
});
check('cancel before link prevents output, while cancel after the actual link retains recoverable fact', async t => {
  const f = await notesFixture(t), ref = await stage(f), before = new AbortController();
  before.abort();
  await assert.rejects(f.fs.dshGoPublishNotesFile(ref, before.signal), { code: 'FS_ABORTED' });
  await assert.rejects(stat(output(f)), { code: 'ENOENT' });
  const during = new AbortController();
  f.fs.internals.linkFile = async (a, b) => { await link(a, b); during.abort(); };
  await assert.rejects(f.fs.dshGoPublishNotesFile(ref, during.signal), { code: 'FS_ABORTED' });
  assert.equal((await f.fs.dshGoInspectNotesPublication(ref)).state, 'verified');
});
check('replaced or removed artifacts report changed/missing and never recreate', async t => {
  const f = await notesFixture(t), ref = await stage(f), artifact = await f.fs.dshGoPublishNotesFile(ref);
  await rename(output(f), output(f) + '.moved');
  await assert.rejects(f.fs.dshGoReadNotesArtifact(ref.directory, ref.outputName, artifact), { code: 'ENOENT' });
  await writeFile(output(f), content, { flag: 'wx' });
  await assert.rejects(f.fs.dshGoReadNotesArtifact(ref.directory, ref.outputName, artifact), { code: 'FS_STALE_VERSION' });
  assert.equal(await readFile(output(f) + '.moved', 'utf8'), content);
});
check('read-only and outside-workspace policy deny the stage before IO', async t => {
  const f = await notesFixture(t, { sandboxed: true });
  await assert.rejects(f.fs.dshGoStageNotesFile(f.directory, 'new.md', content, undefined, { mode: 'read-only', workspaceRoot: join(f.root, 'notes') }), { code: 'FS_SANDBOX_DENIED' });
  await mkdir(join(f.root, 'outside'));
  const outside = await f.fs.dshGoBindNotesDirectory(await f.fs.resolve(join(f.root, 'outside')));
  await assert.rejects(f.fs.dshGoStageNotesFile(outside, 'new.md', content), { code: 'FS_SANDBOX_DENIED' });
  assert.deepEqual(await readdir(join(f.root, 'notes')), []);
  assert.deepEqual(await readdir(join(f.root, 'outside')), []);
});
check('the publication and cleanup each recheck real sandbox policy', async t => {
  const f = await notesFixture(t, { sandboxed: true }), ref = await stage(f);
  const denied = { mode: 'read-only', workspaceRoot: join(f.root, 'notes') };
  await assert.rejects(f.fs.dshGoPublishNotesFile(ref, undefined, denied), { code: 'FS_SANDBOX_DENIED' });
  await assert.rejects(stat(output(f)), { code: 'ENOENT' });
  await f.fs.dshGoPublishNotesFile(ref);
  await assert.rejects(f.fs.dshGoReleaseNotesStage(ref, undefined, denied), { code: 'FS_SANDBOX_DENIED' });
  assert.equal(await readFile(join(f.root, 'notes', ref.stageName, 'content'), 'utf8'), content);
  await f.fs.dshGoReleaseNotesStage(ref);
  assert.equal(await readFile(output(f), 'utf8'), content);
});
check('output traversal is rejected before any stage or target exists', async t => {
  const f = await notesFixture(t);
  await assert.rejects(f.fs.dshGoStageNotesFile(f.directory, '../other.md', content), { code: 'FS_NOT_OBSERVED' });
  assert.deepEqual(await readdir(join(f.root, 'notes')), []);
});
