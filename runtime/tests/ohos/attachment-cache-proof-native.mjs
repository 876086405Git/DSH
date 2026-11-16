// Actual fixed attachment/preload/NAPI/scanner/ladder; existing explicit host SDK pixels.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, writeFile, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const prefix = resolve(process.env.DSH_PREFIX);
const out = resolve(process.env.DSH_IMAGE_PROOF_OUT);
const home = resolve(process.env.DSH_HOME);
const scenario = process.env.DSH_IMAGE_PROOF_CASE;
const oracle = JSON.parse(await readFile(process.env.DSH_IMAGE_PROOF_ORACLE, 'utf8'));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
assert.equal(process.platform, 'linux');
Object.defineProperty(process, 'platform', { value: 'openharmony' });
await import(pathToFileURL(join(prefix, 'runtime/ohos/sim/marker.mjs')));
await import(pathToFileURL(join(prefix, 'runtime/ohos/publication/preload.mjs')));
await import(pathToFileURL(join(prefix, 'runtime/ohos/image/preload.mjs')));
const codec = globalThis[Symbol.for('dsh.go.ohos.image-codec')];
const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await load('cordis');
const { LocalAttachmentStore, readRequestImageFile } = await load('dsh-attachment-local');
assert.deepEqual(codec.identity(), oracle.identity);
const contexts = [], stores = [], records = [];
const c = oracle.cases.find(row => row.name === (scenario === 'alpha-warm' ? 'transparent-png' : 'opaque-jpeg'));

async function openStore() {
  const ctx = new Context(); await ctx.plugin(LocalAttachmentStore, { dshHome: home });
  contexts.push(ctx); stores.push(ctx.attachments); return { ctx, store: ctx.attachments };
}
async function snapshot(label) {
  const text = await readFile(process.env.DSH_IMAGE_TEST_TRACE, 'utf8');
  const rows = text.trim().split('\n').filter(Boolean).map(JSON.parse);
  const live = new Map(); let creates = 0, releases = 0;
  for (const row of rows) {
    if (row.type === 'create') { assert(!live.has(row.id)); live.set(row.id, row.a); creates++; }
    if (row.type === 'release') { assert.equal(live.get(row.id), row.a); live.delete(row.id); releases++; }
  }
  assert.equal(live.size, 0);
  for (const store of stores) {
    assert.equal(store.requestInflight.size, 0); assert.equal(store.compression.active, 0);
    assert.equal(store.compression.waiting.length, 0);
  }
  const record = { label, creates, releases, packs: rows.filter(row => row.type === 'pack').length,
    sourceDecodes: rows.filter(row => row.type === 'decode' && row.name === 'source').length,
    verifyDecodes: rows.filter(row => row.type === 'decode' && row.name === 'verify').length,
    scales: rows.filter(row => row.type === 'scale').length };
  records.push(record); return record;
}
function difference(a, b) {
  return Object.fromEntries(['packs', 'sourceDecodes', 'verifyDecodes', 'scales'].map(k => [k, b[k] - a[k]]));
}
const converted = n => ({ packs: n, sourceDecodes: n, verifyDecodes: n, scales: n });
async function counted(label, n, action) {
  const before = await snapshot(label + ':before');
  const result = await action(); const after = await snapshot(label + ':after');
  assert.deepEqual(difference(before, after), converted(n), label); return result;
}
function check(result) {
  assert.equal(hash(result.data), c.request.sha256);
  assert.equal(result.width, 3); assert.equal(result.height, 2);
  assert.equal(result.hasAlpha, c.alpha); assert.equal(result.space, 'srgb');
}

await test('actual NDK cache proof: ' + scenario, async () => {
  let status = 'STARTED';
  try {
    const { ctx, store } = await openStore();
    const ref = await store.saveImage({ data: Buffer.from(c.input.hex, 'hex'), mediaType: c.inputMediaType, name: c.file });
    assert.deepEqual(ref, c.ref);
    await snapshot('saved');
    const first = await store.readImageRequest(ref, c.target); check(first);
    assert.equal(first.variantId, c.variantId);
    await snapshot('first-request');
    const cache = join(store.cacheRoot, 'request-images', c.variantId.slice(7, 9), c.variantId.slice(7));
    const cached = await readFile(cache);
    assert.equal((await codec.probe(cached)).space, undefined);
    switch (scenario) {
      case 'warm': case 'alpha-warm':
        check(await counted('adjacent same request', 0, () => store.readImageRequest(ref, c.target)));
        break;
      case 'caller-alias': {
        Buffer.from(first.data.buffer, first.data.byteOffset, first.data.byteLength).fill(0);
        Object.assign(first, { width: 1, height: 1, hasAlpha: true, mediaType: 'image/png' });
        const second = await counted('caller mutated first returned buffer', 0, () => store.readImageRequest(ref, c.target)); check(second);
        second.data.fill(255);
        check(await counted('caller mutated cache-hit returned buffer', 0, () => store.readImageRequest(ref, c.target)));
        assert.equal(hash(await readFile(cache)), c.request.sha256); break;
      }
      case 'same-header-tamper': {
        const changed = Buffer.from(cached); changed[changed.length - 3] ^= 1;
        assert.deepEqual(await codec.probe(changed), await codec.probe(cached));
        await writeFile(cache, changed);
        check(await counted('same scanner facts but different SHA', 1, () => store.readImageRequest(ref, c.target)));
        assert.equal(hash(await readFile(cache)), c.request.sha256); break;
      }
      case 'corrupt-cache':
        await writeFile(cache, Buffer.from('not an image'));
        check(await counted('malformed cache falls back to intact source', 1, () => store.readImageRequest(ref, c.target)));
        break;
      case 'variant-eviction': {
        const target = { ...c.target, maxBytes: c.target.maxBytes + 1 };
        const next = await counted('different variant', 1, () => store.readImageRequest(ref, target)); check(next);
        assert.notEqual(next.variantId, c.variantId);
        check(await counted('old variant evicted', 1, () => store.readImageRequest(ref, c.target)));
        check(await counted('current variant repeated', 0, () => store.readImageRequest(ref, c.target))); break;
      }
      case 'owner-isolation': {
        const second = await openStore();
        check(await counted('new instance cannot borrow', 1, () => second.store.readImageRequest(ref, c.target)));
        await ctx.fiber.dispose();
        check(await counted('old owner disposal preserves latest owner', 0, () => second.store.readImageRequest(ref, c.target))); break;
      }
      case 'disposed-reference':
        await ctx.fiber.dispose();
        check(await counted('disposed retained reference has no proof', 1, () => store.readImageRequest(ref, c.target)));
        check(await counted('late success does not reactivate disposed owner', 1, () => store.readImageRequest(ref, c.target)));
        break;
      case 'public-helper': {
        const input = await store.readImage(ref);
        check(await counted('exported four-argument helper has no proof owner', 1,
          () => readRequestImageFile(store.cacheRoot, input, c.target))); break;
      }
      case 'missing-source': case 'corrupt-source': {
        if (scenario === 'missing-source') await rm(store.imageHostPath(ref));
        else { await rm(store.imageHostPath(ref)); await writeFile(store.imageHostPath(ref), Buffer.from('corrupt source')); }
        const before = await snapshot('source-invalid:before');
        await assert.rejects(store.readImageRequest(ref, c.target), { code: scenario === 'missing-source' ? 'ATTACHMENT_NOT_FOUND' : 'ATTACHMENT_CORRUPT' });
        const after = await snapshot('source-invalid:after');
        assert.deepEqual(difference(before, after), converted(0)); break;
      }
      default: throw new Error('Unknown requested proof scenario: ' + scenario);
    }
    status = 'PASS_SCOPED';
  } catch (error) {
    status = error?.code === 'ERR_ASSERTION' ? 'BEHAVIOR_RED' : 'SETUP_OR_RUNTIME_ERROR';
    throw error;
  } finally {
    for (const ctx of contexts) await ctx.fiber.dispose();
    await snapshot('all-contexts-disposed');
    await writeFile(join(out, 'OBSERVATION.json'), JSON.stringify({ status, scenario, records,
      identity: codec.identity(), nativeSourceSpace: 'UNKNOWN', pixelsDecodedByRealSDK: false, deviceRun: false,
      scope: 'Actual attachment/preload/NAPI/scanner/ladder/publication and file I/O; explicit existing host SDK pixel fixture' }, null, 2) + '\n');
  }
});
