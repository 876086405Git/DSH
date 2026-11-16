import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { calls } from './linux-http-fixture.mjs';
import { LinuxControl as NodeLinuxControl } from '../../../runtime/ohos/linux/control.mjs';

const source = new URL('../../../app/ohos/entry/src/main/ets/runtime/', import.meta.url);
const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-linux-control-'));
after(() => fs.rm(directory, { recursive: true, force: true }));
await fs.copyFile(new URL('RuntimeCore.ets', source), path.join(directory, 'RuntimeCore.mts'));
const ets = await fs.readFile(new URL('LinuxControl.ets', source), 'utf8');
await fs.writeFile(path.join(directory, 'LinuxControl.mts'), ets
  .replace("import http from '@ohos.net.http';", `import { http } from '${new URL('./linux-http-fixture.mjs', import.meta.url).href}';`)
  .replace("from './RuntimeCore'", "from './RuntimeCore.mts'"));
const { LinuxControl } = await import(pathToFileURL(path.join(directory, 'LinuxControl.mts')));

const snapshot = (extra = {}) => ({ v: 1, instanceId: 'service-930', attemptId: null, state: 'disabled',
  enabled: false, admission: false, guestOpened: false, ownerRetained: false, workspaceLease: false,
  restartRequired: false, shutdownComplete: false, nextRequestId: 1, ownerState: null, backendState: null,
  progress: null, lastErrorCode: null, job: null, retirement: null, ...extra });
const retired = (extra = {}) => ({ resourcesRetired: true, filesRemoved: false, dataRetained: true,
  ownerQuarantined: true, native: { joined: true, retirementError: false, apiResult: -4 },
  releaseErrorCode: null, ...extra });
const deferred = () => Promise.withResolvers();

async function serverFor(body) {
  const observed = [];
  const server = createServer(async (request, response) => {
    const chunks = []; for await (const bytes of request) chunks.push(bytes);
    const item = { url: request.url, method: request.method, headers: request.headers,
      body: chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : null };
    observed.push(item);
    if (request.url === '/?token=test-only-token') {
      response.writeHead(303, { 'set-cookie': 'dsh-auth-fixture=session.value; HttpOnly; Path=/', location: '/' });
      response.end(); return;
    }
    assert.equal(request.url, '/dsh-go/v1/linux');
    assert.equal(request.headers.cookie, 'dsh-auth-fixture=session.value');
    try { await body(item, response); }
    catch (error) { response.destroy(error); }
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  return { url: 'http://127.0.0.1:' + server.address().port, observed,
    close: async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); } };
}
function reply(response, status, value) {
  response.writeHead(status, { 'content-type': 'application/json' }); response.end(JSON.stringify(value));
}

test('status authenticates to fixed loopback without preparing or posting', async () => {
  calls.length = 0;
  const fixture = await serverFor((_request, response) => reply(response, 200, snapshot()));
  try {
    const client = new LinuxControl();
    const actual = JSON.parse(await client.getStatus(fixture.url, 'test-only-token'));
    assert.equal(actual.state, 'disabled');
    await client.getStatus(fixture.url, 'test-only-token');
    assert.deepEqual(fixture.observed.map(row => row.method), ['GET', 'GET', 'GET']);
    assert.equal(fixture.observed.filter(row => row.url.startsWith('/?token=')).length, 1);
    assert.ok(calls.every(row => row.redirectAllowed === false && row.destroyed));
    assert.ok(calls.every(row => row.options.usingCache === false && row.options.usingProxy === false && row.options.maxLimit === 65536));
    assert.equal(fixture.observed[1].headers.authorization, undefined);
  } finally { await fixture.close(); }
});

test('untrusted endpoints are refused before any HTTP handle is created', async () => {
  const client = new LinuxControl(), before = calls.length;
  for (const url of ['https://127.0.0.1:80', 'http://localhost:80', 'http://127.0.0.1:0',
    'http://127.0.0.1:65536', 'http://127.0.0.1:80/path', 'http://user@127.0.0.1:80']) {
    await assert.rejects(client.getStatus(url, 'test-only-token'), { code: 'ohos_linux_endpoint' });
  }
  assert.equal(calls.length, before);
});

test('enable is accepted asynchronously, and run preserves the supplied identity and bytes', async () => {
  const fixture = await serverFor((request, response) => reply(response, request.method === 'POST' ? 202 : 200,
    snapshot(request.body?.action === 'setEnabled' ? { state: 'installing', enabled: true, attemptId: 'attempt-930' } : {})));
  try {
    const client = new LinuxControl();
    const accepted = JSON.parse(await client.setEnabled(fixture.url, 'test-only-token', true));
    assert.equal(accepted.state, 'installing'); assert.equal(accepted.admission, false);
    const request = { v: 1, instanceId: 'service-930', attemptId: 'attempt-930', action: 'runPrivateGuest',
      requestId: 7, argv: ['python3', '-c', 'print("中文")'], cwd: '/workspace', env: { TEST_VALUE: 'a b' }, stdin: 'input\n' };
    await client.runPrivateGuest(fixture.url, 'test-only-token', request);
    assert.deepEqual(fixture.observed.at(-1).body, request);
    assert.deepEqual(fixture.observed.find(row => row.body?.action === 'setEnabled').body,
      { v: 1, instanceId: 'service-930', attemptId: null, action: 'setEnabled', enabled: true });
  } finally { await fixture.close(); }
});

test('shutdown waits for the actual retirement observation after 202', async () => {
  const entered = deferred(), release = deferred(); let stopping = false, done = false;
  const fixture = await serverFor(async (request, response) => {
    if (request.method === 'POST') { stopping = true; reply(response, 202, snapshot({ state: 'stopping' })); }
    else if (stopping) {
      entered.resolve(); await release.promise;
      // Historical job failure can coexist with proven native/resource retirement.
      reply(response, 200, snapshot({ state: 'unknown', shutdownComplete: true, retirement: retired() }));
    } else reply(response, 200, snapshot({ state: 'enabled', enabled: true, admission: true, guestOpened: true }));
  });
  try {
    const client = new LinuxControl();
    const waiting = client.shutdown(fixture.url, 'test-only-token').then(() => { done = true; });
    await entered.promise; assert.equal(done, false);
    release.resolve(); await waiting; assert.equal(done, true);
    assert.equal(fixture.observed.filter(row => row.body?.action === 'shutdown').length, 1);
  } finally { release.resolve(); await fixture.close(); }
});

test('installation cleanup does not replace final shutdown completion over HTTP', async t => {
  // The controller and ETS client are production code. Installation/Native and
  // SDK HTTP/authentication are explicit fixtures; no guest or Native is loaded.
  const disposed = deferred(), trace = [], wire = [];
  let cleanup;
  const owner = {
    state: 'created', nativeOwnerCreated: false,
    async install() {
      trace.push('install'); this.state = 'failed';
      throw Object.assign(new Error('fixture installation unavailable'), { code: 'ERR_OHOS_LINUX_DOWNLOAD' });
    },
    dispose() {
      trace.push('dispose');
      return cleanup ??= Promise.resolve().then(() => {
        trace.push('cleanup'); this.state = 'disposed'; disposed.resolve();
        return { resourcesRetired: true, filesRemoved: true, dataRetained: false,
          ownerQuarantined: false, native: null, releaseError: null };
      });
    },
  };
  const control = new NodeLinuxControl({ hostPaths: { filesDir: directory, cacheDir: directory } }, {
    async loadModule() { return {
      async loadLinuxInstallationManifest() { return {}; },
      createLinuxInstallationOwner() { return owner; },
    }; },
  });
  const fixture = await serverFor((request, response) => {
    // Preserve the production command -> synchronous JSON response order.
    const value = request.method === 'POST' ? control.command(request.body) : control.status();
    wire.push({ method: request.method, action: request.body?.action ?? null,
      value: JSON.parse(JSON.stringify(value)) });
    reply(response, request.method === 'POST' ? 202 : 200, value);
  });
  try {
    const client = new LinuxControl();
    const accepted = JSON.parse(await client.setEnabled(fixture.url, 'test-only-token', true));
    assert.equal(accepted.state, 'installing');
    await disposed.promise;
    const failed = JSON.parse(await client.getStatus(fixture.url, 'test-only-token'));
    assert.equal(failed.state, 'failed'); assert.equal(failed.ownerRetained, true);
    assert.equal(failed.shutdownComplete, false); assert.equal(failed.retirement.resourcesRetired, true);
    assert.equal(failed.retirement.native, null); assert.equal(failed.nativeMemoryRelease, null);
    let shutdownError;
    try { await client.shutdown(fixture.url, 'test-only-token'); }
    catch (error) { shutdownError = error; }
    const posts = wire.filter(row => row.action === 'shutdown');
    assert.equal(posts.length, 1);
    assert.equal(posts[0].value.instanceId, failed.instanceId);
    assert.equal(posts[0].value.shutdownComplete, false);
    assert.deepEqual(posts[0].value.retirement, failed.retirement);
    assert.equal(shutdownError, undefined, 'historical confirmed cleanup must not reject final shutdown');
    const last = wire.at(-1);
    assert.equal(last.method, 'GET'); assert.equal(last.value.instanceId, failed.instanceId);
    assert.equal(last.value.shutdownComplete, true);
    assert.equal(last.value.retirement.resourcesRetired, true);
    assert.deepEqual(trace, ['install', 'dispose', 'cleanup', 'dispose']);
  } finally {
    await control.shutdown();
    await fixture.close();
    t.diagnostic(JSON.stringify({ trace, wire }));
  }
});

test('missing join, retirement errors and changed instance never confirm shutdown', async () => {
  const cases = [
    { value: snapshot({ shutdownComplete: true, retirement: null }), code: 'ohos_linux_shutdown_unconfirmed' },
    { value: snapshot({ shutdownComplete: true, retirement: retired({ native: { joined: false, retirementError: false, apiResult: 0 } }) }), code: 'ohos_linux_shutdown_unconfirmed' },
    { value: snapshot({ shutdownComplete: true, retirement: retired({ native: { joined: true, retirementError: true, apiResult: -8 } }) }), code: 'ohos_linux_shutdown_unconfirmed' },
    { value: snapshot({ state: 'unknown', retirement: retired({ resourcesRetired: false }) }), code: 'ohos_linux_shutdown_unconfirmed' },
    { value: snapshot({ instanceId: 'replacement', shutdownComplete: true, retirement: retired() }), code: 'ohos_linux_stale' },
  ];
  for (const item of cases) {
    const fixture = await serverFor((request, response) => reply(response, request.method === 'POST' ? 202 : 200,
      request.method === 'POST' ? item.value : snapshot()));
    try { await assert.rejects(new LinuxControl().shutdown(fixture.url, 'test-only-token'), { code: item.code }); }
    finally { await fixture.close(); }
  }
});

test('HTTP failures preserve the error code, destroy handles and never retry a run', async () => {
  const fixture = await serverFor((_request, response) => reply(response, 409,
    { v: 1, error: { code: 'ERR_OHOS_LINUX_REQUEST_REUSED', message: 'must not surface this text' } }));
  try {
    const client = new LinuxControl();
    await assert.rejects(client.runPrivateGuest(fixture.url, 'test-only-token', { action: 'runPrivateGuest', requestId: 3 }),
      error => error.code === 'ERR_OHOS_LINUX_REQUEST_REUSED' && !error.message.includes('must not surface'));
    assert.equal(fixture.observed.filter(row => row.method === 'POST').length, 1);
    assert.ok(calls.every(row => row.destroyed));
  } finally { await fixture.close(); }
});

test('actual native unjoined null facts stay visible without confirming release', async () => {
  const value = snapshot({ state: 'unknown', retirement: retired({ resourcesRetired: false,
    native: { joined: false, retirementError: null, apiResult: null } }) });
  const fixture = await serverFor((_request, response) => reply(response, 200, value));
  try {
    const observed = JSON.parse(await new LinuxControl().getStatus(fixture.url, 'test-only-token'));
    assert.equal(observed.state, 'unknown'); assert.equal(observed.shutdownComplete, false);
    assert.deepEqual(observed.retirement.native, value.retirement.native);
  } finally { await fixture.close(); }
});

test('a clean checkpoint requires guest sync, native retirement and retained disk facts', async () => {
  const guestClose = { epoch: 'b'.repeat(64), rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' };
  const clean = retired({ guestClose, cleanCheckpoint: true });
  const cases = [
    { ...clean, guestClose: null }, { ...clean, guestClose: { ...guestClose, rootfsSync: false } },
    { ...clean, guestClose: { ...guestClose, syncMethod: 'sync' } },
    { ...clean, guestClose: { ...guestClose, epoch: 'old' } },
    { ...clean, resourcesRetired: false }, { ...clean, dataRetained: false }, { ...clean, filesRemoved: true },
    { ...clean, native: null }, { ...clean, native: { ...clean.native, apiResult: 0 } },
    { ...clean, native: { ...clean.native, joined: false } },
    { ...clean, native: { ...clean.native, retirementError: true } },
  ];
  for (const retirement of cases) {
    const fixture = await serverFor((_request, response) => reply(response, 200, snapshot({ retirement,
      persistentInstanceId: '2f887aa7-437e-49b6-bbde-4e30d899d3cc', bootMode: 'resume' })));
    try { await assert.rejects(new LinuxControl().getStatus(fixture.url, 'test-only-token'), { code: 'ohos_linux_protocol' }); }
    finally { await fixture.close(); }
  }
});

test('persistence observations retain install versus resume and an unconfirmed checkpoint', async () => {
  const guestClose = { epoch: 'b'.repeat(64), rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' };
  const value = snapshot({ persistentInstanceId: '2f887aa7-437e-49b6-bbde-4e30d899d3cc', bootMode: 'resume',
    retirement: retired({ guestClose, cleanCheckpoint: false, releaseErrorCode: 'EIO' }), shutdownComplete: true });
  for (const cleanCheckpoint of [false, true]) {
    value.retirement.cleanCheckpoint = cleanCheckpoint;
    value.retirement.releaseErrorCode = cleanCheckpoint ? null : 'EIO';
    const fixture = await serverFor((_request, response) => reply(response, 200, value));
    try { assert.deepEqual(JSON.parse(await new LinuxControl().getStatus(fixture.url, 'test-only-token')), value); }
    finally { await fixture.close(); }
  }
});


test('native memory lifetime crosses the actual HTTP decoder without accepting a false freed claim', async () => {
  for (const value of ['freed', false, 85, {}]) {
    const f = await serverFor((_request, response) => reply(response, 200, snapshot({ nativeMemoryRelease: value })));
    try { await assert.rejects(new LinuxControl().getStatus(f.url, 'test-only-token'), { code: 'ohos_linux_protocol' }); }
    finally { await f.close(); }
  }
  for (const value of [undefined, null, 'process-exit']) {
    const f = await serverFor((_request, response) => reply(response, 200, snapshot({ nativeMemoryRelease: value })));
    try { const observed = JSON.parse(await new LinuxControl().getStatus(f.url, 'test-only-token'));
      assert.equal(observed.nativeMemoryRelease ?? null, value ?? null); }
    finally { await f.close(); }
  }
});

test('proxy configuration uses the current trusted identity while responses contain only safe facts', async () => {
  const proxy = { mode: 'manual', httpProxy: 'http://127.0.0.1:3128', noProxy: 'fixture.invalid' };
  const facts = { source: 'manual', revision: 1, httpConfigured: true, httpsConfigured: true };
  const fixture = await serverFor((request, response) => reply(response, request.method === 'POST' ? 202 : 200,
    snapshot({ proxy: request.method === 'POST' ? facts : { source: 'inherit', revision: 0, httpConfigured: false, httpsConfigured: false } })));
  try {
    const client = new LinuxControl();
    const actual = JSON.parse(await client.setProxy(fixture.url, 'test-only-token', proxy));
    assert.deepEqual(actual.proxy, facts);
    assert.deepEqual(fixture.observed.at(-1).body,
      { v: 1, instanceId: 'service-930', attemptId: null, action: 'setProxy', proxy });
    assert.ok(calls.every(row => row.options.usingProxy === false));
  } finally { await fixture.close(); }
});

test('proxy response rejects configuration strings, invalid revisions and contradictory facts', async () => {
  const safe = { source: 'manual', revision: 1, httpConfigured: true, httpsConfigured: true };
  for (const proxy of [
    { ...safe, httpProxy: 'http://private.invalid:3128' }, { ...safe, noProxy: 'private.invalid' },
    { ...safe, source: 'future' }, { ...safe, revision: -1 }, { ...safe, revision: 9007199254740992 },
    { ...safe, httpConfigured: 'yes' }, { ...safe, source: 'direct' },
    { ...safe, httpConfigured: false, httpsConfigured: false },
  ]) {
    const fixture = await serverFor((_request, response) => reply(response, 200, snapshot({ proxy })));
    try { await assert.rejects(new LinuxControl().getStatus(fixture.url, 'test-only-token'), { code: 'ohos_linux_protocol' }); }
    finally { await fixture.close(); }
  }
});

test('重新安装 Linux: discardRetained sends the current identity, waits for the deletion and keeps refusal codes', async () => {
  let discards = 0;
  const control = new NodeLinuxControl({ hostPaths: { directory: directory + '/linux-tools', nativeLibraryDirectory: '/trusted/native' } }, {
    async loadModule() { return { async discardLinuxInstallation(input) {
      discards++; assert.deepEqual(input, { directory: directory + '/linux-tools' }); return { removed: 1 };
    } }; },
  });
  const fixture = await serverFor(async (request, response) => {
    if (request.method === 'GET') { reply(response, 200, control.status()); return; }
    // Preserve the production route: the discard reply comes after the deletion.
    try { reply(response, request.body.action === 'discardRetained' ? 200 : 202, await control.command(request.body)); }
    catch (error) { reply(response, 409, { v: 1, error: { code: error.code, message: 'Conflict' }, status: control.status() }); }
  });
  try {
    calls.length = 0;
    const client = new LinuxControl();
    const done = JSON.parse(await client.discardRetained(fixture.url, 'test-only-token'));
    assert.equal(done.state, 'disabled'); assert.equal(done.lastErrorCode, null); assert.equal(discards, 1);
    assert.deepEqual(fixture.observed.find(row => row.method === 'POST').body,
      { v: 1, instanceId: done.instanceId, attemptId: null, action: 'discardRetained' });
    const post = calls.find(row => row.options.method === 'POST');
    assert.equal(post.options.readTimeout, 60000); assert.ok(post.destroyed);
    assert.ok(calls.filter(row => row.options.method === 'GET' && !row.url.includes('token=')).every(row => row.options.readTimeout === 5000));
  } finally { await control.shutdown(); await fixture.close(); }
  const refused = await serverFor((request, response) => request.method === 'GET' ? reply(response, 200, snapshot())
    : reply(response, 409, { v: 1, error: { code: 'ERR_OHOS_LINUX_RESTART_REQUIRED', message: 'must not surface this text' } }));
  try {
    await assert.rejects(new LinuxControl().discardRetained(refused.url, 'test-only-token'),
      error => error.code === 'ERR_OHOS_LINUX_RESTART_REQUIRED' && !error.message.includes('must not surface'));
    assert.equal(refused.observed.filter(row => row.method === 'POST').length, 1);
  } finally { await refused.close(); }
});
