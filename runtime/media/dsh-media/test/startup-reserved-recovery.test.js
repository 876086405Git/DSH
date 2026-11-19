import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { mkdtemp, mkdir, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { apply, selectedRequest } from '../src/index.js';
import { Config, CREDENTIAL_SLOTS, runtimeSnapshot } from '../src/config.js';
import { admitGeneration } from '../src/budget.js';
import { createBudgetLedger } from '../src/budget-ledger.js';

test('plugin startup releases a killed producer reservation before registering tools', async t => {
  const directory = await realpath(await mkdtemp(join(tmpdir(), 'media-reserved-recovery-')));
  const disposers = [];
  const originalNow = Date.now, now = Date.now();
  t.after(async () => {
    Date.now = originalNow;
    try { for (const dispose of disposers.reverse()) await dispose(); }
    finally { await rm(directory, { recursive: true, force: true }); }
  });
  Date.now = () => now; // Both processes must use the same Shanghai budget day.
  const workspace = join(directory, 'workspace');
  await mkdir(workspace);
  const dshHome = join(directory, 'home');
  const hostStateDir = join(dshHome, 'media', 'dsh-media');
  const config = Config({ dshHome, services: [{ id: 'recovery', enabled: true, keyRef: CREDENTIAL_SLOTS[0] }] });
  const snapshot = runtimeSnapshot(config);
  const { request, keyRef } = selectedRequest({ prompt: 'blue circle' }, snapshot, snapshot.services);
  const input = { now, workspace, request, hostStateDir, keyRef,
    budget: { dailyMicros: 20_000_000, unknownHoldMicros: 20_000_000 }, sessionId: 'recovery-session' };
  const child = spawnSync(process.execPath, ['--input-type=module', '-e', `
    import { admitGeneration } from ${JSON.stringify(new URL('../src/budget.js', import.meta.url).href)};
    const input = JSON.parse(process.argv[1]);
    Date.now = () => input.now;
    await admitGeneration(input.request, { ...input, signal: new AbortController().signal,
      approve: async () => 'allowed-once',
      authorizeWorkspace: async () => ({ cwd: input.workspace, workspaceRoot: input.workspace, mode: 'workspace-write' }),
    });
    process.kill(process.pid, 'SIGKILL');
  `, JSON.stringify(input)], { encoding: 'utf8', timeout: 10_000 });
  assert.equal(child.error, undefined, child.error?.message);
  assert.equal(child.status, null, child.stderr);
  assert.equal(child.signal, 'SIGKILL', child.stderr);
  assert.equal(child.stderr, '');

  const ledger = createBudgetLedger(join(hostStateDir, 'budget'));
  const before = await ledger.snapshot();
  assert.equal(before.requests.length, 1);
  const original = before.requests[0];
  assert.equal(original.state, 'reserved');
  assert.equal(original.estimateMicros, 20_000_000);
  assert.equal(before.dailyLimitMicros, 20_000_000);
  const registered = new Map(), registrationStates = [];
  const ctx = {
    fiber: { assertActive() {} },
    jobs: { events: { subscribe: () => () => {} } },
    effect(callback) { const dispose = callback(); disposers.push(dispose); return dispose; },
    on: () => () => {},
    credentials: { describe: async () => ({ configured: true }) },
    tools: { register(tool) {
      const state = JSON.parse(readFileSync(join(hostStateDir, 'budget', 'ledger-v1.json'), 'utf8'));
      registrationStates.push(state.requests.find(record => record.rid === original.rid)?.state);
      registered.set(tool.name, tool);
      return () => registered.delete(tool.name);
    } },
    systemPrompt: { section: () => () => {} },
  };
  await apply(ctx, config);
  // refresh catches registration errors, so these assertions must stay outside it.
  assert.ok(registered.has('generate_image'));
  assert.ok(registrationStates.length > 0);
  assert.ok(registrationStates.every(state => state === 'released'));
  assert.deepEqual((await ledger.snapshot()).requests, [{ ...original, state: 'released' }]);

  const next = await admitGeneration(request, { ...input, signal: new AbortController().signal,
    approve: async () => 'allowed-once',
    authorizeWorkspace: async () => ({ cwd: workspace, workspaceRoot: workspace, mode: 'workspace-write' }),
  });
  const after = await ledger.snapshot();
  const fresh = after.requests.find(record => record.rid === next.rid);
  assert.equal(after.requests.length, 2);
  assert.notEqual(next.rid, original.rid);
  assert.equal(fresh.state, 'reserved');
  assert.equal(fresh.day, original.day);
  assert.equal(fresh.estimateMicros, 20_000_000);
  assert.equal(after.dailyLimitMicros, 20_000_000);
});
