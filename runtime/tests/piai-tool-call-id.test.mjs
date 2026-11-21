// Real pinned SDK, PiAiAdapter, AgentLoop and JSONL; only the HTTP peer is synthetic.
// DSH_PREFIX=<patched prefix> node --test runtime/tests/piai-tool-call-id.test.mjs
import assert from 'node:assert/strict';
import test from 'node:test';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
if (!prefix) throw Error('Set DSH_TEST_PREFIX or DSH_PREFIX to the patched 0.2.2-rc.1 prefix');
const load = name => import(pathToFileURL(join(resolve(prefix), 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await load('cordis');
const { createUserMessage } = await load('dsh-llm');
const { apply: applyPiAi } = await load('dsh-llm-pi-ai');
const { apply: applyPersistence } = await load('dsh-session-persistence-jsonl');
const route = { provider: 'tool-id-fixture', model: 'fixture-model' };
const declaration = { name: 'fixture_probe', description: 'Synthetic tool', parameters: { type: 'object', properties: {} } };

function chunk(delta, finish_reason = null) {
  return `data: ${JSON.stringify({ id: 'synthetic', object: 'chat.completion.chunk', created: 1,
    model: route.model, choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
}

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-piai-tool-id-'));
  const ctx = new Context(), forks = [], owners = [], responses = [], requests = [];
  let executions = 0;
  const server = createServer(async (request, response) => {
    requests.push(JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString('utf8')));
    const frames = responses.shift();
    if (!frames) { response.writeHead(500).end('Unexpected synthetic request'); return; }
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    response.end(frames.join('') + 'data: [DONE]\n\n');
  });
  t.after(async () => {
    try {
      for (const owner of owners) await owner.dispose();
      for (const fork of forks.reverse()) await fork.dispose();
      await ctx.fiber.dispose();
    } finally {
      server.closeAllConnections();
      await new Promise(done => server.close(done));
      await rm(root, { recursive: true, force: true });
    }
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  for (const name of ['dsh-session-projection', 'dsh-session', 'dsh-agent', 'dsh-llm', 'dsh-tools', 'dsh-system-prompt']) {
    const fork = ctx.plugin((await load(name)).default); forks.push(fork); await fork.await();
  }
  const native = ctx.plugin(await load('dsh-tool-executor-native')); forks.push(native); await native.await();
  await applyPersistence(ctx, { root, compression: 'none', listConcurrency: 1 });
  ctx.provide('credentials', { resolve: async () => ({ value: 'synthetic-not-a-credential' }) });
  const profiles = { [route.provider]: { api: 'openai-completions',
    baseURL: `http://127.0.0.1:${server.address().port}/v1`, apiKeyEnv: 'TOOL_ID_FIXTURE_KEY',
    models: [{ id: route.model }], streamIdleTimeoutMs: 5000 } };
  applyPiAi(ctx, { providers: { get: () => profiles } });
  ctx.tools.register({ ...declaration,
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    execute: async () => { executions++; return 'Synthetic tool completed'; },
  });
  const loop = ctx.plugin((await load('dsh-agent-loop')).AgentLoop, { agents: [] }); forks.push(loop); await loop.await();
  return {
    ctx, requests, owners, respond: frames => responses.push(frames), get executions() { return executions; },
    async read(id) {
      const reader = await ctx.sessionPersistence.open(id, 'read');
      try { return (await reader.read()).events; } finally { await reader.close(); }
    },
  };
}

// The reported provider sent a call with neither id nor name; a provider may also send an explicit empty id.
for (const [finish, fields, name, ran] of [['stop', { id: '' }, declaration.name, 1], ['tool_calls', {}, '', 0]]) {
  test(`a ${finish} tool call without an id gets a local id and the turn completes`, { timeout: 15000 }, async t => {
    const f = await fixture(t);
    const owner = await f.ctx.agents.create({ sessionId: `tool-id-${finish}`, agentOptions: route, meta: { cwd: tmpdir() } });
    f.owners.push(owner);
    const agent = owner.agent;
    f.respond([chunk({ role: 'assistant', tool_calls: [{ index: 0, type: 'function', ...fields, function: { name, arguments: '{}' } }] }), chunk({}, finish)]);
    f.respond([chunk({ role: 'assistant', content: 'Synthetic follow-up' }), chunk({}, 'stop')]);
    agent.followup(createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text: 'Synthetic turn' }] }));
    await agent.whenIdle();
    await f.ctx.sessions.flush(agent.session);

    assert.equal(f.executions, ran);
    assert.equal(f.requests.length, 2, 'the tool result went back to the provider');
    const call = f.requests[1].messages.find(message => message.tool_calls)?.tool_calls[0];
    const result = f.requests[1].messages.find(message => message.role === 'tool');
    assert.ok(call?.id, 'replayed call carries the local id');
    assert.equal(result?.tool_call_id, call.id);
    const messages = agent.session.snapshotEvents().filter(event => event.type === 'assistant/message');
    assert.deepEqual(messages.at(-1).data.message.content, [{ type: 'text', text: 'Synthetic follow-up' }]);
    assert.deepEqual(await f.read(agent.id), agent.session.snapshotEvents(), 'JSONL accepted the tool call and result');
  });
}
