// Real bridge HTTP routes and a loopback upstream. No engine packages or live credentials.
//   node --test runtime/tests/bridge-speech.test.mjs
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createServer, request as httpRequest } from 'node:http';
import { connect } from 'node:net';
import { test } from 'node:test';
import { apply } from '../bridge/dsh-go-bridge/lib/index.js';

const ROOT = '/dsh-go/v1/speech';
const OFFICIAL = 'https://api.deepseek.com';
const TOKEN = 'speech-test-account-secret-never-real-7193';
const KEY = 'speech-test-api-key-never-real-5081';
const PCM = Buffer.from([1, 0, 2, 0, 3, 0]);
const nativeFetch = globalThis.fetch;
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const bounded = async (promise, label, ms = 4000) => {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(label)), ms);
    })]);
  } finally { clearTimeout(timer); }
};
const until = async (predicate, label) => {
  const deadline = Date.now() + 4000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(label);
    await new Promise(resolve => setImmediate(resolve));
  }
};
const post = (body, type = 'application/json') => ({ method: 'POST',
  headers: { 'content-type': type }, body: typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body) });
const tts = (body = { text: 'hello' }) => post(body);
const asr = (body = Buffer.from('RIFF-test-audio'), type = 'audio/wav') => post(body, type);

async function readAll(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks);
}

async function fixture(t, options = {}) {
  const state = { seen: [], calls: [], tokens: [], keys: [], logs: [], faults: [], disposed: false,
    dispatches: 0, settled: 0, transportError: undefined };
  const dispose = [];
  const up = createServer((req, res) => {
    req.on('error', () => {});
    res.on('error', () => {});
    void (async () => {
      const record = { method: req.method, path: req.url, headers: req.headers, body: await readAll(req) };
      state.seen.push(record);
      if (options.upstream) return options.upstream(req, res, record);
      if (req.url === '/v1/tools/tts') {
        res.writeHead(200, { 'content-type': 'application/octet-stream' });
        res.end(PCM);
      } else if (req.url === '/v1/tools/asr') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ text: '你好，世界', duration_ms: 1250, request_id: 'upstream-r1', ignored: TOKEN }));
      } else { res.writeHead(404); res.end('wrong endpoint'); }
    })().catch(error => { if (!state.disposed) state.faults.push(error); res.destroy(); });
  });
  up.listen(0, '127.0.0.1');
  await once(up, 'listening');
  const upstreamOrigin = `http://127.0.0.1:${up.address().port}`;
  let bridge, gate;
  const webServer = {
    exact: new Map(), prefixes: new Map(), upgrades: new Map(),
    tapIndex() { return () => {}; },
    register(route) {
      const table = route.kind === 'exact' ? this.exact : this.prefixes;
      table.set(route.path, route);
      return () => table.delete(route.path);
    },
    registerUpgrade(route) { this.upgrades.set(route.path, route); return () => this.upgrades.delete(route.path); },
    getOrigin: () => `http://127.0.0.1:${bridge.address().port}`,
  };
  const account = options.account === false ? undefined : {
    inferenceOrigin: options.accountOrigin === 'loopback' ? upstreamOrigin : options.accountOrigin ?? OFFICIAL,
    async resolveToken(url) {
      state.tokens.push(url);
      if (options.resolveToken) return options.resolveToken(url);
      return Object.hasOwn(options, 'token') ? options.token : TOKEN;
    },
  };
  const credentials = options.key !== undefined || options.resolveKey ? {
    async resolve(ref) {
      state.keys.push(ref);
      return options.resolveKey ? options.resolveKey(ref) : { value: options.key };
    },
  } : undefined;
  const logger = Object.fromEntries(['debug', 'info', 'warn', 'error'].map(name => [name, (...args) => state.logs.push(args)]));
  const ctx = {
    webServer, logger, on() {}, provide() {},
    get(name) {
      if (name === 'connection' && options.connection !== false) return { requestRejection: () => options.rejection };
      if (name === 'deepseekAccount') return account;
      if (name === 'credentials') return credentials;
    },
    effect(fn) { const stop = fn(); if (typeof stop === 'function') dispose.push(stop); },
    inject(_deps, fn) { fn(ctx); },
  };
  // Even a broken implementation must never send a test credential to the real service.
  t.mock.method(globalThis, 'fetch', (url, init) => {
    const target = new URL(url);
    assert.equal(target.hostname, '127.0.0.1', 'test attempted a non-loopback request');
    return nativeFetch(url, init);
  });
  const speechFetch = async (url, init) => {
    const target = new URL(url);
    state.calls.push({ url: target.href, init });
    if (state.transportError) throw state.transportError;
    const response = await nativeFetch(new URL(target.pathname + target.search, upstreamOrigin), init);
    options.observeSpeechResponse?.(response);
    return response;
  };
  apply(ctx, { persist: false, guardRoutes: options.guardRoutes ?? false,
    speech: { fetch: speechFetch, ...(options.speech ?? {}) } });
  bridge = createServer((req, res) => {
    req.on('error', () => {});
    res.on('error', () => {});
    void (async () => {
      state.dispatches++;
      const path = new URL(req.url, 'http://dsh-go.invalid').pathname;
      const held = gate?.path === path ? gate : undefined;
      if (held) { gate = undefined; held.arrived.resolve({ req, res }); await held.resume.promise; }
      const route = webServer.exact.get(path) ?? [...webServer.prefixes.values()].find(r => path.startsWith(r.path));
      options.observeBridgeResponse?.(res);
      if (route) await route.handler(req, res);
      else { res.writeHead(404); res.end(); }
      state.settled++;
      held?.done.resolve();
    })().catch(error => { if (!state.disposed) state.faults.push(error); res.destroy(); });
  });
  bridge.listen(0, '127.0.0.1');
  await once(bridge, 'listening');
  const disposeBridge = () => dispose.splice(0).reverse().forEach(stop => stop());
  t.after(async () => {
    state.disposed = true;
    disposeBridge();
    bridge.closeAllConnections(); up.closeAllConnections();
    await Promise.all([new Promise(resolve => bridge.close(resolve)), new Promise(resolve => up.close(resolve))]);
    assert.deepEqual(state.faults, [], 'fixture/route emitted an uncaught failure');
  });
  const raw = (suffix = '', init = {}) => nativeFetch(`${webServer.getOrigin()}${ROOT}${suffix}`, init);
  const request = async (suffix = '', init = {}) => {
    const response = await raw(suffix, init);
    const bytes = Buffer.from(await response.arrayBuffer());
    const text = bytes.toString('utf8');
    return { status: response.status, headers: response.headers, bytes, text,
      body: response.headers.get('content-type')?.includes('application/json') ? JSON.parse(text) : text };
  };
  return { state, ctx, account, raw, request, disposeBridge, upstreamOrigin, origin: webServer.getOrigin(),
    port: bridge.address().port,
    holdNext(path) {
      gate = { path, arrived: deferred(), resume: deferred(), done: deferred() };
      return { arrived: gate.arrived.promise, resume: gate.resume.resolve, done: gate.done.promise };
    } };
}

function errorIs(response, status, code) {
  assert.equal(response.status, status);
  assert.deepEqual(Object.keys(response.body), ['error']);
  assert.equal(response.body.error.code, code);
  assert.equal(typeof response.body.error.message, 'string');
  assert.ok(response.body.error.message.length > 0);
  assert.match(response.headers.get('content-type'), /^application\/json/);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  for (const secret of [TOKEN, KEY]) assert.equal(response.text.includes(secret), false, 'response exposed a credential');
}

test('GET reports account without upstream I/O; capabilities advertise speech', async t => {
  const f = await fixture(t, { key: KEY });
  const result = await f.request();
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { v: 1, credential: 'account' });
  assert.deepEqual(f.state.tokens, [`${OFFICIAL}/v1/tools/tts`]);
  assert.equal(f.state.keys.length, 0, 'account takes precedence before resolving a key');
  assert.equal(f.state.calls.length, 0);
  assert.equal(f.state.seen.length, 0);
  assert.equal(result.headers.get('cache-control'), 'no-store');
  assert.equal(result.text.includes(TOKEN), false);
  const capability = await nativeFetch(`${f.origin}/dsh-go/v1/capabilities`).then(r => r.json());
  assert.ok(capability.capabilities.includes('speech'));
});

test('GET reports null without an account or a reliable host key', async t => {
  const f = await fixture(t, { account: false });
  assert.deepEqual((await f.request()).body, { v: 1, credential: null });
  errorIs(await f.request('/tts', tts()), 401, 'speech/no-credential');
  errorIs(await f.request('/asr', asr()), 401, 'speech/no-credential');
  assert.equal(f.state.calls.length, 0);
});

test('API-key fallback resolves host references and sends Bearer only to upstream', async t => {
  const f = await fixture(t, { token: undefined, key: KEY,
    speech: { apiKeyEnv: 'MY_DEEPSEEK_KEY' } });
  assert.deepEqual((await f.request()).body, { v: 1, credential: 'api-key' });
  assert.equal(f.state.calls.length, 0);
  const response = await f.request('/tts', tts());
  assert.equal(response.status, 200);
  assert.deepEqual(response.bytes, PCM);
  assert.ok(f.state.keys.every(ref => ref === 'MY_DEEPSEEK_KEY'));
  assert.equal(f.state.seen[0].headers.authorization, `Bearer ${KEY}`);
  assert.equal(f.state.seen[0].headers['x-dsh-auth-token'], undefined);
  assert.equal(response.text.includes(KEY), false);
  assert.equal(JSON.stringify([...response.headers]).includes(KEY), false);
});

test('TTS uses the account inference origin, fixed upstream fields and default voice', async t => {
  const f = await fixture(t, { accountOrigin: 'loopback', key: KEY });
  const response = await f.request('/tts', tts({ text: '**hello**', voice_id: 'other', format: 'wav',
    filter_markdown: false, token: 'client-controlled', url: 'https://untrusted.invalid' }));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'application/octet-stream');
  assert.deepEqual(response.bytes, PCM);
  assert.equal(f.state.calls[0].url, `${f.upstreamOrigin}/v1/tools/tts`);
  assert.deepEqual(f.state.tokens, [`${f.upstreamOrigin}/v1/tools/tts`]);
  assert.equal(f.state.keys.length, 0);
  const upstream = f.state.seen[0];
  assert.equal(upstream.method, 'POST');
  assert.equal(upstream.headers['x-dsh-auth-token'], TOKEN);
  assert.equal(upstream.headers.authorization, undefined);
  assert.deepEqual(JSON.parse(upstream.body), { text: '**hello**', voice_id: 'stella', format: 'pcm', filter_markdown: true });
  assert.equal(JSON.stringify([...response.headers]).includes(TOKEN), false);
  const tide = await f.request('/tts', tts({ text: '海潮', voice: 'tide' }));
  assert.equal(tide.status, 200);
  assert.equal(JSON.parse(f.state.seen[1].body).voice_id, 'tide');
});

for (const [type, filename] of [['audio/wav', 'speech.wav'], ['audio/ogg', 'speech.ogg']]) {
  test(`ASR forwards ${type} as multipart file and returns only contract fields`, async t => {
    const f = await fixture(t);
    const input = Buffer.from([82, 73, 70, 70, 0, 255, 1, 17]);
    const result = await f.request('/asr', asr(input, type));
    assert.equal(result.status, 200);
    assert.deepEqual(result.body, { text: '你好，世界', duration_ms: 1250 });
    const upstream = f.state.seen[0];
    assert.equal(upstream.path, '/v1/tools/asr');
    assert.equal(upstream.headers['x-dsh-auth-token'], TOKEN);
    assert.match(upstream.headers['content-type'], /^multipart\/form-data; boundary=/);
    const form = await new Response(upstream.body, { headers: { 'content-type': upstream.headers['content-type'] } }).formData();
    assert.deepEqual([...form.keys()], ['file']);
    const file = form.get('file');
    assert.equal(file.name, filename);
    assert.equal(file.type, type);
    assert.deepEqual(Buffer.from(await file.arrayBuffer()), input);
    assert.equal(result.text.includes(TOKEN), false);
  });
}

test('TTS forwards three chunks before upstream completion and does not abort on normal req close', { timeout: 10000 }, async t => {
  const second = deferred(), third = deferred();
  t.after(() => { second.resolve(); third.resolve(); });
  let ended = false;
  const f = await fixture(t, { upstream: async (_req, res) => {
    res.writeHead(200, { 'content-type': 'application/octet-stream' });
    res.write(PCM.subarray(0, 2));
    await second.promise;
    res.write(PCM.subarray(2, 4));
    await third.promise;
    ended = true;
    res.end(PCM.subarray(4));
  } });
  const response = await bounded(f.raw('/tts', tts()), 'TTS did not start streaming');
  const reader = response.body.getReader();
  const first = await bounded(reader.read(), 'first chunk was buffered until upstream completion');
  assert.deepEqual(Buffer.from(first.value), PCM.subarray(0, 2));
  assert.equal(ended, false);
  assert.equal(f.state.calls[0].init.signal.aborted, false, 'normal IncomingMessage close must not abort an active response');
  second.resolve();
  const next = await bounded(reader.read(), 'second chunk did not stream');
  assert.deepEqual(Buffer.from(next.value), PCM.subarray(2, 4));
  assert.equal(ended, false);
  third.resolve();
  const rest = [];
  for (;;) { const item = await bounded(reader.read(), 'TTS completion stalled'); if (item.done) break; rest.push(Buffer.from(item.value)); }
  assert.deepEqual(Buffer.concat([Buffer.from(first.value), Buffer.from(next.value), ...rest]), PCM);
});

test('client disconnect during PCM immediately aborts the upstream fetch', { timeout: 10000 }, async t => {
  const closed = deferred();
  let finished = false;
  const f = await fixture(t, { upstream: async (_req, res) => {
    res.once('close', () => { finished = res.writableEnded; closed.resolve(); });
    res.writeHead(200, { 'content-type': 'application/octet-stream' });
    res.write(PCM);
    await closed.promise;
  } });
  const controller = new AbortController();
  const response = await f.raw('/tts', { ...tts(), signal: controller.signal });
  const reader = response.body.getReader();
  assert.equal((await bounded(reader.read(), 'no audio')).done, false);
  controller.abort();
  await bounded(closed.promise, 'bridge left upstream synthesis running after client disconnect');
  assert.equal(f.state.calls[0].init.signal.aborted, true);
  assert.equal(finished, false);
  await reader.cancel().catch(() => {});
});

test('client disconnect before upstream headers also aborts the upstream fetch', { timeout: 10000 }, async t => {
  const arrived = deferred(), closed = deferred();
  const f = await fixture(t, { upstream: async (_req, res) => {
    res.once('close', closed.resolve);
    arrived.resolve();
    await closed.promise;
  } });
  const controller = new AbortController();
  const pending = f.raw('/tts', { ...tts(), signal: controller.signal });
  const rejected = assert.rejects(pending);
  await bounded(arrived.promise, 'upstream request was not dispatched');
  controller.abort();
  await bounded(rejected, 'client request did not reject');
  await bounded(closed.promise, 'pre-header disconnect did not cancel upstream');
  assert.equal(f.state.calls[0].init.signal.aborted, true);
});

test('upstream mid-audio failure destroys the downstream response without JSON or padding', { timeout: 10000 }, async t => {
  const breakStream = deferred();
  t.after(breakStream.resolve);
  const f = await fixture(t, { upstream: async (_req, res) => {
    res.writeHead(200, { 'content-type': 'application/octet-stream' });
    res.write(PCM);
    await breakStream.promise;
    res.destroy();
  } });
  const response = await f.raw('/tts', tts());
  const reader = response.body.getReader();
  const first = await bounded(reader.read(), 'no first audio chunk');
  assert.deepEqual(Buffer.from(first.value), PCM);
  breakStream.resolve();
  await assert.rejects(bounded((async () => {
    for (;;) { const item = await reader.read(); if (item.done) return; assert.fail('bridge appended data after upstream failure'); }
  })(), 'downstream was not destroyed'), /terminated|abort|socket|premature|closed/i);
});

test('all upstream status mappings preserve a safe reason on both POST routes', async t => {
  let status = 400;
  const f = await fixture(t, { upstream(_req, res) {
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { message: `upstream-reason-${status}` } }));
  } });
  for (const [upStatus, expected, code] of [
    [400, 400, 'speech/rejected'], [401, 401, 'speech/sign-in-required'],
    [402, 402, 'speech/insufficient-balance'], [403, 400, 'speech/rejected'],
    [408, 400, 'speech/rejected'], [413, 413, 'speech/too-large'], [429, 429, 'speech/rate-limited'],
    [500, 500, 'speech/busy'], [502, 502, 'speech/busy'], [503, 503, 'speech/busy'],
    [504, 504, 'speech/busy'], [599, 599, 'speech/busy'],
  ]) for (const [route, init] of [['/tts', tts()], ['/asr', asr()]]) {
    status = upStatus;
    const result = await f.request(route, init);
    errorIs(result, expected, code);
    assert.match(result.body.error.message, new RegExp(`upstream-reason-${status}`));
  }
});

test('key-based 401 is unauthorized and account-based 401 never retries with the available key', async t => {
  const f = await fixture(t, { key: KEY, token: undefined, upstream(_req, res) {
    res.writeHead(401, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { message: 'expired credential' } }));
  } });
  errorIs(await f.request('/tts', tts()), 401, 'speech/unauthorized');
  assert.deepEqual(f.state.keys, ['DEEPSEEK_API_KEY']);
  f.account.resolveToken = async () => TOKEN;
  errorIs(await f.request('/tts', tts()), 401, 'speech/sign-in-required');
  assert.deepEqual(f.state.keys, ['DEEPSEEK_API_KEY']);
  assert.equal(f.state.seen.length, 2, 'one upstream request per operation, including an account rejection');
});

test('connectivity failure and upstream disconnect before headers return a safe 502', async t => {
  const f = await fixture(t, { upstream(_req, res) { res.destroy(); } });
  errorIs(await f.request('/tts', tts()), 502, 'speech/upstream-unreachable');
  f.state.transportError = new Error(`fetch failed; secret ${TOKEN} ${KEY}`);
  for (const [path, body] of [['/tts', tts()], ['/asr', asr()]]) {
    errorIs(await f.request(path, body), 502, 'speech/upstream-unreachable');
  }
  assert.equal(JSON.stringify(f.state.logs).includes(TOKEN), false);
  assert.equal(JSON.stringify(f.state.logs).includes(KEY), false);
});

test('upstream errors redact account tokens and keys in JSON/text reasons and logs', async t => {
  const consoleOutput = [];
  for (const method of ['log', 'warn', 'error', 'debug', 'info']) t.mock.method(console, method, (...args) => consoleOutput.push(args));
  let plain = false;
  const f = await fixture(t, { key: KEY, upstream(req, res) {
    const secret = req.headers['x-dsh-auth-token'] ?? req.headers.authorization.slice(7);
    const message = `Content Exists Risk; credential=${secret}; Authorization: Bearer ${secret}`;
    res.writeHead(400, { 'content-type': plain ? 'text/plain' : 'application/json' });
    res.end(plain ? message : JSON.stringify({ error: { message, token: secret }, other: secret }));
  } });
  for (const account of [true, false]) for (const asText of [false, true]) {
    f.account.resolveToken = async () => account ? TOKEN : undefined;
    plain = asText;
    const result = await f.request('/tts', tts());
    errorIs(result, 400, 'speech/rejected');
    assert.match(result.body.error.message, /Content Exists Risk/);
    assert.equal(JSON.stringify([...result.headers]).includes(TOKEN), false);
    assert.equal(JSON.stringify([...result.headers]).includes(KEY), false);
  }
  for (const secret of [TOKEN, KEY]) {
    assert.equal(JSON.stringify(f.state.logs).includes(secret), false);
    assert.equal(JSON.stringify(consoleOutput).includes(secret), false);
  }
});

test('redirects are never followed with a credential', async t => {
  let redirected = 0;
  const f = await fixture(t, { upstream(req, res) {
    if (req.url === '/secret-target') { redirected++; res.end(PCM); return; }
    res.writeHead(307, { location: `${f.upstreamOrigin}/secret-target` });
    res.end('unexpected redirect');
  } });
  errorIs(await f.request('/tts', tts()), 502, 'speech/upstream-unreachable');
  assert.equal(redirected, 0);
  assert.equal(f.state.seen.length, 1);
  assert.ok(['error', 'manual'].includes(f.state.calls[0].init.redirect));
});

test('ASR malformed success bodies are protocol failures', async t => {
  let body;
  const f = await fixture(t, { upstream(_req, res) {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(body);
  } });
  for (body of ['not JSON', '{}', '{"text":123,"duration_ms":1}', '{"text":"ok"}',
    '{"text":"ok","duration_ms":"1"}', '{"text":"ok","duration_ms":-1}', 'null']) {
    errorIs(await f.request('/asr', asr()), 502, 'speech/upstream-unreachable');
  }
  body = '{"text":"","duration_ms":0}';
  assert.deepEqual((await f.request('/asr', asr())).body, { text: '', duration_ms: 0 });
});

test('method, media type, malformed JSON, empty text and unsupported voices are rejected locally', async t => {
  const f = await fixture(t);
  for (const [route, init, status, code] of [
    ['', { method: 'POST' }, 405, 'method-not-allowed'],
    ['/tts', {}, 405, 'method-not-allowed'], ['/asr', {}, 405, 'method-not-allowed'],
    ['/tts', post('{}', 'text/plain'), 415, 'unsupported-media-type'],
    ['/asr', post('x', 'application/octet-stream'), 415, 'unsupported-media-type'],
    ['/tts', post('{'), 400, 'speech/rejected'],
    ...[null, [], {}, { text: 3 }, { text: '' }, { text: ' \n\t' }, { text: 'hello', voice: null },
      { text: 'hello', voice: 'other' }].map(body => ['/tts', tts(body), 400, 'speech/rejected']),
    ['/missing', {}, 404, 'route-not-found'],
  ]) errorIs(await f.request(route, init), status, code);
  assert.equal(f.state.calls.length, 0);
  const accepted = await f.request('/tts', post({ text: 'hello' }, 'Application/JSON; charset=UTF-8'));
  assert.equal(accepted.status, 200);
});

test('TTS limit is 64 KiB of request bytes, with an inclusive boundary', async t => {
  const f = await fixture(t);
  const prefix = JSON.stringify({ text: 'hello', ignored: '' });
  const atLimit = JSON.stringify({ text: 'hello', ignored: 'x'.repeat(65536 - Buffer.byteLength(prefix)) });
  assert.equal(Buffer.byteLength(atLimit), 65536);
  assert.equal((await f.request('/tts', post(atLimit))).status, 200);
  errorIs(await f.request('/tts', post(atLimit + ' ')), 413, 'speech/too-large');
  const unicode = JSON.stringify({ text: '鲸'.repeat(23000) });
  assert.ok(unicode.length < 65536 && Buffer.byteLength(unicode) > 65536);
  errorIs(await f.request('/tts', post(unicode)), 413, 'speech/too-large');
  assert.equal(f.state.seen.length, 1);
});

test('ASR accepts 8 MiB and rejects one additional byte before upstream dispatch', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('/asr', asr(Buffer.alloc(8 * 1024 * 1024)))).status, 200);
  errorIs(await f.request('/asr', asr(Buffer.alloc(8 * 1024 * 1024 + 1))), 413, 'speech/too-large');
  assert.equal(f.state.seen.length, 1);
});

for (const guardRoutes of [false, true]) for (const rejection of [401, 403, 503]) {
  test(`existing Connection guard precedes speech, status=${rejection}, fallback=${guardRoutes}`, async t => {
    const f = await fixture(t, { guardRoutes, rejection, connection: rejection !== 503 });
    for (const [route, init] of [['', {}], ['/tts', tts()], ['/asr', asr()]]) {
      assert.equal((await f.request(route, init)).status, rejection);
    }
    assert.equal(f.state.tokens.length, 0);
    assert.equal(f.state.keys.length, 0);
    assert.equal(f.state.calls.length, 0);
  });
}

for (const timing of ['before dispatch', 'during upload']) test(`interrupted input ${timing} settles and permits retry`, { timeout: 10000 }, async t => {
  const f = await fixture(t);
  const gate = f.holdNext(`${ROOT}/tts`);
  t.after(gate.resume);
  const socket = connect(f.port, '127.0.0.1');
  t.after(() => socket.destroy());
  await once(socket, 'connect');
  socket.write(`POST ${ROOT}/tts HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{`);
  const { req, res } = await bounded(gate.arrived, 'partial request did not arrive');
  if (timing === 'during upload') {
    gate.resume();
    await until(() => req.listenerCount('data') > 0, 'request reader did not start');
  }
  const closed = once(res, 'close');
  socket.destroy();
  await bounded(closed, 'aborted client socket did not close');
  if (timing === 'before dispatch') gate.resume();
  await bounded(gate.done, 'interrupted request handler did not settle');
  assert.equal(f.state.seen.length, 0);
  assert.equal((await f.request('/tts', tts())).status, 200);
});

test('a complete but unread request is still accepted after delayed dispatch', async t => {
  const f = await fixture(t);
  const gate = f.holdNext(`${ROOT}/tts`);
  t.after(gate.resume);
  const pending = f.request('/tts', tts());
  const { req } = await bounded(gate.arrived, 'request did not arrive');
  await until(() => req.complete, 'parser did not finish the request');
  assert.equal(req.readableEnded, false);
  gate.resume();
  assert.equal((await bounded(pending, 'unread body was discarded')).status, 200);
});

for (const kind of ['account', 'api-key']) test(`a late ${kind} resolver cannot dispatch after the client disconnects`, { timeout: 10000 }, async t => {
  const release = deferred();
  t.after(release.resolve);
  const options = kind === 'account' ? { resolveToken: () => release.promise } :
    { token: undefined, resolveKey: () => release.promise };
  const f = await fixture(t, options);
  const controller = new AbortController();
  const pending = f.raw('/tts', { ...tts(), signal: controller.signal });
  const rejected = assert.rejects(pending);
  await until(() => kind === 'account' ? f.state.tokens.length > 0 : f.state.keys.length > 0,
    'credential resolver did not start');
  controller.abort();
  await bounded(rejected, 'disconnected client request did not reject');
  await until(() => f.state.settled === 1, 'request lifetime waited for an uncancellable credential resolver');
  release.resolve(kind === 'account' ? TOKEN : { value: KEY });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.state.calls.length, 0, 'a late credential started billable upstream work');
});

test('chunked uploads enforce both byte limits without Content-Length', async t => {
  const f = await fixture(t);
  for (const [suffix, type, size] of [['/tts', 'application/json', 64 * 1024], ['/asr', 'audio/wav', 8 * 1024 * 1024]]) {
    const body = async function* () {
      for (let sent = 0; sent < size; sent += 16384) yield Buffer.alloc(Math.min(16384, size - sent));
      yield Buffer.from([1]);
    };
    errorIs(await f.request(suffix, { method: 'POST', headers: { 'content-type': type }, body: body(), duplex: 'half' }),
      413, 'speech/too-large');
  }
  assert.equal(f.state.calls.length, 0);
});

test('a slow audio consumer applies backpressure instead of buffering the complete upstream', { timeout: 10000 }, async t => {
  const block = Buffer.alloc(64 * 1024, 1);
  const total = 1024; // 64 MiB exceeds loopback socket and fetch stream buffers.
  let writes = 0, completed = false, stopped = false;
  const started = deferred(), upstreamClosed = deferred();
  const pressure = deferred();
  let waitingForDrain = false, readsBeforeDrain = 0, backpressureCount = 0;
  // Call the original transport methods; do not add another stream queue.
  const f = await fixture(t, {
    observeBridgeResponse(res) {
      res.on('drain', () => { waitingForDrain = false; });
      const write = res.write;
      t.mock.method(res, 'write', function (...args) {
        const accepted = write.apply(this, args);
        if (!accepted) {
          waitingForDrain = true;
          backpressureCount++;
          pressure.resolve();
        }
        return accepted;
      });
    },
    observeSpeechResponse(response) {
      const body = response.body, getReader = body.getReader;
      t.mock.method(body, 'getReader', function (...args) {
        const reader = getReader.apply(this, args), read = reader.read;
        t.mock.method(reader, 'read', function (...readArgs) {
          if (waitingForDrain) readsBeforeDrain++;
          return read.apply(this, readArgs);
        });
        return reader;
      });
    },
    upstream: async (_req, res) => {
      res.once('close', () => { stopped = true; upstreamClosed.resolve(); });
      res.writeHead(200, { 'content-type': 'application/octet-stream' });
      started.resolve();
      for (; writes < total && !stopped; writes++) {
        if (!res.write(block)) {
          await Promise.race([once(res, 'drain'), upstreamClosed.promise]);
        }
      }
      if (!stopped) { completed = true; res.end(); }
    },
  });
  const gotResponse = deferred();
  const req = httpRequest(`${f.origin}${ROOT}/tts`, { method: 'POST', headers: { 'content-type': 'application/json' } }, response => {
    response.on('error', () => {});
    response.pause();
    gotResponse.resolve(response);
  });
  req.on('error', () => {});
  req.end(JSON.stringify({ text: 'slow client' }));
  const response = await bounded(gotResponse.promise, 'slow client received no response');
  t.after(() => { response.destroy(); req.destroy(); });
  assert.equal(response.statusCode, 200);
  await started.promise;
  await bounded(pressure.promise, 'bridge never reached actual downstream backpressure');
  // Observe the real relay boundary. Socket/fetch buffers need not finish
  // filling within a wall-clock window, even while the client is paused.
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(completed, false, 'the entire audio was consumed while the client was paused');
  assert.ok(writes < total, `read ${writes} of ${total} upstream blocks despite a paused client`);
  assert.ok(backpressureCount > 0, 'the real bridge write never returned false');
  assert.equal(readsBeforeDrain, 0, 'relay read another upstream chunk after write(false) and before drain');
  response.destroy(); req.destroy();
  await bounded(upstreamClosed.promise, 'slow consumer disconnect did not abort upstream');
});

test('TTS rejects a nominally successful JSON or text credential echo before sending audio', async t => {
  let type = 'application/json';
  const f = await fixture(t, { key: KEY, upstream(req, res) {
    const secret = req.headers['x-dsh-auth-token'] ?? req.headers.authorization.slice(7);
    const message = `speech-provider-reason; Authorization: Bearer ${secret}`;
    res.writeHead(200, { 'content-type': type });
    res.end(type === 'application/json' ? JSON.stringify({ error: { message } }) : message);
  } });
  for (const account of [true, false]) for (type of ['application/json', 'text/plain']) {
    f.account.resolveToken = async () => account ? TOKEN : undefined;
    const result = await f.request('/tts', tts());
    errorIs(result, 502, 'speech/upstream-unreachable');
    assert.match(result.body.error.message, /speech-provider-reason/);
    assert.equal(result.headers.get('content-type').startsWith('application/octet-stream'), false);
  }
});

test('ASR credential echoes inside valid transcripts fail instead of returning altered successful text', async t => {
  const f = await fixture(t, { key: KEY, upstream(req, res) {
    const secret = req.headers['x-dsh-auth-token'] ?? req.headers.authorization.slice(7);
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ text: `upstream echoed ${secret} as transcript`, duration_ms: 10 }));
  } });
  for (const account of [true, false]) {
    f.account.resolveToken = async () => account ? TOKEN : undefined;
    const result = await f.request('/asr', asr());
    errorIs(result, 502, 'speech/upstream-unreachable');
    assert.equal(Object.hasOwn(result.body, 'text'), false);
  }
});

test('ASR success JSON must be valid UTF-8 without replacement decoding', async t => {
  const f = await fixture(t, { upstream(_req, res) {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(Buffer.concat([Buffer.from('{"text":"'), Buffer.from([0xff]), Buffer.from('","duration_ms":10}')]));
  } });
  errorIs(await f.request('/asr', asr()), 502, 'speech/upstream-unreachable');
});

test('TTS accepts PCM media types or an undeclared type and rejects declared non-PCM formats', async t => {
  let type;
  const f = await fixture(t, { upstream(_req, res) {
    res.writeHead(200, type === undefined ? {} : { 'content-type': type });
    res.end(PCM);
  } });
  for (type of ['audio/pcm', 'audio/x-pcm', 'application/octet-stream', undefined, 'Audio/PCM; rate=24000']) {
    const result = await f.request('/tts', tts());
    assert.equal(result.status, 200, `PCM response type ${String(type)}`);
    assert.equal(result.headers.get('content-type'), 'application/octet-stream');
    assert.deepEqual(result.bytes, PCM);
  }
  for (type of ['audio/wav', 'image/png']) errorIs(await f.request('/tts', tts()), 502, 'speech/upstream-unreachable');
});

test('empty and 204 TTS responses are protocol errors, never successful empty audio', async t => {
  let status = 200;
  const f = await fixture(t, { upstream(_req, res) {
    res.writeHead(status, { 'content-type': 'application/octet-stream' });
    res.end();
  } });
  for (status of [200, 204]) errorIs(await f.request('/tts', tts()), 502, 'speech/upstream-unreachable');
});

test('disposing the bridge interrupts active speech and aborts its upstream request', { timeout: 10000 }, async t => {
  const closed = deferred();
  const f = await fixture(t, { upstream: async (_req, res) => {
    res.once('close', closed.resolve);
    res.writeHead(200, { 'content-type': 'application/octet-stream' });
    res.write(PCM);
    await closed.promise;
  } });
  const response = await f.raw('/tts', tts());
  const reader = response.body.getReader();
  assert.deepEqual(Buffer.from((await bounded(reader.read(), 'audio did not start')).value), PCM);
  f.disposeBridge();
  await bounded(closed.promise, 'bridge disposal left upstream running');
  assert.equal(f.state.calls[0].init.signal.aborted, true);
  await assert.rejects(bounded(reader.read(), 'bridge disposal left client stream open'));
  await until(() => f.state.settled === 1, 'disposed speech handler did not settle');
});

test('credential service failures do not expose their exception text or start upstream work', async t => {
  const f = await fixture(t, {
    resolveToken() { throw new Error(`account failure containing ${TOKEN}`); },
    resolveKey() { throw new Error(`credential store failure containing ${KEY}`); },
  });
  const status = await f.request();
  assert.equal(status.status, 200);
  assert.deepEqual(status.body, { v: 1, credential: null });
  errorIs(await f.request('/tts', tts()), 401, 'speech/no-credential');
  assert.equal(f.state.calls.length, 0);
  for (const secret of [TOKEN, KEY]) assert.equal(JSON.stringify(f.state.logs).includes(secret), false);
});

test('each request re-resolves rotated account and key credentials without caching them', async t => {
  let token = TOKEN, key = KEY;
  const f = await fixture(t, { resolveToken: () => token, resolveKey: () => key === undefined ? undefined : { value: key } });
  for (const [nextToken, nextKey, header, value] of [
    [TOKEN, KEY, 'x-dsh-auth-token', TOKEN],
    [`${TOKEN}-rotated`, KEY, 'x-dsh-auth-token', `${TOKEN}-rotated`],
    [undefined, KEY, 'authorization', `Bearer ${KEY}`],
    [undefined, `${KEY}-rotated`, 'authorization', `Bearer ${KEY}-rotated`],
  ]) {
    token = nextToken; key = nextKey;
    assert.equal((await f.request('/tts', tts())).status, 200);
    assert.equal(f.state.seen.at(-1).headers[header], value);
  }
  token = undefined; key = undefined;
  assert.deepEqual((await f.request()).body, { v: 1, credential: null });
  assert.equal(f.state.seen.length, 4);
});

test('oversized error bodies are discarded entirely instead of echoing a truncated credential', async t => {
  const marker = 'oversized-upstream-marker';
  const f = await fixture(t, { upstream(_req, res) {
    res.writeHead(400, { 'content-type': 'text/plain' });
    const partial = Math.floor(TOKEN.length / 2);
    res.end(marker + 'x'.repeat(65536 - marker.length - partial) + TOKEN + 'tail');
  } });
  const result = await f.request('/tts', tts());
  errorIs(result, 400, 'speech/rejected');
  assert.equal(result.text.includes(marker), false, 'discard an oversized upstream message in full');
  assert.equal(result.text.includes(TOKEN.slice(0, Math.floor(TOKEN.length / 2))), false);
});
