import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createCompanionUsage } from '../bridge/dsh-go-bridge/lib/companion/usage.js';
import { createCompanionPromptContext } from '../bridge/dsh-go-bridge/lib/companion/prompt-context.js';
import { createCompanionRoutes } from '../bridge/dsh-go-bridge/lib/companion/routes.js';

function ledger(limits) {
  const owner = {}, usage = createCompanionUsage({ instanceId: 'boot', now: () => 100, limits });
  const prepare = (requestId = 'request', agent = owner) => usage.prepare(agent,
    { sessionId: 'session', requestId, archiveId: 'archive', controlRevision: 3, historyAfterSeq: 4 });
  const claim = (requestId = 'request', turn = 1) => usage.claim(owner, 'session', requestId, turn);
  const open = (ids = ['request'], turn = 1, observed = true) => usage.open(owner, 'session', ids, turn,
    { provider: 'provider', model: 'model' }, observed);
  const snapshot = (requestId = 'request', instanceId = 'boot') => usage.snapshot({ instanceId, sessionId: 'session', requestId });
  return { owner, usage, prepare, claim, open, snapshot };
}

test('root preparation alone or no observed calls never proves a model request was free', () => {
  const f = ledger(); assert(f.prepare());
  assert.equal(f.snapshot().state, 'pending'); assert.equal(f.snapshot().complete, false);
  f.claim(); f.usage.end(f.owner, 1);
  assert.equal(f.snapshot().state, 'settled'); assert.equal(f.snapshot().physicalRequests, null);
  assert.deepEqual(f.snapshot().gaps, ['no-call-observation']);
  for (const [request, instance, gap] of [['absent', 'boot', 'not-retained'], ['request', 'old', 'instance-changed']]) {
    const result = f.snapshot(request, instance);
    assert.equal(result.revision, 0); assert.equal(result.state, 'unknown'); assert.equal(result.complete, false);
    assert.equal(result.physicalRequests, null); assert.equal(result.binding, null); assert.deepEqual(result.gaps, [gap]);
    assert.deepEqual(result.receipts, []);
  }
});

test('same global receipt identity is shared between roots and physical close controls settlement', () => {
  const f = ledger(); f.prepare('one'); f.prepare('two'); f.claim('one'); f.claim('two');
  const call = f.open(['one', 'two']), physical = call.beginPhysical(121);
  physical.observe({ type: 'usage', event: 'message_start', raw: { input_tokens: 10 } });
  physical.observe({ type: 'usage', event: 'message_delta', raw: { output_tokens: 3 } });
  call.close(); f.usage.end(f.owner, 1);
  const active = f.snapshot('one'); assert.equal(active.state, 'running'); assert.equal(active.activeCalls, 1);
  assert.deepEqual(active.receipts, f.snapshot('two').receipts);
  physical.observe({ type: 'complete' }); physical.close({ kind: 'stop' });
  const result = f.snapshot('one'); assert.equal(result.state, 'settled'); assert.equal(result.complete, true);
  assert.equal(result.receipts[0].receiptId, active.receipts[0].receiptId);
  assert(result.receipts[0].revision > active.receipts[0].revision);
  const immutable = JSON.stringify(result);
  physical.observe({ type: 'usage', event: 'message_delta', raw: { output_tokens: 999 } }); physical.close(); call.close();
  assert.equal(JSON.stringify(f.snapshot('one')), immutable, 'finished physical receipts never change');
});

test('only the latest raw cumulative object supplies components and invalid or oversized finals cannot leave a stale final', () => {
  const f = ledger({ raw: 130 }); f.prepare(); f.claim(); const call = f.open(), physical = call.beginPhysical(100);
  physical.observe({ type: 'usage', event: 'message_start', raw: { input_tokens: 40 } });
  physical.observe({ type: 'usage', event: 'message_delta', raw: { input_tokens: 21, output_tokens: 7 } });
  assert.equal(f.snapshot().receipts[0].usage.input_uncached, 21);
  physical.observe({ type: 'usage', event: 'message_delta', raw: { output_tokens: 8 } });
  assert.equal(f.snapshot().receipts[0].usage.input_uncached, null);
  physical.observe({ type: 'usage', event: 'message_delta', raw: { output_tokens: 9, extra: 'x'.repeat(150) } });
  let result = f.snapshot(); assert.equal(result.receipts[0].usage.final_usage, null);
  assert.equal(result.receipts[0].usage.output_tokens, null); assert(result.gaps.includes('usage-capacity'));
  assert.equal(result.receipts[0].usage.start_usage.input_tokens, 40);
  physical.observe({ type: 'usage', event: 'message_delta', raw: { output_tokens: 10 } });
  physical.observe({ type: 'usage', event: 'message_delta', raw: ['invalid'] });
  result = f.snapshot(); assert.equal(result.receipts[0].usage.final_usage, null); assert(result.gaps.includes('invalid-usage'));
  physical.close(); call.close(); f.usage.end(f.owner, 1);
  assert.equal(f.snapshot().complete, false); assert.equal(f.snapshot().physicalRequests, null);
});

test('unknown normalized events remain separate and are never added together or converted to raw zeros', () => {
  const f = ledger(); f.prepare(); f.claim(); const call = f.open(['request'], 1, false);
  call.chunk({ type: 'usage', usage: { inputTokens: 8, outputTokens: 2 } });
  call.chunk({ type: 'usage', usage: { inputTokens: 9, outputTokens: 3 } });
  call.chunk({ type: 'finish', reason: { kind: 'stop' } }); call.close(); f.usage.end(f.owner, 1);
  const result = f.snapshot(), receipt = result.receipts[0];
  assert.equal(result.state, 'settled'); assert.equal(result.complete, false); assert.equal(result.physicalRequests, null);
  assert.equal(receipt.dispatched, null); assert.equal(receipt.physicalRequests, null); assert.equal(receipt.dispatchAtMs, null);
  assert.equal(receipt.usage.input_uncached, null); assert.equal(receipt.usage.output_tokens, null);
  assert.deepEqual(receipt.usage.runtime_normalized_usage, [{ inputTokens: 8, outputTokens: 2 }, { inputTokens: 9, outputTokens: 3 }]);
});

test('retirement retains late evidence for its original binding and does not erase already closed coverage', () => {
  const f = ledger(); f.prepare(); f.claim(); const call = f.open(), physical = call.beginPhysical(123);
  f.usage.retire(f.owner);
  physical.observe({ type: 'usage', event: 'message_delta', raw: { output_tokens: 31 } });
  physical.close(undefined, { code: 'ABORTED', message: 'NEVER_KEEP_THIS' }, true); call.close(undefined, true);
  const result = f.snapshot(); assert.equal(result.binding.archiveId, 'archive'); assert.equal(result.state, 'settled');
  assert.equal(result.receipts[0].usage.output_tokens, 31); assert(result.gaps.includes('session-retired'));
  assert(!JSON.stringify(result).includes('NEVER_KEEP_THIS'));
  const g = ledger(); g.prepare(); g.claim(); const next = g.open(); next.close({ code: 'MISSING_CREDENTIAL' });
  g.usage.end(g.owner, 1); const before = g.snapshot(); assert.equal(before.complete, true);
  g.usage.retire(g.owner); assert.deepEqual(g.snapshot(), before, 'retiring a completed turn creates no accounting gap');
});

test('root or receipt capacity never evicts unfinished work and explicitly marks missing coverage', () => {
  const f = ledger({ roots: 1, receipts: 1 }); f.prepare(); f.claim(); const call = f.open(), physical = call.beginPhysical(100);
  assert.equal(f.prepare('second'), false); assert.equal(f.snapshot('second').state, 'unknown');
  const secondPhysical = call.beginPhysical(101); secondPhysical.close();
  assert.deepEqual(f.snapshot().gaps, ['capacity']); assert.equal(f.snapshot().receipts.length, 1);
  physical.close(); call.close(); f.usage.end(f.owner, 1);
  assert.equal(f.prepare('second'), true, 'closed records may now be evicted');
  assert.equal(f.snapshot().state, 'unknown'); assert.deepEqual(f.snapshot().gaps, ['not-retained']);
});

test('an owner collision cannot relabel old receipts and disposal is an explicit unknown response', () => {
  const f = ledger(); f.prepare(); f.claim(); const call = f.open(); call.close({ code: 'MISSING_CREDENTIAL' }); f.usage.end(f.owner, 1);
  assert.equal(f.prepare('request', {}), false); assert(f.snapshot().gaps.includes('binding-conflict'));
  assert.equal(f.usage.open({}, 'session', ['request'], 1, { provider: 'other', model: 'other' }, true), undefined);
  f.usage.dispose(); const result = f.snapshot(); assert.equal(result.state, 'unknown');
  assert.equal(result.physicalRequests, null); assert.deepEqual(result.gaps, ['instance-disposed']);
});

async function httpFixture(t) {
  const runtime = { dshGoPhoneMemory: true, dshGoCompanionChatUsage: true };
  const agent = { id: 'session', ctx: { get: name => name === 'llm' ? runtime : undefined },
    session: { id: 'session', seq: 0, header: { isSeeded: false }, inheritedEventCount: 0,
      eventAt() { throw new Error('empty synthetic Session must not read history'); } } };
  const context = createCompanionPromptContext({ now: () => 100, instanceId: 'boot' });
  const route = createCompanionRoutes({ promptContext: context, ctx: { get(name) {
    assert.equal(name, 'connection', 'usage reads must not resolve or start an Agent');
    return { admit(req) { return req.headers.authorization === 'owner' ? { peer: { principal: { kind: 'owner' } } } :
      req.headers.authorization === 'reader' ? { peer: { principal: { kind: 'reader' } } } : { rejection: 401 }; } };
  } }, send(res, status, body) { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); } });
  const server = createServer((req, res) => { void route.handle(req, res, new URL(req.url, 'http://local').pathname); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { context.clear(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const request = async ({ auth = 'owner', method = 'GET', query = 'instanceId=boot&sessionId=session&requestId=request' } = {}) => {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/dsh-go/v1/companion/usage?${query}`,
      { method, headers: { authorization: auth } });
    return { status: response.status, body: await response.json() };
  };
  const prepare = () => context.prepare(agent, { v: 1, instanceId: 'boot', sessionId: 'session', requestId: 'request', events: [],
    phoneMemory: { archiveId: 'archive', controlRevision: 0, historyAfterSeq: 0,
      block: '{"type":"companion_memory","version":2,"scope":"real","items":[]}' } });
  return { agent, runtime, context, request, prepare };
}

test('actual owner GET rejects reader, anonymous, malformed identity, duplicates, extra keys and non-GET without opening a Session', async t => {
  const f = await httpFixture(t);
  for (const [auth, expected] of [['reader', 403], ['anonymous', 401]]) {
    const result = await f.request({ auth }); assert.equal(result.status, expected);
    assert.equal(result.body.error.code, 'companion/usage-forbidden');
  }
  for (const query of ['instanceId=boot&sessionId=session',
    'instanceId=boot&sessionId=session&requestId=request&requestId=request',
    'instanceId=boot&sessionId=session&requestId=request&extra=1',
    'instanceId=boot&sessionId=session&requestId=']) {
    const result = await f.request({ query }); assert.equal(result.status, 400);
    assert.equal(result.body.error.code, 'companion/usage-invalid-request');
  }
  assert.equal((await f.request({ method: 'POST' })).status, 405);
});

test('actual GET returns original closed receipts after retirement and explicit cross-instance unknown, with no agent lookup', async t => {
  const f = await httpFixture(t); assert.equal(f.prepare().chatUsage, true);
  const human = { role: 'user', source: { kind: 'user', rpcId: 'request' }, content: [{ type: 'text', text: 'NEVER_IN_USAGE' }] };
  f.context.claim(f.agent, human, 4);
  const request = f.context.forRequest(f.agent, { sessionId: 'session', provider: 'provider', model: 'model', messages: [human] });
  const call = f.context.observeUsageRequest(f.agent, request, true), physical = call.beginPhysical(123);
  physical.observe({ type: 'usage', event: 'message_delta', raw: { output_tokens: 12, extra: true } });
  physical.observe({ type: 'complete' }); physical.close({ kind: 'stop' }); call.close(); f.context.end(f.agent.session);
  f.context.retire(f.agent);
  const result = await f.request(); assert.equal(result.status, 200); assert.equal(result.body.complete, true);
  assert.equal(result.body.binding.archiveId, 'archive'); assert.equal(result.body.receipts[0].usage.final_usage.extra, true);
  assert(!JSON.stringify(result).includes('NEVER_IN_USAGE'));
  const old = await f.request({ query: 'instanceId=old&sessionId=session&requestId=request' });
  assert.equal(old.status, 200); assert.equal(old.body.instanceId, 'boot'); assert.equal(old.body.revision, 0);
  assert.equal(old.body.state, 'unknown'); assert.deepEqual(old.body.gaps, ['instance-changed']);
  assert.equal(old.body.physicalRequests, null); assert.deepEqual(old.body.receipts, []);
});

test('chatUsage is only advertised with the installed runtime hook', async t => {
  const f = await httpFixture(t); f.runtime.dshGoCompanionChatUsage = false;
  assert.equal(f.context.info(f.agent).chatUsage, undefined);
  assert.equal(f.prepare().chatUsage, undefined);
  assert.equal((await f.request()).body.state, 'unknown');
});
