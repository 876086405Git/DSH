// Owner-run full pinned engine. The real adapter's fetch is intercepted only at
// the synthetic .invalid provider. This test never calls a live model service.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request } from 'node:http';
import { once } from 'node:events';
import { createFixture, requestSystemText, textResponse } from './fixtures/companion-recall-engine.mjs';
import { createCompanionRoutes } from '../bridge/dsh-go-bridge/lib/companion/routes.js';

const integration = (name, run) => test(name, {
  skip: !process.env.DSH_PREFIX && 'Set DSH_PREFIX to the actual runtime including companion-auxiliary-single-request.diff',
  concurrency: false, timeout: 15000,
}, run);
const path = '/dsh-go/v1/companion/auxiliary';

async function fixture(t, options) {
  const f = await createFixture(options);
  const { agent } = await f.createAgent('AUXILIARY_SESSION');
  f.ctx.provide('connection', { admit: () => ({ peer: { principal: { kind: 'owner' } } }) });
  const routes = createCompanionRoutes({ ctx: f.ctx, store: f.store, promptContext: f.promptContext,
    send(res, status, body) { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); } });
  const server = createServer((req, res) => { void routes.handle(req, res, new URL(req.url, 'http://local').pathname); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { routes.dispose(); server.closeAllConnections(); await new Promise(r => server.close(r)); await f.dispose(); });
  const http = (method, body) => new Promise((resolve, reject) => {
    const req = request({ host: '127.0.0.1', port: server.address().port, path: `${path}?sessionId=${agent.id}`,
      method, headers: { 'content-type': 'application/json' } }, res => {
      const chunks = []; res.on('data', chunk => chunks.push(chunk)); res.on('error', reject);
      res.on('end', () => { const value = Buffer.concat(chunks).toString(); resolve({ status: res.statusCode,
        body: res.headers['content-type'].startsWith('application/x-ndjson') ? value.trim().split('\n').map(JSON.parse) : JSON.parse(value) }); });
    });
    req.on('error', reject); req.end(body === undefined ? undefined : JSON.stringify(body));
  });
  const info = await http('GET');
  assert.equal(info.body.supported, true, 'the actual runtime/adapter must advertise the new physical hook');
  const body = { v: 1, instanceId: info.body.instanceId, requestId: 'AUXILIARY_REQUEST', sessionId: agent.id,
    provider: f.route.provider, model: f.route.model, kind: 'extract', system: 'Synthetic extraction instruction', input: 'AUXILIARY_SOURCE_ONLY', maxTokens: 128 };
  return { ...f, agent, http, body };
}

integration('full engine HTTP auxiliary uses selected model, emits physical/raw receipts, and leaves Session history unchanged', async t => {
  const f = await fixture(t);
  await f.send(f.agent, 'PREVIOUS_CONVERSATION_NOT_AUXILIARY_INPUT');
  const before = f.agent.session.snapshotEvents(f.engine.session.SessionLogOffset(0));
  const r = await f.http('POST', f.body);
  assert.equal(r.status, 200); assert.equal(f.requests.length, 2);
  const sent = f.requests.at(-1);
  assert.equal(sent.body.model, f.route.model); assert.equal(sent.sessionId, null);
  assert.deepEqual(sent.body.messages, [{ role: 'user', content: [{ type: 'text', text: 'AUXILIARY_SOURCE_ONLY' }] }]);
  assert.equal(sent.body.tools, undefined); assert.deepEqual(sent.body.thinking, { type: 'disabled' });
  assert.deepEqual(f.agent.session.snapshotEvents(f.engine.session.SessionLogOffset(0)), before);
  assert.equal(r.body.find(event => event.type === 'dispatch').boundary, 'fetch-invoked');
  const finish = r.body.at(-1); assert.equal(finish.dispatched, true); assert.equal(finish.terminal, 'complete');
  assert.deepEqual(finish.usage.start_usage, { input_tokens: 5, output_tokens: 0 });
  assert.deepEqual(finish.usage.final_usage, { output_tokens: 3 });
  assert.equal(finish.usage.input_uncached, null); assert.equal(finish.usage.output_tokens, 3);
});

integration('full engine selection change during credential await prevents the actual auxiliary POST', async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  t.after(() => release.resolve());
  const f = await fixture(t, { deepseekDependencies: { async resolveAuth() {
    entered.resolve(); await release.promise;
    return { headers: { authorization: 'Bearer synthetic-only' } };
  } } });
  const pending = f.http('POST', f.body); await entered.promise;
  f.agent.model.select({ provider: f.route.provider, model: 'OTHER_SELECTED_MODEL', reasoningEffort: 'off' });
  release.resolve(); const r = await pending;
  assert.equal(r.body.at(-1).dispatched, false); assert.equal(f.requests.length, 0);
});

integration('full engine followup sends the exact one-opportunity material without conversation history or tools', async t => {
  const line = JSON.stringify({ action: 'line', text: '周四的面试，今天想聊聊吗？' });
  const f = await fixture(t, { transport: () => textResponse(line) });
  await f.send(f.agent, 'HISTORY_NOT_IN_FOLLOWUP');
  const before = f.agent.session.snapshotEvents(f.engine.session.SessionLogOffset(0));
  const system = 'Synthetic fixed followup instruction. At most one question.';
  const input = JSON.stringify({ persona: { name: '小棠', style: '简短温和' },
    card: { text: '你打算周四去面试。' },
    invitation: { message_id: 'invitation', source_rev: 1, said_at_utc: '2026-11-18T02:00:00Z',
      offset_minutes: 480, quote: '周四打算去面试。周五你可以问问我。' },
    support: [], now_utc: '2026-11-20T02:00:00Z', offset_minutes: 480 });
  const result = await f.http('POST', { ...f.body, kind: 'followup', system, input });
  assert.equal(result.status, 200);
  assert.equal(f.requests.length, 2, 'one ordinary chat and one auxiliary request');
  const sent = f.requests.at(-1);
  assert.equal(sent.body.model, f.route.model);
  assert.equal(sent.body.max_tokens, 128);
  assert.equal(sent.sessionId, null);
  assert.equal(sent.body.tools, undefined);
  assert.equal(requestSystemText(sent), system);
  assert.deepEqual(sent.body.messages, [{ role: 'user', content: [{ type: 'text', text: input }] }]);
  assert(!sent.rawBody.includes('HISTORY_NOT_IN_FOLLOWUP'));
  assert.equal(result.body.filter(event => event.type === 'text').map(event => event.text).join(''), line);
  assert.equal(result.body.at(-1).terminal, 'complete');
  assert.equal(result.body.at(-1).dispatched, true);
  assert.equal(result.body.at(-1).usage.output_tokens, 3);
  assert.deepEqual(f.agent.session.snapshotEvents(f.engine.session.SessionLogOffset(0)), before);
});

integration('full engine HTTP 401 is one sent request, preserves unknown usage, and same request ID is not replayed', async t => {
  const f = await fixture(t, { transport: () => new Response(JSON.stringify({ error: { type: 'authentication_error', message: 'synthetic test failure' } }), { status: 401 }),
    deepseekOptions: { retryPolicy: { mode: 'normal', maxRetries: 8, backoff: { initialDelayMs: 1, maxDelayMs: 1, jitterRatio: 0 } } } });
  const r = await f.http('POST', f.body), finish = r.body.at(-1);
  assert.equal(f.requests.length, 1); assert.equal(finish.dispatched, true); assert.equal(finish.httpStatus, 401);
  assert.equal(finish.terminal, 'http_error'); assert.equal(finish.usage.input_uncached, null);
  assert.equal(finish.usage.final_usage, null); assert.equal((await f.http('POST', f.body)).status, 409);
  assert.equal(f.requests.length, 1);
});

integration('full engine permits a selected pi-ai route and returns unknown physical dispatch without raw-usage fabrication', async t => {
  const calls = [];
  const provider = 'AUXILIARY_PIAI', modelId = 'AUXILIARY_PIAI_MODEL';
  const f = await fixture(t, { async configureLlm({ ctx, engine }) {
    const { PiAiAdapter } = await engine.load('dsh-llm-pi-ai');
    const model = { id: modelId, name: 'Synthetic pi-ai', provider, api: 'openai-completions',
      baseUrl: 'https://synthetic-piai.invalid/v1', input: ['text'], contextWindow: 8192 };
    const profiles = new Map([[provider, { modelErrors: new Map(), configuredMaxTokens: new Map(), streamIdleTimeoutMs: 5000 }]]);
    const adapter = new PiAiAdapter({ profiles: () => profiles, resolveApiKey: async () => 'synthetic-test-only' });
    adapter.snapshot = { profiles, models: { getModel: () => model,
      streamSimple(actualModel, context, options) {
        calls.push({ model: actualModel, context, options });
        return (async function* () {
          yield { type: 'text_delta', contentIndex: 0, delta: '{"items":[]}' };
          yield { type: 'done', message: { model: modelId, provider, api: model.api,
            content: [{ type: 'text', text: '{"items":[]}' }], stopReason: 'stop',
            usage: { input: 4, output: 2, totalTokens: 6, cacheRead: 0, cacheWrite: 0 } } };
        })();
      },
    } };
    ctx.llm.registerAdapter([provider], adapter);
  } });
  f.agent.model.select({ provider, model: modelId });
  const info = await f.http('GET');
  assert.equal(info.body.supported, true); assert.equal(info.body.capability.maxPhysicalRequests, null);
  const before = f.agent.session.snapshotEvents(f.engine.session.SessionLogOffset(0));
  const r = await f.http('POST', { ...f.body, provider, model: modelId });
  assert.equal(calls.length, 1); assert.equal(calls[0].options.maxRetries, 0); assert.equal(f.requests.length, 0);
  assert.equal(calls[0].context.tools, undefined); assert.equal(calls[0].options.sessionId, undefined);
  assert.deepEqual(f.agent.session.snapshotEvents(f.engine.session.SessionLogOffset(0)), before);
  const finish = r.body.at(-1);
  assert.equal(finish.dispatched, null); assert.equal(finish.terminal, 'complete');
  assert.equal(finish.usage.start_usage, null); assert.equal(finish.usage.final_usage, null);
  assert.equal(finish.usage.runtime_normalized_usage[0].outputTokens, 2);
});
