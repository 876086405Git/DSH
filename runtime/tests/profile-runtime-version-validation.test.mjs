import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('默认和显式运行版本在插件兼容性检查中各验证一次', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, async t => {
  const boot = join(resolve(prefix), 'node_modules/@deepseek-ai/dsh-app-boot/lib/index.js');
  const { evaluatePluginCompatibility } = await import(pathToFileURL(boot));
  const valid = t.mock.method(createRequire(boot)('semver'), 'valid');
  assert.equal(evaluatePluginCompatibility({}), undefined);
  assert.equal(valid.mock.callCount(), 1);
  assert.equal(evaluatePluginCompatibility({}, {}, 'v1.2.3+build'), undefined);
  assert.equal(valid.mock.callCount(), 2);
});
