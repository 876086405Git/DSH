import assert from 'node:assert/strict';
import test from 'node:test';
import * as originalFs from 'node:fs/promises';
import { readFile, writeFile, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { isMarkedAsUntransferable } from 'node:worker_threads';
import { createHook } from 'node:async_hooks';
import { appendFileSync, truncateSync } from 'node:fs';

const config = JSON.parse(await readFile(process.env.DSH_IMAGE_FILE_STORAGE_CONFIG, 'utf8'));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const url = p => pathToFileURL(p).href;
const records = [];
const originalBufferFrom = Buffer.from;
const constructors = [Buffer, Uint8Array, ArrayBuffer];
const fsIdentities = Object.entries(originalFs);
assert.equal(process.platform, 'linux');
Object.defineProperty(process, 'platform', { value: 'openharmony' });
await import(url(join(config.prefix, 'runtime/ohos/sim/marker.mjs')));
await import(url(join(config.prefix, 'runtime/ohos/publication/preload.mjs')));
await import(url(join(config.prefix, 'runtime/ohos/image/preload.mjs')));
const { Context } = await import(url(join(config.prefix, 'node_modules/@deepseek-ai/cordis/lib/index.js')));
const { LocalAttachmentStore } = await import(url(join(config.view, 'node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js')));
const observed = await import(url(join(config.view, 'node_modules/@deepseek-ai/dsh-attachment-local/lib/fs-observer.mjs')));
const codec = globalThis[Symbol.for('dsh.go.ohos.image-codec')];
const oracle = JSON.parse(await readFile(config.oracle, 'utf8'));
assert.deepEqual(codec.identity(), oracle.identity);
const c = oracle.cases.find(row => row.name === 'opaque-jpeg');
const ctx = new Context();
let store;
function shape(bytes) {
  return { constructor: bytes.constructor.name, buffer: Buffer.isBuffer(bytes),
    byteOffset: bytes.byteOffset, byteLength: bytes.byteLength,
    capacity: bytes.buffer.byteLength, transferable: !isMarkedAsUntransferable(bytes.buffer),
    resizable: bytes.buffer.resizable, ownKeys: Reflect.ownKeys(bytes).filter(k => !/^\d+$/.test(String(k))).map(String) };
}
function checkPublicBytes(bytes, expectedHash) {
  assert.equal(bytes.constructor, Uint8Array);
  assert.equal(Buffer.isBuffer(bytes), false);
  assert.equal(bytes.byteOffset, 0);
  assert.equal(bytes.buffer.byteLength, bytes.byteLength);
  assert.equal(isMarkedAsUntransferable(bytes.buffer), false);
  assert.equal(bytes.buffer.resizable, false);
  assert.equal(hash(bytes), expectedHash);
  assert.equal(bytes.toString(), Array.from(bytes).join(','));
  const slice = bytes.slice();
  assert.equal(slice.constructor, Uint8Array);
  assert.notEqual(slice.buffer, bytes.buffer);
  slice.fill(0);
  assert.equal(hash(bytes), expectedHash);
}
function lastRead(path) {
  return observed.reads.filter(row => String(row.path) === path).at(-1);
}
function record(label, path, bytes) {
  const raw = lastRead(path).value;
  const sameBacking = raw.buffer === bytes.buffer;
  records.push({ label, path, readFile: shape(raw), returned: shape(bytes), sameBacking,
    explicitCopyBytes: sameBacking ? 0 : bytes.byteLength, sha256: hash(bytes) });
}
function counts(rows) {
  const live = new Map(); let creates = 0, releases = 0;
  for (const row of rows) {
    if (row.type === 'create') { assert(!live.has(row.id)); live.set(row.id, row.a); creates++; }
    if (row.type === 'release') { assert.equal(live.get(row.id), row.a); live.delete(row.id); releases++; }
  }
  assert.equal(live.size, 0);
  return { creates, releases, live: live.size, packs: rows.filter(row => row.type === 'pack').length };
}
async function trace() {
  return counts((await readFile(process.env.DSH_IMAGE_TEST_TRACE, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse));
}
async function atFirstRealFileRead(action, read) {
  const stages = []; let callbackError;
  const hook = createHook({ init(id, type) {
    if (type !== 'FSREQPROMISE') return;
    stages.push(new Error().stack);
    if (stages.length === 3) {
      try { action(); } catch (error) { callbackError = error; }
    }
  } });
  hook.enable();
  let result;
  try { result = await read(); } finally { hook.disable(); }
  if (callbackError) throw callbackError;
  assert.match(stages[0], /at open \(node:internal\/fs\/promises:/);
  assert.match(stages[1], /at readFileHandle \(node:internal\/fs\/promises:/);
  assert.match(stages[2], /at readFileHandle \(node:internal\/fs\/promises:/);
  return { result, stages };
}
await test('actual private fs storage reuse preserves public image bytes and boundaries', async () => {
let status = 'STARTED';
try {
  await ctx.plugin(LocalAttachmentStore, { dshHome: config.home });
  store = ctx.attachments;
  const ref = await store.saveImage({ data: Buffer.from(c.input.hex, 'hex'), mediaType: c.inputMediaType, name: c.file });
  assert.deepEqual(ref, c.ref);
  const sourcePath = store.imageHostPath(ref);
  const sourceBytes = await readFile(sourcePath);
  const sourceHash = hash(sourceBytes);
  const first = await store.readImage(ref);
  checkPublicBytes(first.data, sourceHash);
  record('normal regular source', sourcePath, first.data);
  const transferred = structuredClone(first.data, { transfer: [first.data.buffer] });
  assert.equal(first.data.byteLength, 0);
  checkPublicBytes(transferred, sourceHash);
  transferred.fill(0);
  assert.equal(hash(await readFile(sourcePath)), sourceHash);
  const again = await store.readImage(ref);
  checkPublicBytes(again.data, sourceHash);
  assert.notEqual(again.data.buffer, transferred.buffer);
  assert.deepEqual(transferred, new Uint8Array(transferred.byteLength));
  record('fresh source after transfer and mutation', sourcePath, again.data);

  const request = await store.readImageRequest(ref, c.target);
  assert.equal(request.variantId, c.variantId);
  assert.equal(hash(request.data), c.request.sha256);
  const beforeHit = await trace();
  const hit = await store.readImageRequest(ref, c.target);
  const afterHit = await trace();
  assert.equal(afterHit.packs, beforeHit.packs);
  assert.equal(hit.variantId, c.variantId);
  checkPublicBytes(hit.data, c.request.sha256);
  const cachePath = join(store.cacheRoot, 'request-images', c.variantId.slice(7, 9), c.variantId.slice(7));
  record('actual warm request cache', cachePath, hit.data);
  hit.data.fill(0);
  const hitAgain = await store.readImageRequest(ref, c.target);
  checkPublicBytes(hitAgain.data, c.request.sha256);
  assert.notEqual(hitAgain.data.buffer, hit.data.buffer);
  assert.deepEqual(hit.data, new Uint8Array(hit.data.byteLength));
  assert.equal((await trace()).packs, afterHit.packs);
  assert.equal(hash(await readFile(cachePath)), c.request.sha256);

  // Node's real open -> fstat -> read async resource sequence makes the file
  // mutation deterministic. Hooks only schedule actual truncate/append syscalls;
  // they do not replace fs exports, return values, constructors, or native reads.
  await rm(sourcePath);
  await writeFile(sourcePath, Buffer.concat([sourceBytes, Buffer.alloc(17, 0xab)]));
  const shortened = await atFirstRealFileRead(() => truncateSync(sourcePath, sourceBytes.byteLength), () => store.readImage(ref));
  checkPublicBytes(shortened.result.data, sourceHash);
  record('actual regular file shrinks after fstat', sourcePath, shortened.result.data);
  assert.equal(lastRead(sourcePath).value.buffer.byteLength, sourceBytes.byteLength + 17);
  assert.notEqual(lastRead(sourcePath).value.buffer, shortened.result.data.buffer);
  await writeFile(join(config.out, 'SHORT-READ-STAGES.json'), JSON.stringify(shortened.stages, null, 2) + '\n');

  const grown = await atFirstRealFileRead(() => appendFileSync(sourcePath, Buffer.alloc(17, 0xab)), () => store.readImage(ref));
  checkPublicBytes(grown.result.data, sourceHash);
  record('actual regular file grows after fstat', sourcePath, grown.result.data);
  assert.equal((await readFile(sourcePath)).byteLength, sourceBytes.byteLength + 17);
  await writeFile(join(config.out, 'GROWTH-STAGES.json'), JSON.stringify(grown.stages, null, 2) + '\n');
  await writeFile(sourcePath, sourceBytes);

  // Empty cached input remains a disposable failed probe, then re-encodes the
  // verified original. Empty source still fails its digest before native work.
  await writeFile(cachePath, new Uint8Array());
  const emptyCache = await store.readImageRequest(ref, c.target);
  checkPublicBytes(emptyCache.data, c.request.sha256);
  const emptyRead = observed.reads.filter(row => String(row.path) === cachePath).findLast(row => row.value.byteLength === 0);
  assert(emptyRead);
  records.push({ label: 'actual empty cache fallback', readFile: shape(emptyRead.value), sha256: hash(emptyCache.data), variantId: emptyCache.variantId });
  await writeFile(sourcePath, new Uint8Array());
  await assert.rejects(store.readImage(ref), { code: 'ATTACHMENT_CORRUPT' });
  records.push({ label: 'actual empty source', code: 'ATTACHMENT_CORRUPT', readFile: shape(lastRead(sourcePath).value) });
  await writeFile(sourcePath, sourceBytes);

  // An actual size-zero filesystem carrier exercises Node's real unknown-size
  // readFile branch. No fake Buffer, fs return, or global constructor is used.
  await rm(sourcePath);
  execFileSync('mkfifo', [sourcePath], { env: Object.fromEntries(Object.entries(process.env).filter(([key]) => key !== 'LD_PRELOAD')) });
  try {
    const pending = store.readImage(ref);
    const writer = writeFile(sourcePath, sourceBytes);
    const fifo = await pending;
    await writer;
    checkPublicBytes(fifo.data, sourceHash);
    record('real FIFO unknown-size source', sourcePath, fifo.data);
    assert(lastRead(sourcePath).value.buffer.byteLength > fifo.data.byteLength);
    assert.notEqual(lastRead(sourcePath).value.buffer, fifo.data.buffer);
  } finally {
    await rm(sourcePath);
    await writeFile(sourcePath, sourceBytes);
  }

  // Keep the earlier admitted coercion counterexample intact: this actor does
  // not change the public codec or its Buffer.from snapshot.
  const own = new Uint8Array(Buffer.from(c.input.hex, 'hex'));
  const png = Buffer.from(oracle.cases.find(row => row.name === 'transparent-png').input.hex, 'hex');
  let conversions = 0;
  own.valueOf = () => { conversions++; return png; };
  const coercion = await codec.probe(own);
  assert.equal(conversions, 1);
  assert.equal(coercion.mediaType, 'image/png');
  assert.equal(coercion.hasAlpha, true);
  records.push({ label: 'unchanged public valueOf coercion', conversions, mediaType: coercion.mediaType });
  assert.equal(Buffer.from, originalBufferFrom);
  assert.deepEqual([Buffer, Uint8Array, ArrayBuffer], constructors);
  assert.deepEqual(Object.entries(originalFs), fsIdentities);
  assert.equal(observed.realReadFile, readFile);
  await ctx.fiber.dispose();
  assert.equal(store.requestInflight.size, 0);
  assert.equal(store.compression.active, 0);
  assert.equal(store.compression.waiting.length, 0);
  const native = await trace();
  status = records[0].sameBacking && records[2].sameBacking ? 'REUSED_PRIVATE_FS_STORAGE' : 'EXPLICIT_FS_COPY_OBSERVED';
  await writeFile(join(config.out, 'OBSERVATION.json'), JSON.stringify({ status, records, native,
    variantId: c.variantId, publicBehaviorControls: 'PASS',
    scope: 'Actual filesystem, attachment, preload, N-API, scanner and existing explicit host SDK pixel/ownership fixture; no RSS/PSS/target SDK claim' }, null, 2) + '\n');
  assert.equal(records[0].sameBacking, true, 'ordinary readFile-owned storage is copied before the unchanged public codec snapshot');
  assert.equal(records[2].sameBacking, true, 'warm cache readFile-owned storage is copied before the unchanged public codec snapshot');
} finally {
  await ctx.fiber.dispose();
}

});
