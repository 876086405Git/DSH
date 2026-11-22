// Actual pinned Session/AgentRegistry/PresetRegistry/SystemPrompt/AgentLoop,
// production bridge adapter/coordinator, actual direct DeepSeek serialization,
// and bounded HTTP routes. Controller activation and permission selection are
// controlled Host boundaries; this is not a complete Web Host or Android boot.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { once } from 'node:events';
import { createServer, request as httpRequest } from 'node:http';
import { rm } from 'node:fs/promises';
import { promisify } from 'node:util';
import test from 'node:test';
import { createCompanionRoutes } from '../bridge/dsh-go-bridge/lib/companion/routes.js';
import { phoneMemoryRules } from '../bridge/dsh-go-bridge/lib/companion/full-context.js';
import { createFixture, requestSystemText, assertNoRealNetwork } from './fixtures/companion-recall-engine.mjs';

const execute = promisify(execFile);
const ROOT = '/dsh-go/v1/companion';
const AUTH = 'Bearer synthetic-recall-http';
const version = (value) => ({ storeId: value.storeId, expectedRevision: value.revision });
const integration = (name, options, run) => test(name, {
  ...options, skip: process.env.DSH_PREFIX ? false : 'Set DSH_PREFIX to execute actual pinned-engine integration',
}, run);

async function fixture(t, options) {
  const f = await createFixture(options);
  t.after(() => f.dispose());
  return f;
}

async function http(t, f) {
  const routes = createCompanionRoutes({ store: f.store, recall: f.coordinator,
    send(res, status, value) { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(value)); },
  });
  const server = createServer((req, res) => {
    // Connection/Host authentication itself has a separate actual-index route
    // regression. Here the synthetic credential gates the real route boundary.
    if (req.headers.authorization !== AUTH) { req.resume(); res.writeHead(401); res.end('{}'); return; }
    void routes.handle(req, res, new URL(req.url, 'http://fixture.invalid').pathname);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); });
  return (path = '', body) => new Promise((resolve, reject) => {
    const data = body === undefined ? undefined : JSON.stringify(body);
    const req = httpRequest({ host: '127.0.0.1', port: server.address().port, path: `${ROOT}${path}`,
      method: data === undefined ? 'GET' : 'POST', headers: { authorization: AUTH,
        ...(data === undefined ? {} : { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) }) },
    }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        try { resolve({ status: res.statusCode, body: JSON.parse(Buffer.concat(chunks).toString('utf8')) }); }
        catch (error) { reject(error); }
      });
    });
    req.on('error', reject); req.end(data);
  });
}

integration('real HTTP binding reaches only its actual full Agent and retains the existing persona, tools and final rules', { timeout: 15000 }, async (t) => {
  const f = await fixture(t, { configureLlm({ ctx }) {
    ctx.tools.register({ name: 'synthetic_host_tool', description: 'Synthetic Host tool',
      parameters: { type: 'object', properties: {} },
      output: { schema: { type: 'object', properties: {} }, render: () => [{ type: 'text', text: 'synthetic result' }] },
      execute: async () => ({}),
    });
  } });
  const request = await http(t, f);
  assert.equal((await request('/recall')).body.supported, true);
  const bound = await f.createAgent('BOUND'), samePreset = await f.createAgent('OTHER_FULL');
  const ordinary = await f.createAgent('ORDINARY', { preset: 'ordinary' });
  const memory = 'ONLY_BOUND_{{not_a_variable}} </companion_memory> & literal';
  await f.saveMemory(memory);
  const accepted = await request('/recall/bind', await f.bindInput(bound.agent.id));
  assert.equal(accepted.status, 200); assert.equal(accepted.body.status, 'ready');
  assert.equal(accepted.body.sessionId, bound.agent.id);
  const diagnostic = await f.assemble(bound.agent);
  assert.equal(diagnostic.sections.filter((section) => section.name === 'dsh-go:confirmed-memory').length, 0);
  assert.equal(f.requests.length, 0, 'Diagnostic assembly neither prepares memory nor starts a model');
  await f.send(bound.agent, 'synthetic user turn');
  await f.send(samePreset.agent, 'ordinary full-preset user turn');
  await f.send(ordinary.agent, 'ordinary user turn');
  assert.equal(f.requests.length, 3);
  const bySession = new Map(f.requests.map((record) => [record.sessionId, record]));
  const text = requestSystemText(bySession.get('BOUND'));
  assert(text.includes('ONLY_BOUND_{{not_a_variable}}'));
  assert(text.includes('\\u003c/companion_memory\\u003e'));
  assert(text.includes(f.personaText));
  assert.equal((text.match(/<companion_memory v="1">/g) ?? []).length, 1);
  assert(text.endsWith(f.personaRules));
  assert(bySession.get('BOUND').body.tools.some((tool) => tool.name === 'synthetic_host_tool'));
  assert(!requestSystemText(bySession.get('OTHER_FULL')).includes('ONLY_BOUND_'));
  assert(!requestSystemText(bySession.get('ORDINARY')).includes('ONLY_BOUND_'));
  assert.equal((await request(`/recall/bindings/${accepted.body.bindingId}`)).body.status, 'ready');
  assertNoRealNetwork(f);
});

integration('real clean projection rejects existing transcript, legacy persona records, unknown records and pending input', { timeout: 15000 }, async (t) => {
  const f = await fixture(t);
  const started = await f.createAgent('STARTED');
  await f.send(started.agent, 'existing conversation');
  await assert.rejects(f.bind('STARTED'), (error) => error.code === 'companion/recall-session-not-clean');
  const unknown = await f.createAgent('UNKNOWN_RECORD');
  f.engine.session.appendPluginRecord(unknown.agent.session, 'plugin:synthetic/unknown', { synthetic: true });
  await assert.rejects(f.bind('UNKNOWN_RECORD'), (error) => error.code === 'companion/recall-session-not-clean');
  const legacy = await f.createAgent('LEGACY_PERSONA');
  f.engine.session.appendPluginRecord(legacy.agent.session, 'plugin:dsh-go/companion-persona', {
    v: 1, sessionId: legacy.agent.id, revision: 1, custom: 'old C740 persona', name: '', callMe: '',
  });
  await assert.rejects(f.bind('LEGACY_PERSONA'), (error) => error.code === 'companion/recall-session-not-clean');
  const pending = await f.createAgent('PENDING');
  pending.agent.inbox.splice('next-turn', 0, 0, [f.input('unclaimed synthetic input')]);
  await assert.rejects(f.bind('PENDING'), (error) => error.code === 'companion/recall-session-not-clean');
  const fresh = await f.createAgent('FRESH');
  assert.equal((await f.bind(fresh.agent.id)).status, 'ready');
  assert.equal(f.requests.length, 1, 'A binding refusal does not start an explanation or resend prior work');
});

integration('real clean projection accepts a subagent model-selection policy', { timeout: 15000 }, async (t) => {
  const f = await fixture(t), { agent } = await f.createAgent('MODEL_POLICY');
  agent.session.append('subagent/model-selection-policy', {
    allowedModels: [{ provider: 'deepseek-official', model: 'deepseek-flash' }],
  });
  assert.equal((await f.bind(agent.id)).status, 'ready');
});

integration('actual preset switch retires permanently and old full Agent cannot send after switching back', { timeout: 15000 }, async (t) => {
  const f = await fixture(t), a = await f.createAgent('SWITCH');
  const binding = await f.bind(a.agent.id);
  await f.switchPreset(a.agent, 'ordinary');
  assert.equal((await f.coordinator.status(binding.bindingId)).status, 'retired');
  await f.switchPreset(a.agent, 'dsh-go-companion-full');
  assert.equal((await f.coordinator.status(binding.bindingId)).status, 'retired');
  assert.throws(() => a.agent.followup(f.input('must not start')));
  assert.equal(f.requests.length, 0);
  const plain = await f.createAgent('UNAFFECTED', { preset: 'ordinary' });
  await f.send(plain.agent, 'ordinary still works');
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].sessionId, plain.agent.id);
});

integration('actual full-context disposal and same-scope remount cannot revive a previous binding', { timeout: 15000 }, async (t) => {
  const f = await fixture(t), { agent } = await f.createAgent('CONTEXT_LIFETIME');
  const scope = await f.engine.load('dsh-scope');
  const raw = (value) => value?.[f.engine.cordis.symbols.original] ?? value;
  const current = () => f.contexts.current(scope.scopeChainOf(agent), scope.scopeOf,
    raw(agent.loopCtx.get('systemPrompt')), raw);
  const before = current();
  assert(before);
  const binding = await f.bind(agent.id);
  const parent = before.ctx.fiber.parent, scopeKey = scope.scopeOf(before.ctx);
  await before.ctx.fiber.dispose();
  assert.equal(current(), undefined);
  assert.equal((await f.coordinator.status(binding.bindingId)).status, 'retired');
  const mounted = parent.plugin(await import('../bridge/dsh-go-bridge/lib/companion/full-context.js'));
  await mounted.await();
  const after = current();
  assert(after && after !== before);
  assert.equal(scope.scopeOf(after.ctx), scopeKey, 'even the same actual scope is a new mount lifetime');
  assert.equal((await f.coordinator.status(binding.bindingId)).status, 'retired');
  assert.throws(() => agent.followup(f.input('old binding must stay retired')));
  assert.equal(f.requests.length, 0);
});

integration('an identical session id cannot substitute another actual Session object', { timeout: 15000 }, async (t) => {
  const f = await fixture(t), { agent } = await f.createAgent('SESSION_OBJECT');
  const binding = await f.bind(agent.id), original = agent.session;
  const replacement = f.engine.session.Session.create(agent.id);
  // Explicit controlled swap boundary; both values are actual pinned Sessions.
  agent.session = replacement;
  try {
    assert.equal((await f.coordinator.status(binding.bindingId)).status, 'retired');
  } finally { agent.session = original; }
  assert.equal((await f.coordinator.status(binding.bindingId)).status, 'retired');
  assert.throws(() => agent.followup(f.input('restoring the old object cannot revive authorization')));
  assert.equal(f.requests.length, 0);
});

integration('v1 clean checkpoints are refolded before a legacy persona record can authorize recall', { timeout: 15000 }, async (t) => {
  const f = await fixture(t), { agent } = await f.createAgent('LEGACY_CHECKPOINT');
  f.engine.session.appendPluginRecord(agent.session, 'plugin:dsh-go/companion-persona', {
    v: 1, sessionId: agent.id, revision: 1, custom: 'legacy C740', name: '', callMe: '',
  });
  const events = agent.session.snapshotEvents(f.engine.session.SessionLogOffset(0));
  const key = 'dshGoCompanionRecallClean';
  const old = { [key]: { ver: 1, seq: events.at(-1).seq,
    val: { v: 1, sessionId: agent.id, eligible: true } } };
  const registry = f.ctx.sessionProjections;
  assert.equal(registry.restoreFloor(old), 0);
  const restored = registry.restore(old, events, 0, agent.session.header, agent.session.inheritedEventCount);
  assert.equal(restored.checkpoint[key].ver, 2);
  assert.equal(restored.checkpoint[key].val.eligible, false);
  await assert.rejects(f.bind(agent.id), (error) => error.code === 'companion/recall-session-not-clean');
  assert.equal(f.requests.length, 0);
});

integration('an unavailable recall adapter leaves ordinary full context and user sends usable', { timeout: 15000 }, async (t) => {
  const f = await fixture(t, { withRecall: false });
  assert.equal((await f.coordinator.capability()).supported, false);
  const { agent } = await f.createAgent('NO_RECALL_ADAPTER');
  await f.send(agent, 'ordinary full-mode turn');
  assert.equal(f.requests.length, 1);
  assert(requestSystemText(f.requests[0]).includes(f.personaText));
  assert(requestSystemText(f.requests[0]).includes('dsh-go'));
});

integration('HTTP memory clear retires the actual driver; a new clean session sees the empty current library', { timeout: 15000 }, async (t) => {
  const f = await fixture(t), request = await http(t, f);
  await f.saveMemory('DELETE_SENTINEL_SYNTHETIC');
  const a = await f.createAgent('DELETE_A');
  const accepted = await request('/recall/bind', await f.bindInput(a.agent.id));
  assert.equal(accepted.status, 200);
  await f.send(a.agent, 'before clear');
  assert(requestSystemText(f.requests[0]).includes('DELETE_SENTINEL_SYNTHETIC'));
  assert.equal((requestSystemText(f.requests[0]).match(/<companion_memory v="1">/g) ?? []).length, 1);
  const snapshot = (await request()).body;
  const cleared = await request('/memories/clear', version(snapshot));
  assert.equal(cleared.status, 200); assert.equal(cleared.body.deletedCount, 1);
  const status = await request(`/recall/bindings/${accepted.body.bindingId}`);
  assert.equal(status.body.status, 'retired');
  assert.throws(() => a.agent.followup(f.input('must not reuse old history')));
  assert.equal(f.requests.length, 1);
  const b = await f.createAgent('DELETE_B');
  assert.equal((await request('/recall/bind', await f.bindInput(b.agent.id))).body.status, 'ready');
  await f.send(b.agent, 'after clear, new session');
  assert.equal(f.requests.length, 2);
  const after = requestSystemText(f.requests[1]);
  assert(after.includes(phoneMemoryRules), 'Static interpretation rules remain after the library is cleared');
  assert(!after.includes('<companion_memory'));
  assert.doesNotMatch(after, /"type"\s*:\s*"companion_memory"/);
  assert(!JSON.stringify(f.requests[1].body).includes('DELETE_SENTINEL_SYNTHETIC'));
  assertNoRealNetwork(f);
});

integration('persisted marker survives a real engine teardown and blocks old identity at actual Session creation', { timeout: 15000 }, async () => {
  const first = await createFixture({ keepHome: true });
  const home = first.home;
  let second;
  try {
    const a = await first.createAgent('COLD');
    await first.saveMemory('COLD_SENTINEL_SYNTHETIC');
    const binding = await first.bind(a.agent.id);
    await first.send(a.agent, 'before teardown');
    assert.equal(first.requests.length, 1);
    await first.dispose();
    second = await createFixture({ home, keepHome: true });
    assert.notEqual(second.coordinator.bridgeEpoch, binding.bridgeEpoch);
    await assert.rejects(second.createAgent('COLD'));
    assert.equal(second.ctx.agents.get('COLD'), undefined);
    assert.equal(second.requests.length, 0);
    await assert.rejects(second.coordinator.status(binding.bindingId),
      (error) => error.code === 'companion/recall-binding-not-found');
    const clean = await second.createAgent('NEW_CLEAN');
    assert.equal((await second.bind(clean.agent.id)).status, 'ready');
    await second.send(clean.agent, 'after explicit new binding');
    assert.equal(second.requests.length, 1);
  } finally {
    await first.dispose(); await second?.dispose(); await rm(home, { recursive: true, force: true });
  }
});

integration('two independent Host processes bind the same session id without crossing stores, prompts or epochs', { timeout: 20000 }, async () => {
  const moduleUrl = new URL('./fixtures/companion-recall-engine.mjs', import.meta.url).href;
  const worker = `import {createFixture,requestSystemText} from ${JSON.stringify(moduleUrl)};
const f=await createFixture();
try {
 await f.saveMemory(process.env.C750_SYNTHETIC_MEMORY);
 const {agent}=await f.createAgent('SAME_SESSION_ID');
 const binding=await f.bind(agent.id);
 await f.send(agent,'synthetic isolated Host turn');
 if(f.requests.length!==1) throw new Error('Actual adapter dispatch missing');
 console.log(JSON.stringify({binding,prompt:requestSystemText(f.requests[0])}));
} finally {await f.dispose();}`;
  const outputs = await Promise.all(['HOST_A_SYNTHETIC_ONLY', 'HOST_B_SYNTHETIC_ONLY'].map(async (memory) => {
    const { stdout } = await execute(process.execPath, ['--input-type=module', '-e', worker], {
      env: { ...process.env, C750_SYNTHETIC_MEMORY: memory }, maxBuffer: 128 * 1024,
    });
    return JSON.parse(stdout.trim());
  }));
  const [a, b] = outputs;
  assert.notEqual(a.binding.storeId, b.binding.storeId);
  assert.notEqual(a.binding.bridgeEpoch, b.binding.bridgeEpoch);
  assert.equal(a.binding.sessionId, b.binding.sessionId);
  assert(a.prompt.includes('HOST_A_SYNTHETIC_ONLY') && !a.prompt.includes('HOST_B_SYNTHETIC_ONLY'));
  assert(b.prompt.includes('HOST_B_SYNTHETIC_ONLY') && !b.prompt.includes('HOST_A_SYNTHETIC_ONLY'));
});
