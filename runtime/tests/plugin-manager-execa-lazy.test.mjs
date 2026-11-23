import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('加载插件管理服务并解析包名时无需启动子进程模块', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, async () => {
  let loads = 0;
  const hook = registerHooks({
    resolve(specifier, context, next) {
      if (specifier === 'execa') loads++;
      return next(specifier, context);
    },
  });
  try {
    const entry = join(resolve(prefix), 'node_modules/@deepseek-ai/dsh-plugin-manager/lib/index.js');
    const { parseInstallSpec } = await import(pathToFileURL(entry));
    assert.equal(parseInstallSpec('sample-plugin@1.0.0').kind, 'registry');
    assert.equal(loads, 0);
  } finally { hook.deregister(); }
});
