// Real pinned AgentLoop, skill registry/tool, request projection, and auxiliary LlmRuntime.
// Native persistence/physical actions are the explicit RPC boundary of this test.
import test from 'node:test';
import assert from 'node:assert/strict';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { attachPhoneSkills, inject, guestPhoneNames, selectSkills, nativeBridge } from
  '../../app/android/app/src/main/assets/phone/skills.mjs';
import { createPaths } from '../direct/paths.mjs';

if (!process.env.DSH_PREFIX) throw new Error('Set DSH_PREFIX to the prepared patched runtime');
const base = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
const load = name => import(pathToFileURL(join(base, name, 'lib/index.js')));
const { Context } = await load('cordis');
const { LlmAdapter, createUserMessage } = await load('dsh-llm');
const { renderSkillContent } = await load('dsh-skill');
let sequence = 0;
const item = (name = 'phone-search', state = 'trial') => ({
  name, display: 'Find an item', description: 'Search for an item', whenToUse: 'When searching',
  apps: ['com.example.app'], state, fingerprint: 'b'.repeat(64), readFingerprint: 'a'.repeat(64), updatedAt: 1,
  body: '---\nname: ' + name + '\n---\n\n## Entry\nOpen the app.\n## Steps\nSearch and verify.\n',
});
const tool = (name, args = {}) => ({ type: 'tool-call', id: 'call-' + ++sequence,
  name, arguments: JSON.stringify(args) });
async function until(check) {
  for (let i = 0; i < 1000; i++) { if (check()) return; await delay(5); }
  assert.fail('Timed out waiting for the integration boundary');
}

async function fixture(t, { script = [], skills = [item()], nativeFailure, restricted = false,
  quarantine = [], beforeRequest, suppress = false, guestRoot, mountLate = false, beforeAux,
  auxiliary = 'delta', replaceAdapter = false } = {}) {
  const ctx = new Context(), requests = [], calls = [], actions = [], events = [];
  t.after(() => ctx.fiber.dispose());
  for (const name of ['dsh-session', 'dsh-session-projection', 'dsh-agent', 'dsh-llm',
    'dsh-tools', 'dsh-system-prompt', 'dsh-skill'])
    await ctx.plugin((await load(name)).default);
  ctx.provide('workingDirectory', { ensure: async () => '/tmp' });
  await ctx.plugin(await load('dsh-tool-executor-native'));
  await ctx.plugin(await load('dsh-tool-skill'));
  await ctx.plugin((await load('dsh-agent-loop')).AgentLoop, { agents: [] });
  if (suppress) ctx.systemPrompt.suppressRuntimeContext();
  for (const name of ['mcp__phone__screen', 'mcp__phone__tap']) ctx.tools.register({
    name, description: 'Synthetic phone action', parameters: { type: 'object', properties: {} },
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute() { actions.push(calls.filter(call => call.op === 'read').length); return 'accepted'; },
  });
  class Adapter extends LlmAdapter {
    async *stream(options) {
      requests.push(options);
      const main = options.sessionId !== undefined;
      if (!main) {
        await beforeAux?.(options);
        if (auxiliary === 'tool') yield { type: 'block-end', index: 0, block: tool('invented') };
        else {
          if (auxiliary !== 'block') yield { type: 'text-delta', index: 0, text: 'SKIP' };
          yield { type: 'block-end', index: 0, block: { type: 'text', text: 'SKIP' } };
        }
        yield { type: 'finish', reason: { kind: 'stop' } };
        return;
      }
      const index = requests.filter(request => request.sessionId !== undefined).length - 1;
      if (replaceAdapter && index === 0) registration.replace(['actual-provider', 'other-provider'], new Adapter());
      await beforeRequest?.(index, ctx, options);
      const blocks = script[index] ?? [{ type: 'text', text: 'Finished.' }];
      for (let i = 0; i < blocks.length; i++) yield { type: 'block-end', index: i, block: blocks[i] };
      yield { type: 'finish', reason: { kind: 'stop' } };
    }
  }
  const registration = ctx.llm.registerAdapter(['actual-provider', 'other-provider'], new Adapter());
  const bridge = {
    async call(params) {
      calls.push(params);
      if (nativeFailure === params.op) throw new Error('synthetic-private-path-must-not-be-logged');
      switch (params.op) {
        case 'catalog': return { control: true, learn: true, skills, quarantined: quarantine };
        case 'get': return skills.find(skill => skill.name === params.name);
        case 'read': return {};
        case 'finish': return params.draft ? { ticket: 'ticket', prompt: 'FIXED_SAFE_ABSTRACT_TRACE' } : {};
        case 'offer': return {};
        default: assert.fail('Unexpected native operation');
      }
    },
    close() {},
  };
  const mount = () => ctx.plugin({ name: 'test-phone-skills', inject,
    apply: context => attachPhoneSkills(context, bridge, renderSkillContent,
      () => guestRoot ? guestPhoneNames(guestRoot) : Promise.resolve([])) });
  if (!mountLate) await mount();
  ctx.on('session/event', (_session, event) => events.push(event));
  const handle = await ctx.agents.create({ sessionId: 'phone-skills-' + ++sequence,
    agentOptions: { provider: 'actual-provider', model: 'actual-model' } });
  const { agent } = handle;
  if (mountLate) await mount();
  if (guestRoot) await ctx.plugin(await load('dsh-skill-filesystem'),
    { customSkillDirs: [guestRoot], includeDefaultRoots: false, watch: false });
  if (restricted) agent.ctx.tools.restrict({ allow: [] });
  const send = async text => {
    agent.followup(createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text }] }));
    await agent.whenIdle();
  };
  return { ctx, agent, calls, requests, actions, events, send, handle };
}

test('parallel skill read is not attributed until its complete result enters an actual later request', async t => {
  const f = await fixture(t, { script: [
    [tool('skill', { name: 'phone-search' }), tool('mcp__phone__tap')],
    [tool('mcp__phone__tap')],
  ] });
  await f.send('Original TASK words\nCase and newlines stay.');
  await until(() => f.calls.some(call => call.op === 'offer'));
  assert.deepEqual(f.actions, [0, 1]);
  assert.deepEqual(f.calls.find(call => call.op === 'read').reads,
    [{ name: 'phone-search', fingerprint: 'a'.repeat(64) }]);
  const auxiliary = f.requests.filter(request => request.sessionId === undefined);
  assert.equal(auxiliary.length, 1);
  assert.equal(auxiliary[0].provider, 'actual-provider');
  assert.equal(auxiliary[0].model, 'actual-model');
  assert.equal(auxiliary[0].tools, undefined);
  assert.equal(auxiliary[0].system, 'FIXED_SAFE_ABSTRACT_TRACE');
  assert.deepEqual(JSON.parse(auxiliary[0].messages[0].content[0].text),
    { goal: 'Original TASK words\nCase and newlines stay.', finalAnswer: 'Finished.' });
  assert(!JSON.stringify(f.calls).includes('Original TASK words'));
  assert.equal(f.calls.find(call => call.op === 'offer').response, 'SKIP');
  assert(!JSON.stringify(f.events).includes('FIXED_SAFE_ABSTRACT_TRACE'));
});

test('explicit slash reads can justify an action from the same model request', async t => {
  const f = await fixture(t, { script: [[tool('mcp__phone__tap')]] });
  await f.send('/phone-search');
  await until(() => f.calls.some(call => call.op === 'offer'));
  assert.deepEqual(f.actions, [1]);
  assert(f.requests[0].messages.some(message => message.source?.kind === 'skill-invocation'));
});

test('model catalog is capped at forty, native suspended and unreviewed entries shadow filesystem skills', async t => {
  const skills = Array.from({ length: 42 }, (_, i) =>
    item('phone-item-' + String.fromCharCode(97 + Math.floor(i / 26), 97 + i % 26)));
  skills.push(item('phone-suspended', 'suspended'));
  skills[41].state = 'active';
  skills[41].whenToUse = 'Unique topic';
  const f = await fixture(t, { skills, quarantine: ['phone-unreviewed'], suppress: true });
  await f.send('Unique topic');
  const listing = await f.ctx.skills.list({ scope: f.agent });
  assert.equal(listing.filter(skill => skill.invocation.modelInvocable).length, 40);
  assert.equal(listing.filter(skill => skill.invocation.userInvocable).length, 42);
  assert.equal(listing.find(skill => skill.name === 'phone-unreviewed').invocation.userInvocable, false);
  const contexts = f.requests[0].messages.filter(message => message.source?.kind === 'runtime-context');
  const index = contexts.flatMap(message => message.source.sections ?? [])
    .find(section => section.name === 'dsh-go:phone-skills').text;
  assert(index.includes('"display":"Find an item"'));
  assert(index.includes('"description":'));
  assert(index.indexOf(skills[41].name) < index.indexOf(skills[0].name));
  assert(!index.includes('phone-suspended'));
  assert(!index.includes('phone-unreviewed'));
});

test('no-phone scopes and unavailable native learning do not block ordinary conversations', async t => {
  for (const options of [{ restricted: true }, { nativeFailure: 'catalog' }]) {
    const f = await fixture(t, options);
    await f.send('Ordinary conversation');
    assert.equal(f.requests.length, 1);
    assert.equal(f.events.findLast(event => event.type === 'turn/end').data.reason.kind, 'completed');
    assert(!JSON.stringify(f.requests[0].messages).includes('Phone procedures approved by the user'));
  }
});

test('read witness transport failure does not suppress the original phone action', async t => {
  const f = await fixture(t, { script: [[tool('mcp__phone__tap')]], nativeFailure: 'read' });
  await f.send('/phone-search');
  await until(() => f.calls.some(call => call.op === 'finish'));
  assert.equal(f.actions.length, 1);
  assert.equal(f.calls.find(call => call.op === 'finish').observationComplete, false);
  assert.equal(f.requests.filter(request => request.sessionId === undefined).length, 0);
});

test('a task that actually changes model route skips drafting instead of using a later selected route', async t => {
  let agent;
  const f = await fixture(t, { script: [[tool('mcp__phone__tap')]],
    beforeRequest(index) { if (index === 0) agent.model.select({ provider: 'other-provider', model: 'other-model' }); },
  });
  agent = f.agent;
  await f.send('Change route after this action');
  await until(() => f.calls.some(call => call.op === 'finish'));
  assert.equal(f.calls.find(call => call.op === 'finish').draft, false);
  assert.equal(f.requests.filter(request => request.sessionId === undefined).length, 0);
});

test('same-named adapter replacement after a task request prevents auxiliary dispatch', async t => {
  const f = await fixture(t, { script: [[tool('mcp__phone__tap')]], replaceAdapter: true });
  await f.send('Use the phone');
  await until(() => f.calls.some(call => call.op === 'finish'));
  assert.equal(f.calls.find(call => call.op === 'finish').draft, false);
  assert.equal(f.requests.filter(request => request.sessionId === undefined).length, 0);
});

test('first native outage shadows actual filesystem definitions and hot-mounted agents initialize', async t => {
  const root = await mkdtemp(join(tmpdir(), 'phone-skill-files-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, 'phone-search'));
  await writeFile(join(root, 'phone-search/SKILL.md'),
    '---\nname: phone-search\ndescription: Unapproved filesystem body\n---\nNever execute this fixture.\n');
  const f = await fixture(t, { nativeFailure: 'catalog', guestRoot: root, mountLate: true });
  await f.send('Ordinary conversation');
  const skill = (await f.ctx.skills.list({ scope: f.agent })).find(skill => skill.name === 'phone-search');
  assert.equal(skill.provider, 'dsh-go-phone');
  assert.deepEqual(skill.invocation, { modelInvocable: false, userInvocable: false });
  assert(!JSON.stringify(f.requests[0].messages).includes('Unapproved filesystem body'));
});

test('Chinese task words select a relevant older procedure beyond the first forty', () => {
  const skills = Array.from({ length: 40 }, (_, index) => ({ ...item('phone-recent-' + index),
    display: '打开设置', description: '调节亮度', whenToUse: '屏幕', updatedAt: 100 + index }));
  skills.push({ ...item('phone-voice'), display: '微信发语音', description: '给联系人发送语音消息',
    whenToUse: '微信聊天', apps: ['com.tencent.mm'], updatedAt: 1 });
  assert(selectSkills(skills, '请在微信给同事发语音').some(skill => skill.name === 'phone-voice'));
});

test('auxiliary complete text blocks are accepted once and tool blocks are rejected', async t => {
  for (const auxiliary of ['block', 'tool']) {
    const f = await fixture(t, { script: [[tool('mcp__phone__tap')]], auxiliary });
    await f.send('Use the phone');
    await until(() => f.calls.some(call => call.op === 'offer'));
    assert.equal(f.calls.find(call => call.op === 'offer').response, auxiliary === 'block' ? 'SKIP' : null);
  }
});

test('disposing an agent cancels an earlier turn draft even after a later turn starts', async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  t.after(() => release.resolve());
  const f = await fixture(t, { script: [[tool('mcp__phone__tap')]],
    beforeAux: async () => { entered.resolve(); await release.promise; } });
  await f.send('First phone task');
  await entered.promise;
  await f.send('Second ordinary turn');
  await f.handle.dispose();
  release.resolve();
  await until(() => f.calls.some(call => call.op === 'offer'));
  assert.equal(f.calls.find(call => call.op === 'offer').response, null);
});

test('Direct paths and a later relay connection work without replaying a failed request', async t => {
  const root = await mkdtemp(join(tmpdir(), 'phone-skills-direct-'));
  const symbol = Symbol.for('dsh.go.direct'), before = globalThis[symbol];
  globalThis[symbol] = createPaths(root, []);
  t.after(async () => { if (before === undefined) delete globalThis[symbol]; else globalThis[symbol] = before;
    await rm(root, { recursive: true, force: true }); });
  await mkdir(join(root, 'opt/dsh-app/phone'), { recursive: true });
  await mkdir(join(root, 'var/lib/dsh-app/phone'), { recursive: true });
  await writeFile(join(root, 'opt/dsh-app/phone/relay.cjs'),
    "const fs=require('fs'),rl=require('readline');" +
    "if(JSON.parse(fs.readFileSync(process.argv[2])).fail)process.exit(2);" +
    "rl.createInterface({input:process.stdin}).on('line',l=>{const q=JSON.parse(l);" +
    "process.stdout.write(JSON.stringify({id:q.id,result:{operation:q.params.op}})+'\\n')});");
  const config = join(root, 'var/lib/dsh-app/phone/bridge.json');
  await writeFile(config, JSON.stringify({ fail: true }));
  const bridge = nativeBridge();
  t.after(() => bridge.close());
  await assert.rejects(bridge.call({ op: 'catalog' }), /PHONE_SKILLS_UNAVAILABLE/);
  await writeFile(config, JSON.stringify({ fail: false }));
  assert.deepEqual(await bridge.call({ op: 'get' }), { operation: 'get' });
});
