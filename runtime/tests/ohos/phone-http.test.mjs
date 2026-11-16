import { symlinkFixture } from './host-link-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { once } from 'node:events';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Context } from '@deepseek-ai/cordis';
import { PhoneQueue } from '../../ohos/phone/queue.mjs';
import { registerPhoneRoutes } from '../../ohos/phone/routes.mjs';
import { listen, request } from '../../../tooling/ohos/tests/lifecycle-http-fixture.mjs';

const require = createRequire(import.meta.url), prefix = fileURLToPath(new URL('../../../node_modules', import.meta.url));
const authSource = await fs.readFile(require.resolve('@deepseek-ai/dsh-client-connection'), 'utf8');
assert(!/from\s+['"]\./.test(authSource));
const proof = 'c'.repeat(64);

async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'phone-http-'));
  await symlinkFixture(prefix, path.join(directory, 'node_modules'), 'dir');
  const authPath = path.join(directory, 'actual-auth.mjs');
  await fs.writeFile(authPath, authSource + '\nexport { BrowserAuth };\n');
  const { BrowserAuth, HostConnectionService } = await import(pathToFileURL(authPath));
  const ctx = new Context(), routes = new Map();
  ctx.provide('webServer', { host: '127.0.0.1', protocol: 'http:', register(route) {
    routes.set(route.path, route.handler); return () => routes.delete(route.path);
  } });
  const auth = new BrowserAuth(ctx, Buffer.alloc(32, 41), 1), connection = new HostConnectionService(ctx, [], auth);
  const state = { available: true, foreground: true, nowMs: 1000, engineId: 'http-unit-engine', bridgeGeneration: 1,
    ownerHash: createHash('sha256').update(proof).digest('hex') };
  const seen = { claims: 0, complete: 0 };
  // Native permit is a declared seam fixture here; these tests prove real HTTP/auth/queue semantics only.
  const queue = new PhoneQueue({ snapshot: () => ({ ...state }), claim: () => { seen.claims++; return true; },
    revoke: () => false, complete: () => { seen.complete++; return true; } });
  const subscriptions = [], removals = [];
  const subscribe = queue.subscribe.bind(queue);
  let onSubscribe = null, onRemove = null;
  queue.subscribe = callback => {
    const dispose = subscribe(callback); subscriptions.push(callback); onSubscribe?.();
    return () => { dispose(); removals.push(callback); onRemove?.(); };
  };
  registerPhoneRoutes(ctx, queue);
  t.after(async () => { queue.close(); await ctx.fiber.dispose(); await fs.rm(directory, { recursive: true, force: true }); });
  const { origin } = await listen(t, async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/') { if (connection.authorizeIndex(req, res)) res.end('index'); }
    else if (routes.has(url.pathname)) await routes.get(url.pathname)(req, res);
    else { res.writeHead(404); res.end(); }
  });
  const login = await request(origin + '/?token=' + encodeURIComponent(auth.launchToken));
  assert.equal(login.status, 303);
  const cookie = login.headers['set-cookie'][0].split(';')[0];
  const owner = { v: 1, engineId: state.engineId, bridgeGeneration: 1, owner: proof };
  const headers = { cookie, 'content-type': 'application/json' };
  const post = (action, body = {}, extra = {}) => request(origin + '/dsh-go/v1/phone/' + action,
    { method: 'POST', headers: { ...headers, ...extra }, body: JSON.stringify({ ...owner, ...body }) });
  let calls = 0;
  const enqueue = () => {
    const abort = new AbortController();
    const result = queue.enqueue({ sessionId: '真实HTTP会话', callId: `http-call-${++calls}`, tool: 'mcp__phone__open',
      args: { url: 'https://example.test/中文' }, signal: abort.signal });
    return { result, abort };
  };
  return { ctx, origin, headers, owner, state, queue, seen, post, enqueue,
    subscribed() { const ready = Promise.withResolvers(); onSubscribe = ready.resolve; return ready.promise; },
    removed() { const ready = Promise.withResolvers(); onRemove = ready.resolve; return ready.promise; },
    counts: () => ({ subscriptions: subscriptions.length, removals: removals.length }) };
}

test('actual signed cookie plus distinct native owner is required on every phone route', async t => {
  const f = await fixture(t), pending = f.enqueue();
  for (const action of ['next', 'claim', 'result', 'cancel']) {
    assert.equal((await f.post(action, {}, { cookie: 'dsh-auth-invalid=forged' })).status, 401);
    assert.equal((await f.post(action, {}, { origin: 'https://evil.invalid' })).status, 403);
    assert.equal((await f.post(action, {}, { host: 'evil.invalid' })).status, 403);
  }
  const wrong = await f.post('next', { owner: 'd'.repeat(64) });
  assert.equal(wrong.status, 403); assert(!wrong.text.includes(proof)); assert(!wrong.text.includes('真实HTTP会话'));
  const next = await f.post('next'); assert.equal(next.status, 200);
  assert.equal(next.headers['cache-control'], 'no-store');
  assert.equal(JSON.parse(next.text).request.sessionId, '真实HTTP会话');
  assert.equal(f.seen.claims, 0); pending.abort.abort(); await pending.result;
  t.diagnostic(JSON.stringify({ actualAuthSourceSHA256: createHash('sha256').update(authSource).digest('hex'), native: 'unit seam, not device' }));
});

test('method, unknown fields, malformed UTF8 and oversized controls reject before native admission', async t => {
  const f = await fixture(t);
  assert.equal((await request(f.origin + '/dsh-go/v1/phone/next', { headers: f.headers })).status, 405);
  assert.equal((await f.post('next', { args: { forged: true } })).status, 400);
  assert.equal((await f.post('next', { v: 2 })).status, 400);
  assert.equal((await f.post('next', {}, { 'content-type': 'text/plain' })).status, 415);
  for (const body of [Buffer.from([0xff]), Buffer.alloc(16_385, 0x20)]) {
    const result = await request(f.origin + '/dsh-go/v1/phone/next', { method: 'POST', headers: f.headers, body });
    assert.equal(result.status, body.length > 16_384 ? 413 : 400);
  }
  assert.equal(f.seen.claims, 0);
});

test('actual HTTP claim/result retains one execution identity and rejects forged evidence', async t => {
  const f = await fixture(t), pending = f.enqueue();
  const task = JSON.parse((await f.post('next')).text).request;
  const claim = await f.post('claim', { requestId: task.requestId }); assert.equal(claim.status, 200);
  const lease = JSON.parse(claim.text), identity = { requestId: task.requestId, executionNonce: lease.executionNonce };
  assert.equal((await f.post('claim', { requestId: task.requestId })).status, 410);
  const result = { status: 'succeeded', effect: 'opened_ui', evidence: 'opened_ui', dispatched: true, code: 'ok', message: '已打开系统界面。' };
  assert.equal((await f.post('result', { ...identity, result: { ...result, evidence: 'user_confirmed' } })).status, 400);
  assert.equal(f.seen.complete, 0);
  const first = await f.post('result', { ...identity, result }); assert.equal(first.status, 200);
  assert.deepEqual(JSON.parse((await f.post('result', { ...identity, result })).text), JSON.parse(first.text));
  assert.equal((await f.post('result', { ...identity, result: { ...result, message: 'changed' } })).status, 409);
  assert.deepEqual(await pending.result, result); assert.equal(f.seen.claims, 1); assert.equal(f.seen.complete, 1);
});

test('unauthorized polling cannot replace a legitimate long read; reconnect replaces only the old read', async t => {
  const f = await fixture(t), ready = f.subscribed(), first = f.post('next'); await ready;
  assert.equal(f.queue.status().listeners, 1);
  assert.equal((await f.post('next', { owner: 'e'.repeat(64) })).status, 403);
  assert.equal(f.queue.status().listeners, 1);
  const readyAgain = f.subscribed(), second = f.post('next'); await readyAgain;
  assert.equal((await first).status, 409); assert.equal(f.queue.status().listeners, 1);
  const pending = f.enqueue(), received = await second;
  assert.equal(received.status, 200); assert.equal(JSON.parse(received.text).request.callId, 'http-call-1');
  assert.equal(f.queue.status().listeners, 0); pending.abort.abort(); await pending.result;
});

test('closing a real client socket releases its waiting subscription and timeout', async t => {
  const f = await fixture(t), ready = f.subscribed(), removed = f.removed();
  const req = http.request(f.origin + '/dsh-go/v1/phone/next', { method: 'POST', headers: f.headers });
  const closed = once(req, 'error'); req.end(JSON.stringify(f.owner)); await ready;
  req.destroy(new Error('intentional unit client disconnect')); await closed; await removed;
  assert.equal(f.queue.status().listeners, 0); assert.equal(f.queue.status().timer, false);
  assert.deepEqual(f.counts(), { subscriptions: 1, removals: 1 });
});

test('disposing the real route scope terminates its outstanding HTTP long read', async t => {
  const f = await fixture(t), ready = f.subscribed(), read = f.post('next'); await ready;
  await f.ctx.fiber.dispose(); assert.equal((await read).status, 410);
  assert.equal(f.queue.status().listeners, 0);
});
