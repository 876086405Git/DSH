// Workshop routes: public catalog/bytes and explicitly authenticated moderation.
// All lower-level exceptions are translated here; never log an account token, its
// upstream response, or an exception that might contain request headers.
import { json, readExactly } from './api';
import type { Env } from './env';
import { COMMON, matchesEtag, parseHttpDate, serveObject, type Ctx } from './files';
import { record } from './pet-catalog';
import { readBounded, storedAsset } from './pet-market-io';
import { account, admin, enabled, features, jsonBody, limitBurst, quota, user } from './workshop-auth';
import { WORKSHOP_ADMIN_HTML, WORKSHOP_ADMIN_SCRIPT } from './workshop-admin-page';
import { assetUrl, blobKey, encoder, EXPANDED_CAP, id, identity, KINDS, kind, LICENSES, MEMBER_CAP, metadata, PREVIEW_CONTRACT, previewKey, previewUrl, releaseId,
  requireWorkshop as need, sha256, validVersion, text, UPLOAD_CAP, WorkshopError, type PublicPreview, type SubmissionMeta } from './workshop-common';
import { validatePack } from './workshop-pack';
import { checkPreviewRequest, derivePreview, validatePublicPng } from './workshop-preview';
import { emptyInspection, inspectPack, inspectionPage, readPreview } from './workshop-inspection';
import { approve, audit, catalog, commitState, editState, loadState, resolveReport, sameOwner, STATUSES, withdrawRelease, withdrawSubmission,
  type Owner, type Report, type Snapshot, type State, type Submission } from './workshop-state';

// Historical official Core measurement in tooling/companion/fixtures/
// live2d-core-sources-v1.json (2026-11-07). This is a file-format ceiling,
// not validation by Core, a match to installed runtime bytes, or a render test.
export const MAX_MOC_VERSION = 6;
const API = '/api/workshop/v1';
const SID = /^[a-f0-9]{32}$/;
export const isWorkshopPath = (path: string) => path === '/api/workshop' || path.startsWith('/api/workshop/') ||
  path === '/workshop/admin' || path === '/market/workshop.json' || path === '/market/companions.json' || path === '/market/workshop' || path.startsWith('/market/workshop/');
function method(request: Request, ...allowed: string[]): void {
  if (!allowed.includes(request.method)) throw new WorkshopError('method_not_allowed', 405, { Allow: allowed.join(', ') });
}
const reason = (body: Record<string, unknown>): string => { need(text(body.reason, 2000), 'bad_reason'); return body.reason; };
function find(state: State, sid: string, owner?: Owner): Submission {
  const s = state.submissions.find(s => s.submissionId === sid);
  need(s && (!owner || sameOwner(s.owner, owner)), 'not_found', 404); return s;
}
function page<T>(items: T[], url: URL, key: (item: T) => string) {
  const limitText = url.searchParams.get('limit') ?? '20', cursor = url.searchParams.get('cursor');
  need(/^[1-9][0-9]{0,2}$/.test(limitText) && Number(limitText) <= 100 && (cursor === null || cursor.length === 32 && SID.test(cursor)), 'bad_query');
  const sorted = items.filter(item => cursor === null || key(item) > cursor).sort((a, b) => key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0);
  const limit = Number(limitText), selected = sorted.slice(0, limit);
  return { selected, nextCursor: sorted.length > limit ? key(selected[selected.length - 1]!) : null };
}
function personalPage(items: Submission[], url: URL, status: string | null) {
  const limitText = url.searchParams.get('limit') ?? '20', cursor = url.searchParams.get('cursor');
  need(/^[1-9][0-9]{0,2}$/.test(limitText) && Number(limitText) <= 100 && (cursor === null || cursor.length === 32 && SID.test(cursor)), 'bad_query');
  // The caller supplies all of this owner's records. Resolve before filtering:
  // a retained cursor row may have left the selected status since the last page.
  const anchor = cursor === null ? undefined : items.find(s => s.submissionId === cursor);
  need(cursor === null || anchor !== undefined, 'bad_query');
  // State timestamps have one canonical UTC millisecond format. Creation keys
  // never change and submissions are not pruned; updatedAt is not an order key.
  const sorted = items.filter(s => (!status || s.status === status) && (!anchor || s.createdAt < anchor.createdAt ||
    s.createdAt === anchor.createdAt && s.submissionId > anchor.submissionId)).sort((a, b) =>
    a.createdAt > b.createdAt ? -1 : a.createdAt < b.createdAt ? 1 :
      a.submissionId < b.submissionId ? -1 : a.submissionId > b.submissionId ? 1 : 0);
  const limit = Number(limitText), selected = sorted.slice(0, limit);
  return { selected, nextCursor: sorted.length > limit ? selected[selected.length - 1]!.submissionId : null };
}
const LEGACY_PERSONAL_KINDS = new Set(['pet', 'companion']);
function personalSupportedKinds(request?: Request): Set<string> {
  const raw = request?.headers.get('X-Workshop-Supported-Kinds');
  if (!raw) return LEGACY_PERSONAL_KINDS;
  const allowed = new Set<string>();
  for (const part of raw.split(',')) {
    const trimmed = part.trim();
    if (kind(trimmed)) allowed.add(trimmed);
  }
  return allowed.size > 0 ? allowed : LEGACY_PERSONAL_KINDS;
}
function listSubmissions(snapshot: Snapshot, url: URL, owner?: Owner, request?: Request): Response {
  const status = url.searchParams.get('status'); need(status === null || STATUSES.includes(status as typeof STATUSES[number]), 'bad_query');
  const selectedKind = owner ? null : url.searchParams.get('kind'); need(selectedKind === null || kind(selectedKind), 'bad_query');
  const allowedPersonalKinds = owner ? personalSupportedKinds(request) : null;
  const result = owner
    ? personalPage(
        snapshot.state.submissions.filter(
          s => sameOwner(s.owner, owner) && allowedPersonalKinds!.has(s.metadata.kind),
        ),
        url,
        status,
      )
    : page(snapshot.state.submissions.filter(s => (!status || s.status === status) &&
      (!selectedKind || s.metadata.kind === selectedKind)), url, s => s.submissionId);
  return json(200, { submissions: result.selected, nextCursor: result.nextCursor });
}
function reportView(report: Report) { return { ...report, status: report.resolution ? 'resolved' as const : 'open' as const }; }
function reportDetail(state: State, report: Report) {
  const key = releaseId(report);
  return { report: reportView(report), target: {
    release: state.releases.find(release => releaseId(release) === key)!,
    current: state.current.some(sid => releaseId(find(state, sid).metadata) === key),
    withdrawal: state.withdrawn.find(withdrawal => releaseId(withdrawal) === key) ?? null,
  } };
}
async function submissionDetail(env: Env, sid: string) {
  const state = (await loadState(env)).state;
  // Return just this row before image/ZIP work, rather than retaining the
  // complete authority envelope during bounded decompression.
  return { submission: find(state, sid), current: state.current.includes(sid) };
}
let adminScriptHash: Promise<string> | undefined;
async function adminPage(request: Request): Promise<Response> {
  method(request, 'GET', 'HEAD');
  adminScriptHash ??= crypto.subtle.digest('SHA-256', encoder.encode(WORKSHOP_ADMIN_SCRIPT))
    .then(bytes => btoa(String.fromCharCode(...new Uint8Array(bytes))));
  return new Response(request.method === 'HEAD' ? null : WORKSHOP_ADMIN_HTML, { headers: {
    'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer', 'X-Robots-Tag': 'noindex',
    'Content-Security-Policy': `default-src 'none'; script-src 'sha256-${await adminScriptHash}'; style-src 'unsafe-inline'; img-src blob: 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'`,
  } });
}
function privateAdmin(response: Response): Response {
  const headers = new Headers(response.headers); headers.set('Cache-Control', 'private, no-store');
  headers.set('X-Content-Type-Options', 'nosniff'); headers.set('Referrer-Policy', 'no-referrer');
  headers.set('Cross-Origin-Resource-Policy', 'same-origin');
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}
async function blobBytes(env: Env, meta: SubmissionMeta): Promise<Uint8Array> {
  const object = await env.BUCKET.get(blobKey(meta.sha256));
  if (!storedAsset(object, { ...meta, url: assetUrl(meta) }) || !object?.body) {
    void object?.body?.cancel().catch(() => {}); throw new WorkshopError('storage_unavailable', 503);
  }
  const bytes = await readBounded(object.body, meta.size);
  need(bytes.length === meta.size && await sha256(bytes) === meta.sha256, 'storage_unavailable', 503); return bytes;
}
async function putBlob(env: Env, meta: SubmissionMeta, bytes: Uint8Array): Promise<void> {
  const result = await env.BUCKET.put(blobKey(meta.sha256), bytes, {
    onlyIf: new Headers({ 'If-None-Match': '*' }), sha256: meta.sha256,
    httpMetadata: { contentType: 'application/zip', cacheControl: 'private, no-store' },
  });
  const stored = result ?? await env.BUCKET.head(blobKey(meta.sha256));
  need(storedAsset(stored, { ...meta, url: assetUrl(meta) }), 'storage_unavailable', 503);
}
async function putPreview(env: Env, preview: PublicPreview, bytes: Uint8Array): Promise<void> {
  const result = await env.BUCKET.put(previewKey(preview.sha256), bytes, {
    onlyIf: new Headers({ 'If-None-Match': '*' }), sha256: preview.sha256,
    httpMetadata: { contentType: 'image/png', cacheControl: 'private, no-store' },
  });
  const stored = result ?? await env.BUCKET.head(previewKey(preview.sha256));
  need(storedAsset(stored, { ...preview, url: preview.path }), 'storage_unavailable', 503);
}
async function previewBytes(env: Env, preview: PublicPreview): Promise<Uint8Array> {
  const object = await env.BUCKET.get(previewKey(preview.sha256));
  if (!storedAsset(object, { ...preview, url: preview.path }) || !object?.body) {
    void object?.body?.cancel().catch(() => {}); throw new WorkshopError('storage_unavailable', 503);
  }
  const bytes = await readBounded(object.body, preview.size);
  need(bytes.length === preview.size && await sha256(bytes) === preview.sha256, 'storage_unavailable', 503); return bytes;
}
async function servePreview(request: Request, env: Env, preview: PublicPreview): Promise<Response> {
  let bytes: Uint8Array | null = null;
  if (request.method === 'HEAD') {
    need(storedAsset(await env.BUCKET.head(previewKey(preview.sha256)), { ...preview, url: preview.path }), 'storage_unavailable', 503);
  } else bytes = await previewBytes(env, preview);
  // Images have no Range/304 protocol. Authorization precedes storage even
  // when clients send conditional headers; the body is always this exact PNG.
  return new Response(bytes, { headers: { ...COMMON,
    'Content-Type': 'image/png', 'Content-Length': String(preview.size), 'Cache-Control': 'private, no-store',
    'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'; sandbox",
  } });
}
async function serveBlob(request: Request, env: Env, ctx: Ctx, meta: SubmissionMeta): Promise<Response> {
  const asset = { ...meta, url: assetUrl(meta) };
  const checked = <T extends R2Object | null>(object: T): T => {
    if (!storedAsset(object, asset)) {
      if (object && 'body' in object) void (object as R2ObjectBody).body?.cancel().catch(() => {});
      throw new WorkshopError('storage_unavailable', 503);
    }
    return object;
  };
  const head = checked(await env.BUCKET.head(blobKey(meta.sha256)))!;
  // serveObject supplies Range/conditional streaming. Enforce If-Range here
  // and check the native SHA on its actual GET, not only a preceding HEAD.
  let input = request;
  const ifRange = request.headers.get('If-Range');
  if (request.headers.has('Range') && ifRange !== null) {
    const date = parseHttpDate(ifRange), matches = ifRange.trim() === head.httpEtag || date !== null && Math.floor(head.uploaded.getTime() / 1000) * 1000 === date;
    if (!matches) { const headers = new Headers(request.headers); headers.delete('Range'); input = new Request(request, { headers }); }
  }
  const bucket = {
    head: async (key: string) => checked(await env.BUCKET.head(key)),
    get: async (key: string, options?: R2GetOptions) => checked(await env.BUCKET.get(key, options)),
  } as unknown as R2Bucket;
  const response = await serveObject(input, { ...env, BUCKET: bucket }, ctx, {
    key: blobKey(meta.sha256), name: `${meta.id}-${meta.version}.zip`, cacheControl: 'private, no-store',
  });
  response.headers.set('Content-Type', 'application/zip'); return response;
}
async function publicRoute(request: Request, env: Env, ctx: Ctx, url: URL): Promise<Response> {
  const picture = /^\/market\/workshop\/(pet|companion|theme)\/[^/]+\/[^/]+\/[a-f0-9]{64}\/preview\/[a-f0-9]{64}\.png$/.test(url.pathname);
  method(request, 'GET', 'HEAD'); await limitBurst(request, env, false, picture ? 'workshop-preview' : 'workshop');
  const flags = features(env), companions = url.pathname === '/market/companions.json';
  if (companions || url.pathname.startsWith('/market/workshop/companion/')) need(flags.companion, 'companion_disabled', 503);
  const snapshot = await loadState(env);
  if (url.pathname === '/market/workshop.json' || companions) {
    const body = JSON.stringify(catalog(snapshot.state, flags, companions)), tag = `"${await sha256(body)}"`;
    const headers = { ...COMMON, 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-cache, must-revalidate', ETag: tag };
    if (matchesEtag(request.headers.get('If-None-Match'), tag)) return new Response(null, { status: 304, headers });
    return new Response(request.method === 'HEAD' ? null : body, { headers: { ...headers, 'Content-Length': String(encoder.encode(body).length) } });
  }
  if (picture) {
    const state = snapshot.state, byId = new Map(state.submissions.map(s => [s.submissionId, s]));
    const submission = state.current.map(sid => byId.get(sid)).find(s => s?.preview?.path === url.pathname);
    need(submission?.status === 'approved' && submission.preview, 'not_found', 404);
    const key = releaseId(submission.metadata), release = state.releases.find(r => releaseId(r) === key);
    need(release && release.sha256 === submission.metadata.sha256 && release.size === submission.metadata.size &&
      !state.withdrawn.some(w => releaseId(w) === key), 'not_found', 404);
    return servePreview(request, env, submission.preview);
  }
  const match = /^\/market\/workshop\/(pet|companion|theme)\/([^/]+)\/([^/]+)\/([a-f0-9]{64})\.zip$/.exec(url.pathname);
  need(match, 'not_found', 404);
  const s = snapshot.state.current.map(sid => find(snapshot.state, sid)).find(s => assetUrl(s.metadata) === url.pathname);
  need(s, 'not_found', 404);
  return serveBlob(request, env, ctx, s.metadata);
}
async function userRoute(request: Request, env: Env, ctx: Ctx, url: URL): Promise<Response> {
  const path = url.pathname.slice(API.length);
  if (path === '/submissions' && request.method === 'POST') {
    enabled(env); const owner = await user(request, env), body = await jsonBody(request), meta = metadata(body); enabled(env, meta.kind);
    need(text(body.requestId, 128) && /^[A-Za-z0-9_-]{16,128}$/.test(body.requestId), 'bad_request_id');
    const sid = (await sha256(`${owner.accountOrigin}\n${owner.accountId}\n${body.requestId}`)).slice(0, 32), previous = await loadState(env);
    const existing = previous.state.submissions.find(s => s.submissionId === sid);
    if (existing) {
      need(sameOwner(existing.owner, owner) && JSON.stringify(existing.metadata) === JSON.stringify(meta), 'request_id_reused', 409);
      return json(200, { submission: existing });
    }
    await quota(request, env, owner, 'create', 5);
    const state = editState(previous), now = new Date().toISOString();
    const submission: Submission = { submissionId: sid, owner, metadata: meta, status: 'draft', createdAt: now, updatedAt: now };
    state.submissions.push(submission); audit(state, now, { action: 'create', actor: owner, submissionId: sid });
    await commitState(env, previous, state, now); return json(201, { submission });
  }
  if (path === '/submissions') {
    method(request, 'GET'); const owner = await user(request, env); return listSubmissions(await loadState(env), url, owner, request);
  }
  if (path === '/reports') {
    method(request, 'POST'); const owner = await user(request, env), body = await jsonBody(request), explanation = reason(body);
    need(kind(body.kind) && id(body.id) && validVersion(body.version), 'bad_request');
    await quota(request, env, owner, 'report', 20);
    const previous = await loadState(env), state = editState(previous), now = new Date().toISOString();
    const target = { kind: body.kind, id: body.id, version: body.version };
    need(state.releases.some(r => releaseId(r) === releaseId(target)), 'not_found', 404);
    const reportId = crypto.randomUUID().replaceAll('-', '');
    state.reports.push({ reportId, ...target, reason: explanation, reporter: owner, createdAt: now });
    audit(state, now, { action: 'report', actor: owner, reportId, releaseId: releaseId(target), reason: explanation });
    await commitState(env, previous, state, now); return json(201, { reportId });
  }
  const match = /^\/submissions\/([a-f0-9]{32})(?:\/(archive|withdraw))?$/.exec(path);
  need(match, 'not_found', 404); const sid = match[1]!, action = match[2];
  method(request, action === 'archive' ? 'PUT' : action === 'withdraw' ? 'POST' : 'GET');
  if (action === 'archive') enabled(env);
  const owner = await user(request, env);
  if (action === 'archive') {
    // Keep only this record alive while decoding the ZIP; a full authority
    // envelope and a 16-bit RGBA inflate must not occupy the heap together.
    const existing = find((await loadState(env)).state, sid, owner);
    enabled(env, existing.metadata.kind); need(existing.status === 'draft' || uploaded(existing), 'submission_state', 409);
    need(request.headers.get('Content-Type')?.split(';')[0]?.trim().toLowerCase() === 'application/zip', 'content_type', 415);
    const length = request.headers.get('Content-Length'); need(length === null || /^\d+$/.test(length) && Number(length) <= UPLOAD_CAP, 'body_too_large', 413);
    // Before the quota: a busy isolate is not the author's attempt.
    const release = largeArchiveLease(existing.metadata.size);
    let validation: ReturnType<typeof validatePack>, descriptor: PublicPreview | undefined;
    try {
      await quota(request, env, owner, 'archive', 20);
      // Straight into one buffer of the declared size: at the 50 MiB cap,
      // chunks plus a copy would take most of the Worker's memory.
      let bytes = await readExactly(request, existing.metadata.size, LARGE_READ_MS);
      need(bytes !== 'timeout', 'upload_timeout', 408);
      need(bytes && bytes.length === existing.metadata.size, 'size_mismatch', 422); need(await sha256(bytes) === existing.metadata.sha256, 'sha_mismatch', 422);
      if (uploaded(existing)) return json(200, { submission: existing });
      // The opt-in dimensions/byte gate runs before any image inflate. Full
      // archive validation still precedes deriving and registering the image.
      checkPreviewRequest(bytes, existing.metadata);
      validation = validatePack(bytes, existing.metadata, MAX_MOC_VERSION);
      let preview = await derivePreview(bytes, existing.metadata);
      await putBlob(env, existing.metadata, bytes); bytes = null;
      descriptor = preview?.descriptor;
      if (preview) await putPreview(env, preview.descriptor, preview.bytes);
      preview = undefined;
    } finally { release(); }
    // Re-read after validation and the private blob write. A concurrent owner
    // withdrawal/review cannot be overwritten by a stale draft snapshot.
    const previous = await loadState(env), state = editState(previous), submission = find(state, sid, owner), now = new Date().toISOString();
    if (uploaded(submission)) return json(200, { submission });
    need(submission.status === 'draft', 'submission_state', 409);
    submission.status = 'pending'; submission.submittedAt = now; submission.updatedAt = now; submission.validation = validation;
    if (descriptor) submission.preview = descriptor;
    audit(state, now, { action: 'submit', actor: owner, submissionId: sid });
    if (env.WORKSHOP_AUTO_APPROVE === '1') autoApprove(state, submission, now);
    await commitState(env, previous, state, now);
    return json(200, { submission });
  }
  const previous = await loadState(env), existing = find(previous.state, sid, owner);
  if (!action) return json(200, { submission: existing });
  const body = await jsonBody(request), explanation = reason(body);
  if (existing.status === 'withdrawn') return json(200, { submission: existing });
  await quota(request, env, owner, 'withdraw', 20);
  const state = editState(previous), submission = find(state, sid, owner), now = new Date().toISOString();
  withdrawSubmission(state, submission, now, explanation, owner);
  await commitState(env, previous, state, now); return json(200, { submission });
}
/** A fresh submission id for an admin-repair row, derived like an author
 *  submission: sha256(origin, accountId, requestId) truncated to 32 hex. */
async function newSubmissionId(state: State, owner: Owner): Promise<string> {
  for (let attempt = 0; attempt < 4; attempt++) {
    const requestId = crypto.randomUUID().replaceAll('-', '');
    const submissionId = (await sha256(`${owner.accountOrigin}\n${owner.accountId}\n${requestId}`)).slice(0, 32);
    if (!state.submissions.some(submission => submission.submissionId === submissionId)) return submissionId;
  }
  throw new WorkshopError('state_conflict', 409);
}
async function adminRoute(request: Request, env: Env, ctx: Ctx, url: URL): Promise<Response> {
  await admin(request, env);
  const path = url.pathname.slice(`${API}/admin`.length);
  if (path === '/submissions') { method(request, 'GET'); return listSubmissions(await loadState(env), url); }
  if (path === '/reports') {
    method(request, 'GET');
    const status = url.searchParams.get('status'), selectedKind = url.searchParams.get('kind');
    need(status === null || status === 'open' || status === 'resolved', 'bad_query'); need(selectedKind === null || kind(selectedKind), 'bad_query');
    const reports = (await loadState(env)).state.reports.filter(report => (!selectedKind || report.kind === selectedKind) &&
      (!status || (report.resolution ? 'resolved' : 'open') === status));
    const result = page(reports, url, report => report.reportId);
    return json(200, { reports: result.selected.map(reportView), nextCursor: result.nextCursor });
  }
  if (path === '/audit') {
    method(request, 'GET'); const result = page((await loadState(env)).state.audit, url, event => event.eventId);
    return json(200, { events: result.selected, nextCursor: result.nextCursor });
  }
  const reportMatch = /^\/reports\/([a-f0-9]{32})(?:\/(resolve))?$/.exec(path);
  if (reportMatch) {
    method(request, reportMatch[2] ? 'POST' : 'GET');
    const body = reportMatch[2] ? await jsonBody(request) : undefined;
    const explanation = body ? reason(body) : undefined;
    if (body) need(body.decision === 'handled' || body.decision === 'dismissed', 'bad_decision');
    const previous = await loadState(env), state = editState(previous), report = state.reports.find(report => report.reportId === reportMatch[1]);
    need(report, 'not_found', 404);
    if (!body) return json(200, reportDetail(state, report));
    if (report.resolution) {
      need(report.resolution.decision === body.decision, 'report_state', 409); return json(200, reportDetail(state, report));
    }
    const now = new Date().toISOString();
    resolveReport(state, report, now, body.decision as 'handled' | 'dismissed', explanation!);
    await commitState(env, previous, state, now); return json(200, reportDetail(state, report));
  }
  if (path === '/releases/withdraw') {
    method(request, 'POST'); const body = await jsonBody(request), explanation = reason(body);
    need(kind(body.kind) && id(body.id) && validVersion(body.version), 'bad_request');
    const previous = await loadState(env), state = editState(previous), target = { kind: body.kind, id: body.id, version: body.version };
    const release = state.releases.find(r => releaseId(r) === releaseId(target)); need(release, 'not_found', 404);
    const existing = state.withdrawn.find(w => releaseId(w) === releaseId(release)); if (existing) return json(200, { withdrawn: existing });
    const now = new Date().toISOString(), withdrawn = withdrawRelease(state, release, now, explanation);
    audit(state, now, { action: 'withdraw', actor: 'admin', releaseId: releaseId(release), reason: explanation });
    await commitState(env, previous, state, now); return json(200, { withdrawn });
  }
  const match = /^\/submissions\/([a-f0-9]{32})(?:\/(archive|review|withdraw|preview|public-preview|rework))?$/.exec(path); need(match, 'not_found', 404);
  const sid = match[1]!;
  if (!match[2]) {
    method(request, 'GET'); await limitBurst(request, env, false); const paging = inspectionPage(url), detail = await submissionDetail(env, sid);
    let inspection = emptyInspection();
    if (detail.submission.submittedAt) {
      // A whole archive in memory, like an upload: the same one-large-at-a-time lease.
      const release = largeArchiveLease(detail.submission.metadata.size);
      try { inspection = inspectPack(await blobBytes(env, detail.submission.metadata), detail.submission.metadata, sid, MAX_MOC_VERSION, paging); } finally { release(); }
    }
    return json(200, { ...detail, inspection });
  }
  if (match[2] === 'preview') {
    method(request, 'GET', 'HEAD'); await limitBurst(request, env, false);
    const submission = find((await loadState(env)).state, sid); need(submission.submittedAt, 'not_found', 404);
    const release = largeArchiveLease(submission.metadata.size);
    let preview: ReturnType<typeof readPreview>;
    try { preview = readPreview(await blobBytes(env, submission.metadata), url.searchParams.get('file')); } finally { release(); }
    return new Response(request.method === 'HEAD' ? null : preview.bytes, { headers: {
      'Content-Type': preview.info.mediaType, 'Content-Length': String(preview.bytes.length),
      'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'; sandbox",
    } });
  }
  if (match[2] === 'public-preview') {
    method(request, 'GET', 'HEAD'); await limitBurst(request, env, false);
    need(url.search === '', 'bad_query');
    const submission = find((await loadState(env)).state, sid); need(submission.submittedAt && submission.preview, 'not_found', 404);
    return servePreview(request, env, submission.preview);
  }
  if (match[2] === 'archive') {
    method(request, 'GET', 'HEAD'); const submission = find((await loadState(env)).state, sid);
    need(submission.submittedAt, 'not_found', 404); return serveBlob(request, env, ctx, submission.metadata);
  }
  if (match[2] === 'rework') {
    // Admin repair: rebuild one submission from the author's existing archive
    // with a corrected id/version and/or a supplied preview, then publish it.
    // Ownership stays with the author; release bytes stay the same ZIP.
    method(request, 'POST');
    const body = await jsonBody(request), explanation = reason(body);
    const previous = await loadState(env), source = find(previous.state, sid);
    need(source.submittedAt, 'submission_state', 409);
    enabled(env, source.metadata.kind);
    // An uploaded preview is registered against a declared source, exactly
    // like an author submission; the kind decides which source that is.
    let uploaded: Uint8Array | undefined;
    if (body.preview !== undefined) {
      need(typeof body.preview === 'string' && body.preview.length > 0 && body.preview.length <= 2_800_000, 'bad_preview');
      try { uploaded = Uint8Array.from(atob(body.preview), value => value.charCodeAt(0)); } catch { throw new WorkshopError('bad_preview'); }
    }
    // The archive binds its own work id; a row cannot be moved to another id
    // without repacking the author's bytes. Only the version can be replaced.
    need(body.id === undefined || body.id === source.metadata.id, 'bad_request');
    const sourceName = source.metadata.kind === 'pet' ? 'pet-idle' : source.metadata.kind === 'theme' ? 'theme-preview' : 'companion-preview';
    const meta = metadata({ ...source.metadata,
      ...(body.version === undefined ? {} : { version: body.version }),
      ...(uploaded === undefined ? {} : { previewSource: sourceName }) });
    const target = releaseId(meta), existing = previous.state.releases.find(release => releaseId(release) === target);
    const holder = previous.state.releases.find(release => identity(release) === identity(meta))?.owner;
    need(!holder || sameOwner(holder, source.owner), 'owner_conflict', 409);
    need(!previous.state.withdrawn.some(withdrawal => releaseId(withdrawal) === target), 'version_withdrawn', 409);
    need(!existing || existing.sha256 === meta.sha256 && existing.size === meta.size, 'version_rewritten', 409);
    const bytes = await blobBytes(env, source.metadata), validation = validatePack(bytes, meta, MAX_MOC_VERSION);
    // An explicit PNG replaces derivation; otherwise a declared preview source
    // is derived from the archive exactly as a normal submission would be.
    let preview: PublicPreview | undefined, image: Uint8Array | undefined;
    if (uploaded !== undefined) {
      const info = validatePublicPng(uploaded), digest = await sha256(uploaded);
      preview = { path: previewUrl(meta, digest), sha256: digest, size: uploaded.length, width: info.width, height: info.height };
      image = uploaded;
    } else if (meta.previewSource !== undefined) {
      const derived = await derivePreview(bytes, meta);
      if (derived) { preview = derived.descriptor; image = derived.bytes; }
    }
    if (preview && image) await putPreview(env, preview, image);
    const now = new Date().toISOString(), state = editState(previous), fresh = await newSubmissionId(state, source.owner);
    const submission: Submission = { submissionId: fresh, owner: source.owner, metadata: meta, status: 'pending',
      createdAt: now, updatedAt: now, submittedAt: now, validation, ...(preview ? { preview } : {}) };
    state.submissions.push(submission);
    audit(state, now, { action: 'create', actor: 'admin', submissionId: fresh, reason: explanation });
    audit(state, now, { action: 'submit', actor: 'admin', submissionId: fresh });
    approve(state, submission, now, explanation);
    // Only a live pending row is superseded; approved/rejected/withdrawn rows
    // stay as retained history for the same author.
    if (source.status === 'pending') withdrawSubmission(state, source, now, `已被管理员修正版 ${fresh} 取代`, 'admin');
    await commitState(env, previous, state, now);
    return json(200, { submission, replaced: source.submissionId });
  }
  method(request, 'POST'); const body = await jsonBody(request), explanation = reason(body);
  if (match[2] === 'withdraw') {
    const previous = await loadState(env), state = editState(previous), submission = find(state, sid), now = new Date().toISOString();
    if (submission.status === 'withdrawn') return json(200, { submission });
    // Moderators can release reservations held by abandoned drafts as well as
    // withdraw approved work; metadata/history/audit remain retained.
    withdrawSubmission(state, submission, now, explanation, 'admin');
    await commitState(env, previous, state, now); return json(200, { submission });
  }
  need(body.decision === 'approve' || body.decision === 'reject', 'bad_decision');
  const initial = find((await loadState(env)).state, sid);
  if (initial.review?.decision === body.decision && initial.status === (body.decision === 'approve' ? 'approved' : 'rejected')) return json(200, { submission: initial });
  need(initial.status === 'pending', 'submission_state', 409);
  let validation = initial.validation;
  if (body.decision === 'approve') {
    enabled(env, initial.metadata.kind);
    const release = largeArchiveLease(initial.metadata.size);
    try { validation = validatePack(await blobBytes(env, initial.metadata), initial.metadata, MAX_MOC_VERSION); } finally { release(); }
    if (initial.preview) {
      const info = validatePublicPng(await previewBytes(env, initial.preview));
      need(info.width === initial.preview.width && info.height === initial.preview.height, 'storage_unavailable', 503);
    }
  }
  const previous = await loadState(env), state = editState(previous), submission = find(state, sid), now = new Date().toISOString();
  need(submission.status === 'pending', 'submission_state', 409);
  if (body.decision === 'approve') {
    submission.validation = validation;
    approve(state, submission, now, explanation);
  } else {
    submission.status = 'rejected'; submission.updatedAt = now; submission.review = { at: now, decision: 'reject', reason: explanation };
    audit(state, now, { action: 'reject', actor: 'admin', submissionId: sid, reason: explanation });
  }
  await commitState(env, previous, state, now); return json(200, { submission });
}
/** An isolate has 128 MB and may serve several requests: one archive over
 *  16 MiB at a time is read and checked in it, another gets 429 and retries;
 *  smaller ones go as they come. The lease lapses by itself, so a request the
 *  runtime drops mid-way (its finally never runs) cannot hold it for good. */
const LARGE_ARCHIVE = 16 * 1024 * 1024, LARGE_LEASE_MS = 10 * 60_000;
/** Reading the body ends before the lease does, leaving time to check it. */
export const LARGE_READ_MS = 9 * 60_000;
let largeLease: { until: number } | null = null;
function largeArchiveLease(size: number): () => void {
  if (size <= LARGE_ARCHIVE) return () => {};
  need(!largeLease || largeLease.until <= Date.now(), 'rate_limited', 429);
  const lease = { until: Date.now() + LARGE_LEASE_MS };
  largeLease = lease;
  return () => { if (largeLease === lease) largeLease = null; };
}
export const AUTO_APPROVE_REASON = '自动通过';
/** The archive checks are the whole review. A version conflict (an id another
 *  author holds, a withdrawn or rewritten version) stays pending for a person. */
function autoApprove(state: State, submission: Submission, now: string) {
  try { approve(state, submission, now, AUTO_APPROVE_REASON); } catch (error) { if (!(error instanceof WorkshopError)) throw error; }
}
/** The archive is in: a repeated upload answers with the record, also once
 *  auto-approval already published it. */
function uploaded(submission: Submission) {
  return submission.status === 'pending' || submission.status === 'approved' && submission.review?.reason === AUTO_APPROVE_REASON;
}
export async function workshop(request: Request, env: Env, ctx: Ctx): Promise<Response> {
  let adminRequest = false;
  try {
    const url = new URL(request.url);
    if (url.pathname === '/workshop/admin') return await adminPage(request);
    if (url.pathname.startsWith('/market/')) return await publicRoute(request, env, ctx, url);
    if (url.pathname === `${API}/capabilities`) {
      method(request, 'GET'); return json(200, { schema: 1, features: features(env), kinds: KINDS, licenses: LICENSES,
        account: account(env), maxMocVersion: MAX_MOC_VERSION, preview: PREVIEW_CONTRACT,
        limits: { archiveBytes: UPLOAD_CAP, expandedBytes: EXPANDED_CAP, companionMemberBytes: MEMBER_CAP, companionEntries: 1000, petEntries: 256 } });
    }
    need(url.pathname.startsWith(API + '/'), 'not_found', 404);
    if (url.pathname.startsWith(API + '/admin/')) { adminRequest = true; return privateAdmin(await adminRoute(request, env, ctx, url)); }
    return await userRoute(request, env, ctx, url);
  } catch (error) {
    const failure = error instanceof WorkshopError ? error : new WorkshopError('storage_unavailable', 503);
    return json(failure.status, { error: `workshop_${failure.code}` }, { ...(failure.status === 429 ? { 'Retry-After': '60' } : {}),
      ...(adminRequest ? { 'Cache-Control': 'private, no-store' } : {}), ...failure.headers });
  }
}
