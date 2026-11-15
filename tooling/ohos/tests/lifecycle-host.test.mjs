import test, { after, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { loadHostModules, timers, tickRetry, permission } from './lifecycle-host-fixture.mjs';

const modules = await loadHostModules(process.env.DSH_LIFECYCLE_ETS_SOURCE);
const { RuntimeLifecycle, LifecycleFailure, backgroundComputePermission } = modules;
after(() => modules.close());
const models = [];
afterEach(() => {
  for (const model of models.splice(0)) model.runtime(null, null);
  assert.equal(timers.size, 0, 'stopping leaves no retry timer');
});
const flush = async () => { await Promise.resolve(); await Promise.resolve(); };
function setup(value = 'unknown') {
  const sends = []; let queries = 0, cancels = 0;
  const source = { value };
  const transport = { cancel() { cancels++; }, send(baseUrl, token, observation) {
    const pending = Promise.withResolvers(); sends.push({ baseUrl, token, observation, ...pending }); return pending.promise;
  } };
  const model = new RuntimeLifecycle(transport, () => { queries++; return source.value; }); models.push(model);
  return { model, sends, source, get queries() { return queries; }, get cancels() { return cancels; } };
}
const start = model => model.runtime('http://127.0.0.1:12345', 'fixture-launch-token');

test('early ability observations and remote-only status do not query permissions or load/send to a host', () => {
  const f = setup(); f.model.observe(true); f.model.observe(false);
  for (let i = 0; i < 30; i++) f.model.status();
  assert.equal(f.queries, 0); assert.equal(f.sends.length, 0); assert.equal(timers.size, 0);
  assert.equal(f.model.status().get('foreground'), false);
});
test('a late local engine receives only the latest observation; polling does not duplicate it', async () => {
  const f = setup('denied'); f.model.observe(true); f.model.observe(false); start(f.model);
  for (let i = 0; i < 100; i++) start(f.model);
  assert.equal(f.sends.length, 1); assert.equal(f.queries, 1);
  assert.deepEqual(f.sends[0].observation, { revision: 3, foreground: false, computePermission: 'denied' });
  f.sends[0].resolve(); await flush(); assert.equal(f.model.status().get('acknowledgedRevision'), 3);
});
test('a delayed old foreground acknowledgement cannot overwrite a newer background observation', async () => {
  const f = setup(); f.model.observe(true); start(f.model); f.model.observe(false);
  assert.equal(f.sends.length, 2);
  f.sends[1].resolve(); await flush(); f.sends[0].resolve(); await flush();
  assert.equal(f.model.status().get('acknowledgedRevision'), 3);
  assert.equal(f.model.status().get('foreground'), false);
});
test('late rejection after a new revision never leaks its raw error or schedules an old retry', async () => {
  const f = setup(); start(f.model); f.model.observe(true);
  f.sends[0].reject(new Error('fixture-secret-do-not-return')); await flush();
  assert.equal(f.model.status().get('error'), null); assert.equal(timers.size, 0);
  f.sends[1].resolve(); await flush(); assert.equal(f.model.status().get('acknowledgedRevision'), 2);
});
test('engine stop cancels transport ownership and ignores its late successful completion', async () => {
  const f = setup(); start(f.model); const before = f.cancels; f.model.runtime(null, null);
  assert(f.cancels > before); f.sends[0].resolve(); await flush();
  assert.equal(f.model.status().get('acknowledgedRevision'), null); assert.equal(timers.size, 0);
});
test('transient control failure retries the same observation, keeps one timer and recovers without a UI event', async () => {
  const f = setup('denied'); start(f.model);
  f.sends[0].reject(new LifecycleFailure('ohos_lifecycle_unavailable')); await flush();
  assert.equal(f.model.status().get('error'), 'ohos_lifecycle_unavailable');
  assert.equal(timers.size, 1); f.source.value = 'granted';
  assert.equal(tickRetry(), 1000); assert.equal(f.sends.length, 2);
  assert.deepEqual(f.sends[1].observation, f.sends[0].observation);
  assert.equal(f.queries, 1, 'same revision cannot silently change its permission claim');
  f.sends[1].resolve(); await flush();
  assert.equal(f.model.status().get('error'), null); assert.equal(f.model.status().get('acknowledgedRevision'), 1);
  assert.equal(timers.size, 0);
});
test('repeated failures back off to a bound; new observation cancels the old timer and resets the delay', async () => {
  const f = setup(); start(f.model); const delays = [];
  for (let i = 0; i < 8; i++) {
    f.sends.at(-1).reject(new Error('credential-looking-fixture')); await flush();
    assert.equal(timers.size, 1); assert.equal(f.model.status().get('error'), 'ohos_lifecycle_unavailable');
    delays.push(tickRetry());
  }
  assert.deepEqual(delays, [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000]);
  f.sends.at(-1).reject(new Error('temporary')); await flush();
  f.model.observe(true); assert.equal(timers.size, 0);
  f.sends.at(-1).reject(new Error('temporary')); await flush(); assert.equal(tickRetry(), 1000);
});
test('polling during an outstanding retry keeps the failure visible until a current acknowledgement arrives', async () => {
  const f = setup(); start(f.model);
  f.sends[0].reject(new LifecycleFailure('ohos_lifecycle_unavailable')); await flush();
  tickRetry();
  assert.equal(f.model.status().get('error'), 'ohos_lifecycle_unavailable');
  assert.equal(f.model.failureCode(), 'ohos_lifecycle_unavailable');
  f.model.observe(true);
  f.sends[1].resolve(); await flush();
  assert.equal(f.model.status().get('error'), 'ohos_lifecycle_unavailable', 'stale retry ack cannot clear the failure');
  f.sends[2].resolve(); await flush();
  assert.equal(f.model.status().get('error'), null);
});
test('stopping while backoff is armed clears it and prevents any extra permission/network operation', async () => {
  const f = setup(); start(f.model); f.sends[0].reject(new Error('transient')); await flush();
  assert.equal(timers.size, 1); f.model.runtime(null, null); assert.equal(timers.size, 0);
  assert.equal(f.sends.length, 1); assert.equal(f.queries, 1);
});
test('public eligibility query distinguishes prerequisite denial from unsupported or failed observation', () => {
  const reset = () => Object.assign(permission, { grants: 0, modes: 0, status: 0, supported: true,
    accessCapability: true, backgroundCapability: true, error: null, requestedModes: null });
  reset(); assert.equal(backgroundComputePermission(42), 'granted');
  assert.deepEqual(permission.last, { id: 42, name: 'ohos.permission.KEEP_BACKGROUND_RUNNING' });
  assert.deepEqual(permission.requestedModes, [9]); assert.equal(permission.modes, 1);
  reset(); permission.status = -1; assert.equal(backgroundComputePermission(42), 'denied'); assert.equal(permission.modes, 0);
  reset(); permission.supported = false; assert.equal(backgroundComputePermission(42), 'denied');
  reset(); permission.backgroundCapability = false; assert.equal(backgroundComputePermission(42), 'unknown');
  reset(); permission.accessCapability = false; assert.equal(backgroundComputePermission(42), 'unknown'); assert.equal(permission.grants, 0);
  reset(); permission.error = Object.assign(new Error('ACL/mode/config'), { code: 9800005 });
  assert.equal(backgroundComputePermission(42), 'unknown');
  reset(); permission.status = 999; assert.equal(backgroundComputePermission(42), 'unknown'); assert.equal(permission.modes, 0);
});
