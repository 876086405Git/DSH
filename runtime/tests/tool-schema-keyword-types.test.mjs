import assert from 'node:assert/strict';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('校验标量工具模式时复用关键字类型表', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, async t => {
  const file = join(resolve(prefix), 'node_modules/@deepseek-ai/dsh-tools/lib/index.js');
  const { assertSupportedJsonSchema } = await import(pathToFileURL(file));
  const entries = t.mock.method(Object, 'entries');
  assertSupportedJsonSchema({ type: 'integer', enum: [1, 2], const: 1 });
  assert.equal(entries.mock.callCount(), 0);
  assert.throws(() => assertSupportedJsonSchema({ type: 'integer', items: {} }), error =>
    error.violations.includes('schema.items is not supported on type "integer"'));
});
