// Exercise the actual patched service/tool bodies over memory-only seams.
// DSH_PREFIX=<isolated patched prefix> node --test runtime/tests/schedule-authorization.test.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { registerHooks } from 'node:module';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';

const prefix = process.env.DSH_PREFIX;
if (!prefix) throw Error('Set DSH_PREFIX to an isolated patched candidate, not a live Host');
const modulePath = join(resolve(prefix), 'node_modules/@deepseek-ai/dsh-schedule/lib/index.js');
const source = await readFile(modulePath, 'utf8');
assert.match(source, /dshGoAuthorize\(task, actorSessionId, "create", signal\)/);
const { ScheduleService, createAfterScheduleRecord } = await import(pathToFileURL(modulePath));
const { apply: applyTools } = await import(pathToFileURL(join(resolve(prefix), 'node_modules/@deepseek-ai/dsh-tool-schedule/lib/index.js')));
const approveLabel = '\u6388\u6743 / Authorize';
const signal = () => new AbortController().signal;
const required = error => error.code === 'schedule-authorization-required';
const delay = () => new Promise(resolve => setImmediate(resolve));
const granted = request => ({ answers: [{ id: request.questions[0].id, selected: [approveLabel] }] });
const details = request => JSON.parse(request.questions[0].question.split('\n\n').at(-1));
const createRequest = () => ({ title: 'Synthetic task', prompt: 'Harmless synthetic instructions', timing: { kind: 'after', after_seconds: 86400 }, target: { kind: 'session', sessionId: 'synthetic-session' } });

function fixture({ answer = granted, provider = true, resolveError = false, delegated = false, host = false } = {}) {
  const rows = new Map();
  const requests = [];
  const writes = [];
  const controls = [];
  const agent = { id: 'synthetic-session', options: {}, session: { id: 'synthetic-session', header: { delegationDepth: delegated ? 1 : 0 } } };
  let inMutation = false;
  const questions = { async ask(request) {
    assert.equal(inMutation, false, 'human interaction must not hold the mutation/deletion queue');
    assert.equal(request.agent, host ? undefined : agent);
    requests.push(request);
    return answer(request);
  } };
  const table = {
    get: id => rows.get(id),
    entries: () => rows.entries(),
    async put(id, value) { rows.set(id, structuredClone(value)); writes.push({ id, value: structuredClone(value) }); },
    async delete(id) { rows.delete(id); },
  };
  const ctx = {
    get: name => name === 'userQuestions' && provider ? questions : name === 'sessionController' ? {} : undefined,
    agents: new Map(resolveError ? [] : [[agent.id, agent]]),
    sessionController: { async resolveAgent(id) {
      assert.equal(id, agent.id);
      controls.push('resolve');
      return resolveError ? { error: Error('Synthetic missing session') } : { agent };
    } },
    sessionPersistence: { stat: async () => ({ header: { delegationDepth: 0 } }), dshGoDeletion: {
      assertAdmit() {},
      async withMutation(work) { assert.equal(inMutation, false); inMutation = true; try { return await work(); } finally { inMutation = false; } },
    } },
    approval: { request() { throw Error('Generic approval must not be used'); }, effectivePolicy: () => 'never' },
  };
  const service = Object.create(ScheduleService.prototype);
  Object.defineProperty(service, 'ctx', { value: ctx });
  Object.assign(service, {
    limits: { newSessionIntervalMs: 60000 }, chain: Promise.resolve(), stopping: false, dshGoAuthorizationAbort: new AbortController(),
    resolveWebAgent: async () => { if (resolveError) throw Object.assign(Error('Unavailable'), { code: 'schedule-authorization-required' }); return agent; },
    queueNotification: () => controls.push('notification'),
    getDomain: async () => ({ table(name) { assert.equal(name, 'tasks'); return table; } }),
    emitChanged: () => controls.push('changed'), runtime: { requestDrive: () => controls.push('drive'), deliveryFloorEnd() {}, isExecutionActive() { return false; } },
  });
  function seed() {
    const record = createAfterScheduleRecord('synthetic-task', 'Old synthetic instructions', 86400, Date.now(), 'Old name');
    rows.set(record.id, { target: { kind: 'session', sessionId: agent.id }, involvedSessionIds: [agent.id], record: structuredClone(record), status: 'active', deliveryHistory: { records: [], earlierRecordsUnavailable: false, earlierRecordsPruned: false } });
    return record;
  }
  return { service, rows, requests, writes, controls, seed, ctx, agent };
}

function pendingFixture(options = {}) {
  let accept;
  const waiting = new Promise(resolve => { accept = resolve; });
  const f = fixture({ ...options, answer: () => waiting });
  return { ...f, approve: (index = 0) => accept(granted(f.requests[index])), answer: accept };
}

for (const policy of ['ask', 'never', 'auto']) test(`create needs a separate answer even under ${policy}`, async () => {
  const f = pendingFixture();
  f.ctx.approval.effectivePolicy = () => policy;
  const creation = f.service.create(createRequest(), f.agent.id, signal());
  await delay();
  assert.equal(f.requests.length, 1);
  assert.equal(f.writes.length, 0);
  assert.equal(f.requests[0].purpose, 'schedule-authorization');
  assert.equal(f.requests[0].questions[0].multiSelect, false);
  assert.equal(details(f.requests[0]).operation, 'create');
  f.approve();
  const record = await creation;
  assert.equal(f.writes.length, 1);
  assert.deepEqual(f.rows.get(record.id), details(f.requests[0]).task, 'commit exactly the reviewed record and absolute time');
  assert.equal(f.requests[0].signal.aborted, true, 'settling withdraws the request lifetime');
});

for (const [name, answer] of [
  ['legacy automatic approval string', () => 'allowed-once'],
  ['no answer', () => undefined],
  ['empty answers', () => ({ answers: [] })],
  ['explicit rejection', request => ({ answers: [{ id: request.questions[0].id, selected: ['Reject'] }] })],
  ['typed consent', request => ({ answers: [{ id: request.questions[0].id, selected: [], custom: approveLabel }] })],
  ['mixed selection', request => ({ answers: [{ id: request.questions[0].id, selected: [approveLabel, 'Reject'] }] })],
  ['selection plus free text', request => ({ answers: [{ id: request.questions[0].id, selected: [approveLabel], custom: 'yes' }] })],
  ['wrong pending id', () => ({ answers: [{ id: 'old-pending', selected: [approveLabel] }] })],
  ['missing provider', null],
]) test(`${name} never creates a task`, async () => {
  const f = fixture({ answer: answer ?? granted, provider: answer !== null });
  await assert.rejects(f.service.create(createRequest(), f.agent.id, signal()), required);
  assert.equal(f.writes.length, 0);
});

for (const options of [
  { resolveError: true }, { delegated: true },
  { answer: () => { throw Error('Synthetic disconnected answerer'); } },
]) test(`unavailable routing fails closed: ${JSON.stringify(options)}`, async () => {
  const f = fixture(options);
  await assert.rejects(f.service.create(createRequest(), f.agent.id, signal()), error => required(error) || options.delegated && error.code === 'subagent_session');
  assert.equal(f.writes.length, 0);
});

test('untrusted formatting cannot hide fields, and changing caller input cannot change the approved task', async () => {
  const f = pendingFixture();
  const input = { ...createRequest(), prompt: 'Visible\u202einjected\u2066text' };
  const creation = f.service.create(input, f.agent.id, signal());
  await delay();
  input.prompt = 'Changed after review';
  const question = f.requests[0].questions[0].question;
  assert.equal(question.includes('\u202e'), false);
  assert.equal(question.includes('\\u202e'), true);
  assert.equal(question.includes('\\u2066'), true);
  f.approve();
  const record = await creation;
  assert.equal(record.prompt, 'Visible\u202einjected\u2066text');
});

for (const timing of [
  { after_seconds: 86400 },
  { at: '2099-12-30T23:00:00Z' },
  { every_seconds: 3600 },
  { daily: { time: '23:00:00', time_zone: 'Asia/Taipei' } },
  { weekly: { time: '23:00:00', time_zone: 'Asia/Taipei', weekdays: [1, 5] } },
  { cron: { expression: '0 23 * * *', time_zone: 'Asia/Taipei' } },
]) test(`review includes normalized timing ${Object.keys(timing)[0]}`, async () => {
  const f = fixture();
  const record = await f.service.create({ ...createRequest(), title: 'Synthetic', prompt: 'Harmless', timing: { kind: ({ after_seconds: 'after', every_seconds: 'every' })[Object.keys(timing)[0]] ?? Object.keys(timing)[0], ...timing } }, f.agent.id, signal());
  const reviewed = details(f.requests[0]);
  assert.equal(reviewed.sessionId, f.agent.id);
  assert.deepEqual(reviewed.task, f.rows.get(record.id));
  assert.equal(Number.isFinite(Date.parse(reviewed.task.record.scheduledAt)), true);
});

test('direct RPC-shaped update must review the entire merged candidate', async () => {
  const f = pendingFixture();
  const original = f.seed();
  const editing = f.service.edit({ id: original.id, action: 'update', patch: { prompt: 'New synthetic instructions' } }, f.agent.id, signal());
  await delay();
  assert.equal(f.writes.length, 0);
  const reviewed = details(f.requests[0]);
  assert.equal(reviewed.operation, 'update');
  assert.equal(reviewed.task.record.title, original.title);
  assert.equal(reviewed.task.record.scheduledAt, original.scheduledAt);
  assert.equal(reviewed.task.record.prompt, 'New synthetic instructions');
  f.approve();
  const result = await editing;
  assert.equal(result.id, original.id);
  assert.deepEqual(f.rows.get(original.id), reviewed.task);
});

test('denied update leaves the original task intact', async () => {
  const f = fixture({ answer: () => ({ answers: [] }) });
  const original = f.seed();
  await assert.rejects(f.service.edit({ id: original.id, action: 'update', patch: { title: 'New name' } }, f.agent.id, signal()), required);
  assert.deepEqual(f.rows.get(original.id).record, original);
  assert.equal(f.writes.length, 0);
});

for (const change of ['edited', 'deleted', 'ended']) test(`update rechecks state after review: ${change}`, async () => {
  const f = pendingFixture();
  const original = f.seed();
  const editing = f.service.edit({ id: original.id, action: 'update', patch: { prompt: 'New instructions' } }, f.agent.id, signal());
  await delay();
  if (change === 'deleted') {
    // Real delete must complete while an update's human question is still pending.
    assert.equal((await f.service.edit({ id: original.id, action: 'delete' }, f.agent.id, signal())).deleted, true);
  } else if (change === 'edited') {
    f.rows.get(original.id).record.title = 'Concurrent change';
  } else {
    f.rows.get(original.id).status = 'ended';
  }
  f.approve();
  const result = await editing;
  assert.equal(result.id, original.id);
  assert.equal(result.code, { edited: 'schedule_conflict', deleted: 'schedule_not_found', ended: 'schedule_conflict' }[change]);
  assert.equal(f.writes.length, 0);
});

test('empty and stale updates never ask or mutate', async () => {
  const f = fixture();
  const original = f.seed();
  await assert.rejects(f.service.edit({ id: original.id, action: 'update', patch: {} }, f.agent.id, signal()));
  const stale = await f.service.edit({ id: original.id, action: 'update', expectedUpdatedAt: 'stale', patch: { prompt: 'New' } }, f.agent.id, signal());
  assert.equal(stale.code, 'schedule_conflict');
  assert.equal(f.requests.length, 0);
  assert.equal(f.writes.length, 0);
});

for (const cancellation of ['caller', 'service']) test(`pending ${cancellation} cancellation prevents late authorization`, async () => {
  const f = pendingFixture();
  const caller = new AbortController();
  const creation = f.service.create(createRequest(), f.agent.id, caller.signal);
  await delay();
  if (cancellation === 'caller') caller.abort();
  else { f.service.stopping = true; f.service.dshGoAuthorizationAbort.abort(); }
  await assert.rejects(creation, required);
  f.approve();
  await delay();
  assert.equal(f.writes.length, 0);
  assert.equal(f.requests[0].signal.aborted, true);
});

test('unattended authorization times out and a late answer cannot commit', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const f = pendingFixture();
  const creation = f.service.create(createRequest(), f.agent.id, signal());
  await delay();
  t.mock.timers.tick(120000);
  await assert.rejects(creation, required);
  f.approve();
  await delay();
  assert.equal(f.writes.length, 0);
});

test('expired candidate is not silently re-anchored after confirmation', async t => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2030-01-01T00:00:00Z') });
  const f = pendingFixture();
  const creation = f.service.create({ ...createRequest(), timing: { kind: 'after', after_seconds: 2 } }, f.agent.id, signal());
  await delay();
  t.mock.timers.tick(3000);
  f.approve();
  await assert.rejects(creation, error => required(error) && /time has passed/.test(error.message));
  assert.equal(f.writes.length, 0);
});

test('a previous question answer cannot authorize a later task', async () => {
  let previous;
  const f = fixture({ answer: request => {
    const response = previous ?? granted(request);
    previous = response;
    return response;
  } });
  await f.service.create(createRequest(), f.agent.id, signal());
  await assert.rejects(f.service.create(createRequest(), f.agent.id, signal()), required);
  assert.equal(f.writes.length, 1);
  assert.notEqual(f.requests[0].questions[0].id, f.requests[1].questions[0].id);
});

test('service shutdown after authorization but before queued commit prevents mutation', async () => {
  const f = fixture();
  let release;
  f.service.chain = new Promise(resolve => { release = resolve; });
  const creation = f.service.create(createRequest(), f.agent.id, signal());
  await delay();
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].signal.aborted, true, 'human already answered');
  f.service.stopping = true;
  f.service.dshGoAuthorizationAbort.abort();
  release();
  await assert.rejects(creation);
  assert.equal(f.writes.length, 0);
});

test('tool boundary returns the stable authorization error instead of creating silently', async () => {
  const f = fixture({ provider: false });
  const definitions = new Map();
  const ctx = { systemPrompt: { section() {}, getSectionOrder() { return 0; } }, schedule: f.service, tools: { register(def) { definitions.set(def.name, def); } }, inject(_deps, callback) { callback(this); } };
  applyTools(ctx);
  const result = await definitions.get('schedule_create').execute({ title: 'Synthetic', prompt: 'Harmless', rrule: 'DTSTART:20991230T230000Z\nRRULE:FREQ=DAILY;COUNT=1', target: 'this_session' }, { agent: f.agent, signal: signal() });
  assert.equal(result.code, 'authorization_required');
  assert.equal(f.writes.length, 0);
});

for (const cancellation of ['caller', 'service', 'timeout']) test(`pending update ${cancellation} preserves the stored task and rejects late consent`, async t => {
  if (cancellation === 'timeout') t.mock.timers.enable({ apis: ['setTimeout'] });
  const f = pendingFixture();
  const original = f.seed();
  const caller = new AbortController();
  const editing = f.service.edit({ id: original.id, action: 'update', patch: { prompt: 'Changed instructions' } }, f.agent.id, caller.signal);
  await delay();
  assert.equal(f.requests.length, 1);
  if (cancellation === 'caller') caller.abort();
  else if (cancellation === 'service') {
    f.service.stopping = true;
    f.service.dshGoAuthorizationAbort.abort();
  } else t.mock.timers.tick(120000);
  await assert.rejects(editing, required);
  f.approve();
  await delay();
  assert.deepEqual(f.rows.get(original.id).record, original);
  assert.equal(f.writes.length, 0);
  assert.equal(f.requests[0].signal.aborted, true);
});

test('caller cancellation after authorization but before queued create prevents storage admission', async () => {
  const f = fixture();
  const caller = new AbortController();
  let release;
  f.service.chain = new Promise(resolve => { release = resolve; });
  const creation = f.service.create(createRequest(), f.agent.id, caller.signal);
  await delay();
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].signal.aborted, true, 'explicit consent has already settled');
  caller.abort();
  release();
  await assert.rejects(creation);
  assert.equal(f.writes.length, 0);
});

for (const kind of ['session', 'new_once', 'new']) {
  for (const allowed of [false, true]) test(`Agent create ${kind} requires explicit consent before any task write (${allowed})`, async () => {
    const f = fixture({ answer: allowed ? granted : () => ({ answers: [] }) });
    const target = kind === 'session' ? { kind, sessionId: f.agent.id } : { kind, create: { cwd: '/synthetic', agentPreset: 'synthetic-preset' } };
    const creation = f.service.create({ ...createRequest(), target }, f.agent.id, signal());
    if (!allowed) await assert.rejects(creation, required);
    else {
      const entry = await creation;
      assert.deepEqual(f.rows.get(entry.id), details(f.requests[0]).task);
      assert.equal(entry.target.kind, kind);
      if (kind !== 'session') assert.deepEqual(entry.target.create, target.create);
    }
    assert.equal(f.writes.length, allowed ? 1 : 0);
  });
}

test('Agent edit reviews retargeting, activation and instructions as one immutable candidate', async () => {
  const f = pendingFixture();
  const original = f.seed();
  const request = { id: original.id, action: 'update', patch: { target: { kind: 'new', create: { cwd: '/synthetic' } }, active: false, prompt: 'Reviewed text' } };
  const editing = f.service.edit(request, f.agent.id, signal());
  await delay();
  const reviewed = details(f.requests[0]).task;
  request.patch.target.create.cwd = '/changed-after-review';
  request.patch.prompt = 'Unreviewed text';
  assert.equal(reviewed.status, 'paused');
  assert.equal(reviewed.target.kind, 'new');
  f.approve();
  await editing;
  assert.deepEqual(f.rows.get(original.id), reviewed);
});

for (const target of [undefined, { kind: 'new_once' }, { kind: 'new' }]) test(`Remote create ${target?.kind ?? 'for a Session'} is the person's own action: saved, nothing asked`, async () => {
  const f = fixture({ host: true });
  await f.service.remoteCreate({ ...createRequest(), ...target && { target } }, signal());
  assert.equal(f.requests.length, 0);
  assert.equal(f.writes.length, 1);
});

test("Remote edit is the person's own action: saved, nothing asked", async () => {
  const f = fixture({ host: true });
  const created = await f.service.remoteCreate({ ...createRequest(), target: { kind: 'new_once' } }, signal());
  await f.service.remoteEdit({ id: created.id, action: 'update', patch: { title: 'New name' } }, signal());
  assert.equal(f.requests.length, 0);
  assert.equal(f.rows.get(created.id).record.title, 'New name');
});

test('Remote create is refused once the service is stopping', async () => {
  const f = fixture({ host: true });
  f.service.stopping = true;
  await assert.rejects(f.service.remoteCreate(createRequest(), signal()), required);
  assert.equal(f.writes.length, 0);
});

test('real UserQuestionService and api-remotes forward Session consent before a tool create commits', async t => {
  const load = name => import(pathToFileURL(join(resolve(prefix), 'node_modules/@deepseek-ai', name, 'lib/index.js')));
  const { Context } = await load('cordis');
  const { UserQuestionService } = await load('dsh-user-questions');
  const { apply: applyRemotes } = await load('dsh-api-remotes');
  const ctx = new Context();
  const f = fixture();
  f.agent.ctx = ctx;
  ctx.provide('agents', { get: id => id === f.agent.id ? f.agent : undefined, roots: () => [f.agent] });
  let eventSource;
  ctx.provide('typertGateway', { registerRemoteEvents(source) { eventSource = source; return () => {}; } });
  applyRemotes(ctx);
  const lifetime = new AbortController();
  const events = eventSource(lifetime.signal);
  t.after(async () => { lifetime.abort(); await events.return(); await ctx.fiber.dispose(); });
  const questions = Object.create(UserQuestionService.prototype);
  Object.defineProperty(questions, 'ctx', { value: ctx });
  const get = f.ctx.get;
  f.ctx.get = name => name === 'userQuestions' ? questions : get(name);
  for (const allowed of [false, true]) {
    const creating = f.service.create(createRequest(), f.agent.id, signal());
    const frame = (await events.next()).value;
    assert.equal(frame.event, 'user-questions/request');
    assert.equal(frame.context.agentId, f.agent.id);
    assert.equal(frame.request.purpose, 'schedule-authorization');
    assert.equal(f.writes.length, 0);
    frame.resolve({ kind: 'result', value: allowed ? granted(frame.request) : { answers: [] } });
    if (allowed) await creating;
    else await assert.rejects(creating, required);
  }
  assert.equal(f.writes.length, 1);
});


test('real no-answerer and explicit refusal stay distinct at the schedule tool boundary', async t => {
  const load = name => import(pathToFileURL(join(resolve(prefix), 'node_modules/@deepseek-ai', name, 'lib/index.js')));
  const { Context } = await load('cordis');
  const { UserQuestionService, UserQuestionError } = await load('dsh-user-questions');
  const ctx = new Context();
  t.after(() => ctx.fiber.dispose());
  const f = fixture();
  f.agent.ctx = ctx;
  ctx.provide('agents', { get: id => id === f.agent.id ? f.agent : undefined, roots: () => [f.agent] });
  const questions = Object.create(UserQuestionService.prototype);
  Object.defineProperty(questions, 'ctx', { value: ctx });
  const get = f.ctx.get;
  f.ctx.get = name => name === 'userQuestions' ? questions : get(name);
  const definitions = new Map();
  applyTools({ systemPrompt: { section() {}, getSectionOrder() { return 0; } }, schedule: f.service,
    tools: { register(def) { definitions.set(def.name, def); } }, inject(_deps, callback) { callback(this); } });
  const create = () => definitions.get('schedule_create').execute({ title: 'Synthetic', prompt: 'Harmless',
    rrule: 'DTSTART:20991230T230000Z\nRRULE:FREQ=DAILY;COUNT=1', target: 'this_session' }, { agent: f.agent, signal: signal() });
  const unavailable = await create();
  assert.equal(unavailable.code, 'authorization_unavailable');
  assert.match(unavailable.message, /解锁/);
  assert.equal(f.writes.length, 0);
  for (const answer of [
    request => ({ answers: [{ id: request.questions[0].id, selected: ['拒绝 / Reject'] }] }),
    () => { throw new UserQuestionError('The user declined to answer this question.', 'ASK_CANCELLED'); },
  ]) {
    const stop = ctx.on('user-questions/request', answer);
    try { assert.equal((await create()).code, 'authorization_rejected'); }
    finally { stop(); }
    assert.equal(f.writes.length, 0);
  }
  const stop = ctx.on('user-questions/request', granted);
  try { assert.ok((await create()).id); }
  finally { stop(); }
  assert.equal(f.writes.length, 1, 'a later explicitly authorized attempt still works');
});

test('empty schedule import defers record rules until the first parse', async t => {
  // The other tests already imported this file; use a fresh module instance.
  const file = new URL(pathToFileURL(modulePath));
  file.search = 'dsh-go-schedule-schema-on-demand';
  const counter = '__dshScheduleRecordBuildCount';
  globalThis[counter] = 0;
  let loadedCount = 0;
  const hooks = registerHooks({ load(url, context, next) {
    const loaded = next(url, context);
    if (url !== file.href) return loaded;
    loadedCount++;
    let source = Buffer.from(loaded.source).toString();
    const starts = source.match(/const recordSchema = z\$1\.unknown\(\)/g);
    assert.equal(starts?.length, 1, 'locate the first record rule constructor');
    source = source.replace(starts[0], 'const recordSchema = __countScheduleRecordRule()');
    source += `\nfunction __countScheduleRecordRule() { globalThis.${counter}++; return z$1.unknown(); }\n`;
    return { ...loaded, source };
  }});
  t.after(() => { hooks.deregister(); delete globalThis[counter]; });
  const { scheduleDomain, createAfterScheduleRecord } = await import(file.href);
  assert.equal(loadedCount, 1, 'instrument the fresh module, not a cached export');
  const schema = scheduleDomain.tables.tasks.valueSchema;
  assert.equal(globalThis[counter], 0, 'module import has no record consumer');
  const record = createAfterScheduleRecord('schema-count', 'Fixture reminder', 86400, Date.now(), 'Fixture title');
  const first = schema.parse({ record });
  assert.equal(globalThis[counter], 1, 'first parse constructs the rules once');
  assert.deepEqual(schema.parse({ record }), first);
  assert.equal(schema.safeParse({ record, unexpected: true }).success, false);
  assert.equal(globalThis[counter], 1, 'later valid and invalid parses reuse the rules');
});
