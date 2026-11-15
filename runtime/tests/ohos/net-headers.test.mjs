import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const root = process.env.OHOS_TEST_NET_ROOT ? pathToFileURL(resolve(process.env.OHOS_TEST_NET_ROOT) + '/') : new URL('../../ohos/net/', import.meta.url);
const { createHttpDispatcher } = await import(new URL('dispatcher.mjs', root));

async function fixture(t) {
  const received = [], sockets = new Set();
  const server = http.createServer(async (request, response) => {
    const chunks = [];
    try { for await (const chunk of request) chunks.push(chunk); }
    catch { return; }
    received.push({ headers: request.headers, body: Buffer.concat(chunks).toString() });
    response.setHeader('content-type', 'application/json'); response.end(JSON.stringify(received.at(-1)));
  });
  server.on('clientError', (_error, socket) => socket.destroy());
  server.on('upgrade', (request, socket) => {
    received.push({ headers: request.headers });
    socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: fixture\r\n\r\n');
  });
  server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const dispatcher = createHttpDispatcher({ proxyEnv: {}, headersTimeout: 1000, bodyTimeout: 1000 });
  t.after(async () => { await dispatcher.destroy(); for (const socket of sockets) socket.destroy(); await new Promise(resolve => server.close(resolve)); });
  return { dispatcher, received, origin: `http://127.0.0.1:${server.address().port}` };
}

async function dispatch(f, headers, { style = 'legacy', body = Buffer.from('ab'), upgrade } = {}) {
  const state = { events: [], errorCalls: 0 }, chunks = [];
  await new Promise(resolve => {
    const error = failure => { state.error = { code: failure.code, name: failure.name }; state.errorCalls++; state.events.push('error'); resolve(); };
    const upgraded = socket => { socket.destroy(); state.upgraded = true; state.events.push('upgrade'); resolve(); };
    const finish = () => { state.body = Buffer.concat(chunks).toString(); state.events.push('end'); resolve(); };
    const handler = style === 'legacy' ? {
      onConnect() { state.events.push('start'); }, onHeaders() { return true; },
      onData(chunk) { chunks.push(chunk); return true; }, onComplete: finish, onError: error,
      onUpgrade(_status, _headers, socket) { upgraded(socket); },
    } : {
      onRequestStart() { state.events.push('start'); }, onResponseStart() {},
      onResponseData(_controller, chunk) { chunks.push(chunk); }, onResponseEnd: finish,
      onResponseError(_controller, failure) { error(failure); },
      onRequestUpgrade(_controller, _status, _headers, socket) { upgraded(socket); },
    };
    try { state.returnValue = f.dispatcher.dispatch({ origin: f.origin, path: '/', method: upgrade ? 'GET' : 'POST', headers, body: upgrade ? undefined : body, upgrade }, handler); }
    catch (failure) { state.syncError = failure.message; resolve(); }
  });
  await new Promise(setImmediate);
  assert.equal(state.syncError, undefined);
  return state;
}

for (const style of ['legacy', 'v8']) {
  for (const frozen of [false, true]) test(`${style} upgrade copies a ${frozen ? 'frozen' : 'mutable'} caller header object`, async t => {
    const f = await fixture(t), headers = { 'X-Fixture': 'retained' }, before = structuredClone(headers);
    if (frozen) Object.freeze(headers);
    const result = await dispatch(f, headers, { style, upgrade: 'fixture' });
    assert.equal(result.error, undefined); assert.equal(result.upgraded, true);
    assert.deepEqual(headers, before); assert.equal(f.received[0].headers['x-fixture'], 'retained');
    assert.equal(f.received[0].headers.upgrade, 'fixture'); assert.equal(result.errorCalls, 0);
  });
  for (const length of ['1', '3']) test(`${style} mixed-case Content-Length ${length} checks actual two-byte upload`, async t => {
    const f = await fixture(t), headers = Object.freeze({ 'CoNtEnT-LeNgTh': length });
    const result = await dispatch(f, headers, { style });
    assert.equal(result.error?.code, 'UND_ERR_REQ_CONTENT_LENGTH_MISMATCH');
    assert.equal(result.errorCalls, 1); assert.deepEqual(headers, { 'CoNtEnT-LeNgTh': length });
  });
}

for (const shape of ['object', 'flat-array', 'Map', 'Headers']) test(`valid ${shape} headers retain the body length and custom header`, async t => {
  const f = await fixture(t), pairs = [['CoNtEnT-LeNgTh', '2'], ['X-Fixture', 'retained']];
  const headers = shape === 'object' ? Object.freeze(Object.fromEntries(pairs)) : shape === 'flat-array' ? Object.freeze(pairs.flat()) : shape === 'Map' ? new Map(pairs) : new Headers(pairs);
  const result = await dispatch(f, headers);
  assert.equal(result.error, undefined);
  const observed = JSON.parse(result.body);
  assert.equal(observed.headers['content-length'], '2'); assert.equal(observed.headers['x-fixture'], 'retained'); assert.equal(observed.body, 'ab');
});

test('ordinary header arrays are copied without flattening or mutating the caller', async t => {
  const f = await fixture(t), values = Object.freeze(['one', 'two']);
  const headers = Object.freeze({ 'Content-Length': '2', 'X-Multi': values });
  const result = await dispatch(f, headers);
  assert.equal(result.error, undefined); assert.equal(JSON.parse(result.body).headers['x-multi'], 'one, two');
  assert.deepEqual(values, ['one', 'two']); assert.equal(headers['X-Multi'], values);
});

test('a header getter is read once while the normalized copy is built', async t => {
  const f = await fixture(t); let reads = 0;
  const headers = Object.freeze({ 'Content-Length': '2', get 'X-Fixture'() { reads++; return 'retained'; } });
  const result = await dispatch(f, headers);
  assert.equal(result.error, undefined); assert.equal(JSON.parse(result.body).headers['x-fixture'], 'retained'); assert.equal(reads, 1);
});

for (const shape of ['object', 'flat-array']) test(`duplicate Content-Length after case folding is rejected for ${shape}`, async t => {
  const f = await fixture(t), pairs = [['Content-Length', '2'], ['cONTENT-lENGTH', '2']];
  const result = await dispatch(f, shape === 'object' ? Object.fromEntries(pairs) : pairs.flat());
  assert.equal(result.error?.code, 'UND_ERR_INVALID_ARG'); assert.equal(result.errorCalls, 1); assert.equal(f.received.length, 0);
});
for (const value of ['', '0x2', '+2', '2e0', ' 2', '2 ', ['2'], ['2', '2']]) test(`Content-Length ${JSON.stringify(value)} is not a single decimal value`, async t => {
  const f = await fixture(t), result = await dispatch(f, { 'CONTENT-length': value });
  assert.equal(result.error?.code, 'UND_ERR_INVALID_ARG'); assert.equal(result.errorCalls, 1); assert.equal(f.received.length, 0);
});
test('numeric Content-Length remains supported', async t => {
  const f = await fixture(t), result = await dispatch(f, { 'CONTENT-length': 2 });
  assert.equal(result.error, undefined); assert.equal(JSON.parse(result.body).body, 'ab');
});
