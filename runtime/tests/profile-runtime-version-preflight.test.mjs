import assert from 'node:assert/strict';
import fs from 'node:fs';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('同一同步预检只读一次引擎版本，下一次预检重新读取', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, async t => {
  const boot = join(resolve(prefix), 'node_modules/@deepseek-ai/dsh-app-boot');
  const { prepareProfileEntries } = await import(pathToFileURL(join(boot, 'lib/index.js')));
  const ownManifest = fs.realpathSync(join(boot, 'package.json'));
  const root = await mkdtemp(join(tmpdir(), 'profile-runtime-version-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const profile = join(root, 'profile');
  await mkdir(profile);
  const entries = ['a', 'b'].map(name => ({ id: name, name }));
  for (const { name } of entries) {
    await writeFile(join(root, name + '.json'), JSON.stringify({ name, version: '1.0.0' }));
  }
  const services = {
    profileContext: { dir: profile },
    pluginPackages: { packageOf: name => ({ manifestPath: join(root, name + '.json') }) },
  };
  const ctx = { get: name => services[name] };
  const reads = t.mock.method(fs, 'readFileSync');
  for (const expected of [1, 2]) {
    const prepared = prepareProfileEntries(ctx, entries, pathToFileURL(profile + '/').href);
    assert.deepEqual(prepared.map(row => row.disabled === true), [false, false]);
    assert.equal(reads.mock.calls.filter(call => call.arguments[0] === ownManifest).length, expected);
  }
});
