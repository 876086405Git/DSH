import type { Env } from './env';
import { readCapped } from './api';
import { record } from './pet-catalog';
import { readBounded } from './pet-market-io';
import { burstAllowed, clientKey, uploadQuota } from './limits';
import { strictJson } from './workshop-archive';
import { requireWorkshop as need, sha256, text, whole, WorkshopError, type WorkshopKind } from './workshop-common';
import { ACCOUNT_ORIGIN, type Owner } from './workshop-state';

export function features(env: Env) { return { uploads: env.WORKSHOP_UPLOAD_ENABLED === undefined || env.WORKSHOP_UPLOAD_ENABLED === '1', companion: env.WORKSHOP_COMPANION_ENABLED === undefined || env.WORKSHOP_COMPANION_ENABLED === '1' }; }
export function enabled(env: Env, kind?: WorkshopKind): void {
  need(features(env).uploads, 'upload_disabled', 503);
  if (kind === 'companion') need(features(env).companion, 'companion_disabled', 503);
}
/// The App runs GitHub's device flow with this public OAuth App id; the Worker
/// only verifies the token it yields. A malformed id is announced as absent.
export function account(env: Env) {
  const id = env.WORKSHOP_GITHUB_CLIENT_ID;
  return { origin: ACCOUNT_ORIGIN, clientId: id && /^[A-Za-z0-9._-]{1,64}$/.test(id) ? id : null };
}
function githubApi(env: Env): string {
  // Operator configuration for tests and the local rehearsal; never taken from a request.
  const url = new URL(env.WORKSHOP_GITHUB_API_URL ?? 'https://api.github.com');
  need(url.protocol === 'https:' && !url.username && !url.password && url.pathname === '/' && !url.search && !url.hash, 'account_unavailable', 503);
  return url.origin;
}
export async function user(request: Request, env: Env): Promise<Owner> {
  const token = request.headers.get('Authorization')?.match(/^Bearer ([A-Za-z0-9_]{1,255})$/)?.[1];
  need(token, 'account_auth_required', 401);
  // The App names the account system it signed in with, so a client built
  // for another one fails plainly before its credential leaves the Worker.
  need(request.headers.get('X-Workshop-Account-Origin') === ACCOUNT_ORIGIN, 'account_origin', 409);
  await limitBurst(request, env, false);
  try {
    // Workers supports manual/follow, not error. Manual plus the strict 200
    // check below keeps a redirect from carrying the token to another origin.
    const response = await fetch(githubApi(env) + '/user', {
      method: 'GET', redirect: 'manual', signal: AbortSignal.timeout(15_000),
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'dshgo-workshop' },
    });
    // Only 401 says the token is bad; GitHub also answers 403 for its rate limit.
    if (response.status === 401) { void response.body?.cancel().catch(() => {}); throw new WorkshopError('account_auth_invalid', 401); }
    if (response.status !== 200 || !response.body) { void response.body?.cancel().catch(() => {}); throw new WorkshopError('account_unavailable', 503); }
    const length = response.headers.get('Content-Length');
    if (length !== null && (!/^\d+$/.test(length) || Number(length) > 65536)) { void response.body.cancel().catch(() => {}); throw new WorkshopError('account_unavailable', 503); }
    const value = strictJson(await readBounded(response.body, 65536), 65536, 32);
    need(record(value) && whole(value.id, 1, Number.MAX_SAFE_INTEGER) && text(value.login, 256), 'account_unavailable', 503);
    return { accountOrigin: ACCOUNT_ORIGIN, accountId: value.id, username: value.login };
  } catch (error) {
    if (error instanceof WorkshopError && error.code === 'account_auth_invalid') throw error;
    throw new WorkshopError('account_unavailable', 503);
  }
}
export async function admin(request: Request, env: Env): Promise<void> {
  // Same floor as the share API's admin path: a short key is a misconfiguration, not a credential.
  need(env.ADMIN_KEY && env.ADMIN_KEY.length >= 32, 'admin_unavailable', 503);
  const provided = request.headers.get('X-Admin-Key'); need(provided && provided.length <= 4096, 'admin_auth_required', 401);
  const [a, b] = await Promise.all([sha256(provided), sha256(env.ADMIN_KEY)]);
  let different = 0; for (let n = 0; n < a.length; n++) different |= a.charCodeAt(n) ^ b.charCodeAt(n);
  need(different === 0, 'admin_auth_required', 401);
}
/// [scope] gives a kind of request its own count per client, so a page of
/// pictures cannot use up what the catalog and package downloads need.
export async function limitBurst(request: Request, env: Env, write: boolean, scope = 'workshop'): Promise<void> {
  need(await burstAllowed(write ? env.UPLOAD_BURST : env.READ_LIMIT, `${scope}:${clientKey(request)}`), 'rate_limited', 429);
}
export async function quota(request: Request, env: Env, owner: Owner, action: string, count: number): Promise<void> {
  await limitBurst(request, env, true);
  const meter = await uploadQuota({ ...env, UPLOADS_PER_HOUR: String(count) }, `workshop:${owner.accountOrigin}:${owner.accountId}:${action}`);
  if (!meter.allowed) throw new WorkshopError('rate_limited', 429, { 'Retry-After': String(meter.retryAfter) });
  // Charge the attempt before archive parsing, including malformed packages.
  // KV remains an approximate cross-colo limit, as in the existing service.
  await meter.commit();
}
export async function jsonBody(request: Request, cap = 16384): Promise<Record<string, unknown>> {
  need(request.headers.get('Content-Type')?.split(';')[0]?.trim().toLowerCase() === 'application/json', 'content_type', 415);
  const bytes = await readCapped(request, cap); need(bytes, 'body_too_large', 413);
  try { const value = strictJson(bytes, cap, 16); need(record(value), 'bad_request'); return value; }
  catch { throw new WorkshopError('bad_request'); }
}
