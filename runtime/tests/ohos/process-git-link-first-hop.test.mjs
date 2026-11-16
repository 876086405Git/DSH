import { symlinkFixture } from './host-link-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, writeFile, readlink } from 'node:fs/promises';
import { join } from 'node:path';
import { fixture } from './git-owned-fixture.mjs';

async function stagedLink(f, path, target) {
  await symlinkFixture(target, join(f.dir, path));
  assert.equal(await readlink(join(f.dir, path)), target);
  await f.run(['add', '--', path]);
  const listing = (await f.run(['ls-files', '--stage'])).stdout;
  const row = listing.split('\n').map(line => /^(\d+) ([0-9a-f]{40}) 0\t(.+)$/.exec(line)).find(row => row?.[3] === path);
  assert(row, 'staged link must exist');
  assert.equal(row[1], '120000');
  assert.equal((await f.run(['cat-file', 'blob', row[2]])).stdout, target, 'Git link blob must preserve the raw first hop');
}

test('Git preserves relative and absolute first hops through a link chain', async t => {
  const f = await fixture(t); await f.run(['init', '-q']);
  await writeFile(join(f.dir, 'payload'), 'contents\n');
  await symlinkFixture('payload', join(f.dir, 'hop'));
  await stagedLink(f, 'relative', 'hop');
  await stagedLink(f, 'absolute', join(f.dir, 'hop'));
});

test('Git preserves dot and collapsible parent components in relative link blobs', async t => {
  const f = await fixture(t); await f.run(['init', '-q']);
  await mkdir(join(f.dir, 'dir')); await writeFile(join(f.dir, 'payload'), 'contents\n');
  await stagedLink(f, 'dot', './payload');
  await stagedLink(f, 'parent', 'dir/../payload');
});

test('Git preserves a permitted dangling relative target literally', async t => {
  const f = await fixture(t); await f.run(['init', '-q']);
  await stagedLink(f, 'dangling', './missing-target');
});

test('relative first-hop preservation does not expose or read targets outside the mount', async t => {
  const f = await fixture(t); const outside = join(f.root, 'outside'); await mkdir(outside);
  await writeFile(join(outside, 'sentinel'), 'private fixture sentinel');
  await symlinkFixture('../outside/sentinel', join(f.dir, 'outward'));
  assert.equal(await f.ctx.fs.readlink(join(f.dir, 'outward')), 'sentinel');
  await assert.rejects(f.ctx.fs.readFileBuffer(join(f.dir, 'outward')), /EACCES|ENOENT/);
});
