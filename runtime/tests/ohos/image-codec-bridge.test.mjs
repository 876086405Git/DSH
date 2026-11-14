// Host fake backend only. No NDK, pixel decoding, or attachment persistence.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { isAbsolute } from 'node:path';
import { once } from 'node:events';
import { setImmediate as turn } from 'node:timers/promises';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import test from 'node:test';

const addonPath = isMainThread ? process.argv[2] : workerData.addonPath;
assert.equal(typeof addonPath, 'string', 'explicit host fixture addon path required');
assert.ok(isAbsolute(addonPath), 'use an absolute fixture addon path');
assert.equal(process.version, 'v24.22.1');
const codec = createRequire(import.meta.url)(addonPath);
assert.equal(codec.available, true);
assert.equal(codec.fixtureOnly, true);
assert.equal(codec.codecIdentity, 'host-lifecycle-fake-v1:no-codec:no-ndk:color-getter=not-used');
assert.equal(codec.colorGetterPolicy, 'not-used');
const token = () => Buffer.from([0x31, 0x41, 0x59, 0x26]);
const limits = { maxSide: 32, maxPixels: 1024 };
const target = { width: 2, height: 2, format: 'webp', softMaxBytes: 16 };
const sourceFacts = {
  width: 2, height: 2, mimeType: 'image/png', frameCount: 1, orientation: 1,
  hasAlpha: null, bitDepth: null, colorSpace: null, retainedMetadata: null,
  allocationBytes: null,
};
const workingFacts = {
  ...sourceFacts, hasAlpha: false, bitDepth: 8, colorSpace: 'srgb',
  retainedMetadata: false, allocationBytes: '16',
};

if (!isMainThread) {
  const frame = await codec.open(token(), limits);
  if (workerData.mode === 'idle-exit') {
    await frame.encode(target);
    parentPort.postMessage('idle-frame-left-open');
    parentPort.close();
  } else {
    const promise = frame.encode(target);
    parentPort.postMessage('encode-submitted');
    await promise;
    parentPort.postMessage('encode-completed');
    parentPort.close();
  }
} else {
  await test('native work uses a private input snapshot and preserves unknown facts', async () => {
    const bytes = token();
    const inspected = codec.inspect(bytes);
    bytes.fill(0);
    assert.deepEqual(await inspected, sourceFacts);
    const second = token();
    const opened = codec.open(second, limits);
    second.fill(0);
    const frame = await opened;
    assert.deepEqual(frame.sourceFacts, sourceFacts);
    assert.deepEqual(frame.workingFacts, workingFacts);
    const encoded = await frame.encode(target);
    assert.deepEqual([...encoded.data], [70, 65, 75, 69, 0x31, 2, 2, 1]);
    await frame.close();
    assert.equal(codec.fixtureStats().inputMismatches, 0);
  });

  await test('frame work is serialized and close drains accepted work exactly once', async () => {
    const before = codec.fixtureStats();
    const frame = await codec.open(token(), limits);
    const first = frame.encode(target);
    const second = frame.encode({ ...target, width: 1, height: 1 });
    const closed = frame.close();
    assert.equal(frame.close(), closed, 'idempotent close returns the same Promise');
    const late = assert.rejects(frame.encode(target), { code: 'OHOS_IMAGE_FRAME_CLOSED' });
    const [a, b] = await Promise.all([first, second]);
    await closed;
    await late;
    assert.deepEqual([...a.data], [70, 65, 75, 69, 0x31, 2, 2, 1]);
    assert.deepEqual([...b.data], [70, 65, 75, 69, 0x31, 1, 1, 2]);
    assert.equal(a.mimeType, 'image/webp');
    assert.equal(a.quality, 85);
    assert.deepEqual(a.encodedFacts, { ...workingFacts, mimeType: 'image/webp' });
    const after = codec.fixtureStats();
    assert.equal(after.opens - before.opens, 1);
    assert.equal(after.closes - before.closes, 1);
    assert.equal(after.encodes - before.encodes, 2);
    assert.equal(after.outputs - before.outputs, 2);
    assert.equal(after.releasedOutputs - before.releasedOutputs, 2);
    assert.equal(after.overlaps, 0);
    assert.equal(after.active, 0);
    // Returned copies remain valid after backend buffers and frame are closed.
    assert.equal(a.data.toString('ascii', 0, 4), 'FAKE');
    assert.equal(b.data.toString('ascii', 0, 4), 'FAKE');
  });

  await test('environment cleanup closes an idle frame without relying on its JS close', async () => {
    const before = codec.fixtureStats();
    const worker = new Worker(new URL(import.meta.url), { workerData: { addonPath, mode: 'idle-exit' } });
    const exited = once(worker, 'exit');
    const [message] = await once(worker, 'message');
    assert.equal(message, 'idle-frame-left-open');
    const [code] = await exited;
    assert.equal(code, 0);
    const after = codec.fixtureStats();
    assert.equal(after.opens - before.opens, 1);
    assert.equal(after.closes - before.closes, 1);
    assert.equal(after.active, 0);
    assert.equal(after.outputs, after.releasedOutputs);
  });

  await test('environment teardown waits for an actually running native call', async (t) => {
    const before = codec.fixtureStats();
    codec.fixtureHoldEncodes(true);
    const worker = new Worker(new URL(import.meta.url), { workerData: { addonPath, mode: 'in-flight' } });
    try {
      const [message] = await once(worker, 'message');
      assert.equal(message, 'encode-submitted');
      const deadline = Date.now() + 3000;
      while (codec.fixtureStats().active === 0 && Date.now() < deadline) await turn();
      assert.equal(codec.fixtureStats().active, 1, 'fixture must observe running work before termination');
      const stopped = worker.terminate();
      await turn();
      // Record, rather than require, Node's hook-vs-work ordering. A runtime
      // may start cleanup before or after the native call has drained.
      t.diagnostic(JSON.stringify({ phase: 'before-native-release', stats: codec.fixtureStats() }));
      codec.fixtureHoldEncodes(false);
      await stopped;
    } finally {
      codec.fixtureHoldEncodes(false);
      await worker.terminate();
    }
    const after = codec.fixtureStats();
    assert.equal(after.opens - before.opens, 1);
    assert.equal(after.closes - before.closes, 1);
    assert.equal(after.active, 0);
    assert.equal(after.overlaps, 0);
    assert.equal(after.cleanupStarts - before.cleanupStarts, 1);
    assert.equal(after.outputs, after.releasedOutputs);
    assert.equal(after.inputMismatches, 0);
  });
}
