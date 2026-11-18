import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { symlinkFixture } from './host-link-fixture.mjs';

assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
assert(process.env.OHOS_TEST_LINK_REQUESTS, 'run through process-link-fixture.py');

test('external inputs preserve first-hop and dangling bytes while Node creation stays EACCES', async t => {
  const root = await fs.mkdtemp(join(tmpdir(), 'link-input-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await fs.writeFile(join(root, 'payload'), 'UNCHANGED');
  await symlinkFixture('payload', join(root, 'first'));
  await symlinkFixture('first', join(root, 'second'));
  await symlinkFixture('missing', join(root, 'dangling'));
  assert.equal(await fs.readlink(join(root, 'second')), 'first');
  assert.equal(await fs.readFile(join(root, 'second'), 'utf8'), 'UNCHANGED');
  assert.equal(await fs.readlink(join(root, 'dangling')), 'missing');
  await assert.rejects(fs.stat(join(root, 'dangling')), { code: 'ENOENT' });
  for (const operation of [fs.symlink, fs.link]) {
    await assert.rejects(operation(join(root, 'payload'), join(root, 'forbidden')), { code: 'EACCES' });
    await assert.rejects(fs.lstat(join(root, 'forbidden')), { code: 'ENOENT' });
  }
  assert.equal((await fs.stat(join(root, 'payload'))).nlink, 1);
});

test('fixture actor cannot publish outside its owned workspace, even through a parent link', async t => {
  const root = await fs.mkdtemp(join(tmpdir(), 'link-boundary-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const outside = join(dirname(tmpdir()), 'must-not-create');
  await assert.rejects(symlinkFixture('missing', outside), /destination escaped/);
  await symlinkFixture(dirname(tmpdir()), join(root, 'escape'));
  await assert.rejects(symlinkFixture('missing', join(root, 'escape/must-not-create')), /destination escaped/);
  await assert.rejects(fs.lstat(outside), { code: 'ENOENT' });
});
