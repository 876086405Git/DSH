// Actual attachment module and Cordis; codec completion/failure is an explicit seam.
// Native image work is separately counted by attachment-cache-proof-native.mjs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createRequire, syncBuiltinESMExports } from 'node:module';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

assert.equal(process.platform, 'openharmony');
const prefix = resolve(process.env.DSH_PREFIX);
const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await load('cordis');
const { LocalAttachmentStore, requestImageVariantId, readRequestImageFile } = await load('dsh-attachment-local');
const fs = createRequire(import.meta.url)('node:fs/promises');
const originalRename = fs.rename;
const hash = data => createHash('sha256').update(data).digest('hex');
const identity = { buildId: 'declared-completed-close-seam', colourspace: 'srgb' };
const source = Uint8Array.from([1, 6, 4, 99]);
const encoded = Uint8Array.from([2, 3, 2, 77]);
const ref = { attachmentId: 'sha256:' + hash(source), bytes: source.length, width: 6, height: 4,
  mediaType: 'image/png', name: 'explicit-proof-seam.png' };
const target = { width: 3, height: 2, maxBytes: 1024 };
let fixture;
function metadata(data) {
  return { mediaType: data[0] === 1 ? 'image/png' : 'image/jpeg', width: data[1], height: data[2],
    depth: 'uchar', space: undefined, hasAlpha: false, animated: false, carriesMetadata: false };
}
const codec = Object.freeze({ protocolVersion: 1, identity: () => fixture.identity,
  async probe(data) {
    if (data[0] !== 1) {
      fixture.cacheProbe?.();
      if (fixture.cacheError) throw fixture.cacheError;
      return { ...metadata(data), ...fixture.cacheFacts };
    }
    return metadata(data);
  },
  async detect(data) { return metadata(data); },
  async encode(data, requestTarget) {
    assert.deepEqual(data, source);
    fixture.encodes.push({ ...requestTarget });
    if (fixture.closeGate) await fixture.closeGate.promise;
    if (fixture.closeError) throw fixture.closeError;
    fixture.completedCloses++;
    return { data: Uint8Array.from(encoded), mediaType: 'image/jpeg', width: 3, height: 2, hasAlpha: false };
  },
});
assert.equal(globalThis[Symbol.for('dsh.go.ohos.image-codec')], undefined);
Object.defineProperty(globalThis, Symbol.for('dsh.go.ohos.image-codec'), { value: codec });

async function until(check) {
  const end = performance.now() + 5000;
  while (!check()) {
    assert(performance.now() < end, 'actual asynchronous boundary reached');
    await new Promise(resolve => setImmediate(resolve));
  }
}
async function retired(store) {
  await until(() => store.requestInflight.size === 0 && store.compression.active === 0 && store.compression.waiting.length === 0);
}
async function another(home) {
  const ctx = new Context();
  await ctx.plugin(LocalAttachmentStore, { dshHome: home, imageCompressionConcurrency: 1 });
  return { ctx, store: ctx.attachments };
}
async function prepare(t) {
  fixture = { identity: { ...identity }, encodes: [], completedCloses: 0 };
  const home = await mkdtemp(join(tmpdir(), 'attachment-proof-seam-'));
  const { ctx, store } = await another(home);
  await mkdir(join(store.root, 'objects', ref.attachmentId.slice(7, 9)), { recursive: true });
  await writeFile(store.imageHostPath(ref), source);
  t.after(async () => {
    fixture.closeGate?.resolve();
    fs.rename = originalRename; syncBuiltinESMExports();
    await retired(store);
    await ctx.fiber.dispose();
    await rm(home, { recursive: true, force: true });
  });
  const cache = (forTarget = target) => {
    const id = requestImageVariantId(ref, forTarget).slice(7);
    return join(store.cacheRoot, 'request-images', id.slice(0, 2), id);
  };
  const put = async (bytes = encoded, forTarget = target) => {
    const path = cache(forTarget);
    await mkdir(join(path, '..'), { recursive: true });
    await writeFile(path, bytes);
  };
  return { home, ctx, store, cache, put };
}
function interceptRename(callback) {
  fs.rename = async (...args) => { await originalRename(...args); callback(); };
  syncBuiltinESMExports();
}

test('unknown-space warm bytes reuse only a completed publication proof', async t => {
  const { store } = await prepare(t);
  const first = await store.readImageRequest(ref, target);
  const second = await store.readImageRequest(ref, target);
  assert.deepEqual(second, first);
  assert.equal(fixture.encodes.length, 1);
  assert.equal(fixture.completedCloses, 1);
  assert.equal((await codec.probe(encoded)).space, undefined);
});

test('caller-owned byte aliases and metadata cannot mutate the stored proof', async t => {
  const { store, cache } = await prepare(t);
  const first = await store.readImageRequest(ref, target);
  Buffer.from(first.data.buffer, first.data.byteOffset, first.data.byteLength).fill(9);
  Object.assign(first, { width: 99, height: 99, mediaType: 'image/png', hasAlpha: true });
  const second = await store.readImageRequest(ref, target);
  assert.deepEqual(second.data, encoded);
  assert.equal(second.width, 3); assert.equal(second.hasAlpha, false);
  second.data.fill(0);
  const third = await store.readImageRequest(ref, target);
  assert.deepEqual(third.data, encoded);
  assert.deepEqual(await readFile(cache()), Buffer.from(encoded));
  assert.equal(fixture.encodes.length, 1);
});

test('current disk SHA is required even when all probed fields match', async t => {
  const { store, put } = await prepare(t);
  await store.readImageRequest(ref, target);
  await put(Uint8Array.from([2, 3, 2, 88]));
  assert.deepEqual((await store.readImageRequest(ref, target)).data, encoded);
  assert.equal(fixture.encodes.length, 2);
});

test('one record is evicted by a different variant even for identical encoded bytes', async t => {
  const { store } = await prepare(t);
  const next = { ...target, maxBytes: target.maxBytes + 1 };
  const first = await store.readImageRequest(ref, target);
  const second = await store.readImageRequest(ref, next);
  assert.notEqual(first.variantId, second.variantId);
  await store.readImageRequest(ref, target);
  await store.readImageRequest(ref, target);
  assert.equal(fixture.encodes.length, 3);
});

test('a changed current codec identity cannot reuse or preserve the old proof', async t => {
  const { store, put } = await prepare(t);
  const first = await store.readImageRequest(ref, target);
  fixture.identity = { ...identity, buildId: 'different-codec-identity' };
  await put();
  const second = await store.readImageRequest(ref, target);
  assert.notEqual(second.variantId, first.variantId);
  fixture.identity = { ...identity };
  await store.readImageRequest(ref, target);
  assert.equal(fixture.encodes.length, 3);
});

test('different instances cannot borrow proof; disposing an old owner preserves the new proof', async t => {
  const { home, ctx, store } = await prepare(t);
  await store.readImageRequest(ref, target);
  const second = await another(home);
  t.after(() => second.ctx.fiber.dispose());
  await second.store.readImageRequest(ref, target);
  assert.equal(fixture.encodes.length, 2);
  await ctx.fiber.dispose();
  await second.store.readImageRequest(ref, target);
  assert.equal(fixture.encodes.length, 2);
});

test('dispose during delayed close prevents a late publication from reviving its owner', async t => {
  const { ctx, store } = await prepare(t);
  fixture.closeGate = Promise.withResolvers();
  const pending = store.readImageRequest(ref, target);
  await until(() => fixture.encodes.length === 1);
  await ctx.fiber.dispose();
  fixture.closeGate.resolve(); await pending;
  await store.readImageRequest(ref, target);
  await store.readImageRequest(ref, target);
  assert.equal(fixture.encodes.length, 3, 'retained method references cannot create proof after disposal');
});

test('a real rename failure never registers otherwise verified bytes', async t => {
  const { store, cache, put } = await prepare(t);
  await mkdir(cache(), { recursive: true });
  await assert.rejects(store.readImageRequest(ref, target), error => ['EISDIR', 'ENOTDIR'].includes(error.code));
  await retired(store); await rm(cache(), { recursive: true }); await put();
  await store.readImageRequest(ref, target);
  assert.equal(fixture.encodes.length, 2);
});

test('abort after real rename preserves the reason and does not register published bytes', async t => {
  const { store, cache } = await prepare(t);
  const controller = new AbortController(), reason = new Error('cancelled after actual rename');
  interceptRename(() => controller.abort(reason));
  await assert.rejects(store.readImageRequest(ref, target, controller.signal), error => error === reason);
  await retired(store);
  fs.rename = originalRename; syncBuiltinESMExports();
  assert.deepEqual(await readFile(cache()), Buffer.from(encoded));
  await store.readImageRequest(ref, target);
  assert.equal(fixture.encodes.length, 2);
});

test('dispose after real rename revokes proof before the private write promise returns', async t => {
  const { ctx, store } = await prepare(t);
  let disposed;
  interceptRename(() => { disposed = ctx.fiber.dispose(); });
  await store.readImageRequest(ref, target); await disposed;
  fs.rename = originalRename; syncBuiltinESMExports();
  await store.readImageRequest(ref, target);
  assert.equal(fixture.encodes.length, 2);
});

test('all callers aborting during close never publishes or records late success', async t => {
  const { store, cache, put } = await prepare(t);
  fixture.closeGate = Promise.withResolvers();
  const controller = new AbortController(), reason = new Error('cancelled during close');
  const pending = assert.rejects(store.readImageRequest(ref, target, controller.signal), error => error === reason);
  await until(() => fixture.encodes.length === 1);
  controller.abort(reason); await pending;
  fixture.closeGate.resolve(); await retired(store);
  await assert.rejects(readFile(cache()), { code: 'ENOENT' });
  await put(); await store.readImageRequest(ref, target);
  assert.equal(fixture.encodes.length, 2);
});

test('unconfirmed close is retained as an error and cannot grant cache proof', async t => {
  const { store, put } = await prepare(t);
  fixture.closeError = Object.assign(new Error('explicit close failure seam'), {
    code: 'OHOS_IMAGE_CLEANUP_UNCONFIRMED', resourcesRetired: false, retirement: { confirmed: false } });
  await assert.rejects(store.readImageRequest(ref, target), error => error.code === 'ATTACHMENT_WRITE_FAILED'
    && error.nativeCode === 'OHOS_IMAGE_CLEANUP_UNCONFIRMED' && error.retirement.confirmed === false);
  await retired(store); fixture.closeError = undefined;
  await put(); await store.readImageRequest(ref, target);
  assert.equal(fixture.encodes.length, 2);
  assert.equal(fixture.completedCloses, 1);
});

test('an unretired cache probe is never bypassed by a matching byte proof', async t => {
  const { store } = await prepare(t);
  await store.readImageRequest(ref, target);
  fixture.cacheError = Object.assign(new Error('explicit probe cleanup failure'), {
    code: 'OHOS_IMAGE_CLEANUP_UNCONFIRMED', retirement: { confirmed: false }, resourcesRetired: false });
  await assert.rejects(store.readImageRequest(ref, target), error => error.nativeCode === 'OHOS_IMAGE_CLEANUP_UNCONFIRMED');
  assert.equal(fixture.encodes.length, 1);
});

test('abort during a matching cache probe keeps the caller reason', async t => {
  const { store } = await prepare(t);
  await store.readImageRequest(ref, target);
  const controller = new AbortController(), reason = new Error('cancelled while probing matching bytes');
  fixture.cacheProbe = () => controller.abort(reason);
  fixture.cacheError = Object.assign(new Error('capability failure'), { code: 'OHOS_IMAGE_CODEC_UNAVAILABLE' });
  await assert.rejects(store.readImageRequest(ref, target, controller.signal), error => error === reason);
  assert.equal(fixture.encodes.length, 1);
});

for (const [field, value] of [['width', 2], ['height', 1], ['hasAlpha', true], ['mediaType', 'image/png'], ['depth', 'ushort'], ['space', 'other']]) {
  test('same bytes with incompatible current ' + field + ' cannot borrow proof facts', async t => {
    const { store } = await prepare(t);
    await store.readImageRequest(ref, target);
    fixture.cacheFacts = { [field]: value };
    await store.readImageRequest(ref, target);
    assert.equal(fixture.encodes.length, 2);
  });
}

test('the existing exported helper cannot be given a forged proof or owner argument', async t => {
  const { store } = await prepare(t);
  await store.readImageRequest(ref, target);
  const attachment = await store.readImage(ref);
  await readRequestImageFile(store.cacheRoot, attachment, target, undefined, {
    active: true, proof: { variantId: requestImageVariantId(ref, target), sha256: hash(encoded) } });
  assert.equal(fixture.encodes.length, 2);
});

test('one cancelled waiter does not revoke a shared successful publication', async t => {
  const { store } = await prepare(t);
  fixture.closeGate = Promise.withResolvers();
  const controller = new AbortController(), reason = new Error('one waiter cancelled');
  const first = assert.rejects(store.readImageRequest(ref, target, controller.signal), error => error === reason);
  const second = store.readImageRequest(ref, target);
  await until(() => fixture.encodes.length === 1);
  controller.abort(reason); await first;
  fixture.closeGate.resolve(); await second;
  await store.readImageRequest(ref, target);
  assert.equal(fixture.encodes.length, 1);
});
