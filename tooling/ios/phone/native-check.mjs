import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { Worker } from 'node:worker_threads';
const test = process._linkedBinding('dsh_ios_phone_test');
const binding = process._linkedBinding('dsh_ios_phone');
const first = randomUUID(), second = randomUUID(), token = randomBytes(32).toString('hex');
assert.equal(test.arm(first, token), 0);
assert.equal(test.arm(second, token), 1, 'cannot overwrite active generation');
assert.throws(() => binding.consume(second));
assert.throws(() => binding.consume(first + 'extra'), /Invalid/);
test.clear(second); // wrong generation cannot revoke current
assert.equal(binding.consume(first), token);
assert.throws(() => binding.consume(first));
test.clear(first);
assert.equal(test.arm(second, token), 0); test.clear(second);
assert.throws(() => binding.consume(second));
// Exercise real Environment cleanup: old Worker consumes, Swift-like owner
// retires it and arms a new generation; old Worker cleanup must preserve new slot.
const old = randomUUID(), fresh = randomUUID();
assert.equal(test.arm(old, token), 0);
const worker = new Worker(`const {parentPort,workerData}=require('node:worker_threads');
process._linkedBinding('dsh_ios_phone').consume(workerData);
parentPort.postMessage('consumed');parentPort.on('message',()=>process.exit(0));`, { eval: true, workerData: old });
await new Promise(resolve => worker.once('message', resolve));
test.clear(old); assert.equal(test.arm(fresh, token), 0);
const exited = new Promise(resolve => worker.once('exit', resolve)); worker.postMessage('exit'); await exited;
assert.equal(binding.consume(fresh), token); test.clear(fresh);
console.log('PASS real C arm/clear + Node linkedBinding: one-shot, mismatch/retirement, overwrite refusal, old Environment cleanup preserves fresh generation; no secret output or files');
