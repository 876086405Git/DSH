// Real Cordis/LlmRuntime prepared dispatch. Only an owned module copy gains
// three lexical counters; native globals and the shared package stay unchanged.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { readFile, writeFile, mkdtemp, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import test, { after } from 'node:test';
assert(process.env.DSH_PREFIX, 'DSH_PREFIX must select the actual locked package view');
const prefix = resolve(process.env.DSH_PREFIX);
const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await load('cordis');
const { LlmRuntime, BlockAssembler } = await load('dsh-llm');
const original = await load('dsh-llm-pi-ai');
const source = await readFile(join(prefix, 'node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js'), 'utf8');
const sourceSha256 = createHash('sha256').update(source).digest('hex');
const dir = await mkdtemp(join(tmpdir(), 'dsh-text-preabort-'));
after(() => rm(dir, { recursive: true, force: true }));
await symlink(join(prefix, 'node_modules'), join(dir, 'node_modules'), 'dir');
const head = 'function textOnlyContext(options, supportsMidConvoSystemMessages, onReplayDegrade) {\n';
assert.equal(source.split(head).length, 2);
const begin = source.indexOf(head), end = source.indexOf('\n/**', begin);
let region = source.slice(begin, end);
function insertOnce(body, anchor, insertion) {
  assert.equal(body.split(anchor).length, 2, `one exact counter site: ${anchor}`);
  return body.replace(anchor, insertion + anchor);
}
region = insertOnce(region, '\tassertSupportedHistory(options.messages);\n', '\t__textProbe.contexts++;\n');
region = insertOnce(region, '\t\tmessages.push({\n\t\t\trole: "user",', '\t\t__textProbe.userMessages++;\n');
let instrumented = source.slice(0, begin) + region + source.slice(end);
const flatten = 'function flattenText(message) {\n';
assert.equal(instrumented.split(flatten).length, 2);
instrumented = instrumented.replace(flatten, flatten + '\t__textProbe.flattenCalls++;\n');
instrumented += '\nconst __textProbe = { contexts: 0, userMessages: 0, flattenCalls: 0 };\nexport function textProbe1292(reset = false) { const value = { ...__textProbe }; if (reset) { __textProbe.contexts = 0; __textProbe.userMessages = 0; __textProbe.flattenCalls = 0; } return value; }\n';
await writeFile(join(dir, 'subject.mjs'), instrumented);
const measured = await import(pathToFileURL(join(dir, 'subject.mjs')));
const empty = { contexts: 0, userMessages: 0, flattenCalls: 0 };
const identity = { sourceSha256, instrumentedSha256: createHash('sha256').update(instrumented).digest('hex') };

async function fixture(t, plugin, resolveCredential = async () => ({ value: 'synthetic-preabort-key' })) {
  const requests = [], credentialReads = [];
  const server = createServer(async (request, response) => {
    const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString('utf8'));
    requests.push({ path: request.url, authorization: request.headers.authorization, body });
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    for (const choice of [{ delta: { role: 'assistant', content: 'ok' }, finish_reason: null }, { delta: {}, finish_reason: 'stop' }]) {
      response.write(`data: ${JSON.stringify({ id: 'fixture', object: 'chat.completion.chunk', created: 1, model: 'fixture-model', choices: [{ index: 0, ...choice }] })}\n\n`);
    }
    response.end('data: [DONE]\n\n');
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => { server.closeAllConnections(); return new Promise(done => server.close(done)); });
  const ctx = new Context(); t.after(() => ctx.fiber.dispose());
  ctx.provide('credentials', { async resolve(name) { credentialReads.push(name); return resolveCredential(); } });
  await ctx.plugin(LlmRuntime).await();
  const route = 'private-preabort-fixture';
  await ctx.plugin(plugin, { providers: { [route]: { api: 'openai-completions', baseURL: `http://127.0.0.1:${server.address().port}/v1`, apiKeyEnv: 'SYNTHETIC_PREABORT_KEY', models: [{ id: 'fixture-model', name: 'Fixture Model' }] } } }).await();
  assert(ctx.llm.adapters.get(route).adapter instanceof plugin.PiAiAdapter);
  const controller = new AbortController();
  const prepared = await ctx.llm.prepareCall({ provider: route, model: 'fixture-model' }, controller.signal);
  assert.deepEqual(credentialReads, [], 'preparation has not resolved stream credentials');
  const options = { ...prepared.config, signal: controller.signal, tools: [], messages: Array.from({ length: 64 }, () => ({ role: 'user', content: [{ type: 'text', text: 'x'.repeat(1024) }] })) };
  return { ctx, requests, credentialReads, controller, prepared, options };
}
function aborted(chunks) {
  assert.equal(chunks.at(-1).reason.kind, 'aborted');
  assert.equal(chunks.at(-1).reason.failure.code, 'ABORTED');
  const assembler = new BlockAssembler();
  for (const chunk of chunks) assembler.push(chunk);
  assert.equal(assembler.finish.kind, 'aborted');
  assert.deepEqual(assembler.blocks(), []);
  // Missing usage is already legal for adapterFailureChunk; when present it
  // remains the zero-token SDK record. Raw chunk/message differences are logged.
  if (assembler.usage !== undefined) assert.equal(assembler.usage.totalTokens, 0);
}

test('prepared public call aborted before first consume skips actual text conversion', async t => {
  const f = await fixture(t, measured); measured.textProbe1292(true);
  f.controller.abort('pre-aborted after prepare');
  const chunks = await Array.fromAsync(f.prepared.stream(f.options));
  const counters = measured.textProbe1292();
  t.diagnostic(JSON.stringify({ ...identity, case: 'pre-abort', counters, requests: f.requests.length, credentialReads: f.credentialReads, chunks }));
  aborted(chunks); assert.equal(f.requests.length, 0);
  assert.deepEqual(f.credentialReads, ['SYNTHETIC_PREABORT_KEY'], 'existing credential ordering remains');
  assert.deepEqual(counters, empty);
});

test('uninstrumented public call retains aborted terminal without requiring a usage chunk', async t => {
  const f = await fixture(t, original); f.controller.abort('pre-aborted after prepare');
  const chunks = await Array.fromAsync(f.prepared.stream(f.options));
  t.diagnostic(JSON.stringify({ sourceSha256, case: 'uninstrumented pre-abort', requests: f.requests.length, chunks }));
  aborted(chunks); assert.equal(f.requests.length, 0);
});

test('normal prepared call preserves text, tool declaration and authentication payload', async t => {
  const f = await fixture(t, measured); measured.textProbe1292(true);
  f.options.tools = [{ name: 'fixture_tool', description: 'Fixture tool', parameters: { type: 'object', properties: {} } }];
  const chunks = await Array.fromAsync(f.prepared.stream(f.options));
  const counters = measured.textProbe1292();
  t.diagnostic(JSON.stringify({ ...identity, case: 'normal', counters, requests: f.requests.length, finish: chunks.at(-1) }));
  assert.equal(chunks.at(-1).reason.kind, 'stop'); assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].body.messages.length, 64);
  assert(f.requests[0].body.messages.every(value => value.content === 'x'.repeat(1024)));
  assert.equal(f.requests[0].body.tools[0].function.name, 'fixture_tool');
  assert.equal(f.requests[0].authorization, 'Bearer synthetic-preabort-key');
  assert.deepEqual(f.credentialReads, ['SYNTHETIC_PREABORT_KEY']);
  assert.deepEqual(counters, { contexts: 1, userMessages: 64, flattenCalls: 64 });
});

test('abort during the existing credential await skips the later text conversion', async t => {
  let entered, release;
  const reached = new Promise(done => { entered = done; });
  const held = new Promise(done => { release = done; });
  const f = await fixture(t, measured, async () => { entered(); await held; return { value: 'synthetic-preabort-key' }; });
  measured.textProbe1292(true);
  const consuming = Array.fromAsync(f.prepared.stream(f.options));
  await reached; f.controller.abort('abort while credentials wait'); release();
  const chunks = await consuming, counters = measured.textProbe1292();
  t.diagnostic(JSON.stringify({ ...identity, case: 'credential-await abort', counters, requests: f.requests.length, credentialReads: f.credentialReads, chunks }));
  aborted(chunks); assert.equal(f.requests.length, 0);
  assert.deepEqual(f.credentialReads, ['SYNTHETIC_PREABORT_KEY']);
  assert.deepEqual(counters, empty);
});

test('already aborted preparation remains rejected at the existing public boundary', async t => {
  const f = await fixture(t, measured); measured.textProbe1292(true);
  const reason = Error('already aborted preparation'); f.controller.abort(reason);
  await assert.rejects(f.ctx.llm.prepareCall({ provider: f.options.provider, model: f.options.model }, f.controller.signal), error => error === reason);
  assert.deepEqual(measured.textProbe1292(), empty);
  assert.deepEqual(f.credentialReads, []); assert.equal(f.requests.length, 0);
});
