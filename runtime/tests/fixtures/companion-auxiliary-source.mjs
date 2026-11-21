// A dependency slice of the integrity-verified locked source. This runs the
// byte-for-byte LlmRuntime/DeepSeekAdapter classes, serializer, SSE parser,
// translator, timeout and value helpers. Only Cordis service/decorator setup,
// the unrelated recall gate and the credential/network seams are replaced.
// It is NOT a full engine boot; companion-auxiliary-integration tests own that.
import { readFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';

function between(source, start, end) {
  const from = source.indexOf(start); assert(from >= 0, start);
  const to = source.indexOf(end, from + start.length); assert(to > from, end);
  return source.slice(from, to);
}
const region = (source, name) => between(source, `//#region lib/types/${name}.js`, '//#endregion');

export async function loadAuxiliarySource(root, fetch) {
  const [llm, deepseek, pins, values, timeouts, sse] = await Promise.all([
    readFile(join(root, 'dsh-llm/index.auxiliary.js'), 'utf8'),
    readFile(join(root, 'dsh-llm-deepseek/index.auxiliary.js'), 'utf8'),
    readFile(new URL('../../patches/pins.json', import.meta.url), 'utf8').then(JSON.parse),
    import(pathToFileURL(join(root, 'dsh-util-values/lib/index.js')).href),
    import(pathToFileURL(join(root, 'dsh-timeout/lib/index.js')).href),
    import(pathToFileURL(join(root, 'eventsource-parser/dist/stream.js')).href),
  ]);
  for (const [name, value] of [['dsh-llm', llm], ['dsh-llm-deepseek', deepseek]]) {
    assert.equal(createHash('sha256').update(value).digest('hex'),
      pins.patches['companion-auxiliary-single-request.diff']['0.2.2-rc.1'][`node_modules/@deepseek-ai/${name}/lib/index.js`].after);
  }
  const globals = { ...values, ...timeouts, ...sse, fetch,
    createRequire: () => createRequire(pathToFileURL(join(root, 'dsh-llm/lib/index.js'))),
    TypertRemoteService: class { constructor(ctx) { this.ctx = ctx; } },
    Remote() {}, __esDecorate() {}, __runInitializers() {},
    ReasoningEffortId: value => value, ProviderRequestId: value => value, ToolCallId: value => value,
    LlmAdapter: class {},
    // This slice accepts no attachments; its transport failures are ordinary
    // Error objects, never the attachment package's error class.
    isAttachmentError: () => false,
    // No AgentLoop/sessionId exists in this entry point. The separate full
    // engine fixture verifies composition with the real existing recall gate.
    dshGoRecall: { async beforeFetch() {}, guardFetch() {} },
  };
  const source = [
    region(llm, 'error'), region(llm, 'content'), region(llm, 'attribution'),
    between(llm, 'var LlmError = class', '/**\n* Accept one supplied credential'),
    between(llm, 'let LlmRuntime = (() =>', '/** Convert one adapter throw'),
    ...['model-info', 'messages-api', 'request-files', 'request-extensions', 'images', 'replay',
      'serialize', 'transport', 'sse', 'translate', 'adapter'].map(name => region(deepseek, name)),
    'export { LlmRuntime, DeepSeekAdapter, LlmError, companionAuxiliaryFetch, attributionHeaders, contentHasImage, projectOffloadedImages, isQuotaExceededError, isContextWindowExceededError, CONTEXT_WINDOW_EXCEEDED_CODE, EMPTY_RESPONSE_CODE, QUOTA_EXCEEDED_CODE };',
  ].join('\n');
  return evaluate(source, globals);
}

async function evaluate(source, globals) {
  // Preserve module syntax (the untouched class has an unused import.meta in
  // provider discovery) without rewriting any runtime method under test.
  const key = `companion-auxiliary-source-${randomUUID()}`;
  globalThis[Symbol.for(key)] = globals;
  try {
    const code = `const { ${Object.keys(globals).join(', ')} } = globalThis[Symbol.for(${JSON.stringify(key)})];\n${source}\n//# sourceURL=companion-auxiliary-source-slice.mjs`;
    return await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
  } finally { delete globalThis[Symbol.for(key)]; }
}

export async function piAiSourceFixture(root, engine) {
  const [source, timeouts] = await Promise.all([
    readFile(join(root, 'dsh-llm-pi-ai/index.patched-baseline.js'), 'utf8'),
    import(pathToFileURL(join(root, 'dsh-timeout/lib/index.js')).href),
  ]);
  // Android/common chain through provider-discovery-headers.diff, independently
  // replayed from the lock package. No pi-ai production code is changed here.
  assert.equal(createHash('sha256').update(source).digest('hex'), '71bef2194ebc72d9d86a0ce3a0fe24345b808208a4752fb077f71cf6603b04aa');
  const globals = { ...engine, ...timeouts, LlmAdapter: class {},
    ReasoningEffortId: value => value, brandString: value => value,
    // The fixture has a nonreasoning model and usage far below its context;
    // catalog/overflow discovery is outside this request-method test.
    isContextOverflow: () => false,
    getSupportedThinkingLevels() { throw new Error('Nonreasoning fixture must not request effort metadata'); },
  };
  const { PiAiAdapter } = await evaluate([
    ...['replay', 'context', 'stream', 'adapter'].map(name => region(source, name)),
    between(source, 'function conversationUpdates(model) {', '//#endregion'),
    'export { PiAiAdapter };',
  ].join('\n'), globals);
  const provider = 'chosen-piai', model = { id: 'chosen-piai-model', name: 'Chosen pi-ai', provider,
    api: 'openai-completions', baseUrl: 'https://synthetic.invalid/v1', input: ['text'], contextWindow: 8192 };
  const profile = { modelErrors: new Map(), configuredMaxTokens: new Map(), streamIdleTimeoutMs: 5000 };
  const profiles = new Map([[provider, profile]]), calls = [];
  const adapter = new PiAiAdapter({ profiles: () => profiles, resolveApiKey: async () => 'synthetic-test-only' });
  adapter.snapshot = { profiles, models: { getModel: () => model,
    streamSimple(actualModel, context, options) {
      calls.push({ model: actualModel, context, options });
      return (async function* () {
        yield { type: 'text_delta', contentIndex: 0, delta: 'PI_AI_SOURCE_REPLY' };
        yield { type: 'done', message: { model: model.id, provider, api: model.api,
          content: [{ type: 'text', text: 'PI_AI_SOURCE_REPLY' }], stopReason: 'stop',
          usage: { input: 4, output: 2, totalTokens: 6, cacheRead: 0, cacheWrite: 0 } } };
      })();
    },
  } };
  return { provider, model, adapter, calls };
}

export function auxiliarySse({ finalUsage = { input_tokens: 11, output_tokens: 7, cache_read_input_tokens: 13 },
  startUsage = { input_tokens: 3, output_tokens: 0, cache_read_input_tokens: 2 }, stopReason = 'end_turn', incomplete = false, empty = false } = {}) {
  const events = [
    { type: 'message_start', message: { usage: startUsage } },
    ...empty ? [] : [{ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '{"items":[]}' } },
    { type: 'content_block_stop', index: 0 }],
    { type: 'message_delta', delta: { stop_reason: stopReason }, usage: finalUsage },
    ...incomplete ? [] : [{ type: 'message_stop' }],
  ];
  return new Response(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(''), {
    status: 200, headers: { 'content-type': 'text/event-stream' },
  });
}

export async function sourceFixture(root, options = {}) {
  const events = [], requests = [];
  const engine = await loadAuxiliarySource(root, (url, init) => {
    requests.push({ url, init, body: JSON.parse(init.body) });
    return options.transport ? options.transport(url, init) : Promise.resolve(auxiliarySse(options.response));
  });
  const connection = {
    baseURL: 'https://synthetic.invalid/anthropic', models: [{ id: 'chosen-model', inputModalities: ['text'], contextWindow: 8192 }],
    defaults: { thinking: 'disabled' }, maxTokens: 1024, defaultContextWindow: 8192,
    streamIdleTimeoutMs: 5000, filesApiTimeoutMs: 5000, retryPolicy: { mode: 'normal', maxRetries: 8 },
  };
  const adapter = new engine.DeepSeekAdapter({ options: () => connection, resolveFiles: () => ({}),
    async resolveAuth() {
      await options.authGate;
      if (options.authError) throw new engine.LlmError('Synthetic missing credential', 'MISSING_CREDENTIAL');
      return { headers: { authorization: 'synthetic-test-only' } };
    },
    // Auxiliary transport must not run optional Session extension plugins.
    prepareExtensions() { throw new Error('Auxiliary request entered extension plugins'); },
    resolveUserId: () => 'synthetic-user',
  });
  const ctx = { waterfall() { throw new Error('Auxiliary request entered llm/stream waterfall'); } };
  const llm = new engine.LlmRuntime(ctx);
  const registration = { provider: { id: 'chosen-provider', name: 'Chosen' }, adapter, retryPolicy: connection.retryPolicy };
  llm.adapters.set('chosen-provider', registration);
  const abort = new AbortController();
  const observer = { guard() { options.guard?.(); }, observe(event) { events.push(event); options.observe?.(event); } };
  const config = { provider: 'chosen-provider', model: 'chosen-model', reasoningEffort: 'off', maxTokens: 512 };
  const prepare = () => llm.prepareCompanionAuxiliaryCall(config, abort.signal, observer);
  const run = async () => {
    const call = await prepare(); const chunks = [];
    for await (const chunk of call.stream({ system: 'Synthetic extraction instruction', input: 'SOURCE_ONLY' })) chunks.push(chunk);
    return { call, chunks };
  };
  return { ...engine, llm, adapter, connection, registration, abort, observer, config, events, requests, prepare, run };
}
