import assert from 'node:assert/strict';
import { Socket } from 'node:net';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { setTimeout as delay } from 'node:timers/promises';
import { once } from 'node:events';
const [library, config, mode] = isMainThread ? process.argv.slice(2) : workerData;
const openModule = () => { const module = { exports: {} }; process.dlopen(module, library); return module.exports; };
const until = async predicate => {
  const deadline = performance.now() + 3000;
  while (!predicate()) { assert.ok(performance.now() < deadline, 'lifecycle fixture watchdog'); await delay(2); }
};
if (!isMainThread) {
  const native = openModule(), owner = native.create(config);
  const socket = new Socket({ fd: owner.fd, readable: true, writable: true });
  socket.on('error', () => {}); socket.resume();
  await until(() => native.__ownerTestStats().longSelectCalls > 0);
  parentPort.postMessage({ ready: true, before: native.__ownerTestStats() });
  parentPort.on('message', () => {}); // The parent terminates this actual environment.
} else if (mode === 'worker-cleanup') {
  const worker = new Worker(new URL(import.meta.url), { workerData: [library, config, mode] });
  const [message] = await once(worker, 'message'); assert.equal(message.ready, true);
  assert.equal(message.before.notifications, 0); assert.equal(message.before.longSelectReturns, 0);
  const exitCode = await worker.terminate();
  const native = openModule();
  await until(() => native.__ownerTestStats().bodyReturned === 1);
  const after = native.__ownerTestStats();
  assert.equal(after.notifications, 1); assert.equal(after.joins, 0); assert.equal(after.workCalls, 0);
  assert.equal(after.longSelectReturns, 1); assert.equal(after.readCloses, 1); assert.equal(after.writeCloses, 0);
  assert.throws(() => native.create(config), { code: 'ERR_OHOS_LINUX_OWNER_QUARANTINED' });
  console.log(JSON.stringify({ mode, exitCode, before: message.before, after, joinedNotClaimed: true }));
} else {
  const native = openModule(); let owner = native.create(config);
  const socket = new Socket({ fd: owner.fd, readable: true, writable: true });
  socket.on('error', () => {}); socket.resume();
  await until(() => native.__ownerTestStats().longSelectCalls > 0);
  const before = native.__ownerTestStats(); assert.equal(before.notifications, 0); assert.equal(before.longSelectReturns, 0);
  const weak = new WeakRef(owner); owner = undefined;
  for (let n = 0; native.__ownerTestStats().notifications === 0 && n < 100; n++) {
    await new Promise(resolve => setImmediate(resolve)); global.gc(); await delay(2);
  }
  assert.equal(weak.deref(), undefined, 'the raw JS owner was actually collected');
  if (mode === 'gc-notify-failure') {
    await delay(20); const after = native.__ownerTestStats();
    assert.equal(after.notifications, 1); assert.equal(after.joins, 0); assert.equal(after.workCalls, 0);
    assert.equal(after.longSelectReturns, 0); assert.equal(after.bodyReturned, 0);
    console.log(JSON.stringify({ mode, before, after, unjoinedQuarantine: true }));
  } else {
    await until(() => native.__ownerTestStats().bodyReturned === 1);
    const after = native.__ownerTestStats();
    assert.equal(after.notifications, 1); assert.equal(after.joins, 0); assert.equal(after.workCalls, 0);
    assert.equal(after.longSelectReturns, 1); assert.equal(after.readCloses, 1); assert.equal(after.writeCloses, 0);
    console.log(JSON.stringify({ mode, before, after, joinedNotClaimed: true }));
  }
  assert.throws(() => native.create(config), { code: 'ERR_OHOS_LINUX_OWNER_QUARANTINED' });
  socket.destroy();
}
