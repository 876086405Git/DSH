import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createUsage } from '../bridge/dsh-go-bridge/lib/usage.js';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
const options = { skip: !prefix && 'prepared DSH prefix required' };

test('Bedrock metadata cache counts reach reported usage and the bridge', options, async t => {
  const bedrockPath = resolve(prefix,
    'node_modules/@earendil-works/pi-ai/dist/api/bedrock-converse-stream.js');
  const { BedrockRuntimeClient } = createRequire(pathToFileURL(bedrockPath))('@aws-sdk/client-bedrock-runtime');
  const { Config, apply } = await import(pathToFileURL(resolve(prefix,
    'node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js')));
  const { BlockAssembler } = await import(pathToFileURL(resolve(prefix,
    'node_modules/@deepseek-ai/dsh-llm/lib/index.js')));
  let raw;
  // Replace only the SDK transport result. The installed public adapter calls
  // the real Bedrock streamSimple/buildBaseOptions/stream and usage mapper.
  // These are modeled SDK events, not a paid AWS request or an HTTP decoder test.
  const send = t.mock.method(BedrockRuntimeClient.prototype, 'send', async command => {
    assert.equal(command.constructor.name, 'ConverseStreamCommand');
    return {
      $metadata: { httpStatusCode: 200 },
      stream: (async function* () {
        yield { messageStart: { role: 'assistant' } };
        yield { contentBlockDelta: { contentBlockIndex: 0, delta: { text: 'Hello' } } };
        yield { contentBlockStop: { contentBlockIndex: 0 } };
        yield { messageStop: { stopReason: 'end_turn' } };
        yield { metadata: { usage: raw, metrics: { latencyMs: 1 } } };
      })(),
    };
  });
  let adapter;
  apply({
    fiber: { entry: { options: { id: 'llm-pi-ai' } } }, inject() {}, on() {},
    get: name => name === 'credentials' ? {
      resolve: async () => ({ value: 'synthetic-not-a-real-key' }),
      readRecord: async () => undefined,
    } : undefined,
    waterfall: (_name, _request, headers) => headers,
    llm: {
      registerAdapter(_routes, value) { adapter = value; return { replace() {} }; },
      registerConfigurableProviders: () => ({ replace() {} }), registerModelDiscovery() {},
    },
    logger: { warn() {}, error() {} },
  }, Config({ providers: { 'amazon-bedrock': {
    apiKeyEnv: 'SYNTHETIC_TEST_API_KEY', baseURL: 'https://bedrock.example.invalid',
  } } }));
  assert(adapter);
  const models = await adapter.listModels('amazon-bedrock');
  const model = models.find(entry => entry.id.includes('anthropic.claude'));
  assert(model, 'the pinned Bedrock catalog must contain a Claude model');
  for (const [name, usage, expected] of [
    ['cache read', { inputTokens: 23, outputTokens: 7, totalTokens: 4126,
      cacheReadInputTokens: 4096, cacheWriteInputTokens: 0 },
    { inputTokens: 23, outputTokens: 7, cacheReadTokens: 4096, cacheWriteTokens: 0 }],
    ['cache write', { inputTokens: 23, outputTokens: 7, totalTokens: 4126,
      cacheReadInputTokens: 0, cacheWriteInputTokens: 4096 },
    { inputTokens: 23, outputTokens: 7, cacheReadTokens: 0, cacheWriteTokens: 4096 }],
    ['cache fields absent', { inputTokens: 23, outputTokens: 7, totalTokens: 30 },
    { inputTokens: 23, outputTokens: 7 }],
  ]) {
    raw = usage;
    const calls = send.mock.callCount();
    const assembler = new BlockAssembler();
    for await (const chunk of adapter.stream({
      provider: 'amazon-bedrock', model: model.id, maxTokens: 16, tools: [],
      messages: [{ role: 'user', content: [{ type: 'text', text: 'Synthetic hello.' }] }],
    })) assembler.push(chunk);
    assert.equal(send.mock.callCount(), calls + 1, name);
    assert.equal(assembler.finish.kind, 'stop', name);
    assert.deepEqual(assembler.blocks(), [{ type: 'text', text: 'Hello' }], name);
    assert.deepEqual(assembler.usage.reported, expected, name);
    assert.equal(assembler.usage.totalTokens, usage.totalTokens, name);
    const ledger = createUsage(() => Date.parse('2026-11-21T12:00:00Z'));
    ledger.pull(true);
    ledger.observe({ type: 'assistant/message', data: { usage: assembler.usage } });
    const day = ledger.pull(true).days['2026-11-21'];
    const read = expected.cacheReadTokens ?? 0, write = expected.cacheWriteTokens ?? 0;
    assert.deepEqual(day.values, [23 + read + write, 7, 23 + read + write, 7,
      23, read, write, Object.hasOwn(expected, 'cacheReadTokens') ? 1 : 0, 0, 0], name);
    assert.deepEqual(day.counts, [1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0], name);
  }
});
