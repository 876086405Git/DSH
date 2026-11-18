// Actual generated OH deletion route, authenticated Host and JSONL-v2; local WS protocol peer.
// This host test uses the existing Linux native flock path. It is not an OH SDK/device test.
import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { writeFileSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { createServer, request } from 'node:http';
import { createRequire } from 'node:module';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';

test('permanent deletion cleans pooled SDK resources after title cancellation and Pi unmount', { timeout: 35000 }, async () => {
const sourceArg = process.env.DSH_SESSION_CLEANUP_SOURCE;
const viewArg = process.env.DSH_SESSION_CLEANUP_VIEW;
const outArg = process.env.DSH_SESSION_CLEANUP_OUTPUT;
assert(sourceArg && viewArg && outArg);
const source = resolve(sourceArg), view = resolve(viewArg), out = resolve(outArg);
const privateRoot = join(out, 'private');
assert.equal(process.cwd(), join(privateRoot, 'work'));
const below = value => {
  const part = relative(privateRoot, value);
  assert(part && !isAbsolute(part) && part !== '..' && !part.startsWith(`..${sep}`));
  return value;
};
const ids = { A: '1278-private-A', B: '1278-private-B' };
const sessionRoot = below(join(privateRoot, 'sessions'));
const storageRoot = below(join(privateRoot, 'storage'));
const credentialPath = below(join(privateRoot, 'credentials.yaml'));
const originals = Object.fromEntries(['fetch', 'Request', 'Response', 'Headers', 'WebSocket', 'Map', 'Set']
  .map(name => [name, globalThis[name]]));
const result = {
  source, view, out, privateRoot, sessionRoot, storageRoot, credentialPath, ids,
  scope: 'Actual installed Cordis, AgentLoop, default first-prompt title, JSONL-v2, Storage/JSON/domain, cache/query/workspace/schedule, WebServer, Connection and generated OH bridge. Linux host marker branch, existing flock and OH HTTP dispatcher; not an OH atomic-publication/SDK/device test or full Host/compose.',
  trace: [], requests: [], peers: [], tcp: [], deletions: [], calls: [], publicCleanupObserver: [],
  titleSignals: [], sessionEvents: [], agentErrors: [], peerErrors: [], fixtureCleanupErrors: [],
  maxRequests: 5, maxPeers: 3, maxFrameBytes: 16384, maxResponseBytes: 4096,
  maxTotalResponseBytes: 24576, totalResponseBytes: 0,
  externalRequests: 0, paidRequests: 0, httpFallbackRequests: 0,
  productModified: false, builtinReplacement: false,
};
let sequence = 0;
const event = (kind, details = {}) => {
  const row = { sequence: ++sequence, monotonicMs: performance.now(), kind, ...details };
  result.trace.push(row); return row;
};
const bounded = async (promise, ms, label) => {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Object.assign(new Error(label), { code: 'OBSERVATION_BOUND' })), ms);
    })]);
  } finally { clearTimeout(timer); }
};
const closeObservation = async (entries, label) => {
  let observationBoundExpired = false;
  try { await bounded(Promise.all(entries.flatMap(entry => [entry.closed, entry.tcp.closed])), 1500, label); }
  catch (error) {
    if (error.code !== 'OBSERVATION_BOUND') throw error;
    observationBoundExpired = true;
  }
  const observed = event('physical-close-observation-frozen', { label, observationBoundExpired });
  return entries.map(entry => ({ connection: entry.row.connection, tcpConnection: entry.tcp.row.connection,
    observedAtSequence: observed.sequence, observedMonotonicMs: observed.monotonicMs, observationBoundExpired,
    closeObserved: entry.row.closeObserved, readyState: entry.socket.readyState,
    close: entry.row.close ? { ...entry.row.close } : null,
    tcp: { closeObserved: entry.tcp.row.closeObserved, destroyed: entry.tcp.socket.destroyed,
      close: entry.tcp.row.close ? { ...entry.tcp.row.close } : null } }));
};
const peerEntries = [], tcpEntries = [];
const mainArrived = Promise.withResolvers(), titleArrived = Promise.withResolvers();
let ctx, mounted, dispatcher, oldDispatcher, setDispatcher, server, wss, publicApi, codexApi;
let unregisterObserver, titleTailTimer, pendingMain, titleStreamOptions, titleReturnedNaturally = false;
let scenarioCompleted = false, peerCloseUnknown = false;
const watchdog = setTimeout(() => {
  result.status = 'ACTOR_DEADLINE_124'; event('actor-deadline');
  try { writeFileSync(join(out, 'TIMEOUT.json'), JSON.stringify(result, null, 2) + '\n'); } catch {}
  process.exit(124);
}, 30000);

function frames(message, role) {
  const text = `1278 ${role} ${randomUUID()}`;
  const index = result.requests.length;
  const item = { id: `msg_1278_${index}`, type: 'message', role: 'assistant', status: 'completed',
    phase: 'final_answer', content: [{ type: 'output_text', text, annotations: [] }] };
  const response = { id: `resp_1278_${index}`, object: 'response', status: 'completed', model: message.model,
    output: [item], usage: { input_tokens: 4, output_tokens: 4, total_tokens: 8,
      input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } };
  const value = [
    { type: 'response.created', response: { ...response, status: 'in_progress', output: [], usage: null } },
    { type: 'response.output_item.added', output_index: 0, item: { ...item, status: 'in_progress', content: [] } },
    { type: 'response.output_text.delta', item_id: item.id, output_index: 0, content_index: 0, delta: text },
    { type: 'response.output_item.done', output_index: 0, item },
    { type: 'response.completed', response },
  ].map(value => JSON.stringify(value));
  assert(value.reduce((sum, value) => sum + Buffer.byteLength(value), 0) <= result.maxResponseBytes);
  return { value, text };
}
function sendFrames(entry, row, encoded) {
  for (const text of encoded) {
    result.totalResponseBytes += Buffer.byteLength(text);
    assert(result.totalResponseBytes <= result.maxTotalResponseBytes);
    entry.socket.send(text, error => {
      if (error) result.peerErrors.push({ where: 'send', message: String(error) });
    });
    // This is send initiation, not evidence of remote consumption.
    event('provider-send-called', { connection: entry.row.connection, role: row.role, type: JSON.parse(text).type });
  }
}
function httpCall(url, { cookie, body } = {}) {
  return new Promise((resolveCall, reject) => {
    const encoded = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
    assert(encoded === undefined || encoded.length <= 4096);
    const req = request(url, { method: encoded === undefined ? 'GET' : 'POST', agent: false,
      headers: { ...(cookie ? { cookie } : {}), ...(encoded ? {
        'content-type': 'application/json', 'content-length': encoded.length,
      } : {}) } }, res => {
      const chunks = []; let size = 0;
      res.on('data', bytes => {
        size += bytes.length;
        if (size > 4096) res.destroy(new Error('HTTP fixture response bound'));
        else chunks.push(bytes);
      });
      res.once('error', reject);
      res.once('end', () => resolveCall({ status: res.statusCode, headers: res.headers,
        body: Buffer.concat(chunks).toString() }));
    });
    req.setTimeout(3000, () => req.destroy(new Error('HTTP fixture request bound')));
    req.once('error', reject); req.end(encoded);
  });
}

try {
  const require = createRequire(join(view, 'package.json'));
  const { WebSocketServer } = require('ws');
  const undici = require('undici');
  oldDispatcher = undici.getGlobalDispatcher(); setDispatcher = undici.setGlobalDispatcher;
  const { createHttpDispatcher } = await import(pathToFileURL(join(source, 'runtime/ohos/net/dispatcher.mjs')));
  dispatcher = createHttpDispatcher({ proxyEnv: {}, headersTimeout: 2000, bodyTimeout: 2000 });
  setDispatcher(dispatcher);
  server = createServer((req, res) => {
    result.httpFallbackRequests++; req.resume();
    res.writeHead(401, { 'content-type': 'application/json' });
    res.end('{"error":{"message":"1278 loopback peer only accepts WS"}}');
  });
  server.on('connection', socket => {
    const row = { connection: tcpEntries.length + 1, closeObserved: false };
    result.tcp.push(row);
    const closed = new Promise(resolveClose => socket.once('close', hadError => {
      const observed = event('tcp-close', { connection: row.connection, hadError });
      row.closeObserved = true;
      row.close = { sequence: observed.sequence, monotonicMs: observed.monotonicMs, hadError };
      resolveClose();
    }));
    socket.on('error', error => result.peerErrors.push({ where: 'tcp', message: String(error) }));
    tcpEntries.push({ socket, row, closed });
  });
  wss = new WebSocketServer({ server, path: '/codex/responses', maxPayload: result.maxFrameBytes,
    perMessageDeflate: false, closeTimeout: 1000 });
  wss.on('connection', (socket, req) => {
    let tcp;
    try {
      assert(peerEntries.length < result.maxPeers); assert.equal(req.socket.remoteAddress, '127.0.0.1');
      tcp = tcpEntries.find(entry => entry.socket === req.socket);
      assert(tcp, 'upgraded request must refer to the original observed TCP socket');
    }
    catch (error) { result.peerErrors.push({ where: 'peer-count', message: String(error) }); socket.terminate(); return; }
    const row = { connection: peerEntries.length + 1, tcpConnection: tcp.row.connection,
      closeObserved: false, messages: 0 };
    result.peers.push(row);
    const closed = new Promise(resolveClose => socket.once('close', (code, reason) => {
      const observed = event('ws-close', { connection: row.connection, tcpConnection: tcp.row.connection,
        code, reason: reason.toString() });
      row.closeObserved = true;
      row.close = { code, reason: reason.toString(), sequence: observed.sequence, monotonicMs: observed.monotonicMs };
      resolveClose();
    }));
    const entry = { socket, row, closed, tcp }; peerEntries.push(entry);
    event('ws-open', { connection: row.connection, tcpConnection: tcp.row.connection });
    socket.on('error', error => result.peerErrors.push({ where: 'ws', message: String(error) }));
    socket.on('message', (bytes, binary) => {
      try {
        assert.equal(binary, false); assert(bytes.length <= result.maxFrameBytes);
        assert(result.requests.length < result.maxRequests);
        const message = JSON.parse(bytes.toString());
        assert.equal(message.type, 'response.create'); assert.equal(message.store, false); assert.equal(message.stream, true);
        assert(Object.values(ids).includes(message.prompt_cache_key));
        const previous = result.requests.filter(item => item.sessionId === message.prompt_cache_key);
        const title = String(message.instructions ?? '').startsWith('Create a concise title for an AI coding-assistant session');
        const role = title ? 'A-title' : message.prompt_cache_key === ids.A ? previous.length === 0 ? 'A-prime' : 'A-main'
          : previous.length === 0 ? 'B-prime' : 'B-after-A-delete';
        assert(!title || message.prompt_cache_key === ids.A);
        const record = { role, sessionId: message.prompt_cache_key, connection: row.connection,
          requestBytes: bytes.length, request: message };
        result.requests.push(record); row.messages++;
        event('provider-request-received', { role, connection: row.connection });
        const response = frames(message, role); record.responseText = response.text;
        if (role === 'A-main') {
          assert.equal(row.connection, result.requests.find(item => item.role === 'A-prime').connection,
            'actual main must reuse the known pooled A peer');
          pendingMain = () => sendFrames(entry, record, response.value);
          mainArrived.resolve(record);
          if (result.requests.some(item => item.role === 'A-title')) pendingMain();
        } else if (role === 'A-title') {
          const main = result.requests.find(item => item.role === 'A-main');
          assert(main, 'title busy/uncached prerequisite requires actual main already received');
          assert.notEqual(row.connection, main.connection);
          sendFrames(entry, record, response.value.slice(0, 3));
          // A bounded slow provider, never an indefinitely unresolved fake.
          titleTailTimer = setTimeout(() => {
            if (socket.readyState !== 1) return;
            titleReturnedNaturally = true; event('fixture-title-delay-expired');
            sendFrames(entry, record, response.value.slice(3));
          }, 3000);
          titleArrived.resolve(record); pendingMain();
        } else sendFrames(entry, record, response.value);
      } catch (error) {
        result.peerErrors.push({ where: 'protocol-or-prerequisite', message: String(error) });
        socket.close(1011, '1278_fixture_precondition');
      }
    });
  });
  wss.on('error', error => result.peerErrors.push({ where: 'wss', message: String(error) }));
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const providerURL = `http://127.0.0.1:${server.address().port}`;
  const load = name => import(pathToFileURL(join(view, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
  const { Context } = await load('cordis');
  ctx = new Context();
  const mount = async (name, config) => {
    const module = await load(name); const fiber = ctx.plugin(module.default ?? module, config);
    await fiber.await(); return fiber;
  };
  for (const name of ['dsh-session-projection', 'dsh-session', 'dsh-agent', 'dsh-llm', 'dsh-storage']) await mount(name);
  await mount('dsh-credentials-local', { path: credentialPath, watch: false });
  const credential = `synthetic.${Buffer.from(JSON.stringify({ 'https://api.openai.com/auth': {
    chatgpt_account_id: '1278-local-only-account' } })).toString('base64')}.not-a-signature`;
  await ctx.credentials.set('SYNTHETIC_1278_LOCAL_KEY', credential);
  await mount('dsh-session-persistence-jsonl', { root: sessionRoot, compression: 'none', listConcurrency: 1 });
  assert.equal(ctx.sessionPersistence.root, sessionRoot);
  await mount('dsh-storage-json', { root: storageRoot });
  await mount('dsh-storage-domain', { backend: 'json', routes: {} });
  await mount('dsh-session-projection-cache', { writeEveryEvents: 200, writeIntervalMs: 5000 });
  await mount('dsh-session-query');
  await mount('dsh-workspace');
  await mount('dsh-system-prompt', { personaPrefix: '', includeRuntimeContext: false });
  await mount('dsh-tools');
  await mount('dsh-tool-executor-native');
  await mount('dsh-agent-loop', { agents: [], maxParallelToolCalls: 1 });
  await mount('dsh-schedule', {});
  await mount('dsh-session-title', { fallbackMaxWords: 5, fallbackMaxBytes: 40, maxTitleBytes: 80 });
  await mount('dsh-session-title-first-prompt-llm', { targetWords: 5, targetCjkCharacters: 10,
    maxInputBytes: 4096, maxOutputTokens: 4096, timeoutMs: 60000 });
  mounted = await mount('dsh-llm-pi-ai', { providers: { 'openai-codex': {
    apiKeyEnv: 'SYNTHETIC_1278_LOCAL_KEY', baseURL: providerURL, transport: 'auto',
    timeoutMs: 2000, websocketConnectTimeoutMs: 2000, streamIdleTimeoutMs: 5000,
  } } });
  await mount('dsh-host-webserver', { host: '127.0.0.1', port: 0, compression: 'none' });
  await mount('dsh-client-connection', {});
  const bridgePath = join(view, 'runtime/bridge/dsh-go-bridge/lib/index.js');
  const bridge = await import(pathToFileURL(bridgePath));
  const bridgeFiber = ctx.plugin(bridge, { persist: false }); await bridgeFiber.await();
  const publicRootUrl = import.meta.resolve('@earendil-works/pi-ai', pathToFileURL(bridgePath).href);
  publicApi = await import(publicRootUrl);
  result.publicModule = { url: publicRootUrl, beforeUnmount: true };
  unregisterObserver = publicApi.registerSessionResourceCleanup(id => {
    const row = event('public-cleanup-observer', { id }); result.publicCleanupObserver.push(row);
  });
  // A real public registry observer, not a replacement for Codex's existing callback.
  ctx.on('llm/stream', (options, next) => {
    if (options.purpose === 'session-title') {
      assert.equal(options.sessionId, ids.A); titleStreamOptions = options;
      const row = { sessionId: options.sessionId, purpose: options.purpose, aborted: options.signal.aborted };
      result.titleSignals.push(row); event('real-title-stream', { sessionId: options.sessionId });
      options.signal.addEventListener('abort', () => {
        row.aborted = true; row.reason = String(options.signal.reason);
        row.abortSequence = event('original-title-signal-aborted', { reason: row.reason }).sequence;
      }, { once: true });
    }
    return next(); // No wrapping, extra await, delay or replacement iterator.
  }, { global: true });
  ctx.on('session/disposed', session => event('session-disposed', { id: session.id }));
  ctx.on('dsh-go/session-deleted', id => event('permanent-deletion-event', { id }));
  ctx.on('agent/error', ({ agent, error }) => result.agentErrors.push({ id: agent?.id, message: String(error) }));
  ctx.on('session/event', (session, value) => {
    if (['user/message', 'session/title-llm-request', 'assistant/message', 'turn/end'].includes(value.type))
      result.sessionEvents.push({ id: session.id, event: value });
  });
  const origin = ctx.webServer.getOrigin();
  result.webOrigin = origin; result.providerURL = providerURL;
  assert.equal((await httpCall(new URL('/dsh-go/v1/sessions/deletion', origin))).status, 401);
  const launch = new URL(ctx.connection.authenticatedUrl(origin)); launch.pathname = '/connect';
  const auth = await httpCall(launch); assert.equal(auth.status, 302);
  const cookie = auth.headers['set-cookie'].map(value => value.split(';', 1)[0]).join('; ');
  const capability = await httpCall(new URL('/dsh-go/v1/sessions/deletion', origin), { cookie });
  assert.equal(capability.status, 200); assert.deepEqual(JSON.parse(capability.body), { supported: true, version: 1 });
  result.authentication = { unauthenticatedStatus: 401, tokenExchangeStatus: 302, capabilityStatus: 200,
    credentialsArePrivateSynthetic: true };
  const model = (await ctx.llm.listModels('openai-codex'))[0]; assert(model);
  const agents = {};
  for (const key of ['A', 'B']) {
    agents[key] = (await ctx.agentLoop.createAgent(ctx, { sessionId: ids[key], meta: { cwd: process.cwd() },
      agentOptions: { provider: 'openai-codex', model: model.id, maxTokens: 16 } })).agent;
  }
  await ctx.sessionPersistence.flush();
  const call = async (key, role) => {
    const chunks = await Array.fromAsync(ctx.llm.stream({ provider: 'openai-codex', model: model.id,
      sessionId: ids[key], maxTokens: 16, tools: [], signal: AbortSignal.timeout(6000),
      messages: [{ role: 'user', content: [{ type: 'text', text: '1278 private loopback observation.' }] }] }));
    const text = chunks.filter(chunk => chunk.type === 'text-delta').map(chunk => chunk.text).join('');
    assert.equal(chunks.at(-1)?.type, 'finish'); assert.equal(chunks.at(-1).reason.kind, 'stop');
    assert.equal(text, result.requests.find(row => row.role === role)?.responseText);
    result.calls.push({ role, chunks, text }); event('public-call-finished', { role });
  };
  await call('A', 'A-prime'); await call('B', 'B-prime');
  // Public diagnostic entry only after real provider use has lazily loaded the implementation.
  codexApi = await import(import.meta.resolve('@earendil-works/pi-ai/api/openai-codex-responses', pathToFileURL(bridgePath).href));
  const { createUserMessage } = await load('dsh-llm');
  agents.A.followup(createUserMessage({ source: { kind: 'user' },
    content: [{ type: 'text', text: '1278 private first human turn, answer briefly.' }] }));
  await bounded(Promise.all([mainArrived.promise, titleArrived.promise]), 5000, 'actual default title/busy prerequisite');
  await bounded(agents.A.whenIdle(), 5000, 'actual Agent turn must complete');
  assert.equal(agents.A.phase.kind, 'idle');
  assert(titleStreamOptions && !titleStreamOptions.signal.aborted && !titleReturnedNaturally);
  assert.equal(result.agentErrors.length, 0); assert.equal(result.peerErrors.length, 0);
  const mainText = result.requests.find(row => row.role === 'A-main').responseText;
  assert(result.sessionEvents.some(row => row.id === ids.A && row.event.type === 'assistant/message'
    && row.event.data.message.content.some(block => block.type === 'text' && block.text === mainText)));
  assert(result.sessionEvents.some(row => row.id === ids.A && row.event.type === 'session/title-llm-request'));
  result.busyTitlePrerequisite = { actualMainReusedA: true, actualTitleOnDistinctPeer: true,
    mainNonceInSessionLog: true, agentIdle: true, originalTitleSignalStillLive: true,
    defaultProviderMountedWithBaseConfiguration: true, forcedLlmOrdering: false };
  const remove = async (key, piUnmounted) => {
    const target = result.requests.find(row => row.role === `${key}-prime`).connection;
    const before = result.publicCleanupObserver.length;
    assert.equal(peerEntries.find(entry => entry.row.connection === target).socket.readyState, 1);
    const started = event('authenticated-delete-start', { id: ids[key], piUnmounted });
    const response = await httpCall(new URL('/dsh-go/v1/sessions/delete', origin), { cookie, body: { sessionId: ids[key] } });
    const returned = event('authenticated-delete-response', { id: ids[key], status: response.status });
    assert.equal(response.status, 200); assert.deepEqual(JSON.parse(response.body), { deleted: true, sessionId: ids[key] });
    assert.equal(ctx.sessionPersistence.dshGoDeletion.deleted(ids[key]), true);
    assert.equal(ctx.agents.get(ids[key]), undefined); assert.equal(ctx.sessions.get(ids[key]), undefined);
    assert.equal(ctx.sessionPersistence.tracker.writers.has(ids[key]), false);
    const calls = result.publicCleanupObserver.slice(before);
    const entries = peerEntries.filter(entry => entry.row.connection === target || key === 'A'
      && entry.row.connection === result.requests.find(row => row.role === 'A-title').connection);
    const closes = await closeObservation(entries, `${key} physical close observation`);
    peerCloseUnknown ||= closes.some(row => !row.closeObserved || !row.tcp.closeObserved);
    result.deletions.push({ id: ids[key], piUnmounted, started: started.sequence, returned: returned.sequence,
      cleanupCallsBeforeResponse: calls.filter(row => row.sequence < returned.sequence), physicalCloses: closes,
      tombstoned: true, agentRemoved: true, sessionRemoved: true, writerRemoved: true,
      debugAfter: codexApi.getOpenAICodexWebSocketDebugStats(ids[key]) ?? null });
  };
  await remove('A', false);
  assert(titleStreamOptions.signal.aborted && String(titleStreamOptions.signal.reason).includes('session disposed during title generation'));
  assert(!titleReturnedNaturally, 'title must end through original disposal signal before delayed provider EOF');
  clearTimeout(titleTailTimer);
  assert.equal(result.publicCleanupObserver.filter(row => row.id === ids.B).length, 0);
  await call('B', 'B-after-A-delete');
  assert.equal(result.requests.find(row => row.role === 'B-prime').connection,
    result.requests.find(row => row.role === 'B-after-A-delete').connection);
  event('other-id-successfully-reused');
  const sameRootBefore = publicApi.cleanupSessionResources;
  await mounted.dispose(); mounted = undefined; event('pi-unmounted');
  assert.equal((await import(publicRootUrl)).cleanupSessionResources, sameRootBefore);
  assert.equal((await import(pathToFileURL(bridgePath))).apply, bridge.apply);
  result.publicModule.sameFunctionAfterPiUnmount = true;
  result.bridgeLifetime = { fiberStillActive: bridgeFiber.state === 2, sameModuleApply: true,
    routeStillRegistered: ctx.webServer.prefixes.has('/dsh-go') };
  assert(result.bridgeLifetime.fiberStillActive && result.bridgeLifetime.routeStillRegistered);
  await remove('B', true);
  assert.equal(result.requests.length, 5); assert.equal(result.httpFallbackRequests, 0);
  assert.equal(result.peerErrors.length, 0);
  result.actualNativeModules = Object.keys(require.cache).filter(path => path.endsWith('.node'));
  scenarioCompleted = true;
} catch (error) {
  result.failure = { name: error?.name, code: error?.code, message: error?.message, stack: error?.stack };
  event('observation-incomplete', { message: String(error) });
} finally {
  event('fixture-cleanup-start'); clearTimeout(titleTailTimer);
  unregisterObserver?.();
  // Fixture cleanup is strictly later than the deletion observations and is separately labelled.
  for (const id of Object.values(ids)) {
    try { publicApi?.cleanupSessionResources(id); codexApi?.resetOpenAICodexWebSocketDebugStats(id); }
    catch (error) { result.fixtureCleanupErrors.push({ where: 'sdk-control', message: String(error) }); }
  }
  try { await ctx?.fiber.dispose(); } catch (error) { result.fixtureCleanupErrors.push({ where: 'context', message: String(error) }); }
  try { if (setDispatcher) setDispatcher(oldDispatcher); await dispatcher?.destroy(); }
  catch (error) { result.fixtureCleanupErrors.push({ where: 'dispatcher', message: String(error) }); }
  const closingServer = server ? new Promise(resolveClose => server.close(resolveClose)) : Promise.resolve();
  const closingWs = wss ? new Promise(resolveClose => wss.close(resolveClose)) : Promise.resolve();
  for (const entry of peerEntries) if (!entry.row.closeObserved) {
    event('fixture-ws-terminate', { connection: entry.row.connection }); entry.socket.terminate();
  }
  for (const entry of tcpEntries) if (!entry.row.closeObserved) {
    event('fixture-tcp-destroy', { connection: entry.row.connection }); entry.socket.destroy();
  }
  await Promise.all([closingServer, closingWs, ...peerEntries.map(entry => entry.closed), ...tcpEntries.map(entry => entry.closed)]);
  result.globalIdentitiesPreserved = Object.entries(originals).every(([name, value]) => globalThis[name] === value);
  result.resourceOracle = result.deletions.map(row => ({ id: row.id,
    observedTargetCalls: row.cleanupCallsBeforeResponse.filter(call => call.id === row.id).length,
    otherCalls: row.cleanupCallsBeforeResponse.filter(call => call.id !== row.id).length,
    expectedTargetCalls: 1 }));
  const cleanupMissing = result.resourceOracle.length === 2
    && result.resourceOracle.every(row => row.observedTargetCalls === 0 && row.otherCalls === 0);
  const cleanupExact = result.resourceOracle.length === 2
    && result.resourceOracle.every(row => row.observedTargetCalls === 1 && row.otherCalls === 0);
  result.status = !scenarioCompleted || result.fixtureCleanupErrors.length || !result.globalIdentitiesPreserved
    ? 'PRECONDITION_OR_EXECUTION_INCOMPLETE'
    : cleanupMissing ? 'RESOURCE_CLEANUP_NOT_INVOKED'
    : !cleanupExact ? 'CLEANUP_DISPATCH_COUNT_OR_ID_UNKNOWN'
    : peerCloseUnknown ? 'CLEANUP_INVOKED_PHYSICAL_CLOSE_NOT_OBSERVED_IN_BOUND'
    : 'BOUNDED_CONTRACT_OBSERVATION_COMPLETE';
  result.finalZeroIsFixtureTeardownOnly = true;
  result.finalPeerCloseCount = peerEntries.filter(entry => entry.row.closeObserved).length;
  result.finalTcpCloseCount = tcpEntries.filter(entry => entry.row.closeObserved).length;
  event('fixture-cleanup-finished');
  await writeFile(join(out, 'OBSERVATION.json'), JSON.stringify(result, null, 2) + '\n');
  clearTimeout(watchdog);
  console.log(JSON.stringify({ status: result.status, requests: result.requests.length,
    peers: result.peers.length, resourceOracle: result.resourceOracle, globalIdentitiesPreserved: result.globalIdentitiesPreserved }));
  assert.equal(result.status, 'BOUNDED_CONTRACT_OBSERVATION_COMPLETE');
}
});
