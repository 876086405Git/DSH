// Actual fixed runner, Domain/JSON/FS and locked LlmRuntime/DeepSeek request path.
// Agent ownership/framework services and a synthetic loopback SSE peer are supplied.
// This is SOURCE_HTTP_IO, not a full engine boot or a model-semantic evaluation.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createServer} from 'node:http';
import {join} from 'node:path';
import {chatSourceFixture} from './fixtures/companion-chat-usage-source.mjs';
import {fixture, proposal, harness} from './fixtures/companion-notes-runner-fixture.mjs';
import {notesSystem, notesModelInput, notesInputEstimate, NOTES_LIMITS} from '../bridge/dsh-go-bridge/lib/companion/notes-content.js';

const modelRoot = join(harness, 'model-source');
const finalUsage = {output_tokens: 13, cache_read_input_tokens: 7, vendor_field: 'actual-cumulative-final'};
async function source(t, contextWindow = 64000) {
  const requests = [];
  const server = createServer(async (req, res) => {
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    requests.push({url: req.url, headers: req.headers, body: JSON.parse(Buffer.concat(chunks))});
    const events = [
      {type: 'message_start', message: {usage: {input_tokens: 17, cache_read_input_tokens: 3}}},
      {type: 'content_block_start', index: 0, content_block: {type: 'text', text: ''}},
      {type: 'content_block_delta', index: 0, delta: {type: 'text_delta', text: JSON.stringify(proposal)}},
      {type: 'content_block_stop', index: 0},
      {type: 'message_delta', delta: {stop_reason: 'end_turn'}, usage: finalUsage},
      {type: 'message_stop'},
    ];
    res.writeHead(200, {'content-type': 'text/event-stream'});
    res.end(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(''));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {server.closeAllConnections(); await new Promise(resolve => server.close(resolve));});
  const model = await chatSourceFixture(modelRoot, {lookupWindow: true, transport(url, init) {
    assert.equal(new URL(url).hostname, '127.0.0.1');
    return globalThis.fetch(url, init);
  }});
  t.after(() => model.dispose());
  model.connection.baseURL = `http://127.0.0.1:${server.address().port}/anthropic`;
  model.connection.models[0].contextWindow = contextWindow;
  const f = await fixture(t, {selected: model.config, llm: model.llm});
  const run = async () => {const runner = f.start(); await f.store.create(f.body); await runner.wake(f.body.taskId);};
  return {...f, model, requests, run};
}

test('SOURCE_HTTP_IO fixed notes reach the real selected adapter final body and retain raw cumulative receipt', async t => {
  const f = await source(t); await f.run();
  const snapshot = f.store.snapshot(f.body.taskId);
  assert.equal(snapshot.state, 'done'); assert.equal(f.requests.length, 1); assert.equal(f.counters.links, 1);
  const {body, url, headers} = f.requests[0];
  assert.equal(url, '/anthropic/v1/messages'); assert.equal(body.model, 'chosen-model');
  assert.equal(body.max_tokens, NOTES_LIMITS.outputTokens); assert.equal(body.stream, true);
  assert.deepEqual(body.thinking, {type: 'disabled'}); assert.equal(body.system, notesSystem);
  const inputs = f.store.read(f.body.taskId).notes['1'].inputs;
  assert.deepEqual(body.messages, [{role: 'user', content: [{type: 'text', text: notesModelInput(inputs)}]}]);
  assert(!Object.hasOwn(body, 'tools')); assert(!Object.hasOwn(body, 'tool_choice'));
  assert.equal(headers['x-deepseek-harness-session-id'], undefined);
  assert(!JSON.stringify(body).includes('SYNTHETIC_PHONE_HUMAN'));
  const completion = snapshot.steps.find(step => step.stepKey === 'model').result.completion;
  assert.deepEqual(completion.inputBudget, {...notesInputEstimate(JSON.stringify(body), 64000), boundary: 'provider-request'});
  assert.deepEqual(completion.usage.final_usage, finalUsage);
  assert.equal(completion.usage.start_usage.input_tokens, 17);
  assert.equal(completion.usage.input_uncached, null, 'final omission must not be filled from start usage');
  assert.equal(completion.usage.output_tokens, 13);
  assert.equal((await f.store.artifact(f.body.taskId, snapshot.artifacts[0].artifactId)).status, 'available');
});

test('SOURCE_HTTP_IO final serialized request enforces the same prepared window before any loopback dispatch', async t => {
  const input = notesModelInput({scope: {localDate: '2026-11-20', timeZone: 'UTC'},
    entries: [{name: 'one.md', text: '随手记录。\nTODO: 周五配镜\n'}]});
  const preliminary = JSON.stringify({system: notesSystem, messages: [{role: 'user', content: [{type: 'text', text: input}]}]});
  const window = notesInputEstimate(preliminary).estimatedTokens + NOTES_LIMITS.outputTokens;
  assert.equal(notesInputEstimate(preliminary, window).accepted, true);
  const f = await source(t, window); await f.run();
  const snapshot = f.store.snapshot(f.body.taskId);
  assert.equal(snapshot.state, 'waiting'); assert.equal(snapshot.waitReason, 'model_input_limit');
  assert.equal(f.requests.length, 0); assert.equal(f.model.requests.length, 0); assert.equal(f.counters.links, 0);
  const step = snapshot.steps.find(step => step.stepKey === 'model');
  assert.equal(step.result.completion.preflightDispatched, false);
  const observed = step.result.observations.find(event => event.type === 'model-finish');
  assert.equal(observed.dispatched, false); assert.equal(observed.inputBudget.accepted, false);
  assert.equal(observed.inputBudget.contextWindow, window); assert.equal(observed.inputBudget.boundary, 'provider-request');
  assert(observed.inputBudget.estimatedTokens > notesInputEstimate(preliminary).estimatedTokens);
  assert.equal(snapshot.artifacts.length, 0);
});
