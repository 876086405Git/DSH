import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, rmSync, symlinkSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const sim = new URL('../../ohos/sim/preload.mjs', import.meta.url).pathname;
const store = new URL('../../ohos/plugins/store.mjs', import.meta.url).href;
const saved = ['package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'cordis.patch.yml', 'compatibility.json'];
function fixture(t, phase, before = null) {
  const dir = mkdtempSync(join(tmpdir(), 'ohos-linkless-recovery-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const root = join(dir, '.plugin-manager/ohos'), generation = 'generation-Old123';
  mkdirSync(join(root, 'generations', generation, '.package-old'), { recursive: true });
  writeFileSync(join(dir, 'package.json'), '{"dependencies":{"fixture":"1"}}');
  const files = saved.map(name => ({ name, bytes: name === 'package.json' ? Buffer.from('{"dependencies":{}}\n').toString('base64') : null }));
  const record = { schema: 1, phase: 'pending', files,
    links: phase === 'before-link' ? [] : [{ name: 'fixture', before, after: `../.plugin-manager/ohos/generations/${generation}/.package-old` }],
    created: [generation] };
  writeFileSync(join(root, 'transaction.json'), JSON.stringify(record));
  return { dir, root };
}

test('strict simulation denies all public symbolic-link APIs and hard-link APIs', () => {
  const code = `
    import fs from 'node:fs'; import fsp from 'node:fs/promises'; import assert from 'node:assert/strict';
    import { symlinkSync, symlink } from 'node:fs';
    for (const call of [() => fs.symlinkSync('a','b'), () => symlinkSync('a','b'), () => fs.linkSync('a','b')])
      assert.throws(call, { code: 'EACCES' });
    for (const call of [() => fsp.symlink('a','b'), () => fsp.link('a','b'),
      () => new Promise((resolve,reject) => symlink('a','b', error => error ? reject(error) : resolve())),
      () => new Promise((resolve,reject) => fs.symlink('a','b','dir', error => error ? reject(error) : resolve())),
      () => new Promise((resolve,reject) => fs.link('a','b', error => error ? reject(error) : resolve()))])
      await assert.rejects(call(), { code: 'EACCES' });
  `;
  const result = spawnSync(process.execPath, ['--jitless', '--import', sim, '--input-type=module', '-e', code], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  for (const name of ['fs.symlink', 'fs.symlinkSync', 'fs.promises.symlink', 'fs.link', 'fs.linkSync', 'fs.promises.link'])
    assert.ok(result.stderr.includes(`"operation":"${name}"`), name);
});

for (const phase of ['before-link', 'failed-link']) test(`old device schema1 ${phase} recovers twice without creating any link`, t => {
  const { dir, root } = fixture(t, phase);
  const code = `import { recoverProfile } from ${JSON.stringify(store)}; recoverProfile(${JSON.stringify(dir)}); recoverProfile(${JSON.stringify(dir)});`;
  const result = spawnSync(process.execPath, ['--jitless', '--import', sim, '--input-type=module', '-e', code], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr.includes('[ohos-sim]'), false, 'recovery must never attempt link creation');
  assert.equal(readFileSync(join(dir, 'package.json'), 'utf8'), '{"dependencies":{}}\n');
  assert.deepEqual(readdirSync(join(root, 'generations')), []);
  assert.equal(existsSync(join(root, 'transaction.json')), false);
});

test('an imported old successful-link journal is rejected before changing any saved bytes', t => {
  const { dir, root } = fixture(t, 'failed-link', '../.plugin-manager/ohos/generations/generation-Existing/.package-old');
  const before = readFileSync(join(root, 'transaction.json')), manifest = readFileSync(join(dir, 'package.json'));
  const code = `import { recoverProfile } from ${JSON.stringify(store)};
    import assert from 'node:assert/strict'; assert.throws(() => recoverProfile(${JSON.stringify(dir)}), /保留现场/);`;
  const result = spawnSync(process.execPath, ['--jitless', '--import', sim, '--input-type=module', '-e', code], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(readFileSync(join(root, 'transaction.json')), before);
  assert.deepEqual(readFileSync(join(dir, 'package.json')), manifest);
  assert.deepEqual(readdirSync(join(root, 'generations')), ['generation-Old123']);
});


test('committed legacy links retain the journal when rejecting an imported old layout', t => {
  const { dir, root } = fixture(t, 'failed-link');
  const record = JSON.parse(readFileSync(join(root, 'transaction.json')));
  record.phase = 'committed';
  mkdirSync(join(dir, 'node_modules'));
  symlinkSync(record.links[0].after, join(dir, 'node_modules/fixture'));
  writeFileSync(join(root, 'transaction.json'), JSON.stringify(record));
  const before = readFileSync(join(root, 'transaction.json'));
  const code = `import { recoverProfile } from ${JSON.stringify(store)};
    import assert from 'node:assert/strict'; assert.throws(() => recoverProfile(${JSON.stringify(dir)}), /保留现场/);`;
  const result = spawnSync(process.execPath, ['--jitless', '--import', sim, '--input-type=module', '-e', code], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(readFileSync(join(root, 'transaction.json')), before);
});
