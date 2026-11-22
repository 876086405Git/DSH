import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { readFile } from 'node:fs/promises';
import { createCompanionRoutes } from '../bridge/dsh-go-bridge/lib/companion/routes.js';
import { FULL_PRESET } from '../bridge/dsh-go-bridge/lib/companion/prompt-context.js';
import { deferred, lookupPeer, lookupSource } from './fixtures/companion-lookup-source.mjs';
import { auxiliarySse, piAiSourceFixture } from './fixtures/companion-auxiliary-source.mjs';
import { chatSourceFixture } from './fixtures/companion-chat-usage-source.mjs';
import { estimateLookupInputTokens } from '../bridge/dsh-go-bridge/lib/companion/lookup-input.js';

const PATH = '/dsh-go/v1/companion/lookup';
const webSource = process.env.DSH_LOOKUP_SOURCE, llmSource = process.env.DSH_AUXILIARY_SOURCES;
const sourceTest = (name, fn) => test(name, { skip: webSource ? false : 'Set DSH_LOOKUP_SOURCE to the verified E01 plugin source' }, fn);
const answerTest = (name, fn) => test(name, { skip: webSource && llmSource ? false : 'Set DSH_LOOKUP_SOURCE and DSH_AUXILIARY_SOURCES to verified sources' }, fn);
const task = { placeName: '城市博物馆', city: '测试城市', localDate: '2026-11-21', zoneId: 'Asia/Shanghai', question: '原约定日期是否开门？' };
const source = { fetchRequestId: 'fetched-page', url: 'https://museum.invalid/notice', title: '馆方公告',
  content: '2026 年 11 月 21 日临时闭馆。UNTRUSTED_PAGE_SENTINEL', fetchedAtMs: 1795280000000 };

// Actual production route -> locked provider/dispatcher -> real loopback HTTP.
// Cordis registration, owner admission and credentials are explicit fixture
// services. This does not boot the engine or contact a paid/public endpoint.
async function fixture(t, options = {}) {
  const peer = await lookupPeer(t, options.respond ?? ((_request, response) => {
    response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
    response.end(JSON.stringify({ results: [{ url: source.url, title: source.title, snippet: '短摘要', date: null }] }));
  }));
  const plugin = await lookupSource(webSource, peer.baseURL, options);
  t.after(() => plugin.dispose());
  const state = { selected: { provider: 'chosen-provider', model: 'chosen-model' }, owner: true,
    resolves: 0, web: plugin.web, deadlineAtMs: Date.now() + 60000 };
  const engine = options.model ? await chatSourceFixture(llmSource, {
    lookupWindow: true,
    authGate: options.modelAuthGate,
    onAuth: options.modelAuthEntered?.resolve,
    transport(url, init) {
      assert.equal(new URL(url).hostname, '127.0.0.1', 'the answer uses only a numeric loopback endpoint');
      return globalThis.fetch(url, init);
    },
  }) : undefined;
  if (engine) engine.connection.baseURL = peer.baseURL.replace('/v1/tools', '/anthropic');
  if (engine) t.after(() => engine.dispose());
  state.llm = engine?.llm ?? { companionAuxiliaryCapability: () => undefined };
  const session = { id: 'session', deriveMessages() { throw new Error('lookup must not read Session history'); },
    append() { throw new Error('lookup must not persist Session events'); } };
  const agent = { id: 'session', session, model: { current: () => state.selected } };
  const listeners = new Map();
  const ctx = { get(name) { return {
    llm: state.llm, web: state.web,
    connection: { admit: req => state.owner && req.headers.authorization === 'owner'
      ? { peer: { principal: { kind: 'owner' } } } : { rejection: req.headers.authorization === 'anonymous' ? 401 : 403 } },
    sessionController: { async resolveAgent(id) { state.resolves++; return id === 'session' ? { agent } : undefined; } },
    agentPresets: { presetForSession: () => state.wrongPreset ? 'other' : FULL_PRESET },
    agents: { get: id => id === 'session' && !state.retired ? agent : undefined },
  }[name]; }, on(name, fn) { listeners.set(name, fn); return () => listeners.delete(name); } };
  agent.ctx = ctx;
  const route = createCompanionRoutes({ ctx, store: {}, send(res, status, body) {
    res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body));
  } });
  const server = createServer((req, res) => { void route.handle(req, res, new URL(req.url, 'http://local').pathname); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const origin = `http://127.0.0.1:${server.address().port}`;
  t.after(async () => { route.dispose(); server.closeAllConnections(); await new Promise(done => server.close(done)); });
  async function http({ path = PATH + '?sessionId=session', method = 'GET', body, auth = 'owner', type = 'application/json', signal } = {}) {
    const response = await fetch(origin + path, { method, headers: { authorization: auth, 'content-type': type },
      ...(body === undefined ? {} : { body: typeof body === 'string' ? body : JSON.stringify(body) }), signal });
    const text = await response.text();
    return { status: response.status, body: response.headers.get('content-type').startsWith('application/x-ndjson')
      ? text.trim().split('\n').map(line => JSON.parse(line)) : JSON.parse(text) };
  }
  const info = await http();
  const body = (extra = {}) => ({ v: 1, instanceId: info.body.instanceId, requestId: 'request', sessionId: 'session',
    taskId: 'task', taskRev: 1, deadlineAtMs: state.deadlineAtMs, provider: state.selected.provider, model: state.selected.model,
    kind: 'search', task, payload: { query: '城市博物馆 2026-11-21 官方临时公告' }, ...extra });
  const post = extra => http({ path: PATH, method: 'POST', body: body(extra) });
  const receipt = id => http({ path: `${PATH}/requests/${id}?instanceId=${info.body.instanceId}` });
  const fence = extra => http({ path: PATH + '/fence', method: 'POST', body: { v: 1,
    instanceId: info.body.instanceId, sessionId: 'session', taskId: 'task', taskRev: 1,
    cancelled: true, deadlineAtMs: state.deadlineAtMs, ...extra } });
  return { peer, plugin, state, engine, info, body, post, receipt, fence, http, route, origin };
}

sourceTest('lookup owner and exact narrow wire validation reject before provider preparation', async t => {
  const f = await fixture(t), baseline = f.state.resolves;
  for (const [auth, status] of [['reader', 403], ['anonymous', 401]]) {
    const denied = await f.http({ path: PATH, method: 'POST', body: f.body(), auth });
    assert.equal(denied.status, status); assert.equal(denied.body.dispatched, false);
  }
  for (const [body, type, status] of [[f.body(), 'text/plain', 415], ['{', 'application/json', 400],
    [f.body({ system: 'arbitrary' }), 'application/json', 400], [f.body({ kind: 'chat' }), 'application/json', 400],
    [f.body({ payload: { query: '字'.repeat(129) } }), 'application/json', 400],
    [f.body({ task: { ...task, localDate: '2026-02-30' } }), 'application/json', 400],
    [f.body({ task: { ...task, history: [] } }), 'application/json', 400],
    [f.body({ payload: { query: '\ud800' } }), 'application/json', 400],
    [f.body({ kind: 'fetch', payload: { url: 'https://user:password@museum.invalid/' } }), 'application/json', 400],
    [f.body({ kind: 'answer', payload: { sources: [] } }), 'application/json', 400],
    [f.body({ kind: 'answer', payload: { sources: [{ ...source, history: [] }] } }), 'application/json', 400],
    ['x'.repeat(65537), 'application/json', 413],
    [JSON.stringify(f.body()).replace('"taskRev":1', '"taskRev":1,"taskRev":2'), 'application/json', 400]]) {
    const r = await f.http({ path: PATH, method: 'POST', body, type });
    assert.equal(r.status, status); assert.equal(r.body.dispatched, false);
  }
  assert.equal(f.state.resolves, baseline); assert.equal(f.plugin.credentialReads.length, 0); assert.equal(f.peer.requests.length, 0);
});

sourceTest('lookup search reaches actual Direct Search HTTP with fixed controls and streams untouched raw results', async t => {
  const raw = { results: [{ url: source.url, title: source.title, snippet: '摘'.repeat(350), summary: 'raw-summary',
    date: '2026-11-20', provider_extension: { authority: 'not inferred' } }], extra: 'raw-only' };
  const f = await fixture(t, { respond(_request, res) { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(raw)); } });
  assert.deepEqual(f.info.body.direct, { search: true, fetch: true, physicalDispatch: 'fetch-invoked', maxPhysicalRequests: 1 });
  assert.equal(f.info.body.answer, null, 'tool availability does not invent a model channel');
  const response = await f.post(), last = response.body.at(-1);
  assert.equal(response.status, 200);
  assert.deepEqual(response.body.map(event => event.type), ['accepted', 'dispatch', 'http', 'provider-result', 'finish']);
  assert.equal(response.body[1].boundary, 'fetch-invoked'); assert(Number.isSafeInteger(response.body[1].atMs));
  assert.deepEqual(response.body[3].raw, raw);
  assert.equal(last.dispatched, true); assert.equal(last.httpStatus, 200); assert.equal(last.complete, true);
  assert.equal(last.terminal, 'complete'); assert.equal(last.usage, null); assert.equal(last.bodyRetained, false);
  assert.equal(f.peer.requests.length, 1);
  assert.equal(f.peer.requests[0].url, '/v1/tools/search');
  assert.deepEqual(f.peer.requests[0].body, { query: f.body().payload.query, count: 5, need_content: false });
  assert.equal(f.peer.requests[0].headers.authorization, 'Bearer synthetic-lookup-key');
  const receipt = (await f.receipt('request')).body;
  assert.equal(receipt.bodyRetained, false); assert.equal(receipt.finish.result.metadataOnly, true);
  assert.equal([...receipt.finish.result.sources[0].snippet].length, 300);
  for (const secret of ['raw-only', 'raw-summary', 'UNRELATED_PRIVATE_PROMPT', 'synthetic-lookup-key']) assert(!JSON.stringify(receipt).includes(secret));
});

sourceTest('lookup Fetch body travels only in provider-result and cannot be recovered by metadata GET', async t => {
  const raw = { title: source.title, content: source.content, opaque_provider_field: 17 };
  const f = await fixture(t, { respond(_req, res) { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(raw)); } });
  const response = await f.post({ kind: 'fetch', payload: { url: source.url } });
  assert.deepEqual(f.peer.requests[0].body, { url: source.url });
  assert.equal(f.peer.requests[0].url, '/v1/tools/fetch');
  assert.deepEqual(response.body.find(event => event.type === 'provider-result').raw, raw);
  assert.deepEqual(response.body.at(-1).result, { url: source.url });
  const receipt = (await f.receipt('request')).body;
  assert.equal(receipt.finish.httpStatus, 200); assert.equal(receipt.finish.bodyRetained, false);
  assert(!JSON.stringify(receipt).includes(source.content)); assert(!JSON.stringify(receipt).includes('statusCode'));
  const duplicate = await f.post({ kind: 'fetch', payload: { url: source.url } });
  assert.equal(duplicate.body.error.code, 'companion/lookup-request-used');
  assert.equal(duplicate.body.dispatched, null); assert.equal(duplicate.body.receipt.finish.dispatched, true);
  assert.equal(f.peer.requests.length, 1, 'reading or retrying the same ID never fetches the page again');
});

for (const [name, payload, complete, terminal] of [
  ['empty search', { results: [] }, true, 'complete'],
  ['decoded invalid schema', { results: 'not a list' }, true, 'invalid_response'],
  ['malformed JSON', '{', false, 'invalid_response'],
]) sourceTest(`lookup preserves ${name} without inventing a provider result`, async t => {
  const f = await fixture(t, { respond(_req, res) { res.writeHead(200, { 'content-type': 'application/json' }); res.end(typeof payload === 'string' ? payload : JSON.stringify(payload)); } });
  const response = await f.post(), last = response.body.at(-1);
  assert.equal(last.dispatched, true); assert.equal(last.httpStatus, 200);
  assert.equal(last.complete, complete); assert.equal(last.terminal, terminal);
  assert.equal(response.body.some(event => event.type === 'provider-result'), complete);
  assert.equal(f.peer.requests.length, 1);
});

sourceTest('lookup actual HTTP error is a known tool status, with no fabricated target status or automatic retry', async t => {
  const f = await fixture(t, { respond(_req, res) { res.writeHead(429, { 'content-type': 'application/json' }); res.end('{"error":"synthetic upstream error"}'); } });
  const response = await f.post(), last = response.body.at(-1);
  assert.equal(last.dispatched, true); assert.equal(last.httpStatus, 429); assert.equal(last.complete, false);
  assert.equal(last.terminal, 'http_error'); assert.equal(last.result, null); assert.equal(last.usage, null);
  assert.equal(response.body.some(event => event.type === 'provider-result'), false);
  assert(!JSON.stringify(response.body).includes('synthetic upstream error'));
  assert.equal(f.peer.requests.length, 1);
});

sourceTest('lookup missing credential or hook produces a proven preflight false without falling back to global web', async t => {
  const f = await fixture(t, { missingKey: true });
  assert.equal(f.info.body.direct.search, false);
  const missing = await f.post(); assert.equal(missing.body.at(-1).dispatched, false);
  f.state.web = { search() { throw new Error('must not use global search fallback'); } };
  const absent = await f.post({ requestId: 'absent-hook' });
  assert.equal(absent.body.at(-1).error.code, 'companion/lookup-unavailable');
  assert.equal(absent.body.at(-1).dispatched, false); assert.equal(f.peer.requests.length, 0);
});

sourceTest('lookup rejects same-ID conflict and unknown prior instance without claiming an earlier call was free', async t => {
  const f = await fixture(t); await f.post();
  const conflict = await f.post({ payload: { query: 'changed query' } });
  assert.equal(conflict.body.error.code, 'companion/lookup-request-conflict'); assert.equal(conflict.body.dispatched, null);
  const old = await f.post({ requestId: 'old', instanceId: 'retired-instance' });
  assert.equal(old.body.error.code, 'companion/lookup-instance-changed'); assert.equal(old.body.dispatched, null);
  const unknown = await f.receipt('missing');
  assert.equal(unknown.body.error.code, 'companion/lookup-request-unknown'); assert.equal(unknown.body.dispatched, null);
  assert.equal(f.peer.requests.length, 1);
});

for (const change of ['owner', 'model', 'retire', 'config', 'new-revision']) sourceTest(`lookup ${change} change during real credential resolution prevents final HTTP dispatch`, async t => {
  const entered = deferred(), gate = deferred();
  const f = await fixture(t, { authEntered: entered, authGate: gate.promise });
  const pending = f.post(); await entered.promise;
  assert.equal((await f.receipt('request')).body.dispatched, null, 'accepted is not a durable not-sent receipt');
  if (change === 'owner') f.state.owner = false;
  if (change === 'model') f.state.selected = { provider: 'other', model: 'other' };
  if (change === 'retire') f.state.retired = true;
  if (change === 'config') f.plugin.values.baseURL = f.peer.baseURL + '/changed';
  if (change === 'new-revision') assert.equal((await f.fence({ taskRev: 2, cancelled: false })).status, 200);
  gate.resolve(); const response = await pending;
  assert.equal(response.body.at(-1).dispatched, false); assert.equal(f.peer.requests.length, 0);
  assert.equal(f.plugin.network.length, 0);
});

sourceTest('lookup a received cancellation fences reordered old calls and a same-revision deadline cannot be renewed', async t => {
  const f = await fixture(t);
  assert.equal((await f.fence()).status, 200);
  const cancelled = await f.post(); assert.equal(cancelled.status, 409); assert.equal(cancelled.body.dispatched, false);
  assert.equal((await f.fence({ cancelled: false })).status, 409);
  assert.equal((await f.fence({ taskRev: 2, cancelled: false })).status, 200);
  const renewed = await f.post({ taskRev: 2, deadlineAtMs: f.state.deadlineAtMs + 1 });
  assert.equal(renewed.status, 409); assert.equal(renewed.body.error.code, 'companion/lookup-task-conflict');
  const expired = await f.post({ taskId: 'expired', deadlineAtMs: Date.now() - 1 });
  assert.equal(expired.body.error.code, 'companion/lookup-expired'); assert.equal(expired.body.dispatched, false);
  assert.equal(f.peer.requests.length, 0);
});

sourceTest('lookup known fences do not pretend to observe a revision that only the phone has committed', async t => {
  const f = await fixture(t);
  // No rev2 fence reaches this host: rev1 is honestly the latest received state.
  const old = await f.post(); assert.equal(old.body.at(-1).dispatched, true);
  assert.equal((await f.fence({ taskRev: 2 })).status, 200);
  assert.equal((await f.post({ requestId: 'late-old' })).status, 409);
  assert.equal((await f.receipt('request')).body.finish.taskRev, 1);
  assert.equal(f.peer.requests.length, 1);
});

sourceTest('lookup pending/busy metadata cannot become false while an authorized call can still dispatch', async t => {
  const entered = deferred(), gate = deferred();
  const f = await fixture(t, { authEntered: entered, authGate: gate.promise });
  const pending = f.post(); await entered.promise;
  const receipt = (await f.receipt('request')).body;
  assert.equal(receipt.phase, 'accepted'); assert.equal(receipt.dispatched, null);
  const busy = await f.post({ requestId: 'busy' });
  assert.equal(busy.body.error.code, 'companion/lookup-busy'); assert.equal(busy.body.dispatched, false);
  gate.resolve(); assert.equal((await pending).body.at(-1).dispatched, true);
  assert.equal(f.peer.requests.length, 1);
});

sourceTest('lookup disconnect after actual HTTP headers keeps sent metadata but no recoverable page body', async t => {
  const f = await fixture(t, { respond(_req, res) {
    res.writeHead(200, { 'content-type': 'application/json' }); res.write('{"content":"partial');
  } });
  const abort = new AbortController();
  const response = await fetch(f.origin + PATH, { method: 'POST', headers: { authorization: 'owner', 'content-type': 'application/json' },
    body: JSON.stringify(f.body({ kind: 'fetch', payload: { url: source.url } })), signal: abort.signal });
  const reader = response.body.getReader(), decoder = new TextDecoder();
  let buffer = '';
  while (!buffer.includes('"type":"http"')) {
    const chunk = await reader.read(); assert.equal(chunk.done, false); buffer += decoder.decode(chunk.value, { stream: true });
  }
  abort.abort(); await reader.cancel().catch(() => {});
  let receipt;
  for (let i = 0; i < 50; i++) {
    receipt = (await f.receipt('request')).body;
    if (receipt.phase === 'finished') break;
  }
  assert.equal(receipt.phase, 'finished'); assert.equal(receipt.finish.dispatched, true);
  assert.equal(receipt.finish.httpStatus, 200); assert.equal(receipt.finish.complete, false);
  assert.equal(receipt.bodyRetained, false); assert.equal(receipt.finish.result, null);
  assert.equal((await f.post({ kind: 'fetch', payload: { url: source.url } })).status, 409);
  assert.equal(f.peer.requests.length, 1);
});

answerTest('lookup answer reaches actual locked model HTTP with the shared fixed prompt, current model and original sources only', async t => {
  const rawFinal = { input_tokens: 23, output_tokens: 7, cache_read_input_tokens: 9, vendor_field: 'preserved' };
  const f = await fixture(t, { model: true, async respond(_req, res) {
    res.writeHead(200, { 'content-type': 'text/event-stream' }); res.end(await auxiliarySse({ finalUsage: rawFinal }).text());
  } });
  const golden = JSON.parse(await readFile(new URL('../../tooling/companion/fixtures/public-lookup-answer.json', import.meta.url), 'utf8'));
  const response = await f.post({ kind: 'answer', payload: { sources: [source] } }), last = response.body.at(-1);
  assert.equal(last.terminal, 'complete'); assert.equal(last.dispatched, true); assert.equal(last.complete, true);
  assert.equal(last.usage.output_tokens, 7); assert.deepEqual(last.usage.final_usage, rawFinal);
  assert.equal(f.peer.requests.length, 1); assert.equal(f.plugin.network.length, 0);
  const body = f.peer.requests[0].body;
  assert.equal(body.model, 'chosen-model'); assert.equal(body.max_tokens, 800); assert.equal(body.stream, true);
  assert.deepEqual(body.thinking, { type: 'disabled' });
  assert.equal(body.system, golden.system);
  assert.equal(body.messages.length, 1); assert.equal(body.messages[0].role, 'user');
  assert.deepEqual(JSON.parse(body.messages[0].content[0].text), { task, sources: [source] });
  assert(!Object.hasOwn(body, 'tools')); assert(!Object.hasOwn(body, 'tool_choice'));
  assert(!JSON.stringify(body).includes('UNRELATED_PRIVATE_PROMPT'));
  assert.deepEqual(last.inputBudget, { estimatedTokens: estimateLookupInputTokens(JSON.stringify(body)),
    outputReserve: 800, contextWindow: 8192, scope: 'provider-request', estimator: 'companion-heuristic-v1' });
  assert(!JSON.stringify(last.inputBudget).includes('synthetic-test-only'));
  const receipt = (await f.receipt('request')).body;
  assert.equal(receipt.finish.result.text, '{"items":[]}', 'transport retains model bytes; it does not claim their E schema or semantics passed');
  assert(!JSON.stringify(receipt).includes(source.content));
});

answerTest('lookup generic current provider keeps normalized usage distinct and physical dispatch unknown', async t => {
  const f = await fixture(t, { model: true });
  const pi = await piAiSourceFixture(llmSource, f.engine);
  f.engine.llm.adapters.set(pi.provider, { provider: { id: pi.provider, name: 'Chosen pi-ai' }, adapter: pi.adapter });
  f.state.selected = { provider: pi.provider, model: pi.model.id };
  const response = await f.post({ kind: 'answer', payload: { sources: [source] } }), last = response.body.at(-1);
  assert.equal(last.dispatched, null); assert.equal(last.dispatchAtMs, null); assert.equal(last.terminal, 'complete');
  assert.equal(last.usage.final_usage, null); assert.equal(last.usage.input_uncached, null); assert.equal(last.usage.output_tokens, null);
  assert.equal(last.usage.runtime_normalized_usage[0].outputTokens, 2);
  assert.equal(pi.calls.length, 1); assert.equal(pi.calls[0].options.maxRetries, 0);
  assert.equal(last.inputBudget.scope, 'adapter-input'); assert.equal(last.inputBudget.contextWindow, 8192);
  assert.equal(f.peer.requests.length, 0, 'pi-ai downstream streamSimple is an explicit fixture, not a physical HTTP claim');
});

answerTest('lookup answer model change during real credential preparation prevents final model HTTP', async t => {
  const gate = deferred(); const f = await fixture(t, { model: true, modelAuthGate: gate.promise });
  const pending = f.post({ kind: 'answer', payload: { sources: [source] } });
  let accepted;
  for (let i = 0; i < 50; i++) {
    accepted = await f.receipt('request');
    if (accepted.status === 200) break;
  }
  assert.equal(accepted.body.dispatched, null);
  f.state.selected = { provider: 'changed', model: 'changed' }; gate.resolve();
  const response = await pending;
  assert.equal(response.body.at(-1).dispatched, false); assert.equal(f.peer.requests.length, 0);
});

answerTest('lookup rejects the full final request above 12k estimated input before any model HTTP', async t => {
  const f = await fixture(t, { model: true });
  f.engine.connection.models[0].contextWindow = 100000;
  const response = await f.post({ kind: 'answer', payload: { sources: [{ ...source, content: '馆'.repeat(20000) }] } });
  const last = response.body.at(-1);
  assert.equal(response.status, 200); assert.equal(last.dispatched, false);
  assert.equal(last.error.code, 'companion/lookup-input-limit'); assert.equal(last.terminal, 'preflight_error');
  assert(last.inputBudget.estimatedTokens > 12000); assert.equal(last.inputBudget.contextWindow, 100000);
  assert.equal(last.inputBudget.scope, 'provider-request'); assert.equal(f.peer.requests.length, 0);
});

answerTest('lookup reserves all 800 output tokens within the same prepared model window', async t => {
  const f = await fixture(t, { model: true, async respond(_req, res) {
    res.writeHead(200, { 'content-type': 'text/event-stream' }); res.end(await auxiliarySse().text());
  } });
  const first = await f.post({ kind: 'answer', payload: { sources: [source] } });
  const amount = first.body.at(-1).inputBudget.estimatedTokens;
  assert(amount < 12000); assert.equal(f.peer.requests.length, 1);
  f.engine.connection.models[0].contextWindow = amount + 799;
  const tooSmall = await f.post({ requestId: 'small-window', kind: 'answer', payload: { sources: [source] } });
  assert.equal(tooSmall.body.at(-1).dispatched, false);
  assert.equal(tooSmall.body.at(-1).inputBudget.estimatedTokens, amount);
  assert.equal(f.peer.requests.length, 1);
  f.engine.connection.models[0].contextWindow = amount + 800;
  const exact = await f.post({ requestId: 'exact-window', kind: 'answer', payload: { sources: [source] } });
  assert.equal(exact.body.at(-1).dispatched, true); assert.equal(f.peer.requests.length, 2);
});

answerTest('lookup uses the captured preparation window rather than a later larger model-info lookup', async t => {
  const entered = deferred(), gate = deferred();
  const f = await fixture(t, { model: true, modelAuthEntered: entered, modelAuthGate: gate.promise });
  f.engine.connection.models[0].contextWindow = 2048;
  const pending = f.post({ kind: 'answer', payload: { sources: [{ ...source, content: 'x'.repeat(10000) }] } });
  await entered.promise;
  f.engine.connection.models[0].contextWindow = 100000;
  gate.resolve(); const last = (await pending).body.at(-1);
  assert.equal(last.dispatched, false); assert.equal(last.inputBudget.contextWindow, 2048);
  assert(last.inputBudget.estimatedTokens < 12000); assert.equal(f.peer.requests.length, 0);
});

answerTest('lookup generic adapter input over budget rejects before adapter handoff', async t => {
  const f = await fixture(t, { model: true });
  const pi = await piAiSourceFixture(llmSource, f.engine);
  f.engine.llm.adapters.set(pi.provider, { provider: { id: pi.provider, name: 'Chosen pi-ai' }, adapter: pi.adapter });
  f.state.selected = { provider: pi.provider, model: pi.model.id };
  const last = (await f.post({ kind: 'answer', payload: { sources: [{ ...source, content: '馆'.repeat(20000) }] } })).body.at(-1);
  assert.equal(last.dispatched, false); assert.equal(last.error.code, 'companion/lookup-input-limit');
  assert.equal(last.inputBudget.scope, 'adapter-input'); assert.equal(pi.calls.length, 0);
  assert.equal(last.usage.host_adapter_handoff_at_ms, null); assert.equal(f.peer.requests.length, 0);
});

answerTest('lookup nullable actual generic model context remains unknown and does not become a made-up window', async t => {
  const f = await fixture(t, { model: true });
  let calls = 0;
  // Explicit adapter contract fixture; the actual LlmRuntime validates and
  // seals this absent optional context. No physical HTTP claim is made.
  f.engine.llm.adapters.set('no-context', { provider: { id: 'no-context', name: 'No context fixture' }, adapter: {
    async prepareCall(provider, id) { return { model: { provider, id, name: 'Unknown window' }, stream: async function* () {
      calls++; yield { type: 'text-delta', text: 'synthetic result' }; yield { type: 'finish', reason: { kind: 'stop' } };
    } }; },
  } });
  f.state.selected = { provider: 'no-context', model: 'fixture-model' };
  const last = (await f.post({ kind: 'answer', payload: { sources: [source] } })).body.at(-1);
  assert.equal(last.dispatched, null); assert.equal(last.inputBudget.contextWindow, null);
  assert.equal(last.inputBudget.scope, 'adapter-input'); assert.equal(calls, 1);
  assert.equal(f.peer.requests.length, 0);
});

test('lookup input estimate includes whitespace and Unicode using the existing phone heuristic, never raw usage', () => {
  for (const [text, expected] of [['', 0], ['a'.repeat(10), 3], [' '.repeat(10), 3],
    ['馆'.repeat(10), 6], ['🙂', 4], ['é', 2], ['\u0085', 2], ['\ud840\udc00', 1]]) {
    assert.equal(estimateLookupInputTokens(text), expected);
  }
});
