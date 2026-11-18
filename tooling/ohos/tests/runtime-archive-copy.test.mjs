import test, { after, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { setImmediate } from 'node:timers/promises';
import { prepareArchiveModules, makeArchive, observation, resetObservation, activeInflaters } from './runtime-archive-fixture.mjs';

// Actual ETS methods, Linux files and native libz. ResourceManager/fs/zlib are
// explicit platform boundaries; these deterministic ZIP members are test data.
// Buffer identities measure a live JS copy window, never process RSS or PSS.
const root = process.env.OHOS_ARCHIVE_ROOT ?? path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const temporary = await fs.mkdtemp(path.join(process.env.OHOS_ARCHIVE_TEST_DIR ?? os.tmpdir(), 'archive-copy-'));
const { OhosRuntimeStorage, RuntimeInstaller } = await prepareArchiveModules(root, path.join(temporary, 'modules'));
const CHUNK = 256 * 1024;
const baseFiles = {
  'node_modules/@deepseek-ai/dsh/lib/bin.js': 'fixture bin',
  'runtime/ohos/preload.mjs': 'fixture preload',
  'runtime/ohos/process/index.mjs': 'fixture process',
  'runtime/ohos/process/sandbox.mjs': 'fixture sandbox',
  'runtime/ohos/lifecycle/index.mjs': 'fixture lifecycle',
  'runtime/ohos/phone/index.mjs': 'fixture phone',
  'runtime/ohos/capabilities/index.mjs': 'fixture capabilities',
  'runtime/bridge/dsh-go-bridge/lib/index.js': 'fixture bridge',
  'runtime/ohos/process/child-process.mjs': 'fixture child-process',
};
const sha = bytes => createHash('sha256').update(Buffer.from(bytes)).digest('hex');

async function scenario(name, files) {
  const directory = path.join(temporary, name);
  await fs.mkdir(directory);
  const pack = await makeArchive(path.join(directory, 'payload.hap'), files);
  const storage = new OhosRuntimeStorage(pack.resources, directory);
  return { ...pack, directory, storage, files, installer: new RuntimeInstaller(storage, directory + '/runtime') };
}
async function install(c) {
  await c.storage.withBundledRuntime(async () => {
    await c.installer.install(await c.storage.readBundledManifest(), () => {});
  });
}
async function exactFiles(c) {
  for (const [name, bytes] of Object.entries(c.files)) {
    assert.deepEqual(await fs.readFile(c.installer.root + '/' + name), Buffer.from(bytes));
  }
}
afterEach(() => {
  assert.equal(observation.fd.size, 0, 'all real file descriptors closed');
  assert.equal(activeInflaters(), 0, 'all real libz streams ended');
  resetObservation();
});
after(async () => { await fs.rm(temporary, { recursive: true, force: true }); });

async function eightPendingWrites(c, rejectFirst = false) {
  const sources = new Map(), pending = [], held = new Set();
  const ready = Promise.withResolvers(), release = Promise.withResolvers();
  const failure = new Error('explicit asynchronous file-write interruption');
  observation.beforeCrc = async (_previous, buffer) => {
    if (buffer.byteLength === CHUNK) sources.set(sha(buffer), new WeakRef(buffer));
  };
  observation.beforeWrite = async (fd, buffer, options) => {
    if (options.offset !== 0 || buffer.byteLength !== CHUNK || held.has(fd)) return;
    held.add(fd);
    const digest = sha(buffer), source = sources.get(digest)?.deref();
    assert.ok(source, 'the complete output block was checked by the actual native CRC path');
    const row = { source, buffer, digest, index: pending.length };
    pending.push(row);
    if (pending.length === 8) ready.resolve();
    await release.promise;
    assert.equal(sha(buffer), digest, 'write input remains unchanged until its asynchronous completion');
    assert.equal(sha(source), digest, 'inflater output remains unchanged while write is pending');
    if (rejectFirst && row.index === 0) throw failure;
  };
  const operation = install(c);
  operation.catch(() => {});
  let timer, snapshot;
  try {
    await Promise.race([
      ready.promise,
      operation.then(() => { throw new Error('installer finished before eight pending writes'); }),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('eight-write admission timeout')), 10000); }),
    ]);
    assert.equal(activeInflaters(), 8);
    const inflates = observation.inflates;
    await setImmediate();
    await setImmediate();
    assert.equal(observation.inflates, inflates, 'no lane reuses its output before the pending write settles');
    for (const row of pending) {
      assert.equal(sha(row.source), row.digest);
      assert.equal(sha(row.buffer), row.digest);
    }
    const copied = pending.filter(row => row.source !== row.buffer);
    snapshot = {
      scope: 'eight real installer lanes paused at the explicit Linux fs.write boundary; not RSS/PSS',
      pendingWrites: pending.length, validBytesEach: CHUNK, activeInflaters: activeInflaters(),
      duplicateWriteBuffers: copied.length, duplicateWriteBytes: copied.reduce((n, row) => n + row.buffer.byteLength, 0),
      crcAndWriteBytesIdentical: true, unchangedAcrossPendingWrite: true,
      nextInflateBlockedUntilWriteCompletion: true,
    };
  } finally {
    clearTimeout(timer);
    release.resolve();
  }
  if (rejectFirst) await assert.rejects(operation, error => error === failure);
  else await operation;
  observation.beforeCrc = null; observation.beforeWrite = null;
  return snapshot;
}

function eightFiles() {
  const files = { ...baseFiles };
  // Different hashes keep eight real RuntimeInstaller lanes distinct. Each
  // member has two full output blocks and a short final block.
  for (let i = 0; i < 8; i++) files['000-lane-' + i + '.bin'] = Buffer.alloc(2 * CHUNK + 37, 0x61 + i);
  return files;
}

test('eight pending full-block writes share their checked output buffer without an extra copy', async t => {
  const c = await scenario('eight-writes', eightFiles());
  const snapshot = await eightPendingWrites(c);
  await exactFiles(c);
  assert.equal((await c.installer.installed()).runtimeVersion, 'v1');
  t.diagnostic(JSON.stringify(snapshot));
  assert.equal(snapshot.duplicateWriteBytes, 0, 'complete initial writes must not retain a redundant copy');
});

test('real short writes keep exact offsets and do not expose the output-buffer tail', async t => {
  const bytes = Buffer.alloc(CHUNK + 37, 0x59);
  const c = await scenario('short-write', { ...baseFiles, '000-short.bin': bytes });
  observation.maxWriteChunk = 65533;
  const writes = [];
  let target;
  observation.beforeWrite = async (fd, buffer, options) => {
    if (buffer.byteLength === CHUNK && options.offset === 0) target = fd;
    if (fd === target) writes.push({ offset: options.offset, bytes: buffer.byteLength });
  };
  await install(c);
  observation.beforeWrite = null;
  await exactFiles(c);
  assert.deepEqual(writes.slice(0, 6), [
    { offset: 0, bytes: CHUNK }, { offset: 65533, bytes: CHUNK - 65533 },
    { offset: 131066, bytes: CHUNK - 131066 }, { offset: 196599, bytes: CHUNK - 196599 },
    { offset: 262132, bytes: 12 }, { offset: CHUNK, bytes: 37 },
  ]);
  t.diagnostic(JSON.stringify({ scope: 'actual archive short-write offsets', writes: writes.slice(0, 6), exactOutputBytes: bytes.length }));
});

test('storage honors a valid byte count smaller than the supplied callback buffer', async () => {
  const directory = path.join(temporary, 'callback-range'); await fs.mkdir(directory);
  const storage = new OhosRuntimeStorage({}, directory);
  const buffer = new ArrayBuffer(91); new Uint8Array(buffer).fill(0x71);
  new Uint8Array(buffer, 37).fill(0x7a);
  // Explicit archive callback boundary for the declared (buffer,count) API;
  // the real inflater above already slices a short final block before writing.
  storage.archive = { async extract(_file, write) { await write(buffer, 37); } };
  const file = { path: 'range.bin', size: 37, sha256: sha(buffer.slice(0, 37)) };
  const target = path.join(directory, 'range.bin');
  await storage.copyRawFile('dsh-runtime/files/range.bin', target, file);
  assert.deepEqual(await fs.readFile(target), Buffer.alloc(37, 0x71));
});

test('write rejection joins every pending lane, retires buffers and permits journal-based retry', async t => {
  const c = await scenario('interrupted-write', eightFiles());
  const snapshot = await eightPendingWrites(c, true);
  assert.equal(observation.fd.size, 0); assert.equal(activeInflaters(), 0);
  assert.equal(await c.installer.installed(), null);
  await fs.access(c.installer.base + '/installing.json');
  await install(c);
  await exactFiles(c);
  assert.equal((await c.installer.installed()).runtimeVersion, 'v1');
  t.diagnostic(JSON.stringify({ ...snapshot, outcome: 'explicit write rejection; all lanes joined; exact retry completed',
    cancellationScope: 'installer has no AbortSignal; this is a rejected platform write, not a user-stop simulation' }));
});
