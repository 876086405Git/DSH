import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { setup, native, osBoundary, wire, timers, trace, advance, flush, RuntimeController,
  plain, saveCase, closeModules, loadModules, localDate, linuxBoundary } from './background-idle-fixture.mjs';
await loadModules();
after(closeModules);
const counters = controller => plain(controller.getIdleDiagnostics()).window.counters;

test('parking qualification: 30/120 second checks are finite and do not send periodic lifecycle requests', async () => {
  const f = await setup(); const calls = { healthy: [], pin: [] };
  try {
    f.controller.attempt = 'fixture-attempt'; f.controller.bootProfile = { fixtureCapturedBoot: true };
    f.controller.recovery.markHealthy = async id => { calls.healthy.push({ id, at: localDate.now() }); };
    f.controller.lastGood.pinBooted = async (boot, at) => { calls.pin.push({ boot, at }); };
    f.controller.collect(); await f.background();
    const began = localDate.now(), sends = wire.sends.length;
    f.controller.setIdleDiagnosticsEnabled(true);
    assert.equal(f.controller.timer, null); assert.equal(timers.size, 1);
    await advance(29999); assert.deepEqual(calls, { healthy: [], pin: [] });
    await advance(1); assert.equal(calls.healthy.length, 1); assert.equal(calls.pin.length, 0);
    assert.equal(calls.healthy[0].at - began, 30000);
    await advance(89999); assert.equal(calls.pin.length, 0);
    await advance(1); assert.equal(calls.pin.length, 1); assert.equal(calls.pin[0].at - began, 120000);
    assert.equal(timers.size, 0); await advance(60000);
    const value = { calls, counters: counters(f.controller), sends: wire.sends.length - sends, logicalWindowMs: 180000 };
    await saveCase('Q1-finite-qualification', value);
    assert.equal(value.counters.pollTicks, 0); assert.equal(value.counters.collectCalls, 2);
    assert.equal(value.counters.lifecycleRefreshRequests, 0); assert.equal(value.sends, 0);
  } finally { await f.close(); }
});

test('parking qualification: callback rereads exited state and never pins an old running snapshot', async () => {
  const f = await setup(); const calls = { healthy: 0, pin: 0, finish: 0 };
  try {
    f.controller.attempt = 'fixture-attempt'; f.controller.bootProfile = { fixtureCapturedBoot: true };
    f.controller.recovery.markHealthy = async () => { calls.healthy++; };
    f.controller.lastGood.pinBooted = async () => { calls.pin++; };
    f.controller.recovery.finish = async () => { calls.finish++; };
    f.controller.collect(); await f.background();
    native.state.phase = 'exited'; native.state.exitCode = 17;
    native.events.push({ kind: 'log', stream: 'stderr', line: 'exit-before-qualification' }, { kind: 'exit', exitCode: 17 });
    await advance(120000);
    await saveCase('Q2-exit-before-qualification', { calls, timers: timers.size, lines: f.controller.failureLines });
    assert.deepEqual(calls, { healthy: 0, pin: 0, finish: 1 }); assert.equal(timers.size, 0);
    assert(f.controller.failureLines.some(line => line.includes('exit-before-qualification')));
  } finally { await f.close(); }
});

test('parking qualification: safe mode has no normal-run qualification wakeups', async () => {
  const f = await setup();
  try {
    f.controller.runMode = 'safe'; f.controller.attempt = 'fixture-safe';
    await f.background(); f.controller.setIdleDiagnosticsEnabled(true); const sends = wire.sends.length;
    await advance(180000);
    await saveCase('Q3-safe-mode', { counters: counters(f.controller), sends: wire.sends.length - sends, timers: timers.size });
    assert.equal(counters(f.controller).collectCalls, 0); assert.equal(wire.sends.length - sends, 0); assert.equal(timers.size, 0);
  } finally { await f.close(); }
});

test('parking stop: explicit stop restarts 100 ms collection before awaited Linux retirement', async () => {
  const f = await setup(); const held = Promise.withResolvers(); let stopping;
  try {
    await f.background(); assert.equal(f.controller.timer, null);
    linuxBoundary.shutdown = async () => held.promise;
    f.controller.setIdleDiagnosticsEnabled(true); stopping = f.controller.stop();
    assert.equal(linuxBoundary.calls, 1); assert.equal(native.stops, 0);
    assert.equal(timers.get(f.controller.timer)?.delay, 100);
    await advance(500); assert.equal(counters(f.controller).pollTicks, 5); assert.equal(native.stops, 0);
    held.resolve(); await stopping; await flush();
    await saveCase('S1-stop-awaits-linux', { counters: counters(f.controller), linuxCalls: linuxBoundary.calls, nativeStops: native.stops });
    assert.equal(native.stops, 1);
  } finally { held.resolve(); await stopping; await f.close(); }
});

test('parking ownerless: destroyed idle Ability releases owner and does not retain periodic polls', async () => {
  const f = await setup();
  try {
    RuntimeController.onDestroy(f.ability); await flush();
    assert.equal(f.controller.taskOwner, null); assert.equal(native.lifecycleSnapshot().available, 0);
    f.controller.setIdleDiagnosticsEnabled(true); const sends = wire.sends.length;
    await advance(60000);
    await saveCase('O1-destroyed-idle-owner', { counters: counters(f.controller), sends: wire.sends.length - sends, owner: f.controller.taskOwner });
    assert.equal(counters(f.controller).pollTicks, 0); assert.equal(wire.sends.length - sends, 0);
  } finally { await f.close(); }
});

test('parking ownerless: rejected native revision and unresolved cleanup cannot park a destroyed owner', async () => {
  const f = await setup(); const held = Promise.withResolvers();
  try {
    osBoundary.startDeferred = held; wire.busy = true; await f.observe(); await f.background();
    wire.busy = false; wire.alterAck = ack => { ack.nativeHost.revision--; };
    RuntimeController.onDestroy(f.ability); await flush();
    assert.equal(f.controller.retiredOwners.length, 1); assert.notEqual(f.controller.timer, null);
    held.resolve({ continuousTaskId: 73, notificationId: 173 }); await flush();
    assert.notEqual(f.controller.timer, null); assert.deepEqual(osBoundary.stopped.map(row => row.id), [73]);
    wire.alterAck = null; await f.observe();
    await saveCase('O2-retired-debt-and-rejected-ack', { retiredOwners: f.controller.retiredOwners.length, timer: f.controller.timer, stops: osBoundary.stopped.map(row => row.id) });
    assert.equal(f.controller.retiredOwners.length, 0); assert.equal(f.controller.timer, null);
  } finally { held.resolve({ continuousTaskId: 73 }); wire.alterAck = null; await flush(); await f.close(); }
});

test('parking refresh: a later explicit busy ACK resumes the background cadence without manufacturing a grant', async () => {
  const f = await setup();
  try {
    await f.background(); assert.equal(f.controller.timer, null);
    wire.busy = true; await f.observe();
    await saveCase('B1-later-busy-ack', { timer: f.controller.timer, delay: timers.get(f.controller.timer)?.delay ?? null, phase: native.lifecycleSnapshot().phase, requests: osBoundary.requested.length });
    assert.equal(timers.get(f.controller.timer)?.delay, 1000);
    assert.equal(native.lifecycleSnapshot().phase, 4); assert.equal(osBoundary.requested.length, 0);
  } finally { await f.close(); }
});

test('parking refresh: a rejected new ACK cannot reuse an older accepted idle fact', async () => {
  const f = await setup();
  try {
    await f.background(); assert.equal(f.controller.timer, null);
    wire.busy = true; wire.alterAck = ack => { ack.nativeHost.revision--; }; await f.observe();
    await saveCase('B2-rejected-after-idle', { timer: f.controller.timer, idleAccepted: f.controller.taskOwner.idleAccepted, delay: timers.get(f.controller.timer)?.delay ?? null });
    assert.equal(f.controller.taskOwner.idleAccepted, false);
    assert.equal(timers.get(f.controller.timer)?.delay, 1000);
  } finally { wire.alterAck = null; await f.close(); }
});

test('a failure after a valid ACK is logged once and remains visible until the retry succeeds', async () => {
  const f = await setup();
  try {
    await f.background();
    assert.equal(f.controller.lifecycle.synchronized(), true);
    wire.failure = new Error('private transport detail');
    await f.observe();
    assert.equal(f.controller.lifecycle.synchronized(), false);
    assert.equal(f.controller.lifecycle.failureCode(), 'ohos_lifecycle_unavailable');
    await advance(1000);
    const lines = f.events.filter(event => event.type === 'logs').flatMap(event => event.entries.map(entry => entry.line));
    assert.deepEqual(lines.filter(line => line.startsWith('lifecycle:')), ['lifecycle: ohos_lifecycle_unavailable']);
    assert(!lines.some(line => line.includes('private transport detail')));
    assert.equal(f.events.filter(event => event.type === 'notice').length, 1);
    wire.failure = null;
    await advance(2000);
    assert.equal(f.controller.lifecycle.synchronized(), true);
    assert.equal(f.controller.lifecycle.failureCode(), null);
  } finally { await f.close(); }
});

test('parking foreground: immediate collection and original 10 ticks/one refresh per second remain', async () => {
  const f = await setup();
  try {
    await f.background(); f.controller.setIdleDiagnosticsEnabled(true);
    RuntimeController.onForeground(f.ability); await flush(); const sends = wire.sends.length;
    await advance(1000);
    const value = { counters: counters(f.controller), sends: wire.sends.length - sends };
    await saveCase('F3-foreground-cadence', value);
    assert.equal(value.counters.collectCalls, 11); assert.equal(value.counters.pollTicks, 10);
    assert.equal(value.counters.lifecycleRefreshRequests, 1); assert.equal(value.sends, 1);
  } finally { await f.close(); }
});

test('parking visibility: background logs and exit may wait for foreground, then failure tail is collected', async () => {
  const f = await setup();
  try {
    await f.background();
    native.state.phase = 'exited'; native.state.exitCode = 19;
    native.events.push({ kind: 'log', stream: 'stderr', line: 'parked-exit-private-fixture-token' }, { kind: 'exit', exitCode: 19 });
    await advance(60000); assert.equal(native.events.length, 2);
    RuntimeController.onForeground(f.ability); await flush();
    await saveCase('V1-delayed-background-exit', { delayedMs: 60000, lines: f.controller.failureLines, queued: native.events.length });
    assert.equal(native.events.length, 0); assert(f.controller.failureLines.some(line => line.includes('parked-exit')));
    assert(!f.controller.failureLines.some(line => line.includes('private-fixture-token')));
  } finally { await f.close(); }
});
