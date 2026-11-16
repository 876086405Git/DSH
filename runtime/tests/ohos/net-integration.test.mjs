import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import fs from 'node:fs';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHttpDispatcher } from '../../ohos/net/dispatcher.mjs';
import { bootstrapDshNetwork } from '../../ohos/net/bootstrap.mjs';

assert.ok(process.env.OHOS_TEST_DSH_PREFIX, 'OHOS_TEST_DSH_PREFIX must name a separately patched npm-ci tree');
const prefix = resolve(process.env.OHOS_TEST_DSH_PREFIX);
const fromPackage = (file) => import(pathToFileURL(join(prefix, 'node_modules', file)).href);
const nativeFetch = globalThis.fetch;
const network = bootstrapDshNetwork(join(prefix, 'node_modules/@deepseek-ai/dsh/lib/bin.js'));
assert.ok(network, 'enable the OHOS runtime or explicitly preload sim/marker.mjs');
const undici = await fromPackage('undici/index.js');
const { EventSource } = await fromPackage('eventsource/dist/index.js');
const { installProxyFromEnvironment, proxyRouteFor, proxyEnvironmentForChild } = await fromPackage('@deepseek-ai/dsh-http-proxy/lib/index.js');
const { HttpFetchProvider } = await fromPackage('@deepseek-ai/dsh-web-fetch-http/lib/index.js');
const limits = { maxResponseBytes: 10000, maxBodyChars: 10000, timeoutMs: 1000, maxRedirects: 3, userAgent: 'ohos-local-test' };
const env = (values) => new Map(Object.entries(values).map(([name, value]) => [name, { value }]));

async function serve(t, listener, tls) {
  const server = tls ? https.createServer(tls, listener) : http.createServer(listener);
  const sockets = new Set();
  server.on('connection', (socket) => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise((done) => server.close(done));
  });
  return { server, port: server.address().port, url: `${tls ? 'https' : 'http'}://127.0.0.1:${server.address().port}` };
}

async function policy(t, values = {}) {
  const dispose = await installProxyFromEnvironment(env(values), () => {});
  t.after(dispose);
  return dispose;
}

test('locked Undici 8 and native Undici 7 share the public global dispatcher', async (t) => {
  const { url } = await serve(t, (_q, r) => r.end('ok'));
  await policy(t);
  assert.equal(await (await nativeFetch(url)).text(), 'ok');
  assert.equal(await (await undici.fetch(url)).text(), 'ok');
  assert.equal(await (await fetch(url)).text(), 'ok');
});

test('locked Undici 8 RetryAgent retries a transport error instead of classifying it as explicit abort', async (t) => {
  let requests = 0;
  const { url } = await serve(t, (q, r) => {
    if (++requests === 1) q.socket.destroy();
    else r.end('recovered');
  });
  const dispatcher = new undici.RetryAgent(createHttpDispatcher(), { maxRetries: 1, minTimeout: 1, maxTimeout: 1 });
  t.after(() => dispatcher.close());
  const response = await undici.request(url, { dispatcher });
  assert.equal(await response.body.text(), 'recovered');
  assert.equal(requests, 2);
});

test('v8 controller preserves the first explicit abort reason and never sends the pre-aborted request', async (t) => {
  let requests = 0;
  const { url } = await serve(t, (_q, r) => { requests++; r.end('unexpected'); });
  const dispatcher = createHttpDispatcher();
  t.after(() => dispatcher.close());
  const first = new Error('first');
  const second = new Error('second');
  let controller;
  const failure = await new Promise(resolve => {
    dispatcher.dispatch({ origin: url, path: '/', method: 'GET' }, {
      onRequestStart(value) { controller = value; value.abort(first); value.abort(second); },
      onResponseError(_controller, error) { resolve(error); },
    });
  });
  assert.equal(failure, first);
  assert.equal(controller.aborted, true);
  assert.equal(controller.reason, first);
  assert.equal(requests, 0);
});

// rc.1 removed provider-owned DNS pinning. Inject only the real transport
// factory's lookup boundary; the provider still uses its public requestOnce.
async function transportPolicy(t, options, values = {}) {
  const create = network.createDispatcher;
  network.createDispatcher = policyOptions => create({ ...policyOptions, ...options });
  t.after(() => { network.createDispatcher = create; });
  await policy(t, values);
}

test('web-fetch-http uses the installed dispatcher lookup once and preserves Host', async (t) => {
  let count = 0;
  let host;
  const { url } = await serve(t, (q, r) => { host = q.headers.host; r.setHeader('content-type', 'text/plain'); r.end('dispatched'); });
  await transportPolicy(t, { lookup: (hostname, options, callback) => {
    count++;
    assert.equal(hostname, 'public-fixture.invalid');
    if (options.all) callback(null, [{ address: '127.0.0.1', family: 4 }]);
    else callback(null, '127.0.0.1', 4);
  } });
  const provider = new HttpFetchProvider(limits);
  const target = url.replace('127.0.0.1', 'public-fixture.invalid');
  const response = await provider.fetch({ url: target });
  assert.equal(response.body.content, 'dispatched');
  assert.equal(host, new URL(target).host);
  assert.equal(count, 1);
});

test('web-fetch-http follows main loopback access while refusing embedded credentials before I/O', async (t) => {
  let sent = 0;
  const { url } = await serve(t, (_q, r) => { sent++; r.setHeader('content-type', 'text/plain'); r.end('local'); });
  await policy(t);
  const provider = new HttpFetchProvider(limits);
  const response = await provider.fetch({ url });
  assert.equal(response.body.content, 'local');
  assert.equal(sent, 1);
  await assert.rejects(provider.fetch({ url: url.replace('://', '://user:secret@') }), (error) => error.code === 'WEB_BLOCKED_URL');
  assert.equal(sent, 1);
});

test('the public dispatcher retains explicit IPv4/IPv6 family selection', async (t) => {
  const { url } = await serve(t, (_q, r) => { r.setHeader('content-type', 'text/plain'); r.end('fallback'); });
  const previous = net.getDefaultAutoSelectFamily();
  net.setDefaultAutoSelectFamily(false);
  t.after(() => net.setDefaultAutoSelectFamily(previous));
  let lookups = 0;
  await transportPolicy(t, { autoSelectFamily: true, lookup: (_host, options, callback) => {
    lookups++;
    assert.equal(options.all, true);
    callback(null, [{ address: '::1', family: 6 }, { address: '127.0.0.1', family: 4 }]);
  } });
  const provider = new HttpFetchProvider(limits);
  const response = await provider.fetch({ url: url.replace('127.0.0.1', 'public-fixture.invalid') });
  assert.equal(response.body.content, 'fallback');
  assert.equal(lookups, 1);
});

test('web-fetch-http keeps its cross-origin redirect refusal', async (t) => {
  let followed = 0;
  const other = await serve(t, (_q, r) => { followed++; r.end('must not follow'); });
  const { url } = await serve(t, (_q, r) => { r.writeHead(302, { location: other.url }); r.end(); });
  await policy(t);
  const provider = new HttpFetchProvider(limits);
  await assert.rejects(provider.fetch({ url }), (error) => error.code === 'WEB_REDIRECT_BLOCKED');
  assert.equal(followed, 0);
});

test('a routed proxy resolves the origin; the public fetch provider does not resolve again', async (t) => {
  let target;
  let lookups = 0;
  const proxy = await serve(t, (q, r) => { target = q.url; r.setHeader('content-type', 'text/plain'); r.end('proxied'); });
  await transportPolicy(t, { lookup: (_host, _options, callback) => {
    lookups++; callback(new Error('origin DNS must remain at the proxy'));
  } }, { HTTP_PROXY: proxy.url });
  const provider = new HttpFetchProvider(limits);
  const response = await provider.fetch({ url: 'http://public-fixture.invalid/document' });
  assert.equal(response.body.content, 'proxied');
  assert.equal(target, 'http://public-fixture.invalid/document');
  assert.equal(proxyRouteFor(new URL('http://public-fixture.invalid/document')).proxied, true);
  assert.equal(lookups, 0);
});

test('loopback bypass and no_proxy suffix rules continue to use DSH policy', async (t) => {
  let proxyRequests = 0;
  const proxy = await serve(t, (_q, r) => { proxyRequests++; r.end('proxy'); });
  const local = await serve(t, (_q, r) => r.end('local'));
  await policy(t, { HTTP_PROXY: proxy.url, NO_PROXY: '.example.invalid' });
  assert.equal(await (await fetch(local.url)).text(), 'local');
  assert.equal(proxyRequests, 0);
  assert.equal(proxyRouteFor(new URL('http://api.example.invalid/')).proxied, false);
  assert.equal(proxyRouteFor(new URL('http://example.invalid/')).proxied, false);
  assert.equal(proxyRouteFor(new URL('http://notexample.invalid/')).proxied, true);
});

test('an explicit direct layer and disposal restore the preceding proxy policy', async (t) => {
  const proxy = await serve(t, (_q, r) => r.end('proxy'));
  const outer = await installProxyFromEnvironment(env({ HTTP_PROXY: proxy.url }), () => {});
  t.after(outer);
  assert.equal(proxyRouteFor(new URL('http://public-fixture.invalid/')).proxied, true);
  const old = network.dispatcher;
  const direct = await installProxyFromEnvironment(env({}), () => {});
  assert.equal(proxyRouteFor(new URL('http://public-fixture.invalid/')).proxied, false);
  assert.notEqual(network.dispatcher, old);
  await direct();
  assert.equal(network.dispatcher, old);
  assert.equal(proxyRouteFor(new URL('http://public-fixture.invalid/')).proxied, true);
  assert.equal(await (await fetch('http://public-fixture.invalid/')).text(), 'proxy');
  assert.equal(proxyEnvironmentForChild().NODE_USE_ENV_PROXY, '1');
});

test('native WebSocket without custom options works through the installed policy', async (t) => {
  const { server, url } = await serve(t, (_q, r) => r.end());
  server.on('upgrade', (q, socket) => {
    const accept = createHash('sha1').update(`${q.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.write(Buffer.from([0x81, 2, 111, 107]));
    socket.on('data', (chunk) => { if ((chunk[0] & 15) === 8) socket.end(Buffer.from([0x88, 0])); });
  });
  await policy(t);
  const socket = new WebSocket(url.replace('http:', 'ws:'));
  const closed = new Promise((resolve) => socket.addEventListener('close', resolve, { once: true }));
  const message = await new Promise((resolve, reject) => {
    socket.addEventListener('message', (event) => resolve(event.data), { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  assert.equal(message, 'ok');
  socket.close();
  await closed;
});

test('the locked EventSource package consumes the injected native fetch as SSE', async (t) => {
  const { url } = await serve(t, (_q, r) => { r.writeHead(200, { 'content-type': 'text/event-stream' }); r.write('data: 事件\n\n'); });
  await policy(t);
  const source = new EventSource(url, { fetch });
  t.after(() => source.close());
  const data = await new Promise((resolve, reject) => {
    source.addEventListener('message', (event) => resolve(event.data), { once: true });
    source.addEventListener('error', reject, { once: true });
  });
  assert.equal(data, '事件');
  source.close();
});

test('HTTPS origins keep TLS verification across an HTTP CONNECT proxy', async (t) => {
  const ca = fs.readFileSync(process.env.OHOS_NET_TEST_CERT);
  const target = await serve(t, (_q, r) => r.end('tunnel'), { cert: ca, key: fs.readFileSync(process.env.OHOS_NET_TEST_KEY) });
  const proxy = await serve(t, (_q, r) => { r.writeHead(400); r.end(); });
  let authority;
  const peers = new Set();
  t.after(() => { for (const socket of peers) socket.destroy(); });
  proxy.server.on('connect', (q, downstream, head) => {
    authority = q.url;
    const upstream = net.connect(target.port, '127.0.0.1', () => {
      downstream.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) upstream.write(head);
      upstream.pipe(downstream).pipe(upstream);
    });
    peers.add(upstream);
    upstream.on('close', () => peers.delete(upstream));
    upstream.on('error', () => downstream.destroy());
    downstream.on('error', () => upstream.destroy());
    downstream.on('close', () => upstream.destroy());
  });
  const create = network.createDispatcher;
  network.createDispatcher = (options) => create({ ...options, ca });
  t.after(() => { network.createDispatcher = create; });
  await policy(t, { HTTPS_PROXY: proxy.url });
  assert.equal(await (await fetch(`https://origin.invalid:${target.port}/`)).text(), 'tunnel');
  assert.equal(authority, `origin.invalid:${target.port}`);
});

test.after(async () => { await network.dispatcher.destroy(); });
