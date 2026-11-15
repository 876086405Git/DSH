import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { setTimeout as wait } from 'node:timers/promises';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { bootstrapDshNetwork } from '../../ohos/net/bootstrap.mjs';
import { createHttpDispatcher } from '../../ohos/net/dispatcher.mjs';
import { createLifecycleTransport } from '../../ohos/lifecycle/transport.mjs';
import { ActiveBudgetClock } from '../../ohos/lifecycle/budget.mjs';

const prefix = resolve(process.env.DSH_LIFECYCLE_TEST_PREFIX);
const network = bootstrapDshNetwork(join(prefix, 'node_modules/@deepseek-ai/dsh/lib/bin.js'));
const transport = createLifecycleTransport(network);
const require = createRequire(join(prefix, 'package.json'));
const undici = require('undici');
after(async () => { transport.close(); await network.dispatcher.destroy(); });
async function server(t, handler) {
  const instance = http.createServer(handler); instance.listen(0, '127.0.0.1');
  await once(instance, 'listening');
  t.after(async () => { instance.closeAllConnections(); await new Promise(resolve => instance.close(resolve)); });
  return `http://127.0.0.1:${instance.address().port}`;
}

test('real active response completes through the old owner; resume makes a fresh socket and never replays a POST', async t => {
  const finish = Promise.withResolvers(), observed = [];
  const url = await server(t, async (req, res) => {
    observed.push({ path: req.url, method: req.method, port: req.socket.remotePort });
    if (req.url === '/hold') {
      res.writeHead(200, { 'content-type': 'text/plain' }); res.write('first-');
      await finish.promise; res.end('last');
    } else res.end('fresh');
  });
  const response = await network.fetch(url + '/hold', { method: 'POST', body: 'single-effect' });
  const reading = response.text();
  const previous = network.dispatcher;
  const state = await transport.revalidate();
  assert.notEqual(network.dispatcher, previous);
  assert.equal(undici.getGlobalDispatcher(), network.dispatcher);
  assert.equal(state.retiredInFlight, 1);
  assert.equal(await (await network.fetch(url + '/new')).text(), 'fresh');
  assert.notEqual(observed[0].port, observed[1].port);
  finish.resolve(); assert.equal(await reading, 'first-last');
  await wait(0);
  assert.equal(observed.filter(row => row.method === 'POST').length, 1);
  assert.equal(transport.status().retiredInFlight, 0);
});

test('actual Undici global custom dispatcher and explicit per-request dispatcher survive default rotation', async t => {
  const url = await server(t, (_req, res) => res.end('custom'));
  const custom = createHttpDispatcher(), originalDispatch = custom.dispatch;
  let calls = 0;
  custom.dispatch = function (...args) { calls++; return originalDispatch.apply(this, args); };
  undici.setGlobalDispatcher(custom);
  try {
    const before = network.dispatcher;
    const state = await transport.revalidate();
    assert.notEqual(network.dispatcher, before);
    assert.equal(state.globalDispatcher, 'custom-preserved');
    assert.equal(undici.getGlobalDispatcher(), custom);
    const reply = await undici.request(url); assert.equal(await reply.body.text(), 'custom');
    assert.equal(await (await network.fetch(url, { dispatcher: custom })).text(), 'custom');
    assert.equal(calls, 2);
  } finally { undici.setGlobalDispatcher(network.dispatcher); await custom.destroy(); }
});

test('real server expiry follows wall time while activity is paused; failed authorization produces no second effect', async t => {
  let token, expiresAt, effects = 0, attempts = 0;
  const url = await server(t, (req, res) => {
    if (req.url === '/issue') {
      token = randomUUID(); expiresAt = Date.now() + 120;
      res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ token, expiresAt })); return;
    }
    attempts++;
    if (req.headers.authorization !== 'Bearer ' + token || Date.now() >= expiresAt) { res.writeHead(401); res.end('expired'); return; }
    effects++; res.end('accepted');
  });
  const issued = await (await network.fetch(url + '/issue')).json();
  const headers = { authorization: 'Bearer ' + issued.token };
  assert.equal((await network.fetch(url + '/write', { method: 'POST', headers })).status, 200);
  const clock = new ActiveBudgetClock('wall-token-test'); clock.pause();
  const activity = clock.now(); await wait(170);
  assert.equal(clock.now(), activity); assert(Date.now() >= issued.expiresAt);
  await transport.revalidate(); clock.resume();
  assert.equal((await network.fetch(url + '/write', { method: 'POST', headers })).status, 401);
  assert.equal(attempts, 2); assert.equal(effects, 1); clock.dispose();
});

test('actual DSH policy wrapper renews its real proxy connections in place and drains an accepted POST', async t => {
  const { installProxyFromEnvironment, proxyRouteFor } = await import(require.resolve('@deepseek-ai/dsh-http-proxy'));
  const finish = Promise.withResolvers(), observed = [];
  const proxy = await server(t, async (req, res) => {
    observed.push({ url: req.url, method: req.method, port: req.socket.remotePort });
    if (req.url.endsWith('/hold')) {
      res.writeHead(200); res.write('proxy-first-'); await finish.promise; res.end('last');
    } else res.end('proxy-fresh');
  });
  const restore = await installProxyFromEnvironment(new Map([['http_proxy', { value: proxy }], ['no_proxy', { value: '' }]]), () => {});
  const policyOwner = network.dispatcher, target = 'http://ohos-lifecycle.invalid';
  const route = proxyRouteFor(target);
  const custom = createHttpDispatcher();
  try {
    const response = await network.fetch(target + '/hold', { method: 'POST', body: 'only-once' });
    const reading = response.text();
    undici.setGlobalDispatcher(custom);
    const state = await transport.revalidate();
    assert.equal(network.dispatcher, policyOwner);
    assert.equal(undici.getGlobalDispatcher(), custom);
    assert.equal(state.defaultDispatcher, 'policy-connections-renewed');
    assert.equal(state.retiredInFlight, 1);
    assert.deepEqual(proxyRouteFor(target), route);
    assert.equal(await (await network.fetch(target + '/new')).text(), 'proxy-fresh');
    assert.notEqual(observed[0].port, observed[1].port);
    assert.equal(observed[1].url, target + '/new');
    finish.resolve(); assert.equal(await reading, 'proxy-first-last');
    await wait(0);
    assert.equal(observed.filter(row => row.method === 'POST').length, 1);
    assert.equal(transport.status().retiredInFlight, 0);
  } finally { finish.resolve(); await restore(); await custom.destroy(); }
});
