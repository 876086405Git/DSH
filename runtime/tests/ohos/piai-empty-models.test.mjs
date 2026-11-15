// Actual Cordis, LlmRuntime, pi-ai registration and local HTTP; no global mocks.
// The Map observations are source-bound state counts, not heap-byte measurements.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';

if (!process.env.DSH_PREFIX) throw Error('DSH_PREFIX must select the locked actual package view');
const prefix = resolve(process.env.DSH_PREFIX);
const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await load('cordis');
const { updateVolatile } = await load('cosmokit');
const { LlmRuntime } = await load('dsh-llm');
const pi = await load('dsh-llm-pi-ai');
const custom = (extra = {}) => ({
  api: 'openai-completions', baseURL: 'http://127.0.0.1:1/v1',
  models: [{ id: 'fixture-model', name: 'Fixture Model' }], ...extra,
});

async function fixture(t, providers, credentials) {
  const ctx = new Context();
  t.after(() => ctx.fiber.dispose());
  if (credentials) ctx.provide('credentials', credentials);
  await ctx.plugin(LlmRuntime).await();
  const mounted = ctx.plugin(pi, { providers });
  await mounted.await();
  const adapter = route => {
    const registration = ctx.llm.adapters.get(route);
    assert(registration, 'the real LlmRuntime registered the configured route');
    assert(registration.adapter instanceof pi.PiAiAdapter);
    return registration.adapter;
  };
  // The loader's exact public volatile-ref commit and notification, without
  // mounting its filesystem loader or claiming a whole Host/UI hot update.
  const update = next => {
    updateVolatile(mounted.ctx.fiber.effectiveConfig.providers, pi.Config({ providers: next }).providers);
    mounted.ctx.emit('loader/volatile-update', [['providers']]);
  };
  return { ctx, adapter, update };
}

function observe(t, label, models) {
  const providers = models.getProviders().map(value => value.id).sort();
  const generations = [...models.refreshGenerations].sort(([a], [b]) => a.localeCompare(b));
  const unexpected = generations.map(([id]) => id).filter(id => !providers.includes(id));
  t.diagnostic(JSON.stringify({ label, providers, generations, unexpected,
    controllers: models.refreshControllers.size, publications: models.publicationChains.size }));
  assert.deepEqual(unexpected, [], 'a snapshot must not retain refresh state for providers it never owns');
  assert.equal(models.refreshControllers.size, 0);
  assert.equal(models.publicationChains.size, 0);
  return { providers, generations };
}

test('real builtin route registration retains only the configured provider state', async t => {
  const f = await fixture(t, { deepseek: { displayName: 'Configured DeepSeek' } });
  assert.deepEqual(f.ctx.llm.listProviders(), [{ id: 'deepseek', name: 'Configured DeepSeek' }]);
  const adapter = f.adapter('deepseek');
  // registerAdapter -> prepareRoutes -> providerInfo already created it.
  assert(adapter.snapshot, 'snapshot creation is reached by actual registration, without calling current in the test');
  const models = await f.ctx.llm.listModels('deepseek');
  assert(models.length > 0);
  assert(models.every(model => model.provider === 'deepseek'));
  assert.equal(adapter.snapshot.models.getProviders().length, 1);
  observe(t, 'builtin registration', adapter.snapshot.models);
});

test('real private route registration retains no unrelated builtin state', async t => {
  const route = 'private-empty-models-fixture';
  const f = await fixture(t, { [route]: custom() });
  const adapter = f.adapter(route);
  assert(adapter.snapshot, 'real registration creates the snapshot');
  assert.deepEqual(await f.ctx.llm.listModels(route), [{ provider: route, id: 'fixture-model',
    name: 'Fixture Model', inputModalities: ['text'] }]);
  observe(t, 'private route registration', adapter.snapshot.models);
});

test('empty plugin retains the full directory and registers no adapter; explicit empty adapter remains empty', async t => {
  const f = await fixture(t, {});
  assert.deepEqual(f.ctx.llm.listProviders(), []);
  const directory = f.ctx.llm.listConfigurableProviders();
  assert(directory.length > 1);
  assert(directory.some(entry => entry.provider === 'deepseek' && entry.declared === false));
  assert(directory.some(entry => entry.provider === 'openai' && entry.declared === false));
  t.diagnostic(JSON.stringify({ emptyPluginDirectoryEntries: directory.length, registeredAdapters: 0,
    emptyAdapterBelow: 'explicit exported-class boundary; not an empty Host reachability claim' }));
  const profiles = new Map();
  const adapter = new pi.PiAiAdapter({ profiles: () => profiles, auth: {},
    resolveApiKey() { throw Error('empty snapshot construction must not resolve credentials'); } });
  assert.deepEqual(adapter.providerInfo('not-configured'), { id: 'not-configured', name: 'not-configured' });
  const snapshot = adapter.snapshot;
  assert.equal(adapter.current(), snapshot);
  assert.deepEqual(snapshot.models.getProviders(), []);
  assert.deepEqual(snapshot.models.getModels(), []);
  observe(t, 'explicit empty exported adapter', snapshot.models);
});

test('unchanged profiles reuse a snapshot; volatile route replacement keeps the old snapshot intact', async t => {
  const a = 'old-empty-models-fixture', b = 'new-empty-models-fixture';
  const f = await fixture(t, { [a]: custom() });
  const adapter = f.adapter(a), before = adapter.snapshot;
  const oldProvider = before.models.getProvider(a);
  const oldGenerations = [...before.models.refreshGenerations];
  adapter.providerInfo(a);
  await f.ctx.llm.listModels(a);
  assert.equal(adapter.snapshot, before);
  f.update({ [b]: custom({ displayName: 'Next route' }) });
  assert.equal(f.adapter(b), adapter);
  assert.deepEqual(f.ctx.llm.listProviders(), [{ id: b, name: 'Next route' }]);
  assert.notEqual(adapter.snapshot, before);
  assert.equal(before.models.getProvider(a), oldProvider);
  assert.equal(before.models.getProvider(b), undefined);
  assert.deepEqual([...before.models.refreshGenerations], oldGenerations);
  assert.deepEqual(before.profiles.size, 1);
  assert(before.profiles.has(a));
  assert.equal(adapter.snapshot.models.getProvider(a), undefined);
  assert(f.ctx.llm.listConfigurableProviders().some(entry => entry.provider === b && entry.declared));
  observe(t, 'after actual volatile ref commit', adapter.snapshot.models);
});

test('public constructor options retain identity without eager credential or model-store calls', () => {
  const denied = () => { throw Error('factory construction must not perform storage or authentication IO'); };
  const auth = {
    credentials: { read: denied, list: denied, modify: denied, delete: denied },
    modelsStore: { read: denied, write: denied },
    authContext: { env: denied, fileExists: denied },
    identity: { name: 'source-bound-fixture', version: '1' },
  };
  const profiles = new Map();
  const adapter = new pi.PiAiAdapter({ profiles: () => profiles, auth, resolveApiKey: denied });
  adapter.providerInfo('not-configured');
  for (const key of ['credentials', 'modelsStore', 'authContext', 'identity']) {
    assert.equal(adapter.snapshot.models[key], auth[key]);
  }
});

test('actual registered credential resolution preserves missing, present and thrown results', async t => {
  const route = 'credential-empty-models-fixture';
  let response, failure;
  const names = [];
  const credentials = { async resolve(name) {
    names.push(name); if (failure) throw failure; return response;
  } };
  const f = await fixture(t, { [route]: custom({ apiKeyEnv: 'SYNTHETIC_EMPTY_MODELS_KEY' }) }, credentials);
  assert.deepEqual(names, [], 'registration/factory does not read a credential');
  assert.deepEqual(await f.ctx.llm.listModels(route), []);
  response = { value: 'synthetic-only-key' };
  assert.equal((await f.ctx.llm.listModels(route)).length, 1);
  failure = Error('explicit credential service failure');
  await assert.rejects(f.ctx.llm.listModels(route), error => error === failure);
  assert.deepEqual(names, Array(3).fill('SYNTHETIC_EMPTY_MODELS_KEY'));
});

test('prepared old call and new current call keep their exact model, credentials and HTTP target', async t => {
  const requests = [];
  const server = createServer(async (request, response) => {
    const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString('utf8'));
    requests.push({ path: request.url, authorization: request.headers.authorization, body });
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    for (const choice of [{ delta: { role: 'assistant', content: 'ok' }, finish_reason: null },
      { delta: {}, finish_reason: 'stop' }]) {
      response.write(`data: ${JSON.stringify({ id: 'fixture', object: 'chat.completion.chunk', created: 1,
        model: 'fixture-model', choices: [{ index: 0, ...choice }] })}\n\n`);
    }
    response.end('data: [DONE]\n\n');
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => { server.closeAllConnections(); return new Promise(resolve => server.close(resolve)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const route = 'prepared-empty-models-fixture';
  const reads = [];
  const credentials = { async resolve(name) { reads.push(name); return { value: `synthetic-${name}` }; } };
  const profile = version => custom({ baseURL: `${base}/${version}`, apiKeyEnv: `KEY_${version.toUpperCase()}`,
    models: [{ id: 'fixture-model', name: version, maxTokens: version === 'old' ? 32 : 64 }] });
  const f = await fixture(t, { [route]: profile('old') }, credentials);
  const adapter = f.adapter(route), oldSnapshot = adapter.snapshot;
  const prepared = await adapter.prepareCall(route, 'fixture-model');
  f.update({ [route]: profile('new') });
  assert.equal(prepared.model.name, 'old');
  assert.equal(prepared.model.defaultMaxTokens, 32);
  assert.equal((await adapter.resolveModel(route, 'fixture-model')).name, 'new');
  assert.notEqual(adapter.snapshot, oldSnapshot);
  const options = { provider: route, model: 'fixture-model', tools: [],
    messages: [{ role: 'user', content: [{ type: 'text', text: 'Synthetic local hello.' }] }] };
  const oldChunks = await Array.fromAsync(prepared.stream(options));
  const newChunks = await Array.fromAsync(adapter.stream(options));
  assert.equal(oldChunks.at(-1).reason.kind, 'stop');
  assert.equal(newChunks.at(-1).reason.kind, 'stop');
  assert.deepEqual(reads, ['KEY_OLD', 'KEY_NEW']);
  assert.deepEqual(requests.map(value => [value.path, value.authorization]), [
    ['/old/chat/completions', 'Bearer synthetic-KEY_OLD'],
    ['/new/chat/completions', 'Bearer synthetic-KEY_NEW'],
  ]);
  assert.equal(requests[0].body.max_tokens ?? requests[0].body.max_completion_tokens, 32);
  assert.equal(requests[1].body.max_tokens ?? requests[1].body.max_completion_tokens, 64);
  assert.equal(oldSnapshot.models.getModel(route, 'fixture-model').name, 'old');
  assert.equal(adapter.snapshot.models.getModel(route, 'fixture-model').name, 'new');
});
