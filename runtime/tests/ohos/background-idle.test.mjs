import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { setup, native, osBoundary, wire, timers, trace, advance, flush, RuntimeController,
  TransientTaskOwner, plain, saveCase, closeModules, loadModules } from './background-idle-fixture.mjs';
await loadModules();
after(closeModules);

test('1287 R1: confirmed background idle has zero steady periodic requests and collects', async () => {
  const f = await setup();
  try {
    await f.background();
    assert.equal(f.controller.taskOwner.awaitingActivity, false);
    assert.equal(f.controller.taskOwner.cleanupPending(), false);
    assert.equal(native.lifecycleSnapshot().phase, 4);
    assert.equal(osBoundary.requested.length, 0);
    f.controller.setIdleDiagnosticsEnabled(true); const before = wire.sends.length;
    await advance(60000);
    const counters = plain(f.controller.getIdleDiagnostics()).window.counters;
    const sends = wire.sends.length - before;
    await saveCase('R1-idle-periodic', { logicalWindowMs: 60000, counters, transportSendStarts: sends, nativeStops: native.stops,
      awaitingActivity: f.controller.taskOwner.awaitingActivity, cleanupPending: f.controller.taskOwner.cleanupPending() });
    assert.deepEqual({ ticks: counters.pollTicks, collects: counters.collectCalls, refreshes: counters.lifecycleRefreshRequests, sends },
      { ticks: 0, collects: 0, refreshes: 0, sends: 0 });
    assert.equal(native.stops, 0);
  } finally { await f.close(); }
});

test('1287 R2a: foreground callback immediately collects before any timer advance', async () => {
  const f = await setup();
  try {
    await f.background(); f.controller.setIdleDiagnosticsEnabled(true);
    native.events.push({ kind: 'log', stream: 'stdout', line: 'foreground-immediate-marker' });
    const before = plain(f.controller.getIdleDiagnostics()).window.counters.collectCalls;
    RuntimeController.onForeground(f.ability); await flush();
    const after = plain(f.controller.getIdleDiagnostics()).window.counters.collectCalls;
    const lines = f.controller.recentLogs(10);
    await saveCase('R2a-foreground-immediate', { before, after, timerAdvanceMs: 0, lines, queuedNativeEvents: native.events.length });
    assert.equal(after - before, 1);
    assert(lines.some(line => line.includes('foreground-immediate-marker')));
  } finally { await f.close(); }
});

test('1287 control: final idle ACK revokes same-owner native lease before targeted OS stop and emits non-7', async () => {
  const f = await setup();
  try {
    wire.busy = true; await f.observe(); await f.background(); await flush();
    assert.equal(native.lifecycleSnapshot().phase, 7); assert.equal(osBoundary.requested.length, 1);
    const owner = native.lifecycleSnapshot().ownerGeneration, first = trace.length;
    wire.busy = false; await f.observe(); await flush();
    const tail = trace.slice(first);
    const revoke = tail.findIndex(row => row.kind === 'native-update' && row.operation === 'continuous' && row.value === 0);
    const stop = tail.findIndex(row => row.kind === 'os-stop');
    const status = f.events.filter(event => event.type === 'status').at(-1);
    await saveCase('C1-targeted-idle-release', { owner, revoke, stop, osStops: osBoundary.stopped.map(row => row.id), status,
      cleanupPending: f.controller.taskOwner.cleanupPending() });
    assert(revoke >= 0 && stop > revoke);
    assert.equal(native.lifecycleSnapshot().ownerGeneration, owner); assert.equal(native.lifecycleSnapshot().phase, 4);
    assert.deepEqual(osBoundary.stopped.map(row => row.id), [73]); assert.equal(f.controller.taskOwner.cleanupPending(), false);
    assert.equal(status.status.transientTask.phase, 4); assert.equal(status.status.transientTask.foreground, false);
  } finally { await f.close(); }
});

test('1287 control: old pending OS grant stays debt and its late id cannot activate a replacement owner', async () => {
  const f = await setup(); let pending;
  try {
    pending = Promise.withResolvers(); osBoundary.startDeferred = pending;
    wire.busy = true; await f.observe(); await f.background();
    const old = f.controller.taskOwner, oldOwner = native.lifecycleSnapshot().ownerGeneration;
    assert.equal(old.cleanupPending(), true); assert.notEqual(native.lifecycleSnapshot().phase, 7);
    wire.busy = false; await f.observe();
    assert.equal(old.cleanupPending(), true); assert.notEqual(f.controller.timer, null);
    const replacement = new TransientTaskOwner(native, true, () => {}, f.ability.context);
    const newOwner = native.lifecycleSnapshot().ownerGeneration;
    pending.resolve({ continuousTaskId: 73, notificationId: 173 }); await flush();
    await saveCase('C2-late-old-grant', { oldOwner, newOwner, oldCleanupPending: old.cleanupPending(),
      osStops: osBoundary.stopped.map(row => row.id), activatedOwners: trace.filter(row => row.kind === 'native-update' && row.operation === 'continuous' && row.value === 1).map(row => row.owner) });
    assert(newOwner !== oldOwner); assert.equal(native.lifecycleSnapshot().ownerGeneration, newOwner);
    assert.equal(native.lifecycleSnapshot().foreground, 1); assert.notEqual(native.lifecycleSnapshot().phase, 7);
    assert.deepEqual(osBoundary.stopped.map(row => row.id), [73]); assert.equal(old.cleanupPending(), false);
    replacement.retire();
  } finally { pending?.resolve({ continuousTaskId: 73 }); await flush(); await f.close(); }
});

test('1287 control: failed OS stop retains cleanup debt and cannot be treated as parked completion', async () => {
  const f = await setup();
  try {
    wire.busy = true; await f.observe(); await f.background(); await flush();
    osBoundary.stopError = true; wire.busy = false; await f.observe();
    assert.equal(native.lifecycleSnapshot().phase, 4); assert.equal(f.controller.taskOwner.cleanupPending(), true);
    assert.notEqual(f.controller.timer, null);
    await advance(2000);
    await saveCase('C3-cleanup-debt', { cleanupPending: f.controller.taskOwner.cleanupPending(),
      ownerStatus: plain(f.controller.taskOwner.status()), osStops: osBoundary.stopped.map(row => row.id), controllerTimerPresent: timers.has(f.controller.timer) });
    assert.equal(osBoundary.stopped.length, 3); assert.equal(f.controller.taskOwner.cleanupPending(), true);
    assert.equal(f.controller.taskOwner.status().get('error'), 'ohos_continuous_cancel_failed');
    assert(timers.has(f.controller.timer));
  } finally { osBoundary.stopError = false; await f.close(); }
});

test('1287 control: HTTP success with wrong native revision does not count as owner-accepted idle', async () => {
  const f = await setup();
  try {
    wire.busy = true; await f.observe(); await f.background(); await flush();
    wire.busy = false; wire.alterAck = ack => { ack.nativeHost.revision--; };
    await f.observe();
    const lifecycle = plain(f.controller.lifecycle.status());
    await saveCase('C4-http-success-owner-rejected', { lifecycle, ownerStatus: plain(f.controller.taskOwner.status()), osStops: osBoundary.stopped.length });
    assert.equal(lifecycle.acknowledgedRevision, lifecycle.revision); assert.equal(lifecycle.error, null);
    assert.equal(native.lifecycleSnapshot().phase, 7); assert.equal(osBoundary.stopped.length, 0);
    assert.notEqual(f.controller.timer, null);
  } finally { wire.alterAck = null; await f.close(); }
});
