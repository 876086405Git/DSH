import test, { after, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { openBoundaryJournal } from '../../ohos/lifecycle/journal.mjs';
import { BoundaryCoordinator } from '../../ohos/lifecycle/coordinator.mjs';
import { registerLifecycleRoutes } from '../../ohos/lifecycle/index.mjs';
import { runtimeCapabilities } from '../../ohos/capabilities/snapshot.mjs';
import { loadHostModules } from '../../../tooling/ohos/tests/lifecycle-host-fixture.mjs';
import { httpState, loadHttpTransport, listen, request } from '../../../tooling/ohos/tests/lifecycle-http-fixture.mjs';

const prefix = path.resolve(process.env.DSH_LIFECYCLE_TEST_PREFIX);
const require = createRequire(path.join(prefix, 'package.json'));
const { Context } = await import(pathToFileURL(require.resolve('@deepseek-ai/cordis')));
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const source = path.join(root, 'app/ohos/entry/src/main/ets/runtime');
const modules = await loadHostModules(source);
const { OhosLifecycleTransport } = await loadHttpTransport(source, modules.directory);
// The actual pinned authentication implementation is bundled into this one JS
// file. Export its private constructor in a private copy; do not edit the prefix.
const authInput = require.resolve('@deepseek-ai/dsh-client-connection');
const authSource = await fs.readFile(authInput, 'utf8');
assert(!/from\s+['"]\./.test(authSource));
await fs.symlink(path.join(prefix, 'node_modules'), path.join(modules.directory, 'node_modules'), 'dir');
const authFixture = path.join(modules.directory, 'actual-browser-auth.mjs');
await fs.writeFile(authFixture, authSource + '\nexport { BrowserAuth };\n');
const { BrowserAuth, HostConnectionService } = await import(pathToFileURL(authFixture));
after(() => modules.close());
afterEach(() => {
  assert.equal(httpState.active.size, 0, 'all native-boundary HTTP clients were destroyed');
  httpState.beforeReply = null; httpState.addAllowed = true; httpState.applyAllowed = true;
});
const observation = (revision, foreground, computePermission = 'denied') => ({ revision, foreground, computePermission });
const body = data => JSON.stringify({ operation: 'host', ...data });
const nativeSnapshot = foreground => ({version:1,engineGeneration:1,ownerGeneration:1,revision:1,grantGeneration:0,
  nowMs:1000,deadlineMs:0,drainAtMs:0,phase:0,available:1,foreground:foreground?1:0,clockFailed:0});
async function fixture(t, options = {}) {
  const native = nativeSnapshot(false);
  const foreground = value => { native.foreground = value ? 1 : 0; native.revision++; };
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-host-http-'));
  const journal = await openBoundaryJournal({ directory: path.join(directory, 'journal'),
    lockExclusive: process._linkedBinding('dsh_ohos_publication').lockExclusive, ...options.journal });
  await options.seedHistory?.(journal);
  const coordinator = new BoundaryCoordinator({ journal, bootId: 'actual-host-http-test',
    flushSession: async () => true, readEvents: async () => [], readHost: () => native, ...options.coordinator });
  const routes = new Map(), ctx = new Context();
  ctx.provide('webServer', { host: '127.0.0.1', protocol: 'http:', register(route) {
    routes.set(route.path, route.handler); return () => routes.delete(route.path);
  } });
  ctx.provide('ohosLifecycle', coordinator);
  const auth = new BrowserAuth(ctx, Buffer.alloc(32, 23), 1);
  const connection = new HostConnectionService(ctx, [], auth);
  (options.registerRoutes ?? registerLifecycleRoutes)(ctx, coordinator, { status: () => ({ fixture: 'HTTP transport not rotated by this adapter' }) });
  const seen = [];
  const { origin } = await listen(t, async (req, res) => {
    const url = new URL(req.url, 'http://localhost'); seen.push({ method: req.method, path: url.pathname });
    if (url.pathname === '/') {
      if (await options.login?.(req, res) === false) return;
      if (connection.authorizeIndex(req, res)) res.end('index');
    } else {
      const handler = routes.get(url.pathname);
      if (handler) await handler(req, res); else { res.writeHead(404); res.end(); }
    }
  });
  t.after(async () => { await coordinator.close(); await ctx.fiber.dispose(); await fs.rm(directory, { recursive: true, force: true }); });
  const login = async () => {
    const response = await request(origin + '/?token=' + encodeURIComponent(auth.launchToken));
    assert.equal(response.status, 303); return response.headers['set-cookie'][0].split(';')[0];
  };
  const post = (cookie, value, extraHeaders = {}) => request(origin + '/dsh-go/v1/lifecycle', {
    method: 'POST', headers: { cookie, 'content-type': 'application/json', ...extraHeaders }, body: JSON.stringify(value),
  });
  return { directory, journal, coordinator, ctx, connection, auth, origin, seen, login, post, native, foreground };
}

test('actual signed-cookie login drives durable pause/resume through production ETS and backend routes', async t => {
  const f = await fixture(t), client = new OhosLifecycleTransport();
  await client.send(f.origin, f.auth.launchToken, observation(1, false));
  assert.equal(f.coordinator.status().paused, true); assert.equal(f.coordinator.status().confirmedPause, true);
  const rows = (await fs.readFile(path.join(f.directory, 'journal/boundary.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert.deepEqual(rows.map(row => row.body.kind), ['header', 'pause']);
  f.foreground(true);
  await client.send(f.origin, f.auth.launchToken, observation(2, true, 'granted'));
  assert.equal(f.coordinator.status().paused, false);
  assert.deepEqual(f.seen, [{ method: 'GET', path: '/' }, { method: 'POST', path: '/dsh-go/v1/lifecycle' },
    { method: 'POST', path: '/dsh-go/v1/lifecycle' }]);
  const capabilities = runtimeCapabilities(f.ctx, 'cap-test');
  assert.deepEqual(capabilities.background, { policy: 'may-freeze', computePermission: 'unknown', resume: 'reconcile' });
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['header', 'pause', 'resume']);
  t.diagnostic(JSON.stringify({ actualAuthSourceSHA256: createHash('sha256').update(authSource).digest('hex'),
    realJournalRecords: f.journal.records.length, deviceHTTP: 'NOT_RUN' }));
});
test('wrong token produces no host control; arbitrary or redirected endpoints are rejected before I/O', async t => {
  const f = await fixture(t), client = new OhosLifecycleTransport();
  await assert.rejects(client.send(f.origin, 'invalid-test-token', observation(1, false)), { code: 'ohos_lifecycle_auth' });
  assert.equal(f.seen.length, 1); assert.equal(f.journal.records.length, 1);
  const before = httpState.created;
  for (const endpoint of ['https://127.0.0.1:1', 'http://localhost:1', 'http://127.0.0.1:0', 'http://127.0.0.1:65536',
    'http://127.0.0.1:80@evil.invalid', 'http://127.0.0.1:80/?x=1', 'http://[::1]:80', 'http://127.0.0.1:80/path']) {
    await assert.rejects(client.send(endpoint, 'test', observation(1, false)), { code: 'ohos_lifecycle_endpoint' });
  }
  assert.equal(httpState.created, before);
});
test('Host/Origin and signed-cookie admission precede all host changes; status GET is read-only', async t => {
  const f = await fixture(t), cookie = await f.login();
  assert.equal((await f.post('dsh-auth-forged=invalid', { operation: 'host', ...observation(1, false) })).status, 401);
  assert.equal((await f.post(cookie, { operation: 'host', ...observation(1, false) }, { origin: 'https://evil.invalid' })).status, 403);
  assert.equal((await f.post(cookie, { operation: 'host', ...observation(1, false) }, { host: 'evil.invalid' })).status, 403);
  assert.equal(f.journal.records.length, 1);
  const before = f.coordinator.status();
  for (let i = 0; i < 3; i++) {
    const status = await request(f.origin + '/dsh-go/v1/lifecycle', { headers: { cookie } }); assert.equal(status.status, 200);
    runtimeCapabilities(f.ctx, 'read-only');
  }
  assert.deepEqual(f.coordinator.status(), before); assert.equal(f.journal.records.length, 1);
});
test('malformed host observations fail closed, bounded acknowledgement omits every tool row', async t => {
  const f = await fixture(t), cookie = await f.login(), valid = { operation: 'host', ...observation(4, false) };
  for (const invalid of [{ ...valid, revision: 0 }, { ...valid, revision: 1.1 }, { ...valid, revision: 2 ** 53 },
    { ...valid, foreground: 'false' }, { ...valid, computePermission: 'allowed' }, { ...valid, sessionId: 'extra' }]) {
    assert.equal((await f.post(cookie, invalid)).status, 400);
  }
  assert.equal(f.journal.records.length, 1);
  const result = await f.post(cookie, valid); assert.equal(result.status, 200);
  const ack = JSON.parse(result.text);
  assert.deepEqual(Object.keys(ack).sort(), ['v', 'host', 'nativeHost', 'busy', 'manualPaused', 'observationRevision', 'closed', 'blocked', 'paused', 'confirmedPause', 'controlVersion'].sort());
  assert(result.text.length < 1024); assert.equal(ack.observationRevision, 4); assert.equal(ack.host.revision, f.native.revision);
});
test('duplicate/out-of-order wakeups cannot override native changes or replay resume', async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers(); let rotations = 0;
  const f = await fixture(t, { coordinator: { async revalidateTransport() { rotations++; entered.resolve(); await release.promise; } } });
  await f.coordinator.observeHost(observation(1, false)); f.foreground(true);
  const first = f.coordinator.observeHost(observation(10, true)); await entered.promise;
  const duplicate = f.coordinator.observeHost(observation(10, true));
  f.foreground(false);
  const newer = f.coordinator.observeHost(observation(11, false));
  const old = f.coordinator.observeHost(observation(9, true));
  assert.equal(f.coordinator.status().paused, true, 'new background closes admission immediately');
  const abort = new AbortController(); let enteredTool = false;
  const gated = f.coordinator.gate('session-without-replay', abort.signal).then(() => { enteredTool = true; }, () => {});
  release.resolve(); await Promise.all([first, duplicate, newer, old]);
  assert.equal(rotations, 1); assert.equal(enteredTool, false); assert.equal(f.coordinator.status().confirmedPause, true);
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['header', 'pause', 'resume', 'pause']);
  abort.abort(); await gated;
});
test('cancelling a held login settles immediately and its late response never starts a POST', async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  const f = await fixture(t, { async login() { entered.resolve(); await release.promise; } });
  const client = new OhosLifecycleTransport();
  const pending = client.send(f.origin, f.auth.launchToken, observation(1, false));
  const rejected = assert.rejects(pending, { code: 'ohos_lifecycle_cancelled' });
  await entered.promise; client.cancel(); await rejected; release.resolve();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.seen.filter(x => x.method === 'POST').length, 0); assert.equal(f.journal.records.length, 1);
});
test('cancelled response can already have applied: newer revision wins without repeating old tools or transport rotation', async t => {
  const f = await fixture(t), client = new OhosLifecycleTransport();
  const held = Promise.withResolvers(), release = Promise.withResolvers(); let heldOnce = false;
  httpState.beforeReply = async (_reply, url) => {
    if (url.endsWith('/dsh-go/v1/lifecycle') && !heldOnce) { heldOnce = true; held.resolve(); await release.promise; }
  };
  f.foreground(true);
  const old = client.send(f.origin, f.auth.launchToken, observation(1, true));
  const rejected = assert.rejects(old, { code: 'ohos_lifecycle_cancelled' });
  await held.promise; client.cancel(); await rejected;
  f.foreground(false);
  await client.send(f.origin, f.auth.launchToken, observation(2, false)); release.resolve();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.coordinator.status().paused, true); assert.equal(f.coordinator.status().host.revision, f.native.revision);
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['header', 'pause']);
});
test('a redirect is intercepted before following; unavailable guard closes the client before any request', async t => {
  let leaked = 0;
  const victim = await listen(t, (_req, res) => { leaked++; res.end(); });
  const attacker = await listen(t, async (req, res) => {
    if (req.method === 'GET') { res.writeHead(303, { location: victim.origin + '/leak', 'set-cookie': 'dsh-auth-test=fake.cookie; Path=/' }); res.end(); }
    else { const chunks = []; for await (const chunk of req) chunks.push(chunk);
      const data = JSON.parse(Buffer.concat(chunks)); res.end(JSON.stringify({ v: 1, host: {
        revision: data.revision, foreground: false, computePermission: 'unknown' }, observationRevision:data.revision, nativeHost:nativeSnapshot(false), busy:false, manualPaused:false, confirmedPause:true, closed: false, blocked: false })); }
  });
  const client = new OhosLifecycleTransport(); await client.send(attacker.origin, 'fixture-redirect-token', observation(1, false));
  assert.equal(leaked, 0);
  const count = httpState.requests.length; httpState.applyAllowed = false;
  await assert.rejects(new OhosLifecycleTransport().send(attacker.origin, 'fixture', observation(1, false)), { code: 'ohos_lifecycle_redirect_guard' });
  assert.equal(httpState.requests.length, count);
  assert(httpState.requests.every(row => row.options.usingProxy === false && row.options.usingCache === false && row.options.maxLimit === 65536));
});

test('original530 authenticated route rejects the same real host observation; new route above accepts it', async t => {
  assert(process.env.DSH_LIFECYCLE_BEFORE_ROUTE, 'Supply the byte-exact530 route preimage');
  const beforePath = path.resolve(process.env.DSH_LIFECYCLE_BEFORE_ROUTE);
  const beforeSource = await fs.readFile(beforePath);
  const { registerLifecycleRoutes: before } = await import(pathToFileURL(beforePath));
  const f = await fixture(t, { registerRoutes: before }), client = new OhosLifecycleTransport();
  await assert.rejects(client.send(f.origin, f.auth.launchToken, observation(1, false)), { code: 'ohos_lifecycle_control' });
  const cookie = await f.login(), rejected = await f.post(cookie, { operation: 'host', ...observation(1, false) });
  assert.equal(rejected.status, 400); assert.equal(f.journal.records.length, 1);
  t.diagnostic(JSON.stringify({ beforeSourceSHA256: createHash('sha256').update(beforeSource).digest('hex'), actualBeforeHTTP: rejected.status }));
});

test('manual and host pauses retain independent ownership through a foreground/background round trip', async t => {
  const f = await fixture(t), cookie = await f.login();
  assert.equal((await f.post(cookie, { operation: 'pause' })).status, 200);
  await f.coordinator.observeHost(observation(1, false));
  f.foreground(true);
  await f.coordinator.observeHost(observation(2, true));
  assert.equal(f.coordinator.status().paused, true); assert.equal(f.coordinator.status().manualPaused, true);
  assert.equal((await f.post(cookie, { operation: 'resume' })).status, 200);
  assert.equal(f.coordinator.status().paused, false);
  f.foreground(false);
  await f.coordinator.observeHost(observation(3, false));
  assert.equal((await f.post(cookie, { operation: 'resume' })).status, 200);
  assert.equal(f.coordinator.status().paused, true); assert.equal(f.coordinator.status().manualPaused, false);
  const duplicate = await f.coordinator.observeHost(observation(3, false));
  assert.equal(duplicate.controlVersion, f.coordinator.status().controlVersion);
  assert.equal(duplicate.paused, true);
  f.foreground(true);
  await f.coordinator.observeHost(observation(4, true)); assert.equal(f.coordinator.status().paused, false);
});

test('durable pause reasons restore manual intent, while a host-only pause can resume on a new process foreground', async t => {
  for (const manual of [false, true]) {
    const f = await fixture(t);
    if (manual) await f.coordinator.pause();
    await f.coordinator.observeHost(observation(1, false)); await f.coordinator.close();
    const journal = await openBoundaryJournal({ directory: path.join(f.directory, 'journal'),
      lockExclusive: process._linkedBinding('dsh_ohos_publication').lockExclusive });
    const restored = new BoundaryCoordinator({ journal, bootId: 'next-process', flushSession: async () => true, readEvents: async () => [], readHost: () => nativeSnapshot(true) });
    try {
      assert.equal(restored.status().manualPaused, manual); assert.equal(restored.status().paused, true);
      await restored.observeHost(observation(1, true)); assert.equal(restored.status().paused, manual);
      await restored.resume(); assert.equal(restored.status().paused, false);
    } finally { await restored.close(); }
  }
});

test('malformed native ACK cannot reach the owner callback as valid authority', async t => {
  const f = await fixture(t), client = new OhosLifecycleTransport();
  for (const bad of [undefined, null, {}, { ...nativeSnapshot(false), nowMs: -2 },
    { ...nativeSnapshot(false), ownerGeneration: '1' }, { ...nativeSnapshot(false), foreground: true }]) {
    httpState.beforeReply = (reply, url) => {
      if (!url.endsWith('/dsh-go/v1/lifecycle')) return;
      const ack = JSON.parse(reply.result); ack.nativeHost = bad; reply.result = JSON.stringify(ack);
    };
    await assert.rejects(client.send(f.origin, f.auth.launchToken, observation(1, false)), { code: 'ohos_lifecycle_native' });
  }
});


// The heartbeat is not a request for the per-call diagnostics view.
test('steady host heartbeat avoids detailed history projection while full queries retain it', async t => {
  const hash = '0'.repeat(64);
  const f = await fixture(t, { async seedHistory(journal) {
    for (let i = 0; i < 4; i++) {
      const identity = { sessionId: 'history-session', callId: 'history-call-' + i, name: 'fixture-tool',
        originBootId: 'history-boot', callSeq: i * 2, turn: 1, step: 1, callHash: hash };
      for (const part of [{ kind: 'prepared' }, { kind: 'outcome', result: { path: 'results/' + hash + '.json', sha256: hash, bytes: 2 } },
        { kind: 'committed', sessionResultSeq: i * 2 + 1, sessionResultHash: hash }])
        await journal.append({ bootId: 'history-boot', identity, ...part });
    }
  } });
  f.foreground(true);
  const cookie = await f.login();
  await f.post(cookie, { operation: 'host', ...observation(500, true) });
  const fullStatus = f.coordinator.status.bind(f.coordinator);
  let detailedReads = 0;
  f.coordinator.status = (...args) => { detailedReads++; return fullStatus(...args); };
  const expected = fullStatus();
  for (const revision of [501, 502, 503]) {
    const response = await f.post(cookie, { operation: 'host', ...observation(revision, false, 'granted') });
    assert.equal(response.status, 200);
    const ack = JSON.parse(response.text);
    const { v, host, nativeHost, busy, manualPaused, closed, blocked, paused, confirmedPause, controlVersion } = expected;
    assert.deepEqual(ack, { v, host, nativeHost, busy, manualPaused, observationRevision: revision, closed, blocked, paused, confirmedPause, controlVersion });
  }
  assert.equal(detailedReads, 0, 'a stable host heartbeat must not rebuild historical call diagnostics');
  const direct = await f.coordinator.observeHost(observation(504, true));
  assert.equal(direct.calls.length, 4, 'the default service API remains a full status view');
  assert.equal(detailedReads, 1);
  const get = await request(f.origin + '/dsh-go/v1/lifecycle', { headers: { cookie } });
  assert.equal(get.status, 200); assert.equal(JSON.parse(get.text).calls.length, 4);
  assert.equal(detailedReads, 2, 'an explicit GET still obtains detailed history');
});

test('host heartbeat waits for native control completion before acknowledging', async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  t.after(() => release.resolve());
  const f = await fixture(t, { coordinator: { async revalidateTransport() { entered.resolve(); await release.promise; } } });
  const cookie = await f.login();
  await f.post(cookie, { operation: 'host', ...observation(600, false) });
  f.foreground(true); let settled = false;
  const response = f.post(cookie, { operation: 'host', ...observation(601, false) }).then(value => { settled = true; return value; });
  await entered.promise; assert.equal(settled, false);
  release.resolve();
  const ack = JSON.parse((await response).text);
  assert.equal(ack.observationRevision, 601); assert.equal(ack.host.revision, f.native.revision);
  assert.equal(ack.host.foreground, true); assert.equal(ack.paused, false);
  assert.equal(ack.confirmedPause, false);
});
