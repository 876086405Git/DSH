import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { setup, native, wire, timers, trace, advance, flush, RuntimeController,
  plain, saveCase, closeModules, loadModules } from './background-idle-fixture.mjs';
await loadModules();
after(closeModules);

test('1287 foreground adjacency: exit after drain keeps the next final drain and preserves the failure tail', async () => {
  const f = await setup();
  const originalDrain = native.drainEvents;
  try {
    await f.background();
    let raced = false;
    native.drainEvents = () => {
      const result = originalDrain();
      if (!raced) {
        raced = true;
        native.events.push({ kind: 'log', stream: 'stderr', line: 'foreground-race-tail private-fixture-token' },
          { kind: 'exit', exitCode: 23 });
        Object.assign(native.state, { phase: 'exited', exitCode: 23, token: null });
      }
      return result;
    };
    RuntimeController.onForeground(f.ability); await flush();
    const intermediate = { timerPresent: timers.has(f.controller.timer), pollInterval: f.controller.pollIntervalMs,
      pendingEvents: native.events.length, failureLines: f.controller.failureLog() };
    assert.equal(raced, true);
    assert.equal(intermediate.timerPresent, true);
    assert.equal(intermediate.pollInterval, 100);
    assert.equal(intermediate.pendingEvents, 2);
    await advance(100);
    const tail = f.controller.failureLog();
    const final = { timer: f.controller.timer, pendingEvents: native.events.length,
      failureLines: tail, owner: f.controller.taskOwner, recentLogs: f.controller.recentLogs(20) };
    await saveCase('F1-foreground-terminal-tail', { intermediate, final });
    assert.equal(final.timer, null);
    assert.equal(final.pendingEvents, 0);
    assert.equal(final.owner, null);
    assert.match(tail.join('\n'), /foreground-race-tail/);
    assert.match(tail.join('\n'), /code=23/);
    assert.doesNotMatch(tail.join('\n'), /private-fixture-token/);
    f.controller.collect();
    assert.deepEqual(f.controller.failureLog(), tail);
  } finally { native.drainEvents = originalDrain; await f.close(); }
});

test('1287 foreground adjacency: current Ability collects immediately, stale callbacks cannot replace owner, and cadence resumes at 100 ms', async () => {
  const f = await setup();
  try {
    await f.background();
    const current = { context: f.ability.context };
    f.controller.setIdleDiagnosticsEnabled(true);
    const count = () => plain(f.controller.getIdleDiagnostics()).window.counters;
    const before = count();
    RuntimeController.onForeground(current); await flush();
    const currentOwner = native.lifecycleSnapshot().ownerGeneration;
    const afterForeground = count(), writes = trace.filter(row => row.kind === 'native-update').length;
    const sends = wire.sends.length;
    RuntimeController.onBackground(f.ability); RuntimeController.onDestroy(f.ability); await flush();
    const afterStale = { owner: native.lifecycleSnapshot().ownerGeneration, foreground: RuntimeController.foreground,
      currentAbility: RuntimeController.ability === current, writes: trace.filter(row => row.kind === 'native-update').length,
      sends: wire.sends.length };
    assert.equal(afterForeground.collectCalls - before.collectCalls, 1);
    assert.equal(afterStale.owner, currentOwner);
    assert.equal(afterStale.foreground, true);
    assert.equal(afterStale.currentAbility, true);
    assert.equal(afterStale.writes, writes);
    assert.equal(afterStale.sends, sends);
    const firstTicks = count().pollTicks;
    await advance(1000);
    const ticks = count().pollTicks - firstTicks;
    await saveCase('F2-foreground-owner-cadence', { before, afterForeground, afterStale,
      logicalWindowMs: 1000, foregroundTicks: ticks, interval: f.controller.pollIntervalMs });
    assert.equal(ticks, 10);
    assert.equal(f.controller.pollIntervalMs, 100);
  } finally { await f.close(); }
});
