// Owner-run gate: real patched Session/Inbox/AgentLoop/AsyncLocal/LlmRuntime
// and direct adapter. Only the model HTTP peer returns synthetic SSE.
import assert from 'node:assert/strict';
import test from 'node:test';
import { createFixture, textResponse, sseResponse } from './fixtures/companion-recall-engine.mjs';

const integration = (name, run) => test(name, {
  skip: !process.env.DSH_PREFIX && 'NOT_RUN: set DSH_PREFIX to the complete pinned runtime including companion-chat-usage-receipts.diff',
  concurrency: false, timeout: 15000,
}, run);
async function fixture(t, options) {
  const f = await createFixture(options); t.after(() => f.dispose());
  assert.equal(f.ctx.llm.dshGoCompanionChatUsage, true, 'actual runtime hook required');
  const { agent } = await f.createAgent('CHAT_USAGE_SESSION');
  const instanceId = f.promptContext.info(agent).instanceId;
  const prepare = requestId => f.promptContext.prepare(agent, { v: 1, instanceId,
    sessionId: agent.id, requestId, events: [], phoneMemory: { archiveId: 'PHONE_ARCHIVE', controlRevision: 0,
      historyAfterSeq: 0, block: '{"type":"companion_memory","version":2,"scope":"real","items":[]}' } });
  const send = async (requestId, text = 'SYNTHETIC_ORIGINAL_HUMAN') => {
    agent.followup(f.engine.llm.createUserMessage({ source: { kind: 'user', rpcId: requestId }, content: [{ type: 'text', text }] }));
    await agent.whenIdle();
  };
  const snapshot = requestId => f.promptContext.usageSnapshot({ instanceId, sessionId: agent.id, requestId });
  return { ...f, agent, prepare, send, snapshot };
}

integration('actual full-engine ordinary turn closes one physical receipt without writing accounting metadata or phone context into Session', async t => {
  const f = await fixture(t); assert.equal(f.prepare('phone').chatUsage, true);
  await f.send('phone'); const result = f.snapshot('phone');
  assert.equal(f.requests.length, 1); assert.equal(result.state, 'settled'); assert.equal(result.complete, true);
  assert.equal(result.observedAdapterCalls, 1); assert.equal(result.physicalRequests, 1);
  const receipt = result.receipts[0]; assert.equal(receipt.observation, 'fetch-invoked');
  assert.deepEqual(receipt.usage.start_usage, { input_tokens: 5, output_tokens: 0 });
  assert.deepEqual(receipt.usage.final_usage, { output_tokens: 3 });
  assert.equal(receipt.usage.input_uncached, null); assert.equal(receipt.usage.output_tokens, 3);
  const events = f.agent.session.snapshotEvents(f.engine.session.SessionLogOffset(0));
  assert.deepEqual(events.find(event => event.type === 'user/message').data.content,
    [{ type: 'text', text: 'SYNTHETIC_ORIGINAL_HUMAN' }]);
  assert(!JSON.stringify(events).includes(receipt.receiptId)); assert(!JSON.stringify(events).includes('PHONE_ARCHIVE'));
  const original = JSON.stringify(result);
  await f.send('without-prepared-sidecar'); assert.equal(f.requests.length, 2);
  assert.equal(JSON.stringify(f.snapshot('phone')), original, 'a later human does not retroactively charge the old root');
  assert.equal(f.snapshot('without-prepared-sidecar').state, 'unknown');
});

integration('actual ReactLoop retry and tool continuation remain enabled and produce three separate physical receipts', async t => {
  const toolReply = () => sseResponse([
    { type: 'message_start', message: { usage: { input_tokens: 5, output_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 'synthetic-call', name: 'usage_probe', input: {} } },
    { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: '{}' } },
    { type: 'content_block_stop', index: 0 },
    { type: 'message_delta', delta: { stop_reason: 'tool_use' }, usage: { output_tokens: 3 } },
    { type: 'message_stop' },
  ]);
  const f = await fixture(t, { transport: (_request, count) => count === 1
    ? new Response(JSON.stringify({ error: { type: 'rate_limit_error', message: 'Synthetic retry' } }), { status: 429 })
    : count === 2 ? toolReply() : textResponse() });
  let executed = 0, retryDecisions = 0;
  f.ctx.tools.register({ name: 'usage_probe', description: 'Synthetic accounting test tool',
    parameters: { type: 'object', properties: {}, additionalProperties: false },
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    execute: async () => { executed++; return 'Synthetic tool result'; },
  });
  f.ctx.on('agent/request-error', (_event, next) => retryDecisions++ === 0 ? { kind: 'retry' } : next());
  f.prepare('retry-and-tool'); await f.send('retry-and-tool');
  const result = f.snapshot('retry-and-tool');
  assert.equal(executed, 1); assert.equal(retryDecisions, 1); assert.equal(f.requests.length, 3);
  assert.equal(result.complete, true); assert.equal(result.physicalRequests, 3); assert.equal(result.observedAdapterCalls, 3);
  assert.equal(new Set(result.receipts.map(r => r.receiptId)).size, 3);
  assert.equal(new Set(result.receipts.map(r => r.callId)).size, 3);
  assert.deepEqual(result.receipts.map(r => r.terminal), ['http_error', 'tool_calls', 'complete']);
  assert.equal(result.receipts[0].usage.final_usage, null); assert.equal(result.receipts[0].httpStatus, 429);
  assert(result.receipts.every(r => r.requestIds.includes('retry-and-tool')));
});
