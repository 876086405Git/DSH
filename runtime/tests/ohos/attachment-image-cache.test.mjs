// Actual LocalAttachmentStore/readRequestImageFile with a declared codec registration seam.
// The known-sRGB capability below is a fixture, not a claim about native scanner output.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

assert.equal(process.platform, 'openharmony', 'Run with the explicit OH simulation carrier');
const prefix = resolve(process.env.DSH_PREFIX);
const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await load('cordis');
const { LocalAttachmentStore, requestImageVariantId } = await load('dsh-attachment-local');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const identity = JSON.parse(await readFile(new URL('./image-attachment-oracle.json', import.meta.url), 'utf8')).identity;
const source = Uint8Array.from([1, 6, 4, 99]);
const ref = { attachmentId: 'sha256:' + hash(source), bytes: source.length, width: 6, height: 4,
  mediaType: 'image/png', name: 'explicit-codec-seam.png' };
const target = { width: 3, height: 2, maxBytes: 1024 };
let fixture;
const metadata = data => ({ mediaType: data[0] === 1 ? 'image/png' : 'image/jpeg',
  width: data[1], height: data[2], depth: 'uchar', space: data[0] === 3 ? undefined : 'srgb',
  hasAlpha: false, animated: false, carriesMetadata: false });
const codec = Object.freeze({ protocolVersion: 1, identity: () => fixture.identity,
  async probe(data) {
    fixture.probes.push(data[0]);
    if (data[0] === 4) throw Object.assign(new Error('declared unsupported cached format'), {
      code: 'OHOS_IMAGE_CODEC_UNAVAILABLE', stage: 'source-orientation' });
    if (data[0] === 5) throw Object.assign(new Error('declared unretired owner'), {
      code: 'OHOS_IMAGE_CLEANUP_UNCONFIRMED', retirement: { confirmed: false }, resourcesRetired: false });
    if (data[0] === 6) {
      fixture.abortCache();
      throw Object.assign(new Error('cache capability failure during cancellation'), { code: 'OHOS_IMAGE_CODEC_UNAVAILABLE' });
    }
    return metadata(data);
  },
  async detect(data) { return metadata(data); },
  async encode(data, requestTarget) {
    assert.deepEqual(data, source);
    fixture.encodes.push({ ...requestTarget });
    if (fixture.encodeGate) await fixture.encodeGate.promise;
    return { data: Uint8Array.from([2, requestTarget.width, requestTarget.height, 77]),
      mediaType: 'image/jpeg', width: requestTarget.width, height: requestTarget.height, hasAlpha: false };
  },
});
assert.equal(globalThis[Symbol.for('dsh.go.ohos.image-codec')], undefined, 'No real native registration is replaced');
Object.defineProperty(globalThis, Symbol.for('dsh.go.ohos.image-codec'), { value: codec });

async function prepare(t) {
  fixture = { identity: structuredClone(identity), probes: [], encodes: [], encodeGate: null };
  const home = await mkdtemp(join(tmpdir(), 'attachment-codec-seam-'));
  const ctx = new Context();
  await ctx.plugin(LocalAttachmentStore, { dshHome: home, imageCompressionConcurrency: 1 });
  const store = ctx.attachments;
  await mkdir(join(store.root, 'objects', ref.attachmentId.slice(7, 9)), { recursive: true });
  await writeFile(store.imageHostPath(ref), source);
  t.after(async () => {
    fixture.encodeGate?.resolve();
    await ctx.fiber.dispose();
    await rm(home, { recursive: true, force: true });
  });
  const cache = () => {
    const id = requestImageVariantId(ref, target).slice(7);
    return join(store.cacheRoot, 'request-images', id.slice(0, 2), id);
  };
  return { store, cache };
}
async function until(predicate) {
  const end = performance.now() + 5000;
  while (!predicate()) {
    assert(performance.now() < end, 'fixture scheduling reached the expected actual method boundary');
    await new Promise(resolve => setImmediate(resolve));
  }
}
async function retired(store) {
  await until(() => store.requestInflight.size === 0 && store.compression.active === 0 && store.compression.waiting.length === 0);
}

test('public persistent variant keeps all original codec and target identity inputs', async t => {
  await prepare(t);
  const expected = 'sha256:' + hash(JSON.stringify({ transformVersion: 'request-image-v6-ohos-ndk26-v1',
    attachmentId: ref.attachmentId, targetWidth: target.width, targetHeight: target.height,
    encodedByteBudget: target.maxBytes, encoding: identity }));
  assert.equal(requestImageVariantId(ref, target), expected);
  for (const key of ['width', 'height', 'maxBytes']) assert.notEqual(requestImageVariantId(ref, { ...target, [key]: target[key] + 1 }), expected);
  assert.notEqual(requestImageVariantId({ ...ref, attachmentId: 'sha256:' + 'f'.repeat(64) }, target), expected);
  for (const key of Object.keys(identity)) {
    fixture.identity = { ...identity, [key]: 'changed-fixture-identity:' + key };
    assert.notEqual(requestImageVariantId(ref, target), expected, key + ' remains in the persistent identity');
  }
});

test('known-sRGB codec seam keeps valid cache hits and exact public variant', async t => {
  const { store, cache } = await prepare(t);
  const first = await store.readImageRequest(ref, target);
  const second = await store.readImageRequest(ref, target);
  assert.equal(fixture.encodes.length, 1);
  assert.deepEqual(second, first);
  assert.deepEqual(await readFile(cache()), Buffer.from(first.data));
  await retired(store);
});

for (const [label, marker] of [['unknown source colour', 3], ['unsupported cached format', 4]]) {
  test('discardable cache ' + label + ' falls back to the verified source', async t => {
    const { store, cache } = await prepare(t);
    const first = await store.readImageRequest(ref, target);
    await writeFile(cache(), Uint8Array.from([marker, 3, 2, 88]));
    const second = await store.readImageRequest(ref, target);
    assert.equal(fixture.encodes.length, 2);
    assert.deepEqual(second, first);
    assert.deepEqual(await readFile(cache()), Buffer.from(first.data));
    await retired(store);
  });
}

test('cache fallback never swallows an unretired native owner', async t => {
  const { store, cache } = await prepare(t);
  await store.readImageRequest(ref, target);
  await writeFile(cache(), Uint8Array.from([5, 3, 2, 88]));
  await assert.rejects(store.readImageRequest(ref, target), error => {
    assert.equal(error.code, 'ATTACHMENT_WRITE_FAILED');
    assert.equal(error.nativeCode, 'OHOS_IMAGE_CLEANUP_UNCONFIRMED');
    assert.equal(error.retirement.confirmed, false); return true;
  });
  assert.equal(fixture.encodes.length, 1);
  await retired(store);
});

test('cache capability error preserves an already aborted request reason', async t => {
  const { store, cache } = await prepare(t);
  await store.readImageRequest(ref, target);
  await writeFile(cache(), Uint8Array.from([6, 3, 2, 88]));
  const controller = new AbortController(), reason = new Error('explicit caller cancellation');
  fixture.abortCache = () => controller.abort(reason);
  await assert.rejects(store.readImageRequest(ref, target, controller.signal), error => error === reason);
  assert.equal(fixture.encodes.length, 1);
  await retired(store);
});

test('same request still shares one operation while one caller cancels', async t => {
  const { store } = await prepare(t);
  fixture.encodeGate = Promise.withResolvers();
  const controller = new AbortController(), reason = new Error('one caller cancelled');
  const first = store.readImageRequest(ref, target, controller.signal);
  const cancelled = assert.rejects(first, error => error === reason);
  const second = store.readImageRequest(ref, target);
  await until(() => fixture.encodes.length === 1);
  assert.equal(store.requestInflight.size, 1);
  assert.equal(store.compression.active, 1);
  assert.equal(store.compression.waiting.length, 0);
  controller.abort(reason); await cancelled;
  fixture.encodeGate.resolve();
  const result = await second;
  assert.equal(result.variantId, requestImageVariantId(ref, target));
  assert.equal(fixture.encodes.length, 1);
  await retired(store);
});

test('different targets retain separate shared operations and compression limit', async t => {
  const { store } = await prepare(t);
  fixture.encodeGate = Promise.withResolvers();
  const first = store.readImageRequest(ref, target);
  const nextTarget = { ...target, width: 2, height: 1 };
  const second = store.readImageRequest(ref, nextTarget);
  await until(() => fixture.encodes.length === 1 && store.compression.waiting.length === 1);
  assert.equal(store.requestInflight.size, 2);
  assert.equal(store.compression.active, 1);
  fixture.encodeGate.resolve();
  const results = await Promise.all([first, second]);
  assert.notEqual(results[0].variantId, results[1].variantId);
  assert.equal(fixture.encodes.length, 2);
  await retired(store);
});
