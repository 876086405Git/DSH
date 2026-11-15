import type { RateLimiter } from './limits';

export interface Env {
  /** Emergency switches. Absent/"1" is enabled; "0" pauses the new capability. */
  WORKSHOP_UPLOAD_ENABLED?: string;
  WORKSHOP_COMPANION_ENABLED?: string;
  /** "1": a submission that passes the archive checks is approved as soon as
   *  it is uploaded. Absent/"0": it waits in the review queue as pending. */
  WORKSHOP_AUTO_APPROVE?: string;
  /** Public client id of the GitHub OAuth App the App signs authors in with;
   *  empty or malformed: capabilities announce `clientId: null`. */
  WORKSHOP_GITHUB_CLIENT_ID?: string;
  /** Tests and the local rehearsal only: an HTTPS origin standing in for
   *  https://api.github.com. Never set in production; never request-supplied. */
  WORKSHOP_GITHUB_API_URL?: string;
  /** HTTPS publication root; defaults to dsh-go-market GitHub Pages. */
  MARKET_SOURCE_URL?: string;
  /** "1": cron also verifies and mirrors pets/adapters from the same market. */
  PET_MARKET_ENABLED?: string;
  /** Static files (public/): the site, and the viewer the Worker serves at /c/<id>. */
  ASSETS: { fetch(request: Request): Promise<Response> };
  /** Ciphertexts, under the tier prefixes of ids.ts. */
  BUCKET: R2Bucket;
  /** The public download bucket (dshgo-dl, at DL_BASE_URL): the cron writes
   *  the market's files there (src/market.ts). */
  DL: R2Bucket;
  /** Hourly upload counters; beta grants and blocks (`beta:` keys). */
  QUOTA?: KVNamespace;
  UPLOAD_BURST?: RateLimiter;
  READ_LIMIT?: RateLimiter;
  /** Secret: lets `DELETE` remove any link (reports). */
  ADMIN_KEY?: string;
  UPLOADS_PER_HOUR?: string;
  MAX_BYTES?: string;
  /** Wrong access keys per client (src/beta-guard.ts). */
  BETA_GUARD?: DurableObjectNamespace;
  /** Secret: keys the access-key hashes and signs beta download links
   *  (src/beta-auth.ts). Without it /beta is 404. */
  BETA_SECRET?: string;
  /** "public": /download serves the latest build to anyone and /beta
   *  redirects there. Anything else (default "key"): an access key on /beta. */
  DOWNLOAD_ACCESS?: string;
  /** Base URL of the Hong Kong bucket (the China route): files are at
   *  `<base><version>/<file>`. Empty or not https: the route isn't offered. */
  CN_BASE_URL?: string;
  /** Base URL of the public download bucket (dshgo-dl): files at
   *  `<base>download/<version>/<file>`, the Global route's once a release is
   *  there. Empty or not https: Global stays on /download/<version>/<file>. */
  DL_BASE_URL?: string;
  /** Workers Analytics Engine datasets (src/stats.ts, src/usage.ts). */
  DOWNLOADS?: AnalyticsEngineDataset;
  CHECKS?: AnalyticsEngineDataset;
  USAGE?: AnalyticsEngineDataset;
  /** Today's random salt for daily device codes (src/stats.ts). */
  STATS_SALT?: DurableObjectNamespace;
  /** Secret: keys the hash of the app's install id (src/usage.ts). Without
   *  it /api/usage/v1 is 404. */
  USAGE_SECRET?: string;
  /** Usage reports per client per minute. */
  USAGE_LIMIT?: RateLimiter;
  /** Optional secret: a GitHub token (no scopes) for the star count's API
   *  requests, which otherwise share GitHub's per-IP limit (src/github.ts). */
  GITHUB_TOKEN?: string;
}
