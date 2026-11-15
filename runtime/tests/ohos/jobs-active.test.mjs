import test from 'node:test';
import assert from 'node:assert/strict';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const base = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
const load = name => import(pathToFileURL(join(base, name, 'lib/index.js')));
const { Context } = await load('cordis');
let serial = 0;

async function fixture(t) {
  const ctx = new Context();
  const producers = [];
  t.after(async () => {
    for (const producer of producers) producer.done.resolve({ status: 'killed', detail: 'fixture cleanup' });
    await ctx.fiber.dispose();
  });
  for (const name of ['dsh-session', 'dsh-session-projection', 'dsh-agent', 'dsh-jobs-local']) {
    await ctx.plugin((await load(name)).default);
  }
  const jobs = ctx.jobs;
  jobs.attachController('jobs-active-fixture');
  function start(owner) {
    const done = Promise.withResolvers();
    const cancelled = Promise.withResolvers();
    const reasons = [];
    const id = jobs.start({
      kind: 'jobs-active', label: 'bounded producer', owner,
      run() {
        return {
          done: done.promise,
          cancel(reason) { reasons.push(reason); cancelled.resolve(reason); },
        };
      },
    });
    const producer = {
      id, done, cancelled: cancelled.promise, reasons,
      async settle(status) {
        done.resolve({ status, detail: status });
        return jobs.wait(id, 1000, owner);
      },
    };
    producers.push(producer);
    return producer;
  }
  async function owner() {
    let ownerCtx;
    const fiber = ctx.plugin({ inject: ['agents'], apply(child) { ownerCtx = child; } });
    await fiber;
    const session = ctx.sessions.create(`jobs-active-owner-${++serial}`);
    // register() accepts an already-constructed Agent. Session, Registry,
    // registration/disposer and owner fiber are real; no AgentLoop/LLM runs.
    const agent = { id: session.id, session, ctx: ownerCtx, status: 'idle' };
    const detach = ownerCtx.agents.register(agent);
    await detach;
    assert.equal(ctx.agents.get(agent.id), agent);
    return { agent, detach, fiber };
  }
  return { ctx, jobs, start, owner };
}

test('authoritative query follows unowned running, stopping, settlement and removal', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  assert.equal(f.jobs.hasActiveJobs(), false);
  const p = f.start();
  assert.equal(f.ctx.agents.list().length, 0);
  assert.equal(f.jobs.hasActiveJobs(), true);
  assert.equal(f.jobs.kill(p.id, undefined, 'user stop'), 'requested');
  assert.deepEqual(p.reasons, ['user stop']);
  assert.equal(f.jobs.get(p.id).status, 'stopping');
  assert.equal(f.jobs.hasActiveJobs(), true);
  await p.settle('killed');
  assert.equal(f.jobs.hasActiveJobs(), false);
  assert.equal(f.jobs.list().length, 1, 'terminal records remain retained');
  f.jobs.remove(p.id);
  assert.equal(f.jobs.hasActiveJobs(), false);
  assert.equal(f.jobs.list().length, 0);
});

test('all terminal states are idle and a subsequent real job is observed without a cached count', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  for (const status of ['completed', 'killed', 'failed']) {
    const p = f.start();
    assert.equal(f.jobs.hasActiveJobs(), true);
    await p.settle(status);
    assert.equal(f.jobs.hasActiveJobs(), false);
  }
  assert.deepEqual(f.jobs.list().map(job => job.status), ['completed', 'killed', 'failed']);
  const p = f.start();
  assert.equal(f.jobs.hasActiveJobs(), true);
  await p.settle('completed');
  assert.equal(f.jobs.hasActiveJobs(), false);
});

test('public AgentRegistry unregistration leaves its live owned job visible to the global query', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  const owner = await f.owner();
  const p = f.start(owner.agent.id);
  assert.equal(f.jobs.list().length, 0, 'caller-less list still hides owned jobs');
  assert.equal(f.jobs.hasActiveJobs(), true);
  await owner.detach();
  assert.equal(f.ctx.agents.get(owner.agent.id), undefined);
  assert.equal(f.ctx.agents.list().length, 0);
  assert.equal(f.jobs.get(p.id, owner.agent.id).status, 'running');
  assert.deepEqual(p.reasons, [], 'registration removal does not dispose the owner fiber');
  assert.equal(f.jobs.hasActiveJobs(), true);
  await p.settle('completed');
  assert.equal(f.jobs.hasActiveJobs(), false);
  await owner.fiber.dispose();
  assert.throws(() => f.jobs.get(p.id, owner.agent.id), /unknown job/);
});

test('owner teardown stays active until its compliant producer settles and the record is dropped', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  const owner = await f.owner();
  const p = f.start(owner.agent.id);
  const removed = [];
  f.jobs.events.subscribe({ owners: 'all' }, event => {
    if (event.type === 'removed') removed.push(event.job.id);
  });
  let disposed = false;
  const disposal = owner.fiber.dispose().then(() => { disposed = true; });
  assert.equal(await p.cancelled, 'owner disposed');
  assert.equal(disposed, false);
  assert.equal(f.jobs.get(p.id, owner.agent.id).status, 'stopping');
  assert.equal(f.jobs.hasActiveJobs(), true);
  p.done.resolve({ status: 'killed', detail: 'producer acknowledged stop' });
  await disposal;
  assert.equal(f.jobs.hasActiveJobs(), false);
  assert.deepEqual(removed, [p.id]);
  assert.throws(() => f.jobs.get(p.id, owner.agent.id), /unknown job/);
});

test('query allocates no job view/list and stops scanning at the first active record', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  await f.start().settle('completed');
  const active = f.start();
  const later = f.start();
  let visited = 0;
  const values = f.jobs.store.values;
  const list = f.jobs.list;
  const view = f.jobs.view;
  let listCalls = 0;
  let viewCalls = 0;
  // Per-instance observation only. No global Map/Array/Node builtin is replaced.
  f.jobs.store.values = function* () {
    for (const record of values.call(this)) { visited++; yield record; }
  };
  f.jobs.list = function (...args) { listCalls++; return list.apply(this, args); };
  f.jobs.view = function (...args) { viewCalls++; return view.apply(this, args); };
  try {
    assert.equal(f.jobs.hasActiveJobs(), true);
    assert.equal(visited, 2);
    assert.equal(listCalls, 0);
    assert.equal(viewCalls, 0);
  } finally {
    delete f.jobs.store.values;
    delete f.jobs.list;
    delete f.jobs.view;
  }
  await active.settle('completed');
  await later.settle('completed');
  assert.equal(f.jobs.hasActiveJobs(), false);
});
