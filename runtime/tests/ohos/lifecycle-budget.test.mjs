import test from 'node:test';
import assert from 'node:assert/strict';
import { setTimeout as wait } from 'node:timers/promises';
import { performance } from 'node:perf_hooks';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { ActiveBudgetClock } from '../../ohos/lifecycle/budget.mjs';

const require = createRequire(join(resolve(process.env.DSH_LIFECYCLE_TEST_PREFIX), 'package.json'));
const { deadline, timeoutOf, idleWatchdog, ohosLifecycleBudgetProtocol } = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-timeout')));
const key = Symbol.for('dsh.go.ohos.lifecycle');
assert.equal(ohosLifecycleBudgetProtocol, 1);
function fixture(t) {
  assert.equal(globalThis[key], undefined);
  const clock = new ActiveBudgetClock('test-boot');
  globalThis[key] = { clock };
  t.after(() => { clock.dispose(); delete globalThis[key]; });
  return clock;
}

for (const code of ['TOOL_TIMEOUT', 'BASH_TIMEOUT']) test(`actual ${code} deadline excludes only acknowledged logical pause, retains reason class and remaining budget`, async t => {
  const clock = fixture(t), limit = deadline(undefined, 240, code);
  const start = performance.now();
  await wait(70); clock.pause();
  assert.equal(clock.pendingCount, 1);
  const frozen = clock.now(); await wait(320);
  assert.equal(clock.now(), frozen); assert.equal(limit.signal.aborted, false);
  clock.resume(); await wait(65);
  assert.equal(limit.signal.aborted, false);
  await wait(200);
  assert.equal(limit.signal.aborted, true);
  assert.equal(timeoutOf(limit.signal, code)?.timeoutMs, 240);
  assert(performance.now() - start >= 500);
  assert.equal(clock.pendingCount, 0); limit[Symbol.dispose]();
});

test('a late logical pause cannot resurrect a deadline already elapsed during blocked JS', t => {
  const clock = fixture(t), limit = deadline(undefined, 30, 'TOOL_TIMEOUT');
  const until = performance.now() + 70;
  while (performance.now() < until) { /* actual occupied event loop */ }
  assert.equal(limit.signal.aborted, false, 'timer callback has not run yet');
  clock.pause();
  assert.equal(timeoutOf(limit.signal)?.code, 'TOOL_TIMEOUT');
  clock.resume(); assert.equal(limit.signal.aborted, true);
});

test('upstream cancellation preserves the exact reason while paused, removes timer and cannot be undone', t => {
  const clock = fixture(t), control = new AbortController(), reason = { exact: 'caller-owned' };
  const limit = deadline(control.signal, 1000, 'BASH_TIMEOUT');
  clock.pause(); control.abort(reason);
  assert.equal(limit.signal.reason, reason); assert.equal(timeoutOf(limit.signal), undefined);
  assert.equal(clock.pendingCount, 0); clock.resume();
  assert.equal(limit.signal.reason, reason);
});

test('dispose stops only the owned timer; zero-budget and network deadlines retain original behavior', async t => {
  const clock = fixture(t), control = new AbortController();
  assert.equal(deadline(control.signal, 0, 'TOOL_TIMEOUT').signal, control.signal);
  const disposed = deadline(undefined, 40, 'TOOL_TIMEOUT'); disposed[Symbol.dispose]();
  const network = deadline(undefined, 40, 'HTTP_TIMEOUT');
  clock.pause(); await wait(95);
  assert.equal(disposed.signal.aborted, false);
  assert.equal(timeoutOf(network.signal)?.code, 'HTTP_TIMEOUT');
  network[Symbol.dispose](); assert.equal(clock.pendingCount, 0);
});

test('actual idle watchdog still expires in wall time during logical pause and drains its upstream later', async t => {
  const clock = fixture(t), returned = Promise.withResolvers();
  const watchdog = idleWatchdog(undefined, 35, 'LLM_IDLE_TIMEOUT');
  clock.pause();
  await assert.rejects(watchdog.next({ next: () => returned.promise }), error => error.code === 'LLM_IDLE_TIMEOUT');
  assert.equal(timeoutOf(watchdog.signal)?.code, 'LLM_IDLE_TIMEOUT');
  returned.resolve({ done: true }); watchdog[Symbol.dispose]();
});

test('a closed budget owner rejects later tool deadlines rather than silently reverting to wall time', t => {
  const clock = fixture(t); clock.dispose();
  assert.throws(() => deadline(undefined, 100, 'TOOL_TIMEOUT'), { code: 'ERR_OHOS_LIFECYCLE_CLOSED' });
});
