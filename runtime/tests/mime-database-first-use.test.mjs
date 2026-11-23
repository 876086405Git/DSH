import assert from 'node:assert/strict';
import { createRequire, registerHooks } from 'node:module';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('文件控制器及 gzip 共享的 MIME 库在首次类型判断时读取一次', {
  skip: !prefix && '请设置 DSH_TEST_PREFIX 指向已准备的引擎',
}, async () => {
  const root = resolve(prefix);
  const require = createRequire(join(root, 'package.json'));
  let reads = 0;
  const hook = registerHooks({ load(url, context, next) {
    if (url.endsWith('/mime-db/db.json')) reads++;
    return next(url, context);
  } });
  try {
    await import(pathToFileURL(join(root, 'node_modules/@deepseek-ai/dsh-api-session-controller/lib/index.js')));
    const compression = require('compression');
    assert.equal(reads, 0);
    assert.equal(compression.filter({}, { getHeader: () => 'application/javascript' }), true);
    assert.equal(require('mime-types').lookup('example.js'), 'text/javascript');
    assert.equal(reads, 1);
  } finally { hook.deregister(); }
});
