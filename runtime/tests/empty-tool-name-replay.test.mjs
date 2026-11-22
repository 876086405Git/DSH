import test from 'node:test';
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
const options = { skip: !prefix && 'prepared DSH prefix required', timeout: 10000 };
const load = name => import(pathToFileURL(resolve(prefix,
  `node_modules/@deepseek-ai/${name}/lib/index.js`)));
const model = 'empty-name-replay-fixture';
const baseURL = 'https://strict-replay.example.invalid/v1';

async function adapterFor(protocol) {
  if (protocol === 'deepseek-messages') {
    const { DeepSeekAdapter, resolveAdapterOptions } = await load('dsh-llm-deepseek');
    const connection = resolveAdapterOptions({
      baseURL, thinking: 'disabled', maxTokens: 64, streamIdleTimeoutMs: 5000,
      models: [{ id: model, inputModalities: ['text'], contextWindow: 8192, maxTokens: 64 }],
    });
    return new DeepSeekAdapter({
      options: () => connection,
      resolveAuth: async () => ({ headers: { 'x-api-key': 'synthetic-not-a-real-key' } }),
      resolveUserId: () => 'empty-name-replay-fixture',
      prepareExtensions: async () => ({ fields: {}, accept: async () => {} }),
    });
  }
  const { Config, apply } = await load('dsh-llm-pi-ai');
  let adapter;
  apply({
    fiber: { entry: { options: { id: 'llm-pi-ai' } } }, inject() {}, on() {},
    get: name => name === 'credentials' ? {
      resolve: async () => ({ value: 'synthetic-not-a-real-key' }), readRecord: async () => undefined,
    } : undefined,
    waterfall: (_name, _request, headers) => headers,
    llm: {
      registerAdapter(_routes, value) { adapter = value; return { replace() {} }; },
      registerConfigurableProviders: () => ({ replace() {} }), registerModelDiscovery() {},
    },
    logger: { warn() {}, error() {} },
  }, Config({ providers: { 'custom-replay': {
    apiKeyEnv: 'SYNTHETIC_TEST_API_KEY', api: 'openai-completions', baseURL,
    models: [{ id: model, input: ['text'], contextWindow: 8192, maxTokens: 64,
      reasoningEfforts: false, compat: { requiresToolResultName: true } }],
  } } }));
  assert(adapter);
  return adapter;
}

function successResponse(protocol) {
  if (protocol === 'openai-completions') {
    const event = { id: 'synthetic-replay-response', object: 'chat.completion.chunk', created: 0, model,
      choices: [{ index: 0, delta: { role: 'assistant', content: 'Continued.' }, finish_reason: null }] };
    const stop = { ...event, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
      usage: { prompt_tokens: 5, completion_tokens: 1, total_tokens: 6 } };
    return `data: ${JSON.stringify(event)}\n\ndata: ${JSON.stringify(stop)}\n\ndata: [DONE]\n\n`;
  }
  return [
    { type: 'message_start', message: { id: 'synthetic-replay-response', type: 'message', role: 'assistant',
      model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 5, output_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Continued.' } },
    { type: 'content_block_stop', index: 0 },
    { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 1 } },
    { type: 'message_stop' },
  ].map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join('');
}

for (const protocol of ['openai-completions', 'deepseek-messages']) {
  test(`${protocol} replays an empty tool name without changing durable history`, options, async t => {
    const [{ createUserMessage, createAssistantMessage, createToolResultMessage }, { deepFreeze }] =
      await Promise.all([load('dsh-llm'), load('dsh-util-values')]);
    const calls = [
      { type: 'tool-call', id: 'call_empty', name: '', arguments: '{}' },
      { type: 'tool-call', id: 'call_named', name: 'known_tool', arguments: '{"value":1}' },
    ];
    const history = [
      createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text: 'Previous request.' }] }),
      createAssistantMessage({ source: {
        provider: 'historical-provider', model: 'historical-model', replayState: {
          response: { kind: 'pi-ai', version: 2, api: 'openai-completions',
            provider: 'historical-provider', model: 'historical-model', stopReason: 'toolUse' },
          blocks: [{ type: 'tool-call' }, { type: 'tool-call' }],
        },
      }, content: calls }),
      createToolResultMessage({ callId: 'call_empty', isError: true,
        content: [{ type: 'text', text: 'Synthetic unknown tool error.' }] }),
      createToolResultMessage({ callId: 'call_named', isError: false,
        content: [{ type: 'text', text: 'Previous named tool result.' }] }),
      createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text: 'Continue.' }] }),
    ];
    deepFreeze(history);
    const before = structuredClone(history);
    const captures = [];
    // Model only the stated strict-name receiver: the installed public adapter
    // and SDK still construct the real request and parse the synthetic response.
    // This is not an authenticated request to any provider or an Agent replay.
    t.mock.method(globalThis, 'fetch', async (input, init) => {
      const request = new Request(input, init);
      assert.equal(request.method, 'POST');
      assert.equal(request.url, `${baseURL}/${protocol === 'openai-completions' ? 'chat/completions' : 'messages'}`);
      const body = await request.json();
      const wireCalls = body.messages.filter(message => message.role === 'assistant').flatMap(message =>
        protocol === 'openai-completions' ? (message.tool_calls ?? []).map(call => ({
          id: call.id, name: call.function.name, arguments: JSON.parse(call.function.arguments),
        })) : message.content.filter(block => block.type === 'tool_use').map(call => ({
          id: call.id, name: call.name, arguments: call.input,
        })));
      captures.push({ body, calls: wireCalls });
      if (wireCalls.some(call => call.name === '')) return new Response(JSON.stringify({
        type: 'error', error: { type: 'invalid_request_error', message: 'Synthetic receiver rejects empty tool names.' },
      }), { status: 400, headers: { 'content-type': 'application/json' } });
      return new Response(successResponse(protocol), { headers: { 'content-type': 'text/event-stream' } });
    });
    const adapter = await adapterFor(protocol);
    const chunks = await Array.fromAsync(adapter.stream({
      provider: 'custom-replay', model, messages: history, maxTokens: 64,
      tools: [{ name: 'known_tool', description: 'Synthetic existing tool.',
        parameters: { type: 'object', properties: { value: { type: 'integer' } } } }],
    }));
    assert.equal(chunks.at(-1).reason.kind, 'stop');
    assert.equal(chunks.filter(chunk => chunk.type === 'text-delta').map(chunk => chunk.text).join(''), 'Continued.');
    assert.equal(captures.length, 1);
    assert.deepEqual(captures[0].calls, [
      { id: 'call_empty', name: 'unknown', arguments: {} },
      { id: 'call_named', name: 'known_tool', arguments: { value: 1 } },
    ]);
    if (protocol === 'openai-completions') {
      const results = captures[0].body.messages.filter(message => message.role === 'tool');
      assert.deepEqual(results.map(message => [message.tool_call_id, message.name]),
        [['call_empty', 'unknown'], ['call_named', 'known_tool']]);
      assert.equal(results[0].content, 'Synthetic unknown tool error.');
    } else {
      const results = captures[0].body.messages.flatMap(message =>
        message.content.filter(block => block.type === 'tool_result'));
      assert.deepEqual(results.map(block => block.tool_use_id), ['call_empty', 'call_named']);
      assert.equal(results[0].is_error, true);
      assert.deepEqual(results[0].content, [{ type: 'text', text: 'Synthetic unknown tool error.' }]);
    }
    assert.deepEqual(history, before);
  });
}
