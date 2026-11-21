// Exercise the installed DeepSeek adapter with synthetic Messages events over loopback HTTP.
// Assert its terminal error, usage and replay contract.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

if (!process.env.DSH_PREFIX) throw new Error('Set DSH_PREFIX to the verified patched test prefix');
const base = join(resolve(process.env.DSH_PREFIX), 'node_modules', '@deepseek-ai');
const load = name => import(pathToFileURL(join(base, name, 'lib/index.js')).href);
const [{ DeepSeekAdapter, DeepSeekFileStore, DeepSeekUploadIndex, resolveAdapterOptions },
  { createUserMessage, LlmError }] = await Promise.all([load('dsh-llm-deepseek'), load('dsh-llm')]);
const model = 'c750-fixture-model';
const prompt = 'Synthetic refusal fixture prompt';

// Same ordinary Messages envelope/block sequence as companion-recall-engine.mjs.
// These are synthetic protocol events, not the reporter's captured stream.
// stop_details is intentionally omitted: this fixture does not test its metadata.
function responseEvents(text, stopReason) {
  return [
    { type: 'message_start', message: { id: 'synthetic-refusal-message', type: 'message', role: 'assistant',
      model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 5, output_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } },
    { type: 'content_block_stop', index: 0 },
    { type: 'message_delta', delta: { stop_reason: stopReason, stop_sequence: null }, usage: { output_tokens: 3 } },
    { type: 'message_stop' },
  ];
}

async function fixture(t, events) {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-refusal-'));
  const controller = new AbortController();
  const received = [];
  const serverErrors = [];
  const server = createServer(async (request, response) => {
    try {
      const body = Buffer.concat(await Array.fromAsync(request)).toString('utf8');
      received.push({ method: request.method, path: request.url, body });
      if (request.method !== 'POST' || request.url !== '/anthropic/v1/messages') {
        response.writeHead(404).end();
        return;
      }
      response.writeHead(200, { 'content-type': 'text/event-stream' });
      response.end(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(''));
    } catch (error) {
      serverErrors.push(error);
      if (!response.headersSent) response.writeHead(500);
      response.end();
    }
  });
  t.after(async () => {
    controller.abort();
    try {
      if (server.listening) {
        const closed = new Promise((done, reject) => server.close(error => error ? reject(error) : done()));
        server.closeAllConnections();
        await closed;
      }
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const options = resolveAdapterOptions({
    baseURL: `http://127.0.0.1:${server.address().port}/anthropic`,
    thinking: 'disabled', maxTokens: 128, defaultContextWindow: 8192, streamIdleTimeoutMs: 5000,
    models: [{ id: model, inputModalities: ['text'], maxTokens: 128, contextWindow: 8192 }],
  });
  const files = new DeepSeekFileStore({ index: new DeepSeekUploadIndex(join(directory, 'files-v3.json')) });
  const adapter = new DeepSeekAdapter({
    options: () => options,
    resolveFiles: () => files,
    resolveAuth: async () => ({ headers: { authorization: 'Bearer synthetic-not-a-credential' } }),
    prepareExtensions: async () => ({ fields: {}, accept: async () => {} }),
    resolveUserId: () => 'synthetic-refusal-user',
  });
  const chunks = [];
  return {
    chunks,
    async consume() {
      for await (const chunk of adapter.stream({
        provider: 'c750-direct-deepseek', model,
        messages: [createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text: prompt }] })],
        signal: controller.signal,
      })) chunks.push(chunk);
    },
    assertRequest() {
      assert.deepEqual(serverErrors, []);
      // This count applies only to the direct adapter call, not the full loop.
      assert.equal(received.length, 1);
      assert.equal(received[0].method, 'POST');
      assert.equal(received[0].path, '/anthropic/v1/messages');
      const body = JSON.parse(received[0].body);
      assert.equal(body.stream, true);
    },
  };
}

function finalChunk(chunks) {
  const usage = chunks.filter(chunk => chunk.type === 'usage');
  assert.deepEqual(usage.map(chunk => chunk.usage.reported), [
    { inputTokens: 5 }, { inputTokens: 5, outputTokens: 3 }, { inputTokens: 5, outputTokens: 3 },
  ]);
  assert.deepEqual(usage.at(-1).usage, {
    inputTokens: 5, outputTokens: 3, totalTokens: 8, reported: { inputTokens: 5, outputTokens: 3 },
  });
  const finishes = chunks.filter(chunk => chunk.type === 'finish');
  assert.equal(finishes.length, 1);
  assert.equal(chunks.at(-2), usage.at(-1));
  assert.equal(chunks.at(-1), finishes[0]);
  return finishes[0];
}

test('ordinary end_turn retains text, final usage and successful replay', { timeout: 10000 }, async t => {
  const f = await fixture(t, responseEvents('Synthetic complete reply', 'end_turn'));
  await f.consume();
  f.assertRequest();
  assert.deepEqual(f.chunks.filter(chunk => chunk.type === 'block-end'),
    [{ type: 'block-end', index: 0, block: { type: 'text', text: 'Synthetic complete reply' } }]);
  const finish = finalChunk(f.chunks);
  assert.deepEqual(finish.reason, { kind: 'stop' });
  assert.equal(typeof finish.replayState, 'object');
  assert.notEqual(finish.replayState, null);
});

for (const [label, text] of [['empty text', ''], ['already streamed partial text', 'Synthetic partial reply']]) {
  test(`refusal after ${label} retains final usage and emits error without replay`, { timeout: 10000 }, async t => {
    const f = await fixture(t, responseEvents(text, 'refusal'));
    await f.consume();
    f.assertRequest();
    // Existing chunks remain observable here; this does not assert UI withdrawal.
    assert.equal(f.chunks.filter(chunk => chunk.type === 'text-delta').map(chunk => chunk.text).join(''), text);
    assert.deepEqual(f.chunks.filter(chunk => chunk.type === 'block-end'),
      [{ type: 'block-end', index: 0, block: { type: 'text', text } }]);
    const finish = finalChunk(f.chunks);
    assert.equal(finish.reason.kind, 'error');
    assert.equal(finish.reason.failure.code, 'REFUSAL');
    assert.equal(typeof finish.reason.failure.message, 'string');
    assert.ok(finish.reason.failure.message.length > 0);
    assert.equal(Object.hasOwn(finish, 'replayState'), false);
  });
}

test('an unknown stop reason still rejects as MALFORMED_RESPONSE', { timeout: 10000 }, async t => {
  const f = await fixture(t, responseEvents('Synthetic unknown-reason reply', 'future-fixture-stop'));
  await assert.rejects(() => f.consume(), error => error instanceof LlmError && error.code === 'MALFORMED_RESPONSE');
  f.assertRequest();
  assert.equal(f.chunks.some(chunk => chunk.type === 'finish'), false);
});

test('missing terminal output differs from explicit zero, and truncated streams preserve observations', async t => {
  for (const output of [undefined, 0]) {
    const events = responseEvents('Synthetic reply', 'end_turn');
    events.at(-2).usage = output === undefined ? {} : { output_tokens: output };
    const f = await fixture(t, events);
    await f.consume();
    assert.equal(f.chunks.at(-2).usage.outputTokens, 0);
    assert.deepEqual(f.chunks.at(-2).usage.reported,
      output === undefined ? { inputTokens: 5 } : { inputTokens: 5, outputTokens: 0 });
  }
  const f = await fixture(t, responseEvents('Synthetic truncated reply', 'end_turn').slice(0, -1));
  await assert.rejects(() => f.consume(), error => error instanceof LlmError && error.code === 'STREAM_CLOSED');
  assert.deepEqual(f.chunks.at(-1).usage.reported, { inputTokens: 5, outputTokens: 3 });
  assert.equal(f.chunks.some(chunk => chunk.type === 'finish'), false);
});
