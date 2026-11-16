import assert from 'node:assert/strict';
import { Socket } from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';
import { readFile } from 'node:fs/promises';
const [library, config, mode] = process.argv.slice(2);
const module = { exports: {} }; process.dlopen(module, library);
const create = () => module.exports.create(config);
if (['second-pair', 'create-eagain', 'hook-fail', 'rollback-close'].includes(mode)) {
  assert.throws(create, { code: mode === 'rollback-close' ? 'ERR_OHOS_LINUX_CREATE_QUARANTINED' : 'ERR_OHOS_LINUX_CREATE' });
  if (mode === 'rollback-close') {
    assert.throws(create, { code: 'ERR_OHOS_LINUX_OWNER_QUARANTINED' });
    console.log(JSON.stringify({ mode, creationFailed: true, remainsClaimed: true }));
    process.exitCode = 0;
  }
}
if (mode !== 'rollback-close') {
  const owner = create();
  const socket = new Socket({ fd: owner.fd, readable: true, writable: true });
  socket.on('error', () => {});
  let output = ''; socket.on('data', bytes => { output += bytes; });
  if (mode !== 'already-returned') {
    const deadline = performance.now() + 3000;
    while (!output.includes('900-BEFORE-POWEROFF') && performance.now() < deadline) await delay(2);
    assert.match(output, /900-BEFORE-POWEROFF/);
  }
  assert.throws(() => owner.join(), { code: 'ERR_OHOS_LINUX_STOP_REQUIRED' });
  await readFile(config); // UV_THREADPOOL_SIZE=1 still services ordinary IO.
  assert.equal(owner.requestStop(), undefined);
  assert.equal(owner.requestStop(), undefined);
  if (mode === 'reference-fail') assert.throws(() => owner.join(), { code: 'ERR_OHOS_LINUX_JOIN' });
  const promise = owner.join(); assert.equal(owner.join(), promise);
  const timer = setTimeout(() => { throw new Error('test watchdog: join result did not settle'); }, 3000);
  const result = await promise; clearTimeout(timer);
  assert.equal(owner.join(), promise); assert.equal(owner.requestStop(), undefined);
  assert.equal(result.ownerQuarantined, true);
  assert.throws(create, { code: 'ERR_OHOS_LINUX_OWNER_QUARANTINED' });
  if (mode.startsWith('notify-e')) {
    assert.equal(result.joined, false); assert.equal(result.joinAttempted, false); assert.equal(result.joinError, null);
    assert.equal(result.stopNotification.attempted, true); assert.equal(result.stopNotification.notified, false);
    assert.equal(result.stopNotification.errorCode, mode === 'notify-eio' ? 5 : 4);
    for (const key of ['apiResult', 'fatalReason', 'retirementError', 'ramRetirement', 'waitError', 'fdRetirement']) assert.equal(result[key], null);
  } else if (['join-esrch', 'work-cancelled'].includes(mode)) {
    assert.equal(result.joined, false); assert.equal(result.joinAttempted, mode === 'join-esrch');
    assert.equal(result.joinError, mode === 'join-esrch' ? 3 : null);
    for (const key of ['apiResult', 'fatalReason', 'retirementError', 'ramRetirement', 'waitError', 'fdRetirement']) assert.equal(result[key], null);
  } else {
    assert.equal(result.joined, true); assert.equal(result.joinAttempted, true); assert.equal(result.joinError, 0);
    assert.equal(result.apiResult, mode === 'already-returned' ? -1 : -4);
    assert.equal(result.waitError, 0); assert.equal(result.retirementError, false);
    const fault = { 'peer-close': 'consoleError', 'reader-close': 'wakeReadError', 'writer-close': 'wakeWriteError', 'writer-reuse': 'wakeWriteError' }[mode];
    assert.equal(result.fdRetirement.retired, !fault);
    for (const key of ['consoleError', 'wakeReadError', 'wakeWriteError']) assert.equal(result.fdRetirement[key], key === fault ? 4 : 0);
    if (mode === 'already-returned') assert.deepEqual(result.stopNotification, { attempted: false, notified: false, unnecessary: true, errorCode: 0 });
    else assert.deepEqual(result.stopNotification, { attempted: true, notified: true, unnecessary: false, errorCode: 0 });
  }
  socket.destroy();
  console.log(JSON.stringify({ mode, result }));
}
