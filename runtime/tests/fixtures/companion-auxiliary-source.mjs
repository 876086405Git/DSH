// A dependency slice of the integrity-verified locked source. This runs the
// byte-for-byte LlmRuntime/adapter classes, serializer, SSE parser,
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
      pins.patches[name === 'dsh-llm' ? 'companion-screen-piai-image.diff' : 'companion-screen-image.diff']
        ['0.2.2-rc.1'][`node_modules/@deepseek-ai/${name}/lib/index.js`].after);
  }
  const globals = { ...values, ...timeouts, ...sse, fetch, createHash,
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
    dshGoRecall: { async beforeFetch() {}, guardFetch() {}, chatUsage() {}, chatObserve() {} },
  };
  const source = [
    region(llm, 'error'), region(llm, 'content'), region(llm, 'attribution'),
    between(llm, 'const DEFAULT_MAX_RETRIES =', 'const backoffSchema ='),
    between(llm, 'const NORMAL_POLICY_KEYS =', '//#endregion'),
    between(llm, 'var LlmError = class', '/**\n* Accept one supplied credential'),
    between(llm, 'let LlmRuntime = (() =>', '/** Convert one adapter throw'),
    ...['model-info', 'messages-api', 'request-files', 'request-extensions', 'images', 'replay',
      'serialize', 'transport', 'sse', 'translate', 'adapter'].map(name => region(deepseek, name)),
    'export { LlmRuntime, DeepSeekAdapter, LlmError, companionAuxiliaryFetch, attributionHeaders, contentHasImage, projectOffloadedImages, resolveRetryPolicy, isQuotaExceededError, isContextWindowExceededError, CONTEXT_WINDOW_EXCEEDED_CODE, EMPTY_RESPONSE_CODE, QUOTA_EXCEEDED_CODE };',
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

export async function piAiSourceFixture(root, engine, options = {}) {
  const upstream = join(root, 'pi-ai');
  const [source, pins, manifest, completions, anthropic] = await Promise.all([
    readFile(join(root, 'dsh-llm-pi-ai/index.auxiliary.js'), 'utf8'),
    readFile(new URL('../../patches/pins.json', import.meta.url), 'utf8').then(JSON.parse),
    readFile(join(upstream, 'package.json'), 'utf8').then(JSON.parse),
    readFile(join(upstream, 'dist/api/openai-completions.js'), 'utf8'),
    readFile(join(upstream, 'dist/api/anthropic-messages.js'), 'utf8'),
  ]);
  assert.equal(createHash('sha256').update(source).digest('hex'),
    pins.patches['companion-screen-piai-image.diff']['0.2.2-rc.1']['node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js'].after);
  assert.equal(manifest.name, '@earendil-works/pi-ai'); assert.equal(manifest.version, '1.5.0');
  for (const [name, value, patch] of [
    ['openai-completions', completions, 'piai-dashscope-system-role.diff'],
    ['anthropic-messages', anthropic, 'piai-anthropic-opus55-thinking.diff'],
  ]) assert.equal(createHash('sha256').update(value).digest('hex'),
    pins.patches[patch]['0.2.2-rc.1'][`node_modules/@earendil-works/pi-ai/dist/api/${name}.js`].after);
  // The owner supplies this complete pinned package and its normal dependencies.
  // Import the real Models/catalog/protocol chain, never a synthetic streamSimple.
  const [timeouts, catalog, completionApi, responseApi, anthropicApi, overflow] = await Promise.all([
    import(pathToFileURL(join(root, 'dsh-timeout/lib/index.js')).href),
    import(pathToFileURL(join(upstream, 'dist/providers/all.js')).href),
    import(pathToFileURL(join(upstream, 'dist/api/openai-completions.lazy.js')).href),
    import(pathToFileURL(join(upstream, 'dist/api/openai-responses.lazy.js')).href),
    import(pathToFileURL(join(upstream, 'dist/api/anthropic-messages.lazy.js')).href),
    import(pathToFileURL(join(upstream, 'dist/utils/overflow.js')).href),
  ]);
  const calls = [], requests = [], events = [];
  const fetch = (input, init) => {
    const record = raw => {
      assert.equal(typeof raw, 'string', 'the real SDK must supply its serialized request');
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
      requests.push({ url, init, body: JSON.parse(raw), raw });
      return options.transport ? options.transport(input, init) : Promise.resolve(piAiSse(options.api ?? 'openai-completions'));
    };
    if (typeof init?.body === 'string') return record(init.body);
    assert(input instanceof Request && init?.body === undefined);
    return input.clone().text().then(record);
  };
  const globals = { ...engine, ...timeouts, ...catalog, ...completionApi, ...responseApi, ...anthropicApi, ...overflow,
    fetch, LlmAdapter: class {}, ReasoningEffortId: value => value, brandString: value => value };
  const { PiAiAdapter, resolveProfiles } = await evaluate([
    ...['replay', 'catalog', 'models', 'provider'].map(name => region(source, name)),
    between(source, '//#region lib/types/config.js', 'const thinkingBudgets ='),
    between(source, 'function rejectRemovedFields(', '//#endregion'),
    ...['context', 'stream', 'adapter'].map(name => region(source, name)),
    'export { PiAiAdapter, resolveProfiles };',
  ].join('\n'), globals);
  const provider = options.provider ?? 'chosen-piai', modelId = options.modelId ?? 'chosen-piai-model';
  let profile = options.profile ?? { api: options.api ?? 'openai-completions', baseURL: 'https://synthetic.invalid/v1',
    models: [{ id: modelId, input: options.image ? ['text', 'image'] : ['text'], contextWindow: 8192, maxTokens: 1024 }],
    streamIdleTimeoutMs: 5000, retryPolicy: { mode: 'normal', maxRetries: 8 } };
  let profiles;
  const configure = changes => {
    profile = { ...profile, ...changes };
    profiles = resolveProfiles({ [provider]: profile });
    const actual = profiles.get(provider).piProvider;
    const streamSimple = actual.streamSimple;
    actual.streamSimple = (model, context, requestOptions) => {
      calls.push({ model, context, options: requestOptions });
      // Only the final network seam is supplied for ordinary text. Preserve the
      // production private fetch wrapper for images; this spy is no send proof.
      return streamSimple(model, context, { ...requestOptions, fetch: requestOptions.fetch ?? fetch });
    };
  };
  configure({});
  let authEntered;
  const enteredAuth = new Promise(resolve => { authEntered = resolve; });
  const adapter = new PiAiAdapter({ profiles: () => profiles,
    async resolveApiKey() {
      authEntered(); await options.authGate;
      if (options.authError) throw new engine.LlmError('Synthetic missing credential', 'MISSING_CREDENTIAL');
      return 'synthetic-test-only';
    },
    resolveAttachments() { throw new Error('Transient image entered durable attachments'); },
  });
  const llm = engine.llm, abort = new AbortController();
  const registration = { provider: { id: provider, name: provider }, adapter, retryPolicy: profiles.get(provider).retryPolicy };
  llm.adapters.set(provider, registration);
  const config = { provider, model: modelId, maxTokens: 111 };
  const observer = { guard() { options.guard?.(); }, observe(event) { events.push(event); },
    ...options.checkRequest ? { checkRequest: options.checkRequest } : {} };
  const prepare = () => llm.prepareCompanionAuxiliaryCall(config, abort.signal, observer);
  return { provider, adapter, llm, registration, config, abort, observer, calls, requests, events, prepare, configure, enteredAuth,
    get model() { return adapter.current().models.getModel(provider, modelId); },
    catalogModels: catalog.getBuiltinModels,
  };
}

export function piAiSse(api, { incomplete = false,
  completionUsage = { prompt_tokens: 4, completion_tokens: 2, total_tokens: 6, prompt_tokens_details: { cached_tokens: 0 } } } = {}) {
  const text = 'PI_AI_SOURCE_REPLY', model = 'chosen-piai-model';
  let events;
  if (api === 'openai-completions') {
    const frame = { id: 'synthetic-completion', object: 'chat.completion.chunk', created: 0, model };
    events = [{ ...frame, choices: [{ index: 0, delta: { role: 'assistant', content: text }, finish_reason: null }] },
      ...incomplete ? [] : [{ ...frame, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
        ...completionUsage === null ? {} : { usage: completionUsage } }]];
  } else if (api === 'openai-responses') {
    const item = { type: 'message', id: 'synthetic-message', role: 'assistant', status: 'completed',
      content: [{ type: 'output_text', text, annotations: [] }] };
    events = [{ type: 'response.created', response: { id: 'synthetic-response', model, status: 'in_progress' } },
      { type: 'response.output_item.added', output_index: 0, item: { ...item, content: [] } },
      { type: 'response.output_text.delta', output_index: 0, content_index: 0, delta: text },
      { type: 'response.output_item.done', output_index: 0, item },
      ...incomplete ? [] : [{ type: 'response.completed', response: { id: 'synthetic-response', model, status: 'completed',
        output: [item], usage: { input_tokens: 4, output_tokens: 2, total_tokens: 6, input_tokens_details: { cached_tokens: 0 } } } }]];
  } else {
    assert.equal(api, 'anthropic-messages');
    events = [{ type: 'message_start', message: { id: 'synthetic-message', type: 'message', role: 'assistant', model,
      content: [], stop_reason: null, stop_sequence: null,
      usage: { input_tokens: 4, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } },
      { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
      { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } },
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 2 } },
      ...incomplete ? [] : [{ type: 'message_stop' }]];
  }
  return new Response(events.map(event => `${event.type ? `event: ${event.type}\n` : ''}data: ${JSON.stringify(event)}\n\n`).join('') +
    (api === 'openai-completions' && !incomplete ? 'data: [DONE]\n\n' : ''),
    { status: 200, headers: { 'content-type': 'text/event-stream' } });
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
    baseURL: 'https://synthetic.invalid/anthropic', models: [{ id: 'chosen-model', inputModalities: options.image ? ['text', 'image'] : ['text'], contextWindow: 8192 }],
    defaults: { thinking: 'disabled' }, maxTokens: 1024, defaultContextWindow: 8192,
    streamIdleTimeoutMs: 5000, filesApiTimeoutMs: 5000, retryPolicy: { mode: 'normal', maxRetries: 8 },
    maxInlineRequestImageBytes: 2 * 1024 * 1024, maxRequestFilesBytes: 2 * 1024 * 1024,
    maxImagesPerRequest: 1, inlineImageOffloadByteQuantum: 1024, imageOffloadByteQuantum: 1024, imageOffloadCountQuantum: 1,
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
