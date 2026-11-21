import assert from 'node:assert/strict';
import test from 'node:test';
import { createUsage } from '../bridge/dsh-go-bridge/lib/usage.js';

test('background settlement counts only reported fields and opt-out clears the lease', () => {
  let now = Date.parse('2026-11-20T14:00:00Z');
  const usage = createUsage(() => now);
  const event = { type: 'assistant/message', data: { usage: {
    inputTokens: 99, outputTokens: 0, reported: { inputTokens: 99 },
  } } };
  usage.observe(event);
  assert.equal(usage.pull(true).days['2026-11-20'].counts[0], 0);
  usage.observe(event);
  usage.observe({ type: 'assistant/attempt', data: { stream: [{ type: 'chunk', chunk: {
    type: 'usage', usage: { reported: { outputTokens: 8 } },
  } }] } });
  const plugin = usage.beginPlugin();
  plugin(1);
  plugin(1);
  const snapshot = usage.pull(true);
  const day = snapshot.days['2026-11-20'];
  assert.deepEqual(day.counts, [2, 1, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0]);
  assert.equal(day.values[1], 0);
  assert.equal(day.values[9], 8);
  assert.equal(day.plugins[0], 1);
  now += 180001;
  usage.observe(event);
  assert.equal(usage.pull(true).days['2026-11-20'].counts[0], 2);
  const old = usage.beginPlugin();
  assert.deepEqual(usage.pull(false).days, {});
  assert.notEqual(usage.pull(true).epoch, snapshot.epoch);
  old(1);
  assert.equal(usage.pull(true).days['2026-11-20'].plugins[0], 0);
});
