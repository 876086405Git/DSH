// Owner-run pinned-engine coverage. No real model network: the existing fixture
// captures the actual direct adapter's POST and returns synthetic SSE replies.
// DSH_PREFIX must include companion-phone-memory-request.diff.
import assert from 'node:assert/strict';
import test from 'node:test';
import { createFixture, requestSystemText } from './fixtures/companion-recall-engine.mjs';

const integration = (name, run) => test(name, {
  skip: !process.env.DSH_PREFIX && 'Set DSH_PREFIX to the actual patched runtime; not run without it',
  concurrency: false, timeout: 15000,
}, run);
const memoryText = 'A03_PHONE_SELECTED_🐋_{{literal}}_</companion_memory>';
const block = (empty = false) => JSON.stringify({ type: 'companion_memory', version: 2, scope: 'real',
  items: empty ? [] : [{ id: 'phone-z', kind: 'fact', text: memoryText }, { id: 'phone-a', kind: 'preference', text: '先听我说完' }],
});
const phone = (extra = {}) => ({ archiveId: 'A03_PHONE_ARCHIVE', controlRevision: 0, historyAfterSeq: 0, block: block(), ...extra });
const fail = (fn, code) => assert.throws(fn, error => error.code === `companion/${code}`);
async function fixture(t, options) {
  const f = await createFixture(options);
  t.after(() => f.dispose());
  assert.equal(f.ctx.llm.dshGoPhoneMemory, true, 'the declared runtime patch must actually be installed');
  const input = (rpcId, text = '  用户未改写的原话\n') => f.engine.llm.createUserMessage({
    source: { kind: 'user', rpcId }, content: [{ type: 'text', text }],
  });
  const prepare = (agent, requestId, phoneMemory = phone()) => f.promptContext.prepare(agent, {
    v: 1, instanceId: f.promptContext.info(agent).instanceId, sessionId: agent.id, requestId, events: [], phoneMemory,
  });
  const send = async (agent, rpcId) => { agent.followup(input(rpcId)); await agent.whenIdle(); };
  const events = session => session.snapshotEvents(f.engine.session.SessionLogOffset(0));
  return { ...f, input, prepare, send, events };
}
const memoryBlocks = request => request.body.messages.flatMap(message => message.content)
  .filter(content => content.type === 'text' && content.text === block());

integration('actual main loop sends the exact phone JSON once, then zero times for empty; Session keeps original humans', async t => {
  const f = await fixture(t), { agent } = await f.createAgent('PHONE_MAIN');
  await f.saveMemory('LEGACY_HOST_MEMORY_SHOULD_NOT_APPEAR', { keywords: ['原话'], pinned: true });
  f.prepare(agent, 'selected'); await f.send(agent, 'selected');
  assert.equal(f.requests.length, 1);
  assert.equal(memoryBlocks(f.requests[0]).length, 1);
  assert.doesNotMatch(requestSystemText(f.requests[0]), /A03_PHONE_SELECTED|LEGACY_HOST_MEMORY/);
  assert.equal(f.requests[0].body.messages.at(-1).content[0].text, '  用户未改写的原话\n');
  const firstEvents = f.events(agent.session);
  assert.doesNotMatch(JSON.stringify(firstEvents), /A03_PHONE_SELECTED|phone-z|phone-a/);
  const human = firstEvents.find(event => event.type === 'user/message' && event.data.source?.rpcId === 'selected');
  assert.deepEqual(human.data.content, [{ type: 'text', text: '  用户未改写的原话\n' }]);
  assert.doesNotMatch(f.promptContext.render(agent), /A03_PHONE_SELECTED/);
  f.prepare(agent, 'empty', phone({ block: block(true) })); await f.send(agent, 'empty');
  assert.equal(f.requests.length, 2);
  assert.equal(memoryBlocks(f.requests[1]).length, 0);
  assert.doesNotMatch(JSON.stringify(f.requests[1].body.messages), /A03_PHONE_SELECTED|LEGACY_HOST_MEMORY/);
  await f.send(agent, 'without-sidecar');
  assert.equal(f.requests.length, 3);
  assert.doesNotMatch(JSON.stringify(f.requests[2].body.messages), /A03_PHONE_SELECTED/);
  assert.doesNotMatch(JSON.stringify(f.events(agent.session)), /A03_PHONE_SELECTED/);
});

integration('actual unmarked auxiliary LlmRuntime calls cannot inherit an active phone selection', async t => {
  const f = await fixture(t), { agent } = await f.createAgent('PHONE_AUX');
  f.prepare(agent, 'active');
  const message = f.input('active');
  agent.inbox.append('next-turn', message); agent.inbox.claim('next-turn', 1);
  await f.ctx.agents.withInitiator(agent, async () => {
    const chunks = [];
    for await (const chunk of f.ctx.llm.stream({ ...f.route, sessionId: agent.id,
      messages: [message], signal: new AbortController().signal })) chunks.push(chunk);
    assert(chunks.length > 0);
  });
  assert.equal(f.requests.length, 1);
  assert.doesNotMatch(JSON.stringify(f.requests[0].body.messages), /A03_PHONE_SELECTED/);
  assert.equal(memoryBlocks(f.requests[0]).length, 0);
});

integration('control received during actual provider credential await prevents the physical POST', async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  t.after(() => release.resolve());
  const f = await fixture(t, { deepseekDependencies: { async resolveAuth() {
    entered.resolve(); await release.promise;
    return { headers: { authorization: 'Bearer synthetic-not-a-credential' } };
  } } });
  const { agent } = await f.createAgent('PHONE_OLD'), { agent: clean } = await f.createAgent('PHONE_CLEAN');
  f.prepare(agent, 'old'); agent.followup(f.input('old'));
  await entered.promise;
  f.prepare(clean, 'after-control', phone({ controlRevision: 1, historyAfterSeq: 20, block: block(true) }));
  release.resolve(); await agent.whenIdle();
  assert.equal(f.requests.length, 0, 'the retired selected block must not reach fetch after the await');
  fail(() => f.prepare(agent, 'late', phone()), 'memory-context-stale');
  await f.send(clean, 'after-control');
  assert.equal(f.requests.length, 1);
  assert.doesNotMatch(JSON.stringify(f.requests[0].body.messages), /A03_PHONE_SELECTED/);
});

integration('actual Session replay and compaction contain no request-only phone selection', async t => {
  const f = await fixture(t), { agent } = await f.createAgent('PHONE_COMPACT');
  f.prepare(agent, 'original'); await f.send(agent, 'original');
  const seed = f.events(agent.session);
  const replayed = f.engine.session.Session.create('PHONE_REPLAY_READ', seed);
  assert.doesNotMatch(JSON.stringify(replayed.deriveMessages()), /A03_PHONE_SELECTED|phone-z|phone-a/);
  const { agent: restored } = await f.createAgent('PHONE_RESTORED', { seed });
  fail(() => f.prepare(restored, 'reuse-history'), 'memory-context-stale');
  await f.send(restored, 'plain-replay');
  assert.doesNotMatch(JSON.stringify(f.requests.at(-1).body.messages), /A03_PHONE_SELECTED/);
  // Only token pricing is controlled. The maintained Session surface, actual
  // compactor, summary channel and provider serialization remain pinned code.
  f.ctx.provide('tokenMeter', {
    measure(session) { const nodes = session.surface.nodes.map(seq => ({ seq, tokens: 1024, heuristicTokens: 1024 }));
      return { nodes, totalTokens: nodes.length * 1024 }; },
    estimateMessage: () => 1,
  });
  const { BasicCompactionEngine } = await f.engine.load('dsh-compaction-basic');
  const compaction = new BasicCompactionEngine(f.ctx, { auto: false, thresholdRatio: 0.1,
    headroomTokens: 1, retainTokens: 0, maxTokens: 128 });
  const before = f.requests.length;
  assert(await compaction.compactNow(agent, new AbortController().signal));
  assert.equal(f.requests.length, before + 1);
  assert.doesNotMatch(JSON.stringify(f.requests.at(-1).body.messages), /A03_PHONE_SELECTED/);
  assert.doesNotMatch(JSON.stringify(f.events(agent.session)), /A03_PHONE_SELECTED/);
});
