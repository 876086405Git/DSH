import assert from 'node:assert/strict';
import { createRequire, registerHooks } from 'node:module';
import { join, resolve } from 'node:path';
import test from 'node:test';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('OTel 的 Node SDK 读取稳定属性无需加载公共聚合入口', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, () => {
  const require = createRequire(join(resolve(prefix), 'package.json'));
  const entries = [];
  const hook = registerHooks({
    load(url, context, next) {
      if (url.includes('/@opentelemetry/semantic-conventions/dist/')) entries.push(url.split('/').at(-1));
      return next(url, context);
    },
  });
  try {
    require('@opentelemetry/sdk-logs');
    assert.deepEqual(entries, ['stable_attributes.cjs']);
  } finally { hook.deregister(); }
});
