import assert from 'node:assert/strict';
import { mkdir, mkdtemp, realpath, rm, writeFile } from 'node:fs/promises';
import Module from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('安装包的同级依赖共用父清单的查找器', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, async t => {
  const { createRuntimeResolution } = await import(pathToFileURL(
    join(resolve(prefix), 'node_modules/@deepseek-ai/dsh-app-boot/lib/index.js')));
  const root = await mkdtemp(join(tmpdir(), 'profile-sibling-lookup-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const pkg = join(root, 'pkg');
  const anchor = join(pkg, 'package.json');
  for (const name of ['first', 'second']) {
    const dir = join(pkg, 'node_modules', name);
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, 'package.json'), JSON.stringify({ name, version: '1.0.0' }));
  }
  await writeFile(anchor, JSON.stringify({
    name: 'fixture', version: '1.0.0', dependencies: { first: '*', second: '*' },
  }));
  const canonical = await realpath(pkg);
  const parents = t.mock.method(Module, '_nodeModulePaths');
  const result = await createRuntimeResolution({ installAnchor: anchor, home: root });
  assert.deepEqual(result.entries.map(entry => entry.name), ['fixture', 'first', 'second']);
  assert.equal(parents.mock.calls.filter(call => call.arguments[0] === canonical).length, 1);
});
