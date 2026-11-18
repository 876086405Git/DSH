import { symlinkFixture } from './host-link-fixture.mjs';
import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fixture, executeGit, fixedEnv } from './git-owned-fixture.mjs';

// Native Git is executed only by the unrestricted oracle-recording pass. The
// strict pass replays the exact observations bound to this test source hash.
const record = process.env.DSH_GIT_ORACLE === 'record';
const oraclePath = new URL('./git-selection-native-oracle.json', import.meta.url);
const sourceSHA = createHash('sha256').update(await fs.readFile(fileURLToPath(import.meta.url))).digest('hex');
const nativeEnv = { ...process.env, ...fixedEnv, GIT_CONFIG_NOSYSTEM: '1',
  GIT_CONFIG_GLOBAL: '/dev/null', GIT_OPTIONAL_LOCKS: '0', LC_ALL: 'C' };
delete nativeEnv.LD_PRELOAD;
function native(cwd, args) {
  const value = spawnSync('git', args, { cwd, env: nativeEnv, encoding: 'utf8' });
  if (value.error) throw value.error;
  assert.equal(value.signal, null);
  return { exitCode: value.status, stdout: value.stdout, stderr: value.stderr };
}
const oracle = record ? { gitVersion: native(undefined, ['--version']).stdout.trim(),
  testSHA256: sourceSHA, scope: 'Native Git control starts from an exact recursive copy of the product fixture', results: {} }
  : JSON.parse(await fs.readFile(oraclePath, 'utf8'));
if (!record) assert.equal(oracle.testSHA256, sourceSHA, 'oracle must match this exact test source');
if (record) after(() => fs.writeFile(oraclePath, JSON.stringify(oracle, null, 2) + '\n'));

async function seed(f) {
  await f.run(['init', '-b', 'main']);
  await fs.writeFile(join(f.dir, 'tracked.txt'), 'tracked base\n');
  await f.run(['add', '--all']); await f.run(['commit', '-m', 'outer seed']);
}
async function nested(f) {
  const directory = join(f.dir, 'nested');
  await fs.mkdir(directory, { recursive: true });
  await f.run(['init', '-b', 'main'], { cwd: directory });
  await fs.writeFile(join(directory, 'tracked.txt'), 'nested base\n');
  await f.run(['add', '--all'], { cwd: directory });
  await f.run(['commit', '-m', 'nested seed'], { cwd: directory });
  return directory;
}
async function stageCompare(f, key, args) {
  if (record) {
    const control = join(f.root, 'native-control');
    await fs.cp(f.dir, control, { recursive: true });
    const result = native(control, args);
    const index = native(control, ['ls-files', '--stage']);
    assert.equal(index.exitCode, 0, index.stderr);
    oracle.results[key] = { args, exitCode: result.exitCode, index: index.stdout };
  }
  const expected = oracle.results[key]; assert(expected, `missing native observation: ${key}`);
  assert.deepEqual(args, expected.args);
  const actual = await executeGit(args, f.ctx);
  const listing = await f.run(['ls-files', '--stage']);
  if (record) assert.equal(listing.stdout, native(f.dir, ['ls-files', '--stage']).stdout,
    'restricted index reader must agree with native Git over the actual index');
  assert.equal(actual.exitCode, expected.exitCode, actual.stderr);
  assert.equal(listing.stdout, expected.index);
}

for (const kind of ['update-only', 'ignored-all', 'ignored-explicit', 'ignored-force']) {
  test(`nested repository selection: ${kind}`, async t => {
    const f = await fixture(t); await seed(f);
    if (kind.startsWith('ignored')) {
      await fs.writeFile(join(f.dir, '.gitignore'), 'nested/\n');
      await f.run(['add', '.gitignore']); await f.run(['commit', '-m', 'ignore nested']);
    }
    await nested(f);
    await fs.writeFile(join(f.dir, 'tracked.txt'), 'tracked changed\n');
    const args = kind === 'update-only' ? ['add', '-u'] : kind === 'ignored-explicit'
      ? ['add', '--', 'nested'] : kind === 'ignored-force' ? ['add', '--force', '--all'] : ['add', '--all'];
    await stageCompare(f, kind, args);
  });
}

for (const flag of ['-u', '--all']) {
  test(`repository created around existing outer tracked descendants: ${flag}`, async t => {
    const f = await fixture(t); await seed(f);
    const directory = join(f.dir, 'nested'); await fs.mkdir(directory);
    await fs.writeFile(join(directory, 'tracked.txt'), 'outer tracked nested file\n');
    await f.run(['add', '--all']); await f.run(['commit', '-m', 'outer descendant']);
    // The new inner repository must not absorb the already-tracked outer path.
    await nested(f);
    await fs.writeFile(join(f.dir, '.gitignore'), 'nested/\n');
    await stageCompare(f, `tracked-descendant-${flag}`, ['add', flag]);
  });
}

test('an already tracked gitlink updates despite a later ignore rule', async t => {
  const f = await fixture(t); await seed(f); const directory = await nested(f);
  await f.run(['add', '--all']); await f.run(['commit', '-m', 'track gitlink']);
  await fs.writeFile(join(f.dir, '.gitignore'), 'nested/\n');
  await f.run(['add', '.gitignore']); await f.run(['commit', '-m', 'ignore nested']);
  await fs.writeFile(join(directory, 'tracked.txt'), 'nested second commit\n');
  await f.run(['add', '-u'], { cwd: directory }); await f.run(['commit', '-m', 'nested second'], { cwd: directory });
  await stageCompare(f, 'tracked-gitlink', ['add', '-u']);
});

const crlfCases = [
  { key: 'nul-binary', before: [0, 255, 13, 10, 128, 10] },
  { key: 'control-binary', before: [1, 2, 13, 10] },
  { key: 'bare-cr', before: [65, 13, 66, 13, 10] },
  { key: 'non-utf8-text', before: [255, 10, 128, 10], after: [255, 13, 10, 128, 13, 10] },
  { key: 'text-lf', before: 'first\nsecond\n', after: 'first\r\nsecond\r\n' },
  { key: 'legacy-index-crlf', before: 'first\r\nsecond\r\n' },
  { key: 'input-lf', config: 'input', before: 'first\nsecond\n', after: 'first\r\nsecond\r\n' },
  { key: 'changed-text', before: 'first\nsecond\n', after: 'changed\r\nsecond\r\nnew\r\n' },
];
for (const row of crlfCases) {
  test(`autocrlf preserves raw bytes and native diff: ${row.key}`, async t => {
    const f = await fixture(t); await seed(f);
    const path = join(f.dir, 'content.dat'), before = Buffer.from(row.before), work = Buffer.from(row.after ?? row.before);
    await fs.writeFile(path, before);
    await f.run(['add', 'content.dat']); await f.run(['commit', '-m', 'raw bytes']);
    await f.run(['config', 'core.autocrlf', row.config ?? 'true']);
    await fs.writeFile(path, work);
    const args = ['diff', '--numstat'];
    if (record) oracle.results[row.key] = native(f.dir, args);
    const expected = oracle.results[row.key]; assert(expected, `missing native observation: ${row.key}`);
    const actual = await executeGit(args, f.ctx);
    assert.equal(expected.exitCode, 0, expected.stderr);
    assert.equal(actual.exitCode, expected.exitCode, actual.stderr);
    assert.equal(actual.stdout, expected.stdout);
    assert.deepEqual(await fs.readFile(path), work, 'diff never rewrites worktree bytes');
  });
}

test('autocrlf does not normalize a symlink represented as a regular file', async t => {
  const f = await fixture(t); await seed(f);
  const path = join(f.dir, 'link'), target = 'first\r\nsecond';
  await symlinkFixture(target, path); await f.run(['add', 'link']); await f.run(['commit', '-m', 'symlink bytes']);
  await f.run(['config', 'core.symlinks', 'false']); await f.run(['config', 'core.autocrlf', 'true']);
  await fs.rm(path); await fs.writeFile(path, target);
  if (record) oracle.results['symlink-as-file'] = native(f.dir, ['diff', '--numstat']);
  const expected = oracle.results['symlink-as-file']; assert(expected);
  const actual = await executeGit(['diff', '--numstat'], f.ctx);
  assert.equal(expected.exitCode, 0, expected.stderr);
  assert.equal(actual.exitCode, 0, actual.stderr); assert.equal(actual.stdout, expected.stdout);
});
