// v1.2 capability tests for dsh-go-bridge (docs/design/native-plugins-protocol.md §11): real HTTP and
// WebSocket through the bridge's apply(), with a fake loader. No DSH needed.
//   node --test runtime/tests/native-capabilities.test.mjs
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { test } from 'node:test';
import { createServer } from 'node:http';
import { connect } from 'node:net';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { once } from 'node:events';
import { apply } from '../bridge/dsh-go-bridge/lib/index.js';
import { encodeFrame } from '../bridge/dsh-go-bridge/lib/native/ws.js';
import { parseManifest } from '../bridge/dsh-go-bridge/lib/native/manifest.js';
import { normalize } from '../bridge/dsh-go-bridge/lib/native/effects.js';
import { CapabilityRuntime } from '../bridge/dsh-go-bridge/lib/native/capability-runtime.js';
import { microModel } from '../bridge/dsh-go-bridge/lib/native/capabilities.js';
import { LIMITS } from '../bridge/dsh-go-bridge/lib/native/limits.js';
const delay = ms => new Promise(r => setTimeout(r, ms));
const manifest = { v: 1, capabilities: ['audio', 'voice', 'micro', 'overlay'], contributes: {
  'composer.actions': [{ id: 'go', label: 'Go' }], media: [{ id: 'clip' }], micro: [{ id: 'caption' }], overlays: [{ id: 'captionOverlay', channel: 'caption' }], panels: [{ id: 'panel', title: 'Panel', micro: 'caption' }] } };

async function fixture(t, declaration = manifest) {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-cap-'));
  writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'voice-test', version: '1.0.0', dshGo: declaration }));
  writeFileSync(join(dir, 'index.js'), '');
  const disposers = [], routes = [], upgrades = [], hooks = new Map(), services = {};
  const entry = { options: { name: pathToFileURL(join(dir, 'index.js')).href }, parent: { tree: { ctx: { baseUrl: pathToFileURL(dir + '/').href } } }, fiber: { uid: 7 } };
  const entries = [entry];
  let guardCalls = 0;
  const connection = { requestRejection(req) { guardCalls++; if (req.headers.authorization !== 'Bearer test') return 401; if (req.headers.origin === 'https://evil.invalid') return 403; } };
  const ctx = { logger: { warn() {} }, get: n => n === 'loader' ? { entries: () => entries } : n === 'connection' ? connection : services[n],
    provide(n, s) { services[n] = s; }, effect(fn) { const d = fn(); if (typeof d === 'function') disposers.push(d); return d; },
    on(n, fn) { hooks.set(n, fn); }, inject(deps, fn) { fn(ctx); },
    webServer: { tapIndex() { return () => {}; }, register(r) { routes.push(r); return () => {}; }, registerUpgrade(r) { upgrades.push(r); return () => {}; } } };
  apply(ctx, { persist: false, guardRoutes: false });
  const responses = []; let holdMedia = false, mediaRouteGate;
  const server = createServer(async (req, res) => {
    if (req.url.startsWith('/dsh-go/v1/media/')) {
      const gate = mediaRouteGate; mediaRouteGate = undefined;
      if (gate) { gate.arrived.resolve(res); await gate.resume.promise; }
      responses.push(res);
      if (holdMedia) {
        holdMedia = false;
        const end = res.end;
        res.end = function (body, ...args) {
          if (this.statusCode !== 200) return end.call(this, body, ...args);
          // Keep a real HTTP response unfinished without depending on socket buffer sizes.
          assert.ok(body instanceof Uint8Array && body.byteLength > 1);
          this.write(body.subarray(0, 1));
          return this;
        };
      }
    }
    const r = routes.find(r => r.kind === 'prefix' && req.url.startsWith(r.path));
    if (r) r.handler(req, res); else { res.writeHead(404); res.end(); }
  });
  server.on('upgrade', (req, socket, head) => upgrades[0].handler(req, socket, head));
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const port = server.address().port;
  const pluginCtx = { fiber: { entry }, effect: ctx.effect };
  const service = Object.assign(Object.create(services.dshGo), { ctx: pluginCtx });
  const sockets = new Set();
  async function ws(features) {
    const socket = connect(port, '127.0.0.1'); sockets.add(socket); await once(socket, 'connect');
    const messages = [], waiters = []; let buffer = Buffer.alloc(0), handshake = false;
    const deliver = m => { const i = waiters.findIndex(w => w.p(m)); if (i < 0) messages.push(m); else { const [w] = waiters.splice(i, 1); clearTimeout(w.timer); w.r(m); } };
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!handshake) { const i = buffer.indexOf('\r\n\r\n'); if (i < 0) return; assert.match(buffer.subarray(0, i).toString(), /101 Switching/); buffer = buffer.subarray(i + 4); handshake = true; }
      while (buffer.length >= 2) {
        const op = buffer[0] & 15; let n = buffer[1] & 127, off = 2;
        if (n === 126) { if (buffer.length < 4) return; n = buffer.readUInt16BE(2); off = 4; }
        if (n === 127 || buffer.length < off + n) return;
        const data = buffer.subarray(off, off + n); buffer = buffer.subarray(off + n);
        if (op === 1) deliver(JSON.parse(data.toString()));
      }
    });
    socket.write('GET /dsh-go/v1/stream HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n');
    const out = { socket, messages, send: m => socket.write(encodeFrame(1, JSON.stringify(m), { mask: true })), next(p) { const i = messages.findIndex(p); if (i >= 0) return Promise.resolve(messages.splice(i, 1)[0]); return new Promise((r, reject) => { const w = { p, r }; w.timer = setTimeout(() => reject(new Error('message timeout')), 1500); waiters.push(w); }); } };
    out.send({ t: 'hello', v: [1], ...(features === undefined ? {} : { features }) }); out.welcome = await out.next(m => m.t === 'welcome'); return out;
  }
  const request = (path, options = {}) => fetch(`http://127.0.0.1:${port}/dsh-go/v1/${path}`, { ...options, headers: { authorization: 'Bearer test', ...options.headers } });
  const invoke = async (w, scope = { sessionId: 's1' }, pkg = 'voice-test') => { const response = await request('invoke', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ v: 1, pkg, id: 'go', surface: 'composer.actions', scope, stream: w?.welcome.conn }) }); return { status: response.status, ...await response.json() }; };
  const mediaPath = (e, pkg = 'voice-test') => `media/${pkg}/clip?lease=${e.lease}${e.key === undefined ? '' : `&key=${e.key}`}`;
  t.after(async () => { for (const s of sockets) s.destroy(); while (disposers.length) disposers.pop()(); server.closeAllConnections(); await new Promise(r => server.close(r)); rmSync(dir, { recursive: true, force: true }); });
  function addPlugin(name) {
    const folder = join(dir, name); mkdirSync(folder); writeFileSync(join(folder, 'index.js'), ''); writeFileSync(join(folder, 'package.json'), JSON.stringify({ name, version: '1.0.0', dshGo: declaration }));
    const extra = { options: { name: pathToFileURL(join(folder, 'index.js')).href }, parent: entry.parent, fiber: { uid: entries.length + 10 } }; entries.push(extra); hooks.get('internal/plugin')();
    return Object.assign(Object.create(services.dshGo), { ctx: { fiber: { entry: extra }, effect: ctx.effect } });
  }
  return { service, ws, request, invoke, mediaPath, entry, hooks, addPlugin, port, responses,
    holdNextMediaRoute() {
      const gate = { arrived: Promise.withResolvers(), resume: Promise.withResolvers() };
      mediaRouteGate = gate;
      return { arrived: gate.arrived.promise, resume: gate.resume.resolve };
    },
    holdNextMediaResponse: () => { holdMedia = true; }, guardCalls: () => guardCalls };
}

test('old manifest/effect semantics and 4Hz budget remain unchanged', () => {
  const parsed = parseManifest({ name: 'old', dshGo: { v: 1, contributes: {} } }, '.');
  assert.equal(parsed.capabilities, undefined); assert.deepEqual(Object.keys(parsed.items), ['composer.actions', 'message.actions', 'composer.strip', 'panels']); assert.equal(LIMITS.dataHz, 4); assert.equal(LIMITS.dataBytes, 32768);
  const e = { type: 'audio', op: 'play', instance: 'one', src: 'media:clip' };
  for (const opts of [{}, { static: true }, { deferred: true }]) assert.equal(normalize(e, { panels: new Set(), ...opts }).effects.length, 0);
  assert.deepEqual(normalize({ toast: 'Hi' }, { panels: new Set() }).effects, [{ type: 'toast', text: 'Hi' }]);
});

test('declarations survive unnegotiated contributions; old welcome stays old', async t => {
  const f = await fixture(t); f.service.on('go', () => ({ type: 'audio', op: 'play', instance: 'a', src: 'media:clip' })); f.service.media('clip', () => ({ body: Buffer.from('audio'), contentType: 'audio/wav' }));
  const old = await f.ws(); assert.equal(old.welcome.features, undefined);
  const row = (await (await f.request('contributions')).json()).plugins[0]; assert.deepEqual(row.capabilities, manifest.capabilities); assert.equal(row.contributes.media[0].id, 'clip');
  assert.deepEqual((await f.invoke(old)).effects, []);
  const fresh = await f.ws(['audio', 'future']); assert.deepEqual(fresh.welcome.features, ['audio']); assert.ok((await f.invoke(fresh)).effects[0].lease);
});

test('actual production HTTP guard precedes media handler; finite same-host media only', async t => {
  const f = await fixture(t); let calls = 0;
  f.service.media('clip', (scope, { key }) => { calls++; assert.equal(scope.sessionId, 's1'); assert.equal(key, 'opaque'); return { body: Buffer.from('audio'), contentType: 'audio/wav', location: 'http://127.0.0.1:8765', headers: { 'set-cookie': 'no' } }; });
  f.service.on('go', () => ({ type: 'audio', op: 'play', instance: 'a', src: 'media:clip', key: 'opaque' }));
  const w = await f.ws(['audio']); const e = (await f.invoke(w)).effects[0]; const path = f.mediaPath(e);
  assert.equal((await f.request(path, { headers: { authorization: '' } })).status, 401);
  assert.equal((await f.request(path, { headers: { origin: 'https://evil.invalid' } })).status, 403); assert.equal(calls, 0);
  const good = await f.request(path); assert.equal(good.status, 200); assert.equal(await good.text(), 'audio'); assert.equal(good.headers.get('set-cookie'), null); assert.equal(good.headers.get('location'), null); assert.equal(good.headers.get('x-content-type-options'), 'nosniff');
  for (const bad of [path + '&url=http://127.0.0.1', path.replace('opaque', 'other'), path.replace('/clip?', '/%252e%252e?'), path.replace('voice-test', 'other-plugin')]) assert.ok((await f.request(bad)).status >= 400);
  assert.equal(calls, 1); assert.ok(f.guardCalls() >= 8);
});

test('lease rejects cross-connection/stale/duplicate events and ignores handler effects', async t => {
  const f = await fixture(t), events = [];
  let marker = 0;
  const settled = async client => {
    const at = ++marker; client.send({ t: 'ping', at });
    await client.next(message => message.t === 'pong' && message.at === at);
  };
  f.service.media('clip', () => ({ body: Buffer.from('a'), contentType: 'audio/mpeg' })); f.service.onCapability((s, e) => { events.push([s, e.event]); return { command: 'danger' }; });
  f.service.on('go', () => ({ type: 'audio', op: 'play', instance: 'a', src: 'media:clip' }));
  const a = await f.ws(['audio']), b = await f.ws(['audio']); const old = (await f.invoke(a)).effects[0], current = (await f.invoke(a)).effects[0]; assert.notEqual(old.lease, current.lease);
  b.send({ t: 'cap.event', lease: current.lease, seq: 1, event: 'audio.ended' }); a.send({ t: 'cap.event', lease: old.lease, seq: 2, event: 'audio.ended' }); await Promise.all([settled(a), settled(b)]); assert.equal(events.length, 0);
  a.send({ t: 'cap.event', lease: current.lease, seq: 2, event: 'audio.ended' }); a.send({ t: 'cap.event', lease: current.lease, seq: 3, event: 'audio.ended' }); await settled(a); assert.equal(events.length, 1); assert.equal(events[0][0].sessionId, 's1'); assert.equal((await f.request(f.mediaPath(current))).status, 404);
});

test('media stop aborts pending handler; disconnect revokes lease', async t => {
  const f = await fixture(t); let signal, begun;
  const started = new Promise(r => { begun = r; });
  f.service.media('clip', (s, e) => { signal = e.signal; begun(); return new Promise(() => {}); });
  let op = 'play'; f.service.on('go', () => ({ type: 'audio', op, instance: 'a', ...(op === 'play' ? { src: 'media:clip' } : {}) }));
  const w = await f.ws(['audio']); const e = (await f.invoke(w)).effects[0]; const pending = f.request(f.mediaPath(e)); await started;
  op = 'stop'; assert.equal((await f.invoke(w)).effects[0].lease, e.lease); assert.equal((await pending).status, 410); assert.equal(signal.aborted, true);
  w.socket.destroy(); await delay(25); assert.equal((await f.request(f.mediaPath(e))).status, 404);
});

test('media disconnected before dispatch leaves its plugin slot available', async t => {
  const f = await fixture(t); let calls = 0;
  f.service.media('clip', () => { calls++; return { body: Buffer.from('audio'), contentType: 'audio/wav' }; });
  f.service.on('go', () => ({ type: 'audio', op: 'play', instance: 'a', src: 'media:clip' }));
  const w = await f.ws(['audio']), effect = (await f.invoke(w)).effects[0], path = f.mediaPath(effect);
  // Peer for the WebServer's awaited Connection guard; the request, close event,
  // lease, dispatch and subsequent retry use the real HTTP/native implementation.
  const gate = f.holdNextMediaRoute();
  const socket = connect(f.port, '127.0.0.1'); t.after(() => socket.destroy());
  await once(socket, 'connect');
  socket.write(`GET /dsh-go/v1/${path} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test\r\n\r\n`);
  const response = await gate.arrived, closed = once(response, 'close');
  socket.destroy(); await closed;
  assert.equal(response.destroyed, true);
  gate.resume();
  const retry = await f.request(path);
  assert.equal(retry.status, 200);
  assert.equal(await retry.text(), 'audio');
  assert.equal(calls, 1, 'only the live retry may produce audio');
});

test('media bounds and registration disposal fail closed', async t => {
  const f = await fixture(t); let body = Buffer.from('a'), contentType = 'text/html';
  const remove = f.service.media('clip', () => ({ body, contentType })); f.service.on('go', () => ({ type: 'audio', op: 'play', instance: 'a', src: 'media:clip' }));
  const w = await f.ws(['audio']); const e = (await f.invoke(w)).effects[0]; assert.equal((await f.request(f.mediaPath(e))).status, 502);
  body = Buffer.alloc(16 * 1024 * 1024 + 1); contentType = 'audio/wav'; assert.equal((await f.request(f.mediaPath(e))).status, 413);
  remove(); assert.equal((await f.request(f.mediaPath(e))).status, 404);
});

test('micro starts on first subscriber, coalesces latest at 10Hz, immediately disposes last', async t => {
  const f = await fixture(t); let emit, started = 0, stopped = 0;
  f.service.micro('caption', { data(s, fn) { started++; emit = fn; fn({ text: 'first' }); return () => stopped++; } });
  const w = await f.ws(['micro']); assert.equal(started, 0);
  w.send({ t: 'micro.sub', sub: 'm', pkg: 'voice-test', id: 'caption' }); const first = await w.next(m => m.t === 'micro.data'); assert.equal(first.data.text, 'first');
  for (let i = 0; i < 50; i++) emit({ text: `value${i}`, progress: i / 50 });
  const latest = await w.next(m => m.t === 'micro.data'); assert.equal(latest.data.text, 'value49'); assert.notEqual(first.rev, latest.rev); assert.equal(started, 1);
  emit(latest.data); await delay(115); assert.equal(w.messages.filter(m => m.t === 'micro.data').length, 0);
  w.send({ t: 'micro.unsub', sub: 'm' }); await delay(25); assert.equal(stopped, 1); emit({ text: 'late' }); await delay(110); assert.equal(w.messages.filter(m => m.t === 'micro.data').length, 0);
});

test('micro schema rejects trees, effects, oversize Unicode and invalid progress', () => {
  for (const data of [{}, { text: 'x', effects: [] }, { text: '😀'.repeat(241) }, { progress: 1.1 }, { progress: NaN }, { tree: {} }]) assert.equal(microModel(data), undefined);
  assert.deepEqual(microModel({ text: '你好', progress: null }), { text: '你好', progress: null });
});

test('speechStart clears audio role while voice survives; speech edges are paced, terminals never dropped', async t => {
  const f = await fixture(t), events = [];
  f.service.media('clip', () => ({ body: Buffer.from('a'), contentType: 'audio/wav' })); f.service.onCapability((s, e) => events.push(e.event));
  f.service.on('go', () => [{ type: 'audio', op: 'play', instance: 'owner', src: 'media:clip' }, { type: 'voice', op: 'start', instance: 'owner' }]);
  const w = await f.ws(['audio', 'voice']); const r = await f.invoke(w); assert.equal(r.effects.length, 2); const lease = r.effects[0].lease; assert.equal(r.effects[1].lease, lease);
  // Hold elapsed time after connection setup; socket waits and their timeouts stay real.
  let now = Math.ceil(performance.now());
  t.mock.method(performance, 'now', () => now);
  w.send({ t: 'cap.event', lease, seq: 1, event: 'voice.speechStart' });
  w.send({ t: 'ping', at: 1 }); await w.next(m => m.t === 'pong' && m.at === 1);
  assert.deepEqual(events, ['voice.speechStart']); assert.equal((await f.request(f.mediaPath(r.effects[0]))).status, 404);
  // At one logical instant only four edges fit, including the first speechStart.
  for (let seq = 2; seq <= 6; seq++) w.send({ t: 'cap.event', lease, seq, event: seq % 2 ? 'voice.speechStart' : 'voice.speechEnd' });
  w.send({ t: 'ping', at: 2 }); await w.next(m => m.t === 'pong' && m.at === 2);
  const burst = ['voice.speechStart', 'voice.speechEnd', 'voice.speechStart', 'voice.speechEnd'];
  assert.deepEqual(events, burst);
  // 10 edges/second replenishes one slot after 100ms, not another whole burst.
  now += 100;
  w.send({ t: 'cap.event', lease, seq: 7, event: 'voice.speechEnd' });
  w.send({ t: 'cap.event', lease, seq: 8, event: 'voice.speechStart' });
  w.send({ t: 'ping', at: 3 }); await w.next(m => m.t === 'pong' && m.at === 3);
  assert.deepEqual(events, [...burst, 'voice.speechEnd']);
  // The empty edge budget cannot drop the terminal, and the retired role stays closed.
  w.send({ t: 'cap.event', lease, seq: 9, event: 'voice.stopped' });
  w.send({ t: 'ping', at: 4 }); await w.next(m => m.t === 'pong' && m.at === 4);
  assert.deepEqual(events, [...burst, 'voice.speechEnd', 'voice.stopped']);
  w.send({ t: 'cap.event', lease, seq: 10, event: 'voice.error' });
  w.send({ t: 'ping', at: 5 }); await w.next(m => m.t === 'pong' && m.at === 5);
  assert.deepEqual(events, [...burst, 'voice.speechEnd', 'voice.stopped']);
});

test('v1.1 plugins are untouched: undeclared capability effects and keys keep their old answers', async t => {
  const legacy = parseManifest({ name: 'legacy', dshGo: { v: 1, contributes: { media: [{ id: 'x' }], 'composer.actions': [{ id: 'go', label: 'Go' }] } } }, '.');
  assert.equal(legacy.capabilities, undefined); assert.equal(legacy.items.media, undefined);
  assert.ok(legacy.issues.some(i => i.code === 'unknown-surface' && i.path === '/dshGo/contributes/media'));
  const e = { type: 'audio', op: 'play', instance: 'one', src: 'media:clip' };
  for (const opts of [{}, { deferred: true }]) {
    const norm = normalize(e, { panels: new Set(), ...opts });
    assert.equal(norm.effects.length, 0); assert.equal(norm.violation, false); assert.equal(norm.issues[0].code, 'unknown-effect');
  }
  const f = await fixture(t, { v: 1, contributes: { 'composer.actions': [{ id: 'go', label: 'Go' }] } });
  f.service.on('go', () => [{ toast: 'hi' }, e]);
  const w = await f.ws(['audio']); const r = await f.invoke(w);
  assert.deepEqual(r.effects, [{ type: 'toast', text: 'hi' }]); assert.equal(r.issues[0].code, 'unknown-effect');
  const row = (await (await f.request('contributions?features=audio')).json()).plugins[0];
  assert.equal(row.capabilities, undefined); assert.deepEqual(Object.keys(row.contributes), ['composer.actions', 'message.actions', 'composer.strip', 'panels']);
});

test('declared but not negotiated: dropped without a violation, the plugin is never degraded', async t => {
  const f = await fixture(t); f.service.media('clip', () => ({ body: Buffer.from('a'), contentType: 'audio/wav' }));
  f.service.on('go', () => ({ type: 'audio', op: 'play', instance: 'a', src: 'media:clip' }));
  const old = await f.ws();
  for (let i = 0; i < 7; i++) { const r = await f.invoke(old); assert.equal(r.status, 200); assert.deepEqual(r.effects, []); assert.equal(r.issues[0].code, 'unknown-effect'); await delay(260); }
  const row = (await (await f.request('contributions')).json()).plugins[0]; assert.equal(row.state, 'ok');
});

test('new tap after speechStart rotates the whole owner, restores media and rejects old terminal', async t => {
  const f = await fixture(t), events = []; let withVoice = true;
  f.service.media('clip', () => ({ body: Buffer.from('new audio'), contentType: 'audio/wav' })); f.service.onCapability((s, e) => events.push(e.event));
  f.service.on('go', () => [{ type: 'audio', op: 'play', instance: 'owner', src: 'media:clip' }, ...(withVoice ? [{ type: 'voice', op: 'start', instance: 'owner' }] : [])]);
  const w = await f.ws(['audio', 'voice']); const first = (await f.invoke(w)).effects[0];
  w.send({ t: 'cap.event', lease: first.lease, seq: 1, event: 'voice.speechStart' }); await delay(25);
  withVoice = false; const second = (await f.invoke(w)).effects[0]; assert.notEqual(first.lease, second.lease);
  w.send({ t: 'cap.event', lease: first.lease, seq: 2, event: 'audio.ended' }); w.send({ t: 'cap.event', lease: first.lease, seq: 3, event: 'voice.stopped' }); await delay(25);
  const audio = await f.request(f.mediaPath(second)); assert.equal(audio.status, 200); assert.equal(await audio.text(), 'new audio'); assert.deepEqual(events, ['voice.speechStart']);
});

test('media concurrency is one per plugin and two across the real bridge', async t => {
  const f = await fixture(t), w = await f.ws(['audio']); const names = ['voice-test', 'second', 'third'], effects = [], starts = [];
  for (const name of names) {
    const service = name === 'voice-test' ? f.service : f.addPlugin(name); let start; starts.push(new Promise(r => { start = r; }));
    service.media('clip', () => { start(); return new Promise(() => {}); }); service.on('go', () => ({ type: 'audio', op: 'play', instance: 'one', src: 'media:clip' })); effects.push((await f.invoke(w, {}, name)).effects[0]);
  }
  const a = f.request(f.mediaPath(effects[0])); await starts[0]; assert.equal((await f.request(f.mediaPath(effects[0]))).status, 429);
  const b = f.request(f.mediaPath(effects[1], 'second')); await starts[1]; assert.equal((await f.request(f.mediaPath(effects[2], 'third'))).status, 429);
  w.socket.destroy();
  const cancelled = await Promise.race([Promise.all([a, b]), delay(1000).then(() => { throw new Error('peer FIN did not promptly release media') })]);
  assert.deepEqual(cancelled.map(r => r.status), [410, 410]);
});

test('lease budgets and stopped roles reclaim capacity, plugin disable revokes', async t => {
  const f = await fixture(t), w = await f.ws(['audio']); let i = 0;
  f.service.media('clip', () => ({ body: Buffer.from('a'), contentType: 'audio/wav' })); f.service.on('go', () => ({ type: 'audio', op: 'play', instance: `i${++i}`, src: 'media:clip' }));
  const a = (await f.invoke(w)).effects[0]; assert.ok((await f.invoke(w)).effects[0]); assert.equal((await f.invoke(w)).effects.length, 0);
  w.send({ t: 'cap.event', lease: a.lease, seq: 1, event: 'audio.stopped' }); await delay(20); assert.ok((await f.invoke(w)).effects[0]);
  f.entry.disabled = true; f.hooks.get('internal/status')(); assert.equal((await f.request(f.mediaPath(a))).status, 404);
});

test('micro requires negotiation, enforces per-plugin two and cancels on unload', async t => {
  const f = await fixture(t); let stops = 0; const remove = f.service.micro('caption', { data(s, emit) { emit({ text: 'x' }); return () => stops++; } });
  const old = await f.ws(); old.send({ t: 'micro.sub', sub: 'old', pkg: 'voice-test', id: 'caption' }); assert.equal((await old.next(m => m.t === 'micro.end')).reason, 'unsupported');
  const w = await f.ws(['micro']); for (const sub of ['a', 'b']) { w.send({ t: 'micro.sub', sub, pkg: 'voice-test', id: 'caption' }); await w.next(m => m.t === 'micro.data' && m.sub === sub); }
  w.send({ t: 'micro.sub', sub: 'c', pkg: 'voice-test', id: 'caption' }); assert.equal((await w.next(m => m.t === 'micro.end')).reason, 'limit');
  await delay(10); remove(); assert.equal((await w.next(m => m.t === 'micro.end')).reason, 'not-found'); assert.equal(stops, 1);
});

test('eight leases per connection are bounded independently of plugin allowance', async t => {
  const f = await fixture(t), w = await f.ws(['audio']); let accepted = 0;
  for (let plugin = 0; plugin < 5; plugin++) {
    const name = plugin === 0 ? 'voice-test' : `extra-${plugin}`; const service = plugin === 0 ? f.service : f.addPlugin(name); let index = 0;
    service.media('clip', () => ({ body: Buffer.from('x'), contentType: 'audio/wav' })); service.on('go', () => ({ type: 'audio', op: 'play', instance: `instance${++index}`, src: 'media:clip' }));
    for (let i = 0; i < 2; i++) accepted += (await f.invoke(w, {}, name)).effects.length;
  }
  assert.equal(accepted, 8);
});

test('30 second media deadline aborts producer instead of returning partial audio', { timeout: 35000 }, async t => {
  const f = await fixture(t), w = await f.ws(['audio']); let signal, started;
  const ready = new Promise(resolve => { started = resolve; });
  f.service.media('clip', (scope, event) => {
    t.mock.timers.enable({ apis: ['setTimeout'] });
    signal = event.signal; started(); return new Promise(() => {});
  }); f.service.on('go', () => ({ type: 'audio', op: 'play', instance: 'slow', src: 'media:clip' }));
  const e = (await f.invoke(w)).effects[0]; const pending = f.request(f.mediaPath(e));
  await ready;
  t.mock.timers.tick(29999);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(signal.aborted, false, 'producer keeps its full 30 second budget');
  t.mock.timers.tick(1);
  const response = await pending; assert.equal(response.status, 504); assert.equal(signal.aborted, true); assert.equal((await response.json()).error.code, 'timeout');
  t.mock.timers.reset();
});

for (const [order, state] of ['voice-first', 'audio-first'].flatMap(order => ['audio-active', 'after-speech'].map(state => [order, state]))) {
  test(`NJS2 restart batch binds both roles to one current lease: ${order}/${state}`, async t => {
    const f = await fixture(t), w = await f.ws(['audio', 'voice']); let restart = false;
    const audio = { type: 'audio', op: 'play', instance: 'owner', src: 'media:clip' };
    const voice = { type: 'voice', op: 'start', instance: 'owner' };
    f.service.media('clip', () => ({ body: Buffer.from('new audio'), contentType: 'audio/wav' }));
    f.service.on('go', () => !restart ? (state === 'audio-active' ? [audio] : [audio, voice]) : order === 'voice-first' ? [voice, audio] : [audio, voice]);
    const old = (await f.invoke(w)).effects[0];
    if (state === 'after-speech') { w.send({ t: 'cap.event', lease: old.lease, seq: 1, event: 'voice.speechStart' }); await delay(25); }
    restart = true;
    const result = await f.invoke(w); assert.equal(result.effects.length, 2);
    assert.equal(result.effects[0].lease, result.effects[1].lease); assert.notEqual(result.effects[0].lease, old.lease);
    const active = result.effects.find(e => e.type === 'audio'); assert.equal((await f.request(f.mediaPath(active))).status, 200);
    const events = []; f.service.onCapability((s, event) => events.push(event.event));
    w.send({ t: 'cap.event', lease: active.lease, seq: 1, event: 'voice.speechEnd' }); await delay(25); assert.deepEqual(events, ['voice.speechEnd']);
  });
}

async function until(predicate, message, timeout = 1500) {
  const end = Date.now() + timeout;
  while (!predicate()) { if (Date.now() > end) throw new Error(message); await delay(10); }
}
async function unfinishedMedia(t, f, effect, producerReady) {
  f.holdNextMediaResponse();
  const count = f.responses.length;
  const socket = connect(f.port, '127.0.0.1'); t.after(() => socket.destroy()); await once(socket, 'connect');
  socket.pause(); socket.write(`GET /dsh-go/v1/${f.mediaPath(effect)} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test\r\nConnection: close\r\n\r\n`);
  if (producerReady) {
    await producerReady;
    // Let the actual transfer continuation write its headers and first body byte.
    await new Promise(resolve => setImmediate(resolve));
    assert.ok(f.responses.length > count && f.responses[count].headersSent, 'media headers were not produced');
  } else await until(() => f.responses.length > count && f.responses[count].headersSent, 'media headers were not produced');
  const res = f.responses[count]; assert.equal(res.writableFinished, false, 'fixture must keep the HTTP response unfinished');
  return { socket, res };
}

test('NJS3 slow response keeps plugin slot and stop aborts unfinished HTTP body', async t => {
  const f = await fixture(t), w = await f.ws(['audio']); let signal;
  f.service.media('clip', (scope, event) => { signal = event.signal; return { body: Buffer.from('pending audio'), contentType: 'audio/wav' }; });
  f.service.on('go', () => ({ type: 'audio', op: 'play', instance: 'slow-reader', src: 'media:clip' }));
  const effect = (await f.invoke(w)).effects[0]; const held = await unfinishedMedia(t, f, effect);
  assert.equal(signal.aborted, false, 'producer signal stays alive through response completion');
  assert.equal((await f.request(f.mediaPath(effect))).status, 429, 'unfinished response keeps the per-plugin slot');
  w.send({ t: 'cap.event', lease: effect.lease, seq: 1, event: 'audio.stopped' });
  await until(() => held.res.destroyed, 'stop did not destroy unfinished response'); assert.equal(signal.aborted, true); assert.equal(held.res.writableFinished, false);
});

test('NJS3 total media deadline includes the slow response, not only producer', { timeout: 35000 }, async t => {
  const f = await fixture(t), w = await f.ws(['audio']); let signal, started;
  const ready = new Promise(resolve => { started = resolve; });
  f.service.media('clip', (scope, event) => {
    t.mock.timers.enable({ apis: ['setTimeout'] });
    signal = event.signal; started(); return { body: Buffer.from('pending audio'), contentType: 'audio/wav' };
  });
  f.service.on('go', () => ({ type: 'audio', op: 'play', instance: 'deadline-reader', src: 'media:clip' }));
  const effect = (await f.invoke(w)).effects[0]; const held = await unfinishedMedia(t, f, effect, ready);
  t.mock.timers.tick(29999);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(held.res.destroyed, false, 'unfinished response keeps its full 30 second budget');
  assert.equal(signal.aborted, false);
  t.mock.timers.tick(1);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(held.res.destroyed, true, 'shared media deadline destroys the unfinished response');
  assert.equal(held.res.writableFinished, false); assert.equal(signal.aborted, true);
  t.mock.timers.reset();
  // Replace the callback after timeout to establish that the old slot was released.
  f.service.media('clip', () => ({ body: Buffer.from('next'), contentType: 'audio/wav' }));
  const next = (await f.invoke(w)).effects[0]; assert.equal((await f.request(f.mediaPath(next))).status, 200);
});

test('terminal callback signal is deliberately lease-bound across async continuation', async t => {
  const f = await fixture(t), w = await f.ws(['voice']), observed = [];
  f.service.on('go', () => ({ type: 'voice', op: 'start', instance: 'last-role' }));
  f.service.onCapability(async (scope, event) => { observed.push(event.signal.aborted); await Promise.resolve(); observed.push(event.signal.aborted); });
  const effect = (await f.invoke(w)).effects[0]; w.send({ t: 'cap.event', lease: effect.lease, seq: 1, event: 'voice.stopped' });
  await until(() => observed.length === 2, 'terminal callback did not settle'); assert.deepEqual(observed, [false, true]);
});

for (const mode of ['dispose', 'replace']) {
  test(`W15 463 media completion rejects its retired registration: ${mode}`, async t => {
    const f = await fixture(t);
    const next = () => ({ body: Buffer.from('fresh audio'), contentType: 'audio/wav' });
    let signal, remove;
    remove = f.service.media('clip', (scope, event) => {
      signal = event.signal;
      // The service's ordinary disposer/re-registration happens before this
      // callback returns; no private runtime mutation or timer is involved.
      if (mode === 'dispose') remove();
      else f.service.media('clip', next);
      return { body: Buffer.from(`retired audio: ${mode}`), contentType: 'audio/wav' };
    });
    f.service.on('go', () => ({ type: 'audio', op: 'play', instance: 'a', src: 'media:clip' }));
    const w = await f.ws(['audio']);
    const effect = (await f.invoke(w)).effects[0];
    const response = await f.request(f.mediaPath(effect));
    const text = await response.text();
    assert.equal(response.status, 410, text);
    assert.equal(JSON.parse(text).error.code, 'cancelled');
    assert.equal(signal.aborted, true);

    if (mode === 'dispose') f.service.media('clip', next);
    const fresh = (await f.invoke(w)).effects[0];
    assert.notEqual(fresh.lease, effect.lease);
    const good = await f.request(f.mediaPath(fresh));
    assert.equal(good.status, 200);
    assert.equal(await good.text(), 'fresh audio');
  });
}

test('W15 463 another resource registration does not retire this media result', async t => {
  const f = await fixture(t);
  let calls = 0;
  f.service.media('clip', () => {
    calls++;
    const remove = f.service.micro('caption', { data() {} });
    remove();
    return { body: Buffer.from('current audio'), contentType: 'audio/wav' };
  });
  f.service.on('go', () => ({ type: 'audio', op: 'play', instance: 'a', src: 'media:clip' }));
  const w = await f.ws(['audio']);
  const effect = (await f.invoke(w)).effects[0];
  const response = await f.request(f.mediaPath(effect));
  assert.equal(response.status, 200);
  assert.equal(await response.text(), 'current audio');
  assert.equal(calls, 1);
});

test('NJS2 duplicate role start is rejected without returning a stale earlier lease', async t => {
  const f = await fixture(t), w = await f.ws(['voice']);
  f.service.on('go', () => [{ type: 'voice', op: 'start', instance: 'one' }, { type: 'voice', op: 'start', instance: 'one' }]);
  const result = await f.invoke(w); assert.equal(result.effects.length, 1); assert.ok(result.issues.some(i => i.code === 'bad-effect'));
  let calls = 0; f.service.onCapability(() => calls++);
  w.send({ t: 'cap.event', lease: result.effects[0].lease, seq: 1, event: 'voice.stopped' }); await until(() => calls === 1, 'accepted start has no live lease');
});

for (const [mode, role] of [['replace', 'voice'], ['dispose', 'overlay'], ['unrelated', 'voice']]) {
  test(`5307 ${role} start keeps a current lease across ${mode} registration`, async t => {
    const f = await fixture(t), w = await f.ws(['audio', 'voice', 'overlay']), events = [];
    const audio = () => ({ body: Buffer.from('audio'), contentType: 'audio/wav' });
    const remove = f.service.media('clip', audio);
    let second = false;
    f.service.onCapability((scope, event) => events.push(event.event));
    f.service.on('go', () => {
      if (!second) return { type: 'audio', op: 'play', instance: 'owner', src: 'media:clip' };
      // Ordinary plugin registration work completes before this invoke returns.
      if (mode === 'replace') f.service.media('clip', audio);
      else if (mode === 'dispose') remove();
      else f.service.micro('caption', { data() {} })();
      return role === 'voice'
        ? { type: 'voice', op: 'start', instance: 'owner' }
        : { type: 'overlay', op: 'show', instance: 'owner', id: 'captionOverlay' };
    });
    const original = (await f.invoke(w)).effects[0];
    second = true;
    const result = await f.invoke(w);
    assert.equal(result.status, 200);
    assert.equal(result.effects.length, 1);
    assert.deepEqual(result.issues, []);
    const added = result.effects[0];
    const terminal = role === 'voice' ? 'voice.stopped' : 'overlay.closed';
    // A round trip allows the already queued registration sweep to run.
    w.send({ t: 'ping', at: 1 }); await w.next(m => m.t === 'pong' && m.at === 1);
    w.send({ t: 'cap.event', lease: added.lease, seq: 1, event: terminal });
    w.send({ t: 'ping', at: 2 }); await w.next(m => m.t === 'pong' && m.at === 2);
    const observed = { reused: added.lease === original.lease, events };
    t.diagnostic(JSON.stringify({ mode, role, ...observed }));
    assert.deepEqual(observed, { reused: mode === 'unrelated', events: [terminal] });
  });
}

for (const mode of ['dispose', 'replace', 'callback-only']) {
  test(`5307 late terminal after ${mode} stays with the current media generation`, async t => {
    const f = await fixture(t), w = await f.ws(['audio', 'voice']), events = [];
    const audio = () => ({ body: Buffer.from('audio'), contentType: 'audio/wav' });
    const remove = f.service.media('clip', audio);
    f.service.on('go', () => [
      { type: 'audio', op: 'play', instance: 'owner', src: 'media:clip' },
      { type: 'voice', op: 'start', instance: 'owner' },
    ]);
    let afterTurn = false;
    f.service.onCapability((scope, event) => {
      events.push({ handler: 'original', event: event.event });
      if (mode === 'dispose') remove();
      else if (mode === 'replace') f.service.media('clip', audio);
      f.service.onCapability((scope, next) => {
        events.push({ handler: 'replacement', event: next.event, afterTurn });
      });
      setImmediate(() => { afterTurn = true; });
    });
    const effect = (await f.invoke(w)).effects[0];
    // Valid messages can arrive together. The actual WS decoder dispatches them
    // in order, including plugin registration work, before its data turn ends.
    w.socket.write(Buffer.concat([
      { t: 'cap.event', lease: effect.lease, seq: 1, event: 'voice.speechStart' },
      { t: 'cap.event', lease: effect.lease, seq: 2, event: 'voice.stopped' },
      { t: 'ping', at: 3 },
    ].map(message => encodeFrame(1, JSON.stringify(message), { mask: true }))));
    await w.next(m => m.t === 'pong' && m.at === 3);
    t.diagnostic(JSON.stringify({ mode, events }));
    const expected = [{ handler: 'original', event: 'voice.speechStart' }];
    if (mode === 'callback-only') expected.push({ handler: 'replacement', event: 'voice.stopped', afterTurn: false });
    assert.deepEqual(events, expected);
  });
}

// §11.5 is a source send budget; network receive timestamps cannot measure it.
test('micro source clock enforces 100ms latest-only budget and cancels pending work', async t => {
  t.mock.timers.enable({ apis: ['Date', 'setTimeout'], now: 1000 });
  // The feed paces on the monotonic clock; let it follow the mocked one.
  t.mock.method(performance, 'now', () => Date.now());
  let emit, starts = 0, cancels = 0;
  const sent = [];
  const rec = { pkg: 'voice-test', uid: 1, stamp: 1, parsed: { capabilities: ['micro'], items: { micro: [{ id: 'caption' }] } } };
  const reg = { token: {}, def: { data(scope, fn) { starts++; emit = fn; fn({ text: 'first' }); return () => cancels++; } } };
  const core = { onChanged: () => () => {}, plugin: () => rec, stateOf: () => 'ok', registration: () => reg, violation: () => assert.fail('valid micro rejected') };
  const runtime = new CapabilityRuntime(core, () => assert.fail('unexpected failure'));
  t.after(() => runtime.dispose());
  const conn = { features: ['micro'], locale: 'en', send: frame => sent.push({ at: Date.now(), ...frame }) };
  const message = { t: 'micro.sub', sub: 'm', pkg: 'voice-test', id: 'caption' };
  assert.equal(starts, 0); runtime.message(conn, message); await Promise.resolve();
  assert.equal(starts, 1); assert.equal(sent.length, 1); assert.equal(sent[0].at, 1000);
  emit({ text: 'superseded' }); t.mock.timers.tick(99); emit({ text: 'latest' });
  assert.equal(sent.length, 1, 'no source send before the 100ms boundary');
  t.mock.timers.tick(1); assert.equal(sent.length, 2); assert.equal(sent[1].at, 1100); assert.equal(sent[1].data.text, 'latest');
  emit({ text: 'latest' }); t.mock.timers.tick(100); assert.equal(sent.length, 2, 'equal data is suppressed');
  emit({ text: 'next' }); assert.equal(sent.length, 3); assert.equal(sent[2].at, 1200);
  const revisions = sent.map(x => x.rev.split('.'));
  assert.equal(new Set(revisions.map(x => x[0])).size, 1); assert.deepEqual(revisions.map(x => Number(x[1])), [1, 2, 3]);
  emit({ text: 'cancel-pending' }); runtime.message(conn, { t: 'micro.unsub', sub: 'm' });
  assert.equal(cancels, 1); assert.equal(runtime.feeds.size, 0); assert.equal(conn.microSubs.size, 0);
  t.mock.timers.tick(1000); emit({ text: 'late' }); assert.equal(sent.length, 3, 'unsub removes pending and future emissions');
});
