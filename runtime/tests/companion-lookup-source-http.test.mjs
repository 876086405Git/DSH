import test from 'node:test';
import assert from 'node:assert/strict';
import { deferred, lookupPeer, lookupSource } from './fixtures/companion-lookup-source.mjs';

const source = process.env.DSH_LOOKUP_SOURCE;
const sourceTest = (name, run) => test(name, {
  skip: source ? false : 'Set DSH_LOOKUP_SOURCE to the verified, patched dsh-web-deepseek-api/lib/index.js; no engine is installed',
}, run);
const query = '青桥美术馆 本城 2026-11-21 开放公告';
const result = { results: [] };
const json = (value, status = 200) => (_request, response) => {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(value));
};

sourceTest('lookup source HTTP sends exactly one task search using the real configured endpoint and credential reference', async t => {
  const peer = await lookupPeer(t);
  const f = await lookupSource(source, peer.baseURL);
  assert.deepEqual(await f.web.companionLookupCapability('chosen-other-model-provider'),
    { search: true, fetch: true, physicalDispatch: 'fetch-invoked', maxPhysicalRequests: 1 });
  const call = f.prepare({ kind: 'search', query });
  const response = await call.invoke();
  assert.equal(peer.requests.length, 1);
  assert.equal(peer.requests[0].url, '/v1/tools/search');
  assert.deepEqual(peer.requests[0].body, { query, count: 5, need_content: false });
  assert.equal(peer.requests[0].headers.authorization, 'Bearer synthetic-lookup-key');
  assert.equal(peer.requests[0].headers['x-dsh-auth-token'], undefined);
  assert.deepEqual(f.credentialReads, ['LOOKUP_TEST_KEY']);
  assert.deepEqual(f.accountReads, [], 'an unrelated currentInitiator cannot select account authentication');
  assert.deepEqual(f.events.map(event => event.type), ['dispatch', 'http', 'provider-result']);
  assert.equal(f.events[0].boundary, 'fetch-invoked');
  assert(Number.isSafeInteger(f.events[0].atMs));
  assert.equal(f.events[1].status, 200);
  assert.equal(f.events[2].raw.results[0].title, '馆方公告');
  assert.equal(response.sources[0].url, 'https://museum.invalid/notice');
  assert.throws(() => call.invoke(), { code: 'WEB_COMPANION_USED' });
  assert.equal(peer.requests.length, 1);
});

sourceTest('lookup source HTTP fetch preserves raw page title/content and does not call the target page itself', async t => {
  const raw = { title: '当天安排', content: '# 临时闭馆\n测试日期仅用于离线回放。' };
  const peer = await lookupPeer(t, json(raw));
  const f = await lookupSource(source, peer.baseURL);
  const response = await f.prepare({ kind: 'fetch', url: 'https://museum.invalid/notice' }).invoke();
  assert.equal(peer.requests[0].url, '/v1/tools/fetch');
  assert.deepEqual(peer.requests[0].body, { url: 'https://museum.invalid/notice' });
  assert.equal(f.network.length, 1);
  assert.deepEqual(f.events.at(-1), { type: 'provider-result', raw });
  assert.equal(response.body.content, raw.content);
  assert.equal(response.url, 'https://museum.invalid/notice');
  assert.equal(response.statusCode, 200, 'existing provider projection, not an observed museum-origin status');
});

sourceTest('ordinary registered providers keep their existing count and original-question behavior', async t => {
  const peer = await lookupPeer(t, json(result));
  const f = await lookupSource(source, peer.baseURL);
  await f.search.get('deepseek-search-api').search({ query, maxResults: 7 });
  assert.deepEqual(peer.requests[0].body, { query, count: 7, need_content: false, ori_question: 'UNRELATED_PRIVATE_PROMPT' });
  assert.equal(f.events.length, 0, 'ordinary web operations do not acquire task observers');
  assert.equal(f.values.count, 9);
  assert.equal(f.values.sendOriginalQuestion, true);
  assert.equal(f.search.size, 1); assert.equal(f.fetch.size, 1);
});

for (const [name, change] of [
  ['endpoint', f => { f.values.baseURL += '/changed'; }],
  ['credential reference', f => { f.values.apiKeyEnv = 'OTHER_KEY'; }],
  ['literal key', f => { f.values.apiKey = 'changed-synthetic-key'; }],
  ['plugin disposal', f => f.dispose()],
]) {
  sourceTest(`lookup ${name} change during real auth preparation prevents HTTP dispatch`, async t => {
    const peer = await lookupPeer(t), authEntered = deferred(), authGate = deferred();
    const f = await lookupSource(source, peer.baseURL, { authEntered, authGate: authGate.promise });
    const call = f.prepare({ kind: 'search', query });
    const pending = call.invoke();
    await authEntered.promise;
    change(f); authGate.resolve();
    await assert.rejects(pending, { code: 'WEB_COMPANION_STALE' });
    assert.equal(peer.requests.length, 0); assert.equal(f.network.length, 0); assert.equal(f.events.length, 0);
  });
}

sourceTest('owner or received task-revision fence is rechecked after async credentials and before HTTP', async t => {
  const peer = await lookupPeer(t), authEntered = deferred(), authGate = deferred();
  let current = true;
  const f = await lookupSource(source, peer.baseURL, { authEntered, authGate: authGate.promise,
    guard() { if (!current) throw Object.assign(new Error('Observed rev changed'), { code: 'LOOKUP_OLD_REVISION' }); } });
  const pending = f.prepare({ kind: 'search', query }).invoke();
  await authEntered.promise; current = false; authGate.resolve();
  await assert.rejects(pending, { code: 'LOOKUP_OLD_REVISION' });
  assert.equal(f.network.length, 0); assert.equal(peer.requests.length, 0); assert.equal(f.events.length, 0);
});

sourceTest('missing credentials and abort during credential resolution are proven pre-dispatch', async t => {
  const peer = await lookupPeer(t);
  const missing = await lookupSource(source, peer.baseURL, { missingKey: true });
  assert.equal((await missing.web.companionLookupCapability('chosen-other-model-provider')).search, false);
  await assert.rejects(missing.prepare({ kind: 'search', query }).invoke(), { code: 'WEB_PROVIDER_CREDENTIAL_MISSING' });
  assert.equal(missing.network.length, 0); assert.equal(missing.events.length, 0);
  const entered = deferred(), gate = deferred();
  const cancelled = await lookupSource(source, peer.baseURL, { authEntered: entered, authGate: gate.promise });
  const pending = cancelled.prepare({ kind: 'search', query }).invoke();
  await entered.promise; cancelled.abort.abort(); gate.resolve();
  await assert.rejects(pending, { code: 'WEB_ABORTED' });
  assert.equal(cancelled.network.length, 0); assert.equal(peer.requests.length, 0);
});

sourceTest('real selected account route uses only its scoped token and never changes the supplied key into that token', async t => {
  const peer = await lookupPeer(t, json(result));
  const f = await lookupSource(source, peer.baseURL, { accountToken: 'synthetic-account-token' });
  await f.prepare({ kind: 'search', query, llmProvider: 'deepseek-account' }).invoke();
  assert.equal(peer.requests[0].headers['x-dsh-auth-token'], 'synthetic-account-token');
  assert.equal(peer.requests[0].headers.authorization, undefined);
  assert.deepEqual(f.accountReads, [peer.baseURL + '/search']);
  assert.deepEqual(f.credentialReads, []);
});

for (const status of [401, 402, 404, 429, 503]) {
  sourceTest(`lookup HTTP ${status} is observed once with no hidden retry`, async t => {
    const peer = await lookupPeer(t, json({ error: { message: 'Synthetic API error', code: 'test_error' } }, status));
    const f = await lookupSource(source, peer.baseURL);
    await assert.rejects(f.prepare({ kind: 'search', query }).invoke(), { code: 'WEB_PROVIDER_ERROR' });
    assert.equal(peer.requests.length, 1); assert.equal(f.network.length, 1);
    assert.deepEqual(f.events.map(event => event.type), ['dispatch', 'http']);
    assert.equal(f.events[1].status, status);
  });
}

sourceTest('empty search and empty fetched content remain explicit provider results rather than transport failures', async t => {
  const peer = await lookupPeer(t, (request, response) => json(request.url.endsWith('/search') ? result : { title: '', content: '' })(request, response));
  const f = await lookupSource(source, peer.baseURL);
  assert.deepEqual(await f.prepare({ kind: 'search', query }).invoke(), { sources: [], truncated: false });
  assert.deepEqual(f.events.at(-1).raw, { results: [] });
  assert.equal((await f.prepare({ kind: 'fetch', url: 'https://museum.invalid/empty' }).invoke()).body.content, '');
  assert.deepEqual(f.events.at(-1).raw, { title: '', content: '' });
  assert.equal(peer.requests.length, 2, 'one physical call for each distinct prepared handle');
});

sourceTest('malformed JSON differs from a raw JSON payload that fails the existing result decoder', async t => {
  let count = 0;
  const peer = await lookupPeer(t, (_request, response) => {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(++count === 1 ? '{' : JSON.stringify({ results: 'invalid-schema' }));
  });
  const f = await lookupSource(source, peer.baseURL);
  await assert.rejects(f.prepare({ kind: 'search', query }).invoke(), { code: 'WEB_PROVIDER_ERROR' });
  assert.deepEqual(f.events.map(event => event.type), ['dispatch', 'http']);
  f.events.length = 0;
  await assert.rejects(f.prepare({ kind: 'search', query }).invoke(), { code: 'WEB_PROVIDER_ERROR' });
  assert.deepEqual(f.events.map(event => event.type), ['dispatch', 'http', 'provider-result']);
  assert.deepEqual(f.events.at(-1).raw, { results: 'invalid-schema' });
});

sourceTest('abort after actual headers keeps dispatch/status observations without a complete provider result', async t => {
  const headers = deferred();
  const peer = await lookupPeer(t, (_request, response) => {
    response.writeHead(200, { 'content-type': 'application/json' }); response.flushHeaders();
  });
  const f = await lookupSource(source, peer.baseURL, { observe(event) { if (event.type === 'http') headers.resolve(); } });
  const pending = f.prepare({ kind: 'search', query }).invoke();
  await headers.promise; f.abort.abort();
  await assert.rejects(pending, { code: 'WEB_ABORTED' });
  assert.equal(peer.requests.length, 1);
  assert.deepEqual(f.events.map(event => event.type), ['dispatch', 'http']);
});

sourceTest('redirect rejection does not contact the location or invent an unobserved HTTP status', async t => {
  const peer = await lookupPeer(t, (_request, response) => {
    response.writeHead(302, { location: 'https://external.invalid/never' }); response.end();
  });
  const f = await lookupSource(source, peer.baseURL);
  await assert.rejects(f.prepare({ kind: 'search', query }).invoke(), { code: 'WEB_PROVIDER_ERROR' });
  assert.equal(peer.requests.length, 1); assert.equal(f.network.length, 1);
  assert.deepEqual(f.events.map(event => event.type), ['dispatch']);
});

sourceTest('a synchronous fetch throw is still an invocation, and invalid task controls never reach fetch', async t => {
  const peer = await lookupPeer(t);
  const f = await lookupSource(source, peer.baseURL, { fetch() { throw new Error('Synthetic synchronous fetch rejection'); } });
  await assert.rejects(f.prepare({ kind: 'search', query }).invoke(), { code: 'WEB_PROVIDER_ERROR' });
  assert.equal(f.network.length, 1); assert.equal(peer.requests.length, 0);
  assert.deepEqual(f.events.map(event => event.type), ['dispatch']);
  for (const request of [
    { kind: 'search', query: '😀'.repeat(129) }, { kind: 'search', query, apiKey: 'forbidden' },
    { kind: 'fetch', url: 'https://user:password@museum.invalid/' }, { kind: 'fetch', url: 'file:///secret' },
  ]) assert.throws(() => f.prepare(request), { code: 'WEB_COMPANION_INVALID' });
  assert.equal(f.network.length, 1);
  f.dispose();
  assert.equal(f.web.prepareCompanionLookupCall, undefined);
  assert.equal(f.web.companionLookupCapability, undefined);
});
