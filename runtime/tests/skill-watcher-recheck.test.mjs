import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { renameSync, symlinkSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';

const prefix = resolve(process.env.DSH_PREFIX);
const base = join(prefix, 'node_modules/@deepseek-ai');
const load = name => import(pathToFileURL(join(base, name, 'lib/index.js')));
const { Context } = await load('cordis');
const { SkillRegistry } = await load('dsh-skill');
const filesystem = await load('dsh-skill-filesystem');
const { default: chokidar } = await import(pathToFileURL(join(prefix, 'node_modules/chokidar/index.js')));

async function fixture(t, transition, config = {}) {
  const temp = await fs.mkdtemp(join(tmpdir(), 'skill-watcher-recheck-'));
  const root = join(temp, 'skills'), moved = join(temp, 'moved');
  await fs.mkdir(root);
  await fs.writeFile(join(root, 'example.md'), '---\nname: example\ndescription: Temporary test skill\n---\nBody\n');
  const opened = [], watch = chokidar.watch;
  let transitioned = false;
  chokidar.watch = function (...args) {
    const watcher = watch.apply(this, args), close = watcher.close.bind(watcher), once = watcher.once;
    const item = { watcher, closes: 0 };
    opened.push(item);
    watcher.close = () => { item.closes++; return close(); };
    // Change the actual filesystem only when the actual watcher reports ready.
    // The original listener and all watch/probe/close operations still run.
    watcher.once = function (event, listener) {
      if (event !== 'ready' || transitioned || transition === undefined) return once.call(this, event, listener);
      return once.call(this, event, (...values) => {
        transitioned = true;
        transition({ root, moved });
        listener(...values);
      });
    };
    return watcher;
  };
  const ctx = new Context();
  t.after(async () => {
    chokidar.watch = watch;
    await ctx.fiber.dispose();
    // Rescue original-product orphan handles after assertions, so a red test exits.
    for (const item of opened) if (!item.watcher.closed) await item.watcher.close();
    await fs.rm(temp, { recursive: true, force: true });
  });
  await ctx.plugin(SkillRegistry);
  const plugin = ctx.plugin(filesystem, { includeDefaultRoots: false, customSkillDirs: [root], watch: true, ...config });
  await plugin.await();
  return { ctx, plugin, root, moved, opened };
}

test('a real ELOOP after watcher ready closes the unowned handle and later discovery recovers', async t => {
  const f = await fixture(t, ({ root, moved }) => { renameSync(root, moved); symlinkSync(root, root); });
  const failed = await f.ctx.skills.snapshot();
  assert.equal(failed.complete, false);
  await assert.rejects(fs.stat(f.root), { code: 'ELOOP' });
  assert.equal(f.opened.length, 1);
  t.diagnostic(`post-ready ELOOP: close-count=${f.opened[0].closes} closed=${f.opened[0].watcher.closed}`);
  assert.equal(f.opened[0].closes, 1);
  assert.equal(f.opened[0].watcher.closed, true);
  await fs.unlink(f.root);
  await fs.rename(f.moved, f.root);
  const recovered = await f.ctx.skills.snapshot();
  assert.equal(recovered.complete, true);
  assert.equal(recovered.skills[0].name, 'example');
  assert.equal(f.opened.length, 2);
  assert.equal(f.opened[1].closes, 0);
  await f.plugin.dispose();
  assert.deepEqual(f.opened.map(item => item.closes), [1, 1]);
});

test('provider disposal after failed recheck has no orphan watcher', async t => {
  const f = await fixture(t, ({ root, moved }) => { renameSync(root, moved); symlinkSync(root, root); });
  assert.equal((await f.ctx.skills.snapshot()).complete, false);
  await f.plugin.dispose();
  t.diagnostic(`after provider disposal: close-count=${f.opened[0].closes} closed=${f.opened[0].watcher.closed}`);
  assert.equal(f.opened[0].closes, 1);
  assert.equal(f.opened[0].watcher.closed, true);
});

test('a successful changed-mode recheck still closes the old watcher and opens the new anchor', async t => {
  const f = await fixture(t, ({ root, moved }) => { renameSync(root, moved); symlinkSync(moved, root); });
  const snapshot = await f.ctx.skills.snapshot();
  assert.equal(snapshot.complete, true);
  assert.equal(snapshot.skills[0].name, 'example');
  assert.equal(f.opened.length, 2);
  assert.deepEqual(f.opened.map(item => item.closes), [1, 0]);
  await f.plugin.dispose();
  assert.deepEqual(f.opened.map(item => item.closes), [1, 1]);
});

test('stable mode retains its watcher until normal provider disposal', async t => {
  const f = await fixture(t);
  const snapshot = await f.ctx.skills.snapshot();
  assert.equal(snapshot.complete, true);
  assert.equal(snapshot.skills[0].name, 'example');
  assert.equal(f.opened.length, 1);
  assert.equal(f.opened[0].closes, 0);
  await f.plugin.dispose();
  assert.equal(f.opened[0].closes, 1);
  assert.equal(f.opened[0].watcher.closed, true);
});

test('a missing-root polling handle is also released when the second probe sees a real symlink loop', async t => {
  const f = await fixture(t, undefined, { watchUsePolling: true });
  await fs.rename(f.root, f.moved);
  const manager = f.ctx.skills.layers.global.providers.get('filesystem').provider.watchManager;
  const open = manager.openAncestorWatcher;
  const records = [];
  // Scope the ordering fixture to this owned provider instance. The actual
  // watchFile/unwatchFile calls run; no Node builtin is replaced process-wide.
  manager.openAncestorWatcher = function (...args) {
    const handle = open.apply(this, args), close = handle.close.bind(handle);
    const record = { handle, closes: 0 };
    records.push(record);
    handle.close = () => { record.closes++; return close(); };
    symlinkSync(f.root, f.root);
    return handle;
  };
  try {
    assert.equal((await f.ctx.skills.snapshot()).complete, false);
    await assert.rejects(fs.stat(f.root), { code: 'ELOOP' });
    assert.equal(f.opened.length, 0);
    assert.equal(records.length, 1);
    t.diagnostic(`ancestor post-open ELOOP: unwatch-count=${records[0].closes}`);
    assert.equal(records[0].closes, 1);
    await f.plugin.dispose();
    assert.equal(records[0].closes, 1);
  } finally {
    // Explicit harness rescue for the original-product orphan, after assertions.
    for (const record of records) if (record.closes === 0) record.handle.close();
    manager.openAncestorWatcher = open;
  }
});
