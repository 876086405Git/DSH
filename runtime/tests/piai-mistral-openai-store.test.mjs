import test from 'node:test';
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
const options = { skip: !prefix && 'prepared DSH prefix required' };
let modulePromise;
function api() {
  if (!modulePromise) {
    modulePromise = import(pathToFileURL(resolve(prefix, 'node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js')));
  }
  return modulePromise;
}

// Capture the public stream's real OpenAI SDK request. The fixed error response
// avoids a paid API call and makes no claim about provider-side acceptance.
async function body(baseUrl, compat) {
  const { stream } = await api();
  const captures = [];
  const result = await stream({
    id: 'deepseek-v4-1-flash-1017', name: 'Request capture only',
    api: 'openai-completions', provider: 'custom', baseUrl,
    input: ['text'], reasoning: true, contextWindow: 8192, maxTokens: 1024,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    ...(compat ? { compat } : {}),
  }, {
    messages: [
      { role: 'system', content: 'Keep the existing instruction role.', timestamp: 0 },
      { role: 'user', content: 'Capture only.', timestamp: 0 },
    ],
  }, {
    apiKey: 'synthetic-not-a-real-key', maxRetries: 0, maxTokens: 16,
    reasoningEffort: 'medium',
    fetch: async (input, init) => {
      const method = init?.method ?? (input instanceof Request ? input.method : 'GET');
      const text = init?.body ?? (input instanceof Request ? await input.text() : undefined);
      captures.push({
        url: input instanceof Request ? input.url : String(input),
        method, body: JSON.parse(text),
      });
      return new Response(JSON.stringify({ error: { message: 'controlled transport capture', type: 'invalid_request_error' } }), {
        status: 400, headers: { 'content-type': 'application/json' },
      });
    },
  }).result();
  assert.equal(result.stopReason, 'error');
  assert.equal(captures.length, 1);
  assert.equal(captures[0].method, 'POST');
  assert.equal(new URL(captures[0].url).origin, new URL(baseUrl).origin);
  assert.equal(new URL(captures[0].url).pathname, `${new URL(baseUrl).pathname.replace(/\/$/, '')}/chat/completions`);
  return captures[0].body;
}

const golden = {
  model: 'deepseek-v4-1-flash-1017',
  messages: [
    { role: 'developer', content: 'Keep the existing instruction role.' },
    { role: 'user', content: 'Capture only.' },
  ],
  stream: true, stream_options: { include_usage: true },
  max_completion_tokens: 16, reasoning_effort: 'medium',
};
const mistral = 'https://api.mistral.ai/v1';
for (const [name, url, compat, hasStore] of [
  ['reported native endpoint', mistral, undefined, false],
  ['native endpoint with trailing slash', `${mistral}/`, undefined, false],
  ['native endpoint with canonical host and port', 'https://API.MISTRAL.AI:443/v1', undefined, false],
  ['explicit supportsStore true', mistral, { supportsStore: true }, true],
  ['explicit supportsStore false', mistral, { supportsStore: false }, false],
  ['standard OpenAI', 'https://api.openai.com/v1', undefined, true],
  ['existing Google compatibility', 'https://generativelanguage.googleapis.com/v1beta/openai', undefined, false],
  ['Mistral preview endpoint remains unchanged', 'https://api.mistral.ai/openai/v1', undefined, true],
  ['custom proxy remains unchanged', 'https://proxy.example.invalid/v1', undefined, true],
]) {
  test(`Mistral store compatibility: ${name}`, options, async () => {
    assert.deepEqual(await body(url, compat), hasStore ? { ...golden, store: false } : golden);
  });
}
