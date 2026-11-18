import test from 'node:test';
import assert from 'node:assert/strict';
import { Duplex } from 'node:stream';
import { setTimeout as delay } from 'node:timers/promises';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LinuxRuntimeBackend } from './source/runtime/ohos/linux/backend.mjs';

const epoch = '01'.repeat(32);
const clean = { rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' };
class Transport extends Duplex {
  commands = []; sequence = 0;
  _read() {}
  _write(bytes, _encoding, done) {
    for (const line of bytes.toString().trimEnd().split('\n')) this.commands.push(JSON.parse(line));
    done();
  }
  frame(kind, fields = {}) {
    this.push(Buffer.from('DSHG1 ' + JSON.stringify({ v: 1, epoch, seq: ++this.sequence,
      kind, job: null, ...fields }) + '\n'));
  }
}

// Only native/guest transport is doubled. Production backend/controller and
// real public OutputCollector dependencies are used. This is not VM evidence.
async function fixture(run, native = { joined: true, retirementError: false, apiResult: -4 }) {
  const root = await mkdtemp(join(tmpdir(), 'linux-clean-close-')), socket = new Transport();
  const calls = [];
  const backend = new LinuxRuntimeBackend({ configPath: '/trusted/config', epoch, temporaryRoot: root,
    closeTimeoutMs: 35 }, { createSession: () => ({ socket, requestStop() { calls.push('stop'); },
      async join() { calls.push('join'); return native; } }) });
  try {
    socket.frame('opened', { capabilities: { streamingStdin: true, pidNamespace: true, workspaceLease: false } });
    await backend.opened;
    await run({ backend, socket, calls });
  } finally { socket.destroy(); await rm(root, { recursive: true, force: true }); }
}

test('only the same-epoch synced closed yields an immutable guest close result', () => fixture(async f => {
  assert.equal(f.backend.guestClose, null);
  const pending = f.backend.dispose(); await delay(0);
  assert.equal(f.socket.commands.at(-1).op, 'close'); assert.deepEqual(f.calls, []);
  f.socket.frame('closed', clean);
  const result = await pending;
  assert.deepEqual(result.guestClose, { epoch, ...clean });
  assert.equal(result.guestClose, f.backend.guestClose); assert.ok(Object.isFrozen(result.guestClose));
  assert.throws(() => { f.backend.guestClose = { epoch: 'forged' }; }, TypeError);
  assert.deepEqual(f.calls, ['stop', 'join']); assert.equal(result.closed, true);
}));

for (const [label, fields] of [
  ['legacy closed with no sync fact', {}], ['false sync fact', { ...clean, rootfsSync: false }],
  ['non-boolean sync fact', { ...clean, rootfsSync: 'true' }],
  ['wrong sync method', { ...clean, syncMethod: 'sync' }],
  ['wrong filesystem scope', { ...clean, syncScope: 'tmpfs' }],
  ['wrong epoch', { ...clean, epoch: 'ff'.repeat(32) }],
  ['unexpected job identity', { ...clean, job: 1 }],
]) test(label + ' cannot become clean', () => fixture(async f => {
  const pending = f.backend.dispose(); await delay(0); f.socket.frame('closed', fields);
  await assert.rejects(pending, { code: 'ERR_OHOS_LINUX_UNKNOWN' });
  assert.equal(f.backend.guestClose, null); assert.equal(f.backend.state, 'quarantined');
  assert.deepEqual(f.calls, ['stop', 'join']);
}));

test('sync failure preserves errno and still retires native without inventing clean', () => fixture(async f => {
  const pending = f.backend.dispose(); await delay(0);
  f.socket.frame('close-failed', { ...clean, rootfsSync: false, code: 'ERR_OHOS_GUEST_SYNC', errno: 5 });
  await assert.rejects(pending, error => error.code === 'ERR_OHOS_LINUX_UNKNOWN' &&
    error.cause?.code === 'ERR_OHOS_LINUX_GUEST_SYNC' && error.cause.errno === 5);
  assert.equal(f.backend.guestClose, null); assert.deepEqual(f.calls, ['stop', 'join']);
}));

test('invalid sync-failure errno is rejected as protocol failure', () => fixture(async f => {
  const pending = f.backend.dispose(); await delay(0);
  f.socket.frame('close-failed', { ...clean, rootfsSync: false, code: 'ERR_OHOS_GUEST_SYNC', errno: 0 });
  await assert.rejects(pending, error => error.code === 'ERR_OHOS_LINUX_UNKNOWN' && error.cause?.code === 'ERR_OHOS_LINUX_PROTOCOL');
  assert.equal(f.backend.guestClose, null);
}));

test('a confirmed guest sync with failed native retirement is not successful disposal', () => fixture(async f => {
  const pending = f.backend.dispose(); await delay(0); f.socket.frame('closed', clean);
  await assert.rejects(pending, { code: 'ERR_OHOS_LINUX_UNKNOWN' });
  assert.deepEqual(f.backend.guestClose, { epoch, ...clean }); // Historical fact, not a successful return.
  assert.equal(f.backend.state, 'quarantined'); assert.deepEqual(f.calls, ['stop', 'join']);
}, { joined: true, retirementError: true, apiResult: -8 }));

test('a close timeout remains unconfirmed even if native later joins', () => fixture(async f => {
  await assert.rejects(f.backend.dispose(), error => error.code === 'ERR_OHOS_LINUX_UNKNOWN' &&
    error.cause?.code === 'ERR_OHOS_LINUX_CLOSE_UNCONFIRMED');
  assert.equal(f.backend.guestClose, null); assert.deepEqual(f.calls, ['stop', 'join']);
}));
