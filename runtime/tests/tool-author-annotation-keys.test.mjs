import assert from 'node:assert/strict';
import test from 'node:test';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

test('编译必填工具参数时复用已有的注解键表', async t => {
  if (!process.env.DSH_PREFIX) return t.skip('需要已部署的 DSH_PREFIX');
  const entry = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai/dsh-tools/lib/index.js');
  const { parameterSchemaSpecToJsonSchema } = await import(pathToFileURL(entry));
  const iterate = Array.prototype[Symbol.iterator];
  let copies = 0;
  Array.prototype[Symbol.iterator] = function () {
    if (this.length === 4 && this[0] === 'description' && this[1] === 'title'
        && this[2] === 'default' && this[3] === 'examples') copies++;
    return iterate.call(this);
  };
  let schema;
  try {
    schema = parameterSchemaSpecToJsonSchema({ note: { type: 'string', required: true, title: '备注' } });
  } finally {
    Array.prototype[Symbol.iterator] = iterate;
  }
  assert.equal(schema.properties.note.title, '备注');
  assert.deepEqual(schema.required, ['note']);
  assert.equal(copies, 0);
});
