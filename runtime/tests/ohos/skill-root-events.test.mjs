import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { renameSync, mkdirSync, statSync } from 'node:fs';
import { join, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const prefix = resolve(process.env.DSH_PREFIX);
const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await load('cordis');
const { SkillRegistry } = await load('dsh-skill');
const filesystem = await load('dsh-skill-filesystem');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

function resources(directory) {
  return process.report.getReport().libuv.filter(handle =>
    ['fs_poll', 'fs_event'].includes(handle.type) && handle.is_active &&
    (handle.filename === directory || handle.filename?.startsWith(directory + sep)));
}
async function eventually(action, predicate, label, timeoutMs = 5000) {
  const deadline = performance.now() + timeoutMs;
  let last;
  do {
    last = await action();
    if (predicate(last)) return last;
    await delay(20);
  } while (performance.now() < deadline);
  assert.fail(`${label}: ${JSON.stringify(last)}`);
}
async function fixture(t, options = {}) {
  const directory = await fs.mkdtemp(join(tmpdir(), 'dsh-skill-root-events-'));
  const anchor = join(directory, 'anchor');
  const root = join(anchor, 'missing', 'skills');
  await fs.mkdir(anchor);
  if (options.exists) await fs.mkdir(root, { recursive: true });
  const ctx = new Context();
  const warnings = [];
  await ctx.plugin(SkillRegistry);
  let changes = 0;
  ctx.on('skills/change', () => { changes += 1; });
  const plugin = ctx.plugin(filesystem, {
    includeDefaultRoots: false, customSkillDirs: [root],
    dshHome: join(directory, 'private-home'), agentsHome: join(directory, 'private-agents'),
    ...options.config,
  });
  await plugin.await();
  t.after(async () => {
    await ctx.fiber.dispose();
    await eventually(() => resources(directory), value => value.length === 0, 'all owned watch handles retire');
    await fs.rm(directory, { recursive: true, force: true });
  });
  const catalog = () => ctx.skills.snapshot();
  const first = await catalog();
  assert.equal(first.complete, true);
  assert.deepEqual(first.skills, []);
  return { directory, anchor, root, ctx, plugin, catalog, changes: () => changes, warnings };
}
async function publish(root, description = 'first', atomic = false) {
  await fs.mkdir(root, { recursive: true });
  const target = join(root, 'example.md');
  const body = `---\nname: example\ndescription: ${description}\n---\n${description} body\n`;
  if (atomic) {
    const staging = join(root, 'staging.tmp');
    await fs.writeFile(staging, body);
    await fs.rename(staging, target);
  } else await fs.writeFile(target, body);
}
const has = description => snapshot => snapshot.complete && snapshot.skills.some(skill => skill.name === 'example' && skill.description === description);
const empty = snapshot => snapshot.complete && snapshot.skills.length === 0;

test('default missing-root watches use native events without a steady stat-poll handle', async t => {
  const f = await fixture(t);
  const actual = resources(f.directory);
  t.diagnostic(JSON.stringify({ phase: 'default-missing-root', resources: actual }));
  assert.equal(actual.filter(handle => handle.type === 'fs_poll').length, 0);
  assert(actual.some(handle => handle.type === 'fs_event'));
});

test('missing intermediate directories and a newly published skill invalidate the cached empty catalog', async t => {
  const f = await fixture(t);
  const changes = f.changes();
  await publish(f.root);
  await eventually(f.catalog, has('first'), 'new root is discovered through actual watcher invalidation');
  assert(f.changes() > changes);
  assert.match((await f.ctx.skills.get('example')).content, /first body/);
});

test('atomic file replacement is observed after a missing root becomes an ordinary root', async t => {
  const f = await fixture(t);
  await publish(f.root);
  await eventually(f.catalog, has('first'), 'first publication');
  await publish(f.root, 'replacement', true);
  await eventually(f.catalog, has('replacement'), 'atomic replacement');
  assert.match((await f.ctx.skills.get('example')).content, /replacement body/);
});

test('deleting and recreating the skill root preserves discovery', async t => {
  const f = await fixture(t);
  await publish(f.root);
  await eventually(f.catalog, has('first'), 'initial skill');
  await fs.rm(f.root, { recursive: true });
  await eventually(f.catalog, empty, 'root deletion invalidates');
  await publish(f.root, 'recreated');
  await eventually(f.catalog, has('recreated'), 'root recreated');
});

test('renaming the existing ancestor while the root is absent still permits later discovery at the original path', async t => {
  const f = await fixture(t);
  await fs.rename(f.anchor, join(f.directory, 'moved-anchor'));
  await publish(f.root, 'new-ancestor');
  await eventually(f.catalog, has('new-ancestor'), 'new ancestor at the original path');
});

test('same-path empty ancestor replacement retains discovery after its rename event has settled', async t => {
  const f = await fixture(t);
  const before = statSync(f.anchor, { bigint: true });
  renameSync(f.anchor, join(f.directory, 'moved-anchor'));
  mkdirSync(f.anchor);
  const replacement = statSync(f.anchor, { bigint: true });
  assert.notEqual(before.ino, replacement.ino);
  // The target remains absent while events for the old inode are delivered.
  await delay(300);
  assert(empty(await f.catalog()));
  await publish(f.root, 'after-inode-replacement');
  await eventually(f.catalog, has('after-inode-replacement'), 'creation on the replacement ancestor invalidates the same cached catalog');
  t.diagnostic(JSON.stringify({ beforeIno: String(before.ino), replacementIno: String(replacement.ino) }));
});

test('explicit watchUsePolling=true retains missing-root polling and live discovery', async t => {
  const f = await fixture(t, { config: { watchUsePolling: true } });
  assert(resources(f.directory).some(handle => handle.type === 'fs_poll'));
  await publish(f.root, 'explicit-poll');
  await eventually(f.catalog, has('explicit-poll'), 'explicit polling discovers creation');
});

test('watch=false creates no native filesystem handles', async t => {
  const f = await fixture(t, { config: { watch: false } });
  assert.deepEqual(resources(f.directory), []);
  const changes = f.changes();
  await publish(f.root, 'unwatched');
  await delay(250);
  assert.equal(f.changes(), changes);
  assert.deepEqual(resources(f.directory), []);
  assert(empty(await f.catalog()), 'cached catalog is not silently refreshed by a hidden watcher');
});

test('provider disposal retires missing-root handles and ignores later directory creation', async t => {
  const f = await fixture(t);
  await f.plugin.dispose();
  await eventually(() => resources(f.directory), value => value.length === 0, 'provider dispose closes resources');
  const changes = f.changes();
  await publish(f.root, 'after-dispose');
  await delay(250);
  assert.equal(f.changes(), changes);
  assert.deepEqual(resources(f.directory), []);
});

test('an already existing root keeps its ordinary native watcher behavior', async t => {
  const f = await fixture(t, { exists: true });
  assert(!resources(f.directory).some(handle => handle.type === 'fs_poll'));
  await publish(f.root, 'existing-root');
  await eventually(f.catalog, has('existing-root'), 'existing root publication');
});

test('all default roots stay inside an explicit private project and homes', async t => {
  const directory = await fs.mkdtemp(join(tmpdir(), 'dsh-skill-private-project-'));
  const project = join(directory, 'project'), cwd = join(project, 'nested');
  const dshHome = join(directory, 'user-dsh'), agentsHome = join(directory, 'user-agents');
  const bundle = join(directory, 'empty-bundle');
  // findProjectRoot's exact contract tests for this entry's presence. This is an
  // owned marker fixture, not a claim that Git operations were executed.
  for (const path of [join(project, '.git'), cwd, dshHome, agentsHome, bundle]) await fs.mkdir(path, { recursive: true });
  const ctx = new Context();
  await ctx.plugin(SkillRegistry);
  const plugin = ctx.plugin(filesystem, { dshHome, agentsHome, bundledSkillDir: bundle });
  await plugin.await();
  t.after(async () => {
    await ctx.fiber.dispose();
    await eventually(() => resources(directory), value => value.length === 0, 'private default roots retire');
    await fs.rm(directory, { recursive: true, force: true });
  });
  const catalog = () => ctx.skills.snapshot({ cwd });
  assert(empty(await catalog()));
  const actual = process.report.getReport().libuv.filter(h => ['fs_poll', 'fs_event'].includes(h.type) && h.is_active);
  assert(actual.every(h => h.filename === directory || h.filename.startsWith(directory + sep)), 'no filesystem watcher escapes the owned fixture');
  t.diagnostic(JSON.stringify({ phase: 'private-default-roots', resources: actual }));
  assert.equal(actual.filter(h => h.type === 'fs_poll').length, 0);
  await publish(join(dshHome, 'skills'), 'user-root');
  await eventually(catalog, has('user-root'), 'user default root discovered');
  await publish(join(project, '.dsh/skills'), 'project-root');
  await eventually(catalog, has('project-root'), 'private project root discovered with original priority');
});
