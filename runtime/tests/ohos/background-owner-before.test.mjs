import { symlinkFixture } from './host-link-fixture.mjs';
import test, { after, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { openBoundaryJournal } from '../../ohos/lifecycle/journal.mjs';
import { BoundaryCoordinator } from '../../ohos/lifecycle/coordinator.mjs';
import { registerLifecycleRoutes } from '../../ohos/lifecycle/index.mjs';
import { runtimeCapabilities } from '../../ohos/capabilities/snapshot.mjs';
import { loadHostModules } from '../../../tooling/ohos/tests/lifecycle-host-fixture.mjs';
import { httpState, loadHttpTransport, listen, request } from '../../../tooling/ohos/tests/lifecycle-http-fixture.mjs';

const prefix = path.resolve(process.env.DSH_LIFECYCLE_TEST_PREFIX);
const require = createRequire(path.join(prefix, 'package.json'));
const { Context } = await import(pathToFileURL(require.resolve('@deepseek-ai/cordis')));
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const source = path.join(root, 'app/ohos/entry/src/main/ets/runtime');
const modules = await loadHostModules(source);
const { OhosLifecycleTransport } = await loadHttpTransport(source, modules.directory);
// The actual pinned authentication implementation is bundled into this one JS
// file. Export its private constructor in a private copy; do not edit the prefix.
const authInput = require.resolve('@deepseek-ai/dsh-client-connection');
const authSource = await fs.readFile(authInput, 'utf8');
assert(!/from\s+['"]\./.test(authSource));
await symlinkFixture(path.join(prefix, 'node_modules'), path.join(modules.directory, 'node_modules'), 'dir');
const authFixture = path.join(modules.directory, 'actual-browser-auth.mjs');
await fs.writeFile(authFixture, authSource + '\nexport { BrowserAuth };\n');
const { BrowserAuth, HostConnectionService } = await import(pathToFileURL(authFixture));
after(() => modules.close());
afterEach(() => {
  assert.equal(httpState.active.size, 0, 'all native-boundary HTTP clients were destroyed');
  httpState.beforeReply = null; httpState.addAllowed = true; httpState.applyAllowed = true;
});
const observation = (revision, foreground, computePermission = 'denied') => ({ revision, foreground, computePermission });
const body = data => JSON.stringify({ operation: 'host', ...data });
async function fixture(t, options = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-host-http-'));
  const journal = await openBoundaryJournal({ directory: path.join(directory, 'journal'),
    lockExclusive: process._linkedBinding('dsh_ohos_publication').lockExclusive, ...options.journal });
  const coordinator = new BoundaryCoordinator({ journal, bootId: 'actual-host-http-test',
    flushSession: async () => true, readEvents: async () => [], ...options.coordinator });
  const routes = new Map(), ctx = new Context();
  ctx.provide('webServer', { host: '127.0.0.1', protocol: 'http:', register(route) {
    routes.set(route.path, route.handler); return () => routes.delete(route.path);
  } });
  ctx.provide('ohosLifecycle', coordinator);
  const auth = new BrowserAuth(ctx, Buffer.alloc(32, 23), 1);
  const connection = new HostConnectionService(ctx, [], auth);
  (options.registerRoutes ?? registerLifecycleRoutes)(ctx, coordinator, { status: () => ({ fixture: 'HTTP transport not rotated by this adapter' }) });
  const seen = [];
  const { origin } = await listen(t, async (req, res) => {
    const url = new URL(req.url, 'http://localhost'); seen.push({ method: req.method, path: url.pathname });
    if (url.pathname === '/') {
      if (await options.login?.(req, res) === false) return;
      if (connection.authorizeIndex(req, res)) res.end('index');
    } else {
      const handler = routes.get(url.pathname);
      if (handler) await handler(req, res); else { res.writeHead(404); res.end(); }
    }
  });
  t.after(async () => { await coordinator.close(); await ctx.fiber.dispose(); await fs.rm(directory, { recursive: true, force: true }); });
  const login = async () => {
    const response = await request(origin + '/?token=' + encodeURIComponent(auth.launchToken));
    assert.equal(response.status, 303); return response.headers['set-cookie'][0].split(';')[0];
  };
  const post = (cookie, value, extraHeaders = {}) => request(origin + '/dsh-go/v1/lifecycle', {
    method: 'POST', headers: { cookie, 'content-type': 'application/json', ...extraHeaders }, body: JSON.stringify(value),
  });
  return { directory, journal, coordinator, ctx, connection, auth, origin, seen, login, post };
}

// First-red112: a real ordinary signed host cookie is not an ArkTS owner capability.
test('ordinary authenticated host client cannot reopen native host admission', async t => {
  const f = await fixture(t);
  await f.coordinator.observeHost(observation(1, false));
  assert.equal(f.coordinator.status().paused, true);
  const cookie = await f.login();
  const response = await f.post(cookie, { operation: 'host', ...observation(2, true, 'granted') });
  t.diagnostic(JSON.stringify({httpStatus:response.status,paused:f.coordinator.status().paused,
    journalKinds:f.journal.records.map(row=>row.body.kind), proof:'actual718routes+auth+coordinator+nativeflock'}));
  assert.equal(f.coordinator.status().paused, true,
    'generic host-cookie foreground report must not prove actual ArkTS foreground');
});
