import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { gzipSync, brotliCompressSync, deflateSync, zstdCompressSync } from 'node:zlib';
import { createHttpDispatcher } from '../../ohos/net/dispatcher.mjs';
import { createFetch, installFetch } from '../../ohos/net/fetch.mjs';

const deferred = () => Promise.withResolvers();
const encode = new TextEncoder();

async function serve(t, handler, tls) {
  const server = tls ? https.createServer(tls, handler) : http.createServer(handler);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  });
  return { server, url: `${tls ? 'https' : 'http'}://127.0.0.1:${server.address().port}` };
}

function client(t, options) {
  const dispatcher = createHttpDispatcher(options);
  t.after(() => dispatcher.destroy());
  return { dispatcher, fetch: createFetch(dispatcher) };
}

async function bytes(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks);
}

async function echo(request, response) {
  const body = await bytes(request);
  response.setHeader('content-type', 'application/json');
  response.end(JSON.stringify({ method: request.method, url: request.url, headers: request.headers, body: body.toString() }));
}

test('factory preserves native constructors, immutable headers and response clone metadata', async (t) => {
  const constructors = [Request, Response, Headers, FormData];
  const { url } = await serve(t, (_q, r) => { r.setHeader('x-value', 'one'); r.end('中文'); });
  const { fetch } = client(t);
  const response = await fetch(`${url}/中文?q=😀`);
  assert.deepEqual([Request, Response, Headers, FormData], constructors);
  assert.ok(response instanceof Response);
  assert.ok(response.body instanceof ReadableStream);
  assert.throws(() => response.headers.set('x-value', 'two'), TypeError);
  const copy = response.clone();
  assert.equal(copy.url, response.url);
  assert.equal(copy.redirected, response.redirected);
  assert.deepEqual(await Promise.all([response.text(), copy.text()]), ['中文', '中文']);
});

test('HTTP errors remain responses, empty HEAD/204 bodies stay null', async (t) => {
  const { url } = await serve(t, (q, r) => {
    r.writeHead(q.url === '/empty' ? 204 : 404, { 'content-encoding': 'gzip' });
    r.end();
  });
  const { fetch } = client(t);
  const missing = await fetch(url, { method: 'HEAD' });
  assert.equal(missing.status, 404);
  assert.equal(missing.body, null);
  const empty = await fetch(`${url}/empty`);
  assert.equal(empty.status, 204);
  assert.equal(empty.body, null);
});

test('native Request and FormData serialize multipart without WASM', async (t) => {
  const { url } = await serve(t, async (q, r) => {
    const request = new Request('http://test.invalid', { method: 'POST', headers: q.headers, body: await bytes(q) });
    const data = await request.formData();
    r.end(JSON.stringify({ field: data.get('名称'), file: await data.get('文件').text(), name: data.get('文件').name }));
  });
  const { fetch } = client(t);
  const data = new FormData();
  data.set('名称', '汉字');
  data.set('文件', new Blob(['文件内容']), '中文.txt');
  const result = await fetch(new Request(url, { method: 'POST', body: data }));
  assert.deepEqual(await result.json(), { field: '汉字', file: '文件内容', name: '中文.txt' });
});

test('SSE is readable before the server finishes its response', async (t) => {
  const continueResponse = deferred();
  const { url } = await serve(t, async (_q, r) => {
    r.writeHead(200, { 'content-type': 'text/event-stream' });
    r.write('data: 一\n\n');
    await continueResponse.promise;
    r.end('data: 二\n\n');
  });
  const { fetch } = client(t);
  const response = await fetch(url);
  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
  const first = await reader.read();
  assert.equal(first.value, 'data: 一\n\n');
  assert.equal(first.done, false);
  continueResponse.resolve();
  assert.equal((await reader.read()).value, 'data: 二\n\n');
  assert.equal((await reader.read()).done, true);
});

for (const [status, method, expectedMethod] of [[301, 'POST', 'GET'], [301, 'PUT', 'PUT'], [302, 'POST', 'GET'], [303, 'PATCH', 'GET'], [303, 'HEAD', 'HEAD'], [307, 'POST', 'POST'], [308, 'PUT', 'PUT']]) {
  test(`redirect ${status} ${method} becomes ${expectedMethod}`, async (t) => {
    const { url } = await serve(t, async (q, r) => {
      if (q.url === '/start') { await bytes(q); r.writeHead(status, { location: '/end' }); r.end(); }
      else if (q.method === 'HEAD') { r.setHeader('x-method', q.method); r.end(); }
      else await echo(q, r);
    });
    const { fetch } = client(t);
    const response = await fetch(`${url}/start`, { method, ...(method === 'HEAD' ? {} : { body: '完整正文', headers: { 'content-type': 'text/plain', 'content-language': 'zh' } }) });
    assert.equal(response.redirected, true);
    assert.equal(response.clone().url, `${url}/end`);
    if (method === 'HEAD') assert.equal(response.headers.get('x-method'), 'HEAD');
    else {
      const data = await response.json();
      assert.equal(data.method, expectedMethod);
      assert.equal(data.body, expectedMethod === 'GET' ? '' : '完整正文');
      if (expectedMethod === 'GET') {
        assert.equal(data.headers['content-type'], undefined);
        assert.equal(data.headers['content-language'], undefined);
      }
    }
  });
}

for (const status of [307, 308]) test(`${status} preserves multipart bytes and boundary`, async (t) => {
  let first;
  const { url } = await serve(t, async (q, r) => {
    const seen = { body: (await bytes(q)).toString(), contentType: q.headers['content-type'] };
    if (q.url === '/start') { first = seen; r.writeHead(status, { location: '/end' }); r.end(); }
    else r.end(JSON.stringify(seen));
  });
  const { fetch } = client(t);
  const body = new FormData();
  body.set('field', '中文');
  const response = await fetch(`${url}/start`, { method: 'POST', body });
  const second = await response.json();
  // The OHOS Node build snapshots multipart bytes before a redirect replay.
  for (const item of [first, second]) {
    assert.ok(item.contentType.startsWith('multipart/form-data; boundary='));
    assert.ok(item.body.includes('中文'));
    assert.ok(item.body.includes(item.contentType.split('boundary=')[1]));
  }
  assert.equal(second.body, first.body);
});

test('cross-origin redirect strips credentials permanently through a return hop', async (t) => {
  let home;
  const seen = [];
  const away = await serve(t, (q, r) => {
    seen.push(q.headers);
    r.writeHead(302, { location: `${home.url}/end` }); r.end();
  });
  home = await serve(t, (q, r) => {
    seen.push(q.headers);
    if (q.url === '/start') { r.writeHead(302, { location: away.url }); r.end(); }
    else r.end('ok');
  });
  const { fetch } = client(t);
  assert.equal(await (await fetch(`${home.url}/start`, { headers: { authorization: 'Bearer fake-only', cookie: 'test=only' } })).text(), 'ok');
  assert.equal(seen[0].authorization, 'Bearer fake-only');
  assert.equal(seen[0].cookie, 'test=only');
  for (const headers of seen.slice(1)) {
    assert.equal(headers.authorization, undefined);
    assert.equal(headers.cookie, undefined);
  }
});

test('manual/error redirect modes and exact 20-hop maximum remain native', async (t) => {
  const { url } = await serve(t, (q, r) => {
    const left = Number(q.url.slice(1));
    if (left > 0) { r.writeHead(302, { location: `/${left - 1}` }); r.end(); }
    else r.end('done');
  });
  const { fetch } = client(t);
  const manual = await fetch(`${url}/1`, { redirect: 'manual' });
  assert.equal(manual.status, 302);
  await manual.body.cancel();
  await assert.rejects(fetch(`${url}/1`, { redirect: 'error' }), TypeError);
  assert.equal(await (await fetch(`${url}/20`)).text(), 'done');
  await assert.rejects(fetch(`${url}/21`), TypeError);
});

test('a non-replayable upload is rejected on 307 by native Fetch', async (t) => {
  const { url } = await serve(t, async (q, r) => { await bytes(q); r.writeHead(307, { location: '/again' }); r.end(); });
  const { fetch } = client(t);
  const body = new ReadableStream({ start(controller) { controller.enqueue(encode.encode('one')); controller.close(); } });
  await assert.rejects(fetch(url, { method: 'POST', body, duplex: 'half' }), TypeError);
});

test('pre-aborted signals preserve even falsy reasons without sending a request', async (t) => {
  let requests = 0;
  const { url } = await serve(t, (_q, r) => { requests++; r.end(); });
  const { fetch } = client(t);
  for (const reason of [null, 0, false, 'stop', { detail: 'stop' }]) {
    const result = await fetch(url, { signal: AbortSignal.abort(reason) }).then(() => 'unexpected success', (error) => error);
    assert.equal(result, reason);
  }
  await assert.rejects(fetch(url, { signal: AbortSignal.abort() }), { name: 'AbortError' });
  assert.equal(requests, 0);
});

test('abort before headers stops the active connection and preserves a custom reason', async (t) => {
  const arrived = deferred();
  const closed = deferred();
  const { url } = await serve(t, (q) => { q.on('close', closed.resolve); arrived.resolve(); });
  const { fetch } = client(t);
  const controller = new AbortController();
  const reason = { cancelled: true };
  const result = fetch(url, { signal: controller.signal }).catch((error) => error);
  await arrived.promise;
  controller.abort(reason);
  assert.equal(await result, reason);
  await closed.promise;
});

test('abort after headers errors the web stream rather than returning EOF', async (t) => {
  const { url } = await serve(t, (_q, r) => { r.writeHead(200); r.write('first'); });
  const { fetch } = client(t);
  const controller = new AbortController();
  const response = await fetch(url, { signal: controller.signal });
  const reader = response.body.getReader();
  assert.equal(new TextDecoder().decode((await reader.read()).value), 'first');
  controller.abort();
  await assert.rejects(reader.read(), { name: 'AbortError' });
});

for (const reason of [null, 0, false]) {
  test(`body abort preserves falsy reason ${JSON.stringify(reason)}`, async (t) => {
    const { url } = await serve(t, (_q, r) => { r.writeHead(200); r.write('first'); });
    const { fetch } = client(t);
    const controller = new AbortController();
    const reader = (await fetch(url, { signal: controller.signal })).body.getReader();
    await reader.read();
    controller.abort(reason);
    const result = await reader.read().then(() => 'unexpected success', (error) => error);
    assert.equal(result, reason);
  });
}

test('AbortSignal.timeout preserves TimeoutError', async (t) => {
  const { url } = await serve(t, () => {});
  const { fetch } = client(t);
  await assert.rejects(fetch(url, { signal: AbortSignal.timeout(40) }), { name: 'TimeoutError' });
});

test('headers and body inactivity deadlines destroy unfinished transfers', async (t) => {
  const { url } = await serve(t, (q, r) => { if (q.url === '/body') { r.writeHead(200); r.write('one'); } });
  const { fetch } = client(t, { headersTimeout: 40, bodyTimeout: 40 });
  await assert.rejects(fetch(url), (error) => error.cause.code === 'UND_ERR_HEADERS_TIMEOUT');
  const body = await fetch(`${url}/body`);
  await assert.rejects(body.text(), (error) => error.cause.code === 'UND_ERR_BODY_TIMEOUT');
});

test('backpressure suspends the body inactivity deadline until resume', async (t) => {
  const sendRest = deferred();
  const { url } = await serve(t, async (_q, r) => { r.write('first'); await sendRest.promise; r.end('last'); });
  const { dispatcher } = client(t, { bodyTimeout: 30 });
  const paused = deferred();
  const completed = deferred();
  let resume;
  let output = '';
  dispatcher.dispatch({ origin: url, path: '/', method: 'GET' }, {
    onConnect() {},
    onHeaders(_status, _headers, next) { resume = next; },
    onData(chunk) { output += chunk; paused.resolve(); return false; },
    onComplete: completed.resolve,
    onError: completed.reject,
  });
  await paused.promise;
  await delay(70);
  sendRest.resolve();
  resume();
  // The final chunk also pauses; the caller must consume it before EOF.
  await delay(5);
  resume();
  await completed.promise;
  assert.equal(output, 'firstlast');
});

for (const [encoding, compress] of [['gzip', gzipSync], ['br', brotliCompressSync], ['deflate', deflateSync], ['zstd', zstdCompressSync]]) {
  test(`native Fetch decodes ${encoding} without replacing response headers`, async (t) => {
    const compressed = compress(Buffer.from('压缩正文'));
    const { url } = await serve(t, (_q, r) => { r.writeHead(200, { 'content-encoding': encoding, 'content-length': compressed.length }); r.end(compressed); });
    const { fetch } = client(t);
    const response = await fetch(url);
    assert.equal(response.headers.get('content-encoding'), encoding);
    assert.equal(response.headers.get('content-length'), String(compressed.length));
    assert.equal(await response.text(), '压缩正文');
  });
}

test('stacked content encodings are decoded in reverse order', async (t) => {
  const { url } = await serve(t, (_q, r) => { r.writeHead(200, { 'content-encoding': 'gzip, br' }); r.end(brotliCompressSync(gzipSync(Buffer.from('twice')))); });
  const { fetch } = client(t);
  assert.equal(await (await fetch(url)).text(), 'twice');
});

test('invalid compression and truncated network bodies reject consumption', async (t) => {
  const disconnect = deferred();
  const { url } = await serve(t, async (q, r) => {
    if (q.url === '/gzip') { r.writeHead(200, { 'content-encoding': 'gzip' }); r.end('not a gzip stream'); }
    else { r.writeHead(200, { 'content-length': 100 }); r.write('first'); await disconnect.promise; r.socket.destroy(); }
  });
  const { fetch } = client(t);
  await assert.rejects((await fetch(`${url}/gzip`)).text(), TypeError);
  const response = await fetch(url);
  const result = response.text();
  disconnect.resolve();
  await assert.rejects(result, TypeError);
});

test('cancelling a response stream releases its connection', async (t) => {
  const closed = deferred();
  const { url } = await serve(t, (_q, r) => { r.on('close', closed.resolve); r.write('first'); });
  const { fetch } = client(t);
  const response = await fetch(url);
  await response.body.cancel();
  await closed.promise;
});

test('request Content-Length mismatches fail instead of hanging', async (t) => {
  const { url } = await serve(t, (q, r) => { q.on('error', () => {}); q.on('end', () => r.end()); q.resume(); });
  const { fetch } = client(t);
  for (const length of [1, 20]) {
    await assert.rejects(fetch(url, { method: 'POST', body: 'three', headers: { 'content-length': String(length) } }),
      (error) => error.cause.code === 'UND_ERR_REQ_CONTENT_LENGTH_MISMATCH');
  }
});

test('address-pinned DNS retains the HTTP Host while avoiding a second resolution', async (t) => {
  let calls = 0;
  const { url } = await serve(t, echo);
  const { fetch } = client(t, { lookup: (_host, options, callback) => {
    calls++;
    callback(null, options.all ? [{ address: '127.0.0.1', family: 4 }] : '127.0.0.1', 4);
  } });
  const target = url.replace('127.0.0.1', 'pin.invalid');
  const result = await (await fetch(target)).json();
  assert.equal(result.headers.host, new URL(target).host);
  assert.equal(calls, 1);
});

test('an explicit dispatcher is preserved rather than bypassing caller policy', async (t) => {
  const { url } = await serve(t, (_q, r) => r.end('pinned'));
  const { dispatcher } = client(t);
  const fetch = createFetch({ dispatch() { throw new Error('default must not run'); } });
  assert.equal(await (await fetch(url, { dispatcher })).text(), 'pinned');
});

test('proxyEnv sends HTTP through the chosen proxy without resolving the origin', async (t) => {
  const { url } = await serve(t, echo);
  const { fetch } = client(t, { proxyEnv: { HTTP_PROXY: url } });
  const response = await fetch('http://proxy-target.invalid/path?x=1');
  const data = await response.json();
  assert.equal(data.url, 'http://proxy-target.invalid/path?x=1');
  assert.equal(data.headers.host, 'proxy-target.invalid');
});

test('native WebSocket uses the same parser-free upgrade transport', async (t) => {
  const { server, url } = await serve(t, (_q, r) => { r.writeHead(400); r.end(); });
  const sockets = new Set();
  t.after(() => { for (const socket of sockets) socket.destroy(); });
  server.on('upgrade', (request, socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    const accept = createHash('sha1').update(`${request.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.write(Buffer.from([0x81, 2, 111, 107]));
    socket.on('data', (chunk) => { if ((chunk[0] & 15) === 8) socket.end(Buffer.from([0x88, 0])); });
  });
  const { dispatcher } = client(t);
  const socket = new WebSocket(url.replace('http:', 'ws:'), { dispatcher });
  const closed = new Promise((resolve) => socket.addEventListener('close', resolve, { once: true }));
  const message = await new Promise((resolve, reject) => {
    socket.addEventListener('message', (event) => resolve(event.data), { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  assert.equal(message, 'ok');
  socket.close();
  await closed;
});

test('TLS validates by default and accepts an explicitly trusted local test CA', async (t) => {
  assert.ok(process.env.OHOS_NET_TEST_CERT && process.env.OHOS_NET_TEST_KEY, 'run runtime/ohos/net/test.sh to prepare TLS fixtures');
  const ca = fs.readFileSync(process.env.OHOS_NET_TEST_CERT);
  const { url } = await serve(t, (_q, r) => r.end('secure'), { cert: ca, key: fs.readFileSync(process.env.OHOS_NET_TEST_KEY) });
  const insecure = client(t);
  await assert.rejects(insecure.fetch(url), TypeError);
  const trusted = client(t, { ca });
  assert.equal(await (await trusted.fetch(url)).text(), 'secure');
});

test('close drains an in-flight response and rejects new requests', async (t) => {
  const finish = deferred();
  const { url } = await serve(t, async (_q, r) => { r.write('one'); await finish.promise; r.end('two'); });
  const { dispatcher, fetch } = client(t);
  const response = await fetch(url);
  let closed = false;
  const pending = dispatcher.close().then(() => { closed = true; });
  assert.equal(closed, false);
  await assert.rejects(fetch(url), (error) => error.cause.code === 'UND_ERR_CLOSED');
  finish.resolve();
  assert.equal(await response.text(), 'onetwo');
  await pending;
  assert.equal(closed, true);
});

test('destroy releases active requests and has an awaitable completion', async (t) => {
  const arrived = deferred();
  const { url } = await serve(t, () => arrived.resolve());
  const { dispatcher, fetch } = client(t);
  const pending = fetch(url).catch((error) => error);
  await arrived.promise;
  await dispatcher.destroy();
  assert.equal((await pending).cause.code, 'UND_ERR_DESTROYED');
});

test('a normal Linux/Android path does not install the OHOS fetch preload', () => {
  if (process.platform === 'openharmony' || globalThis[Symbol.for('dsh.go.ohos.sim')] === true) return;
  const before = globalThis.fetch;
  assert.equal(installFetch(), undefined);
  assert.equal(globalThis.fetch, before);
});

test.after(async () => { await globalThis[Symbol.for('dsh.go.ohos.net')]?.dispatcher.destroy(); });
