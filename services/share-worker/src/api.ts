// The link API (docs/design/share-links.md). The server only ever sees ciphertext.

import type { Env } from './env';
import { expiresAt, newId, objectKey, parseTtl, tierOfId, tierOfTtl } from './ids';
import { burstAllowed, clientKey, uploadQuota } from './limits';

export const MAGIC = [0x44, 0x53, 0x47, 0x31]; // "DSG1"
/** Magic + 12-byte IV + 16-byte GCM tag: the smallest valid blob. */
export const MIN_BYTES = 4 + 12 + 16;
export const DEFAULT_MAX_BYTES = 20 * 1024 * 1024;

const API_HEADERS: Record<string, string> = {
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'; sandbox",
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Referrer-Policy': 'no-referrer',
  'X-Robots-Tag': 'noindex',
};

export function json(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...API_HEADERS, 'Content-Type': 'application/json; charset=utf-8', ...extra },
  });
}

const error = (status: number, code: string, extra?: Record<string, string>) => json(status, { error: code }, extra);

function maxBytes(env: Env): number {
  const n = Number(env.MAX_BYTES);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_MAX_BYTES;
}

/** The body, or null once it grows past [limit]. */
export async function readCapped(request: Request, limit: number): Promise<Uint8Array | null> {
  if (!request.body) return new Uint8Array(0);
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.byteLength;
  }
  return out;
}

/** A body whose length is already known, read straight into one buffer: a
 *  large upload is held once, not as chunks plus their concatenation. Longer
 *  than [size]: null. Not finished within [withinMs]: 'timeout'. Shorter: the
 *  bytes that came. */
export async function readExactly(request: Request, size: number, withinMs: number): Promise<Uint8Array | null | 'timeout'> {
  const out = new Uint8Array(size);
  if (!request.body) return out.subarray(0, 0);
  const reader = request.body.getReader();
  const copy = async (): Promise<Uint8Array | null> => {
    let at = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) return out.subarray(0, at);
      if (value.byteLength > size - at) {
        await reader.cancel().catch(() => {});
        return null;
      }
      out.set(value, at);
      at += value.byteLength;
    }
  };
  // One race for the whole copy: racing each read would keep every chunk
  // reachable from the deadline promise until the end.
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<'timeout'>(resolve => { timer = setTimeout(() => resolve('timeout'), withinMs); });
  try {
    const result = await Promise.race([copy(), late]);
    if (result === 'timeout') await reader.cancel().catch(() => {});
    return result;
  } finally { if (timer !== undefined) clearTimeout(timer); }
}


function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Constant-time comparison of two secrets (compared as SHA-256 digests, so
 *  the lengths don't leak either). */
async function sameSecret(a: string, b: string): Promise<boolean> {
  const [x, y] = await Promise.all([sha256Hex(a), sha256Hex(b)]);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x.charCodeAt(i) ^ y.charCodeAt(i);
  return diff === 0;
}

export async function upload(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const ttl = parseTtl(url.searchParams.get('ttl'));
  if (!ttl) return error(400, 'bad_ttl');

  const type = (request.headers.get('Content-Type') ?? '').split(';')[0]!.trim().toLowerCase();
  if (type !== 'application/octet-stream') return error(415, 'bad_content_type');

  const limit = maxBytes(env);
  const declared = request.headers.get('Content-Length');
  if (declared !== null && Number(declared) > limit) return error(413, 'too_large');

  const client = clientKey(request);
  if (!(await burstAllowed(env.UPLOAD_BURST, client))) return error(429, 'rate_limited', { 'Retry-After': '60' });
  const quota = await uploadQuota(env, client);
  if (!quota.allowed) return error(429, 'rate_limited', { 'Retry-After': String(quota.retryAfter) });

  const body = await readCapped(request, limit);
  if (body === null) return error(413, 'too_large');
  if (body.byteLength < MIN_BYTES || MAGIC.some((b, i) => body[i] !== b)) return error(400, 'bad_format');

  const tier = tierOfTtl(ttl);
  const deleteToken = randomToken();
  const tokenHash = await sha256Hex(deleteToken);
  for (let attempt = 0; attempt < 4; attempt++) {
    const id = newId(ttl);
    const key = tier.prefix + id;
    // Check absence atomically with the write, without a separate R2 read.
    const stored = await env.BUCKET.put(key, body, {
      onlyIf: new Headers({ 'If-None-Match': '*' }),
      httpMetadata: { contentType: 'application/octet-stream' },
      customMetadata: { dt: tokenHash },
    });
    if (stored === null) continue;
    await quota.commit();
    const expires = expiresAt(tier, stored.uploaded);
    return json(201, { id, deleteToken, expiresAt: expires ? expires.toISOString() : null });
  }
  return error(503, 'try_again');
}

export async function fetchBlob(request: Request, env: Env, id: string): Promise<Response> {
  if (!(await burstAllowed(env.READ_LIMIT, clientKey(request)))) {
    return error(429, 'rate_limited', { 'Retry-After': '60' });
  }
  const key = objectKey(id);
  if (!key) return error(404, 'not_found');
  const object = await env.BUCKET.get(key);
  if (!object) return error(404, 'not_found');
  const expires = expiresAt(tierOfId(id)!, object.uploaded);
  if (expires && expires.getTime() <= Date.now()) {
    // The lifecycle rule removes it within a day; until then it's gone too.
    await object.body.cancel().catch(() => {});
    return error(404, 'not_found');
  }
  return new Response(object.body, {
    status: 200,
    headers: {
      ...API_HEADERS,
      'Content-Type': 'application/octet-stream',
      'Content-Length': String(object.size),
      'Content-Disposition': `attachment; filename="${id}.dsg"`,
    },
  });
}

export async function remove(request: Request, env: Env, id: string): Promise<Response> {
  const admin = request.headers.get('X-Admin-Key');
  const auth = request.headers.get('Authorization') ?? '';
  const bearer = /^Bearer\s+([A-Za-z0-9_-]{16,128})$/.exec(auth.trim())?.[1] ?? null;
  if (admin === null && bearer === null) return error(401, 'unauthorized');
  const adminAllowed = admin !== null && !!env.ADMIN_KEY && env.ADMIN_KEY.length >= 32 && (await sameSecret(admin, env.ADMIN_KEY));
  if (!adminAllowed && !(await burstAllowed(env.READ_LIMIT, clientKey(request)))) {
    return error(429, 'rate_limited', { 'Retry-After': '60' });
  }

  const key = objectKey(id);
  if (!key) return error(404, 'not_found');
  const object = await env.BUCKET.head(key);
  if (!object) return error(404, 'not_found');

  let allowed = adminAllowed;
  if (admin === null && bearer !== null) {
    const stored = object.customMetadata?.dt ?? '';
    allowed = stored.length === 64 && (await sameSecret(await sha256Hex(bearer), stored));
  }
  if (!allowed) return error(403, 'forbidden');

  await env.BUCKET.delete(key);
  return new Response(null, { status: 204, headers: API_HEADERS });
}
