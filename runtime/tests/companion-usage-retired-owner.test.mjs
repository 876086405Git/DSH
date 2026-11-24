import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { setImmediate } from 'node:timers/promises';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { createCompanionUsage } from '../bridge/dsh-go-bridge/lib/companion/usage.js';

async function collect() {
  for (let i = 0; i < 5; i++) {
    await setImmediate();
    global.gc();
  }
}

if (process.argv.includes('--check-retirement')) {
  const usage = createCompanionUsage({ instanceId: 'boot' });
  const prepare = (owner, requestId) => usage.prepare(owner, {
    sessionId: 'same-id', requestId, archiveId: 'archive', controlRevision: 0, historyAfterSeq: 0, preparedAt: 1,
  });
  const snapshot = requestId => usage.snapshot({ instanceId: 'boot', sessionId: 'same-id', requestId });
  const reference = (() => {
    const session = { id: 'same-id' };
    assert(prepare(session, 'one'));
    return new WeakRef(session);
  })();
  await collect();
  let session = reference.deref();
  assert.ok(session, 'an active receipt still owns its Session');
  assert(usage.claim(session, 'same-id', 'one', 1));
  usage.end(session, 1);
  usage.retire(session);
  const revision = snapshot('one').revision;
  usage.end({ id: 'same-id' }, 1);
  assert.equal(snapshot('one').revision, revision);
  usage.end(session, 1);
  assert(snapshot('one').revision > revision);
  usage.failed({}, 'same-id', ['one']);
  assert(!snapshot('one').gaps.includes('observer-error'));
  usage.failed(session, 'same-id', ['one']);
  assert(snapshot('one').gaps.includes('observer-error'));
  assert(prepare(session, 'one'), 'the original Session may reconcile an old binding');
  assert.equal(prepare({ id: 'same-id' }, 'one'), false);
  assert(snapshot('one').gaps.includes('binding-conflict'));
  assert(prepare(session, 'two'), 'the same Session may subsequently own a new request');
  usage.retire(session);
  usage.retire(session);
  const last = snapshot('two');
  assert.equal(last.state, 'settled');
  assert(last.gaps.includes('not-claimed'));
  session = undefined;
  await collect();
  assert.equal(reference.deref(), undefined, 'retained receipts must release the retired Session');
  assert.deepEqual(snapshot('two'), last, 'the closed receipt remains readable after collection');

  for (const [i, owner] of [null, undefined, Symbol('foreign'), () => {}].entries()) {
    const id = 'owner-' + i;
    usage.retire(owner);
    assert(prepare(owner, id));
    usage.retire(owner);
    assert(prepare(owner, id));
    assert.equal(prepare({}, id), false);
  }
} else {
  test('active and retired companion usage preserve owner identity and release retired sessions', () => {
    execFileSync(process.execPath, ['--expose-gc', fileURLToPath(import.meta.url), '--check-retirement']);
  });
}
