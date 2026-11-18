// Actual Cordis provider/dependent teardown and LocalJobRegistry producer lifetime.
// Other core services are explicit idle interfaces; no AgentLoop/device execution is claimed.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { Context } from '@deepseek-ai/cordis';
import Jobs from '@deepseek-ai/dsh-jobs-local';
import * as lifecycle from '../../ohos/lifecycle/index.mjs';
import { LinuxControl } from '../../ohos/linux/control.mjs';
import { until } from './linux-control-fixture.mjs';

test('jobs provider retirement closes lifecycle before producer settlement permits absence', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-activity-retire-'));
  const home = join(directory, 'home'), workspace = join(directory, 'workspace');
  await mkdir(home); await mkdir(workspace);
  const previous = process.env.DSH_HOME; process.env.DSH_HOME = home;
  const ctx = new Context(), done = Promise.withResolvers(); let cancelled = 0, retired = false;
  ctx.provide('agents', { list: () => [], get: () => undefined });
  ctx.provide('sessions', { flush: async () => true });
  ctx.provide('sessionPersistence', {});
  ctx.provide('subprocess', { backend: { roots: [workspace], live: new Set() }, linux: new LinuxControl() });
  globalThis[Symbol.for('dsh.go.ohos.sim')] = true;
  globalThis[Symbol.for('dsh.go.ohos.publication')] = { protocolVersion: 1, ownerId: randomUUID() };
  t.after(async () => {
    done.resolve({ status: 'killed' }); await ctx.fiber.dispose();
    if (previous === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = previous;
    await rm(directory, { recursive: true, force: true });
  });
  const jobsFiber = ctx.plugin(Jobs, { maxConcurrentJobsPerOwner: 4, retainBytes: 4096,
    settledRetainBytes: 1024, pumpPollMs: 150 });
  await jobsFiber;
  const jobs = ctx.get('jobs'); jobs.attachController('retirement-test');
  const lifecycleFiber = ctx.plugin(lifecycle); await lifecycleFiber;
  const coordinator = ctx.get('ohosLifecycle');
  assert(coordinator, 'real injected lifecycle activated');
  jobs.start({ kind: 'held', label: 'producer joins after provider hides',
    run() { return { done: done.promise, cancel() { cancelled++; } }; } });
  let revision = 0;
  const ack = () => coordinator.observeHost({ revision: ++revision, foreground: true, computePermission: 'unknown' }, true);
  assert.equal((await ack()).busy, true);
  const inflight = ack();
  const disposal = jobsFiber.dispose().then(() => { retired = true; });
  const during = await inflight;
  assert(during.closed || during.busy, 'an admitted ACK cannot turn provider disappearance into idle');
  await until(() => cancelled === 1);
  assert.equal(ctx.get('jobs'), undefined);
  assert.equal(retired, false);
  assert.equal(jobs.hasActiveJobs(), true, 'captured old registry still owns stopping producer');
  assert.equal(ctx.get('ohosLifecycle'), undefined, 'dependent service is no longer published');
  assert.throws(ack, { code: 'ERR_OHOS_LIFECYCLE_CLOSED' });
  done.resolve({ status: 'killed' }); await disposal;
  assert.equal(retired, true); assert.equal(jobs.hasActiveJobs(), false);
  assert.throws(ack, { code: 'ERR_OHOS_LIFECYCLE_CLOSED' });
  assert.equal(ctx.get('ohosLifecycle'), undefined, 'dependent service is no longer published');
  t.diagnostic(JSON.stringify({ actualProviderDispose: true, cancelled, producerJoined: retired,
    inflightClosed: during.closed, inflightBusy: during.busy, lifecycleClosedBeforeJoin: true }));
});
