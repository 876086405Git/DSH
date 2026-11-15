// Real lifecycle apply/coordinator, locked jobs registry and Linux control/owner/protocol.
// Native host time is the explicit always-foreground native fixture; guest execution is the existing TCP peer fixture.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { Context } from '@deepseek-ai/cordis';
import Jobs from '@deepseek-ai/dsh-jobs-local';
import { apply } from '../../ohos/lifecycle/index.mjs';
import { LinuxControl } from '../../ohos/linux/control.mjs';
import * as installation from '../../ohos/linux/owner.mjs';
import { ownerFixture, until, tick } from './linux-control-fixture.mjs';

test('published independent work remains busy after the round becomes idle', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-activity-'));
  const home = join(directory, 'home'), workspace = join(directory, 'workspace');
  await mkdir(home, { mode: 0o700 }); await mkdir(workspace, { mode: 0o700 });
  const previousHome = process.env.DSH_HOME;
  process.env.DSH_HOME = home;
  const ctx = new Context(), records = [];
  const agent = { id: 'activity-owner', status: 'idle', ctx,
    session: { id: 'activity-owner', append(type, data) { records.push({ type, data }); } } };
  ctx.provide('agents', { list: () => [agent], get: id => id === agent.id ? agent : undefined });
  ctx.provide('sessions', { flush: async () => true });
  ctx.provide('sessionPersistence', {});
  const f = await ownerFixture(t);
  const control = new LinuxControl({ hostPaths: { directory: f.data, nativeLibraryDirectory: '/trusted/native' },
    assetsDirectory: f.assets }, { async loadModule() {
    return { loadLinuxInstallationManifest: installation.loadLinuxInstallationManifest,
      createLinuxInstallationOwner: input => f.createOwner(input) };
  } });
  const live = new Set();
  ctx.provide('subprocess', { backend: { roots: [workspace], live }, linux: control });
  const jobs = new Jobs(ctx, { maxConcurrentJobsPerOwner: 4, retainBytes: 4096,
    settledRetainBytes: 1024, pumpPollMs: 150 });
  jobs.attachController('activity-test');
  globalThis[Symbol.for('dsh.go.ohos.sim')] = true;
  globalThis[Symbol.for('dsh.go.ohos.publication')] = { protocolVersion: 1, ownerId: randomUUID() };
  let coordinator;
  t.after(async () => {
    try { await coordinator?.close(); await ctx.fiber.dispose(); }
    finally {
      if (previousHome === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = previousHome;
      await rm(directory, { recursive: true, force: true });
    }
  });
  await apply(ctx);
  coordinator = ctx.ohosLifecycle;
  let revision = 0;
  const ack = () => coordinator.observeHost({ revision: ++revision, foreground: true, computePermission: 'unknown' }, true);
  const initial = await ack();
  assert.equal(initial.busy, false);
  const diagnostic = (name, actual, facts) => t.diagnostic(JSON.stringify({ name, busy: actual.busy,
    activeRound: agent.status, ...facts }));
  async function withJob(owner, stopping, child) {
    const done = Promise.withResolvers(); let cancelled = 0;
    const id = jobs.start({ kind: 'held-producer', label: 'actual independent producer',
      ...(owner === undefined ? {} : { owner }),
      run() { return { done: done.promise, cancel() { cancelled++; } }; } });
    try {
      if (stopping) jobs.kill(id, owner, 'controlled cancellation remains in flight');
      const current = jobs.get(id, owner);
      assert.equal(current.status, stopping ? 'stopping' : 'running');
      assert.equal(agent.status, 'idle');
      const observed = await ack();
      diagnostic(child, observed, { jobStatus: current.status, jobsVisible: jobs.list(owner).length, cancelled });
      assert.equal(observed.busy, true, 'a live producer is work even when no round or durable tool call is pending');
    } finally {
      done.resolve({ status: stopping ? 'killed' : 'completed' });
      await until(() => ['completed', 'killed'].includes(jobs.get(id, owner).status));
      jobs.remove(id, owner);
      assert.equal((await ack()).busy, false, 'terminal retained producer no longer holds activity');
    }
  }
  await t.test('unowned running job', () => withJob(undefined, false, 'unowned-running'));
  await t.test('owned running job after the round', () => withJob(agent.id, false, 'owned-running'));
  await t.test('owned stopping job until producer completion', () => withJob(agent.id, true, 'owned-stopping'));
  const command = (action, fields = {}) => { const state = control.status(); return control.command({ v: 1,
    instanceId: state.instanceId, attemptId: state.attemptId, action, ...fields }); };
  command('setEnabled', { enabled: true }); await until(() => control.status().admission);
  assert.equal((await ack()).busy, false, 'enabled retained idle guest is not itself an active command');
  await t.test('private Linux command not represented by an Agent round', async () => {
    command('runPrivateGuest', { requestId: control.status().nextRequestId,
      argv: ['python3', '-c', 'print(1)'], cwd: '/workspace' });
    const started = await f.peer.admitted();
    await until(() => control.status().job.started);
    try {
      const observed = await ack();
      diagnostic('private-linux-running', observed, { jobState: control.status().job.state, guestCommands: f.peer.commands.length });
      assert.equal(observed.busy, true, 'private guest execution must keep the activity fact busy');
    } finally {
      await f.peer.complete(started.job);
      await until(() => control.status().job.state === 'settled');
      assert.equal((await ack()).busy, false, 'settled retained Linux result is idle');
    }
  });
  await t.test('routed Linux command even when status.job is a previous settled result', async () => {
    const count = f.peer.commands.filter(command => command.op === 'start').length;
    const handle = await control.spawnRouted({ argv: ['python3', '-c', 'print(2)'], cwd: '/workspace',
      env: {}, graceMs: 10000, stdio: { stdin: { data: '' }, stdout: { maxBytes: 16384 }, stderr: { maxBytes: 16384 } } }, { label: 'routed-activity-test' });
    await until(() => f.peer.commands.filter(command => command.op === 'start').length === count + 1);
    const started = await f.peer.admitted(); await handle.started;
    try {
      assert.equal(control.status().job.state, 'settled');
      const observed = await ack();
      diagnostic('routed-linux-running', observed, { projectedPrivateJobState: control.status().job.state });
      assert.equal(observed.busy, true, 'routed work must not disappear behind the retained private-job projection');
    } finally {
      await f.peer.complete(started.job); await handle.done; await tick(); await tick();
      assert.equal((await ack()).busy, false);
    }
  });
  await t.test('subprocess handle lifetime is distinct from Agent running status', async () => {
    const handle = { explicitBoundary: 'preexisting backend live Set; no worker execution in this subcase' };
    live.add(handle);
    try {
      const observed = await ack(); diagnostic('backend-live-handle', observed, { liveHandles: live.size });
      assert.equal(observed.busy, true);
    } finally { live.delete(handle); assert.equal((await ack()).busy, false); }
  });
  assert.equal((await ack()).busy, false);
});

