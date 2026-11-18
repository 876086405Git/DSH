import test from 'node:test';
import assert from 'node:assert/strict';
import { createNativeGuestChannel } from '../../../runtime/ios/guest/native-channel.mjs';
const request = { mounts: [{ host: '/work', guest: '/workspace' }, { host: '/temp', guest: '/tmp' }],
  mode: 'read-only', cwd: '/workspace', argv: ['/bin/sh', '-c', 'printf x'], env: {}, stdin: '' };
function fixture({ signalError, stdinError, state = 'ready' } = {}) {
  let callback, acknowledgements = 0, writes = 0;
  const native = { start(_, cb) { callback = cb; return 1n; }, status() { return { state }; },
    ack() { acknowledgements++; }, stdinClose() {}, stdinWrite(_, bytes) { writes++; if (stdinError) throw stdinError; return bytes.length; },
    cancel() { if (signalError) throw signalError; }, kill() { if (signalError) throw signalError; }, abandon() {} };
  return { channel: createNativeGuestChannel(native, { root: '/rootfs' }),
    event(type, extra = {}) { callback({ id: 1n, type, ...extra }); },
    get acknowledgements() { return acknowledgements; }, get writes() { return writes; } };
}
const exit = { error: 0, exitCode: 137, abandoned: true, resourcesSettled: true };
test('explicit signal waits for the actual consumer without a fabricated ACK', async () => {
  for (const signal of ['SIGTERM', 'SIGKILL']) {
    const f = fixture(), gate = Promise.withResolvers();
    const operation = f.channel.exec(request, async () => gate.promise);
    f.event('stdout', { data: Buffer.from('x'), end: 1n });
    await Promise.resolve();
    operation.signal(signal); f.event('exit', exit);
    let finished = false; operation.finished.then(() => { finished = true; });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(finished, false); assert.equal(f.acknowledgements, 0);
    gate.resolve(); assert.equal((await operation.finished).resourcesSettled, true);
    assert.equal(f.acknowledgements, 0);
  }
});
test('failed or absent signal never authorizes abandonment', async () => {
  for (const fail of [false, true]) {
    const f = fixture({ signalError: fail ? new Error('signal refused') : undefined });
    const operation = f.channel.exec(request, async () => {});
    if (fail) assert.throws(() => operation.signal('SIGTERM'), /signal refused/);
    f.event('exit', exit);
    await assert.rejects(operation.finished, /not cleanly settled/);
  }
});
test('signal cannot override missing settlement or quarantine', async () => {
  for (const state of ['unsettled', 'quarantined']) {
    const f = fixture({ state: state === 'quarantined' ? state : 'ready' });
    const operation = f.channel.exec(request, async () => {});
    operation.signal('SIGKILL');
    f.event('exit', { ...exit, resourcesSettled: state !== 'unsettled' });
    await assert.rejects(operation.finished, /not cleanly settled/);
  }
});
test('a consumer rejection after native exit remains a rejection', async () => {
  const f = fixture(), gate = Promise.withResolvers();
  const operation = f.channel.exec(request, async () => gate.promise);
  f.event('stdout', { data: Buffer.from('x'), end: 1n }); await Promise.resolve();
  operation.signal('SIGTERM'); f.event('exit', exit); gate.reject(new Error('sink rejected'));
  await assert.rejects(operation.finished, /sink rejected/); assert.equal(f.acknowledgements, 0);
});
test('successful signal stops a pending EAGAIN stdin retry', async () => {
  const f = fixture({ stdinError: Object.assign(new Error('would block'), { errno: 11 }) });
  const operation = f.channel.exec({ ...request, stdin: 'pending bytes' }, async () => {});
  f.event('started'); assert.equal(f.writes, 1);
  operation.signal('SIGTERM');
  await new Promise(resolve => setTimeout(resolve, 25)); assert.equal(f.writes, 1);
  f.event('exit', exit); assert.equal((await operation.finished).resourcesSettled, true);
});
test('an unrelated stdin EPIPE still rejects the operation', async () => {
  const f = fixture({ stdinError: Object.assign(new Error('broken input pipe'), { errno: 32 }) });
  const operation = f.channel.exec({ ...request, stdin: 'pending bytes' }, async () => {});
  f.event('started'); await assert.rejects(operation.finished, /broken input pipe/);
  assert.equal(f.writes, 1);
});
