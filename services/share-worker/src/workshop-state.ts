// One private R2 CAS object is the authority for approvals, permanent version
// bindings, current public rows, withdrawals and their audit trail.
import type { Env } from './env';
import { record } from './pet-catalog';
import { readBounded } from './pet-market-io';
import { strictJson } from './workshop-archive';
import { assetUrl, encoder, EXPANDED_CAP, LEGACY_UPLOAD_CAP, UPLOAD_CAP, hash, id, identity, kind, releaseId, requireWorkshop as need, sha256, validVersion, text, validMeta, validPreview, whole,
  WorkshopError, type PublicPreview, type SubmissionMeta, type WorkshopKind } from './workshop-common';
import type { PackSummary } from './workshop-pack';

export const STATE_KEY = 'workshop/state-v1.json';
export const STATE_CAP = 8 * 1024 * 1024;
export const AUDIT_RETENTION_MS = 186 * 24 * 60 * 60 * 1000;
export const STATUSES = ['draft', 'pending', 'approved', 'rejected', 'withdrawn'] as const;
export type Status = typeof STATUSES[number];
/// Authors are GitHub accounts; the origin is kept so a stored identity names its account system.
export const ACCOUNT_ORIGIN = 'https://github.com';
export interface Owner { accountOrigin: string; accountId: number; username: string }
export interface Submission {
  submissionId: string; owner: Owner; metadata: SubmissionMeta; status: Status; createdAt: string; updatedAt: string;
  submittedAt?: string; validation?: PackSummary; preview?: PublicPreview;
  review?: { at: string; decision: 'approve' | 'reject'; reason: string };
  withdrawal?: { at: string; reason: string };
}
export interface Release { kind: WorkshopKind; id: string; version: string; sha256: string; size: number; owner: Owner; approvedAt: string }
export interface Withdrawal { kind: WorkshopKind; id: string; version: string; reason: string; at: string }
export interface Report {
  reportId: string; kind: WorkshopKind; id: string; version: string; reason: string; reporter: Owner; createdAt: string;
  resolution?: { at: string; decision: 'handled' | 'dismissed'; reason: string; actor: 'admin' };
}
export interface Audit {
  eventId: string; at: string; action: 'create' | 'submit' | 'approve' | 'reject' | 'withdraw' | 'report' | 'resolve_report';
  actor: Owner | 'admin'; submissionId?: string; releaseId?: string; reportId?: string; reason?: string;
}
export interface State {
  schema: 1; revision: number; updatedAt: string; submissions: Submission[]; releases: Release[];
  current: string[]; withdrawn: Withdrawal[]; reports: Report[]; audit: Audit[];
}
export interface Snapshot { etag: string | null; state: State }
const timestamp = (v: unknown): v is string => typeof v === 'string' && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(v) && Number.isFinite(Date.parse(v)) && new Date(v).toISOString() === v;
const token = (v: unknown): v is string => typeof v === 'string' && v.length === 32 && /^[a-f0-9]{32}$/.test(v);
export const sameOwner = (a: Owner, b: Owner) => a.accountOrigin === b.accountOrigin && a.accountId === b.accountId;
function validOwner(v: unknown): v is Owner {
  return record(v) && v.accountOrigin === ACCOUNT_ORIGIN && whole(v.accountId, 1, Number.MAX_SAFE_INTEGER) && text(v.username, 256);
}
function validSummary(v: unknown): v is PackSummary {
  return record(v) && text(v.validator, 256) && whole(v.files, 1, 1000) && whole(v.expandedBytes, 1, EXPANDED_CAP) &&
    (v.sheets === undefined || whole(v.sheets, 1, 64)) && (v.mocVersions === undefined || Array.isArray(v.mocVersions) && v.mocVersions.length > 0 && v.mocVersions.every(n => whole(n, 1, 6)));
}
function validSubmission(v: unknown): v is Submission {
  if (!record(v) || !token(v.submissionId) || !validOwner(v.owner) || !validMeta(v.metadata) || !STATUSES.includes(v.status as Status) ||
      !timestamp(v.createdAt) || !timestamp(v.updatedAt) || v.updatedAt < v.createdAt) return false;
  if ((v.submittedAt === undefined) !== (v.validation === undefined) || v.submittedAt !== undefined && (!timestamp(v.submittedAt) || !validSummary(v.validation))) return false;
  // Submissions without a registered preview are image-free. A declared
  // preview is registered when the archive enters pending and stays bound to
  // this submission through review/withdrawal; Release is unchanged. A
  // declaration with no registration (a Worker without previews took the
  // archive) is read as image-free too: every reader asks for the descriptor,
  // and refusing the whole state would take the catalog down with it.
  if (v.preview !== undefined && (v.submittedAt === undefined || !validPreview(v.preview, v.metadata))) return false;
  if (v.review !== undefined && (!record(v.review) || !timestamp(v.review.at) || !['approve', 'reject'].includes(v.review.decision as string) || !text(v.review.reason, 2000))) return false;
  if (v.withdrawal !== undefined && (!record(v.withdrawal) || !timestamp(v.withdrawal.at) || !text(v.withdrawal.reason, 2000))) return false;
  if (v.status === 'draft') return v.submittedAt === undefined && v.review === undefined && v.withdrawal === undefined;
  if (v.status === 'pending') return v.submittedAt !== undefined && v.review === undefined && v.withdrawal === undefined;
  if (v.status === 'withdrawn') return v.withdrawal !== undefined;
  return v.submittedAt !== undefined && record(v.review) && v.review.decision === (v.status === 'approved' ? 'approve' : 'reject') && v.withdrawal === undefined;
}
function validateState(v: unknown): asserts v is State {
  need(record(v) && v.schema === 1 && whole(v.revision, 0, Number.MAX_SAFE_INTEGER) && timestamp(v.updatedAt) &&
    Array.isArray(v.submissions) && v.submissions.length <= 10000 && Array.isArray(v.releases) && v.releases.length <= 10000 &&
    Array.isArray(v.current) && v.current.length <= 1000 && Array.isArray(v.withdrawn) && v.withdrawn.length <= 4000 &&
    Array.isArray(v.reports) && v.reports.length <= 10000 && Array.isArray(v.audit) && v.audit.length <= 20000, 'state_invalid', 503);
  const submissions = new Map<string, Submission>(), releases = new Map<string, Release>(), owners = new Map<string, Owner>(), withdrawn = new Set<string>();
  for (const s of v.submissions) { need(validSubmission(s) && !submissions.has(s.submissionId), 'state_invalid', 503); submissions.set(s.submissionId, s); }
  for (const r of v.releases) {
    need(record(r) && kind(r.kind) && id(r.id) && validVersion(r.version) && hash(r.sha256) && whole(r.size, 1, UPLOAD_CAP) && validOwner(r.owner) && timestamp(r.approvedAt), 'state_invalid', 503);
    const release = r as unknown as Release, key = releaseId(release), who = owners.get(identity(release));
    need(!releases.has(key) && (!who || sameOwner(who, release.owner)), 'state_invalid', 503); releases.set(key, release); owners.set(identity(release), release.owner);
  }
  for (const w of v.withdrawn) {
    need(record(w) && kind(w.kind) && id(w.id) && validVersion(w.version) && text(w.reason, 2000) && timestamp(w.at), 'state_invalid', 503);
    const key = releaseId(w as unknown as Withdrawal); need(releases.has(key) && !withdrawn.has(key), 'state_invalid', 503); withdrawn.add(key);
  }
  const current = new Set<string>();
  for (const key of v.current) {
    const s = typeof key === 'string' ? submissions.get(key) : undefined;
    need(s?.status === 'approved', 'state_invalid', 503); const meta = s.metadata, release = releases.get(releaseId(meta));
    need(release && sameOwner(release.owner, s.owner) && release.sha256 === meta.sha256 && release.size === meta.size && !withdrawn.has(releaseId(meta)) && !current.has(identity(meta)), 'state_invalid', 503);
    current.add(identity(meta));
  }
  for (const s of submissions.values()) if (s.review?.decision === 'approve') {
    const release = releases.get(releaseId(s.metadata));
    need(release && sameOwner(release.owner, s.owner) && release.sha256 === s.metadata.sha256 && release.size === s.metadata.size, 'state_invalid', 503);
    need(s.status === 'withdrawn' ? withdrawn.has(releaseId(s.metadata)) : !withdrawn.has(releaseId(s.metadata)), 'state_invalid', 503);
  }
  const reports = new Map<string, Report>();
  for (const r of v.reports) {
    need(record(r) && token(r.reportId) && !reports.has(r.reportId) && kind(r.kind) && id(r.id) && validVersion(r.version) && text(r.reason, 2000) && validOwner(r.reporter) && timestamp(r.createdAt), 'state_invalid', 503);
    need(r.resolution === undefined || record(r.resolution) && timestamp(r.resolution.at) && r.resolution.at >= r.createdAt &&
      ['handled', 'dismissed'].includes(r.resolution.decision as string) && text(r.resolution.reason, 2000) && r.resolution.actor === 'admin', 'state_invalid', 503);
    need(releases.has(releaseId(r as unknown as Report)), 'state_invalid', 503); reports.set(r.reportId, r as unknown as Report);
  }
  const eventIds = new Set<string>();
  for (const e of v.audit) {
    need(record(e) && token(e.eventId) && !eventIds.has(e.eventId) && timestamp(e.at) && ['create', 'submit', 'approve', 'reject', 'withdraw', 'report', 'resolve_report'].includes(e.action as string) &&
      (e.actor === 'admin' || validOwner(e.actor)) && (e.submissionId === undefined || token(e.submissionId) && submissions.has(e.submissionId)) &&
      (e.releaseId === undefined || typeof e.releaseId === 'string' && releases.has(e.releaseId)) && (e.reportId === undefined || token(e.reportId) && reports.has(e.reportId)) &&
      (e.reason === undefined || text(e.reason, 2000)), 'state_invalid', 503); eventIds.add(e.eventId);
    if (e.action === 'resolve_report') {
      const report = reports.get(e.reportId as string);
      need(report?.resolution && e.actor === 'admin' && e.at === report.resolution.at && e.reason === report.resolution.reason &&
        e.releaseId === releaseId(report), 'state_invalid', 503);
    }
  }
}
function empty(): State { return { schema: 1, revision: 0, updatedAt: '1970-01-01T00:00:00.000Z', submissions: [], releases: [], current: [], withdrawn: [], reports: [], audit: [] }; }
export async function loadState(env: Env): Promise<Snapshot> {
  try {
    const object = await env.BUCKET.get(STATE_KEY);
    if (!object) return { etag: null, state: empty() };
    if (object.size > STATE_CAP || !object.body) { void object.body?.cancel().catch(() => {}); throw new WorkshopError('state_invalid', 503); }
    const bytes = await readBounded(object.body, STATE_CAP); need(bytes.length === object.size && !!object.httpEtag, 'state_invalid', 503);
    let value: unknown;
    try { value = strictJson(bytes, STATE_CAP, 64); validateState(value); } catch { throw new WorkshopError('state_invalid', 503); }
    return { etag: object.httpEtag, state: value as State };
  } catch (error) { if (error instanceof WorkshopError) throw error; throw new WorkshopError('storage_unavailable', 503); }
}
export async function commitState(env: Env, previous: Snapshot, state: State, now: string): Promise<void> {
  state.revision = previous.state.revision + 1; state.updatedAt = now;
  // Only old audit events expire. Version bindings/owners/withdrawals and
  // metadata records are never pruned by this writer, even after six months.
  state.audit = state.audit.filter(e => Date.parse(e.at) >= Date.parse(now) - AUDIT_RETENTION_MS);
  need(state.submissions.length <= 10000 && state.releases.length <= 10000 && state.current.length <= 1000 && state.withdrawn.length <= 4000 && state.reports.length <= 10000 && state.audit.length <= 20000, 'capacity', 503);
  validateState(state);
  const bytes = encoder.encode(JSON.stringify(state));
  // Reserve the worst-case UTF-8 reason + per-record withdrawal + audit bytes
  // before admitting work. Filling the envelope with reports/drafts must not
  // make an already-admitted owner's/admin's withdrawal impossible. Records
  // are bounded; 24/12 KiB include a 2,000-code-point reason and owner fields.
  const liveRecords = state.submissions.filter(s => s.status !== 'withdrawn').length;
  const activeReleases = state.releases.length - state.withdrawn.length;
  const withdrawalReserve = liveRecords * 24 * 1024 + activeReleases * 12 * 1024;
  // Each open report reserves its one resolution and audit event. Two reasons
  // of 2000 code points occupy at most 16000 UTF-8 bytes under text(); 20KiB also
  // covers the fixed fields. This is additional to every withdrawal reserve.
  // Legacy records without resolution read as open; an existing authority
  // must meet this budget before upgrading. Do not mix old/new writers.
  const openReports = state.reports.filter(r => r.resolution === undefined).length;
  need(bytes.length + withdrawalReserve + openReports * 20 * 1024 <= STATE_CAP &&
    state.audit.length + liveRecords + activeReleases + openReports <= 20000 &&
    state.withdrawn.length + activeReleases <= 4000, 'capacity', 503);
  try {
    const result = await env.BUCKET.put(STATE_KEY, bytes, {
      onlyIf: new Headers(previous.etag ? { 'If-Match': previous.etag } : { 'If-None-Match': '*' }),
      sha256: await sha256(bytes), httpMetadata: { contentType: 'application/json', cacheControl: 'no-store' },
    });
    need(result, 'state_conflict', 409);
  } catch (error) { if (error instanceof WorkshopError) throw error; throw new WorkshopError('storage_unavailable', 503); }
}
// loadState parses a fresh request-owned object; it is never shared/cached.
// Editing it avoids a second full 8 MiB envelope while preserving the original
// ETag as the CAS condition. The previous revision is read before increment.
export const editState = (snapshot: Snapshot): State => snapshot.state;
export function audit(state: State, now: string, event: Omit<Audit, 'eventId' | 'at'>): void {
  state.audit.push({ eventId: crypto.randomUUID().replaceAll('-', ''), at: now, ...event });
}
export function resolveReport(state: State, report: Report, now: string, decision: 'handled' | 'dismissed', reason: string): void {
  need(!report.resolution || report.resolution.decision === decision, 'report_state', 409);
  if (report.resolution) return;
  report.resolution = { at: now, decision, reason, actor: 'admin' };
  audit(state, now, { action: 'resolve_report', actor: 'admin', reportId: report.reportId, releaseId: releaseId(report), reason });
}
export function approve(state: State, submission: Submission, now: string, reason: string): void {
  need(submission.status === 'pending', 'submission_state', 409);
  const meta = submission.metadata, key = releaseId(meta);
  need(!state.withdrawn.some(w => releaseId(w) === key), 'version_withdrawn', 409);
  const existing = state.releases.find(r => releaseId(r) === key), owner = state.releases.find(r => identity(r) === identity(meta))?.owner;
  need(!owner || sameOwner(owner, submission.owner), 'owner_conflict', 409);
  need(!existing || existing.sha256 === meta.sha256 && existing.size === meta.size, 'version_rewritten', 409);
  if (!existing) state.releases.push({ kind: meta.kind, id: meta.id, version: meta.version, sha256: meta.sha256, size: meta.size, owner: submission.owner, approvedAt: now });
  state.current = state.current.filter(sid => identity(state.submissions.find(s => s.submissionId === sid)!.metadata) !== identity(meta));
  state.current.push(submission.submissionId); submission.status = 'approved'; submission.updatedAt = now; submission.review = { at: now, decision: 'approve', reason };
  audit(state, now, { action: 'approve', actor: 'admin', submissionId: submission.submissionId, releaseId: key, reason });
}
export function withdrawRelease(state: State, release: Release, now: string, reason: string): Withdrawal {
  const key = releaseId(release), previous = state.withdrawn.find(w => releaseId(w) === key); if (previous) return previous;
  const withdrawn: Withdrawal = { kind: release.kind, id: release.id, version: release.version, reason, at: now }; state.withdrawn.push(withdrawn);
  state.current = state.current.filter(sid => releaseId(state.submissions.find(s => s.submissionId === sid)!.metadata) !== key);
  for (const s of state.submissions) if (s.review?.decision === 'approve' && releaseId(s.metadata) === key) {
    s.status = 'withdrawn'; s.updatedAt = now; s.withdrawal = { at: now, reason };
  }
  return withdrawn;
}
export function withdrawSubmission(state: State, submission: Submission, now: string, reason: string, actor: Owner | 'admin'): void {
  if (submission.status === 'withdrawn') return;
  if (submission.review?.decision === 'approve') {
    const release = state.releases.find(r => releaseId(r) === releaseId(submission.metadata))!;
    withdrawRelease(state, release, now, reason);
    audit(state, now, { action: 'withdraw', actor, submissionId: submission.submissionId, releaseId: releaseId(release), reason });
  } else {
    submission.status = 'withdrawn'; submission.updatedAt = now; submission.withdrawal = { at: now, reason };
    audit(state, now, { action: 'withdraw', actor, submissionId: submission.submissionId, reason });
  }
}
export function catalog(state: State, features: { uploads: boolean; companion: boolean }, onlyCompanions = false) {
  const submissions = new Map(state.submissions.map(s => [s.submissionId, s]));
  const entries = state.current.map(sid => submissions.get(sid)!).filter(s => (features.companion || s.metadata.kind !== 'companion') && (!onlyCompanions || s.metadata.kind === 'companion'))
    .map(s => {
      const { rightsConfirmed: _, ...meta } = s.metadata;
      return { ...meta, ...(s.preview ? { preview: { ...s.preview } } : {}), url: assetUrl(s.metadata), blockedVersions: state.withdrawn.filter(w => identity(w) === identity(meta)).map(w => w.version).sort() };
    }).sort((a, b) => identity(a).localeCompare(identity(b)));
  // Over the old cap: in largeEntries, which apps from before it never read.
  const large = entries.filter(e => e.size > LEGACY_UPLOAD_CAP);
  return { schema: 1, generatedAt: state.updatedAt, features, entries: entries.filter(e => e.size <= LEGACY_UPLOAD_CAP),
    ...(large.length ? { largeEntries: large } : {}), withdrawn: state.withdrawn.filter(w => !onlyCompanions || w.kind === 'companion') };
}
