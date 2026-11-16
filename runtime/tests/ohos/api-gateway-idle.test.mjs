// Real Cordis, WebServer, gateway and WebSockets; only interval time is controlled.
// Connection admission is an explicit peer fixture, not an authentication test.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { once } from 'node:events';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
if (!prefix) throw new Error('Set DSH_TEST_PREFIX or DSH_PREFIX to the pinned patched runtime');
const require = createRequire(join(resolve(prefix), 'package.json'));
const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
const [{ Context }, { WebServer }, { TypertGatewayService }, { REMOTE_STREAM_MUX_PATH }] = await Promise.all([
  load('cordis'), load('dsh-host-webserver'), load('dsh-api-gateway'), load('dsh-api-gateway/stream-protocol'),
]);
const { default: WebSocket } = await import(pathToFileURL(require.resolve('ws')));

async function until(predicate, message) {
  const deadline = performance.now() + 2000;
  while (!predicate()) {
    if (performance.now() >= deadline) throw new Error(message);
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

async function fixture(t) {
  const ctx = new Context(), clients = [], peers = new Set(), timers = new Set();
  let fired = 0, disposed = false;
  t.mock.timers.enable({ apis: ['setInterval'] });
  const set = globalThis.setInterval, clear = globalThis.clearInterval;
  t.mock.method(globalThis, 'setInterval', (callback, ms, ...args) => {
    const timer = set(() => { if (ms === 2000) fired++; callback(...args); }, ms);
    if (ms === 2000) timers.add(timer);
    return timer;
  });
  t.mock.method(globalThis, 'clearInterval', timer => { timers.delete(timer); return clear(timer); });
  const dispose = async () => {
    if (disposed) return;
    disposed = true;
    for (const client of clients) client.socket.terminate();
    await ctx.fiber.dispose();
  };
  t.after(async () => {
    try { await dispose(); }
    finally { t.mock.restoreAll(); t.mock.timers.reset(); }
  });
  ctx.provide('typert', {});
  ctx.provide('remoteAccess', {});
  const connection = {
    requestRejection() {},
    rpc: { intercept() { return () => {}; } },
    admitConnection() {
      const peer = new Context();
      peers.add(peer);
      return { peer: { ctx: peer }, async release() { await peer.fiber.dispose(); peers.delete(peer); } };
    },
  };
  ctx.provide('connection', connection);
  await ctx.plugin(WebServer, { host: '127.0.0.1', port: 0, compression: 'none' }).await();
  const gateway = ctx.plugin(TypertGatewayService, { websocketHeartbeatIntervalMs: 2000,
    streamInboxBytes: 262144, websocketCompression: 'none' });
  await gateway.await();
  return {
    ctx, dispose, retireGateway: () => gateway.dispose(), tick: ms => t.mock.timers.tick(ms),
    setConnection: available => ctx.set('connection', available ? connection : undefined),
    fired: () => fired, timers: () => timers.size, peers: () => peers.size,
    async open(options = {}) {
      const socket = new WebSocket(ctx.webServer.getOrigin().replace('http:', 'ws:') + REMOTE_STREAM_MUX_PATH, options);
      const client = { socket, pings: 0, closed: false };
      clients.push(client);
      socket.on('ping', () => client.pings++);
      socket.on('close', () => { client.closed = true; });
      await once(socket, 'open');
      return client;
    },
    async close(client) {
      const closed = once(client.socket, 'close');
      client.socket.close();
      await closed;
      await new Promise(resolve => setImmediate(resolve));
    },
  };
}

test('gateway has no idle heartbeat before its first WebSocket', async t => {
  const f = await fixture(t);
  f.tick(60000);
  assert.equal(f.fired(), 0);
  assert.equal(f.timers(), 0);
});

test('last WebSocket close stops all heartbeat callbacks during an idle minute', async t => {
  const f = await fixture(t), client = await f.open();
  assert.equal(f.timers(), 1);
  f.tick(2000);
  await until(() => client.pings === 1, 'first real ping not received');
  await f.close(client);
  await until(() => f.peers() === 0, 'peer scope did not retire');
  const before = f.fired();
  f.tick(60000);
  assert.equal(f.fired() - before, 0, 'an empty gateway must not wake every two seconds');
  assert.equal(f.timers(), 0);
});

test('two clients share one heartbeat and reconnect starts one fresh heartbeat', async t => {
  const f = await fixture(t), first = await f.open(), second = await f.open();
  assert.equal(f.timers(), 1);
  f.tick(2000);
  await until(() => first.pings === 1 && second.pings === 1, 'both sockets must receive a ping');
  await f.close(first);
  assert.equal(f.timers(), 1, 'the remaining live socket still needs heartbeat');
  f.tick(2000);
  await until(() => second.pings === 2, 'remaining socket lost heartbeat');
  await f.close(second);
  await until(() => f.peers() === 0, 'both peer scopes did not retire');
  const before = f.fired();
  f.tick(60000);
  assert.equal(f.fired() - before, 0);
  const third = await f.open();
  assert.equal(f.timers(), 1);
  f.tick(1999);
  assert.equal(third.pings, 0);
  f.tick(1);
  await until(() => third.pings === 1, 'reconnected socket lost heartbeat');
  assert.equal(f.fired() - before, 1);
  await f.close(third);
  await until(() => f.peers() === 0, 'reconnected peer did not retire');
  assert.equal(f.timers(), 0);
});

test('unresponsive socket is still terminated after the existing missed-heartbeat bound', async t => {
  const f = await fixture(t), client = await f.open({ autoPong: false });
  f.tick(2000);
  await until(() => client.pings === 1, 'first ping missing');
  f.tick(2000);
  await until(() => client.pings === 2, 'second ping missing');
  assert.equal(client.closed, false);
  f.tick(2000);
  await until(() => client.closed && f.peers() === 0, 'unresponsive peer was not terminated');
  const before = f.fired();
  f.tick(60000);
  assert.equal(f.fired() - before, 0);
  assert.equal(f.timers(), 0);
});

test('gateway disposal closes live sockets and cancels its heartbeat', async t => {
  const f = await fixture(t), client = await f.open();
  await f.retireGateway();
  await until(() => client.closed && f.peers() === 0, 'socket survived gateway disposal');
  const before = f.fired();
  f.tick(60000);
  assert.equal(f.fired() - before, 0);
  assert.equal(f.timers(), 0);
  assert.equal(f.peers(), 0);
});

test('a captured upgrade resumed after gateway disposal cannot restart heartbeat', async t => {
  const f = await fixture(t);
  // Public Cordis service availability leaves WebServer's real guard waiting.
  f.setConnection(false);
  const arrived = once(f.ctx.webServer.server, 'upgrade');
  const pending = f.open();
  pending.catch(() => {});
  await arrived;
  await f.retireGateway();
  assert.equal(f.ctx.webServer.upgrades.has(REMOTE_STREAM_MUX_PATH), false);
  f.setConnection(true);
  // The retired Cordis route context rejects late dispatch; WebServer closes the carrier.
  await assert.rejects(pending, { code: 'ECONNRESET' });
  await until(() => f.peers() === 0, 'late upgrade peer was not released');
  f.tick(60000);
  assert.equal(f.fired(), 0);
  assert.equal(f.timers(), 0);
});
