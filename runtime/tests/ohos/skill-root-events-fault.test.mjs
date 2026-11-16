import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { renameSync, mkdirSync } from 'node:fs';
import { join, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const prefix = resolve(process.env.DSH_PREFIX);
const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await load('cordis');
const { SkillRegistry } = await load('dsh-skill');
const packageDir = join(prefix, 'node_modules/@deepseek-ai/dsh-skill-filesystem/lib');
const localBoundary = new URL('./skill-root-events-fs-fixture.mjs', import.meta.url);
const { boundary } = await import(localBoundary);
// A private copy changes two fs import specifiers only. The real module body, all
// other imports and native operations run unchanged; no builtin is patched.
const moduleDirectory = await fs.mkdtemp(join(tmpdir(), 'dsh-skill-import-fixture-'));
after(() => fs.rm(moduleDirectory, { recursive: true, force: true }));
await fs.symlink(join(prefix, 'node_modules'), join(moduleDirectory, 'node_modules'), 'dir');
const source = await fs.readFile(join(packageDir, 'index.js'), 'utf8');
const specifier = 'from "node:fs";';
assert.equal(source.split(specifier).length, 2);
const promisesSpecifier = 'from "node:fs/promises";';
assert.equal(source.split(promisesSpecifier).length, 2);
await fs.writeFile(join(moduleDirectory, 'filesystem.mjs'), source
  .replace(specifier, `from ${JSON.stringify(localBoundary.href)};`)
  .replace(promisesSpecifier, `from ${JSON.stringify(localBoundary.href)};`));
const filesystem = await import(pathToFileURL(join(moduleDirectory, 'filesystem.mjs')));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const resources = directory => process.report.getReport().libuv.filter(handle =>
  ['fs_poll', 'fs_event'].includes(handle.type) && handle.is_active &&
  (handle.filename === directory || handle.filename?.startsWith(directory + sep)));
async function eventually(action, predicate, label, timeoutMs = 5000) {
  const end = performance.now() + timeoutMs;
  let last;
  do { last = await action(); if (predicate(last)) return last; await delay(20); } while (performance.now() < end);
  assert.fail(`${label}: ${JSON.stringify(last)}`);
}
async function fixture(t, mode) {
  const directory = await fs.mkdtemp(join(tmpdir(), 'dsh-skill-root-events-fault-'));
  const anchor = join(directory, 'anchor'), root = join(anchor, 'missing', 'skills');
  await fs.mkdir(anchor);
  // The owned directory itself may be watched after its child ancestor moves.
  boundary.reset(mode, directory);
  boundary.loopTarget = join(anchor, 'missing');
  const ctx = new Context();
  await ctx.plugin(SkillRegistry);
  let changes = 0;
  ctx.on('skills/change', () => { changes += 1; });
  const plugin = ctx.plugin(filesystem, { includeDefaultRoots: false, customSkillDirs: [root],
    dshHome: join(directory, 'home'), agentsHome: join(directory, 'agents') });
  await plugin.await();
  t.after(async () => {
    await ctx.fiber.dispose();
    await eventually(() => resources(directory), list => list.length === 0, 'all owned handles retire');
    await fs.rm(directory, { recursive: true, force: true });
  });
  return { directory, anchor, root, ctx, plugin, catalog: options => ctx.skills.snapshot(options), changes: () => changes };
}
async function publish(root, description) {
  await fs.mkdir(root, { recursive: true });
  await fs.writeFile(join(root, 'example.md'), `---\nname: example\ndescription: ${description}\n---\nbody\n`);
}
const has = description => value => value.complete && value.skills.some(s => s.description === description);

test('sync event creation failure falls back to real polling without losing a complete catalog', async t => {
  const f = await fixture(t, 'sync-error');
  const first = await f.catalog();
  assert.equal(first.complete, true);
  assert(resources(f.directory).some(h => h.type === 'fs_poll'));
  assert.equal(boundary.attempts.length, 1, 'local failure was actually injected once');
  for (let i = 0; i < 3; i++) await f.catalog({ cwd: join(f.directory, `request-${i}`) });
  assert.equal(boundary.attempts.length, 1, 'same-anchor discovery does not spin native retries');
  await publish(f.root, 'fallback-live');
  await eventually(f.catalog, has('fallback-live'), 'fallback retains discovery');
});

test('real ancestor disappearance between probe and fs.watch is retried with the new mode', async t => {
  const f = await fixture(t, 'ancestor-moves-before-open');
  const first = await f.catalog();
  assert.equal(first.complete, true);
  assert(boundary.injected);
  assert.equal(boundary.attempts.length, 2);
  assert(!resources(f.directory).some(h => h.type === 'fs_poll'));
  await publish(f.root, 'moved-back');
  await eventually(f.catalog, has('moved-back'), 'creation after real ENOENT');
});

test('an early asynchronous native watcher error falls back once after opening settles', async t => {
  const f = await fixture(t, 'early-async-error');
  await f.catalog();
  await eventually(() => resources(f.directory), list => list.some(h => h.type === 'fs_poll'), 'asynchronous error retires native watcher and falls back');
  assert.equal(boundary.attempts.length, 1);
  assert(boundary.records[0].closed);
  await publish(f.root, 'async-fallback');
  await eventually(f.catalog, has('async-fallback'), 'asynchronous fallback retains discovery');
});

test('an old native watcher error after replacement cannot invalidate or replace the new root watcher', async t => {
  const f = await fixture(t, 'none');
  assert.equal((await f.catalog()).complete, true);
  assert.equal(boundary.records.length, 1);
  const old = boundary.records[0];
  await publish(f.root, 'live-root');
  await eventually(f.catalog, has('live-root'), 'ordinary root replaces ancestor watcher');
  await eventually(() => old.closed, Boolean, 'ancestor watcher closes');
  await delay(250);
  const changes = f.changes(), before = resources(f.directory);
  old.watcher.emit('error', Object.assign(new Error('explicit late error on already closed old fixture handle'), { code: 'EIO' }));
  await delay(50);
  assert.equal(f.changes(), changes);
  assert.deepEqual(resources(f.directory), before);
  await publish(f.root, 'still-live');
  await eventually(f.catalog, has('still-live'), 'new watcher remains functional');
});

test('a real symlink loop during the second mode probe closes the new event handle and later recovers', async t => {
  const f = await fixture(t, 'loop-after-open');
  const failed = await f.catalog();
  assert.equal(failed.complete, false);
  await assert.rejects(fs.stat(f.root), { code: 'ELOOP' });
  await eventually(() => resources(f.directory), list => list.length === 0, 'failed recheck closes the unowned native handle');
  assert(boundary.records[0].closed);
  await fs.unlink(boundary.loopTarget);
  assert.equal((await f.catalog()).complete, true);
  await publish(f.root, 'recovered-loop');
  await eventually(f.catalog, has('recovered-loop'), 'later discovery recovers from non-absence failure');
});

test('same-path inode replacement between actual watch open and the second probe retries the native handle', async t => {
  const f = await fixture(t, 'ancestor-replaced-after-open');
  assert.equal((await f.catalog()).complete, true);
  assert.equal(boundary.attempts.length, 2);
  await eventually(() => boundary.records[0].closed, Boolean, 'old inode handle is closed');
  assert.equal(boundary.records[1].closed, false);
  assert(!resources(f.directory).some(h => h.type === 'fs_poll'));
  await publish(f.root, 'after-open-replacement');
  await eventually(f.catalog, has('after-open-replacement'), 'replacement inode is watched');
});

test('a real A-B-A replacement around fs.watch cannot orphan future creation on restored A', async t => {
  const f = await fixture(t, 'ancestor-ABA-around-open');
  assert.equal((await f.catalog()).complete, true);
  assert(boundary.injected);
  await delay(300);
  assert(boundary.records[0].events.some(row => row.event === 'rename'), 'the actual temporary-inode rename was delivered');
  assert.deepEqual((await f.catalog()).skills, []);
  await publish(f.root, 'after-ABA');
  let found = false;
  const end = performance.now() + 2000;
  while (performance.now() < end) {
    if (has('after-ABA')(await f.catalog())) { found = true; break; }
    await delay(20);
  }
  const forced = await f.catalog({ cwd: f.directory });
  assert(has('after-ABA')(forced), 'real file remains valid independently of cached watcher invalidation');
  t.diagnostic(JSON.stringify({ openingAttempts: boundary.attempts.length,
    temporaryHandleClosed: boundary.records[0].closed, actualTemporaryEvents: boundary.records[0].events }));
  assert.equal(found, true, 'restored A must retain live discovery after the B rename event settles');
});

test('unrelated ancestor rename refreshes native liveness without invalidating the catalog, and ordinary change retains the handle', async t => {
  const f = await fixture(t, 'none');
  assert.equal((await f.catalog()).complete, true);
  const changes = f.changes();
  const other = join(f.anchor, 'unrelated.txt');
  await fs.writeFile(other, 'not a skill');
  await delay(250);
  const afterRename = boundary.attempts.length;
  assert(afterRename > 1, 'native rename conservatively refreshes inode liveness');
  assert.equal(f.changes(), changes);
  await fs.writeFile(other, 'still unrelated');
  await delay(250);
  assert.equal(boundary.attempts.length, afterRename, 'same-inode change creates no extra watcher');
  assert.equal(f.changes(), changes);
  assert.equal(resources(f.directory).filter(h => h.type === 'fs_event').length, 1);
  assert(!resources(f.directory).some(h => h.type === 'fs_poll'));
  t.diagnostic(JSON.stringify({ beforeRenameAttempts: 1, afterRenameAttempts: afterRename,
    afterChangeAttempts: boundary.attempts.length, catalogChanges: f.changes() - changes }));
  await publish(f.root, 'after-unrelated');
  await eventually(f.catalog, has('after-unrelated'), 'original watcher remains live');
});

test('closed old-inode events and errors cannot retire the new same-path ancestor watcher', async t => {
  const f = await fixture(t, 'none');
  assert.equal((await f.catalog()).complete, true);
  const old = boundary.records[0];
  renameSync(f.anchor, join(f.directory, 'moved-anchor'));
  mkdirSync(f.anchor);
  await eventually(() => boundary.records.length, count => count === 2, 'same-path ancestor gets a new watcher');
  await eventually(() => old.closed, Boolean, 'old inode closes');
  await delay(100);
  const current = boundary.records[1], changes = f.changes(), before = resources(f.directory);
  // Explicit local delivery of stale native-handle callbacks; no kernel race
  // or natural EIO is claimed by this controlled EventEmitter boundary.
  old.watcher.emit('change', 'rename', null);
  old.watcher.emit('error', Object.assign(new Error('late old inode failure'), { code: 'EIO' }));
  await delay(100);
  assert.equal(f.changes(), changes);
  assert.equal(boundary.records.length, 2);
  assert.equal(current.closed, false);
  assert.deepEqual(resources(f.directory), before);
  await publish(f.root, 'after-old-callbacks');
  await eventually(f.catalog, has('after-old-callbacks'), 'new ancestor survives old callbacks');
});

for (const outcome of ['success', 'EIO']) test(`an old in-flight mode probe cannot affect a replacement watcher after late ${outcome}`, async t => {
  const f = await fixture(t, 'none');
  assert.equal((await f.catalog()).complete, true);
  const old = boundary.records[0];
  const gate = boundary.holdNextStat(f.root);
  // This event starts while the handle is current; only its local stat await is
  // delayed. A second real filesystem event must be free to replace the inode.
  old.watcher.emit('change', 'rename', null);
  await gate.entered;
  renameSync(f.anchor, join(f.directory, 'moved-anchor'));
  mkdirSync(f.anchor);
  await eventually(() => boundary.records.length, count => count === 2, 'real rename replaces old watcher while its first probe waits');
  await eventually(() => old.closed, Boolean, 'old inode retires');
  await delay(100);
  const current = boundary.records[1], changes = f.changes(), before = resources(f.directory);
  gate.release(outcome === 'EIO' ? Object.assign(new Error('local delayed stat failure'), { code: 'EIO' }) : undefined);
  await delay(100);
  assert.equal(f.changes(), changes);
  assert.equal(boundary.records.length, 2);
  assert.equal(current.closed, false);
  assert.deepEqual(resources(f.directory), before);
  await publish(f.root, `after-late-${outcome}`);
  await eventually(f.catalog, has(`after-late-${outcome}`), 'replacement stays live after old probe completion');
});
