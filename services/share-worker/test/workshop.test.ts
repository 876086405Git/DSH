import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';
import { assetUrl, blobKey } from '../src/workshop-common';
import { STATE_KEY } from '../src/workshop-state';
import { makeCtx, makeEnv } from './fakes';
import { PetBucket } from './pet-market-fakes';
import { companion, largeCompanion, metaFor, pet, petManifest } from './workshop-fixtures';

const API = '/api/workshop/v1';
let githubUser = 42;
beforeEach(() => {
  githubUser = 42;
  vi.spyOn(globalThis, 'fetch').mockImplementation(async () => new Response(JSON.stringify({ id: githubUser, login: `synthetic-${githubUser}` })));
});
afterEach(() => vi.restoreAllMocks());
function setup() {
  const bucket = new PetBucket(), f = makeEnv({ BUCKET: bucket as unknown as R2Bucket });
  const call = (path: string, method = 'GET', body?: object | Uint8Array, admin = false, extra: Record<string, string> = {}) => worker.fetch(new Request('https://example.org' + path, {
    method, headers: { ...(path.startsWith(API) ? { Authorization: 'Bearer synthetic_github_token', 'X-Workshop-Account-Origin': 'https://github.com' } : {}), ...(admin ? { 'X-Admin-Key': f.env.ADMIN_KEY! } : {}),
      ...(body ? { 'Content-Type': body instanceof Uint8Array ? 'application/zip' : 'application/json' } : {}), ...extra },
    ...(body ? { body: body instanceof Uint8Array ? body : JSON.stringify(body) } : {}),
  }), f.env, makeCtx().ctx);
  let serial = 0;
  const create = async (bytes = pet(), overrides = {}, requestId = `synthetic_request_${++serial}`) => {
    const meta = metaFor(bytes, overrides), response = await call(API + '/submissions', 'POST', { ...meta, requestId });
    expect(response.status).toBe(201); const { submission } = await response.json() as any; return { sid: submission.submissionId, meta, bytes, requestId };
  };
  const upload = async (item: Awaited<ReturnType<typeof create>>) => {
    const response = await call(`${API}/submissions/${item.sid}/archive`, 'PUT', item.bytes); expect(response.status).toBe(200); return await response.json() as any;
  };
  const review = (sid: string, decision = 'approve') => call(`${API}/admin/submissions/${sid}/review`, 'POST', { decision, reason: 'Synthetic moderation evidence' }, true);
  const publish = async (bytes = pet(), overrides = {}) => { const item = await create(bytes, overrides); await upload(item); expect((await review(item.sid)).status).toBe(200); return item; };
  const state = () => JSON.parse(new TextDecoder().decode(bucket.objects.get(STATE_KEY)!.bytes));
  return { ...f, bucket, call, create, upload, review, publish, state };
}

it('starts with both capabilities enabled and keeps old pet routes separate', async () => {
  const f = setup();
  expect(await (await f.call(API + '/capabilities')).json()).toMatchObject({ schema: 1, features: { uploads: true, companion: true }, maxMocVersion: 6 });
  expect(await (await f.call('/market/workshop.json')).json()).toMatchObject({ entries: [], withdrawn: [] });
  expect(f.dl.objects.size).toBe(0);
  expect((await f.call('/market/pets.json')).status).toBe(404);
});
const AUTHOR_ROUTES = (sid: string) => [
  ['/submissions', 'GET'], ['/submissions', 'POST'], [`/submissions/${sid}`, 'GET'],
  [`/submissions/${sid}/archive`, 'PUT'], [`/submissions/${sid}/withdraw`, 'POST'], ['/reports', 'POST'],
] as const;
it('requires a well-formed GitHub bearer token at every author entry before any upstream call', async () => {
  const f = setup();
  for (const authorization of [undefined, '', 'Bearer ', 'token synthetic_github_token', 'Bearer gho-has-dash',
    'Bearer two words', `Bearer ${'a'.repeat(256)}`]) {
    for (const [path, method] of AUTHOR_ROUTES('0123456789abcdef0123456789abcdef')) {
      const response = await worker.fetch(new Request('https://example.org' + API + path, {
        method, headers: { 'X-Workshop-Account-Origin': 'https://github.com', ...(authorization === undefined ? {} : { Authorization: authorization }) },
      }), f.env, makeCtx().ctx);
      expect(response.status).toBe(401); expect(await response.json()).toEqual({ error: 'workshop_account_auth_required' });
    }
  }
  expect(fetch).not.toHaveBeenCalled(); expect(f.bucket.objects.size).toBe(0);
});
it('requires the GitHub account assertion at every author entry before any upstream call', async () => {
  const f = setup();
  for (const expected of [undefined, '', 'https://github.com/', 'https://api.github.com', 'https://forum.dshtui.com']) {
    for (const [path, method] of AUTHOR_ROUTES('0123456789abcdef0123456789abcdef')) {
      const response = await worker.fetch(new Request('https://example.org' + API + path, {
        method, headers: { Authorization: 'Bearer synthetic_github_token', ...(expected === undefined ? {} : { 'X-Workshop-Account-Origin': expected }) },
      }), f.env, makeCtx().ctx);
      expect(response.status).toBe(409); expect(await response.json()).toEqual({ error: 'workshop_account_origin' });
    }
  }
  expect(fetch).not.toHaveBeenCalled(); expect(f.bucket.objects.size).toBe(0);
});
it('announces GitHub accounts with only a well-formed public client id', async () => {
  const f = setup();
  for (const [configured, announced] of [[undefined, null], ['', null], ['Iv23li.Synthetic_id-01', 'Iv23li.Synthetic_id-01'],
    ['bad id', null], ['x'.repeat(65), null], ['x'.repeat(64), 'x'.repeat(64)]] as const) {
    f.env.WORKSHOP_GITHUB_CLIENT_ID = configured;
    const value = await (await f.call(API + '/capabilities')).json() as any;
    expect(value.account).toEqual({ origin: 'https://github.com', clientId: announced }); expect(value).not.toHaveProperty('forumOrigin');
  }
});
it('verifies only against the operator-configured GitHub API origin', async () => {
  const f = setup(); f.env.WORKSHOP_GITHUB_API_URL = 'https://127.0.0.1:8443/';
  expect((await f.call(API + '/submissions')).status).toBe(200);
  expect(vi.mocked(fetch).mock.calls.map(([url]) => url)).toEqual(['https://127.0.0.1:8443/user']);
  for (const configured of ['http://127.0.0.1:8443', 'https://example.org/api', 'https://user:pass@example.org', 'not a url']) {
    f.env.WORKSHOP_GITHUB_API_URL = configured;
    const response = await f.call(API + '/submissions'); expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: 'workshop_account_unavailable' });
  }
  expect(fetch).toHaveBeenCalledTimes(1);
});
it('keeps public queries and the independent admin gate free of author assertion requirements', async () => {
  const f = setup();
  for (const path of [API + '/capabilities', '/market/workshop.json']) {
    expect((await worker.fetch(new Request('https://example.org' + path), f.env, makeCtx().ctx)).status).toBe(200);
  }
  const admin = await worker.fetch(new Request('https://example.org' + API + '/admin/reports', {
    headers: { 'X-Admin-Key': f.env.ADMIN_KEY! },
  }), f.env, makeCtx().ctx);
  expect(admin.status).toBe(200); expect(fetch).not.toHaveBeenCalled();
});
it('binds idempotency, GitHub identity and metadata without retaining the token', async () => {
  const f = setup(), item = await f.create();
  const same = await f.call(API + '/submissions', 'POST', { ...item.meta, requestId: item.requestId }); expect(same.status).toBe(200);
  const changed = await f.call(API + '/submissions', 'POST', { ...item.meta, title: { zh: '变更', en: 'Changed' }, requestId: item.requestId }); expect(changed.status).toBe(409);
  const [origin, init] = vi.mocked(fetch).mock.calls[0]!;
  expect(origin).toBe('https://api.github.com/user'); expect(init?.redirect).toBe('manual');
  expect(init?.headers).toEqual({ Authorization: 'Bearer synthetic_github_token', Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'dshgo-workshop' });
  expect(JSON.stringify(f.state())).not.toContain('synthetic_github_token');
  const owner = { accountOrigin: 'https://github.com', accountId: 42, username: 'synthetic-42' };
  expect(f.state().submissions[0].owner).toEqual(owner); expect((await same.json() as any).submission.owner).toEqual(owner);
  expect(f.state().audit[0]).toEqual(expect.objectContaining({ action: 'create', actor: owner, submissionId: item.sid }));
  githubUser = 43; expect((await f.call(`${API}/submissions/${item.sid}`)).status).toBe(404);
  expect((await f.call(`${API}/submissions/${item.sid}/archive`, 'PUT', item.bytes)).status).toBe(404);
});
it('retains optional display metadata through creation and publication without embedding it in the pack', async () => {
  const f = setup(), fields = { description: 'A small companion', tags: ['pet', '猫'] };
  const item = await f.publish(pet(), fields);
  expect(f.state().submissions[0].metadata).toMatchObject(fields);
  const response = await f.call(`${API}/submissions/${item.sid}`);
  expect((await response.json() as any).submission.metadata).toMatchObject(fields);
  const catalog = await (await f.call('/market/workshop.json')).json() as any;
  expect(catalog.entries[0]).toMatchObject(fields);
  const repeated = await f.call(API + '/submissions', 'POST', { tags: fields.tags, description: fields.description, ...item.meta, requestId: item.requestId });
  expect(repeated.status).toBe(200);
});
it('exposes bytes only after review and serves conditional/Range without leaking pending archives', async () => {
  const f = setup(), item = await f.create(); await f.upload(item);
  const path = assetUrl(item.meta);
  expect(f.bucket.objects.has(blobKey(item.meta.sha256))).toBe(true);
  for (const method of ['GET', 'HEAD']) expect((await f.call(path, method)).status).toBe(404);
  expect((await f.call(`${API}/admin/submissions/${item.sid}/archive`)).status).toBe(401);
  expect((await f.call(`${API}/admin/submissions/${item.sid}/archive`, 'GET', undefined, true)).status).toBe(200);
  expect((await f.review(item.sid)).status).toBe(200);
  const body = await f.call(path), tag = body.headers.get('ETag')!; expect(Buffer.from(await body.arrayBuffer())).toEqual(item.bytes);
  const range = await f.call(path, 'GET', undefined, false, { Range: 'bytes=10-19', 'If-Range': tag });
  expect(range.status).toBe(206); expect(Buffer.from(await range.arrayBuffer())).toEqual(item.bytes.subarray(10, 20));
  expect((await f.call(path, 'GET', undefined, false, { Range: 'bytes=10-', 'If-Range': '"changed"' })).status).toBe(200);
  expect((await f.call(path, 'HEAD', undefined, false, { 'If-None-Match': tag })).status).toBe(304);
  const head = await f.call(path, 'HEAD'); expect(head.status).toBe(200); expect(await head.text()).toBe('');
  const catalog = await f.call('/market/workshop.json'); const entry = (await catalog.json() as any).entries[0]; expect(entry.url).toBe(path); expect(entry).not.toHaveProperty('rightsConfirmed');
  expect(f.dl.objects.size).toBe(0);
});
it('refuses the admin routes when the configured key is shorter than the share API allows', async () => {
  for (const key of [undefined, 'short', 'x'.repeat(31)]) {
    const weak = makeEnv({ ADMIN_KEY: key, BUCKET: new PetBucket() as unknown as R2Bucket });
    const response = await worker.fetch(new Request(`https://example.org${API}/admin/reports`, {
      headers: { Authorization: 'Bearer synthetic_github_token', ...(key ? { 'X-Admin-Key': key } : {}) },
    }), weak.env, makeCtx().ctx);
    expect(response.status).toBe(503);
  }
});
it('records reports, rejects before publication, and allows owner withdrawal while uploads are paused', async () => {
  const f = setup(), item = await f.publish();
  const report = await f.call(API + '/reports', 'POST', { kind: 'pet', id: 'sample', version: '1.0.0', reason: 'Synthetic rights complaint' }); expect(report.status).toBe(201);
  expect((await (await f.call(API + '/admin/reports', 'GET', undefined, true)).json() as any).reports).toHaveLength(1);
  f.env.WORKSHOP_UPLOAD_ENABLED = '0';
  expect(await (await f.call(API + '/submissions', 'POST', {})).json()).toEqual({ error: 'workshop_upload_disabled' });
  expect((await f.call(`${API}/submissions/${item.sid}/withdraw`, 'POST', { reason: 'Synthetic owner withdrawal' })).status).toBe(200);
  expect((await f.call(assetUrl(item.meta))).status).toBe(404);
  const catalog = await (await f.call('/market/workshop.json')).json() as any; expect(catalog.entries).toEqual([]); expect(catalog.withdrawn).toHaveLength(1);
  expect(f.state().releases).toHaveLength(1); expect(f.state().audit.map((e: any) => e.action)).toEqual(['create', 'submit', 'approve', 'report', 'withdraw']);
});
it('blocks same-version byte rewrites and ownership transfer across upgrades and withdrawals', async () => {
  const f = setup(), first = await f.publish();
  await f.publish(first.bytes, { version: '2.0.0' });
  const changedPack = petManifest(); changedPack.animations.idle.frames[0]!.ms = 101;
  const changed = await f.create(pet(changedPack)); await f.upload(changed);
  expect(await (await f.review(changed.sid)).json()).toEqual({ error: 'workshop_version_rewritten' });
  githubUser = 43; const outsider = await f.create(first.bytes, { version: '3.0.0' }); await f.upload(outsider);
  expect(await (await f.review(outsider.sid)).json()).toEqual({ error: 'workshop_owner_conflict' });
  githubUser = 42;
  expect((await f.call(`${API}/submissions/${first.sid}/withdraw`, 'POST', { reason: 'Withdraw old version' })).status).toBe(200);
  const catalog = await (await f.call('/market/workshop.json')).json() as any;
  expect(catalog.entries[0]).toMatchObject({ version: '2.0.0', blockedVersions: ['1.0.0'] });
  const old = await f.create(first.bytes); await f.upload(old); expect(await (await f.review(old.sid)).json()).toEqual({ error: 'workshop_version_withdrawn' });
});
it('uses the same authority and kill switch for companion catalog/GET/HEAD/Range/ETag', async () => {
  const f = setup(), item = await f.publish(companion(), { kind: 'companion' });
  const path = assetUrl(item.meta), catalog = await f.call('/market/companions.json'), tag = catalog.headers.get('ETag')!;
  expect((await catalog.json() as any).entries[0].kind).toBe('companion');
  f.env.WORKSHOP_COMPANION_ENABLED = '0';
  for (const [url, method, headers] of [['/market/companions.json', 'GET', { 'If-None-Match': tag }], [path, 'GET', { Range: 'bytes=1-' }], [path, 'HEAD', {}]] as const) {
    const result = await f.call(url, method, undefined, false, headers); expect(result.status).toBe(503); expect(await result.json()).toEqual({ error: 'workshop_companion_disabled' });
  }
  const main = await (await f.call('/market/workshop.json')).json() as any; expect(main.entries).toEqual([]); expect(main.features.companion).toBe(false);
  expect((await f.call(`${API}/admin/submissions/${item.sid}/archive`, 'GET', undefined, true)).status).toBe(200);
});
it('maps GitHub answers to stable failures without persisting or logging upstream text', async () => {
  const f = setup(), logged = vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.mocked(fetch).mockResolvedValueOnce(new Response('synthetic secret must not escape', { status: 401 }));
  const revoked = await f.call(API + '/submissions'); expect(revoked.status).toBe(401); expect(await revoked.json()).toEqual({ error: 'workshop_account_auth_invalid' });
  for (const answer of [
    new Response('{"message":"API rate limit exceeded"}', { status: 403 }), new Response('synthetic secret must not escape', { status: 500 }),
    new Response(null, { status: 302, headers: { Location: 'https://redirected.invalid/user' } }),
    new Response(JSON.stringify({ id: 42 })), new Response(JSON.stringify({ id: 0, login: 'zero' })),
  ]) {
    vi.mocked(fetch).mockResolvedValueOnce(answer);
    const response = await f.call(API + '/submissions'); expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: 'workshop_account_unavailable' });
  }
  vi.mocked(fetch).mockRejectedValueOnce(new Error('synthetic upstream credential failure'));
  const unavailable = await f.call(API + '/submissions'); expect(unavailable.status).toBe(503); expect(await unavailable.text()).not.toContain('credential');
  expect(logged).not.toHaveBeenCalled(); expect(f.bucket.objects.size).toBe(0);
});
it('charges invalid archive attempts and verifies both declared SHA and actual byte count', async () => {
  const f = setup(), item = await f.create();
  const wrong = Buffer.from(item.bytes); wrong[0] ^= 1;
  expect(await (await f.call(`${API}/submissions/${item.sid}/archive`, 'PUT', wrong)).json()).toEqual({ error: 'workshop_sha_mismatch' });
  expect(await (await f.call(`${API}/submissions/${item.sid}/archive`, 'PUT', wrong.subarray(1))).json()).toEqual({ error: 'workshop_size_mismatch' });
  expect(await (await f.call(`${API}/submissions/${item.sid}/archive`, 'PUT', Buffer.concat([item.bytes, Buffer.from([0])]))).json()).toEqual({ error: 'workshop_size_mismatch' });
  expect(f.bucket.objects.has(blobKey(item.meta.sha256))).toBe(false); expect(f.state().submissions[0].status).toBe('draft');
  expect([...f.kv.values.values()]).toContain('3');
});
it('reports a CAS loser without losing the winning submission', async () => {
  const f = setup(), bytes = pet(), meta = metaFor(bytes);
  const responses = await Promise.all(['first', 'second'].map(request => f.call(API + '/submissions', 'POST', { ...meta, requestId: `concurrent_request_${request}` })));
  expect(responses.map(r => r.status).sort()).toEqual([201, 409]); expect(f.state().submissions).toHaveLength(1); expect(f.state().audit).toHaveLength(1);
});
it('cannot approve a concurrently withdrawn pending record even after its blob is validated', async () => {
  const f = setup(), item = await f.create(); await f.upload(item);
  const put = f.bucket.put.bind(f.bucket);
  let release!: () => void, entered!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; }), started = new Promise<void>(resolve => { entered = resolve; });
  vi.spyOn(f.bucket, 'put').mockImplementation(async (key, bytes, options) => {
    if (key === STATE_KEY && new TextDecoder().decode(bytes as Uint8Array).includes('"status":"approved"')) { entered(); await gate; }
    return put(key, bytes, options);
  });
  const approving = f.review(item.sid); await started;
  expect((await f.call(`${API}/submissions/${item.sid}/withdraw`, 'POST', { reason: 'Cancel while in review' })).status).toBe(200);
  release(); expect(await (await approving).json()).toEqual({ error: 'workshop_state_conflict' });
  expect(f.state().releases).toEqual([]); expect((await f.call(assetUrl(item.meta))).status).toBe(404);
});
it('fails closed for corrupt durable authority and for changed actual blob metadata', async () => {
  const f = setup(), item = await f.publish();
  const object = f.bucket.objects.get(blobKey(item.meta.sha256))!; object.bytes = Buffer.from('different bytes');
  expect(await (await f.call(assetUrl(item.meta))).json()).toEqual({ error: 'workshop_storage_unavailable' });
  const state = f.state(); state.releases = [];
  f.bucket.objects.get(STATE_KEY)!.bytes = Buffer.from(JSON.stringify(state));
  expect(await (await f.call('/market/workshop.json')).json()).toEqual({ error: 'workshop_state_invalid' });
  expect((await f.call(assetUrl(item.meta), 'HEAD')).status).toBe(503);
});
it('keeps rejected submissions private and pages only the requesting owner records', async () => {
  const f = setup(), item = await f.create(); await f.upload(item);
  expect((await f.review(item.sid, 'reject')).status).toBe(200);
  expect((await f.call(assetUrl(item.meta))).status).toBe(404);
  expect((await f.review(item.sid)).status).toBe(409);
  await f.create(); await f.create();
  const first = await (await f.call(API + '/submissions?limit=2')).json() as any;
  expect(first.submissions).toHaveLength(2); expect(first.nextCursor).toBeTruthy();
  const second = await (await f.call(API + '/submissions?limit=2&cursor=' + first.nextCursor)).json() as any;
  expect(second.submissions).toHaveLength(1); expect(second.nextCursor).toBe(null);
  githubUser = 43; expect((await (await f.call(API + '/submissions')).json() as any).submissions).toEqual([]);
  expect((await (await f.call(API + '/admin/submissions?status=rejected', 'GET', undefined, true)).json() as any).submissions).toHaveLength(1);
});
it('recovers an unknown successful CAS outcome by the same requestId without duplicating a submission', async () => {
  const f = setup(), put = f.bucket.put.bind(f.bucket), bytes = pet(), metadata = metaFor(bytes), requestId = 'unknown_outcome_request';
  let once = true;
  vi.spyOn(f.bucket, 'put').mockImplementation(async (key, value, options) => {
    const result = await put(key, value, options);
    if (key === STATE_KEY && once) { once = false; throw new Error('synthetic acknowledgement loss'); }
    return result;
  });
  const unknown = await f.call(API + '/submissions', 'POST', { ...metadata, requestId }); expect(unknown.status).toBe(503);
  const retry = await f.call(API + '/submissions', 'POST', { ...metadata, requestId }); expect(retry.status).toBe(200);
  expect(f.state().submissions).toHaveLength(1); expect(f.state().audit).toHaveLength(1);
});
it('lets moderators terminate abandoned drafts while retaining immutable metadata/audit', async () => {
  const f = setup(), item = await f.create();
  const path = `${API}/admin/submissions/${item.sid}/withdraw`;
  expect((await f.call(path, 'POST', { reason: 'Abandoned draft' })).status).toBe(401);
  const stopped = await f.call(path, 'POST', { reason: 'Abandoned draft' }, true);
  expect(stopped.status).toBe(200); expect((await stopped.json() as any).submission.status).toBe('withdrawn');
  expect(f.state().submissions).toHaveLength(1); expect(f.state().audit.at(-1)).toMatchObject({ action: 'withdraw', actor: 'admin' });
  expect((await f.call(`${API}/submissions/${item.sid}/archive`, 'PUT', item.bytes)).status).toBe(409);
  expect((await f.call(path, 'POST', { reason: 'Repeat withdrawal' }, true)).status).toBe(200);
  expect(f.state().audit).toHaveLength(2);
});
it('auto-approves a checked upload when the switch is on, idempotently, and leaves version conflicts pending', async () => {
  const f = setup(); f.env.WORKSHOP_AUTO_APPROVE = '1';
  const item = await f.create(), out = await f.upload(item);
  expect(out.submission).toMatchObject({ status: 'approved', review: { decision: 'approve', reason: '自动通过' } });
  expect((await (await f.call('/market/workshop.json')).json() as any).entries).toHaveLength(1);
  expect((await f.call(assetUrl(item.meta))).status).toBe(200);
  expect((await f.upload(item)).submission.status).toBe('approved');
  expect(f.state().audit.map((e: any) => e.action)).toEqual(['create', 'submit', 'approve']);
  githubUser = 43; const outsider = await f.create(item.bytes, { version: '2.0.0' });
  expect((await f.upload(outsider)).submission.status).toBe('pending');
  githubUser = 42;
  f.env.WORKSHOP_AUTO_APPROVE = '0';
  const manual = await f.create(item.bytes, { version: '3.0.0' });
  expect((await f.upload(manual)).submission.status).toBe('pending');
});
it('publishes a companion over the old 20 MiB cap and keeps its state readable', async () => {
  const f = setup(), bytes = largeCompanion(4);
  expect(bytes.length).toBeGreaterThan(25 * 1024 * 1024);
  const item = await f.publish(bytes, { kind: 'companion' });
  expect(f.state().releases[0].size).toBe(bytes.length);
  // Over the old 20 MiB cap: listed apart, where apps from before 50 MiB never look.
  for (const path of ['/market/companions.json', '/market/workshop.json']) {
    const listed = await (await f.call(path)).json() as any;
    expect(listed.entries).toEqual([]); expect(listed.largeEntries).toHaveLength(1);
  }
  expect((await f.call(assetUrl(item.meta))).status).toBe(200);
}, 30_000);
it('reads and checks one large archive at a time per isolate; another gets 429 and can retry', async () => {
  const f = setup(), bytes = largeCompanion(3);
  const [a, b] = [await f.create(bytes, { kind: 'companion' }), await f.create(bytes, { kind: 'companion' })];
  const archive = (sid: string) => f.call(`${API}/submissions/${sid}/archive`, 'PUT', bytes);
  const [x, y] = await Promise.all([archive(a.sid), archive(b.sid)]);
  expect([x.status, y.status]).toEqual([200, 429]);
  expect(await y.json()).toEqual({ error: 'workshop_rate_limited' }); expect(y.headers.get('Retry-After')).toBe('60');
  expect((await f.upload(b)).submission.status).toBe('pending');
}, 30_000);
it('gives up on a large body that stops arriving and frees the isolate for the next one', async () => {
  const f = setup(), bytes = largeCompanion(3), item = await f.create(bytes, { kind: 'companion' });
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] });
  try {
    // pull() runs once the first chunk is taken: the Worker is reading, its deadline is set.
    let reading!: () => void; const started = new Promise<void>(resolve => { reading = resolve; });
    const stalled = new ReadableStream<Uint8Array>({
      start(c) { c.enqueue(bytes.subarray(0, 1024)); },
      pull() { reading(); return new Promise<void>(() => {}); },
    });
    const pending = worker.fetch(new Request('https://example.org' + `${API}/submissions/${item.sid}/archive`, {
      method: 'PUT', body: stalled, duplex: 'half',
      headers: { Authorization: 'Bearer synthetic_github_token', 'X-Workshop-Account-Origin': 'https://github.com', 'Content-Type': 'application/zip' },
    } as RequestInit), f.env, makeCtx().ctx);
    await started;
    await vi.advanceTimersByTimeAsync(9 * 60_000 + 1);
    const response = await pending;
    expect(response.status).toBe(408); expect(await response.json()).toEqual({ error: 'workshop_upload_timeout' });
  } finally { vi.useRealTimers(); }
  expect((await f.upload(item)).submission.status).toBe('pending');
}, 30_000);
