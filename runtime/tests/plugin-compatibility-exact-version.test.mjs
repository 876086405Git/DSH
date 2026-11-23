import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('精确相等的插件版本直接通过，区间仍交给 semver', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, async t => {
  const boot = join(resolve(prefix), 'node_modules/@deepseek-ai/dsh-app-boot/lib/index.js');
  const semver = createRequire(boot)('semver');
  const { evaluatePluginCompatibility } = await import(pathToFileURL(boot));
  const matches = t.mock.method(semver, 'satisfies');
  const version = '0.2.2-rc.1';
  const plugin = { name: 'sample', version: '1.0.0' };
  const check = range => evaluatePluginCompatibility({ ...plugin, engines: { dsh: range } }, {}, version);
  assert.equal(check(version), undefined);
  assert.equal(matches.mock.callCount(), 0);
  assert.deepEqual(check('>=1.0.0').requirements, { 'engines.dsh': '>=1.0.0' });
  assert.equal(matches.mock.callCount(), 1);
});
