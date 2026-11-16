import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { setTimeout as delay } from 'node:timers/promises';

const prefix = resolve(process.env.OHOS_TEST_DSH_PREFIX);
const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')).href);
const { Context } = await load('cordis');
const { apply } = await load('dsh-experimental-liveshare');
const { WebSocketServer } = createRequire(join(prefix, 'package.json'))('ws');
const marker = Symbol.for('dsh.go.ohos.sim');

async function observe({ ohos, mode }) {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-liveshare-owner-'));
  const ownerStateFile = join(directory, 'owner-shares.json');
  const ownerCredentialFile = join(directory, 'owner-credential.json');
  const priorMarker = Object.getOwnPropertyDescriptor(globalThis, marker);
  const ctx = new Context();
  const routes = [];
  // The actual plugin registers its HTTP routes here. No owner algorithm is replaced.
  ctx.provide('connection', { fetch: { register(...args) { routes.push(args); return () => {}; } } });
  const upgrades = [];
  const httpPaths = [];
  const server = createServer((request, response) => {
    httpPaths.push(new URL(request.url, 'http://localhost').pathname);
    response.setHeader('content-type', 'application/json');
    if (request.url.startsWith('/__liveshare/owner-credential')) response.end(JSON.stringify({ supported: true }));
    else if (request.url.startsWith('/__liveshare/share/claim')) response.end(JSON.stringify({ claimed: true }));
    else if (request.url === '/') response.end('{}');
    else { response.statusCode = 503; response.end('{}'); }
  });
  const sockets = new Set();
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  const wss = new WebSocketServer({ noServer: true });
  server.on('upgrade', (request, socket, head) => {
    const url = new URL(request.url, 'http://localhost');
    // A private loopback relay accepts only this fixture's explicit synthetic receipt.
    if (url.pathname !== '/__tunnel_gateway__' || request.headers['x-liveshare-owner-credential'] !== 'fixture-owner') {
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      return;
    }
    upgrades.push({ path: url.pathname, shareId: url.searchParams.get('shareId') });
    wss.handleUpgrade(request, socket, head, peer => wss.emit('connection', peer, request));
  });
  let stop;
  let observation;
  let primary;
  const cleanupErrors = [];
  try {
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const relay = `http://127.0.0.1:${server.address().port}`;
    const saved = {
      shareId: 'saved-fixture', sessionId: 'fixture-session', sessionTitle: 'fixture',
      relay, gatewayToken: 'fixture-gateway', accessMode: 'open', allowedSubjectIds: [],
      sessionMode: 'view', allowsFork: false, createdAt: '2026-01-01T00:00:00.000Z',
    };
    const originalState = JSON.stringify({ instanceId: 'fixture-instance', relayUrl: relay, shares: mode === 'restore' ? [saved] : [] });
    await writeFile(ownerStateFile, originalState);
    await writeFile(ownerCredentialFile, JSON.stringify({ relay, credential: 'fixture-owner', subjectId: 'fixture-subject' }));
    if (ohos) globalThis[marker] = true;
    else delete globalThis[marker];
    stop = await apply(ctx, { ownerStateFile, ownerCredentialFile, allowedSubjectIds: [] });
    const api = ctx.get('liveshareShares');
    assert.ok(api, 'the complete original plugin must register its public service');
    const connectivity = await api.testRelay();
    const identity = await api.identity({});
    let publish;
    let created;
    if (mode === 'create') {
      publish = await api.testPublish({ sessionId: 'fixture-session' });
      try { created = { ok: true, value: await api.create({ sessionId: 'fixture-session' }) }; }
      catch (error) { created = { ok: false, code: error.code, message: error.message }; }
    }
    // A bounded observation for the original saved-share startup path; not a lifetime claim.
    if (mode === 'restore') await delay(1000);
    const listed = await api.list();
    observation = {
      ohos, mode, connectivity, identityState: identity.state,
      publish, created, upgrades: [...upgrades], httpPaths: [...httpPaths],
      shares: listed.shares, savedBytesUnchanged: (await readFile(ownerStateFile, 'utf8')) === originalState,
      registeredHttpRoutes: routes.length,
    };
  } catch (error) { primary = error; }
  finally {
    try { if (stop) await stop(); } catch (error) { cleanupErrors.push(`plugin: ${error.message}`); }
    try { await ctx.fiber.dispose(); } catch (error) { cleanupErrors.push(`context: ${error.message}`); }
    for (const peer of wss.clients) peer.terminate();
    try { await new Promise(resolveClose => wss.close(resolveClose)); } catch (error) { cleanupErrors.push(`websocket: ${error.message}`); }
    for (const socket of sockets) socket.destroy();
    try { await new Promise(resolveClose => server.close(resolveClose)); } catch (error) { cleanupErrors.push(`http: ${error.message}`); }
    if (priorMarker) Object.defineProperty(globalThis, marker, priorMarker);
    else delete globalThis[marker];
    try { await rm(directory, { recursive: true, force: true }); } catch (error) { cleanupErrors.push(`files: ${error.message}`); }
  }
  console.log(JSON.stringify({ liveshareObservation: observation, cleanupErrors, primary: primary?.message }));
  if (primary) throw primary;
  assert.deepEqual(cleanupErrors, []);
  return observation;
}

test('OH empty optional plugin retains relay/identity APIs without an owner worker', { timeout: 30000 }, async () => {
  const result = await observe({ ohos: true, mode: 'empty' });
  assert.equal(result.connectivity.ok, true);
  assert.equal(result.identityState, 'verified');
  assert.deepEqual(result.upgrades, []);
  assert.deepEqual(result.shares, []);
  assert.equal(result.savedBytesUnchanged, true);
});

test('non-OH public publish/create still reaches the real gateway subprocess and local relay', { timeout: 30000 }, async () => {
  const result = await observe({ ohos: false, mode: 'create' });
  assert.equal(result.publish.ok, true);
  assert.equal(result.created.ok, true);
  assert.equal(result.upgrades.length, 2);
  assert.equal(result.shares.length, 1);
});

test('OH public publish/create reports local owner IPC unavailable without a gateway', { timeout: 30000 }, async () => {
  const result = await observe({ ohos: true, mode: 'create' });
  assert.equal(result.publish.ok, false);
  assert.equal(result.publish.blocking, true);
  assert.match(result.publish.error, /OpenHarmony.*owner.*IPC.*computer/i);
  assert.equal(result.created.ok, false);
  assert.equal(result.created.code, 'liveshareShares/relay-unavailable');
  assert.match(result.created.message, /OpenHarmony.*owner.*IPC.*computer/i);
  assert.deepEqual(result.upgrades, []);
  assert.deepEqual(result.shares, []);
  assert.equal(result.savedBytesUnchanged, true);
});

test('OH saved-share recovery retains its record offline without creating a gateway', { timeout: 30000 }, async () => {
  const result = await observe({ ohos: true, mode: 'restore' });
  assert.equal(result.connectivity.ok, true);
  assert.equal(result.shares.length, 1);
  assert.equal(result.shares[0].shareId, 'saved-fixture');
  assert.equal(result.shares[0].online, false);
  assert.equal(result.savedBytesUnchanged, true);
  assert.deepEqual(result.upgrades, []);
});
