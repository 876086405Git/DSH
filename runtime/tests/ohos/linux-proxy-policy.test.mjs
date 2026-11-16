import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { bootstrapDshNetwork } from '../../ohos/net/bootstrap.mjs';

// Install through the actual locked public proxy API, in the same startup order
// as the OHOS launcher. This is policy/env coverage, not a remote-network test.
const require = createRequire(new URL('../../ohos/process/runtime.mjs', import.meta.url));
const packageFile = require.resolve('@deepseek-ai/dsh/package.json');
bootstrapDshNetwork(join(dirname(packageFile), require(packageFile).bin.dsh));
const { installProxyFromEnvironment, proxyEnvironmentForChild } = require('@deepseek-ai/dsh-http-proxy');
const { LinuxProxyPolicy } = await import('../../ohos/linux/proxy.mjs');
const aliases = ['http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY', 'no_proxy', 'NO_PROXY', 'NODE_USE_ENV_PROXY'];

async function ambient(values, run) {
  const before = Object.fromEntries(aliases.map(name => [name, process.env[name]]));
  for (const name of aliases) { if (values[name] === undefined) delete process.env[name]; else process.env[name] = values[name]; }
  try { await run(); }
  finally { for (const name of aliases) { if (before[name] === undefined) delete process.env[name]; else process.env[name] = before[name]; } }
}

test('direct removes all ambient aliases even when the actual active policy is unconfigured', async () => {
  await ambient(Object.fromEntries(aliases.map(name => [name, name.toLowerCase().includes('no_proxy') ? 'stale.invalid' :
    name === 'NODE_USE_ENV_PROXY' ? '1' : 'http://stale.invalid:3128'])), async () => {
    const dispose = await installProxyFromEnvironment(new Map(), () => assert.fail('unexpected proxy diagnostic'));
    try {
      assert.deepEqual(proxyEnvironmentForChild(), {});
      const policy = new LinuxProxyPolicy(); policy.set({ mode: 'direct' });
      const frozen = policy.forRequest({ ORDINARY: 'kept' });
      assert.equal(frozen.environment.ORDINARY, 'kept');
      assert.ok(aliases.every(name => Object.hasOwn(frozen.environment, name) && frozen.environment[name] === undefined));
      assert.deepEqual(policy.status(), { source: 'direct', revision: 1, httpConfigured: false, httpsConfigured: false });
    } finally { await dispose(); }
  });
});

test('inherit consumes the actual installed policy, then maps only its App loopback endpoint', async () => {
  await ambient({}, async () => {
    const dispose = await installProxyFromEnvironment(new Map([
      ['HTTP_PROXY', { value: 'http://127.0.0.1:3128' }], ['NO_PROXY', { value: 'policy.invalid' }],
    ]), () => assert.fail('unexpected proxy diagnostic'));
    try {
      assert.ok(Object.keys(proxyEnvironmentForChild()).length > 0);
      const policy = new LinuxProxyPolicy(), frozen = policy.forRequest({});
      assert.equal(new URL(frozen.environment.HTTP_PROXY).hostname, '10.0.2.2');
      assert.equal(new URL(frozen.environment.HTTPS_PROXY).hostname, '10.0.2.2');
      for (const host of ['policy.invalid', 'gitee.com', '.gitee.com', 'huaweicloud.com', '.huaweicloud.com']) {
        assert.ok(frozen.environment.NO_PROXY.split(',').includes(host));
      }
      assert.deepEqual(policy.status(), { source: 'inherit', revision: 0, httpConfigured: true, httpsConfigured: true });
    } finally { await dispose(); }
  });
});

test('whole no-proxy wildcard remains meaningful to existing non-Node clients', () => {
  const policy = new LinuxProxyPolicy();
  policy.set({ mode: 'manual', httpProxy: 'http://proxy.invalid:3128', noProxy: '*' });
  assert.equal(policy.forRequest({}).environment.NO_PROXY, '*');
});

test('URL normalization cannot hide unsupported loopback address semantics', () => {
  const policy = new LinuxProxyPolicy();
  for (const httpProxy of ['http://2130706434:3128', 'http://127.2:3128', 'https://127.1:3128', 'http://[::1]:3128']) {
    assert.throws(() => policy.set({ mode: 'manual', httpProxy }), { code: 'ERR_OHOS_LINUX_PROXY_ADDRESS' });
  }
  policy.set({ mode: 'manual', httpProxy: 'http://127.1:3128' });
  assert.equal(new URL(policy.forRequest({}).environment.HTTP_PROXY).hostname, '10.0.2.2');
});
