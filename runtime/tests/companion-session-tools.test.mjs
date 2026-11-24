import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import test from 'node:test';
import { createCompanionRoutes } from '../bridge/dsh-go-bridge/lib/companion/routes.js';

const base = '/dsh-go/v1/companion/session-tools/';
const definition = name => ({
  name, description: name + ' on the phone', input_schema: { type: 'object', properties: { text: { type: 'string' } } },
});
const offered = ['reminder', 'photos_recent', 'map_open', 'diary', 'relationship', 'remember', 'revise'].map(definition);

async function fixture(t) {
  const handlers = new Map(), registered = new Map();
  const session = { id: 'cabin' };
  const agent = { id: session.id, session, ctx: {
    plugin(plugin) {
      const entries = new Map();
      plugin.apply({ tools: {
        register(tool) { registered.set(tool.name, tool); entries.set(tool.name, tool); },
      } });
      return { await: async () => {}, dispose: async () => {
        for (const [name, tool] of entries) if (registered.get(name) === tool) registered.delete(name);
      } };
    },
  } };
  const services = {
    connection: { admit: req => ({ peer: { principal: { kind: req.headers.authorization } } }) },
    sessionController: { resolveAgent: async id => ({ agent: id === session.id ? agent : undefined }) },
    agents: new Map([[session.id, agent]]),
    agentPresets: { presetForSession: obj => obj === session ? 'dsh-go-companion-full' : 'other' },
  };
  const ctx = { get: key => services[key], on(name, handle) { handlers.set(name, handle); return () => handlers.delete(name); } };
  const routes = createCompanionRoutes({ ctx, send: (res, status, data) => {
    res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(data));
  } });
  const server = http.createServer((req, res) => routes.handle(req, res, req.url));
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => { await routes.dispose(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const post = (path, body, authorization = 'owner') => fetch('http://127.0.0.1:' + server.address().port + base + path, {
    method: 'POST', headers: { authorization, 'content-type': 'application/json' }, body: JSON.stringify(body),
  });
  const open = async (requestId = 'u1') => {
    const resp = await post('open', { sessionId: session.id, requestId, tools: offered });
    assert.equal(resp.status, 200);
    const reader = resp.body.pipeThrough(new TextDecoderStream()).getReader();
    let tail = '';
    async function next() {
      while (!tail.includes('\n')) {
        const { value, done } = await reader.read();
        if (done) return null;
        tail += value;
      }
      const end = tail.indexOf('\n'), line = tail.slice(0, end);
      tail = tail.slice(end + 1); return JSON.parse(line);
    }
    const ready = await next(); assert.equal(ready.type, 'ready');
    return { next, close: () => reader.cancel(), result: (data, overrides = {}) =>
      post('result', { token: ready.token, sessionId: session.id, requestId, ...data, ...overrides }) };
  };
  const claim = (requestId = 'u1', turn = 1, principal) =>
    handlers.get('agent/inbox/claimed')({ agent, message: { source: { kind: 'user', rpcId: requestId, principal } }, turn });
  const event = (type, data) => handlers.get('session/event')(session, { type, data });
  const call = (name, callId = 't1', args = {}, exec = {}) => registered.get('companion_' + name)
    .execute(args, { agent, callId, signal: new AbortController().signal, ...exec });
  return { post, open, claim, event, call, registered, services, agent };
}

test('authenticated phone is ready before the prompt; only a claimed owner turn can call it', async t => {
  const f = await fixture(t);
  assert.equal((await f.post('open', {}, 'guest')).status, 403);
  const missing = await f.post('open', { sessionId: 'wrong', requestId: 'u', tools: offered });
  assert.equal(missing.status, 409);
  assert.equal((await missing.json()).error.code, 'companion/device-session-unavailable');
  assert.equal((await f.post('open', { sessionId: 'cabin', requestId: 'u', tools: [definition('bash')] })).status, 400);
  const phone = await f.open();
  assert.throws(() => f.call('reminder'), /没有对应/);
  await f.claim('u1', 1, 'visitor');
  assert.throws(() => f.call('reminder'), /没有对应/);
  await f.claim();
  assert.throws(() => f.call('reminder', 'c2', {}, { agent: { ...f.agent } }), /没有对应/);
  const pending = f.call('reminder', 'c3', { text: '午饭' });
  assert.deepEqual(await phone.next(), { type: 'call', callId: 'c3', name: 'reminder', input: { text: '午饭' } });
  const body = { callId: 'c3', content: 'alarm registered', isError: false };
  assert.equal((await phone.result(body, { token: 'other phone' })).status, 409);
  assert.equal((await phone.result(body)).status, 200);
  assert.equal(await pending, 'alarm registered');
  assert.equal((await phone.result(body)).status, 409);
  assert.throws(() => f.call('reminder', 'c3'), /原回执/);
  await f.event('turn/end', { turn: 1 });
  assert.equal(await phone.next(), null); assert.equal(f.registered.size, 0);
});

test('late Android result cannot settle a new phone or a new claim; cancellation never replays', async t => {
  const f = await fixture(t), first = await f.open();
  await f.claim();
  const outcome = assert.rejects(f.call('photos_recent'), /手机结果未知/);
  assert.equal((await first.next()).name, 'photos_recent');
  const second = await f.open('u2');
  await outcome;
  assert.equal((await first.result({ callId: 't1', content: 'late', isError: false })).status, 409);
  assert.throws(() => f.call('map_open'), /没有对应/);
  await f.claim('u2', 2);
  const ctl = new AbortController(), cancelled = assert.rejects(f.call('map_open', 'c2', {}, { signal: ctl.signal }), /stop/);
  assert.equal((await second.next()).type, 'call');
  ctl.abort(Error('stop')); await cancelled;
  assert.deepEqual(await second.next(), { type: 'cancel', callId: 'c2' });
  assert.equal((await second.result({ callId: 'c2', content: 'late', isError: false })).status, 409);
  const nativeFailure = assert.rejects(f.call('reminder', 'c3'), /permission denied/);
  await second.next();
  assert.equal((await second.result({ callId: 'c3', content: 'permission denied', isError: true })).status, 200);
  await nativeFailure;
  await f.claim('other', 2); assert.equal(await second.next(), null);
});

test('host web calls narrow existing-memory mutations for this turn', async t => {
  const f = await fixture(t);
  const first = await f.open('u1'); await f.claim();
  await f.event('tool/call', { turn: 1, name: 'web_fetch' });
  // Reopening an already claimed id must not move its callback onto a fresh
  // phone or reset the per-turn restriction, even when the original went away.
  const same = await f.post('open', { sessionId: 'cabin', requestId: 'u1', tools: offered });
  assert.equal(same.status, 409);
  assert.equal((await same.json()).error.code, 'companion/device-request-in-use');
  assert.throws(() => f.call('revise'), /外部网页/);
  assert.throws(() => f.call('remember', 'c2', { card: 'old' }), /外部网页/);
  const add = f.call('remember', 'c3', { text: '新事实' });
  await first.next(); await first.result({ callId: 'c3', content: 'recorded', isError: false });
  assert.equal(await add, 'recorded');
  const second = await f.open('u2'); await f.claim('u2', 2);
  const revise = f.call('revise', 'c4', { card: 'old' });
  await second.next(); await second.result({ callId: 'c4', content: 'revised', isError: false });
  assert.equal(await revise, 'revised');
});

test('same request cannot re-enable an already performed reminder when its socket is lost', async t => {
  const f = await fixture(t), phone = await f.open(); await f.claim();
  const done = f.call('reminder', 'same');
  await phone.next(); await phone.result({ callId: 'same', content: 'set once', isError: false }); await done;
  await phone.close();
  const duplicate = await f.post('open', { sessionId: 'cabin', requestId: 'u1', tools: offered });
  assert.equal(duplicate.status, 409);
  assert.equal((await duplicate.json()).error.code, 'companion/device-request-in-use');
});

test('generic device control is never offered by the business callback; native names remain untouched', async t => {
  const f = await fixture(t);
  for (const name of ['phone_screen', 'mcp__phone__screen', 'bash']) {
    const response = await f.post('open', { sessionId: 'cabin', requestId: 'u', tools: [definition(name)] });
    assert.equal(response.status, 400);
    assert.equal(f.registered.size, 0);
  }
  await f.open();
  assert.equal(f.registered.has('companion_diary'), true);
  assert.equal(f.registered.has('companion_relationship'), true);
  assert.deepEqual([...f.registered.keys()], offered.map(tool => 'companion_' + tool.name));
});

test('a slow old resolver cannot replace a newer ready phone stream', async t => {
  const f = await fixture(t), entered = Promise.withResolvers(), resume = Promise.withResolvers();
  let first = true;
  f.services.sessionController.resolveAgent = async () => {
    if (first) { first = false; entered.resolve(); await resume.promise; }
    return { agent: f.agent };
  };
  const stale = f.post('open', { sessionId: 'cabin', requestId: 'old', tools: offered });
  await entered.promise;
  const current = await f.open('new');
  resume.resolve();
  const superseded = await stale;
  assert.equal(superseded.status, 409);
  assert.equal((await superseded.json()).error.code, 'companion/device-connection-replaced');
  await f.claim('new');
  const pending = f.call('reminder', 'r1');
  assert.equal((await current.next()).callId, 'r1');
  await current.result({ callId: 'r1', content: 'right phone', isError: false });
  assert.equal(await pending, 'right phone');
});
