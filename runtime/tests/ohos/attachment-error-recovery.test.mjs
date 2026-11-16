// Real storage/agent/session paths, plus explicit constructor-seam fault controls.
// No production methods or global fetch are replaced.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const prefix = resolve(process.env.DSH_PREFIX);
const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await load('cordis');
const { PiAiAdapter } = await load('dsh-llm-pi-ai');
const { AttachmentError, AttachmentStore } = await load('dsh-attachment');
const { LlmRuntime, LlmError } = await load('dsh-llm');
const dispatcherModule = process.env.DSH_ATTACHMENT_DISPATCHER_MODULE
  ? pathToFileURL(resolve(process.env.DSH_ATTACHMENT_DISPATCHER_MODULE))
  : new URL('../../ohos/net/dispatcher.mjs', import.meta.url);
const { createHttpDispatcher } = await import(dispatcherModule);
const api = await import(pathToFileURL(join(prefix, 'node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js')));
const chunk = (delta, finish_reason = null) => 'data: ' + JSON.stringify({
  id: 'fixture', object: 'chat.completion.chunk', choices: [{ index: 0, delta, finish_reason }],
}) + '\n\n';
const image = { attachmentId: 'sha256:' + 'a'.repeat(64), mediaType: 'image/png', bytes: 1, width: 1, height: 1, name: 'fixture.png' };
const user = (id, withImage) => ({ id, role: 'user', source: { kind: 'user' },
  content: [{ type: 'text', text: id }, ...(withImage ? [{ type: 'image', attachment: image }] : [])] });

function profileFor(baseUrl, fetchImpl, idleMs = 5000) {
  const model = { id: 'vision', name: 'fixture', api: 'openai-completions', provider: 'fixture', baseUrl,
    reasoning: false, input: ['text', 'image'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 10000, maxTokens: 100 };
  return { maxRequestImageBytes: 1048576, maxRequestImages: 10, imageOffloadCountQuantum: 1,
    requestImagePixelBudget: 4194304, requestImageMaxBytes: 1048576, provider: 'fixture', displayName: 'fixture',
    streamIdleTimeoutMs: idleMs, modelErrors: new Map(), configuredMaxTokens: new Map(),
    piProvider: { id: 'fixture', name: 'fixture', auth: { apiKey: { resolve: async ({ credential }) => ({ auth: { apiKey: credential.key } }) } },
      getModels: () => [model, { ...model, id: 'text', input: ['text'] }],
      streamSimple: (m, c, o) => api.streamSimple(m, c, { ...o, fetch: fetchImpl }),
    },
  };
}
function adapterFor(profile, resolveAttachments) {
  const profiles = new Map([['fixture', profile]]);
  return new PiAiAdapter({ profiles: () => profiles, resolveApiKey: async () => 'local-fixture-only', resolveAttachments, auth: {} });
}
const cases = ['missing', 'corrupt', ...(process.platform === 'openharmony' ? ['codec-unavailable'] : []),
  'third-party-code', 'forged-attachment-code', 'code-getter'];
for (const damage of cases) test(`attachment ${damage}: durable diagnostic and existing same-session recovery`, { timeout: 10000 }, async t => {
  const home = await mkdtemp(join(tmpdir(), 'attachment-diagnostic-'));
  const requests = [];
  const server = createServer(async (req, res) => {
    const buffers = []; for await (const b of req) buffers.push(b);
    requests.push(JSON.parse(Buffer.concat(buffers)));
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end(chunk({ content: '文字请求完成' }) + chunk({}, 'stop') + 'data: [DONE]\n\n');
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const dispatcher = createHttpDispatcher({ proxyEnv: {}, bodyTimeout: 1000, headersTimeout: 1000 });
  const ctx = new Context();
  t.after(async () => {
    await ctx.fiber.dispose(); await dispatcher.destroy(); server.closeAllConnections();
    await new Promise(done => server.close(done)); await rm(home, { recursive: true, force: true });
  });
  for (const [pkg, symbol] of [['dsh-llm', 'LlmRuntime'], ['dsh-session-projection', 'SessionProjectionRegistry'],
    ['dsh-agent', 'AgentRegistry'], ['dsh-session', 'SessionStore'], ['dsh-system-prompt', 'SystemPrompt'],
    ['dsh-tools', 'ToolRuntime'], ['dsh-tool-executor-native', null], ['dsh-agent-loop', 'AgentLoop']]) {
    const mod = await load(pkg); await ctx.plugin(symbol ? mod[symbol] : mod, {});
  }
  const { LocalAttachmentStore } = await load('dsh-attachment-local');
  await ctx.plugin(LocalAttachmentStore, { dshHome: home });
  // A valid reference whose file disappeared, or a controlled damaged stored object.
  const ref = { ...image };
  if (damage === 'corrupt' || damage === 'codec-unavailable') {
    const bytes = damage === 'corrupt' ? Buffer.from('damaged fixture object')
      : Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aC1sAAAAASUVORK5CYII=', 'base64');
    if (damage === 'codec-unavailable') {
      ref.attachmentId = 'sha256:' + createHash('sha256').update(bytes).digest('hex'); ref.bytes = bytes.length;
    }
    const digest = ref.attachmentId.slice(7), directory = join(home, 'attachments/v1/objects', digest.slice(0, 2));
    await mkdir(directory, { recursive: true }); await writeFile(join(directory, digest), bytes);
  }
  let getterReads = 0;
  const profile = profileFor(`http://127.0.0.1:${server.address().port}/v1`, (input, init) => fetch(input, { ...init, dispatcher }));
  const adapter = adapterFor(profile, () => {
    if (damage === 'third-party-code') throw Object.assign(new Error('fixture SDK failure'), { code: 'SDK_UNTRUSTED_CODE' });
    if (damage === 'forged-attachment-code') throw Object.assign(new Error('fixture SDK failure'), { code: 'ATTACHMENT_NOT_FOUND' });
    if (damage === 'code-getter') throw Object.defineProperty(new Error('fixture SDK failure'), 'code', {
      get() { getterReads++; throw Error('code accessor must not run'); },
    });
    return ctx.attachments;
  });
  ctx.llm.registerAdapter(['fixture'], adapter);
  const log = []; ctx.on('session/event', (_session, event) => log.push(event));
  const agent = await ctx.agentLoop.create('attachment-first-turn', { provider: 'fixture', model: 'vision' });
  const first = user('first', true); first.content[1].attachment = ref;
  agent.followup(first); await agent.whenIdle();
  const failed = log.findLast(e => e.type === 'turn/end');
  t.diagnostic(JSON.stringify({ damage, requests: requests.length, failed }));
  assert.equal(requests.length, 0); assert.equal(failed.data.reason.kind, 'error'); assert.equal(getterReads, 0);
  const known = { missing: 'ATTACHMENT_NOT_FOUND', corrupt: 'ATTACHMENT_CORRUPT', 'codec-unavailable': 'OHOS_IMAGE_CODEC_UNAVAILABLE' };
  assert.equal(failed.data.reason.error.code, process.platform === 'openharmony' ? known[damage] ?? 'UNKNOWN' : 'UNKNOWN');
  assert(!failed.data.reason.error.message.includes(home), 'public diagnostic must not expose fixture storage path');
  // This recovery already worked before the fix; it is a non-regression control.
  agent.model.select({ provider: 'fixture', model: 'text' });
  agent.followup(user('next', false)); await agent.whenIdle();
  const recovered = log.findLast(e => e.type === 'turn/end');
  t.diagnostic(JSON.stringify({ damage, recovered, requestCount: requests.length }));
  assert.equal(recovered.data.reason.kind, 'completed'); assert.equal(requests.length, 1);
  for (const id of ['first', 'next']) assert.equal(log.filter(e => e.type === 'user/message' && e.data.id === id).length, 1);
});

for (const mode of ['caller-cancel', 'idle-timeout', 'existing-llm-error']) test(`attachment boundary preserves ${mode} precedence`, { timeout: 10000 }, async t => {
  const ctx = new Context(), controller = new AbortController();
  await ctx.plugin(LlmRuntime); t.after(async () => { controller.abort(); await ctx.fiber.dispose(); });
  let providerCalls = 0;
  const entered = Promise.withResolvers();
  // Owned test implementation of the public storage seam. No live store is patched.
  class PendingAttachmentStore extends AttachmentStore {
    readImageRequest(_ref, _target, signal) {
      entered.resolve();
      return new Promise((_resolve, reject) => {
        const aborted = () => reject(new AttachmentError('fixture attachment stopped', 'ATTACHMENT_READ_FAILED'));
        if (signal.aborted) aborted(); else signal.addEventListener('abort', aborted, { once: true });
      });
    }
  }
  await ctx.plugin(PendingAttachmentStore);
  let baseUrl = 'http://127.0.0.1:9/v1';
  let transport = () => { providerCalls++; throw Error('provider must not run'); };
  if (mode === 'idle-timeout') {
    const server = createServer((req, res) => { providerCalls++; req.resume(); res.writeHead(200, { 'content-type': 'text/event-stream' }); res.flushHeaders(); });
    server.listen(0, '127.0.0.1'); await once(server, 'listening');
    const dispatcher = createHttpDispatcher({ proxyEnv: {}, bodyTimeout: 2000, headersTimeout: 1000 });
    baseUrl = `http://127.0.0.1:${server.address().port}/v1`;
    transport = (input, init) => fetch(input, { ...init, dispatcher });
    t.after(async () => { await dispatcher.destroy(); server.closeAllConnections(); await new Promise(done => server.close(done)); });
  }
  const profile = profileFor(baseUrl, transport, mode === 'idle-timeout' ? 50 : 5000);
  ctx.llm.registerAdapter(['fixture'], adapterFor(profile, () => {
    if (mode === 'existing-llm-error') throw new LlmError('fixture owned failure', 'INVALID_CONFIG');
    return ctx.attachments;
  }));
  const consume = async () => {
    const result = [];
    for await (const event of ctx.llm.stream({ provider: 'fixture', model: 'vision', messages: [user('first', mode !== 'idle-timeout')], signal: controller.signal })) result.push(event);
    return result;
  };
  const pending = consume();
  if (mode === 'caller-cancel') { await entered.promise; controller.abort(new Error('fixture user cancel')); }
  const events = await pending;
  const terminal = events.at(-1); t.diagnostic(JSON.stringify({ mode, terminal }));
  assert.equal(terminal.type, 'finish'); assert.equal(providerCalls, mode === 'idle-timeout' ? 1 : 0);
  assert.equal(terminal.reason.kind, mode === 'caller-cancel' ? 'aborted' : 'error');
  assert.equal(terminal.reason.failure.code, { 'caller-cancel': 'ABORTED', 'idle-timeout': 'TIMEOUT', 'existing-llm-error': 'INVALID_CONFIG' }[mode]);
});
