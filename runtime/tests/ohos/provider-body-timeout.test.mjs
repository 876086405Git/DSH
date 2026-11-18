// A body timeout mid-answer must read as a timeout, not a dropped connection, in the
// message the engine's existing classifier sees. Only the real provider code runs here:
// fetch is the one double, and it fails the body the way the OH dispatcher does.
import test from 'node:test';
import assert from 'node:assert/strict';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const api = join(resolve(process.env.DSH_TEST_PREFIX), 'node_modules/@earendil-works/pi-ai/dist/api');
const cases = [
  { file: 'openai-completions.js', api: 'openai-completions',
    chunk: 'data: {"id":"x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"first"}}]}\n\n' },
  { file: 'openai-responses.js', api: 'openai-responses',
    chunk: 'event: response.created\ndata: {"type":"response.created","response":{"id":"x"}}\n\n' },
  { file: 'anthropic-messages.js', api: 'anthropic-messages',
    chunk: 'event: message_start\ndata: {"type":"message_start","message":{"id":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n' },
];
const model = row => ({ id: 'fixture', name: 'fixture', api: row.api, provider: 'fixture', baseUrl: 'http://127.0.0.1:9/v1',
  reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000, maxTokens: 100 });
const context = { messages: [{ role: 'user', content: 'hi', timestamp: 1 }] };

async function outcome(row, failure, status = 200) {
  const fetch = async () => {
    if (status !== 200) return new Response('{"error":{"message":"denied"}}', { status, headers: { 'content-type': 'application/json' } });
    const body = new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode(row.chunk)); },
      pull(controller) { controller.error(failure()); } });
    return new Response(body, { headers: { 'content-type': 'text/event-stream' } });
  };
  const { stream } = await import(pathToFileURL(join(api, row.file)));
  let last;
  for await (const event of stream(model(row), context, { apiKey: 'fixture', maxRetries: 0, fetch })) last = event;
  assert.equal(last.type, 'error');
  return last.error.errorMessage;
}
const terminated = code => () => new TypeError('terminated', { cause: Object.assign(new Error(code), { code }) });

for (const row of cases) {
  test(`${row.file}: a body timeout says so`, async () => {
    assert.match(await outcome(row, terminated('UND_ERR_BODY_TIMEOUT')), /HTTP response body timeout/);
  });
  test(`${row.file}: a dropped connection doesn't`, async () => {
    assert.doesNotMatch(await outcome(row, terminated('UND_ERR_SOCKET')), /timeout/i);
  });
  test(`${row.file}: an HTTP error keeps its own message`, async () => {
    assert.doesNotMatch(await outcome(row, terminated('UND_ERR_BODY_TIMEOUT'), 403), /timeout/i);
  });
}
