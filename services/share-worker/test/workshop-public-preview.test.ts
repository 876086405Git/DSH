import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { workshop } from '../src/workshop';
import { WorkshopArchive } from '../src/workshop-archive';
import { assetUrl, metadata, PREVIEW_CONTRACT, previewKey, previewUrl, type SubmissionMeta } from '../src/workshop-common';
import { STATE_KEY } from '../src/workshop-state';
import { makeCtx, makeEnv } from './fakes';
import { PetBucket } from './pet-market-fakes';
import { companion, metaFor, pet, petManifest, png, zip } from './workshop-fixtures';

const API = '/api/workshop/v1';
beforeEach(() => { vi.spyOn(globalThis, 'fetch').mockImplementation(async () => new Response(JSON.stringify({ id: 42, login: 'synthetic-preview-author' }))); });
afterEach(() => vi.restoreAllMocks());
function setup() {
  const bucket = new PetBucket(), f = makeEnv({ BUCKET: bucket as unknown as R2Bucket });
  const call = (path: string, method = 'GET', body?: object | Uint8Array, admin = false, headers: Record<string, string> = {}) => workshop(new Request('https://example.org' + path, {
    method, headers: { Authorization: 'Bearer synthetic_github_token', 'X-Workshop-Account-Origin': 'https://github.com',
      ...(admin ? { 'X-Admin-Key': f.env.ADMIN_KEY! } : {}), ...(body ? { 'Content-Type': body instanceof Uint8Array ? 'application/zip' : 'application/json' } : {}), ...headers },
    ...(body ? { body: body instanceof Uint8Array ? body : JSON.stringify(body) } : {}),
  }), f.env, makeCtx().ctx);
  let serial = 0;
  const create = async (bytes = pet(), overrides: Partial<SubmissionMeta> = { previewSource: 'pet-idle' }, requestId = `preview_request_${++serial}`.padEnd(16, '_')) => {
    const meta = metaFor(bytes, overrides), response = await call(API + '/submissions', 'POST', { ...meta, requestId });
    expect(response.status).toBe(201); const { submission } = await response.json() as any; return { sid: submission.submissionId as string, meta, bytes, requestId };
  };
  const upload = (item: Awaited<ReturnType<typeof create>>) => call(`${API}/submissions/${item.sid}/archive`, 'PUT', item.bytes);
  const review = (sid: string, decision = 'approve') => call(`${API}/admin/submissions/${sid}/review`, 'POST', { decision, reason: 'Synthetic preview review' }, true);
  const withdraw = (sid: string) => call(`${API}/submissions/${sid}/withdraw`, 'POST', { reason: 'Synthetic withdrawal' });
  const publish = async (overrides: Partial<SubmissionMeta> = { previewSource: 'pet-idle' }) => {
    const item = await create(pet(), overrides), response = await upload(item); expect(response.status).toBe(200);
    const { submission } = await response.json() as any; expect((await review(item.sid)).status).toBe(200); return { ...item, submission };
  };
  const state = () => JSON.parse(new TextDecoder().decode(bucket.objects.get(STATE_KEY)!.bytes));
  return { ...f, bucket, call, create, upload, review, withdraw, publish, state };
}
const privatePath = (sid: string) => `${API}/admin/submissions/${sid}/public-preview`;

it('announces the exact optional contract and binds the opt-in to normalized requestId metadata', async () => {
  const f = setup();
  const contract = (await (await f.call(API + '/capabilities')).json() as any).preview;
  expect(contract).toEqual(PREVIEW_CONTRACT); expect(contract.petIdleDownscale).toBe(true);
  const item = await f.create(), changed = { ...item.meta }; delete changed.previewSource;
  const retry = await f.call(API + '/submissions', 'POST', { ...changed, requestId: item.requestId });
  expect(retry.status).toBe(409); expect(await retry.json()).toEqual({ error: 'workshop_request_id_reused' });
  expect(f.state().submissions[0].metadata).toEqual(metadata(item.meta)); expect(f.state().submissions[0]).not.toHaveProperty('preview');
});
it('keeps old no-opt-in uploads, private image inspection and public entries image-free', async () => {
  const f = setup(), item = await f.create(pet(), {}); expect((await f.upload(item)).status).toBe(200);
  expect((await f.call(privatePath(item.sid), 'GET', undefined, true)).status).toBe(404);
  const original = await f.call(`${API}/admin/submissions/${item.sid}/preview?file=0`, 'GET', undefined, true);
  expect(original.status).toBe(200); expect(new Uint8Array(await original.arrayBuffer())).toEqual(new Uint8Array(png()));
  expect((await f.review(item.sid)).status).toBe(200);
  const catalog = await (await f.call('/market/workshop.json')).json() as any;
  expect(catalog.entries[0]).not.toHaveProperty('preview'); expect(catalog.entries[0]).not.toHaveProperty('previewSource');
  expect([...f.bucket.objects.keys()].filter(key => key.startsWith('workshop/previews/'))).toEqual([]);
  expect((await f.call(assetUrl(item.meta))).status).toBe(200);
});
it('shows the registered pending PNG only to an administrator and publishes those exact bytes after approval', async () => {
  const f = setup(), item = await f.create(); const uploaded = await f.upload(item); expect(uploaded.status).toBe(200);
  const { submission } = await uploaded.json() as any, preview = submission.preview;
  expect(preview).toEqual({ path: previewUrl(item.meta, preview.sha256), sha256: preview.sha256, size: preview.size, width: 1, height: 1 });
  const before = f.bucket.gets.length, unauthorized = await f.call(privatePath(item.sid));
  expect(unauthorized.status).toBe(401); expect(f.bucket.gets.length).toBe(before);
  expect((await f.call(preview.path)).status).toBe(404);
  expect(f.bucket.gets.slice(before).every(row => row.key === STATE_KEY)).toBe(true);
  const admin = await f.call(privatePath(item.sid), 'GET', undefined, true), shown = new Uint8Array(await admin.arrayBuffer());
  expect(admin.status).toBe(200); expect(admin.headers.get('Cache-Control')).toBe('private, no-store');
  expect(admin.headers.get('Content-Type')).toBe('image/png'); expect(admin.headers.get('X-Content-Type-Options')).toBe('nosniff');
  expect((await f.call(privatePath(item.sid) + '?file=0', 'GET', undefined, true)).status).toBe(400);
  expect((await f.review(item.sid)).status).toBe(200);
  const catalog = await (await f.call('/market/workshop.json')).json() as any;
  expect(catalog.entries[0].preview).toEqual(preview); expect(catalog.entries[0].previewSource).toBe('pet-idle');
  const published = await f.call(preview.path); expect(published.status).toBe(200);
  expect(new Uint8Array(await published.arrayBuffer())).toEqual(shown); expect(f.state().releases[0]).not.toHaveProperty('preview');
});
it('publishes a derived large-cell preview while serving the original ZIP unchanged', async () => {
  const f = setup(), pack = petManifest(), box = { x: 0, y: 0, w: 1024, h: 4 };
  pack.canvas = { w: box.w, h: box.h }; pack.contentBox = box;
  pack.animations.idle = { ...pack.animations.idle, frameW: box.w, frameH: box.h, box };
  const bytes = zip([['pack.json', Buffer.from(JSON.stringify(pack))], ['idle.png', png(box.w, box.h)]]);
  const item = await f.create(bytes), uploaded = await f.upload(item);
  expect(uploaded.status).toBe(200);
  const { submission } = await uploaded.json() as any;
  expect(submission.preview).toMatchObject({ width: 512, height: 2 });
  expect((await f.review(item.sid)).status).toBe(200);
  const published = await f.call(submission.preview.path);
  expect(published.status).toBe(200); expect(published.headers.get('Content-Type')).toBe('image/png');
  const archive = await f.call(assetUrl(item.meta));
  expect(archive.status).toBe(200);
  expect(new Uint8Array(await archive.arrayBuffer())).toEqual(new Uint8Array(bytes));
});
it('returns authorized full PNG and HEAD despite Range/conditional headers and rejects other verbs', async () => {
  const f = setup(), item = await f.publish(), p = item.submission.preview;
  const response = await f.call(p.path, 'GET', undefined, false, { Range: 'bytes=0-1', 'If-None-Match': '*', 'If-Modified-Since': 'Wed, 01 Jan 2031 00:00:00 GMT' });
  expect(response.status).toBe(200); expect((await response.arrayBuffer()).byteLength).toBe(p.size);
  expect(response.headers.get('Cache-Control')).toBe('private, no-store'); expect(response.headers.get('Content-Range')).toBeNull();
  const head = await f.call(p.path, 'HEAD', undefined, false, { 'If-None-Match': '*' });
  expect(head.status).toBe(200); expect(head.headers.get('Content-Length')).toBe(String(p.size)); expect(await head.text()).toBe('');
  expect((await f.call(p.path, 'POST')).status).toBe(405);
});
it('requires the current descriptor and both archive/version path identities before reading the image', async () => {
  const f = setup(), item = await f.publish(), p = item.submission.preview, before = f.bucket.gets.length;
  for (const path of [p.path.replace(item.meta.sha256, 'a'.repeat(64)), p.path.replace('/1.0.0/', '/1.0.1/'), p.path.replace('/sample/', '/another/'), p.path.replace(p.sha256 + '.png', 'b'.repeat(64) + '.png')]) {
    expect((await f.call(path)).status).toBe(404);
  }
  expect(f.bucket.gets.slice(before).every(row => row.key === STATE_KEY)).toBe(true);
});
it('does not publish rejected or withdrawn pending images', async () => {
  const f = setup(), rejected = await f.create(), r = await (await f.upload(rejected)).json() as any;
  expect((await f.review(rejected.sid, 'reject')).status).toBe(200); expect((await f.call(r.submission.preview.path)).status).toBe(404);
  const withdrawn = await f.create(), w = await (await f.upload(withdrawn)).json() as any;
  expect((await f.withdraw(withdrawn.sid)).status).toBe(200); expect((await f.call(w.submission.preview.path)).status).toBe(404);
});
it('keeps preview selection local to a newly reviewed submission for the same immutable archive release', async () => {
  const f = setup(), original = await f.publish(), p = original.submission.preview;
  const without = await f.create(pet(), {}); expect((await f.upload(without)).status).toBe(200); expect((await f.review(without.sid)).status).toBe(200);
  expect((await f.call(p.path)).status).toBe(404); expect(f.state().releases).toHaveLength(1);
  const again = await f.create(); expect((await f.upload(again)).status).toBe(200); expect((await f.review(again.sid)).status).toBe(200);
  expect((await f.call(p.path)).status).toBe(200); expect(f.state().releases).toHaveLength(1);
  expect(f.bucket.writes.filter(key => key === previewKey(p.sha256))).toHaveLength(1);
});
it('authorizes shared image bytes per version and revokes only the withdrawn release path', async () => {
  const f = setup(), v1 = await f.publish(), v2 = await f.publish({ previewSource: 'pet-idle', version: '2.0.0' });
  expect(v1.submission.preview.sha256).toBe(v2.submission.preview.sha256);
  expect((await f.call(v1.submission.preview.path)).status).toBe(404);
  expect((await f.withdraw(v1.sid)).status).toBe(200); expect((await f.call(v2.submission.preview.path)).status).toBe(200);
  expect((await f.withdraw(v2.sid)).status).toBe(200);
  expect((await f.call(v2.submission.preview.path, 'GET', undefined, false, { 'If-None-Match': '*' })).status).toBe(404);
  expect((await f.call(v2.submission.preview.path, 'HEAD')).status).toBe(404);
  expect(f.bucket.objects.has(previewKey(v2.submission.preview.sha256))).toBe(true);
});
it('allows upload kill-switch read access but retains the companion-specific publication gate', async () => {
  const f = setup(), source = new WorkshopArchive(companion(), 1000), image = png(2, 2);
  const bytes = zip([...source.files.keys()].map(path => [path, source.read(path, 1024 * 1024)] as [string, Uint8Array]).concat([['character/preview.png', image]]));
  const item = await f.create(bytes, { kind: 'companion', previewSource: 'companion-preview' });
  const uploaded = await f.upload(item); expect(uploaded.status).toBe(200); const p = (await uploaded.json() as any).submission.preview;
  expect((await f.review(item.sid)).status).toBe(200); f.env.WORKSHOP_UPLOAD_ENABLED = '0';
  const response = await f.call(p.path); expect(response.status).toBe(200); expect(new Uint8Array(await response.arrayBuffer())).toEqual(new Uint8Array(image));
  f.env.WORKSHOP_COMPANION_ENABLED = '0';
  expect((await f.call(p.path)).status).toBe(503); expect((await f.call('/market/companions.json')).status).toBe(503);
  expect((await (await f.call('/market/workshop.json')).json() as any).entries).toEqual([]);
});
it('does not regenerate a missing pending image on repeated upload or approval', async () => {
  const f = setup(), item = await f.create(); const first = await (await f.upload(item)).json() as any, p = first.submission.preview;
  f.bucket.objects.delete(previewKey(p.sha256));
  expect((await (await f.upload(item)).json() as any).submission.preview).toEqual(p);
  const response = await f.review(item.sid); expect(response.status).toBe(503); expect(await response.json()).toEqual({ error: 'workshop_storage_unavailable' });
  expect(f.state().submissions[0].status).toBe('pending'); expect(f.state().current).toEqual([]);
});
it('fails closed when the stored PNG checksum no longer matches the registered bytes', async () => {
  const f = setup(), item = await f.publish(), p = item.submission.preview;
  f.bucket.objects.get(previewKey(p.sha256))!.bytes = new Uint8Array(png(1, 1, [0, 255, 0, 255]));
  for (const method of ['GET', 'HEAD']) {
    const response = await f.call(p.path, method); expect(response.status).toBe(503); expect(await response.json()).toEqual({ error: 'workshop_storage_unavailable' });
  }
});
it('leaves a private image orphan after a concurrent draft withdrawal without registering pending', async () => {
  const f = setup(), item = await f.create(), put = f.bucket.put.bind(f.bucket);
  vi.spyOn(f.bucket, 'put').mockImplementation(async (key, value, options) => {
    const result = await put(key, value, options);
    if (key.startsWith('workshop/previews/')) expect((await f.withdraw(item.sid)).status).toBe(200);
    return result;
  });
  const response = await f.upload(item); expect(response.status).toBe(409); expect(f.state().submissions[0].status).toBe('withdrawn');
  const key = [...f.bucket.objects.keys()].find(key => key.startsWith('workshop/previews/'))!;
  expect((await f.call(previewUrl(item.meta, key.slice('workshop/previews/'.length, -4)))).status).toBe(404);
});
it('rechecks pending state after long approval reads so a concurrent withdrawal wins', async () => {
  const f = setup(), item = await f.create(); const p = (await (await f.upload(item)).json() as any).submission.preview;
  const get = f.bucket.get.bind(f.bucket); let withdrawn = false;
  vi.spyOn(f.bucket, 'get').mockImplementation(async (key, options) => {
    if (key === previewKey(p.sha256) && !withdrawn) { withdrawn = true; expect((await f.withdraw(item.sid)).status).toBe(200); }
    return get(key, options);
  });
  expect((await f.review(item.sid)).status).toBe(409); expect(f.state().current).toEqual([]);
  expect(f.state().submissions[0].status).toBe('withdrawn'); expect((await f.call(p.path)).status).toBe(404);
});
it('retains a draft when writing the derived private image fails', async () => {
  const f = setup(), item = await f.create(), put = f.bucket.put.bind(f.bucket);
  vi.spyOn(f.bucket, 'put').mockImplementation((key, value, options) => key.startsWith('workshop/previews/') ? Promise.reject(new Error('synthetic write failure')) : put(key, value, options));
  expect((await f.upload(item)).status).toBe(503); expect(f.state().submissions[0].status).toBe('draft');
  expect(f.state().submissions[0]).not.toHaveProperty('preview'); expect(f.state().audit.map((e: any) => e.action)).toEqual(['create']);
});
it('keeps a failed pending CAS private and recovers with the original archive and requestId', async () => {
  const f = setup(), item = await f.create(), put = f.bucket.put.bind(f.bucket); let rejectPending = true;
  vi.spyOn(f.bucket, 'put').mockImplementation((key, value, options) => {
    if (key === STATE_KEY && rejectPending) { rejectPending = false; return Promise.resolve(null); }
    return put(key, value, options);
  });
  const failed = await f.upload(item); expect(failed.status).toBe(409); expect(await failed.json()).toEqual({ error: 'workshop_state_conflict' });
  expect(f.state().submissions[0].status).toBe('draft'); expect(f.state().submissions[0]).not.toHaveProperty('preview');
  const key = [...f.bucket.objects.keys()].find(key => key.startsWith('workshop/previews/'))!;
  expect((await f.call(previewUrl(item.meta, key.slice('workshop/previews/'.length, -4)))).status).toBe(404);
  const repeatedCreate = await f.call(API + '/submissions', 'POST', { ...item.meta, requestId: item.requestId }); expect(repeatedCreate.status).toBe(200);
  const recovered = await f.upload(item); expect(recovered.status).toBe(200); expect((await recovered.json() as any).submission.preview).toBeDefined();
  expect(f.bucket.writes.filter(value => value.startsWith('workshop/previews/'))).toHaveLength(1);
});
it('reads a declared preview with no registered image as image-free instead of refusing the state', async () => {
  const f = setup(), item = await f.publish(), state = f.state();
  // What a Worker without previews leaves behind when it takes the archive.
  delete state.submissions[0].preview;
  await f.bucket.put(STATE_KEY, new TextEncoder().encode(JSON.stringify(state)));
  const catalog = await f.call('/market/workshop.json'); expect(catalog.status).toBe(200);
  const entry = (await catalog.json() as any).entries[0];
  expect(entry.previewSource).toBe('pet-idle'); expect(entry).not.toHaveProperty('preview');
  expect((await f.call(item.submission.preview.path)).status).toBe(404);
  expect((await f.call(assetUrl(item.meta))).status).toBe(200);
});
it('counts picture requests apart from the catalog and package downloads', async () => {
  const f = setup(), item = await f.publish(), keys: string[] = [];
  f.env.READ_LIMIT = { limit: async ({ key }: { key: string }) => { keys.push(key); return { success: !key.startsWith('workshop-preview:') }; } } as unknown as NonNullable<typeof f.env.READ_LIMIT>;
  const picture = await f.call(item.submission.preview.path); expect(picture.status).toBe(429);
  expect(await picture.json()).toEqual({ error: 'workshop_rate_limited' });
  expect((await f.call('/market/workshop.json')).status).toBe(200);
  expect((await f.call(assetUrl(item.meta))).status).toBe(200);
  expect(keys.filter(key => key.startsWith('workshop-preview:'))).toHaveLength(1);
  expect(keys.filter(key => key.startsWith('workshop:'))).toHaveLength(2);
});
it('rejects a persisted descriptor whose path does not match its own submission', async () => {
  const f = setup(), item = await f.publish(), state = f.state();
  state.submissions[0].preview.path = state.submissions[0].preview.path.replace('/sample/', '/another/');
  await f.bucket.put(STATE_KEY, new TextEncoder().encode(JSON.stringify(state)));
  const response = await f.call(item.submission.preview.path); expect(response.status).toBe(503);
  expect(await response.json()).toEqual({ error: 'workshop_state_invalid' });
});
