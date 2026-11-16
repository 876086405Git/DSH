// v1.3 selected-file tests for dsh-go-bridge (docs/design/native-plugins-protocol.md §12): real HTTP and
// WebSocket through the bridge's apply(), with a fake loader. No DSH needed.
//   node --test runtime/tests/native-files.test.mjs
import assert from 'node:assert/strict';
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
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { apply as applyFileExample } from '../../examples/plugins/dsh-go-example-files/lib/index.js';
import { SchemaSet } from '../../sdk/plugin-kit/lib/json-schema.js';
const schemas = new SchemaSet();
const delay = ms => new Promise(r => setTimeout(r, ms));
const manifest = { v: 1, capabilities: ['files'], contributes: {
  'composer.actions': [{ id: 'go', label: 'Choose', requires: ['files'] }], panels: [{ id: 'panel', title: 'Files' }] } };

async function fixture(t, declaration = manifest, native = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-cap-'));
  writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'file-test', version: '1.0.0', dshGo: declaration }));
  writeFileSync(join(dir, 'index.js'), '');
  const disposers = [], routes = [], upgrades = [], hooks = new Map(), services = {};
  const entry = { options: { name: pathToFileURL(join(dir, 'index.js')).href }, parent: { tree: { ctx: { baseUrl: pathToFileURL(dir + '/').href } } }, fiber: { uid: 7 } };
  const entries = [entry];
  let guardCalls = 0;
  const connection = { requestRejection(req) { guardCalls++; if (req.headers.authorization !== 'Bearer test') return 401; if (req.headers.origin === 'https://evil.invalid') return 403; } };
  const ctx = { logger: { warn(error) { t.diagnostic(String(error?.stack ?? error)); } }, get: n => n === 'loader' ? { entries: () => entries } : n === 'connection' ? connection : services[n],
    provide(n, s) { services[n] = s; }, effect(fn) { const d = fn(); if (typeof d === 'function') disposers.push(d); return d; },
    on(n, fn) { hooks.set(n, fn); }, inject(deps, fn) { fn(ctx); },
    webServer: { tapIndex() { return () => {}; }, register(r) { routes.push(r); return () => {}; }, registerUpgrade(r) { upgrades.push(r); return () => {}; } } };
  apply(ctx, { persist: false, guardRoutes: false, native });
  let fileRouteGate;
  const server = createServer(async (req, res) => {
    const gate = req.url.startsWith('/dsh-go/v1/files/') && req.url.includes(`/${fileRouteGate?.operation}?`)
      ? fileRouteGate : undefined;
    if (gate) {
      fileRouteGate = undefined;
      gate.arrived.resolve({ req, res }); await gate.resume.promise;
    }
    const r = routes.find(r => r.kind === 'prefix' && req.url.startsWith(r.path));
    if (r) await r.handler(req, res); else { res.writeHead(404); res.end(); }
    gate?.done.resolve();
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
  const invoke = async (w, scope = { sessionId: 's1' }, pkg = 'file-test') => { const response = await request('invoke', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ v: 1, pkg, id: 'go', surface: 'composer.actions', scope, stream: w?.welcome.conn, userGesture: true }) }); return { status: response.status, ...await response.json() }; };
  t.after(async () => { for (const s of sockets) s.destroy(); while (disposers.length) disposers.pop()(); server.closeAllConnections(); await new Promise(r => server.close(r)); rmSync(dir, { recursive: true, force: true }); });
  function addPlugin(name) {
    const folder = join(dir, name); mkdirSync(folder); writeFileSync(join(folder, 'index.js'), ''); writeFileSync(join(folder, 'package.json'), JSON.stringify({ name, version: '1.0.0', dshGo: declaration }));
    const extra = { options: { name: pathToFileURL(join(folder, 'index.js')).href }, parent: entry.parent, fiber: { uid: entries.length + 10 } }; entries.push(extra); hooks.get('internal/plugin')();
    return Object.assign(Object.create(services.dshGo), { ctx: { fiber: { entry: extra }, effect: ctx.effect } });
  }
  const holdFileRoute = operation => {
    const gate = { operation, arrived: Promise.withResolvers(), resume: Promise.withResolvers(), done: Promise.withResolvers() };
    fileRouteGate = gate;
    return { arrived: gate.arrived.promise, resume: gate.resume.resolve, done: gate.done.promise };
  };
  return { service, ws, request, invoke, entry, hooks, addPlugin, port, guardCalls: () => guardCalls,
    holdNextUploadRoute: () => holdFileRoute('upload'),
    holdNextCompleteRoute: () => holdFileRoute('complete'),
  };
}


test('native stream accepts empty continuations after the guarded upgrade and hello', async t => {
  const f = await fixture(t);
  const w = await f.ws([]);
  assert.ok(f.guardCalls() > 0);
  const frames = [encodeFrame(1, '', { mask: true, fin: false })];
  for (let i = 0; i < 2048; i++) frames.push(encodeFrame(0, '', { mask: true, fin: false }));
  frames.push(encodeFrame(0, JSON.stringify({ t: 'ping', at: 225 }), { mask: true }));
  w.socket.write(Buffer.concat(frames));
  assert.deepEqual(await w.next(m => m.t === 'pong'), { t: 'pong', at: 225 });
});


const choice = { type: 'pickFile', action: 'selected', maxFiles: 4 };
const filePath = (w, effect, op, extra = {}) => `files/${effect.request}/${op}?${new URLSearchParams({ stream: w.welcome.conn, ...extra })}`;
const upload = async (f, w, effect, bytes, name = 'note.txt', options = {}) => {
  const response = await f.request(filePath(w, effect, 'upload', { name }), { method: 'POST', headers: { 'content-type': 'application/octet-stream' }, body: bytes, ...options });
  const body = await response.json();
  if (response.status === 200) assert.deepEqual(schemas.validate(body, 'invoke.schema.json', '/$defs/fileUploadResponse'), []);
  return { status: response.status, ...body };
};
const complete = async (f, w, effect, status = 'selected') => {
  const response = await f.request(filePath(w, effect, 'complete'), { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ status }) });
  const body = await response.json();
  if (response.status === 200) assert.deepEqual(schemas.validate(body, 'invoke.schema.json', '/$defs/fileCompletionResponse'), []);
  return { status: response.status, ...body };
};

test('upload disconnected before dispatch permits error completion and a fresh selection', async t => {
  const f = await fixture(t), events = [];
  f.service.on('go', (_scope, event) => {
    if (event.action !== 'selected') return choice;
    events.push({ status: event.value.status, files: event.value.files.map(file => f.service.readPickedFile(file.handle).toString()) });
  });
  const w = await f.ws(['files']), effect = (await f.invoke(w)).effects[0];
  assert.equal((await upload(f, w, effect, 'discard on interruption')).status, 200);
  // Peer for the WebServer's awaited Connection guard. The partial upload,
  // HTTP abort, file transaction, error completion and retry are real.
  const gate = f.holdNextUploadRoute();
  const socket = connect(f.port, '127.0.0.1'); t.after(() => socket.destroy());
  await once(socket, 'connect');
  socket.write(`POST /dsh-go/v1/${filePath(w, effect, 'upload', { name: 'partial.txt' })} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test\r\nContent-Type: application/octet-stream\r\nContent-Length: 100\r\n\r\npartial`);
  const { req, res } = await gate.arrived, closed = once(res, 'close');
  socket.destroy(); await closed;
  assert.equal(req.aborted, true); assert.equal(res.destroyed, true);
  gate.resume();
  const failed = await upload(f, w, effect, 'must not revive the failed selection');
  assert.equal(failed.status, 409); assert.equal(failed.error.code, 'cancelled');
  assert.equal((await complete(f, w, effect, 'error')).status, 200);
  assert.deepEqual(events, [{ status: 'error', files: [] }], 'interrupted selection discards its earlier bytes');
  assert.equal((await upload(f, w, effect, 'expired request')).status, 404);
  const fresh = (await f.invoke(w)).effects[0];
  assert.ok(fresh?.request); assert.notEqual(fresh.request, effect.request);
  assert.equal((await upload(f, w, fresh, 'new selected bytes')).status, 200);
  assert.equal((await complete(f, w, fresh)).status, 200);
  assert.deepEqual(events.at(-1), { status: 'selected', files: ['new selected bytes'] });
});

const until = async (predicate, label) => {
  const deadline = Date.now() + 3000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(label);
    await new Promise(resolve => setImmediate(resolve));
  }
};

for (const timing of ['before dispatch', 'while reading']) {
  test(`file JSON completion interrupted ${timing} settles and permits retry`, async t => {
    const f = await fixture(t), events = [];
    f.service.on('go', (_scope, event) => {
      if (event.action !== 'selected') return choice;
      events.push({ status: event.value.status, files: event.value.files.map(file => f.service.readPickedFile(file.handle).toString()) });
    });
    const w = await f.ws(['files']), effect = (await f.invoke(w)).effects[0];
    assert.equal((await upload(f, w, effect, 'selected bytes')).status, 200);
    const gate = f.holdNextCompleteRoute(); t.after(gate.resume);
    const socket = connect(f.port, '127.0.0.1'); t.after(() => socket.destroy());
    await once(socket, 'connect');
    socket.write(`POST /dsh-go/v1/${filePath(w, effect, 'complete')} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{"status":`);
    const { req, res } = await gate.arrived;
    let settled = false; gate.done.then(() => { settled = true; });
    if (timing === 'while reading') {
      gate.resume();
      await until(() => req.listenerCount('data') > 0, 'JSON reader did not start');
    }
    const closed = once(res, 'close'); socket.destroy(); await closed;
    assert.equal(req.aborted, true); assert.equal(req.destroyed, true);
    const listeners = ['data', 'end', 'error'].map(event => req.listenerCount(event));
    if (timing === 'before dispatch') gate.resume();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(settled, true, 'a closed IncomingMessage cannot supply later body events');
    if (timing === 'before dispatch') {
      assert.deepEqual(['data', 'end', 'error'].map(event => req.listenerCount(event)), listeners,
        'an already closed request must not retain new body listeners');
    }
    assert.deepEqual(events, []);
    assert.equal((await complete(f, w, effect)).status, 200);
    assert.deepEqual(events, [{ status: 'selected', files: ['selected bytes'] }]);
  });
}

test('file JSON completion accepts a complete but unread IncomingMessage', async t => {
  const f = await fixture(t); let completed = 0;
  f.service.on('go', (_scope, event) => {
    if (event.action !== 'selected') return choice;
    completed++;
  });
  const w = await f.ws(['files']), effect = (await f.invoke(w)).effects[0];
  assert.equal((await upload(f, w, effect, 'selected bytes')).status, 200);
  const gate = f.holdNextCompleteRoute(); t.after(gate.resume);
  const response = complete(f, w, effect), { req } = await gate.arrived;
  await until(() => req.complete, 'HTTP parser did not complete the request');
  assert.equal(req.readableEnded, false);
  assert.equal(req.aborted, false); assert.equal(req.destroyed, false);
  gate.resume();
  assert.equal((await response).status, 200);
  await gate.done;
  assert.equal(completed, 1);
});

const invokePanel = async (f, w) => {
  const response = await f.request('invoke', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({
    v: 1, pkg: 'file-test', id: 'panel', surface: 'panel', action: 'choose', stream: w.welcome.conn, userGesture: true,
  }) });
  return { status: response.status, ...await response.json() };
};

// The source action and its file callback may belong to different registrations.
// Keep the real HTTP/WS path: a stale result must never allocate a chooser slot.
for (const scenario of [
  { surface: 'composer.actions', source: 'handlers', callback: 'handlers' },
  { surface: 'panel', source: 'panels', callback: 'panels' },
  { surface: 'panel', source: 'panels', callback: 'handlers' },
  { surface: 'panel', source: 'handlers', callback: 'panels' },
  { surface: 'panel', source: 'handlers', callback: 'handlers' },
]) {
  const { surface, source, callback } = scenario;
  const id = surface === 'panel' ? 'panel' : 'go';
  const mutations = source === callback ? ['source', 'none'] : ['source', 'callback', 'none'];
  for (const mutate of mutations) test(`registration identity before invoke: ${surface} ${source}->${callback}, replace ${mutate}`, async t => {
    const f = await fixture(t);
    let entered, resume;
    const started = new Promise(r => { entered = r; });
    const waiting = new Promise(r => { resume = r; });
    const callbacks = [];
    const oldChoose = async () => { entered(); await waiting; return choice; };
    const install = (kind, generation) => {
      const choose = generation === 'old' ? oldChoose : () => choice;
      const selected = () => { callbacks.push(generation); };
      return kind === 'panels'
        ? f.service.panel(id, { view: { type: 'text', text: generation }, actions: {
          ...(source === kind ? { choose } : {}), ...(callback === kind ? { selected } : {}),
        } })
        : f.service.on(id, (scope, event) => event.action === 'selected' ? selected() : choose());
    };
    const removes = new Map();
    // A panel without the requested action exercises the actual handler fallback.
    for (const kind of new Set([source, callback, ...(surface === 'panel' ? ['panels'] : [])])) {
      removes.set(kind, install(kind, 'old'));
    }
    const w = await f.ws(['files']);
    const invoke = () => surface === 'panel' ? invokePanel(f, w) : f.invoke(w);
    const pending = invoke();
    await started;
    if (mutate !== 'none') {
      const kind = mutate === 'source' ? source : callback;
      removes.get(kind)();
      install(kind, 'new');
    }
    resume();
    const result = await pending;
    assert.equal(result.status, 200);
    if (mutate === 'none') {
      assert.equal(result.effects.length, 1);
      assert.equal((await upload(f, w, result.effects[0], 'current bytes')).status, 200);
      assert.equal((await complete(f, w, result.effects[0])).status, 200);
      assert.deepEqual(callbacks, ['old']);
      return;
    }
    assert.deepEqual(result.effects, [], 'an old call must not receive replacement file authority');
    assert.ok(result.issues.some(i => /registration|unloaded|changed/.test(i.message)));
    assert.deepEqual(callbacks, []);
    const fresh = await invoke();
    assert.equal(fresh.effects.length, 1, 'rejected old results must not occupy the stream slot');
    assert.equal((await upload(f, w, fresh.effects[0], 'fresh bytes')).status, 200);
    assert.equal((await complete(f, w, fresh.effects[0])).status, 200);
    assert.deepEqual(callbacks, [mutate === 'callback' || source === callback ? 'new' : 'old']);
  });
}

test('registration identity before invoke: a callback first registered during await cannot inherit the tap', async t => {
  const f = await fixture(t);
  let entered, resume, callbacks = 0;
  const started = new Promise(r => { entered = r; });
  const waiting = new Promise(r => { resume = r; });
  f.service.panel('panel', { view: { type: 'text', text: 'Files' }, actions: {
    choose: async () => { entered(); await waiting; return choice; },
  } });
  const w = await f.ws(['files']);
  const pending = invokePanel(f, w);
  await started;
  f.service.on('panel', () => { callbacks++; });
  resume();
  const result = await pending;
  assert.deepEqual(result.effects, []);
  assert.equal(callbacks, 0);
  const fresh = await invokePanel(f, w);
  assert.equal((await complete(f, w, fresh.effects[0], 'cancelled')).status, 200);
  assert.equal(callbacks, 1);
});

test('registration identity before invoke: callback functions are taken from the invocation snapshot', async t => {
  const f = await fixture(t);
  let entered, resume;
  const started = new Promise(r => { entered = r; });
  const waiting = new Promise(r => { resume = r; });
  const callbacks = [];
  const actions = {
    choose: async () => { entered(); await waiting; return choice; },
    selected: () => { callbacks.push('original'); },
  };
  f.service.panel('panel', { view: { type: 'text', text: 'Files' }, actions });
  const w = await f.ws(['files']);
  const pending = invokePanel(f, w);
  await started;
  actions.selected = () => { callbacks.push('mutated'); };
  resume();
  const result = await pending;
  assert.equal((await complete(f, w, result.effects[0], 'cancelled')).status, 200);
  assert.deepEqual(callbacks, ['original']);
});

for (const source of ['panels', 'handlers']) test(`registration identity after issue: removing ${source} also revokes a different-kind callback`, async t => {
  const f = await fixture(t);
  let callbacks = 0;
  const selected = () => { callbacks++; };
  const removePanel = f.service.panel('panel', { view: { type: 'text', text: 'Files' }, actions: source === 'panels'
    ? { choose: () => choice } : { selected } });
  const removeHandler = f.service.on('panel', source === 'handlers' ? () => choice : selected);
  const w = await f.ws(['files']);
  const result = await invokePanel(f, w);
  assert.equal(result.effects.length, 1);
  (source === 'panels' ? removePanel : removeHandler)();
  const response = await complete(f, w, result.effects[0], 'cancelled');
  assert.ok([404, 410].includes(response.status));
  assert.equal(callbacks, 0);
});

test('files are optional, negotiated and only explicitly tapped, within finite budgets', () => {
  const options = { panels: new Set(['panel']), capabilities: { declared: ['files'], features: ['files'] }, userGesture: true };
  assert.deepEqual(normalize(choice, options).effects, [choice]);
  for (const opts of [{}, { capabilities: { declared: ['files'], features: [] }, userGesture: true }]) {
    const r = normalize(choice, { panels: new Set(), ...opts });
    assert.equal(r.effects.length, 0); assert.equal(r.violation, false);
  }
  for (const opts of [{ userGesture: false }, { userGesture: undefined }, { static: true }, { deferred: true }, { fileResult: true }]) {
    const r = normalize(choice, { ...options, ...opts }); assert.equal(r.effects.length, 0); assert.equal(r.violation, true);
  }
  for (const maxFiles of [0, 5, 1.5, '2']) assert.equal(normalize({ ...choice, maxFiles }, options).violation, true);
  assert.equal(normalize({ ...choice, request: 'forged', maxBytes: 999 }, options).effects[0].request, undefined);
  const parsed = parseManifest({ name: 'file-test', dshGo: manifest }, '.');
  assert.deepEqual(parsed.capabilities, ['files']); assert.deepEqual(parsed.items['composer.actions'][0].requires, ['files']);
});

test('production HTTP/WS chain delivers byte copies only inside the awaited owning callback', async t => {
  const f = await fixture(t); const other = f.addPlugin('other'); let selected, lateRead;
  f.service.on('go', async (scope, event) => {
    if (event.action !== 'selected') return choice;
    assert.equal(scope.sessionId, 's1'); selected = event.value;
    const handle = selected.files[0].handle;
    const first = f.service.readPickedFile(handle);
    assert.equal(first.toString(), 'private content'); first.fill(0);
    assert.throws(() => other.readPickedFile(handle), /no longer readable/);
    await Promise.resolve();
    assert.equal(f.service.readPickedFile(handle).toString(), 'private content');
    lateRead = () => f.service.readPickedFile(handle);
    return [{ type: 'patch', id: 'panel', data: { name: selected.files[0].name } }, { type: 'toast', text: 'Read' }, choice];
  });
  const w = await f.ws(['files']); assert.deepEqual(w.welcome.features, ['files']);
  const effect = (await f.invoke(w)).effects[0]; assert.match(effect.request, /^[A-Za-z0-9_-]{32}$/);
  assert.equal(effect.maxBytes, 8 * 1024 * 1024); assert.equal(effect.maxTotalBytes, 16 * 1024 * 1024);
  const put = await upload(f, w, effect, 'private content', '../../note.txt'); assert.equal(put.status, 200);
  assert.deepEqual(Object.keys(put.file), ['handle', 'name', 'bytes', 'mediaType', 'access']); assert.equal(put.file.name, 'note.txt');
  const done = await complete(f, w, effect); assert.equal(done.status, 200);
  assert.equal(selected.status, 'selected'); assert.equal(selected.files[0].access, 'read');
  assert.deepEqual(done.effects.map(e => e.type), ['patch', 'toast']); assert.ok(done.issues.some(i => i.code === 'bad-effect'));
  assert.throws(lateRead, /no longer readable/); assert.equal((await complete(f, w, effect)).status, 404);
});

test('authentication, origin and stream ownership are checked before uploads', async t => {
  const f = await fixture(t); f.service.on('go', () => choice);
  const a = await f.ws(['files']), b = await f.ws(['files']); const e = (await f.invoke(a)).effects[0];
  const path = filePath(a, e, 'upload', { name: 'a' });
  const request = headers => f.request(path, { method: 'POST', body: 'secret', headers: { 'content-type': 'application/octet-stream', ...headers } });
  assert.equal((await request({ authorization: '' })).status, 401);
  assert.equal((await request({ origin: 'https://evil.invalid' })).status, 403);
  assert.equal((await upload(f, b, e, 'secret')).status, 404);
  assert.equal((await complete(f, b, e, 'cancelled')).status, 404);
  assert.equal((await upload(f, a, e, 'ok')).status, 200);
  a.socket.destroy(); await delay(25);
  assert.equal((await complete(f, a, e)).status, 404);
});

test('old streams cannot invoke a required-files action; omitted gesture cannot launch a picker', async t => {
  const f = await fixture(t); f.service.on('go', () => choice);
  const old = await f.ws(); assert.equal((await f.invoke(old)).status, 409);
  const w = await f.ws(['files']);
  const response = await f.request('invoke', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ v: 1, pkg: 'file-test', id: 'go', surface: 'composer.actions', stream: w.welcome.conn }) });
  const body = await response.json(); assert.equal(response.status, 200); assert.deepEqual(body.effects, []); assert.ok(body.issues.some(i => i.code === 'bad-effect'));
});

test('cancel and error release all files and deliver one empty callback', async t => {
  const f = await fixture(t), callbacks = [];
  f.service.on('go', (s, e) => { if (e.action === 'selected') { callbacks.push(e.value); return { toast: e.value.status }; } return choice; });
  const w = await f.ws(['files']);
  for (const status of ['cancelled', 'error']) {
    const e = (await f.invoke(w)).effects[0]; assert.equal((await upload(f, w, e, 'bytes')).status, 200);
    assert.equal((await complete(f, w, e, status)).status, 200); assert.equal((await complete(f, w, e, status)).status, 404);
  }
  assert.deepEqual(callbacks, [{ status: 'cancelled', files: [] }, { status: 'error', files: [] }]);
});

test('preflight size/count and actual streamed total are independent; overflow clears partial selection', async t => {
  const f = await fixture(t), callbacks = []; let maxFiles = 1;
  f.service.on('go', (s, e) => { if (e.action === 'selected') { callbacks.push(e.value); return; } return { ...choice, maxFiles }; });
  const w = await f.ws(['files']); let e = (await f.invoke(w)).effects[0];
  assert.equal((await upload(f, w, e, 'first')).status, 200);
  assert.equal((await upload(f, w, e, 'second')).status, 413);
  assert.equal((await complete(f, w, e, 'error')).status, 200);
  maxFiles = 4; e = (await f.invoke(w)).effects[0];
  assert.equal((await upload(f, w, e, Buffer.alloc(8 * 1024 * 1024 + 1))).status, 413);
  assert.equal((await complete(f, w, e, 'error')).status, 200);
  // Unknown Content-Length: real streaming reader, not merely metadata rejection.
  e = (await f.invoke(w)).effects[0];
  const { Readable } = await import('node:stream');
  const stream = Readable.from([Buffer.alloc(8 * 1024 * 1024), Buffer.from('x')]);
  assert.equal((await upload(f, w, e, stream, 'stream.bin', { duplex: 'half' })).status, 413);
  assert.equal((await complete(f, w, e, 'error')).status, 200);
  assert.ok(callbacks.every(c => c.status === 'error' && c.files.length === 0));
});

test('total budget rejects the next file before it is retained', async t => {
  const f = await fixture(t); f.service.on('go', (s, e) => e.action === 'selected' ? undefined : choice);
  const w = await f.ws(['files']), e = (await f.invoke(w)).effects[0];
  const bytes = Buffer.alloc(8 * 1024 * 1024);
  assert.equal((await upload(f, w, e, bytes)).status, 200); assert.equal((await upload(f, w, e, bytes)).status, 200);
  assert.equal((await upload(f, w, e, 'x')).status, 413);
  assert.equal((await complete(f, w, e, 'selected')).status, 409);
  assert.equal((await complete(f, w, e, 'error')).status, 200);
});

test('one outstanding chooser per stream; handler replacement/unload revokes the old request', async t => {
  const f = await fixture(t); const remove = f.service.on('go', () => choice);
  const w = await f.ws(['files']), e = (await f.invoke(w)).effects[0];
  assert.equal((await f.invoke(w)).effects.length, 0);
  remove(); f.service.on('go', () => choice);
  assert.equal((await upload(f, w, e, 'late')).status, 410);
  const fresh = (await f.invoke(w)).effects[0]; assert.notEqual(fresh.request, e.request);
  f.entry.fiber.uid++; f.hooks.get('internal/plugin')();
  assert.ok([404, 410].includes((await upload(f, w, fresh, 'late')).status));
});


test('host cache budget is shared across streams and freed on cancellation', async t => {
  const f = await fixture(t); f.service.on('go', (s, e) => e.action === 'selected' ? undefined : choice);
  const requests = [];
  const bytes = Buffer.alloc(8 * 1024 * 1024);
  for (let i = 0; i < 5; i++) {
    const w = await f.ws(['files']), e = (await f.invoke(w)).effects[0];
    requests.push([w, e]);
    if (i < 4) {
      assert.equal((await upload(f, w, e, bytes)).status, 200);
      assert.equal((await upload(f, w, e, bytes)).status, 200);
    }
  }
  const [blocked, effect] = requests[4];
  assert.equal((await upload(f, blocked, effect, 'x')).status, 429);
  assert.equal((await complete(f, ...requests[0], 'cancelled')).status, 200);
  assert.equal((await complete(f, blocked, effect, 'error')).status, 200);
  const fresh = (await f.invoke(blocked)).effects[0];
  assert.equal((await upload(f, blocked, fresh, bytes)).status, 200);
});

// Exercise actual stream revocation while the HTTP callback is already running.
// The AbortSignal is the gate; no elapsed-time assumption is needed.
for (const outcome of ['reject', 'resolve', 'status']) {
  test(`disconnected file callback ${outcome} preserves cancellation and health`, async t => {
    const f = await fixture(t);
    let enter;
    const entered = new Promise(resolve => { enter = resolve; });
    f.service.on('go', async (scope, event) => {
      if (event.action !== 'selected') return choice;
      const aborted = new Promise(resolve => event.signal.addEventListener('abort', resolve, { once: true }));
      enter();
      await aborted;
      if (outcome === 'reject') throw new Error('callback stopped after stream close');
      if (outcome === 'status') throw { status: 409, code: 'bad-request', message: 'callback status retained' };
    });
    const w = await f.ws(['files']), e = (await f.invoke(w)).effects[0];
    assert.equal((await upload(f, w, e, 'x')).status, 200);
    const pending = complete(f, w, e);
    await entered;
    w.socket.destroy();
    const result = await pending;
    // Read health before checking status so the original failure records both facts.
    const contributions = await (await f.request('contributions')).json();
    const violations = contributions.plugins.find(p => p.pkg === 'file-test').issues.filter(i => i.code === 'violation');
    t.diagnostic(JSON.stringify({ outcome, result, violations }));
    assert.deepEqual(violations, []);
    // A plugin's status-bearing object is passed through by complete; the
    // outer route still sanitizes non-HttpError objects to its existing 500.
    assert.equal(result.status, outcome === 'status' ? 500 : 410);
    assert.equal(result.error.code, outcome === 'status' ? 'plugin-error' : 'cancelled');
    if (outcome === 'status') assert.equal(result.error.message, 'internal error');
  });
}

test('current file callback ordinary rejection remains a counted plugin error', async t => {
  const f = await fixture(t);
  f.service.on('go', (scope, event) => {
    if (event.action !== 'selected') return choice;
    throw new Error('current callback failed');
  });
  const w = await f.ws(['files']), e = (await f.invoke(w)).effects[0];
  assert.equal((await upload(f, w, e, 'x')).status, 200);
  const result = await complete(f, w, e);
  assert.equal(result.status, 500);
  assert.equal(result.error.code, 'plugin-error');
  const contributions = await (await f.request('contributions')).json();
  const violation = contributions.plugins.find(p => p.pkg === 'file-test').issues.find(i => i.code === 'violation');
  assert.equal(violation.count, 1);
  assert.match(violation.message, /^plugin-error:/);
});

test('callback timeout invalidates handles and rejects a late async continuation', async t => {
  const f = await fixture(t, manifest, { handlerTimeoutMs: 25 });
  let signal, lateRead, resume;
  f.service.on('go', async (scope, event) => {
    if (event.action !== 'selected') return choice;
    signal = event.signal;
    const handle = event.value.files[0].handle;
    assert.equal(f.service.readPickedFile(handle).toString(), 'x');
    await new Promise(resolve => { resume = resolve; });
    assert.throws(() => f.service.readPickedFile(handle), /no longer readable/);
    lateRead = true;
  });
  const w = await f.ws(['files']), e = (await f.invoke(w)).effects[0];
  assert.equal((await upload(f, w, e, 'x')).status, 200);
  assert.equal((await complete(f, w, e)).status, 504);
  const contributions = await (await f.request('contributions')).json();
  const violation = contributions.plugins.find(p => p.pkg === 'file-test').issues.find(i => i.code === 'violation');
  assert.equal(violation.count, 1);
  assert.match(violation.message, /^timeout:/);
  assert.equal(signal.aborted, true); resume(); await delay(1); assert.equal(lateRead, true);
  assert.equal((await complete(f, w, e)).status, 404);
});

test('callback cannot create deferred side effects, including an eager rejected promise', async t => {
  const f = await fixture(t);
  f.service.on('go', (s, e) => e.action === 'selected'
    ? { pending: true, result: Promise.reject(new Error('discarded deferred callback')) } : choice);
  const w = await f.ws(['files']), e = (await f.invoke(w)).effects[0];
  assert.equal((await upload(f, w, e, 'x')).status, 200);
  const done = await complete(f, w, e);
  assert.equal(done.status, 200); assert.deepEqual(done.effects, []);
  assert.ok(done.issues.some(i => i.code === 'bad-effect'));
});

test('runnable example consumes actual uploaded bytes through its registered panel callback', async t => {
  const declaration = JSON.parse(readFileSync(new URL('../../examples/plugins/dsh-go-example-files/package.json', import.meta.url))).dshGo;
  const f = await fixture(t, declaration);
  applyFileExample({ inject: (deps, fn) => fn({ dshGo: f.service }) });
  const w = await f.ws(['files']);
  const response = await f.request('invoke', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({
    v: 1, pkg: 'file-test', id: 'files', surface: 'panel', action: 'chooseFiles', scope: { sessionId: 's1' }, stream: w.welcome.conn, userGesture: true,
  }) });
  assert.equal(response.status, 200);
  const effect = (await response.json()).effects[0];
  assert.equal(effect.type, 'pickFile');
  const bytes = Buffer.from('actual example file content');
  assert.equal((await upload(f, w, effect, bytes, 'example.txt')).status, 200);
  const done = await complete(f, w, effect);
  assert.equal(done.status, 200);
  assert.equal(done.effects[0].type, 'patch');
  assert.equal(done.effects[0].data.files[0].subtitle, createHash('sha256').update(bytes).digest('hex'));
  assert.equal(done.effects[0].data.files[0].trailing, `${bytes.length} B`);
});

test('panel callback names must be registered own actions, never inherited Object methods', async t => {
  const f = await fixture(t);
  f.service.panel('panel', { view: { type: 'text', text: 'Files' }, actions: {
    choose: () => ({ type: 'pickFile', action: 'constructor' }),
  } });
  const w = await f.ws(['files']);
  const response = await f.request('invoke', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({
    v: 1, pkg: 'file-test', id: 'panel', surface: 'panel', action: 'choose', stream: w.welcome.conn, userGesture: true,
  }) });
  const result = await response.json();
  assert.equal(response.status, 200); assert.deepEqual(result.effects, []);
  assert.ok(result.issues.some(i => i.code === 'bad-effect'));
});

// This one needs the OH ETS fixture's TypeScript, so only the OH gate runs it.
if (process.env.OHOS_TYPESCRIPT_PREFIX) {
 const {filesFixture,args,owner,until}=await import('./ohos/native-files-fixture.mjs');
 const {truncateChars}=await import('../bridge/dsh-go-bridge/lib/native/util.js');
 async function selection(t,name){
  const f=await filesFixture(t), bytes=Buffer.from('synthetic selection bytes'), file=await f.file(name,bytes);
  const result=f.call(f.methods,'pick',args());f.select([file.uri]);const reply=await result.done;
  assert(!reply.error,JSON.stringify(reply));const [entry]=reply.value;const chunks=[];
  while(true){const chunk=await f.call(f.methods,'read',{owner,handle:entry.handle}).done;assert(!chunk.error,JSON.stringify(chunk));if(chunk.value===null)break;chunks.push(Buffer.from(chunk.value));}
  const actual=Buffer.concat(chunks);assert.deepEqual(actual,bytes);
  await f.call(f.methods,'cancel',{owner}).done;await until(()=>f.fds.size===0);
  return {entry,bytes:actual};
 }
 test('real bridge callback receives MIME inferred before OH display truncation',async t=>{
  assert.equal([...truncateChars('😀'.repeat(30)+'a'.repeat(98)+'.jpg',128)].length,128);
  const declaration=JSON.parse(readFileSync(new URL('../../examples/plugins/dsh-go-example-files/package.json',import.meta.url))).dshGo;
  const f=await fixture(t,declaration);applyFileExample({inject:(_,fn)=>fn({dshGo:f.service})});const w=await f.ws(['files']);
  const response=await f.request('invoke',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({v:1,pkg:'file-test',id:'files',surface:'panel',action:'chooseFiles',scope:{sessionId:'s1'},stream:w.welcome.conn,userGesture:true})});
  assert.equal(response.status,200);const effect=(await response.json()).effects[0];
  const {entry,bytes}=await selection(t,'😀'.repeat(30)+'a'.repeat(98)+'.jpg');
  const sent=await f.request(filePath(w,effect,'upload',{name:entry.name,mediaType:entry.mediaType}),{method:'POST',headers:{'content-type':'application/octet-stream'},body:bytes});
  assert.equal(sent.status,200);const receipt=await sent.json();assert.equal(receipt.file.name,entry.name);assert.equal(receipt.file.mediaType,entry.mediaType);
  const done=await complete(f,w,effect);assert.equal(done.status,200);const shown=done.effects[0].data.files[0];
  assert.equal(shown.subtitle,createHash('sha256').update(bytes).digest('hex'));
  t.diagnostic(JSON.stringify({oh:entry,receipt,shown}));assert.equal(shown.icon,'image');
 });
}
