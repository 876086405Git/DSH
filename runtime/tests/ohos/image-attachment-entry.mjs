// Author385 ordinary host integration. No factory replacement or native test API.
import assert from 'node:assert/strict';
import { readFile, writeFile, readdir, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = fileURLToPath(new URL('.', import.meta.url));
const prefix = resolve(process.env.DSH_PREFIX);
const out = resolve(process.env.DSH_IMAGE_TEST_OUT);
const home = resolve(process.env.DSH_HOME);
const tracePath = resolve(process.env.DSH_IMAGE_TEST_TRACE);
const oracle = JSON.parse(await readFile(new URL('./image-attachment-oracle.json', import.meta.url), 'utf8'));
const report = { schema: 1, state: 'STARTED', originalPlatform: process.platform,
  node: process.versions.node, phases: [], cases: [], cleanup: {},
  scope: oracle.scope, pixelsDecodedByRealSDK: false, deviceRun: false };
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function serial(value) {
  if (value === undefined) return { $undefined: true };
  if (value instanceof Uint8Array) return { $bytes: value.length, hex: Buffer.from(value).toString('hex'), sha256: hash(value) };
  if (value instanceof Error) return { name: value.name, message: value.message, code: value.code,
    stack: value.stack, cause: value.cause ? serial(value.cause) : undefined,
    errors: value.errors ? value.errors.map(serial) : undefined };
  if (Array.isArray(value)) return value.map(serial);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, serial(v)]));
  return value;
}
async function trace() {
  const text = await readFile(tracePath, 'utf8');
  assert.equal(text.endsWith('\n'), true, 'complete JSONL at awaited boundary');
  const rows = text.trimEnd().split('\n').map(line => JSON.parse(line));
  const live = new Map(); let created = 0, released = 0;
  for (const [i, row] of rows.entries()) {
    assert.equal(row.seq, i + 1, 'trace ordering');
    if (row.type === 'create') { assert.equal(live.has(row.id), false); live.set(row.id, row.a); created++; }
    if (row.type === 'release') { assert.equal(live.get(row.id), row.a, 'same typed handle released'); live.delete(row.id); released++; }
  }
  return { rows: rows.length, created, released, live: [...live],
    packs: rows.filter(x => x.type === 'pack').length,
    sourceDecodes: rows.filter(x => x.type === 'decode' && x.name === 'source').length,
    verificationDecodes: rows.filter(x => x.type === 'decode' && x.name === 'verify').length,
    scales: rows.filter(x => x.type === 'scale').length,
    packRecords: rows.filter(x => x.type === 'pack'),
    sourceOrigins: rows.filter(x => x.type === 'source') };
}
const metricKeys = ['packs', 'sourceDecodes', 'verificationDecodes', 'scales'];
function delta(before, after) { return Object.fromEntries(metricKeys.map(k => [k, after[k] - before[k]])); }
function bytesEqual(actual, expected) {
  assert.ok(actual instanceof Uint8Array);
  assert.equal(actual.length, expected.bytes);
  assert.equal(hash(actual), expected.sha256);
  assert.equal(Buffer.from(actual).toString('hex'), expected.hex);
}
function pngWithUnknownOrientation(bytes) {
  // A valid ancillary text chunk makes the real scanner conservatively leave
  // source orientation unknown. It must invalidate a disposable cache entry.
  const type = Buffer.from('tEXt'), data = Buffer.from('Comment\0image-cache-orientation');
  const chunk = Buffer.alloc(data.length + 12);
  chunk.writeUInt32BE(data.length, 0); type.copy(chunk, 4); data.copy(chunk, 8);
  let crc = 0xffffffff;
  for (const value of Buffer.concat([type, data])) {
    crc ^= value;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  chunk.writeUInt32BE((crc ^ 0xffffffff) >>> 0, 8 + data.length);
  for (let cursor = 8; cursor < bytes.length; cursor += 12 + bytes.readUInt32BE(cursor)) {
    if (bytes.toString('ascii', cursor + 4, cursor + 8) === 'IEND') {
      return Buffer.concat([bytes.subarray(0, cursor), chunk, bytes.subarray(cursor)]);
    }
  }
  throw new Error('The independent PNG fixture has no IEND');
}
let ctx, store, codec, publication, began = false;
async function boundary(label) {
  const current = await trace();
  assert.deepEqual(current.live, [], 'SDK objects retired before public await finishes');
  assert.equal(current.created, current.released);
  assert.equal(publication.pendingCount, 0, 'publication operations settled');
  if (store) {
    assert.equal(store.compression.active, 0);
    assert.equal(store.compression.waiting.length, 0);
    assert.equal(store.requestInflight.size, 0);
  }
  report.phases.push({ label, sdk: current, publicationPending: publication.pendingCount,
    compressionActive: store?.compression.active, queuedCompression: store?.compression.waiting.length,
    requestInflight: store?.requestInflight.size });
  return current;
}
async function filesBelow(root) {
  const rows = [];
  async function walk(dir) {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) await walk(path);
      else if (entry.isFile()) { const b = await readFile(path), s = await stat(path);
        rows.push({ path: path.slice(root.length + 1), bytes: b.length, sha256: hash(b), mode: (s.mode & 0o7777).toString(8) }); }
      else throw new Error('unexpected non-file entry in test-owned attachment storage');
    }
  }
  await walk(root); return rows.sort((a, b) => a.path.localeCompare(b.path));
}
function requestObject(value, c) {
  const expected = { variantId: c.variantId, attachment: c.ref, mediaType: c.ref.mediaType,
    bytes: c.request.bytes, width: 3, height: 2, depth: 'uchar', space: 'srgb', hasAlpha: c.alpha };
  const { data, ...actual } = value;
  assert.deepEqual(actual, expected, 'complete public request metadata');
  bytesEqual(data, c.request);
}
async function checkCached(c) {
  const path = join(store.cacheRoot, 'request-images', c.variantId.slice(7, 9), c.variantId.slice(7));
  const data = await readFile(path); bytesEqual(data, c.request);
  const sourceFacts = await codec.probe(data);
  assert.equal(sourceFacts.space, undefined, 'own output still has unknown source color space');
  assert.equal(sourceFacts.hasAlpha, c.alpha);
  assert.equal(sourceFacts.width, 3); assert.equal(sourceFacts.height, 2);
  return { path, bytes: serial(data), sourceFacts: serial(sourceFacts) };
}
try {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(report.originalPlatform, 'linux', 'this plan is explicitly a Linux host carrier');
  // Only the platform label and existing explicit simulation marker are carried.
  // No filesystem/Native/child_process/global codec function is replaced.
  Object.defineProperty(process, 'platform', { value: 'openharmony' });
  await import(pathToFileURL(join(prefix, 'runtime/ohos/sim/marker.mjs')));
  await import(pathToFileURL(join(prefix, 'runtime/ohos/publication/preload.mjs')));
  await import(pathToFileURL(join(prefix, 'runtime/ohos/image/preload.mjs')));
  codec = globalThis[Symbol.for('dsh.go.ohos.image-codec')];
  publication = globalThis[Symbol.for('dsh.go.ohos.publication')];
  assert.equal(codec.protocolVersion, 1); assert.equal(publication.protocolVersion, 1);
  assert.deepEqual(codec.identity(), oracle.identity);
  const require = createRequire(pathToFileURL(join(prefix, 'runtime/ohos/image/preload.mjs')));
  const fixed = require('@dsh-go/ohos-native').load('image-codec');
  assert.equal(fixed.path, join(resolve(process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR), 'libdsh_image_codec.so'));
  assert.equal(fixed.binding.available, true); assert.equal(fixed.binding.fixtureOnly, false);
  assert.equal(fixed.binding.codecIdentity, oracle.identity.buildId);
  assert.equal(fixed.binding.colorGetterPolicy, 'destroy');
  assert.equal(fixed.binding.fixtureStats, undefined, 'no fake-backend stats macro');
  const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
  const { Context } = await load('cordis');
  const { LocalAttachmentStore } = await load('dsh-attachment-local');
  ctx = new Context(); await ctx.plugin(LocalAttachmentStore, { dshHome: home }); store = ctx.attachments;
  report.admission = { fixedPath: fixed.path, fixtureOnly: fixed.binding.fixtureOnly,
    identity: codec.identity(), publicationProtocol: publication.protocolVersion,
    publicationSystemBuild: publication.systemVersion, platformCarrier: process.platform };
  await boundary('ready-before-target');
  const records = new Map();
  for (const c of oracle.cases) {
    const input = await readFile(join(here, 'image-attachment-fixtures', c.file)); bytesEqual(input, c.input);
    const inputBefore = Buffer.from(input);
    const sourceFacts = await codec.probe(input);
    assert.deepEqual(sourceFacts, { ...c.sourceFacts, space: undefined }, 'complete source facts retain unknown color space');
    const before = await boundary(c.name + ':before-save'); began = true;
    const ref = await store.saveImage({ data: input, mediaType: c.inputMediaType, name: c.file });
    assert.deepEqual(ref, c.ref, 'complete immutable reference');
    const saved = await boundary(c.name + ':save-returned');
    assert.deepEqual(delta(before, saved), { packs: 1, sourceDecodes: 2, verificationDecodes: 1, scales: 0 });
    const read = await store.readImage(ref);
    assert.deepEqual(Object.keys(read).sort(), ['data', 'ref']); assert.deepEqual(read.ref, c.ref);
    bytesEqual(read.data, c.normalized);
    bytesEqual(await readFile(store.imageHostPath(ref)), c.normalized);
    const readAfter = await boundary(c.name + ':read-returned');
    assert.deepEqual(delta(saved, readAfter), { packs: 0, sourceDecodes: 0, verificationDecodes: 0, scales: 0 });
    const value = await store.readImageRequest(ref, c.target);
    requestObject(value, c);
    const requested = await boundary(c.name + ':request-returned');
    assert.deepEqual(delta(readAfter, requested), { packs: 1, sourceDecodes: 1, verificationDecodes: 1, scales: 1 });
    const cached = await checkCached(c);
    assert.deepEqual(input, inputBefore, 'caller input unchanged');
    bytesEqual(await readFile(join(here, 'image-attachment-fixtures', c.file)), c.input);
    const row = { name: c.name, sourceFacts: serial(sourceFacts), ref: serial(ref), read: serial(read), request: serial(value), cached };
    report.cases.push(row); records.set(c.name, { ref, c, value });
  }
  const { ref, c, value: first } = records.get(oracle.sequentialRepeat.case);
  const beforeRepeat = await boundary('sequential-repeat:before');
  const second = await store.readImageRequest(ref, c.target);
  requestObject(second, c); assert.equal(second.variantId, first.variantId);
  const afterRepeat = await boundary('sequential-repeat:returned');
  assert.deepEqual(delta(beforeRepeat, afterRepeat), { packs: 1, sourceDecodes: 1, verificationDecodes: 1, scales: 1 });
  report.sequentialRepeat = { value: serial(second), delta: delta(beforeRepeat, afterRepeat), cached: await checkCached(c),
    conclusion: 'same variant and valid cache file still caused a fresh encode; source space remains unknown' };
  const total = await boundary('all-public-awaits-finished');
  for (const key of metricKeys) assert.equal(total[key], oracle.total[key]);
  assert.equal(total.packRecords.every(x => x.a === 85 && x.b === 240), true);
  const alpha = records.get('transparent-png');
  const cachePath = join(store.cacheRoot, 'request-images', alpha.c.variantId.slice(7, 9), alpha.c.variantId.slice(7));
  const unsupportedCache = pngWithUnknownOrientation(await readFile(join(here, 'image-attachment-fixtures', 'alpha.png')));
  await assert.rejects(codec.probe(unsupportedCache), error => error.code === 'OHOS_IMAGE_CODEC_UNAVAILABLE'
    && error.stage === 'source-orientation');
  await writeFile(cachePath, unsupportedCache);
  const beforeRecovery = await boundary('cache-unknown-orientation:before');
  report.cacheUnavailableRecovery = { cacheSha256: hash(unsupportedCache), stage: 'source-orientation',
    scope: 'Actual product scanner and preload reject only the disposable cache; original source remains valid' };
  const recovered = await store.readImageRequest(alpha.ref, alpha.c.target);
  requestObject(recovered, alpha.c);
  const afterRecovery = await boundary('cache-unknown-orientation:reencoded');
  assert.deepEqual(delta(beforeRecovery, afterRecovery), { packs: 1, sourceDecodes: 1, verificationDecodes: 1, scales: 1 });
  bytesEqual(await readFile(cachePath), alpha.c.request);
  report.cacheUnavailableRecovery = { ...report.cacheUnavailableRecovery, result: 'RECOVERED_SOURCE_REENCODE',
    variantId: recovered.variantId, delta: delta(beforeRecovery, afterRecovery) };
  report.files = await filesBelow(home);
  assert.equal(report.files.some(x => x.path.startsWith('attachments/v1/tmp/')), false);
  assert.equal(report.files.some(x => x.path.endsWith('.tmp')), false);
  report.state = 'PASS';
} catch (error) {
  report.error = serial(error);
  report.state = !began ? 'SETUP' : error?.code === 'ERR_ASSERTION' ? 'BEHAVIOR_RED' : 'UNKNOWN';
} finally {
  try {
    if (ctx) await ctx.fiber.dispose();
    if (codec && publication && store) report.cleanup.afterContextDispose = await boundary('context-dispose-returned');
    report.cleanup.contextDisposed = !!ctx;
    report.cleanup.publicationOwner = 'process-owned ledger has no public close API; no all-FD-retired claim';
    report.cleanup.observerFD = 'test carrier trace FD closes at process exit';
  } catch (error) { report.cleanup.error = serial(error); report.state = 'CLEANUP'; }
  await writeFile(join(out, 'REPORT.json'), JSON.stringify(report, null, 2) + '\n', { flag: 'wx' });
}
process.exitCode = report.state === 'PASS' ? 0 : 1;
