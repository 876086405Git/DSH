// Actual pinned HMR + ClientModuleRegistry + WebServer, with real files and HTTP.
// Only the interval clock is controlled; no product branch or FS implementation is replaced.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { createRequire } from 'node:module';
import { get } from 'node:http';
import { once } from 'node:events';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
if (!prefix) throw new Error('Set DSH_TEST_PREFIX or DSH_PREFIX to the pinned patched runtime');
const require = createRequire(join(resolve(prefix), 'package.json'));
const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
const [{ Context }, { WebServer }, { ClientModuleRegistry }, hmr] = await Promise.all([
  load('cordis'), load('dsh-host-webserver'), load('dsh-client-modules'), load('dsh-client-hmr'),
]);

async function until(predicate, message) {
  const deadline = performance.now() + 2000;
  while (!predicate()) {
    if (performance.now() >= deadline) throw new Error(message);
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

async function fixture(t) {
  const root = await fs.mkdtemp(join(tmpdir(), 'ohos-hmr-idle-'));
  const ctx = new Context(), sockets = [], serverResponses = [];
  const intervals = new Set();
  let fired = 0, disposed = false;
  t.mock.timers.enable({ apis: ['setInterval'] });
  const set = globalThis.setInterval, clear = globalThis.clearInterval;
  t.mock.method(globalThis, 'setInterval', (callback, ms, ...args) => {
    const timer = set(() => { if (ms === 500) fired++; callback(...args); }, ms);
    if (ms === 500) intervals.add(timer);
    return timer;
  });
  t.mock.method(globalThis, 'clearInterval', timer => {
    intervals.delete(timer);
    return clear(timer);
  });
  const dispose = async () => {
    if (disposed) return;
    disposed = true;
    for (const socket of sockets) socket.destroy();
    await ctx.fiber.dispose();
  };
  t.after(async () => {
    try { await dispose(); }
    finally { t.mock.restoreAll(); t.mock.timers.reset(); await fs.rm(root, { recursive: true, force: true }); }
  });
  await fs.writeFile(join(root, 'package.json'), JSON.stringify({
    name: 'ohos-hmr-idle-fixture', dsh: { client: { platform: 'web' } }, exports: { './client': './client.js' },
  }));
  await fs.writeFile(join(root, 'index.js'), '');
  const client = join(root, 'client.js');
  await fs.writeFile(client, 'globalThis.__ohosHmrIdle = true;');
  const entry = { options: { name: pathToFileURL(join(root, 'index.js')).href }, fiber: {},
    parent: { tree: { ctx: { baseUrl: pathToFileURL(root + '/').href } } } };
  ctx.provide('loader', { entries: () => [entry] });
  ctx.provide('connection', { requestRejection() {} });
  await ctx.plugin(WebServer, { host: '127.0.0.1', port: 0, compression: 'none' }).await();
  await ctx.plugin(ClientModuleRegistry).await();
  await ctx.plugin(hmr, { pollIntervalMs: 500 }).await();
  ctx.webServer.server.prependListener('request', (_req, res) => serverResponses.push(res));
  return {
    ctx, dispose,
    fired: () => fired,
    intervals: () => intervals.size,
    tick: ms => t.mock.timers.tick(ms),
    change: () => fs.appendFile(client, '\n// next build generation\n'),
    async open() {
      const frames = [];
      const response = await new Promise((resolve, reject) => {
        const request = get(ctx.webServer.getOrigin() + hmr.EVENTS_ENDPOINT, { agent: false }, resolve);
        request.on('error', reject);
        request.on('socket', socket => sockets.push(socket));
      });
      assert.equal(response.statusCode, 200);
      const server = serverResponses.at(-1);
      let pending = '';
      response.setEncoding('utf8');
      response.on('data', text => {
        pending += text;
        for (let end; (end = pending.indexOf('\n\n')) >= 0;) {
          const block = pending.slice(0, end); pending = pending.slice(end + 2);
          if (block.startsWith('data: ')) frames.push(JSON.parse(block.slice(6)));
        }
      });
      await until(() => frames.some(frame => frame.type === 'graph'), 'initial graph missing');
      return { frames, async close() { const closed = once(server, 'close'); response.destroy(); await closed; } };
    },
  };
}

test('1202 HMR: an empty-client minute has no timer wakes; first SSE catches offline changes before its graph', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  const before = f.ctx.clientModules.graph().rev;
  await f.change();
  f.tick(60_000);
  assert.equal(f.fired(), 0, 'no browser subscribes, so there must be no periodic bundle polling');
  assert.equal(f.intervals(), 0);
  const live = await f.open();
  const fresh = f.ctx.clientModules.graph().rev;
  assert.notEqual(fresh, before, 'the first connection must reconcile offline writes');
  assert.equal(live.frames.find(frame => frame.type === 'graph').graph.rev, fresh);
  assert.equal(f.intervals(), 1);
  await f.change();
  f.tick(500);
  const next = f.ctx.clientModules.graph().rev;
  assert.notEqual(next, fresh);
  await until(() => live.frames.some(frame => frame.type === 'rebuilt'), 'connected rebuild event missing');
  await live.close();
});

test('1202 HMR: two clients share one poller, last close pauses it and reconnect refreshes the graph', { timeout: 5000 }, async t => {
  const f = await fixture(t), first = await f.open(), second = await f.open();
  assert.equal(f.intervals(), 1);
  await first.close();
  f.tick(1000);
  assert.equal(f.fired(), 2, 'remaining client retains the original 500 ms cadence');
  await f.change(); f.tick(500);
  await until(() => second.frames.some(frame => frame.type === 'rebuilt'), 'remaining client lost HMR');
  await second.close();
  const closedAt = f.fired(), oldRev = f.ctx.clientModules.graph().rev;
  await f.change();
  f.tick(60_000);
  assert.equal(f.fired(), closedAt, 'last client close must stop periodic work');
  assert.equal(f.intervals(), 0);
  const again = await f.open();
  assert.notEqual(again.frames.find(frame => frame.type === 'graph').graph.rev, oldRev);
  assert.equal(f.intervals(), 1);
  await f.dispose();
  const disposedAt = f.fired();
  f.tick(60_000);
  assert.equal(f.fired(), disposedAt);
  assert.equal(f.intervals(), 0, 'plugin disposal must retire the interval');
});
