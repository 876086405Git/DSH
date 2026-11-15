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

test('web-fetch-http uses its verified lookup once and preserves Host', async (t) => {
  let count = 0;
  let host;
  const { url } = await serve(t, (q, r) => { host = q.headers.host; r.setHeader('content-type', 'text/plain'); r.end('pinned'); });
  await policy(t);
  const provider = new HttpFetchProvider(limits, async () => { count++; return [{ address: '127.0.0.1', family: 4 }]; });
  const target = url.replace('127.0.0.1', 'public-fixture.invalid');
  const response = await provider.fetch({ url: target });
  assert.equal(response.body.content, 'pinned');
  assert.equal(host, new URL(target).host);
  assert.equal(count, 1);
});

test('web-fetch-http production resolver still refuses loopback and local targets', async (t) => {
  let sent = 0;
  const { url } = await serve(t, (_q, r) => { sent++; r.end(); });
  await policy(t);
  const provider = new HttpFetchProvider(limits);
  await assert.rejects(provider.fetch({ url }), (error) => error.code === 'WEB_BLOCKED_URL');
  assert.equal(sent, 0);
});

test('pinned HTTP retains the provider\'s explicit IPv4/IPv6 fallback policy', async (t) => {
  const { url } = await serve(t, (_q, r) => { r.setHeader('content-type', 'text/plain'); r.end('fallback'); });
  await policy(t);
  const previous = net.getDefaultAutoSelectFamily();
  net.setDefaultAutoSelectFamily(false);
  t.after(() => net.setDefaultAutoSelectFamily(previous));
  const provider = new HttpFetchProvider(limits, async () => [
    { address: '::1', family: 6 }, { address: '127.0.0.1', family: 4 },
  ]);
  const response = await provider.fetch({ url: url.replace('127.0.0.1', 'public-fixture.invalid') });
  assert.equal(response.body.content, 'fallback');
});

test('web-fetch-http keeps its cross-origin redirect refusal', async (t) => {
  const { url } = await serve(t, (_q, r) => { r.writeHead(302, { location: 'http://other.invalid/' }); r.end(); });
  await policy(t);
  const provider = new HttpFetchProvider(limits, async () => [{ address: '127.0.0.1', family: 4 }]);
  await assert.rejects(provider.fetch({ url: url.replace('127.0.0.1', 'public-fixture.invalid') }), (error) => error.code === 'WEB_REDIRECT_BLOCKED');
});

test('a routed proxy resolves the origin; the public fetch provider does not resolve again', async (t) => {
  let target;
  const proxy = await serve(t, (q, r) => { target = q.url; r.setHeader('content-type', 'text/plain'); r.end('proxied'); });
  await policy(t, { HTTP_PROXY: proxy.url });
  const provider = new HttpFetchProvider(limits, async () => { throw new Error('direct resolver must not run for a proxy hop'); });
  const response = await provider.fetch({ url: 'http://public-fixture.invalid/document' });
  assert.equal(response.body.content, 'proxied');
  assert.equal(target, 'http://public-fixture.invalid/document');
  assert.equal(proxyRouteFor(new URL('http://public-fixture.invalid/document')).proxied, true);
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
