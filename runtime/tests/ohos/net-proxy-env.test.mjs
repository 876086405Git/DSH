import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import { once } from 'node:events';
import { readFileSync } from 'node:fs';
import { networkInterfaces } from 'node:os';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { Worker } from 'node:worker_threads';

const netRoot = resolve(process.env.OHOS_TEST_NET_ROOT ?? fileURLToPath(new URL('../../ohos/net/', import.meta.url)));
const interfaceAddress = Object.values(networkInterfaces()).flat().find(entry => entry.family === 'IPv4' && !entry.internal)?.address;
assert.ok(interfaceAddress, 'a local non-loopback IPv4 interface is required for this actual routing fixture');

async function withDeadline(promise, milliseconds) {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('fixture deadline')), milliseconds); })]); }
  finally { clearTimeout(timer); }
}

async function check(t, config) {
  const sockets = new Set(), closures = [], seen = { origin: 0, proxy: 0, connect: 0 };
  const track = server => server.on('connection', socket => {
    sockets.add(socket);
    closures.push(new Promise(resolve => socket.once('close', () => { sockets.delete(socket); resolve(); })));
  });
  const tls = config.tls ? { cert: readFileSync(process.env.OHOS_NET_TEST_CERT), key: readFileSync(process.env.OHOS_NET_TEST_KEY) } : undefined;
  const origin = tls ? https.createServer(tls, (_q, r) => { seen.origin++; r.end('origin'); })
    : http.createServer((_q, r) => { seen.origin++; r.end('origin'); });
  const proxy = http.createServer((_q, r) => { seen.proxy++; r.end('proxy'); });
  proxy.on('connect', (_q, socket) => { seen.connect++; socket.end('HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n'); });
  track(origin); track(proxy);
  origin.listen(0, '::'); proxy.listen(0, '127.0.0.1');
  await Promise.all([once(origin, 'listening'), once(proxy, 'listening')]);
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await Promise.all([origin, proxy].map(server => new Promise(resolve => server.close(resolve))));
  });
  const proxyUrl = `http://127.0.0.1:${proxy.address().port}`;
  const host = config.host === 'interface' ? interfaceAddress : config.host;
  const target = `${config.tls ? 'https' : 'http'}://${host}:${origin.address().port}/fixture`;
  const env = { ...process.env };
  for (const key of ['HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy', 'ALL_PROXY', 'all_proxy', 'NO_PROXY', 'no_proxy', 'NODE_USE_ENV_PROXY', 'DSH_GO_OHOS_SIM']) delete env[key];
  env.HTTP_PROXY = proxyUrl; env.HTTPS_PROXY = proxyUrl;
  if (config.optIn !== undefined) env.NODE_USE_ENV_PROXY = config.optIn;
  if (config.noProxy) env.NO_PROXY = host;
  if (config.lowercase) { env.http_proxy = proxyUrl; env.HTTP_PROXY = 'http://127.0.0.1:1'; }
  const worker = new Worker(new URL('./net-proxy-env-worker.mjs', import.meta.url), {
    env, workerData: {
      netRoot, urls: config.both ? [`http://public-fixture.invalid:${origin.address().port}/fixture`, target] : [target],
      explicit: config.explicit, lookup: config.lookup, ca: tls?.cert,
      mutateProxyAfterCreation: config.mutateProxyAfterCreation,
      proxyEnv: { HTTP_PROXY: proxyUrl, HTTPS_PROXY: proxyUrl, NO_PROXY: '' },
    },
  });
  t.after(() => worker.terminate());
  const outcome = await withDeadline(new Promise((accept, reject) => { worker.once('message', accept); worker.once('error', reject); worker.once('exit', code => reject(new Error(`worker exited before report: ${code}`))); }), 6000);
  assert.equal(outcome.error, undefined, JSON.stringify(outcome));
  assert.deepEqual(outcome.bodies, config.both ? ['proxy', 'origin'] : [config.expected]);
  assert.deepEqual(seen, config.both ? { origin: 1, proxy: 1, connect: 0 } : { origin: config.expected === 'origin' ? 1 : 0, proxy: config.expected === 'proxy' ? 1 : 0, connect: 0 });
  if (config.lookup) assert.equal(outcome.lookupCalls, config.lookup === 'deny' ? 0 : 1);
  assert.equal(outcome.simulated, true);
  await withDeadline(Promise.all(closures), 1000);
  assert.equal(sockets.size, 0, 'close must release direct and proxy sockets while the worker is still alive');
  worker.postMessage('release');
}

for (const optIn of [undefined, '0']) test(`default fetch ignores ambient HTTP_PROXY when NODE_USE_ENV_PROXY=${String(optIn)}`, t => check(t, { host: 'interface', optIn, expected: 'origin' }));
test('explicit environment opt-in proxies a local non-loopback target', t => check(t, { host: 'interface', optIn: '1', expected: 'proxy' }));
test('opt-in still honors NO_PROXY for a non-loopback target', t => check(t, { host: 'interface', optIn: '1', noProxy: true, expected: 'origin' }));
test('the Node proxy option keeps lowercase environment precedence', t => check(t, { host: 'interface', optIn: '1', lowercase: true, expected: 'proxy' }));
test('an explicit factory proxy remains effective without ambient opt-in', t => check(t, { host: 'public-fixture.invalid', explicit: true, expected: 'proxy', lookup: 'deny' }));
test('factory proxy configuration is captured at creation before later caller mutations', t => check(t, { host: 'public-fixture.invalid', explicit: true, expected: 'proxy', mutateProxyAfterCreation: true }));

for (const host of ['127.0.0.1', '127.2.3.4', 'localhost', '[::1]', '[::ffff:7f00:1]', '[::ffff:127.0.0.1]', '127.1', '2130706433']) {
  test(`loopback ${host} always bypasses an opted-in proxy`, t => check(t, { host, optIn: '1', expected: 'origin' }));
}
for (const host of ['child.localhost', 'LOCALHOST.']) {
  test(`explicit lookup is preserved on the direct localhost route: ${host}`, t => check(t, { host, explicit: true, lookup: 'loopback', expected: 'origin' }));
}
test('a lookalike hostname remains proxied without local origin resolution', t => check(t, { host: 'localhost.example.invalid', explicit: true, lookup: 'deny', expected: 'proxy' }));
test('loopback HTTPS bypasses CONNECT while retaining the explicit CA', t => check(t, { host: '127.0.0.1', explicit: true, tls: true, expected: 'origin' }));
test('one dispatcher closes both its direct and proxy pools before the worker exits', t => check(t, { host: '127.0.0.1', explicit: true, both: true }));
