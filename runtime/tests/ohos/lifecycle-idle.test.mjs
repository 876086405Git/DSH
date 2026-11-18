// Actual coordinator and active budget; native facts/journal and timeout time are explicit fixtures.
import test from 'node:test';
import assert from 'node:assert/strict';
import { BoundaryCoordinator } from '../../ohos/lifecycle/coordinator.mjs';

function fixture(t, foreground = 1) {
  const native = { version: 1, engineGeneration: 1, ownerGeneration: 1, revision: 1,
    grantGeneration: 0, nowMs: 1000, deadlineMs: 0, drainAtMs: 0,
    phase: 0, available: 1, foreground, clockFailed: 0 };
  const records = [], timers = new Set();
  let fired = 0, reads = 0, active = false, closed = false;
  const event = { type: 'tool/call', seq: 1,
    data: { callId: 'call', name: 'fixture', turn: 1, step: 1 } };
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const set = globalThis.setTimeout, clear = globalThis.clearTimeout;
  t.mock.method(globalThis, 'setTimeout', (callback, ms, ...args) => {
    const timer = set(() => {
      if (ms === 250) { timers.delete(timer); fired++; }
      callback(...args);
    }, ms);
    if (ms === 250) timers.add(timer);
    return timer;
  });
  t.mock.method(globalThis, 'clearTimeout', timer => { timers.delete(timer); return clear(timer); });
  const journal = { records, async append(body) { const row = { body }; records.push(row); return row; },
    async flush() {}, async close() {} };
  const c = new BoundaryCoordinator({ journal, bootId: 'idle-native-monitor',
    flushSession: async () => true, readEvents: async () => [event],
    readHost: () => { reads++; return { ...native }; }, hasActiveRounds: () => active });
  const close = async () => {
    if (closed) return;
    closed = true;
    c.failedGroup('session', [1]);
    await c.close();
  };
  t.after(async () => {
    try { await close(); }
    finally { t.mock.restoreAll(); t.mock.timers.reset(); }
  });
  return { c, native, records, close, active: value => { active = value; },
    fired: () => fired, reads: () => reads, timers: () => timers.size,
    meta: { session: { id: 'session' }, callSeq: 1, block: { id: 'call', name: 'fixture' }, turn: 1, step: 1 },
    async tick(ms) {
      // Recursive timeouts use the current mock time, so advance in their actual 250 ms steps.
      for (let remaining = ms; remaining > 0; remaining -= 250) {
        t.mock.timers.tick(Math.min(remaining, 250));
        await new Promise(resolve => setImmediate(resolve));
        await new Promise(resolve => setImmediate(resolve)); // native resume joins a subsequent I/O turn
      }
    },
  };
}

test('an idle coordinator performs no periodic native reads for a logical minute', async t => {
  const f = fixture(t);
  await f.c.observeHost({});
  const reads = f.reads(), fired = f.fired();
  await f.tick(60000);
  assert.equal(f.fired() - fired, 0, 'no activity needs no 250 ms native polling');
  assert.equal(f.reads() - reads, 0);
  assert.equal(f.timers(), 0);
});

test('idle host heartbeats still read native authority once per request without a second poll loop', async t => {
  const f = fixture(t);
  for (let i = 0; i < 60; i++) { await f.c.observeHost({ foreground: false }, true); await f.tick(1000); }
  assert.equal(f.reads(), 60);
  assert.equal(f.fired(), 0);
  assert.equal(f.c.status().host.foreground, true, 'HTTP hint cannot override native foreground');
});

test('first running round starts the 250 ms monitor and idle completion retires it', async t => {
  const f = fixture(t);
  f.active(true);
  await f.c.gate('session');
  assert.equal(f.c.admit('session'), true);
  await f.tick(1000);
  assert.equal(f.fired(), 4);
  f.active(false);
  await f.tick(250); // at most one already-armed callback observes the now-idle round set
  const before = f.fired();
  await f.tick(60000);
  assert.equal(f.fired() - before, 0);
  assert.equal(f.timers(), 0);
});

test('a blocked gate observes native recovery without any HTTP host hint', async t => {
  const f = fixture(t, 0);
  let completed = false;
  const gated = f.c.gate('session').then(() => { completed = true; });
  await Promise.resolve();
  assert.equal(f.timers(), 1);
  await f.tick(250);
  assert.equal(completed, false);
  f.native.foreground = 1; f.native.revision++;
  await f.tick(250);
  await gated;
  assert.equal(f.c.admit('session'), true);
  assert.equal(f.c.status().confirmedPause, false);
  const before = f.fired();
  await f.tick(60000);
  assert.equal(f.fired() - before, 0);
});

test('a standalone active budget arms native observation and disposal stops the last monitor', async t => {
  const f = fixture(t), limit = f.c.clock.deadline(undefined, 120000, 'fixture deadline');
  t.after(() => limit[Symbol.dispose]());
  assert.equal(f.timers(), 1, 'budget creation after idle must arm observation immediately');
  f.native.foreground = 0; f.native.phase = 2; f.native.grantGeneration = 1;
  f.native.deadlineMs = 3000; f.native.drainAtMs = 1500; f.native.nowMs = 1500;
  await f.tick(250);
  assert.equal(f.c.clock.paused, true, 'native drain deadline still pauses an active budget');
  assert.equal(limit.signal.aborted, false);
  f.native.foreground = 1; f.native.revision++;
  await f.tick(250);
  assert.equal(f.c.clock.paused, false);
  limit[Symbol.dispose]();
  const before = f.fired();
  await f.tick(60000);
  assert.equal(f.fired() - before, 0);
  assert.equal(f.timers(), 0);
});

test('upstream abort of the last paused budget preserves its reason and cancels polling', async t => {
  const f = fixture(t, 0), abort = new AbortController(), reason = { kind: 'exact upstream reason' };
  const limit = f.c.clock.deadline(abort.signal, 120000, 'fixture deadline');
  await f.tick(250);
  assert.equal(f.c.clock.paused, true);
  abort.abort(reason);
  assert.equal(limit.signal.reason, reason);
  assert.equal(f.c.clock.pendingCount, 0);
  const before = f.fired();
  await f.tick(60000);
  assert.equal(f.fired() - before, 0);
});

test('aborting one blocked gate preserves observation for the other waiter', async t => {
  const f = fixture(t, 0), abort = new AbortController(), reason = { gate: 'cancel only this one' };
  const first = f.c.gate('first', abort.signal), second = f.c.gate('second');
  const rejected = assert.rejects(first, error => error === reason);
  abort.abort(reason); await rejected;
  assert.equal(f.timers(), 1);
  f.native.foreground = 1; f.native.revision++;
  await f.tick(250); await second;
  const before = f.fired();
  await f.tick(60000);
  assert.equal(f.fired() - before, 0);
  assert.equal(f.timers(), 0);
});

test('disposing one of two budgets keeps the remaining budget under native observation', async t => {
  const f = fixture(t), first = f.c.clock.deadline(undefined, 120000, 'first'),
    second = f.c.clock.deadline(undefined, 120000, 'second');
  first[Symbol.dispose]();
  assert.equal(f.c.clock.pendingCount, 1);
  assert.equal(f.timers(), 1);
  f.native.foreground = 0;
  await f.tick(250);
  assert.equal(f.c.clock.paused, true);
  assert.equal(second.signal.aborted, false);
  second[Symbol.dispose]();
  const before = f.fired();
  await f.tick(60000);
  assert.equal(f.fired() - before, 0);
});

test('a prepared call independently keeps the native monitor alive until group retirement', async t => {
  const f = fixture(t);
  await f.c.prepared(f.meta);
  assert.equal(f.timers(), 1);
  f.native.foreground = 0;
  await f.tick(250);
  assert.equal(f.c.status().paused, true);
  assert.equal(f.c.status().calls[0].active, true);
  f.c.failedGroup('session', [1]);
  const before = f.fired();
  await f.tick(60000);
  assert.equal(f.fired() - before, 0);
});

test('admission after idle synchronously rejects exact native expiry and failed native facts', async t => {
  const f = fixture(t, 0);
  f.native.phase = 2; f.native.grantGeneration = 1; f.native.deadlineMs = 3000; f.native.drainAtMs = 1500;
  assert.equal(f.c.admit('session'), true);
  f.native.nowMs = 1500;
  assert.equal(f.c.admit('session'), false, 'no next timer may admit at the drain boundary');
  f.native.phase = 7; f.native.clockFailed = 1;
  assert.equal(f.c.admit('session'), false, 'a phase-7 grant cannot override a failed clock');
  f.native.clockFailed = 0; f.native.available = 0;
  assert.equal(f.c.admit('session'), false);
});

test('close wakes a blocked gate with a closed error and cannot leave a native timer', async t => {
  const f = fixture(t, 0);
  const gated = f.c.gate('session');
  const refused = assert.rejects(gated, { code: 'ERR_OHOS_LIFECYCLE_CLOSED' });
  await f.close(); await refused;
  await f.tick(60000);
  assert.equal(f.timers(), 0);
  assert.equal(f.fired(), 0);
  assert.throws(() => f.c.clock.deadline(undefined, 1000, 'after close'), { code: 'ERR_OHOS_LIFECYCLE_CLOSED' });
});
