import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { installPublication, publicationSymbol } from '../../ohos/publication/index.mjs';
import { engineFixture } from './lifecycle-engine-fixture.mjs';

let privateHome;
before(async () => {
  privateHome = await fs.mkdtemp(join(tmpdir(), 'lifecycle-engine-home-'));
  process.env.DSH_HOME = privateHome;
  await installPublication();
});
after(async () => {
  // The actual publication owner intentionally lives until process exit.
  assert.equal(globalThis[publicationSymbol]?.pendingCount, 0);
  await fs.rm(privateHome, { recursive: true, force: true });
});
async function fixture(t, options = {}) {
  const root = await fs.mkdtemp(join(tmpdir(), 'lifecycle-engine-'));
  const f = await engineFixture({ root, ...options });
  t.after(async () => { await f.close(); await fs.rm(root, { recursive: true, force: true }); });
  return f;
}

test('cold history indexing preserves duplicate-result and first-sequence identity failures', async t => {
  for (const scenario of ['duplicate-result', 'first-sequence-not-call']) await t.test(scenario, async t => {
    const f = await fixture(t), owner = await f.create();
    f.register('effect', async () => [{ type: 'text', text: 'durable result' }]);
    await owner.run([{ id: 'indexed-call' }]);
    const persisted = await f.readEvents(owner.session.id);
    const call = persisted.find(event => event.type === 'tool/call');
    const result = persisted.find(event => event.type === 'tool/result');
    const damaged = scenario === 'duplicate-result'
      ? [...persisted, { ...result, seq: persisted.length }]
      : [{ ...call, type: 'step/start' }, ...persisted];
    assert.deepEqual(await f.coordinator.reconcileCold(owner.session.id, damaged, []), []);
    const status = await f.coordinator.recoveredCommitted(owner.session.id, damaged);
    assert.equal(status.state, 'result-unknown');
    assert.equal(status.calls[0].reconciliation.basis, 'session-identity-mismatch');
    await assert.rejects(f.coordinator.gate(owner.session.id), { code: 'ERR_OHOS_LIFECYCLE_RESULT_UNKNOWN' });
  });
});

test('actual pinned AgentLoop, ToolRuntime and JSONL persist all four boundaries before claiming completion', async t => {
  const f = await fixture(t), owner = await f.create();
  f.register('effect', async () => {
    assert.equal(f.journal.records.at(-1).body.kind, 'dispatch');
    const fileRows = (await fs.readFile(join(f.root, 'boundary/boundary.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
    assert.equal(fileRows.at(-1).body.kind, 'dispatch');
    assert.equal((await f.readEvents(owner.session.id)).at(-1).type, 'tool/call');
    await fs.writeFile(join(f.root, 'workspace/effect.txt'), 'effect once');
    return [{ type: 'text', text: 'final 中文' }];
  });
  await owner.run([{ id: 'same-call-id' }]);
  assert.equal(await fs.readFile(join(f.root, 'workspace/effect.txt'), 'utf8'), 'effect once');
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['header', 'prepared', 'dispatch', 'returned', 'outcome', 'committed']);
  const records = await f.readEvents(owner.session.id), call = records.find(row => row.type === 'tool/call'), result = records.find(row => row.type === 'tool/result');
  assert.deepEqual(result.sourceEventSeqs, [call.seq]);
  assert.equal(result.data.message.content[0].text, 'final 中文');
  assert.equal(f.coordinator.status(owner.session.id).state, 'completed');
  assert.equal(f.coordinator.status(owner.session.id).calls[0].active, false);
});

test('fast B remains live while original ordered finalization waits for A; C is admitted without a false unknown', async t => {
  const aEntered = Promise.withResolvers(), releaseA = Promise.withResolvers(), cEntered = Promise.withResolvers();
  const stages = [];
  const f = await fixture(t, { onStage(kind, body) { stages.push([kind, body.identity?.callId]); } });
  const owner = await f.create();
  f.register('effect', async ({ label }) => {
    if (label === 'A') { aEntered.resolve(); await releaseA.promise; }
    if (label === 'C') cEntered.resolve();
    await fs.appendFile(join(f.root, 'workspace/order'), label);
    return [{ type: 'text', text: label }];
  }, { isConcurrencySafe: () => true });
  const pending = owner.run(['A', 'B', 'C'].map(label => ({ id: label, arguments: { label } })));
  await aEntered.promise; await cEntered.promise;
  assert.equal(f.coordinator.status(owner.session.id).state, 'running');
  assert(stages.some(([kind, id]) => kind === 'returned' && id === 'B'));
  assert(!stages.some(([kind]) => kind === 'outcome'));
  releaseA.resolve(); await pending;
  assert.deepEqual(stages.filter(([kind]) => kind === 'outcome').map(([, id]) => id), ['A', 'B', 'C']);
  const results = (await f.readEvents(owner.session.id)).filter(row => row.type === 'tool/result');
  assert.deepEqual(results.map(row => row.data.message.content[0].text), ['A', 'B', 'C']);
  assert.equal(f.coordinator.status(owner.session.id).state, 'completed');
});

test('actual session flush rejection is visible and prevents any tool body or dispatch journal entry', async t => {
  const f = await fixture(t), owner = await f.create(); let effects = 0;
  f.register('effect', async () => { effects++; return [{ type: 'text', text: 'must not run' }]; });
  const failure = Object.assign(new Error('checkpoint fixture rejected durable admission'), { code: 'EIO' });
  const off = f.ctx.on('session/flush', () => { throw failure; });
  try { await assert.rejects(owner.run([{ id: 'flush-failure' }])); }
  finally { off(); }
  assert.equal(effects, 0); assert.equal(f.journal.records.length, 1);
  assert.equal(f.coordinator.status(owner.session.id).blocked, true);
});

test('real short journal write after prepared poisons admission and the original tool never executes', async t => {
  let armed = false, effects = 0;
  const f = await fixture(t, { onStage(kind) { if (kind === 'prepared') armed = true; }, journalOptions: { fs: { ...fs, async open(path, ...args) {
    const handle = await fs.open(path, ...args);
    if (!String(path).endsWith('boundary.jsonl')) return handle;
    return new Proxy(handle, { get(target, key) {
      if (key === 'write') return async (bytes, offset, length, position) => {
        if (!armed) return target.write(bytes, offset, length, position);
        await target.write(bytes, offset, Math.min(9, length), position);
        throw Object.assign(new Error('real partial dispatch record then EIO'), { code: 'EIO' });
      };
      const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
    } });
  } } } });
  const owner = await f.create();
  f.register('effect', async () => { effects++; return [{ type: 'text', text: 'must not run' }]; });
  await assert.rejects(owner.run([{ id: 'dispatch-write-failure' }]), { code: 'EIO' });
  assert.equal(effects, 0); assert.equal(f.journal.records.at(-1).body.kind, 'prepared');
  assert.equal(f.coordinator.status(owner.session.id).blocked, true);
});

test('same callId and same callSeq in two real sessions never share results', async t => {
  const f = await fixture(t), a = await f.create('session-A'), b = await f.create('session-B');
  f.register('effect', async (_args, exec) => {
    await fs.writeFile(join(f.root, 'workspace', exec.agent.session.id), exec.agent.session.id);
    return [{ type: 'text', text: exec.agent.session.id }];
  });
  await a.run([{ id: 'same' }]); await b.run([{ id: 'same' }]);
  const ca = f.coordinator.status(a.session.id).calls[0], cb = f.coordinator.status(b.session.id).calls[0];
  assert.equal(ca.callSeq, cb.callSeq); assert.equal(ca.callId, cb.callId);
  for (const owner of [a, b]) {
    const stored = await f.coordinator.result(owner.session.id, ca.callSeq);
    assert.equal(stored.result.content[0].text, owner.session.id);
    assert.equal(stored.identity.sessionId, owner.session.id);
  }
});

test('cancel stays cancelling until the actual downstream promise finishes cleanup; it preserves the single result', async t => {
  const f = await fixture(t), owner = await f.create();
  const entered = Promise.withResolvers(), sawAbort = Promise.withResolvers(), cleanup = Promise.withResolvers();
  f.register('effect', async (_args, exec) => {
    await fs.appendFile(join(f.root, 'workspace/side-effect'), 'once\n');
    exec.signal.addEventListener('abort', () => sawAbort.resolve(), { once: true });
    entered.resolve(); await cleanup.promise;
    return [{ type: 'text', text: 'completed cleanup' }];
  });
  const work = owner.run([{ id: 'cancel-live' }]); await entered.promise;
  let joined = false;
  const cancellation = f.coordinator.cancel(owner.session.id).then(status => { joined = true; return status; });
  await sawAbort.promise;
  assert.equal(joined, false); assert.equal(f.coordinator.status(owner.session.id).state, 'cancelling');
  cleanup.resolve(); await work; const status = await cancellation;
  assert.equal(status.state, 'terminated'); assert.equal(status.calls[0].phase, 'committed');
  assert.equal(await fs.readFile(join(f.root, 'workspace/side-effect'), 'utf8'), 'once\n');
  assert.equal((await f.readEvents(owner.session.id)).filter(event => event.type === 'tool/result').length, 1);
});

test('new dispatch cannot overtake a durable cancel request while no older call is active', async t => {
  const reached = Promise.withResolvers(), release = Promise.withResolvers(); let effects = 0;
  const f = await fixture(t, { async onStage(kind) { if (kind === 'cancel') { reached.resolve(); await release.promise; } } });
  const owner = await f.create();
  f.register('effect', async () => { effects++; return [{ type: 'text', text: 'forbidden' }]; });
  const cancellation = f.coordinator.cancel(owner.session.id); await reached.promise;
  assert.equal(f.coordinator.status(owner.session.id).state, 'cancelling');
  await assert.rejects(owner.run([{ id: 'cancel-race' }]), { code: 'ERR_OHOS_LIFECYCLE_CANCELLED' });
  assert.equal(effects, 0); release.resolve(); await cancellation;
  assert.equal(f.coordinator.status(owner.session.id).blocked, false);
});

test('acknowledging an unknown cannot reopen admission while a durable cancellation is still joining', async t => {
  const reached = Promise.withResolvers(), release = Promise.withResolvers();
  let effects = 0, joined = false;
  const f = await fixture(t, { async onStage(kind) {
    if (kind === 'cancel') { reached.resolve(); await release.promise; }
  } });
  const owner = await f.create();
  const effectPath = join(f.root, 'workspace/cancel-ack-effect');
  f.register('effect', async () => {
    effects++; await fs.appendFile(effectPath, 'forbidden\n');
    return [{ type: 'text', text: 'must not run before cancellation joins' }];
  });
  const cancellation = f.coordinator.cancel(owner.session.id).then(status => { joined = true; return status; });
  let ackError, dispatchError, beforeRelease, finalStatus;
  try {
    await reached.promise;
    assert.equal(f.coordinator.status(owner.session.id).state, 'cancelling');
    try { await f.coordinator.acknowledgeUnknown(owner.session.id); }
    catch (error) { ackError = error; }
    try { await owner.run([{ id: 'after-ack-before-cancel-join' }]); }
    catch (error) { dispatchError = error; }
    beforeRelease = { joined, effects, state: f.coordinator.status(owner.session.id).state,
      ackError: ackError?.code, dispatchError: dispatchError?.code };
    t.diagnostic(JSON.stringify(beforeRelease));
  } finally {
    release.resolve(); finalStatus = await cancellation;
  }
  assert.equal(effects, 0, 'no tool body may start until the durable cancellation has joined');
  assert.equal(beforeRelease.joined, false);
  assert.equal(beforeRelease.state, 'cancelling');
  assert.equal(ackError?.code, 'ERR_OHOS_LIFECYCLE_STILL_RUNNING');
  assert.equal(dispatchError?.code, 'ERR_OHOS_LIFECYCLE_CANCELLED');
  assert.equal(finalStatus.state, 'terminated');
  await assert.rejects(fs.access(effectPath), { code: 'ENOENT' });
  await f.coordinator.acknowledgeUnknown(owner.session.id);
});

test('a prepared checkpoint completing after cancel cannot clear the active cancellation admission gate', async t => {
  const flushing = Promise.withResolvers(), releaseFlush = Promise.withResolvers();
  const cancelling = Promise.withResolvers(), releaseCancel = Promise.withResolvers();
  let firstFlush = true, effects = 0, joined = false, f;
  f = await fixture(t, {
    async flushSession(session) {
      if (firstFlush) { firstFlush = false; flushing.resolve(); await releaseFlush.promise; }
      return f.ctx.sessions.flush(session);
    },
    async onStage(kind) {
      if (kind === 'cancel') { cancelling.resolve(); await releaseCancel.promise; }
    },
  });
  const owner = await f.create();
  f.register('effect', async () => {
    effects++; await fs.appendFile(join(f.root, 'workspace/prepared-after-cancel'), 'forbidden\n');
    return [{ type: 'text', text: 'must not run after cancel admission' }];
  });
  const work = owner.run([{ id: 'prepared-after-cancel' }]).then(
    () => ({ fulfilled: true }), error => ({ fulfilled: false, code: error.code }));
  await flushing.promise;
  const cancellation = f.coordinator.cancel(owner.session.id).then(status => { joined = true; return status; });
  let result;
  try {
    await cancelling.promise;
    releaseFlush.resolve(); result = await work;
    t.diagnostic(JSON.stringify({ joined, effects, result, state: f.coordinator.status(owner.session.id).state }));
    assert.equal(joined, false);
  } finally {
    releaseFlush.resolve(); releaseCancel.resolve(); await work; await cancellation;
  }
  assert.equal(effects, 0, 'an earlier gate admission is not permission to dispatch after cancellation starts');
  assert.deepEqual(result, { fulfilled: false, code: 'ERR_OHOS_LIFECYCLE_CANCELLED' });
  await assert.rejects(fs.access(join(f.root, 'workspace/prepared-after-cancel')), { code: 'ENOENT' });
});
