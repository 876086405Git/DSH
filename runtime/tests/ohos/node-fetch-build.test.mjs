import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

assert(process.env.OHOS_NODE_SOURCE && process.env.OHOS_NODE_BUILD_TOOLS,
  'Set OHOS_NODE_SOURCE to pristine official Node24.22.1 source and OHOS_NODE_BUILD_TOOLS to locked esbuild0.27.3');
const pristine = resolve(process.env.OHOS_NODE_SOURCE), buildTools = resolve(process.env.OHOS_NODE_BUILD_TOOLS);
const script = fileURLToPath(new URL('../../../tooling/ohos/prepare-node-fetch.mjs', import.meta.url));
const oldScript = fileURLToPath(new URL('../../ohos/node/patch-undici.mjs', import.meta.url));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const paths = ['deps/undici/src/lib/web/fetch/body.js', 'deps/undici/src/lib/web/fetch/index.js', 'deps/undici/undici.js'];
const finalHashes = [
  '3e57dbca4505d41f0eff63be2d7c631bb4bd0dce8562b4d098e38d1c10281eb7',
  '26701b1c1fd7a2b1240476165fde7661071da4d8ffba1e4624d7b9904cd14fd8',
  'db17946f41981758f1d4328836360fe3d62818b12b73eb12a7198b39e2e61630',
];
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-fetch-build-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, 'src')); await mkdir(join(root, 'deps'));
  await cp(join(pristine, 'src/node_version.h'), join(root, 'src/node_version.h'));
  await cp(join(pristine, 'deps/undici'), join(root, 'deps/undici'), { recursive: true });
  return root;
}
const digest = root => Promise.all(paths.map(async p => hash(await readFile(join(root, p)))));
function run(root, target = 'ohos', tools = buildTools) {
  return spawnSync(process.execPath, [script, '--target', target, '--build-tools', tools, root], { encoding: 'utf8' });
}

test('pristine source produces the exact combined bytes and a second invocation is content-idempotent', async t => {
  const root = await fixture(t);
  const first = run(root); assert.equal(first.status, 0, first.stderr);
  assert.deepEqual(await digest(root), finalHashes);
  const second = run(root); assert.equal(second.status, 0, second.stderr);
  assert.deepEqual(await digest(root), finalHashes);
});

test('the unchanged accepted O7a preparer feeds the new preparer without changing its body.js bytes', async t => {
  const root = await fixture(t), runner = join(root, 'existing-preparer');
  await mkdir(runner); await cp(oldScript, join(runner, 'patch-undici.mjs'));
  await symlink(buildTools, join(runner, 'build-tools'), 'dir');
  const first = spawnSync(process.execPath, [join(runner, 'patch-undici.mjs'), root], { encoding: 'utf8' });
  assert.equal(first.status, 0, first.stderr);
  const body = await readFile(join(root, paths[0]));
  assert.equal(hash(body), finalHashes[0]);
  const second = run(root); assert.equal(second.status, 0, second.stderr);
  assert.deepEqual(await readFile(join(root, paths[0])), body);
  assert.deepEqual(await digest(root), finalHashes);
});

for (const [label, relative, mutate, expected] of [
  ['version', 'src/node_version.h', s => s.replace('#define NODE_PATCH_VERSION 1\n', '#define NODE_PATCH_VERSION 2\n'), /Requires Node 24/],
  ['fetch source', paths[1], s => s + '\n// unapproved input\n', /Unknown Undici input/],
  ['bundle', paths[2], s => s + '\n// unapproved input\n', /Unknown Undici input/],
  ['transitive source', 'deps/undici/src/index-fetch.js', s => s + '\nmodule.exports.__o5Unexpected = true\n', /Regenerated Undici bundle SHA256 mismatch/],
]) {
  test(`rejects changed ${label} before modifying either source leaf or bundle`, async t => {
    const root = await fixture(t), filename = join(root, relative);
    const original = await readFile(filename, 'utf8'), modified = mutate(original);
    assert.notEqual(modified, original); await writeFile(filename, modified);
    const before = await digest(root), result = run(root);
    assert.notEqual(result.status, 0); assert.match(result.stderr, expected);
    assert.deepEqual(await digest(root), before);
  });
}

test('an Android or empty target is refused without touching source bytes', async t => {
  const root = await fixture(t), before = await digest(root);
  for (const target of ['android', '']) {
    const result = run(root, target); assert.notEqual(result.status, 0); assert.match(result.stderr, /Usage:/);
    assert.deepEqual(await digest(root), before);
  }
});

test('wrong build-tool version is rejected before source mutation', async t => {
  const root = await fixture(t), tools = join(root, 'wrong-tools'), entry = join(tools, 'node_modules/esbuild/index.js');
  await mkdir(dirname(entry), { recursive: true }); await writeFile(join(tools, 'package.json'), '{}');
  await writeFile(entry, "module.exports={version:'0.0.0'}\n");
  const before = await digest(root), result = run(root, 'ohos', tools);
  assert.notEqual(result.status, 0); assert.match(result.stderr, /esbuild 0.27.3/);
  assert.deepEqual(await digest(root), before);
});

test('a known interrupted source/bundle state is repaired to the same exact final bytes', async t => {
  const root = await fixture(t), bundle = await readFile(join(root, paths[2]));
  assert.equal(run(root).status, 0);
  await writeFile(join(root, paths[2]), bundle);
  const result = run(root); assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).recoveredKnownSourceBundleMismatch, true);
  assert.deepEqual(await digest(root), finalHashes);
});
