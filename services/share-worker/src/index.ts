// dshgo-share: hosted conversation links for dsh-go (docs/design/share-links.md).
//
//   POST   /api/v1/c?ttl=7d|30d|forever   store a ciphertext → {id, deleteToken, expiresAt}
//   GET    /api/v1/c/<id>                 the ciphertext
//   DELETE /api/v1/c/<id>                 Bearer <deleteToken>, or X-Admin-Key
//   GET    /c/<id>                        the viewer page (decrypts with #k=…)
//   GET    /                              the home page (site/home/), its files
//                                         at /app.js, /assets/…, and the landing
//                                         page at /share/: static files, served
//                                         without the Worker (src/site.ts)
//   GET    /beta, /beta/…                 beta builds behind an access key (src/beta.ts)
//   GET    /download, /download/…         the same builds for anyone, once
//                                         DOWNLOAD_ACCESS=public (src/download.ts)
//   POST   /api/usage/v1                  the app's anonymous usage report (src/usage.ts)
//   GET    /api/github/stars              the repository's star count, for the home page
//                                         (src/github.ts)
//   GET    /market/index.json, /market/dsh-go.json, /p/<package>
//                                         the official plugin market (src/market.ts),
//                                         also put on the public bucket every 10
//                                         minutes (the cron, below)
//
// Downloads, update checks and usage reports are counted in Analytics Engine
// without keeping IPs (src/stats.ts); scripts/stats.sh reads them.
//
// /update.json (a retired public mirror) is 404, and so is /download until
// DOWNLOAD_ACCESS=public.

import { fetchBlob, json, remove, upload } from './api';
import type { Env } from './env';
import { beta, isBetaPath } from './beta';
export { BetaGuard } from './beta-guard';
import { accessMode, download, isDownloadPath } from './download';
export { StatsSalt } from './stats';
import { usage } from './usage';
import { usageV4 } from './usage-v4';
import { githubStars } from './github';
import { isMarketPath, market, publishMarket } from './market';
import { isPetMarketPath, petMarket, publishPetMarket } from './pet-market';
import type { Ctx } from './files';
import { isWorkshopPath, workshop } from './workshop';
import { notFound, redirect, viewer } from './site';

const VIEWER_PATH = /^\/c\/([0-9A-Za-z]{6,32})\/?$/;
const BLOB_PATH = /^\/api\/v1\/c\/([^/]+)$/;
/** Paths of the retired public download mirror; 404 (/download is the
 *  public page once DOWNLOAD_ACCESS=public). */
const RETIRED = /^\/(?:update\.json|download(?:\/.*)?)$/;

async function route(request: Request, env: Env, ctx: Ctx): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;

  if (isWorkshopPath(path)) return workshop(request, env, ctx);
  if (path.startsWith('/api/')) {
    if (path === '/api/usage/v1') return usage(request, env);
    if (path === '/api/usage/v4') return usageV4(request, env);
    if (path === '/api/github/stars') return githubStars(request, env, ctx);
    if (path === '/api/v1/c') {
      return method === 'POST' ? upload(request, env) : json(405, { error: 'method_not_allowed' }, { Allow: 'POST' });
    }
    const blob = BLOB_PATH.exec(path);
    if (blob) {
      const id = blob[1]!;
      if (method === 'GET') return fetchBlob(request, env, id);
      if (method === 'DELETE') return remove(request, env, id);
      return json(405, { error: 'method_not_allowed' }, { Allow: 'GET, DELETE' });
    }
    return json(404, { error: 'not_found' });
  }

  if (isPetMarketPath(path)) return petMarket(request, env, ctx);
  if (isMarketPath(path)) return market(request, env, ctx);
  if (isBetaPath(path)) return beta(request, env, ctx);
  if (isDownloadPath(path) && accessMode(env) === 'public') return download(request, env, ctx);
  if (RETIRED.test(path) || path.startsWith('/__edge/')) return notFound();
  if (method !== 'GET' && method !== 'HEAD') return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
  if (VIEWER_PATH.test(path)) return viewer(request, env);
  if (path === '/share') return redirect('/share/', 301);
  // The site's files never get here (wrangler.jsonc assets): no such file, or a hidden one.
  return notFound();
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    try {
      return await route(request, env, ctx);
    } catch (e) {
      console.error('unhandled', e instanceof Error ? e.message : String(e));
      return json(500, { error: 'internal' });
    }
  },
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    if (env.PET_MARKET_ENABLED !== '1') return publishMarket(env);
    // A plugin publication failure must not settle the scheduled handler while
    // the independently started companion publication is still in flight.
    const results = await Promise.allSettled([publishMarket(env), publishPetMarket(env)]);
    for (const result of results) if (result.status === 'rejected') throw result.reason;
  },
} satisfies ExportedHandler<Env>;
