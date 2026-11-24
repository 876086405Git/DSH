import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import worker from '../src/index';
import { STATE_KEY } from '../src/workshop-state';
import { makeCtx, makeEnv } from './fakes';
import { PetBucket } from './pet-market-fakes';
import { metaFor, pet, png } from './workshop-fixtures';

const API = '/api/workshop/v1', ADMIN = API + '/admin';
const USERS: Record<string, { id: number; login: string }> = {
  token_alice: { id: 42, login: 'Alice fixture' }, token_bob: { id: 7, login: 'Bob fixture' },
};
beforeEach(() => vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
  if (!input) return new Response(JSON.stringify(USERS.token_alice!)); // vitest cleanup may probe fetch without an input
  const request = input instanceof Request ? input : new Request(typeof input === 'string' ? input : String(input), init);
  const token = (request.headers.get('Authorization') || '').replace('Bearer ', '');
  return new Response(JSON.stringify(USERS[token] ?? USERS.token_alice!));
}));
afterEach(() => vi.restoreAllMocks());
function setup() {
  const bucket = new PetBucket(), bindings = makeEnv({ BUCKET: bucket as unknown as R2Bucket }); let serial = 0;
  const call = (path: string, method = 'GET', body?: object | Uint8Array, authenticated = true, token = 'token_alice') =>
    worker.fetch(new Request('https://example.org' + path, {
      method, headers: { Authorization: 'Bearer ' + token, 'X-Workshop-Account-Origin': 'https://github.com',
        ...(authenticated ? { 'X-Admin-Key': bindings.env.ADMIN_KEY! } : {}),
        ...(body ? { 'Content-Type': body instanceof Uint8Array ? 'application/zip' : 'application/json' } : {}) },
      ...(body ? { body: body instanceof Uint8Array ? body : JSON.stringify(body) } : {}),
    }), bindings.env, makeCtx().ctx);
  const create = async (bytes = pet(), overrides: Record<string, unknown> = {}, token = 'token_alice') => {
    const meta = metaFor(bytes, overrides as never);
    const made = await call(API + '/submissions', 'POST', { ...meta, requestId: 'rework_fixture_request_' + (++serial) }, true, token);
    expect(made.status).toBe(201);
    const { submission } = await made.json() as any;
    const upload = await call(API + '/submissions/' + submission.submissionId + '/archive', 'PUT', bytes, true, token);
    expect(upload.status).toBe(200);
    return { sid: submission.submissionId as string, meta, bytes };
  };
  const review = (sid: string, decision = 'approve', reason = 'Synthetic moderation reason') =>
    call(ADMIN + '/submissions/' + sid + '/review', 'POST', { decision, reason });
  const rework = (sid: string, body: Record<string, unknown>) => call(ADMIN + '/submissions/' + sid + '/rework', 'POST', body);
  const publish = async (bytes = pet(), overrides: Record<string, unknown> = {}) => {
    const item = await create(bytes, overrides); expect((await review(item.sid)).status).toBe(200); return item;
  };
  const state = () => JSON.parse(new TextDecoder().decode(bucket.objects.get(STATE_KEY)!.bytes));
  const catalog = async () => (await worker.fetch(new Request('https://example.org/market/workshop.json'), bindings.env, makeCtx().ctx)).json() as any;
  return { ...bindings, bucket, call, create, review, rework, publish, state, catalog };
}
it('authenticates the rework path before reading state or archives', async () => {
  const f = setup();
  const response = await f.call(ADMIN + '/submissions/' + '1'.repeat(32) + '/rework', 'POST', { reason: 'x' }, false);
  expect(response.status).toBe(401); expect(await response.json()).toEqual({ error: 'workshop_admin_auth_required' });
  expect(f.bucket.gets).toEqual([]); expect(f.bucket.writes).toEqual([]);
});
it('republishes a stuck pending submission under a new version and keeps the author', async () => {
  const f = setup();
  const item = await f.create(pet(), { previewSource: 'pet-idle' });
  const before = f.state().submissions.find((s: any) => s.submissionId === item.sid);
  expect(before.status).toBe('pending'); expect(before.preview).toBeTruthy();
  const response = await f.rework(item.sid, { version: '1.0.1', reason: '管理员修正：1.0.0 已撤回，改为 1.0.1' });
  expect(response.status).toBe(200);
  const { submission } = await response.json() as any;
  expect(submission.status).toBe('approved');
  expect(submission.metadata).toMatchObject({ id: 'sample', version: '1.0.1', sha256: item.meta.sha256, size: item.meta.size });
  expect(submission.owner).toMatchObject({ accountId: 42, username: 'Alice fixture' });
  expect(submission.preview.path).toContain('/1.0.1/' + item.meta.sha256 + '/preview/');
  const state = f.state();
  expect(state.submissions.find((s: any) => s.submissionId === item.sid).status).toBe('withdrawn');
  expect(state.current).toEqual([submission.submissionId]);
  expect(state.releases).toHaveLength(1);
  expect(state.releases[0]).toMatchObject({ kind: 'pet', id: 'sample', version: '1.0.1', owner: { accountId: 42 } });
  expect(state.audit.filter((e: any) => e.submissionId === submission.submissionId).map((e: any) => e.action)).toEqual(['create', 'submit', 'approve']);
  expect(state.withdrawn).toEqual([]);
  const catalog = await f.catalog();
  expect(catalog.entries).toHaveLength(1);
  expect(catalog.entries[0]).toMatchObject({ id: 'sample', version: '1.0.1', preview: { width: 1, height: 1 } });
});
it('keeps the author bound and refuses moving a row to another work id', async () => {
  const f = setup();
  await f.publish();
  const other = await f.create(pet(), {}, 'token_bob');
  const blocked = await f.rework(other.sid, { version: '2.0.0', reason: 'same id under another author' });
  expect(blocked.status).toBe(409); expect(await blocked.json()).toEqual({ error: 'workshop_owner_conflict' });
  // The archive binds its own work id; an id change needs the author to repack.
  const moved = await f.rework(other.sid, { id: 'sample-bob', version: '1.0.0', reason: '新作品标识' });
  expect(moved.status).toBe(400); expect(await moved.json()).toEqual({ error: 'workshop_bad_request' });
  expect(f.state().submissions.find((s: any) => s.submissionId === other.sid).status).toBe('pending');
});
it('refuses to restore a withdrawn version but accepts the next one', async () => {
  const f = setup();
  const item = await f.publish();
  const replaced = await f.rework(item.sid, { reason: 'same version, same archive' });
  expect(replaced.status).toBe(200);
  const withdrawn = await f.call(ADMIN + '/releases/withdraw', 'POST', { kind: 'pet', id: 'sample', version: '1.0.0', reason: 'Synthetic withdrawal' });
  expect(withdrawn.status).toBe(200);
  const blocked = await f.rework(item.sid, { reason: 'restore a withdrawn version' });
  expect(blocked.status).toBe(409); expect(await blocked.json()).toEqual({ error: 'workshop_version_withdrawn' });
  expect((await f.rework(item.sid, { version: '1.0.1', reason: 'next version' })).status).toBe(200);
});
it('registers an explicitly supplied PNG preview and rejects malformed ones', async () => {
  const f = setup();
  const item = await f.create();
  expect(f.state().submissions.find((s: any) => s.submissionId === item.sid).preview).toBeUndefined();
  const image = png(2, 2);
  const response = await f.rework(item.sid, { version: '1.0.1', preview: image.toString('base64'), reason: '补上预览图' });
  expect(response.status).toBe(200);
  const { submission } = await response.json() as any;
  expect(submission.preview).toMatchObject({ width: 2, height: 2, size: image.length });
  const served = await f.call(ADMIN + '/submissions/' + submission.submissionId + '/public-preview');
  expect(served.status).toBe(200); expect(Buffer.from(await served.arrayBuffer())).toEqual(image);
  const bad = await f.rework(item.sid, { version: '1.0.2', preview: 'not-base64!', reason: '坏预览' });
  expect(bad.status).toBe(400); expect(await bad.json()).toEqual({ error: 'workshop_bad_preview' });
});
it('only repairs uploaded records and validates the replacement metadata', async () => {
  const f = setup();
  const meta = metaFor(pet());
  const made = await f.call(API + '/submissions', 'POST', { ...meta, requestId: 'rework_draft_fixture_1' });
  expect(made.status).toBe(201);
  const draft = (await made.json() as any).submission.submissionId as string;
  expect((await f.rework(draft, { reason: 'nothing uploaded yet' })).status).toBe(409);
  const item = await f.create();
  expect((await f.rework(item.sid, { reason: '' })).status).toBe(400);
  expect((await f.rework(item.sid, { version: 'not a version', reason: 'bad version' })).status).toBe(400);
  expect((await f.rework(item.sid, { id: 'Bad Id', reason: 'bad id' })).status).toBe(400);
  expect((await f.rework(item.sid, { version: '1.0.1', reason: 'ok' })).status).toBe(200);
});
