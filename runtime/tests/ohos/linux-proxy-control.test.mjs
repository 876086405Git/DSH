import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { LinuxControl } from '../../ohos/linux/control.mjs';
import * as installation from '../../ohos/linux/owner.mjs';
import { ownerFixture, until } from './linux-control-fixture.mjs';

const proxyNames = ['HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy',
  'ALL_PROXY', 'all_proxy', 'NO_PROXY', 'no_proxy', 'NODE_USE_ENV_PROXY'];
function parentProxy(t, values = {}) {
  const before = Object.fromEntries(proxyNames.map(key => [key, process.env[key]]));
  for (const key of proxyNames) delete process.env[key];
  Object.assign(process.env, values);
  t.after(() => { for (const key of proxyNames) {
    if (before[key] === undefined) delete process.env[key]; else process.env[key] = before[key];
  } });
}
async function fixture(t) {
  const f = await ownerFixture(t); let loads = 0;
  const control = new LinuxControl({ hostPaths: { directory: f.data, nativeLibraryDirectory: '/trusted/native' },
    assetsDirectory: f.assets }, { async loadModule() {
    loads++;
    return { loadLinuxInstallationManifest: installation.loadLinuxInstallationManifest,
      createLinuxInstallationOwner: options => f.createOwner(options) };
  } });
  const command = (action, fields = {}) => { const current = control.status();
    return control.command({ v: 1, instanceId: current.instanceId, attemptId: current.attemptId, action, ...fields }); };
  const request = (fields = {}) => ({ requestId: control.status().nextRequestId,
    argv: ['python3', '-c', 'print(1)'], cwd: '/workspace', env: {}, stdin: '', ...fields });
  const enable = async () => { command('setEnabled', { enabled: true }); await until(() => control.status().admission); };
  const started = async count => {
    await until(() => f.peer.commands.filter(value => value.op === 'start').length === count);
    return f.peer.admitted();
  };
  const complete = async start => { await f.peer.complete(start.job); await until(() => control.status().job?.state === 'settled'); };
  return { ...f, control, command, request, enable, started, complete, loads: () => loads };
}

test('inherited App IPv4 loopback proxy reaches the production guest wire as the host alias', async t => {
  parentProxy(t, { http_proxy: 'http://127.0.0.1:18993', HTTP_PROXY: 'http://127.0.0.1:18993' });
  const f = await fixture(t); await f.enable();
  f.command('runPrivateGuest', f.request());
  const start = await f.started(1);
  const mapped = new URL(start.env.http_proxy);
  assert.equal(mapped.hostname, '10.0.2.2'); assert.equal(mapped.port, '18993');
  assert.equal(start.env.HTTP_PROXY, start.env.http_proxy);
  await f.complete(start); await f.control.shutdown();
});

test('inherited proxy bypass includes domestic sources and keeps explicit caller bypasses', async t => {
  parentProxy(t, { HTTPS_PROXY: 'http://proxy.fixture.invalid:8080', NO_PROXY: 'parent.fixture.invalid' });
  const f = await fixture(t); await f.enable();
  f.command('runPrivateGuest', f.request({ env: { no_proxy: 'caller.fixture.invalid' } }));
  const start = await f.started(1), entries = new Set(start.env.no_proxy.split(','));
  for (const host of ['gitee.com', '.gitee.com', 'huaweicloud.com', '.huaweicloud.com', 'localhost', '127.0.0.1',
    'parent.fixture.invalid', 'caller.fixture.invalid']) assert.ok(entries.has(host), 'required bypass entry is present');
  assert.equal(start.env.NO_PROXY, start.env.no_proxy);
  await f.complete(start); await f.control.shutdown();
});

test('proxy configuration and read-only status do not load the guest and expose only bounded facts', async t => {
  parentProxy(t);
  const f = await fixture(t), password = randomBytes(24).toString('hex');
  const proxy = { mode: 'manual', httpProxy: 'http://fixture-user:' + password + '@proxy.fixture.invalid:8080', noProxy: 'custom.fixture.invalid' };
  const before = f.control.status();
  assert.deepEqual(before.proxy, { source: 'inherit', revision: 0, httpConfigured: false, httpsConfigured: false });
  const after = f.command('setProxy', { proxy });
  assert.deepEqual(after.proxy, { source: 'manual', revision: 1, httpConfigured: true, httpsConfigured: true });
  assert.equal(f.loads(), 0); assert.equal(f.counts().created, 0);
  const encoded = JSON.stringify(after);
  assert.equal(encoded.includes(password), false, 'status never contains proxy credentials');
  assert.equal(encoded.includes('proxy.fixture.invalid'), false, 'status never contains a proxy URL or host');
  assert.equal(encoded.includes('custom.fixture.invalid'), false, 'status never contains the user bypass list');
  assert.equal(f.command('setProxy', { proxy }).proxy.revision, 1, 'identical setting is idempotent');
  await f.control.shutdown();
  assert.throws(() => f.command('setProxy', { proxy: { mode: 'direct' } }), { code: 'ERR_OHOS_LINUX_CLOSED' });
});

test('manual policy replaces all inherited aliases and freezes the accepted job revision', async t => {
  parentProxy(t, { http_proxy: 'http://old.fixture.invalid', HTTPS_PROXY: 'http://old.fixture.invalid',
    ALL_PROXY: 'http://fallback.fixture.invalid', all_proxy: 'http://fallback.fixture.invalid', NO_PROXY: 'old.fixture.invalid' });
  const f = await fixture(t); await f.enable();
  f.command('setProxy', { proxy: { mode: 'manual', httpProxy: 'http://localhost:18994', noProxy: 'keep.fixture.invalid' } });
  const request = f.request(); f.command('runPrivateGuest', request);
  const start = await f.started(1);
  for (const key of ['HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy']) assert.equal(start.env[key], 'http://10.0.2.2:18994/');
  for (const key of ['ALL_PROXY', 'all_proxy']) assert.equal(Object.hasOwn(start.env, key), false);
  assert.equal(start.env.NO_PROXY, start.env.no_proxy); assert.ok(start.env.NO_PROXY.includes('keep.fixture.invalid'));
  assert.equal(f.control.status().job.proxyRevision, 1);
  f.command('setProxy', { proxy: { mode: 'direct' } });
  const retry = f.command('runPrivateGuest', request);
  assert.equal(retry.proxy.revision, 2); assert.equal(retry.job.proxyRevision, 1);
  assert.equal(f.peer.commands.filter(value => value.op === 'start').length, 1);
  await f.complete(start); await f.control.shutdown();
});

test('direct clears inherited proxy aliases and both configured modes reject explicit proxy conflicts', async t => {
  parentProxy(t, Object.fromEntries(proxyNames.map(key => [key, key === 'NODE_USE_ENV_PROXY' ? '1' : 'http://old.fixture.invalid'])));
  const f = await fixture(t); await f.enable();
  f.command('setProxy', { proxy: { mode: 'direct' } });
  f.command('runPrivateGuest', f.request());
  const start = await f.started(1);
  for (const key of proxyNames) assert.equal(Object.hasOwn(start.env, key), false, 'direct removes proxy-related inherited aliases');
  await f.complete(start);
  for (const mode of ['direct', 'manual']) {
    f.command('setProxy', { proxy: { mode, ...(mode === 'manual' ? { httpProxy: 'http://proxy.fixture.invalid:8080' } : {}) } });
    for (const key of proxyNames) assert.throws(() => f.command('runPrivateGuest', f.request({ env: { [key]: 'explicit' } })),
      error => error.code === 'ERR_OHOS_LINUX_PROXY_ENV_CONFLICT' && error.status === 400);
  }
  assert.equal(f.peer.commands.filter(value => value.op === 'start').length, 1);
  await f.control.shutdown();
});

test('an inherited explicit request is deduplicated before a later manual conflict check', async t => {
  parentProxy(t);
  const f = await fixture(t); await f.enable();
  const request = f.request({ env: { HTTPS_PROXY: 'http://explicit.fixture.invalid:8080' } });
  f.command('runPrivateGuest', request); const start = await f.started(1);
  assert.equal(start.env.HTTPS_PROXY, request.env.HTTPS_PROXY);
  f.command('setProxy', { proxy: { mode: 'manual', httpsProxy: 'http://new.fixture.invalid:8080' } });
  const retry = f.command('runPrivateGuest', request);
  assert.equal(retry.job.id, request.requestId); assert.equal(retry.job.proxyRevision, 0);
  assert.equal(f.peer.commands.filter(value => value.op === 'start').length, 1);
  await f.complete(start);
  assert.equal(f.command('runPrivateGuest', request).job.id, request.requestId);
  assert.throws(() => f.command('runPrivateGuest', f.request({ env: request.env })), { code: 'ERR_OHOS_LINUX_PROXY_ENV_CONFLICT' });
  await f.control.shutdown();
});

test('manual invalid and ambiguous endpoint forms fail before owner work without echoing userinfo', async t => {
  parentProxy(t); const f = await fixture(t), password = randomBytes(24).toString('hex');
  for (const value of ['socks5://fixture.invalid:1080', 'https://localhost:8080', 'https://127.0.0.1:8080',
    'http://127.0.0.2:8080', 'http://[::1]:8080', 'http://proxy.fixture.invalid/path', 'http://proxy.fixture.invalid/?query=1',
    'http://user:' + password + '@[::1]:8080']) {
    let caught;
    try { f.command('setProxy', { proxy: { mode: 'manual', httpProxy: value } }); } catch (error) { caught = error; }
    assert.ok(caught && caught.status === 400, 'invalid proxy setting is refused');
    assert.equal(String(caught?.message).includes(password), false, 'configuration errors do not echo credentials');
  }
  assert.equal(f.loads(), 0); assert.equal(f.counts().created, 0); await f.control.shutdown();
});
