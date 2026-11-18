'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const { createRequire } = require('node:module');
const { join } = require('node:path');

const [prefix, workspace, expected] = process.argv.slice(2);
const requireAt = createRequire(join(prefix, 'package.json'));
assert.equal(process.platform, 'openharmony');
assert.equal(typeof WebAssembly, 'undefined');

(async () => {
  if (expected) {
    assert.throws(() => requireAt('node-addon-require-builtin'), { code: expected });
    console.log(JSON.stringify({ status: 'PASS', expectedRejection: expected }));
    return;
  }
  const api = requireAt('node-addon-require-builtin');
  const info = api.getBindingInfo();
  assert.equal(info.product, 'require-builtin');
  assert.equal(info.backend, 'napi');
  assert.equal(info.abi, 'napi-v9');
  assert.equal(info.bindingSource, 'ohos-hap-libs');
  assert.ok(info.bindingPath.endsWith('/libdsh_require_builtin.so'));
  assert.equal(typeof api.requireBuiltin('internal/modules/esm/loader').getOrInitializeCascadedLoader, 'function');
  const helper = requireAt('@dsh-go/ohos-native');
  assert.throws(() => helper.load('internal-loader'), { code: 'ERR_OHOS_NATIVE_PRODUCT' });
  const { tryLockExclusive } = await import(requireAt.resolve('@deepseek-ai/node-addon-system/flock'));
  await fs.mkdir(workspace, { recursive: true });
  const file = join(workspace, '中文锁文件');
  const first = await fs.open(file, 'a+'), second = await fs.open(file, 'a+');
  try {
    await tryLockExclusive(first.fd);
    await assert.rejects(tryLockExclusive(second.fd), error =>
      ['EAGAIN', 'EWOULDBLOCK'].includes(error.code) && error.errno > 0 && error.syscall === 'flock');
  } finally { await first.close(); await second.close(); }
  const third = await fs.open(file, 'a+');
  try { await tryLockExclusive(third.fd); } finally { await third.close(); }
  assert.equal(helper.load('flock'), helper.load('flock'));
  console.log(JSON.stringify({ status: 'PASS', loader: info, flock: 'actual contention and close-release',
    scope: 'Linux actual addons in separate .so directory under strict simulation; not HAP loading' }));
})().catch(error => { console.error(error); process.exitCode = 1; });
