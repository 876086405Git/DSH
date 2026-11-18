import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, rm, access, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const round = fileURLToPath(new URL('../../ohos/sim/round.mjs', import.meta.url));
test('linked publication fixture rejects invalid inputs before creating a measurement case', async t => {
  const base = await mkdtemp(join(tmpdir(), 'publication-measure-inputs-'));
  t.after(() => rm(base, { recursive: true, force: true }));
  const directory = join(base, 'directory.so');
  await mkdir(directory);
  const wrongType = join(base, 'not-a-library.txt');
  const separated = join(base, 'space name.so');
  const colon = join(base, 'colon:name.so');
  const apparent = join(base, 'safe-link.so');
  await Promise.all([wrongType, separated, colon].map(path => writeFile(path, 'not executed')));
  await symlink(separated, apparent);
  const inputs = [
    ['relative.so', 'sim', 'requires an absolute'],
    [directory, 'sim', 'requires a regular'],
    [wrongType, 'sim', 'requires a regular'],
    [separated, 'sim', 'without LD_PRELOAD separators'],
    [colon, 'sim', 'without LD_PRELOAD separators'],
    [apparent, 'sim', 'without LD_PRELOAD separators'],
    [join(base, 'missing.so'), 'jit', 'ENOENT'],
  ];
  for (const [index, [input, mode, message]] of inputs.entries()) {
    const out = join(base, `case-${index}`);
    const env = { ...process.env };
    delete env.LD_PRELOAD; delete env.NODE_OPTIONS;
    const result = spawnSync(process.execPath, [round, '--prefix', base, '--out', out,
      '--mode', mode, '--linked-publication-fixture', input], { env, encoding: 'utf8' });
    assert.equal(result.status, 1, result.stderr);
    assert.ok(result.stderr.includes(message), result.stderr);
    assert.equal(await access(out).then(() => true, () => false), false, 'case must not be created');
  }
});
