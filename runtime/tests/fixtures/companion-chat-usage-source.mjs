// Runs byte-for-byte locked LlmRuntime, AgentRegistry AsyncLocal methods and
// the direct adapter serializer/fetch/SSE/translator plus the production bridge.
// Cordis installation and a non-automatic recall marker filesystem boundary
// are explicit seams. This is not a complete AgentLoop/Session engine boot.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { AsyncLocalStorage } from 'node:async_hooks';
import { isPromise } from 'node:util/types';
import { join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { createCompanionPromptContext } from '../../bridge/dsh-go-bridge/lib/companion/prompt-context.js';
import { auxiliarySse, piAiSourceFixture } from './companion-auxiliary-source.mjs';

export { auxiliarySse, piAiSourceFixture };
const between = (source, start, end) => {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert(from >= 0 && to > from, start);
  return source.slice(from, to);
};
const region = (source, name) => between(source, `//#region lib/types/${name}.js`, '//#endregion');

export async function loadChatSource(root, fetch, lookupWindow = false) {
  const sourceFile = lookupWindow ? 'index.lookup-window.js' : 'index.chat-usage.js';
  const [llm, deepseek, agent, pins, values, timeouts, sse] = await Promise.all([
    readFile(join(root, 'dsh-llm', sourceFile), 'utf8'),
    readFile(join(root, 'dsh-llm-deepseek', sourceFile), 'utf8'),
    readFile(join(root, 'dsh-agent/index.js'), 'utf8'),
    readFile(new URL('../../patches/pins.json', import.meta.url), 'utf8').then(JSON.parse),
    import(pathToFileURL(join(root, 'dsh-util-values/lib/index.js')).href),
    import(pathToFileURL(join(root, 'dsh-timeout/lib/index.js')).href),
    import(pathToFileURL(join(root, 'eventsource-parser/dist/stream.js')).href),
  ]);
  for (const [name, value] of [['dsh-llm', llm], ['dsh-llm-deepseek', deepseek]]) {
    const patch = lookupWindow ? (name === 'dsh-llm' && pins.patches['companion-compare-output-window.diff']
      ? 'companion-compare-output-window.diff' : 'companion-lookup-answer-window.diff') : 'companion-chat-usage-receipts.diff';
    assert.equal(createHash('sha256').update(value).digest('hex'),
      pins.patches[patch]['0.2.2-rc.1'][`node_modules/@deepseek-ai/${name}/lib/index.js`].after);
  }
  // The original lock package provenance is recorded in A03-upstream-provenance.
  assert.equal(createHash('sha256').update(agent).digest('hex'), '8673b5cfadfbb6e6ce0bcb341d0ea2877adc2986eab1c2b6c8baf32726534c92');
  const globals = { ...values, ...timeouts, ...sse, fetch, randomUUID, AsyncLocalStorage, isPromise,
    recallHash: createHash, recallJoin: join, recallResolve: resolve, recallHomedir: () => '/synthetic-unused-home',
    recallLstat() { throw Object.assign(new Error('Synthetic session has no automatic recall marker'), { code: 'ENOENT' }); },
    createRequire: () => createRequire(pathToFileURL(join(root, 'dsh-llm/lib/index.js'))),
    TypertRemoteService: class { constructor(ctx) { this.ctx = ctx; } },
    Service: class { static init = Symbol('fixture service init'); constructor(ctx) { this.ctx = ctx; } },
    Remote() {}, __esDecorate() {}, __runInitializers() {},
    brandString: value => value, MessageId: value => value, ReasoningEffortId: value => value,
    ProviderRequestId: value => value, ToolCallId: value => value,
    LlmAdapter: class {}, isAttachmentError: () => false,
  };
  const source = [
    between(llm, '//#region dsh-go companion recall admission', '//#endregion'),
    ...['message', 'error', 'content', 'attribution', 'call-config', 'adapter-failure'].map(name => region(llm, name)),
    between(llm, 'var LlmError = class', '/**\n* Accept one supplied credential'),
    between(llm, 'let LlmRuntime = (() =>', '/** Copy a directory entry'),
    ...['image-tokens', 'request-pricing', 'model-info', 'messages-api', 'request-files', 'request-extensions', 'images', 'replay',
      'serialize', 'transport', 'sse', 'translate', 'adapter'].map(name => region(deepseek, name)),
    region(agent, 'archive-admission'), region(agent, 'index'),
    'export { LlmRuntime, DeepSeekAdapter, LlmError, AgentRegistry, dshGoRecall, markAgentLoopRequest, createUserMessage, attributionHeaders, contentHasImage, projectOffloadedImages, isQuotaExceededError, isContextWindowExceededError, CONTEXT_WINDOW_EXCEEDED_CODE, EMPTY_RESPONSE_CODE, QUOTA_EXCEEDED_CODE };',
  ].join('\n');
  const slot = `companion-chat-source-${randomUUID()}`;
  globalThis[Symbol.for(slot)] = globals;
  try {
    const body = `const { ${Object.keys(globals).join(', ')} } = globalThis[Symbol.for(${JSON.stringify(slot)})];\n${source}\n//# sourceURL=companion-chat-source-slice.mjs`;
    return await import(`data:text/javascript;base64,${Buffer.from(body).toString('base64')}`);
  } finally { delete globalThis[Symbol.for(slot)]; }
}

export async function chatSourceFixture(root, options = {}) {
  const requests = [], auxiliaryEvents = [];
  const engine = await loadChatSource(root, (url, init) => {
    requests.push({ url, init, body: JSON.parse(init.body) });
    return options.transport ? options.transport(url, init, requests.length) : Promise.resolve(auxiliarySse(options.response));
  }, options.lookupWindow);
  const connection = {
    baseURL: 'https://synthetic.invalid/anthropic', models: [{ id: 'chosen-model', inputModalities: ['text'], contextWindow: 8192 }],
    defaults: { thinking: 'disabled' }, maxTokens: 1024, defaultContextWindow: 8192,
    streamIdleTimeoutMs: 5000, filesApiTimeoutMs: 5000, retryPolicy: { mode: 'normal', maxRetries: 8 },
    maxRequestFilesBytes: 1024 * 1024, maxInlineRequestImageBytes: 1024 * 1024, maxImagesPerRequest: 10,
    imageOffloadByteQuantum: 65536, inlineImageOffloadByteQuantum: 65536, imageOffloadCountQuantum: 1,
  };
  const adapter = new engine.DeepSeekAdapter({ options: () => connection,
    resolveFiles: () => options.files ?? {}, resolveAttachments: () => options.attachments,
    async resolveAuth() {
      options.onAuth?.(); await options.authGate;
      if (options.authError) throw new engine.LlmError('Synthetic missing credential', 'MISSING_CREDENTIAL');
      return { headers: { authorization: 'synthetic-test-only' } };
    },
    prepareExtensions: async () => ({ fields: options.extensionFields ?? {}, accept: async () => { options.onAccept?.(); } }),
    resolveUserId: () => 'synthetic-user',
  });
  const services = new Map();
  const ctx = { get: name => services.get(name), inject() {}, on() {}, effect() {},
    waterfall(_self, event, _options, next) { assert.equal(event, 'llm/stream'); return next(); } };
  const agents = new engine.AgentRegistry(ctx);
  const llm = new engine.LlmRuntime(ctx);
  services.set('agents', agents); services.set('llm', llm);
  llm.adapters.set('chosen-provider', { provider: { id: 'chosen-provider', name: 'Chosen' }, adapter, retryPolicy: connection.retryPolicy });
  let clock = 1795280000000;
  const context = createCompanionPromptContext({ now: () => clock, instanceId: 'chat-instance', usageLimits: options.usageLimits,
    isCurrent: agent => agents.get(agent.id) === agent });
  services.set('dshGoCompanionContext', context);
  const actor = (id = 'chat-session') => {
    const agent = { id, ctx, session: { id, header: { isSeeded: false }, inheritedEventCount: 0, seq: 0,
      eventAt() { throw new Error('Synthetic empty Session must not read an event'); } } };
    agents.store.set(id, { agent });
    return agent;
  };
  const agent = actor();
  const config = { provider: 'chosen-provider', model: 'chosen-model', reasoningEffort: 'off', maxTokens: 512 };
  const human = (requestId = 'phone-request') => engine.createUserMessage({ source: { kind: 'user', rpcId: requestId },
    content: [{ type: 'text', text: 'SYNTHETIC_PHONE_HUMAN' }] });
  const prepare = (target = agent, requestId = 'phone-request', phone = {}) => context.prepare(target, {
    v: 1, instanceId: 'chat-instance', sessionId: target.id, requestId, events: [], phoneMemory: {
      archiveId: 'phone-archive', controlRevision: 0, historyAfterSeq: 0,
      block: '{"type":"companion_memory","version":2,"scope":"real","items":[]}', ...phone,
    },
  });
  const claim = (target = agent, requestId = 'phone-request', turn = 1) => context.claim(target, human(requestId), turn);
  const snapshot = (requestId = 'phone-request', target = agent) => context.usageSnapshot({
    instanceId: 'chat-instance', sessionId: target.id, requestId,
  });
  const run = async ({ target = agent, requestId = 'phone-request', marked = true, initiator = target,
    controls = config, signal = new AbortController().signal, messages = [human(requestId)] } = {}) => {
    const request = Object.freeze({ ...controls, messages: Object.freeze(messages), sessionId: target.id, signal });
    if (marked) engine.markAgentLoopRequest(request);
    const before = JSON.stringify(request), chunks = [];
    const invoke = async () => {
      for await (const chunk of llm.stream(request)) chunks.push(chunk);
    };
    if (initiator === null) await agents.withoutInitiator(invoke);
    else await agents.withInitiator(initiator, invoke);
    assert.equal(JSON.stringify(request), before, 'the accounting observer must not mutate a request/history');
    return chunks;
  };
  return { ...engine, llm, adapter, connection, services, ctx, agents, context, agent, actor, config,
    requests, auxiliaryEvents, human, prepare, claim, snapshot, run, setTime: value => { clock = value; },
    async dispose() { context.clear(); await agents.disposeInitiators(); } };
}
