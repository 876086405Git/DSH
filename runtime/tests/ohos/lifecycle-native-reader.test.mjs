// Real default N-API reader, with the existing always-foreground host carrier.
// Custom reader and durable-journal boundaries below are explicit fixtures.
import test, { beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { BoundaryCoordinator } from '../../ohos/lifecycle/coordinator.mjs';
import { readNativeHost, __nativeReaderValidationTrace as trace } from '../../ohos/lifecycle/native-host.mjs';
import { instrumentation, builtinIdentity } from './lifecycle-native-reader-instrument.mjs';

const snapshot = () => ({ version: 1, engineGeneration: 1, ownerGeneration: 1, revision: 1,
  grantGeneration: 0, nowMs: 1000, deadlineMs: 0, drainAtMs: 0, phase: 0,
  available: 1, foreground: 1, clockFailed: 0 });

function fixture(t, options = {}, append) {
  const records = [];
  const journal = { records, async append(body) {
    await append?.(body); const row = { body }; records.push(row); return row;
  }, async flush() {}, async close() {} };
  const coordinator = new BoundaryCoordinator({ journal, bootId: 'native-reader-test',
    flushSession: async () => true, readEvents: async () => [], ...options });
  t.after(() => coordinator.close());
  return { coordinator, records };
}

beforeEach(() => { trace.length = 0; });
afterEach(() => {
  assert.equal(Object.freeze, builtinIdentity.freeze);
  assert.equal(process._linkedBinding, builtinIdentity.linkedBinding);
  assert.equal(instrumentation.transforms, 1);
  trace.length = 0;
});

test('default real N-API snapshots are validated and frozen once per observation, never cached across calls', async t => {
  const { coordinator: c, records } = fixture(t);
  const counts = [], nativeInputs = [], snapshots = [];
  for (let i = 0; i < 2; i++) {
    trace.length = 0;
    let settled = false;
    const pending = c.observeHost({ foreground: false }, true);
    pending.then(() => { settled = true; });
    assert.equal(settled, false, 'the original Promise boundary remains asynchronous');
    assert(trace.length > 0, 'the original read/validation occurs before returning the Promise');
    const ack = await pending, actual = trace[0].input;
    assert.equal(Object.isFrozen(actual), false, 'the real N-API getter creates the raw record');
    assert.deepEqual(Object.keys(actual).sort(), Object.keys(snapshot()).sort());
    for (const descriptor of Object.values(Object.getOwnPropertyDescriptors(actual))) {
      assert.equal(typeof descriptor.value, 'number');
      assert.equal(descriptor.get, undefined);
    }
    assert.equal(ack.host.foreground, true, 'the HTTP hint is not native authority');
    assert.equal(ack.paused, false); assert.equal(ack.blocked, false);
    assert.equal(Object.isFrozen(ack.nativeHost), true);
    assert.equal(ack.nativeHost, trace.at(-1).output);
    assert.notEqual(ack.nativeHost, actual);
    counts.push({ validations: trace.length, frozenCopies: trace.filter(row => Object.hasOwn(row, 'output')).length });
    nativeInputs.push(actual); snapshots.push(ack.nativeHost);
  }
  assert.notEqual(nativeInputs[0], nativeInputs[1]);
  assert.notEqual(snapshots[0], snapshots[1]);
  assert.equal(records.length, 0);
  t.diagnostic(JSON.stringify({ instrumentation, counts, nativeCalls: nativeInputs.length,
    scope: 'explicit JS validation/frozen-copy count, not allocation/CPU/RSS/PSS' }));
  assert.deepEqual(counts, [{ validations: 1, frozenCopies: 1 }, { validations: 1, frozenCopies: 1 }]);
});

test('an explicitly supplied original default reader has the same single-validation path', async t => {
  const { coordinator: c } = fixture(t, { readHost: readNativeHost });
  const ack = await c.observeHost({}, true);
  assert.equal(ack.host.foreground, true);
  assert.equal(Object.isFrozen(ack.nativeHost), true);
  const counts = { validations: trace.length, frozenCopies: trace.filter(row => Object.hasOwn(row, 'output')).length };
  t.diagnostic(JSON.stringify(counts));
  assert.deepEqual(counts, { validations: 1, frozenCopies: 1 });
});

test('a bound default reader remains custom and its returned frozen object is revalidated', async t => {
  const { coordinator: c } = fixture(t, { readHost: readNativeHost.bind(undefined) });
  const ack = await c.observeHost({}, true);
  assert.equal(trace.length, 2);
  assert.equal(trace[1].input, trace[0].output);
  assert.equal(ack.nativeHost, trace[1].output);
  assert.notEqual(ack.nativeHost, trace[0].output);
  assert.equal(ack.host.foreground, true);
});

test('custom reader keeps its receiver, accessor counts, shallow aliasing and fresh frozen result', async t => {
  let readerCalls = 0, revision = 1;
  const reads = { revision: 0, phase: 0, extra: 0 }, shared = { marker: 1 };
  const input = snapshot();
  Object.defineProperties(input, {
    revision: { enumerable: true, get() { reads.revision++; return revision; } },
    phase: { enumerable: true, get() { reads.phase++; return 0; } },
    extra: { enumerable: true, get() { reads.extra++; return shared; } },
  });
  Object.freeze(input);
  let c;
  ({ coordinator: c } = fixture(t, { readHost: function () {
    assert.equal(this, c); readerCalls++; return input;
  } }));
  const first = await c.observeHost({}, true);
  assert.deepEqual(reads, { revision: 3, phase: 4, extra: 1 });
  assert.equal(readerCalls, 1); assert.equal(trace.length, 1);
  assert.notEqual(first.nativeHost, input); assert.equal(Object.isFrozen(first.nativeHost), true);
  assert.equal(first.nativeHost.extra, shared);
  shared.marker = 2; assert.equal(first.nativeHost.extra.marker, 2, 'the existing copy is shallow');
  revision = 2;
  const second = await c.observeHost({}, true);
  assert.deepEqual(reads, { revision: 6, phase: 8, extra: 2 });
  assert.equal(readerCalls, 2); assert.equal(trace.length, 2);
  assert.notEqual(first.nativeHost, second.nativeHost);
  assert.equal(first.nativeHost.revision, 1); assert.equal(second.nativeHost.revision, 2);
});

test('custom throw stays fail-closed and waits for the existing durable pause before ACK; next read can recover', async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  let broken = true, readerCalls = 0;
  const reason = new Error('explicit reader failure');
  const { coordinator: c, records } = fixture(t, { readHost() {
    readerCalls++; if (broken) throw reason; return snapshot();
  } }, async body => { if (body.kind === 'pause') { entered.resolve(); await release.promise; } });
  let settled = false;
  const pending = c.observeHost({}).then(value => { settled = true; return value; });
  try {
    assert.equal(readerCalls, 1); assert.equal(trace.length, 0);
    assert.equal(c.status().paused, true); assert.equal(c.status().nativeFailure, 'ERR_OHOS_LIFECYCLE_NATIVE');
    await entered.promise; assert.equal(settled, false);
  } finally { release.resolve(); }
  const failed = await pending;
  assert.equal(failed.nativeHost, null); assert.equal(failed.confirmedPause, true);
  assert.equal(failed.blocked, false);
  broken = false;
  const recovered = await c.observeHost({});
  assert.equal(recovered.nativeFailure, null); assert.equal(recovered.paused, false);
  assert.equal(trace.length, 1); assert.deepEqual(records.map(row => row.body.kind), ['pause', 'resume']);
});

test('an invalid frozen custom record is rejected and a later valid read is not cached out', async t => {
  let input = Object.freeze({ ...snapshot(), phase: 8 });
  const { coordinator: c, records } = fixture(t, { readHost: () => input });
  const failed = await c.observeHost({});
  assert.equal(failed.nativeHost, null); assert.equal(failed.nativeFailure, 'ERR_OHOS_LIFECYCLE_NATIVE');
  assert.equal(trace.length, 1); assert.equal(Object.hasOwn(trace[0], 'output'), false);
  input = snapshot();
  const recovered = await c.observeHost({});
  assert.equal(recovered.nativeFailure, null); assert.equal(recovered.paused, false);
  assert.equal(trace.length, 2); assert.equal(trace[1].input, input);
  assert.deepEqual(records.map(row => row.body.kind), ['pause', 'resume']);
});

test('custom Promise/thenable returns remain synchronous invalid snapshots, never awaited', async t => {
  let thenReads = 0;
  const thenable = { get then() { thenReads++; throw new Error('must not assimilate custom return'); } };
  for (const value of [Promise.resolve(snapshot()), thenable]) {
    const { coordinator: c } = fixture(t, { readHost: () => value });
    const count = trace.length;
    const pending = c.observeHost({});
    assert.equal(trace.length, count + 1);
    assert.equal(Object.hasOwn(trace.at(-1), 'output'), false);
    const failed = await pending;
    assert.equal(failed.nativeHost, null); assert.equal(failed.nativeFailure, 'ERR_OHOS_LIFECYCLE_NATIVE');
    assert.equal(failed.confirmedPause, true);
  }
  assert.equal(thenReads, 0);
});
