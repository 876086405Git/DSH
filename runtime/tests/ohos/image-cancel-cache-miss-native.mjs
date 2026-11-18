import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, writeFile } from 'node:fs/promises';
import { readFileSync, existsSync } from 'node:fs';
import { pbkdf2 } from 'node:crypto';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHook } from 'node:async_hooks';

const config = JSON.parse(await readFile(process.env.DSH_IMAGE_CANCEL_CACHE_MISS_CONFIG, 'utf8'));
test('cancelled missing-cache I/O does not start a new native encode and permits an immediate retry', async () => {
const url = value => pathToFileURL(value).href;
const hash = value => createHash('sha256').update(value).digest('hex');
const events = [];
const event = (type, fields = {}) => events.push({ type, ns: process.hrtime.bigint().toString(), ...fields });
const builtins = [Buffer, Buffer.from, Uint8Array, ArrayBuffer, readFile];
const promises = new WeakMap(), promisesById = new Map();
let cachePromiseRecord;
const promiseHook = createHook({
  init(asyncId, type, triggerAsyncId, resource) {
    if (type === 'PROMISE') {
      const record = { asyncId, resolveHookCalled: false };
      promises.set(resource, record); promisesById.set(asyncId, record);
    }
  },
  promiseResolve(asyncId) {
    const record = promisesById.get(asyncId);
    if (record) record.resolveHookCalled = true;
    if (record === cachePromiseRecord && record) event('cache-promise-resolve-hook', { asyncId });
  },
}).enable();
const tracePath = process.env.DSH_IMAGE_TEST_TRACE;
function snapshot() {
  const text = readFileSync(tracePath, 'utf8');
  assert(text.endsWith('\n'));
  const rows = text.trim().split('\n').map(JSON.parse);
  const live = new Map(); let creates = 0, releases = 0;
  for (const row of rows) {
    if (row.type === 'create') { assert(!live.has(row.id)); live.set(row.id, row.a); creates++; }
    if (row.type === 'release') { assert.equal(live.get(row.id), row.a); live.delete(row.id); releases++; }
  }
  return { creates, releases, live: [...live], packs: rows.filter(row => row.type === 'pack').length, rows: rows.length };
}
Object.defineProperty(process, 'platform', { value: 'openharmony' });
await import(url(join(config.prefix, 'runtime/ohos/sim/marker.mjs')));
await import(url(join(config.prefix, 'runtime/ohos/publication/preload.mjs')));
await import(url(join(config.prefix, 'runtime/ohos/image/preload.mjs')));
const load = name => import(url(join(config.view, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await load('cordis');
const { LocalAttachmentStore } = await load('dsh-attachment-local');
const control = await import(url(join(config.view, 'node_modules/@deepseek-ai/dsh-attachment-local/lib/fs-control.mjs')));
const oracle = JSON.parse(await readFile(config.oracle, 'utf8'));
const c = oracle.cases.find(row => row.name === 'opaque-jpeg');
assert.deepEqual(globalThis[Symbol.for('dsh.go.ohos.image-codec')].identity(), oracle.identity);
assert.equal(process.env.UV_THREADPOOL_SIZE, '4');
const ctx = new Context();
let store;
try {
  await ctx.plugin(LocalAttachmentStore, { dshHome: config.home, imageCompressionConcurrency: 1 });
  store = ctx.attachments;
  const ref = await store.saveImage({ data: Buffer.from(c.input.hex, 'hex'), mediaType: c.inputMediaType, name: c.file });
  assert.deepEqual(ref, c.ref);
  const cachePath = join(store.cacheRoot, 'request-images', c.variantId.slice(7, 9), c.variantId.slice(7));
  assert.equal(existsSync(cachePath), false);
  const saved = snapshot(); assert.deepEqual(saved.live, []);
  const controller = new AbortController();
  const reason = new Error('explicit user cancellation while actual cache open is pending');
  let blockers = [], completedBlockers = 0, readSettled = false, oldOperation, retry, retryOperation;
  let cancelledState, queuedState, oldSettledState;
  control.arm(cachePath, {
    before() {
      // Finite real libuv jobs make a possible busy-pool ordering reproducible.
      // They do not implement fs, produce ENOENT, or replace native image work.
      blockers = Array.from({ length: 4 }, (_, index) => new Promise((resolve, reject) => {
        event('crypto-submitted', { index });
        pbkdf2('local-scheduler-control', 'fixed-not-a-secret', 500000, 32, 'sha256', error => {
          completedBlockers++; event('crypto-callback', { index });
          if (error) reject(error); else resolve();
        });
      }));
    },
    after(promise, sharedSignal) {
      cachePromiseRecord = promises.get(promise);
      assert(cachePromiseRecord, 'actual fs Promise is observed through the public async_hooks API');
      event('cache-readFile-returned-original-promise', { signalAborted: sharedSignal.aborted, ...cachePromiseRecord });
      void promise.then(() => { readSettled = true; event('cache-promise-fulfilled'); }, error => {
        readSettled = true; event('cache-promise-rejection-delivered', { code: error.code, sharedAborted: sharedSignal.aborted });
      });
      setImmediate(() => {
        cancelledState = { promiseReactionDelivered: readSettled, promiseResolveHookCalled: cachePromiseRecord.resolveHookCalled, completedBlockers,
          sharedAbortedBefore: sharedSignal.aborted, sdk: snapshot() };
        event('user-cancel-callback', cancelledState);
        controller.abort(reason);
        event('user-cancel-returned', { sharedAborted: sharedSignal.aborted });
      });
    },
  });
  const pending = store.readImageRequest(ref, c.target, controller.signal);
  oldOperation = [...store.requestInflight.values()][0];
  assert(oldOperation);
  const oldDone = oldOperation.promise.then(value => ({ unexpectedValue: value }), error => {
    // Synchronous snapshot does not yield to the retry's filesystem callbacks.
    oldSettledState = { sameReason: error === reason, sdk: snapshot(),
      active: store.compression.active, queued: store.compression.waiting.length,
      cacheExists: existsSync(cachePath), replacementStillInMap: [...store.requestInflight.values()].includes(retryOperation) };
    event('old-shared-operation-settled', oldSettledState);
    return { error };
  });
  await pending.then(() => { throw new Error('cancelled request unexpectedly resolved'); }, error => {
    assert.equal(error, reason);
    event('public-cancellation-delivered', { sameReason: true });
    retry = store.readImageRequest(ref, c.target);
    retryOperation = [...store.requestInflight.values()][0];
    assert.notEqual(retryOperation, oldOperation);
    queuedState = { active: store.compression.active, queued: store.compression.waiting.length,
      oldSettled: oldOperation.settled, oldAborted: oldOperation.controller.signal.aborted,
      newWaiters: retryOperation.waiters };
    event('immediate-public-retry-queued', queuedState);
  });
  const oldResult = await oldDone;
  const recovered = await retry;
  await Promise.all(blockers);
  assert.equal(oldResult.error, reason);
  assert.equal(recovered.variantId, c.variantId);
  assert.equal(hash(recovered.data), c.request.sha256);
  assert.equal(hash(await readFile(cachePath)), c.request.sha256);
  assert.equal(cancelledState.promiseReactionDelivered, false, 'fixture requires cancellation before readFile completion is delivered');
  assert.equal(cancelledState.promiseResolveHookCalled, false, 'cancellation precedes resolution/rejection of the original fs Promise, independently of observer reaction order');
  assert.equal(cancelledState.completedBlockers, 0, 'fixture requires actual pool contention at the independent cancellation callback');
  assert.equal(cancelledState.sharedAbortedBefore, false);
  assert.deepEqual(queuedState, { active: 1, queued: 1, oldSettled: false, oldAborted: true, newWaiters: 1 });
  assert.equal(oldSettledState.sameReason, true);
  assert.equal(oldSettledState.cacheExists, false);
  assert.equal(oldSettledState.replacementStillInMap, true);
  assert.deepEqual(oldSettledState.sdk.live, []);
  const delivered = events.find(row => row.type === 'cache-promise-rejection-delivered');
  assert.equal(delivered.code, 'ENOENT');
  assert.equal(delivered.sharedAborted, true);
  assert(events.findIndex(row => row.type === 'cache-promise-resolve-hook') > events.findIndex(row => row.type === 'user-cancel-returned'));
  assert(events.indexOf(delivered) > events.findIndex(row => row.type === 'user-cancel-returned'));
  await ctx.fiber.dispose();
  assert.equal(store.compression.active, 0); assert.equal(store.compression.waiting.length, 0); assert.equal(store.requestInflight.size, 0);
  const final = snapshot(); assert.deepEqual(final.live, []); assert.equal(final.creates, final.releases);
  assert.deepEqual([Buffer, Buffer.from, Uint8Array, ArrayBuffer, readFile], builtins);
  assert.equal(control.realReadFile, readFile);
  const postCancelPacks = oldSettledState.sdk.packs - saved.packs;
  const output = { status: postCancelPacks === 0 ? 'CANCELLED_BEFORE_NEW_ENCODE' : 'CANCELLED_REQUEST_STILL_ENCODED',
    saved, cancelledState, queuedState, oldSettledState, final, postCancelPacks,
    retryPacks: final.packs - oldSettledState.sdk.packs, variantId: recovered.variantId,
    bytesSHA256: hash(recovered.data), events, functionalControls: 'PASS',
    physicalOpenErrnoDeterminationTime: 'UNKNOWN_FROM_JS',
    promiseObservation: 'The original fs Promise is identified by async_hooks.init; its promiseResolve hook has not fired at user abort, and fires before the later rejection reaction. The added then observer is not the sole ordering evidence.',
    scope: 'Actual filesystem/Promise, public store/shared requests/limiter and actual codec; local fs import schedules finite crypto contention and independent user-cancel callback; host SDK pixels are explicit fixture, no cancellation latency or device claim' };
  await writeFile(join(config.out, 'OBSERVATION.json'), JSON.stringify(output, null, 2) + '\n');
  assert.equal(postCancelPacks, 0, 'a cache miss whose caller already cancelled must not start a fresh native encode before releasing its permit');
} finally {
  promiseHook.disable();
  await ctx.fiber.dispose();
}
});
