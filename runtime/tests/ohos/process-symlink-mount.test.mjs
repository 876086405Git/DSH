import { symlinkFixture } from './host-link-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';

const strict = process.platform === 'openharmony' && globalThis[Symbol.for('dsh.go.ohos.sim')] === true;
const creation = strict ? ' (strict: creation is EACCES)' : '';
async function deniedCreation(f, result, entry = 'alias') {
  assert.notEqual(result.exitCode, 0, JSON.stringify(result));
  assert.match(result.stderr, /EACCES/);
  await assert.rejects(fs.lstat(join(f.work, entry)), { code: 'ENOENT' });
  assert.equal(await fs.readFile(join(f.work, 'input'), 'utf8'), 'OWN\n');
}

async function fixture(t) {
  const root = await fs.mkdtemp(join(tmpdir(), 'ohos-symlink-mount-'));
  const [work, temporary, outside] = ['work', 'temporary', 'outside'].map(name => join(root, name));
  await Promise.all([work, temporary, outside].map(path => fs.mkdir(path)));
  await fs.mkdir(join(work, 'sub'));
  await fs.writeFile(join(work, 'input'), 'OWN\n');
  await fs.writeFile(join(temporary, 'input'), 'TEMP\n');
  await fs.writeFile(join(outside, 'input'), 'OUTSIDE\n');
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot: temporary });
  t.after(async () => { try { await runtime.dispose(); } finally { await fs.rm(root, { recursive: true, force: true }); } });
  const run = async (command, env = {}) => {
    const handle = runtime.spawn({ argv: ['bash', '-c', command], cwd: work, env, graceMs: 200,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 4096 }, stderr: { maxBytes: 4096 } } });
    const outcome = await handle.done;
    return { ...outcome, stdout: handle.collected.stdout.readFrom(0).text, stderr: handle.collected.stderr.readFrom(0).text };
  };
  return { root, work, temporary, outside, run };
}

test('same-mount absolute ln target stays absolute through readlink and is readable' + creation, async t => {
  const f = await fixture(t), target = join(f.work, 'input');
  const result = await f.run('ln -s "$TARGET" alias; readlink alias; cat alias', { TARGET: target });
  if (strict) return deniedCreation(f, result);
  assert.equal(result.exitCode, 0, JSON.stringify(result));
  assert.equal(result.stdout, target + '\nOWN\n');
  assert.equal(await fs.readlink(join(f.work, 'alias')), target);
});

test('readlink preserves the first absolute hop instead of resolving a link chain' + creation, async t => {
  const f = await fixture(t), target = join(f.work, 'first');
  await symlinkFixture(join(f.work, 'input'), target);
  const result = await f.run('ln -s "$TARGET" alias; readlink alias; cat alias', { TARGET: target });
  if (strict) return deniedCreation(f, result);
  assert.equal(result.exitCode, 0, JSON.stringify(result));
  assert.equal(result.stdout, target + '\nOWN\n');
  assert.equal(await fs.readlink(join(f.work, 'alias')), target);
});

test('relative parent target remains relative to link directory, not shell cwd' + creation, async t => {
  const f = await fixture(t);
  const result = await f.run('ln -s ../input sub/alias; readlink sub/alias; cat sub/alias');
  if (strict) return deniedCreation(f, result, 'sub/alias');
  assert.equal(result.exitCode, 0, JSON.stringify(result));
  assert.equal(result.stdout, '../input\nOWN\n');
  assert.equal(await fs.readlink(join(f.work, 'sub/alias')), '../input');
});

test('nonexistent same-mount absolute target remains an honest dangling link' + creation, async t => {
  const f = await fixture(t), target = join(f.work, 'later');
  const result = await f.run('ln -s "$TARGET" alias; readlink alias', { TARGET: target });
  if (strict) return deniedCreation(f, result);
  assert.equal(result.exitCode, 0, JSON.stringify(result));
  assert.equal(result.stdout, target + '\n');
  assert.equal(await fs.readlink(join(f.work, 'alias')), target);
  await fs.writeFile(target, 'LATER');
  assert.equal(await fs.readFile(join(f.work, 'alias'), 'utf8'), 'LATER');
});

for (const absolute of [false, true]) test(`cross-mount ${absolute ? 'absolute' : 'relative'} target is explicitly unsupported without a wrong link`, async t => {
  const f = await fixture(t), target = absolute ? join(f.temporary, 'input') : '../temporary/input';
  const result = await f.run('ln -s "$TARGET" alias', { TARGET: target });
  t.diagnostic(JSON.stringify({ target, result, nativeTarget: await fs.readlink(join(f.work, 'alias')).catch(error => ({ code: error.code })), nativeContent: await fs.readFile(join(f.work, 'alias'), 'utf8').catch(error => ({ code: error.code })) }));
  assert.notEqual(result.exitCode, 0, JSON.stringify(result));
  assert.match(result.stderr, /EXDEV/);
  await assert.rejects(fs.lstat(join(f.work, 'alias')), { code: 'ENOENT' });
  assert.equal(await fs.readFile(join(f.temporary, 'input'), 'utf8'), 'TEMP\n');
});

test('outside target remains denied and its isolated sentinel is unchanged', async t => {
  const f = await fixture(t);
  const result = await f.run('ln -s "$TARGET" alias', { TARGET: join(f.outside, 'input') });
  assert.notEqual(result.exitCode, 0);
  assert.match(result.stderr, /EACCES/);
  await assert.rejects(fs.lstat(join(f.work, 'alias')), { code: 'ENOENT' });
  assert.equal(await fs.readFile(join(f.outside, 'input'), 'utf8'), 'OUTSIDE\n');
});
