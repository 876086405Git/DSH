// Production bridge state with synthetic Agent/Session boundaries. Actual
// pinned-loop, provider POST and Session log coverage is in the integration file.
import assert from 'node:assert/strict';
import test from 'node:test';
import { createCompanionPromptContext, validatePromptContext } from '../bridge/dsh-go-bridge/lib/companion/prompt-context.js';

const START = Date.UTC(2026, 10, 21);
const block = (items = [{ id: 'k2', kind: 'fact', text: 'PHONE_MEMORY_🐋' },
  { id: 'k1', kind: 'preference', text: '先听我说完' }]) => JSON.stringify({ type: 'companion_memory', version: 2, scope: 'real', items });
const phone = (extra = {}) => ({ archiveId: 'phone-archive', controlRevision: 0, historyAfterSeq: 0, block: block(), ...extra });
const body = (sessionId = 's', requestId = 'r', extra = {}) => ({
  v: 1, sessionId, requestId, instanceId: 'boot', events: [], phoneMemory: phone(), ...extra,
});
const human = (rpcId = 'r', extra = {}) => Object.freeze({ role: 'user', id: `m-${rpcId}`,
  source: Object.freeze({ kind: 'user', rpcId, ...extra }),
  content: Object.freeze([Object.freeze({ type: 'text', text: '  逐字用户原话\n' })]),
});
const request = (sessionId = 's', messages = [human()], extra = {}) => Object.freeze({
  provider: 'fixture', model: 'fixture', sessionId, messages: Object.freeze(messages), ...extra,
});
const fail = (fn, code) => assert.throws(fn, error => error.code === `companion/${code}`);
function fixture() {
  let clock = START;
  const agents = new Map();
  const runtime = { dshGoPhoneMemory: true };
  const service = createCompanionPromptContext({ instanceId: 'boot', now: () => clock,
    isCurrent: agent => agents.get(agent.id) === agent,
  });
  const agent = (id = 's', events = []) => {
    const value = { id, ctx: { get: name => name === 'llm' ? runtime : undefined },
      session: { id, header: { isSeeded: false }, inheritedEventCount: 0,
        seq: events.length, eventAt: seq => events[seq] },
    };
    agents.set(id, value);
    return value;
  };
  return { service, runtime, agents, agent, setTime: value => { clock = value; } };
}
function claim(f, actor, input = body(actor.id), turn = 1) {
  f.service.prepare(actor, input);
  f.service.claim(actor, human(input.requestId), turn);
  return f.service.forRequest(actor, request(actor.id, [human(input.requestId)]));
}

test('phone capability requires the real runtime hook; v1 and old memory modes stay compatible', () => {
  const f = fixture(), actor = f.agent();
  assert.equal(f.service.info(actor).phoneMemory, true);
  assert.equal(f.service.info(actor).v, 1);
  f.runtime.dshGoPhoneMemory = false;
  assert.equal(Object.hasOwn(f.service.info(actor), 'phoneMemory'), false);
  fail(() => f.service.prepare(actor, body()), 'phone-memory-unsupported');
  assert.equal(f.service.info(actor).memoryMode, 'query');
  f.runtime.dshGoPhoneMemory = true;
  assert.equal(f.service.prepare(actor, body()).memoryMode, 'phone');
});

test('phone JSON keeps exact bytes, ID order, literal markup and both Unicode limits', () => {
  const exact = '{ "type":"companion_memory", "version":2, "scope":"real", "items":' +
    '[{"id":"z","kind":"fact","text":"</companion_memory> {{literal}} & 🐋"},' +
    '{"id":"a","kind":"episode","text":"原文"}] }';
  const value = validatePromptContext(body('s', 'r', { phoneMemory: phone({ block: exact }) }));
  assert.equal(value.phoneMemory.block, exact);
  const overhead = [...block([{ id: 'k', kind: 'fact', text: 'x' }])].length - 1;
  const full = block([{ id: 'k', kind: 'fact', text: '🐋'.repeat(1200 - overhead) }]);
  assert.equal([...full].length, 1200);
  validatePromptContext(body('s', 'limit', { phoneMemory: phone({ block: full }) }));
  fail(() => validatePromptContext(body('s', 'over', { phoneMemory: phone({ block: `${full} ` }) })), 'invalid-request');
  const f = fixture(), actor = f.agent();
  const output = claim(f, actor, body('s', 'r', { phoneMemory: phone({ block: exact }) }));
  assert.equal(output.messages[0].content.at(-1).text, exact);
});

test('invalid phone envelopes, malformed JSON and query coexistence are rejected', () => {
  for (const bad of [
    phone({ archiveId: '' }), phone({ controlRevision: -1 }), phone({ controlRevision: 1.5 }),
    phone({ historyAfterSeq: Number.MAX_SAFE_INTEGER + 1 }), phone({ block: '' }), phone({ block: '{' }),
    phone({ block: JSON.stringify({ type: 'companion_memory', version: 2, scope: 'story', items: [] }) }),
    phone({ block: JSON.stringify({ type: 'companion_memory', version: 1, scope: 'real', items: [] }) }),
    phone({ block: block([{ id: 'a', kind: 'fact', text: 'a', source: 'model' }]) }),
    phone({ block: block([{ id: 'a', kind: 'fact', text: '\ud800' }]) }),
    phone({ block: block([{ id: 'a', kind: 'fact', text: 'a' }, { id: 'a', kind: 'fact', text: 'b' }]) }),
    phone({ block: block(Array.from({ length: 13 }, (_, n) => ({ id: `${n}`, kind: 'fact', text: 'a' }))) }),
  ]) fail(() => validatePromptContext(body('s', 'r', { phoneMemory: bad })), 'invalid-request');
  fail(() => validatePromptContext(body('s', 'r', { query: 'host recall' })), 'invalid-request');
});

test('request copies preserve original human bytes and frozen history; render never contains the phone block', () => {
  const f = fixture(), actor = f.agent(), original = request();
  const before = JSON.stringify(original);
  f.service.prepare(actor, body()); f.service.claim(actor, human(), 1);
  const first = f.service.forRequest(actor, original), second = f.service.forRequest(actor, original);
  assert.notEqual(first, original); assert.notEqual(first.messages, original.messages);
  assert.equal(JSON.stringify(original), before);
  assert.equal(first.messages[0].content.length, 2);
  assert.equal(second.messages[0].content.length, 2);
  assert.equal(first.messages[0].content[0], original.messages[0].content[0]);
  assert(Object.isFrozen(first)); assert(Object.isFrozen(first.messages));
  assert(Object.isFrozen(first.messages[0])); assert(Object.isFrozen(first.messages[0].content));
  assert.equal(f.service.render(actor), '');
  assert.doesNotMatch(JSON.stringify(actor.session), /PHONE_MEMORY/);
  assert.doesNotThrow(() => f.service.guardRequest(actor, first));
});

test('empty selection produces zero memory blocks and never falls back to a preceding selection', () => {
  const f = fixture(), actor = f.agent();
  const first = claim(f, actor);
  assert.equal(first.messages[0].content.length, 2);
  f.service.commit(actor.session, human(), START); f.service.end(actor.session);
  const empty = claim(f, actor, body('s', 'empty', { phoneMemory: phone({ block: block([]) }) }), 2);
  assert.equal(empty.messages[0].content.length, 1);
  assert.doesNotMatch(JSON.stringify(empty), /companion_memory|PHONE_MEMORY/);
  assert.equal(f.service.render(actor), '');
});

test('owner RPC identity, tool steps and same-turn steers define the current slot', () => {
  const f = fixture(), actor = f.agent();
  claim(f, actor);
  const runtime = { role: 'user', source: { kind: 'runtime-context' }, content: [{ type: 'text', text: 'tool context' }] };
  const tool = { role: 'tool', source: { kind: 'tool' }, content: [{ type: 'text', text: 'tool result' }] };
  const output = f.service.forRequest(actor, request('s', [human(), runtime, tool]));
  assert.equal(output.messages[0].content.length, 2);
  assert.equal(output.messages[1], runtime); assert.equal(output.messages[2], tool);
  assert.equal(f.service.forRequest(actor, request('s', [human('wrong')])).messages[0].content.length, 1);
  f.service.claim(actor, human('guest', { principal: { kind: 'guest' } }), 1);
  assert.equal(f.service.forRequest(actor, request()).messages[0].content.length, 2);
  f.service.claim(actor, human('plain'), 1);
  assert.equal(f.service.forRequest(actor, request('s', [human('plain')])).messages[0].content.length, 1);
  fail(() => f.service.guardRequest(actor, output), 'memory-context-stale');
});

test('same request ID accepts identical bytes but rejects different selection or control values', () => {
  const f = fixture(), actor = f.agent(), input = body();
  f.service.prepare(actor, input); f.service.prepare(actor, structuredClone(input));
  for (const change of [{ block: block([]) }, { controlRevision: 1 }, { historyAfterSeq: 2 }]) {
    fail(() => f.service.prepare(actor, body('s', 'r', { phoneMemory: phone(change) })), 'request-conflict');
  }
  f.service.claim(actor, human(), 1); f.service.commit(actor.session, human(), START); f.service.end(actor.session);
  f.service.prepare(actor, input); f.service.claim(actor, human(), 2);
  assert.equal(f.service.forRequest(actor, request()).messages[0].content.length, 1, 'a committed receipt is not a new lease');
});

test('expired retries cannot revive phone data; a fresh request can continue without it', () => {
  const f = fixture(), actor = f.agent();
  const output = claim(f, actor);
  f.setTime(START + 31 * 60000);
  fail(() => f.service.prepare(actor, body()), 'request-expired');
  fail(() => f.service.guardRequest(actor, output), 'memory-context-stale');
  const without = f.service.forRequest(actor, request());
  assert.equal(without.messages[0].content.length, 1);
  assert.doesNotThrow(() => f.service.guardRequest(actor, without));
});

test('legacy query, automatic recall, seeded and reopened history cannot be promoted to phone mode', () => {
  const f = fixture(), actor = f.agent('automatic');
  f.service.disableMemory(actor);
  fail(() => f.service.prepare(actor, body(actor.id)), 'memory-mode-conflict');
  const used = f.agent('used', [{ type: 'user/message', data: human(), time: START }]);
  fail(() => f.service.prepare(used, body(used.id)), 'memory-context-stale');
  const projected = f.agent('projected', [{ type: 'system/message', data: { text: 'OLD_QUERY' } }]);
  fail(() => f.service.prepare(projected, body(projected.id)), 'memory-context-stale');
  const seeded = f.agent('seeded'); seeded.session.header.isSeeded = true;
  fail(() => f.service.prepare(seeded, body(seeded.id)), 'memory-context-stale');
  const fresh = f.agent('fresh', [{ type: 'model/selection' }, { type: 'agent-preset/selected' }]);
  f.service.prepare(fresh, body(fresh.id));
  fail(() => f.service.disableMemory(fresh), 'memory-mode-conflict');
  fail(() => f.service.prepare(fresh, { ...body(fresh.id, 'query'), phoneMemory: undefined, query: 'host' }), 'invalid-request');
  const query = { ...body(fresh.id, 'old-query'), query: 'host' }; delete query.phoneMemory;
  fail(() => f.service.prepare(fresh, query), 'memory-mode-conflict');
  assert.equal(f.service.captureMemory(fresh).allowed, false);
});

test('phone adoption fences a legacy query already awaiting storage', () => {
  const f = fixture(), actor = f.agent();
  const ticket = f.service.captureMemory(actor);
  f.service.prepare(actor, body());
  const old = { ...body('s', 'query'), query: 'host' }; delete old.phoneMemory;
  fail(() => f.service.prepare(actor, old, [{ text: 'OLD_QUERY', expiresAt: null }], undefined, ticket), 'memory-mode-conflict');
  f.service.claim(actor, human(), 1);
  assert.doesNotMatch(f.service.render(actor), /OLD_QUERY|PHONE_MEMORY/);
});

test('higher control revision aborts all old archive requests and forces a new clean session', () => {
  const f = fixture(), a = f.agent('a'), b = f.agent('b'), clean = f.agent('new');
  const oldA = claim(f, a, body('a')), oldB = claim(f, b, body('b'));
  f.service.prepare(a, body('a', 'parked')); f.service.discard(a, human('parked'));
  const next = phone({ controlRevision: 1, historyAfterSeq: 10, block: block([]) });
  fail(() => f.service.prepare(a, body('a', 'control', { phoneMemory: next })), 'memory-context-stale');
  assert.equal(oldA.signal.aborted, true); assert.equal(oldB.signal.aborted, true);
  fail(() => f.service.guardRequest(a, oldA), 'memory-context-stale');
  fail(() => f.service.forRequest(b, request('b')), 'memory-context-stale');
  fail(() => f.service.prepare(b, body('b', 'old-again')), 'memory-context-stale');
  f.service.claim(a, human('parked'), 2);
  fail(() => f.service.forRequest(a, request('a', [human('parked')])), 'memory-context-stale');
  const fresh = claim(f, clean, body('new', 'fresh', { phoneMemory: next }));
  assert.equal(fresh.messages[0].content.length, 1);
  assert.equal(fresh.signal.aborted, false);
  fail(() => f.service.prepare(clean, body('new', 'same-rev-other-boundary', {
    phoneMemory: phone({ controlRevision: 1, historyAfterSeq: 11 }),
  })), 'memory-context-stale');
});

test('retired objects, replacements and bridge disposal cannot dispatch a captured phone request', () => {
  const f = fixture(), old = f.agent();
  const output = claim(f, old);
  const fresh = f.agent();
  f.service.info(fresh);
  assert.equal(output.signal.aborted, true, 'opening the replacement retires the old request signal');
  assert.equal(f.service.forRequest(fresh, request()).messages[0].content.length, 1);
  fail(() => f.service.guardRequest(old, output), 'memory-context-stale');
  f.service.retire(old);
  assert.equal(output.signal.aborted, true);
  fail(() => f.service.forRequest(old, request()), 'memory-context-stale');
  const newOutput = claim(f, fresh);
  f.service.clear();
  assert.equal(newOutput.signal.aborted, true);
  fail(() => f.service.forRequest(fresh, request()), 'memory-context-stale');
});

test('phone request cancellation inherits the real loop signal', () => {
  const f = fixture(), actor = f.agent(), abort = new AbortController();
  f.service.prepare(actor, body()); f.service.claim(actor, human(), 1);
  const output = f.service.forRequest(actor, request('s', [human()], { signal: abort.signal }));
  abort.abort(new Error('loop canceled'));
  assert.equal(output.signal.aborted, true);
  assert.throws(() => f.service.guardRequest(actor, output), /loop canceled/);
});
