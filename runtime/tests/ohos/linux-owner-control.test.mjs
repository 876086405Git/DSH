import test from 'node:test';
import assert from 'node:assert/strict';
import { access, readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { ownerFixture, until } from './linux-control-fixture.mjs';

test('progress observer failures do not change verified installation success', async t => {
  const f = await ownerFixture(t, { progress() { throw new Error('display observer failed'); } });
  const owner = f.createOwner(); const result = await owner.install();
  assert.equal(owner.state, 'active'); assert.equal(result.backend.state, 'opened');
  assert.equal(f.counts().created, 1);
});

test('published writable data survives controlled native retirement acknowledgement', async t => {
  const joined = Promise.withResolvers(), f = await ownerFixture(t, { joinBarrier: joined.promise });
  const owner = f.createOwner(), { active } = await owner.install();
  const targetBefore = await readFile(active.target), disposing = owner.dispose();
  await until(() => f.counts().joined === 1);
  await access(active.target); joined.resolve(); const retirement = await disposing;
  assert.deepEqual(await readFile(active.target), targetBefore, 'published target bytes cannot be deleted by shutdown');
  assert.equal(retirement.resourcesRetired, true);
  assert.equal(retirement.filesRemoved, false);
  assert.equal(retirement.dataRetained, true);
  assert.equal(retirement.native.joined, true); assert.equal(retirement.native.retirementError, false);
  assert.equal((await readdir(f.data)).length, 2, 'fixed lock inode remains beside the retained instance');
  assert.equal(retirement.cleanCheckpoint, true);
  assert.equal(JSON.parse(await readFile(join(active.directory, 'instance.json'), 'utf8')).state, 'clean');
  await assert.rejects(access(join(active.directory, 'active.json')), { code: 'ENOENT' });
  await assert.rejects(owner.install(), { code: 'ERR_OHOS_LINUX_OWNER_CLOSED' });
});

test('a live owner rejects another owner before download or VM, without deletion', async t => {
  const f = await ownerFixture(t), first = f.createOwner(), { active } = await first.install();
  let downloaded = 0;
  const { LinuxInstallationOwner } = await import('../../ohos/linux/owner.mjs');
  const second = new LinuxInstallationOwner(f.options, { ...f.internals, download: { fetch() { downloaded++; throw new Error('must not download'); } } });
  await assert.rejects(second.install(), { code: 'ERR_OHOS_LINUX_BUSY' });
  assert.equal(downloaded, 0); assert.equal(f.counts().created, 1); await access(active.target);
  const retirement = await second.dispose(); assert.equal(retirement.filesRemoved, false);
});

test('App exports become the VM\'s 9P devices; jobs mount only those, and only on a guest that can', async t => {
  const f = await ownerFixture(t), exports = [{ tag: 'dsh0', path: f.directory }, { tag: 'dsh1', path: f.assets }];
  const { readFileSync } = await import('node:fs'), { LinuxInstallationOwner } = await import('../../ohos/linux/owner.mjs');
  assert.throws(() => new LinuxInstallationOwner({ ...f.options, exports: [{ tag: 'dsh1', path: f.directory }] }), TypeError);
  let config; const createSession = f.internals.createSession;
  f.internals.createSession = path => { config = JSON.parse(readFileSync(path, 'utf8')); return createSession(path); };
  const { backend } = await f.createOwner({ exports }).install();
  assert.deepEqual([config.fs0, config.fs1, config.fs2], [{ tag: 'dsh0', file: f.directory }, { tag: 'dsh1', file: f.assets }, undefined]);
  const spec = tag => ({ argv: ['true'], cwd: f.directory, graceMs: 1000, mounts: [{ tag, source: '', target: f.directory, readOnly: false }],
    stdio: { stdin: 'ignore', stdout: { maxBytes: 0 }, stderr: { maxBytes: 0 } } });
  // This peer's opened frame does not offer mounts, as a 931 agent would not.
  for (const tag of ['dsh0', 'dsh2']) assert.throws(() => backend.spawn(spec(tag)), { code: 'ERR_OHOS_LINUX_WORKSPACE_UNAVAILABLE' });
  assert.throws(() => backend.spawn({ ...spec('dsh0'), mounts: [] }), { code: 'ERR_OHOS_LINUX_WORKSPACE_UNAVAILABLE' });
});
