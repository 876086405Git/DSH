import assert from 'node:assert/strict';
import { test } from 'node:test';
import { constants, mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, realpathSync, readdirSync, renameSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { beginTransaction, recoverProfile, transactionFor } from '../../ohos/plugins/store.mjs';

const moduleUrl = new URL('../../ohos/plugins/store.mjs', import.meta.url).href;
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'ohos-plugin-store-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  writeFileSync(join(dir, 'package.json'), '{"dependencies":{},"dsh":{"profile":{"bundles":[]}}}\n');
  writeFileSync(join(dir, 'cordis.patch.yml'), '[]\n');
  return dir;
}
function selected(dir) {
  const active = JSON.parse(readFileSync(join(dir, '.plugin-manager/ohos/active.json')));
  return join(dir, '.plugin-manager/ohos/generations', active.packages['fixture-plugin']);
}
function manifest(dir) { return JSON.parse(readFileSync(join(dir, 'package.json'))); }
function stage(transaction, version = '1.0.0') {
  const generation = transaction.newGeneration();
  const pkg = join(generation, 'pkg');
  mkdirSync(pkg);
  writeFileSync(join(pkg, 'package.json'), JSON.stringify({ name: 'fixture-plugin', version }));
  writeFileSync(join(pkg, 'value.txt'), version);
  return pkg;
}
function install(dir, version) {
  const transaction = beginTransaction(dir);
  const pkg = stage(transaction, version);
  transaction.publish('fixture-plugin', pkg);
  const value = manifest(dir);
  value.dependencies['fixture-plugin'] = version;
  transaction.writeManifest(value);
  transaction.finish(true);
  return pkg;
}

test('install commits exact manifest and package selection while retaining immutable files', t => {
  const dir = fixture(t), pkg = install(dir, '1.0.0');
  assert.equal(manifest(dir).dependencies['fixture-plugin'], '1.0.0');
  assert.equal(selected(dir), pkg);
  assert.equal(existsSync(join(dir, '.plugin-manager/ohos/transaction.json')), false);
});

test('failure after package publication and bundle selection restores both', t => {
  const dir = fixture(t), old = install(dir, '1.0.0');
  const before = readFileSync(join(dir, 'package.json'));
  const transaction = beginTransaction(dir), newer = stage(transaction, '2.0.0');
  transaction.publish('fixture-plugin', newer);
  transaction.writeManifest({ dependencies: { 'fixture-plugin': '2.0.0' }, dsh: { profile: { bundles: ['fixture-plugin'] } } });
  writeFileSync(join(dir, 'compatibility.json'), '{"changed":true}');
  transaction.finish(false);
  assert.deepEqual(readFileSync(join(dir, 'package.json')), before);
  assert.equal(existsSync(join(dir, 'compatibility.json')), false);
  assert.equal(selected(dir), old);
  assert.equal(existsSync(newer), false);
});

test('update retains an old real path for a live Node module and points new readers at new bytes', t => {
  const dir = fixture(t), old = install(dir, '1.0.0'), newer = install(dir, '2.0.0');
  assert.equal(readFileSync(join(old, 'value.txt'), 'utf8'), '1.0.0');
  assert.equal(readFileSync(join(newer, 'value.txt'), 'utf8'), '2.0.0');
  assert.equal(selected(dir), newer);
});

test('remove rollback restores old manifest and selection without a download', t => {
  const dir = fixture(t), old = install(dir, '1.0.0');
  const transaction = beginTransaction(dir);
  transaction.publish('fixture-plugin', null);
  transaction.writeManifest({ dependencies: {}, dsh: { profile: { bundles: [] } } });
  transaction.finish(false);
  assert.equal(manifest(dir).dependencies['fixture-plugin'], '1.0.0');
  assert.equal(selected(dir), old);
});

test('failed registry attempt is reversible and can retry under the same transaction', t => {
  const dir = fixture(t), transaction = beginTransaction(dir);
  const first = stage(transaction);
  transaction.publish('fixture-plugin', first);
  transaction.writeManifest({ dependencies: { 'fixture-plugin': '1.0.0' } });
  transaction.rollbackAttempt();
  assert.equal(existsSync(first), false);
  assert.deepEqual(manifest(dir).dependencies, {});
  const second = stage(transaction, '1.1.0');
  transaction.publish('fixture-plugin', second);
  transaction.writeManifest({ dependencies: { 'fixture-plugin': '1.1.0' } });
  transaction.finish(true);
  assert.equal(manifest(dir).dependencies['fixture-plugin'], '1.1.0');
});

test('resolution reads never recover an active transaction and overlapping begin is refused', t => {
  const dir = fixture(t), transaction = beginTransaction(dir), pkg = stage(transaction);
  transaction.publish('fixture-plugin', pkg);
  recoverProfile(dir);
  assert.equal(selected(dir), pkg);
  assert.equal(transactionFor(dir), transaction);
  assert.throws(() => beginTransaction(dir), /未结束/);
  transaction.finish(false);
});

test('one attempt refuses a second publication before changing its durable intent', t => {
  const dir = fixture(t), old = install(dir, '1.0.0');
  const transaction = beginTransaction(dir), first = stage(transaction, '2.0.0'), second = stage(transaction, '3.0.0');
  transaction.publish('fixture-plugin', first);
  const journal = readFileSync(join(dir, '.plugin-manager/ohos/transaction.json'));
  assert.throws(() => transaction.publish('fixture-plugin', second), /重复发布/);
  assert.deepEqual(readFileSync(join(dir, '.plugin-manager/ohos/transaction.json')), journal);
  assert.equal(selected(dir), first);
  transaction.finish(false);
  assert.equal(selected(dir), old);
});

for (const point of ['generation', 'published', 'manifest']) test(`process death after ${point} restores on next startup`, t => {
  const dir = fixture(t), old = install(dir, '1.0.0');
  const before = readFileSync(join(dir, 'package.json'));
  const code = `
    import { beginTransaction } from ${JSON.stringify(moduleUrl)};
    import { mkdirSync, writeFileSync } from 'node:fs';
    import { join } from 'node:path';
    const transaction = beginTransaction(${JSON.stringify(dir)});
    const generation = transaction.newGeneration(), pkg = join(generation, 'pkg');
    mkdirSync(pkg); writeFileSync(join(pkg, 'package.json'), '{"name":"fixture-plugin","version":"2.0.0"}');
    if (${JSON.stringify(point)} === 'generation') process.exit(71);
    transaction.publish('fixture-plugin', pkg);
    if (${JSON.stringify(point)} === 'published') process.exit(71);
    transaction.writeManifest({ dependencies: { 'fixture-plugin': '2.0.0' } });
    process.exit(71);
  `;
  const result = spawnSync(process.execPath, ['--jitless', '--input-type=module', '-e', code], { encoding: 'utf8' });
  assert.equal(result.status, 71, result.stderr);
  recoverProfile(dir);
  assert.deepEqual(readFileSync(join(dir, 'package.json')), before);
  assert.equal(selected(dir), old);
  assert.equal(readdirSync(join(dir, '.plugin-manager/ohos/generations')).length, 1);
});

test('refuses unmanaged package directory before replacing its bytes', t => {
  const dir = fixture(t);
  mkdirSync(join(dir, 'node_modules/fixture-plugin'), { recursive: true });
  writeFileSync(join(dir, 'node_modules/fixture-plugin/sentinel'), 'keep');
  const transaction = beginTransaction(dir), pkg = stage(transaction);
  assert.throws(() => transaction.publish('fixture-plugin', pkg), /不能覆盖/);
  transaction.finish(false);
  assert.equal(readFileSync(join(dir, 'node_modules/fixture-plugin/sentinel'), 'utf8'), 'keep');
});

test('refuses symlinked store and metadata paths without writing their targets', t => {
  const dir = fixture(t), outside = fixture(t);
  symlinkSync(outside, join(dir, '.plugin-manager'), 'dir');
  assert.throws(() => beginTransaction(dir), /目录/);
  assert.deepEqual(readdirSync(outside).sort(), ['cordis.patch.yml', 'package.json']);
  rmSync(join(dir, '.plugin-manager'));
  rmSync(join(dir, 'package.json'));
  symlinkSync(join(outside, 'package.json'), join(dir, 'package.json'));
  assert.throws(() => beginTransaction(dir), /普通文件/);
  assert.deepEqual(manifest(outside).dependencies, {});
});

// The production source is copied verbatim except for its node:fs import
// specifier. Faults are explicit, scoped to a fresh private profile, and do not
// simulate actual disk quota, power loss, or HarmonyOS filesystem guarantees.
async function faultStore(t) {
  const dir = mkdtempSync(join(tmpdir(), 'ohos-store-fault-module-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const source = readFileSync(new URL(moduleUrl), 'utf8');
  assert.equal(source.split("from 'node:fs'").length, 2);
  writeFileSync(join(dir, 'store.mjs'), source.replace("from 'node:fs'", "from './fs.mjs'"));
  writeFileSync(join(dir, 'fs.mjs'), readFileSync(new URL('./store-fault-fs.mjs', import.meta.url)));
  const storeUrl = pathToFileURL(join(dir, 'store.mjs')).href;
  const boundaryUrl = pathToFileURL(join(dir, 'fs.mjs')).href;
  const boundary = await import(boundaryUrl);
  t.after(() => boundary.disarm());
  return { api: await import(storeUrl), boundary, storeUrl, boundaryUrl };
}
function installUsing(api, dir, version = '1.0.0') {
  const tx = api.beginTransaction(dir), pkg = stage(tx, version);
  tx.publish('fixture-plugin', pkg);
  tx.writeManifest({ dependencies: { 'fixture-plugin': version } });
  tx.finish(true); return pkg;
}
const profileFiles = ['package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'cordis.patch.yml', 'compatibility.json'];
const storePath = dir => join(dir, '.plugin-manager/ohos');
const journalPath = dir => join(storePath(dir), 'transaction.json');
const journal = dir => JSON.parse(readFileSync(journalPath(dir), 'utf8'));
const ioFailure = code => Object.assign(new Error(`Explicit imported-fs ${code} test double`), { code });
const denyCreates = event => {
  if (event.op === 'open' && event.phase === 'before' && typeof event.flags === 'number' && (event.flags & constants.O_CREAT))
    throw ioFailure('ENOSPC');
};
function assertNoTransaction(dir) {
  assert.equal(existsSync(journalPath(dir)), false);
  assert.deepEqual(readdirSync(storePath(dir)).filter(name => name.startsWith('rollback-')), []);
}

test('unchanged rollback frees its generation without allocating replacement file contents', async t => {
  const { api, boundary } = await faultStore(t), dir = fixture(t);
  const before = readFileSync(join(dir, 'package.json'));
  const tx = api.beginTransaction(dir), pkg = stage(tx);
  boundary.arm(dir, denyCreates);
  tx.finish(false);
  assert.deepEqual(readFileSync(join(dir, 'package.json')), before);
  assert.equal(existsSync(pkg), false);
  assertNoTransaction(dir);
});

test('after publication rollback restores all six beforeimages without new file allocation', async t => {
  const { api, boundary } = await faultStore(t), dir = fixture(t);
  const old = installUsing(api, dir);
  for (const name of profileFiles.slice(1)) writeFileSync(join(dir, name), `before ${name}\n`);
  const before = Object.fromEntries(profileFiles.map(name => [name, readFileSync(join(dir, name))]));
  const tx = api.beginTransaction(dir), pkg = stage(tx, '2.0.0');
  tx.publish('fixture-plugin', pkg);
  tx.writeManifest({ dependencies: { 'fixture-plugin': '2.0.0' } });
  for (const name of profileFiles.slice(1)) writeFileSync(join(dir, name), `after ${name}\n`);
  const generation = join(pkg, '..');
  boundary.arm(dir, denyCreates);
  tx.finish(false);
  for (const name of profileFiles) assert.deepEqual(readFileSync(join(dir, name)), before[name]);
  assert.equal(selected(dir), old);
  assert.equal(existsSync(pkg), false);
  assert.equal(existsSync(old), true);
  const events = boundary.events();
  const activeRestore = events.findIndex(e => e.op === 'rename' && e.phase === 'after' && e.to === join(storePath(dir), 'active.json'));
  const newTreeRemoval = events.findIndex(e => e.op === 'rm' && e.phase === 'after' && e.path === generation);
  const profileRestore = events.findIndex(e => e.op === 'rename' && e.phase === 'after' && e.to === join(dir, 'package.json'));
  assert.ok(activeRestore >= 0 && newTreeRemoval > activeRestore && profileRestore > newTreeRemoval);
  assertNoTransaction(dir);
});

test('removal rollback can restore an existing selection without any new generation to free', async t => {
  const { api, boundary } = await faultStore(t), dir = fixture(t), old = installUsing(api, dir);
  const before = readFileSync(join(dir, 'package.json'));
  const tx = api.beginTransaction(dir);
  tx.publish('fixture-plugin', null); tx.writeManifest({ dependencies: {} });
  boundary.arm(dir, denyCreates);
  tx.finish(false);
  assert.equal(selected(dir), old);
  assert.deepEqual(readFileSync(join(dir, 'package.json')), before);
  assertNoTransaction(dir);
});

test('registry retry replenishes consumed backups before a second publication can fail', async t => {
  const { api, boundary } = await faultStore(t), dir = fixture(t), old = installUsing(api, dir);
  const before = readFileSync(join(dir, 'package.json'));
  const tx = api.beginTransaction(dir), first = stage(tx, '2.0.0');
  tx.publish('fixture-plugin', first); tx.writeManifest({ dependencies: { 'fixture-plugin': '2.0.0' } });
  tx.rollbackAttempt();
  const second = stage(tx, '3.0.0');
  tx.publish('fixture-plugin', second); tx.writeManifest({ dependencies: { 'fixture-plugin': '3.0.0' } });
  boundary.arm(dir, denyCreates);
  tx.finish(false);
  assert.equal(selected(dir), old);
  assert.deepEqual(readFileSync(join(dir, 'package.json')), before);
  assert.equal(existsSync(first), false); assert.equal(existsSync(second), false);
  assertNoTransaction(dir);
});

test('begin cannot expose a transaction when ordinary backup preparation fails', async t => {
  const { api, boundary } = await faultStore(t), dir = fixture(t);
  const before = readFileSync(join(dir, 'package.json'));
  let faulted = false, unexpected;
  boundary.arm(dir, event => {
    if (!faulted && event.op === 'write' && event.phase === 'before' && event.path.includes('/rollback-')) {
      faulted = true; throw ioFailure('ENOSPC');
    }
  });
  try {
    assert.throws(() => { unexpected = api.beginTransaction(dir); }, { code: 'ENOSPC' });
    assert.equal(faulted, true);
    assert.throws(() => api.transactionFor(dir), /缺少/);
    assert.equal(journal(dir).phase, 'pending');
  } finally { boundary.disarm(); unexpected?.finish(false); }
  api.recoverProfile(dir);
  assert.deepEqual(readFileSync(join(dir, 'package.json')), before);
  assertNoTransaction(dir);
});

test('a different backup beforeimage is refused while new selection and journal remain intact', async t => {
  const { api } = await faultStore(t), dir = fixture(t), old = installUsing(api, dir);
  const tx = api.beginTransaction(dir), pkg = stage(tx, '2.0.0');
  tx.publish('fixture-plugin', pkg); tx.writeManifest({ dependencies: { 'fixture-plugin': '2.0.0' } });
  const record = journal(dir);
  assert.match(record.rollbackId ?? '', /^[a-f0-9]{32}$/);
  const backup = join(storePath(dir), `rollback-${record.rollbackId}`, 'active.json');
  writeFileSync(backup, '{"schema":1,"packages":{}}\n');
  assert.throws(() => tx.finish(false), /副本/);
  assert.equal(selected(dir), pkg);
  assert.equal(existsSync(pkg), true);
  assert.equal(journal(dir).phase, 'pending');
  writeFileSync(backup, Buffer.from(record.packages, 'base64'));
  api.recoverProfile(dir);
  assert.equal(selected(dir), old);
  assertNoTransaction(dir);
});

test('legacy schema2 journals without ordinary backup fields still recover with available space', async t => {
  const { api, storeUrl } = await faultStore(t), dir = fixture(t), old = installUsing(api, dir);
  const tx = api.beginTransaction(dir), pkg = stage(tx, '2.0.0');
  tx.publish('fixture-plugin', pkg); tx.writeManifest({ dependencies: { 'fixture-plugin': '2.0.0' } });
  const record = journal(dir);
  if (record.rollbackId !== undefined) {
    rmSync(join(storePath(dir), `rollback-${record.rollbackId}`), { recursive: true, force: true });
    delete record.rollbackId;
  }
  writeFileSync(journalPath(dir), JSON.stringify(record));
  const recovery = await import(storeUrl + '?legacy-recovery');
  recovery.recoverProfile(dir);
  assert.equal(selected(dir), old); assert.equal(existsSync(pkg), false);
  assertNoTransaction(dir);
});

test('a malformed ownership record cannot delete a generation still selected by restored active', async t => {
  const { api, storeUrl } = await faultStore(t), dir = fixture(t);
  installUsing(api, dir);
  const tx = api.beginTransaction(dir), unselected = stage(tx, '1.9.0'), pkg = stage(tx, '2.0.0');
  tx.publish('fixture-plugin', pkg);
  const record = journal(dir);
  record.packages = readFileSync(join(storePath(dir), 'active.json')).toString('base64');
  writeFileSync(journalPath(dir), JSON.stringify(record));
  const recovery = await import(storeUrl + '?ownership-recovery');
  assert.throws(() => recovery.recoverProfile(dir), /选择|引用/);
  assert.equal(selected(dir), pkg);
  assert.equal(existsSync(pkg), true);
  assert.equal(existsSync(unselected), true);
  assert.equal(journal(dir).phase, 'pending');
});

test('journal rollback identity must be a string, not a coercible array', async t => {
  const { api, storeUrl } = await faultStore(t), dir = fixture(t);
  api.beginTransaction(dir);
  const record = journal(dir);
  assert.match(record.rollbackId ?? '', /^[a-f0-9]{32}$/);
  record.rollbackId = [record.rollbackId];
  writeFileSync(journalPath(dir), JSON.stringify(record));
  const recovery = await import(storeUrl + '?invalid-identity');
  assert.throws(() => recovery.recoverProfile(dir), /事务记录无效/);
  assert.equal(existsSync(journalPath(dir)), true);
});

test('symlink replacement of the rollback directory is refused without touching outside bytes', async t => {
  const { api } = await faultStore(t), dir = fixture(t), outside = fixture(t), old = installUsing(api, dir);
  const tx = api.beginTransaction(dir), pkg = stage(tx, '2.0.0');
  tx.publish('fixture-plugin', pkg);
  const record = journal(dir), backup = join(storePath(dir), `rollback-${record.rollbackId}`), held = backup + '-held';
  renameSync(backup, held); symlinkSync(outside, backup, 'dir');
  const before = readFileSync(join(outside, 'package.json'));
  assert.throws(() => tx.finish(false), /普通目录/);
  assert.deepEqual(readFileSync(join(outside, 'package.json')), before);
  assert.equal(selected(dir), pkg); assert.equal(existsSync(pkg), true);
  rmSync(backup); renameSync(held, backup);
  api.recoverProfile(dir);
  assert.equal(selected(dir), old);
  assertNoTransaction(dir);
});

test('a consumed active backup survives a failed parent fsync and a no-allocation recovery retry', async t => {
  const { api, boundary } = await faultStore(t), dir = fixture(t), old = installUsing(api, dir);
  const before = readFileSync(join(dir, 'package.json'));
  const tx = api.beginTransaction(dir), pkg = stage(tx, '2.0.0');
  tx.publish('fixture-plugin', pkg); tx.writeManifest({ dependencies: { 'fixture-plugin': '2.0.0' } });
  let renamed = false;
  boundary.arm(dir, event => {
    if (event.op === 'rename' && event.phase === 'after' && event.to === join(storePath(dir), 'active.json')) renamed = true;
    if (renamed && event.op === 'fsync' && event.phase === 'before' && event.path === storePath(dir)) throw ioFailure('EIO');
  });
  assert.throws(() => tx.finish(false), { code: 'EIO' });
  assert.equal(selected(dir), old);
  assert.equal(existsSync(pkg), true);
  boundary.disarm(); boundary.arm(dir, denyCreates);
  api.recoverProfile(dir);
  assert.equal(selected(dir), old);
  assert.equal(existsSync(pkg), false);
  assert.deepEqual(readFileSync(join(dir, 'package.json')), before);
  assertNoTransaction(dir);
});

for (const point of ['unlink', 'unlink-fsync']) test(`committed ${point} cleanup failure does not report a failed installation`, async t => {
  const { api, boundary } = await faultStore(t), dir = fixture(t);
  const tx = api.beginTransaction(dir), pkg = stage(tx);
  tx.publish('fixture-plugin', pkg); tx.writeManifest({ dependencies: { 'fixture-plugin': '1.0.0' } });
  let deleted = false, faulted = false;
  boundary.arm(dir, event => {
    if (event.op === 'unlink' && event.path === journalPath(dir)) {
      if (event.phase === 'before' && point === 'unlink' && journal(dir).phase === 'committed') {
        faulted = true; throw ioFailure('EIO');
      }
      if (event.phase === 'after') deleted = true;
    }
    if (point === 'unlink-fsync' && deleted && event.op === 'fsync' && event.phase === 'before' && event.path === storePath(dir)) {
      faulted = true; throw ioFailure('EIO');
    }
  });
  const result = tx.finish(true);
  assert.equal(faulted, true);
  assert.deepEqual(result, { committed: true, cleanupPending: true });
  assert.equal(selected(dir), pkg);
  assert.throws(() => api.transactionFor(dir), /缺少/);
  boundary.disarm(); api.recoverProfile(dir);
  assert.equal(selected(dir), pkg);
  assert.equal(manifest(dir).dependencies['fixture-plugin'], '1.0.0');
  assertNoTransaction(dir);
});

test('a failed committed-journal directory sync is not misclassified as successful cleanup debt', async t => {
  const { api, boundary } = await faultStore(t), dir = fixture(t);
  const tx = api.beginTransaction(dir), pkg = stage(tx);
  tx.publish('fixture-plugin', pkg);
  let renamedCommitted = false;
  boundary.arm(dir, event => {
    if (event.op === 'rename' && event.phase === 'after' && event.to === journalPath(dir) && journal(dir).phase === 'committed') renamedCommitted = true;
    if (renamedCommitted && event.op === 'fsync' && event.phase === 'before' && event.path === storePath(dir)) throw ioFailure('EIO');
  });
  assert.throws(() => tx.finish(true), { code: 'EIO' });
  assert.equal(existsSync(pkg), true);
  boundary.disarm(); api.recoverProfile(dir);
});

for (const point of ['active-restore', 'generation-removal', 'profile-restore']) test(`process death after rollback ${point} is idempotently recovered`, async t => {
  const { api, storeUrl, boundaryUrl } = await faultStore(t), dir = fixture(t), old = installUsing(api, dir);
  const before = readFileSync(join(dir, 'package.json'));
  const code = `
    import { beginTransaction } from ${JSON.stringify(storeUrl)};
    import { arm } from ${JSON.stringify(boundaryUrl)};
    import { mkdirSync, writeFileSync } from 'node:fs';
    import { join } from 'node:path';
    const dir = ${JSON.stringify(dir)}, point = ${JSON.stringify(point)};
    const tx = beginTransaction(dir), generation = tx.newGeneration(), pkg = join(generation, 'pkg');
    mkdirSync(pkg); writeFileSync(join(pkg, 'package.json'), '{"name":"fixture-plugin","version":"2.0.0"}');
    tx.publish('fixture-plugin', pkg); tx.writeManifest({ dependencies: { 'fixture-plugin': '2.0.0' } });
    arm(dir, event => {
      if (event.phase !== 'after') return;
      if (point === 'active-restore' && event.op === 'rename' && event.to === join(dir, '.plugin-manager/ohos/active.json')) process.exit(73);
      if (point === 'generation-removal' && event.op === 'rm' && event.path === generation) process.exit(73);
      if (point === 'profile-restore' && event.op === 'rename' && event.to === join(dir, 'package.json')) process.exit(73);
    });
    tx.finish(false);
  `;
  const child = spawnSync(process.execPath, ['--jitless', '--input-type=module', '-e', code], { encoding: 'utf8' });
  assert.equal(child.status, 73, child.stderr);
  assert.equal(journal(dir).phase, 'pending');
  api.recoverProfile(dir);
  assert.equal(selected(dir), old);
  assert.deepEqual(readFileSync(join(dir, 'package.json')), before);
  assert.equal(readdirSync(join(storePath(dir), 'generations')).length, 1);
  assertNoTransaction(dir);
});
