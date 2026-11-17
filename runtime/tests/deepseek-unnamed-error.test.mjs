// Real installed DeepSeek adapter, fetch, SSE parser and loopback HTTP.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
if (!prefix) throw new Error('Set DSH_TEST_PREFIX or DSH_PREFIX to the prepared runtime');
const load = name => import(pathToFileURL(join(
  resolve(prefix), 'node_modules/@deepseek-ai', name, 'lib/index.js',
)));
const [
  { DeepSeekAdapter, resolveAdapterOptions },
  { LlmError, createUserMessage },
] = await Promise.all([load('dsh-llm-deepseek'), load('dsh-llm')]);

async function expectFailure(t, frame, code, message) {
  const received = [];
  const controller = new AbortController();
  const server = createServer((request, response) => {
    received.push({ method: request.method, path: request.url });
    request.resume();
    response.writeHead(200, {
      'content-type': 'text/event-stream',
      'connection': 'close',
    });
    response.end(frame);
  });
  t.after(() => {
    controller.abort();
    server.closeAllConnections();
    if (!server.listening) return;
    return new Promise((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');

  const connection = resolveAdapterOptions({
    baseURL: `http://127.0.0.1:${server.address().port}/v1`,
    models: [{ id: 'sse-error-fixture', inputModalities: ['text'] }],
    thinking: 'disabled',
    maxTokens: 64,
    streamIdleTimeoutMs: 5000,
  });
  const adapter = new DeepSeekAdapter({
    options: () => connection,
    resolveAuth: async () => ({ headers: { 'x-api-key': 'loopback-fixture-only' } }),
    resolveUserId: () => 'sse-error-fixture',
    prepareExtensions: async () => ({ fields: {}, accept: async () => {} }),
  });
  const chunks = [];
  await assert.rejects(async () => {
    for await (const chunk of adapter.stream({
      provider: 'fixture', model: 'sse-error-fixture',
      signal: controller.signal,
      messages: [createUserMessage({
        source: { kind: 'user' }, content: [{ type: 'text', text: 'Fixture request.' }],
      })],
    })) chunks.push(chunk);
  }, error => {
    assert.ok(error instanceof LlmError);
    assert.equal(error.code, code);
    assert.equal(error.message, message);
    assert.equal(error.failure.code, code);
    assert.equal(error.failure.message, message);
    return true;
  });
  assert.deepEqual(received, [{ method: 'POST', path: '/v1/messages' }]);
  assert.deepEqual(chunks, []);
}

test('unnamed generation-wait error keeps its provider message and SERVER code', { timeout: 10000 }, async t => {
  const message = 'Fixture generation wait timed out.';
  await expectFailure(t, `data: ${JSON.stringify({ error: { message } })}\n\n`, 'SERVER', message);
});

test('named typed error retains its existing provider classification', { timeout: 10000 }, async t => {
  const message = 'Fixture rate limit.';
  const event = { type: 'error', error: { type: 'rate_limit_error', message } };
  await expectFailure(t, `event: error\ndata: ${JSON.stringify(event)}\n\n`, 'RATE_LIMIT', message);
});

test('named frame without a JSON type remains malformed', { timeout: 10000 }, async t => {
  const event = { error: { message: 'Fixture missing type.' } };
  await expectFailure(t, `event: error\ndata: ${JSON.stringify(event)}\n\n`,
    'MALFORMED_RESPONSE', 'DeepSeek Messages SSE event type mismatch');
});

test('unnamed untyped error without a message remains malformed', { timeout: 10000 }, async t => {
  await expectFailure(t, 'data: {"error":{}}\n\n',
    'MALFORMED_RESPONSE', 'DeepSeek Messages SSE event type mismatch');
});
