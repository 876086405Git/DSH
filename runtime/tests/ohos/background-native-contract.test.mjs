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


const trusted = foreground => ({version:1,engineGeneration:1,ownerGeneration:1,revision:1,grantGeneration:0,
  nowMs:1000,deadlineMs:0,drainAtMs:0,phase:0,available:1,foreground:foreground?1:0,clockFailed:0});
test('native foreground permits repeated observation ACK without an uninitialized promise',async t=>{
 const f=await fixture(t,{coordinator:{readHost:()=>trusted(true)}});
 await f.coordinator.observeHost(observation(1,true));
 await f.coordinator.observeHost(observation(1,true));
 assert.equal(f.coordinator.status().paused,false);
});
test('release manual pause remains durable while native background keeps admission closed',async t=>{
 const f=await fixture(t,{coordinator:{readHost:()=>trusted(false)}});
 await f.coordinator.pause();await f.coordinator.resume();
 assert.equal(f.coordinator.status().manualPaused,false);assert.equal(f.coordinator.status().paused,true);
 await f.coordinator.close();
 const journal=await openBoundaryJournal({directory:path.join(f.directory,'journal'),lockExclusive:process._linkedBinding('dsh_ohos_publication').lockExclusive});
 const again=new BoundaryCoordinator({journal,bootId:'second-boot',flushSession:async()=>true,readEvents:async()=>[],readHost:()=>trusted(false)});
 try {assert.equal(again.status().manualPaused,false,'cold recovery must not resurrect released manual pause');assert.equal(again.status().paused,true);}
 finally {await again.close();}
});
test('HTTP observation cannot replace native facts or pin a caller revision',async t=>{
 const state=trusted(false);
 const f=await fixture(t,{coordinator:{readHost:()=>state}});
 await f.coordinator.observeHost(observation(Number.MAX_SAFE_INTEGER,true,'granted'));
 assert.equal(f.coordinator.status().host.foreground,false);
 assert.equal(f.coordinator.status().host.computePermission,'unknown');
 state.foreground=1;state.revision++;
 const ack=await f.coordinator.observeHost(observation(1,false,'denied'));
 assert.equal(ack.host.foreground,true);assert.equal(ack.host.revision,2);assert.equal(ack.paused,false);
});
test('activity is actual agent work including model wait, never running-state fallback',async t=>{
 let running=false;
 const f=await fixture(t,{coordinator:{readHost:()=>trusted(true),hasActiveRounds:()=>running}});
 assert.equal(f.coordinator.status().busy,false,'idle engine is not an active round');
 running=true;assert.equal(f.coordinator.status().busy,true,'model wait without tools is active');
 running=false;assert.equal(f.coordinator.status().busy,false,'completion/cancel releases activity');
});
test('OS continuous native lease opens background gate without a short deadline; manual pause and revocation still close it',async t=>{
 const state={...trusted(false),phase:7,nowMs:1000000};
 const f=await fixture(t,{coordinator:{readHost:()=>state}});
 let ack=await f.coordinator.observeHost(observation(1,false,'denied'));
 assert.equal(ack.paused,false);assert.equal(ack.host.computePermission,'granted');assert.equal(f.coordinator.admit('continuous-session'),true);
 state.nowMs+=600000;
 assert.equal(f.coordinator.admit('continuous-session'),true,'continuous lease is not a renewed three-minute grant');
 await f.coordinator.pause();assert.equal(f.coordinator.admit('continuous-session'),false);
 await f.coordinator.resume();assert.equal(f.coordinator.admit('continuous-session'),true);
 state.phase=4;state.revision++;
 ack=await f.coordinator.observeHost(observation(2,true,'granted'));
 assert.equal(ack.paused,true);assert.equal(ack.host.computePermission,'unknown');assert.equal(f.coordinator.admit('continuous-session'),false,'HTTP cannot resurrect cancelled OS ownership');
});
test('continuous native state survives actual authenticated ArkTS transport decoding',async t=>{
 const f=await fixture(t,{coordinator:{readHost:()=>({...trusted(false),phase:7})}});
 const transport=new OhosLifecycleTransport();t.after(()=>transport.cancel());
 const ack=await transport.send(f.origin,f.auth.launchToken,observation(1,false,'granted'));
 assert.equal(ack.nativeHost.phase,7);assert.equal(ack.confirmedPause,false);
});
