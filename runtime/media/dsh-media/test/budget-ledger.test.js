import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile, readdir, chmod, symlink, unlink, stat } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createBudgetLedger, cnyMicros } from '../src/budget-ledger.js';

const worker = fileURLToPath(new URL('./fixtures/budget-worker.mjs', import.meta.url));
const directoryWorker = fileURLToPath(new URL('./fixtures/directory-worker.mjs', import.meta.url));
const now = Date.parse('2026-10-28T12:00:00Z');
function request(extra = {}) {
  return { sessionId: 'review-session', serviceId: 'review-ark', modelId: 'review-model',
    profile: 'review-only', region: 'cn-beijing', baseUrl: 'https://example.test/api/v3',
    keyRef: 'REVIEW_KEY_REF', cwd: '/review/workspace', workspaceRoot: '/review/workspace',
    paramsHash: 'a'.repeat(64), ...extra };
}
function reservation(estimateMicros = 12_000_000) {
  return { rid: 'm_' + randomUUID(), request: request(), estimateMicros };
}
async function fixture(t) {
  const outer = await mkdtemp(join(tmpdir(), 'dsh-budget-review-'));
  t.after(() => rm(outer, { recursive: true, force: true }));
  const directory = join(outer, 'private', 'ledger');
  return { outer, directory, ledger: createBudgetLedger(directory, { clock: () => now }) };
}
function child(mode, directory, input, script = worker) {
  const subprocess = spawn(process.execPath, [script, mode, directory, JSON.stringify(input)], {
    env: { ...globalThis.process.env, TZ: 'Asia/Shanghai' }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '', stderr = '';
  subprocess.stdout.on('data', data => { stdout += data; });
  subprocess.stderr.on('data', data => { stderr += data; });
  const done = new Promise((resolve, reject) => {
    subprocess.on('error', reject);
    subprocess.on('close', (code, signal) => resolve({ code, signal, stdout, stderr,
      rows: stdout.trim().split('\n').filter(Boolean).map(line => JSON.parse(line)) }));
  });
  return { process: subprocess, done };
}
function code(expected) { return error => error?.code === expected; }

test('decimal prices use exact integer micro-CNY and round upward', () => {
  assert.equal(cnyMicros('20'), 20_000_000);
  assert.equal(cnyMicros('0.22'), 220_000);
  assert.equal(cnyMicros('0.00000001'), 1);
  assert.equal(cnyMicros('0.000001000000'), 1);
  for (const input of ['-1', 'NaN', '1e-6', '01', '.1', '1.', 0.22, '9007199254.740992']) {
    assert.throws(() => cnyMicros(input), code('invalid_amount'));
  }
});

test('budget counts reservations; rid replay cannot reserve or submit twice', async t => {
  const { ledger } = await fixture(t);
  const input = reservation();
  const first = await ledger.reserve(input);
  assert.equal(first.created, true);
  assert.equal((await ledger.reserve(input)).created, false);
  await assert.rejects(ledger.reserve({ ...input, request: request({ modelId: 'changed' }) }), code('identity_mismatch'));
  await assert.rejects(ledger.reserve(reservation(9_000_000)), code('budget_exceeded'));
  const { rid, identity } = first.record;
  assert.equal((await ledger.beginSubmission(rid, identity)).started, true);
  assert.equal((await ledger.beginSubmission(rid, identity)).started, false);
  await assert.rejects(ledger.releaseUnsent(rid, identity), code('submission_may_have_happened'));
});

test('snapshots hand out the rows parsed for that transaction without another copy', async t => {
  const { ledger } = await fixture(t);
  await ledger.reserve(reservation());
  const clone = t.mock.method(globalThis, 'structuredClone');
  const first = await ledger.snapshot();
  first.requests[0].state = 'changed';
  assert.equal((await ledger.snapshot()).requests[0].state, 'reserved');
  assert.equal(clone.mock.calls.filter(call => Array.isArray(call.arguments[0]?.requests)).length, 0);
});

test('only a request that has not crossed the submission gate may be released', async t => {
  const { ledger } = await fixture(t);
  const { record } = await ledger.reserve(reservation());
  assert.equal((await ledger.releaseUnsent(record.rid, record.identity)).state, 'released');
  assert.equal((await ledger.beginSubmission(record.rid, record.identity)).started, false);
  assert.equal((await ledger.releaseUnsent(record.rid, record.identity)).state, 'released');
  assert.equal((await ledger.reserve(reservation(20_000_000))).created, true);
});

test('provider task identity is immutable and settlement is exactly once', async t => {
  const { ledger } = await fixture(t);
  const { record } = await ledger.reserve(reservation());
  const args = [record.rid, record.identity];
  await ledger.beginSubmission(...args);
  await ledger.markSubmitted(...args, 'task-review-1');
  await assert.rejects(ledger.markSubmitted(...args, 'task-review-2'), code('invalid_transition'));
  await ledger.settle(...args, { chargeMicros: 12_000_000, basis: 'estimate' });
  const before = await ledger.snapshot();
  await ledger.settle(...args, { chargeMicros: 12_000_000, basis: 'estimate' });
  assert.deepEqual(await ledger.snapshot(), before);
  await assert.rejects(ledger.settle(...args, { chargeMicros: 1, basis: 'provider-usage' }), code('settlement_conflict'));
  assert.equal((await ledger.reserve(reservation(8_000_000))).created, true);
  await assert.rejects(ledger.reserve(reservation(1)), code('budget_exceeded'));
});

test('actual overrun is recorded honestly and prevents later admission', async t => {
  const { ledger } = await fixture(t);
  const { record } = await ledger.reserve(reservation(1_000_000));
  await ledger.beginSubmission(record.rid, record.identity);
  await ledger.settle(record.rid, record.identity, { chargeMicros: 21_000_000, basis: 'provider-usage' });
  assert.equal((await ledger.snapshot()).requests[0].chargeMicros, 21_000_000);
  await assert.rejects(ledger.reserve(reservation(1)), code('budget_exceeded'));
});

test('midnight does not move or refund the previous submission day', async t => {
  const { directory } = await fixture(t);
  let milliseconds = Date.parse('2026-10-28T15:59:59Z');
  const ledger = createBudgetLedger(directory, { clock: () => milliseconds });
  const old = await ledger.reserve(reservation(20_000_000));
  await ledger.beginSubmission(old.record.rid, old.record.identity);
  milliseconds = Date.parse('2026-10-28T16:00:00Z');
  const next = await ledger.reserve(reservation(20_000_000));
  assert.equal(old.record.day, '2026-10-28');
  assert.equal(next.record.day, '2026-10-29');
  const state = await ledger.snapshot();
  assert.equal(state.requests[0].state, 'submission_unknown');
  assert.equal(state.requests[0].estimateMicros, 20_000_000);
});

test('policy change has a ledger revision CAS; lowering does not erase holds', async t => {
  const { ledger } = await fixture(t);
  const initial = await ledger.snapshot();
  await ledger.reserve(reservation());
  await assert.rejects(ledger.setDailyLimit(5_000_000, initial.revision), code('conflict'));
  const current = await ledger.snapshot();
  await ledger.setDailyLimit(5_000_000, current.revision);
  await assert.rejects(ledger.reserve(reservation(1)), code('budget_exceeded'));
  assert.equal((await ledger.snapshot()).requests.length, 1);
});

test('three independent processes cannot each spend the same remaining budget', async t => {
  const { directory, ledger } = await fixture(t);
  const results = await Promise.all([1, 2, 3].map(() => child('reserve', directory, reservation()).done));
  for (const result of results) assert.equal(result.rows.length, 1, JSON.stringify(result));
  assert.equal(results.filter(r => r.code === 0 && r.rows[0].result.created).length, 1);
  assert.equal(results.filter(r => r.code === 2 && r.rows[0].code === 'budget_exceeded').length, 2);
  assert.equal((await ledger.snapshot()).requests.length, 1);
});

test('two independent processes sharing a rid reserve once and cross the submit gate once', async t => {
  const { directory, ledger } = await fixture(t);
  const input = reservation();
  const reserves = await Promise.all([1, 2].map(() => child('reserve', directory, input).done));
  for (const result of reserves) assert.equal(result.rows.length, 1, JSON.stringify(result));
  assert.deepEqual(reserves.map(r => r.rows[0].result.created).sort(), [false, true]);
  const record = (await ledger.snapshot()).requests[0];
  const submits = await Promise.all([1, 2].map(() => child('begin', directory, record).done));
  for (const result of submits) assert.equal(result.rows.length, 1, JSON.stringify(result));
  assert.deepEqual(submits.map(r => r.rows[0].result.started).sort(), [false, true]);
  assert.equal((await readdir(directory)).filter(name => name.startsWith('transport-gate-')).length, 1);
});

test('SIGKILL after durable intent leaves an unknown hold and cannot authorize resubmission', async t => {
  const { directory, ledger } = await fixture(t);
  const { record } = await ledger.reserve(reservation());
  const running = child('hold-intent', directory, record);
  t.after(() => running.process.kill('SIGKILL'));
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('child checkpoint timeout')), 8000);
    running.process.stdout.on('data', data => {
      if (String(data).includes('intent:durable')) { clearTimeout(timer); resolve(); }
    });
    running.process.on('error', reject);
  });
  running.process.kill('SIGKILL');
  const killed = await running.done;
  assert.equal(killed.signal, 'SIGKILL');
  const resumed = createBudgetLedger(directory, { clock: () => now });
  assert.equal((await resumed.beginSubmission(record.rid, record.identity)).started, false);
  await assert.rejects(resumed.releaseUnsent(record.rid, record.identity), code('submission_may_have_happened'));
  assert.equal((await readdir(directory)).filter(name => name.startsWith('transport-gate-')).length, 0);
});

test('an error after rename is uncertain, does not return a successful transport gate', async t => {
  const { directory, ledger } = await fixture(t);
  const { record } = await ledger.reserve(reservation());
  const failing = createBudgetLedger(directory, { clock: () => now, checkpoint: async point => {
    if (point === 'intent:renamed') throw new Error('synthetic failure');
  } });
  await assert.rejects(failing.beginSubmission(record.rid, record.identity), code('commit_uncertain'));
  assert.equal((await ledger.beginSubmission(record.rid, record.identity)).started, false);
});

test('missing or corrupt established state fails closed instead of resetting budget', async t => {
  for (const mode of ['missing', 'invalid-json', 'public-mode', 'symlink', 'wrong-instance', 'oversize']) {
    await t.test(mode, async t => {
      const { outer, directory, ledger } = await fixture(t);
      await ledger.reserve(reservation());
      const filename = join(directory, 'ledger-v1.json');
      if (mode === 'missing') await unlink(filename);
      if (mode === 'invalid-json') await writeFile(filename, '{');
      if (mode === 'public-mode') await chmod(filename, 0o644);
      if (mode === 'symlink') {
        const target = join(outer, 'external'); await writeFile(target, '{}', { mode: 0o600 });
        await unlink(filename); await symlink(target, filename);
      }
      if (mode === 'wrong-instance') {
        const current = JSON.parse(await readFile(filename, 'utf8')); current.instanceId = randomUUID();
        await writeFile(filename, JSON.stringify(current));
      }
      if (mode === 'oversize') await writeFile(filename, ' '.repeat(8 * 1024 * 1024 + 1));
      await assert.rejects(ledger.snapshot(), code('corrupt'));
    });
  }
});

test('ledger and initialization marker are private, and secrets are not accepted descriptor fields', async t => {
  const { directory, ledger } = await fixture(t);
  await ledger.reserve(reservation());
  for (const name of ['ledger-v1.json', 'initialized-v1.json']) {
    assert.equal((await stat(join(directory, name))).mode & 0o777, 0o600);
  }
  await assert.rejects(ledger.reserve({ ...reservation(), request: { ...request(), apiKey: 'synthetic-secret' } }), code('invalid_record'));
  const stored = await readFile(join(directory, 'ledger-v1.json'), 'utf8');
  assert.equal(stored.includes('synthetic-secret'), false);
});

test('successor syncs the full ancestor chain after creator dies immediately after recursive mkdir', async t => {
  const { directory } = await fixture(t);
  const input = reservation();
  const creator = child('hold-mkdir', directory, input, directoryWorker);
  t.after(() => creator.process.kill('SIGKILL'));
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('mkdir checkpoint timeout')), 8000);
    creator.process.stdout.on('data', data => {
      if (String(data).includes('mkdir-returned')) { clearTimeout(timer); resolve(); }
    });
    creator.process.on('error', reject);
  });
  creator.process.kill('SIGKILL');
  assert.equal((await creator.done).signal, 'SIGKILL');
  const successor = await child('trace-sync', directory, input, directoryWorker).done;
  assert.equal(successor.code, 0, JSON.stringify(successor));
  const result = successor.rows[0];
  assert.equal(result.started, true);
  for (let path = directory; ; path = dirname(path)) {
    assert.ok(result.synced.includes(path), `missing directory durability barrier: ${path}`);
    if (dirname(path) === path) break;
  }
});

test('an unavailable ancestor sync fails before reserving or authorizing a submission', async t => {
  const { directory } = await fixture(t);
  const failed = await child('deny-ancestor-sync', directory, reservation(), directoryWorker).done;
  assert.equal(failed.code, 2, JSON.stringify(failed));
  assert.equal(failed.rows[0].code, 'durability_unavailable');
  assert.equal(failed.rows[0].started, undefined);
  assert.equal((await readdir(directory)).includes('ledger-v1.json'), false);
});
