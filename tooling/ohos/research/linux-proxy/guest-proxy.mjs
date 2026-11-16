import http from 'node:http';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { readFileSync, createReadStream } from 'node:fs';
import { readFile, readdir, readlink, stat, writeFile } from 'node:fs/promises';
import { Readable } from 'node:stream';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { Context } from '@deepseek-ai/cordis';
import { BrowserAuth, HostConnectionService } from './actual-browser-auth.mjs';
import { LinuxInstallationOwner, loadLinuxInstallationManifest } from './source/runtime/ohos/linux/owner.mjs';

const [nativeLibraryDirectory, assetsDirectory, archive, directory, output, phase] = process.argv.slice(2);
// The anonymous pipe carries ephemeral test proxy credentials. It is never
// copied into a record, request log, environment catalog, argv or error text.
const settings = JSON.parse(readFileSync(0, 'utf8'));
const checks = [], cases = []; let owner, downloads = 0, shutdown, stage = 'setup';
const expect = (pass, name) => { if (!pass) throw Object.assign(new Error(name), { code: 'ERR_PROXY_RESEARCH_ASSERTION' }); checks.push(name); };
const stamp = () => process.hrtime.bigint().toString();
const hostProxy = `http://${encodeURIComponent(settings.username)}:${encodeURIComponent(settings.password)}@127.0.0.1:${settings.httpProxyPort}/`;
for (const name of ['http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY']) process.env[name] = hostProxy;
process.env.no_proxy = process.env.NO_PROXY = ''; process.env.NODE_USE_ENV_PROXY = '1';
const module = await import(phase === 'baseline' ? './source/runtime/ohos/linux/control-baseline.mjs' : './source/runtime/ohos/linux/control.mjs');
const { LinuxControl, registerLinuxControlRoutes } = module;
const control = new LinuxControl({ hostPaths: { directory, nativeLibraryDirectory }, assetsDirectory }, {
  async loadModule() { return { loadLinuxInstallationManifest, createLinuxInstallationOwner(options) {
    owner = new LinuxInstallationOwner(options, { download: { fetch: async () => {
      downloads++; expect(phase !== 'resume', 'resume never downloads or replaces the retained target');
      return new Response(Readable.toWeb(createReadStream(archive)), { status: 200 });
    } } }); return owner;
  } }; },
});
const ctx = new Context(), routes = new Map();
ctx.provide('webServer', { host: '127.0.0.1', protocol: 'http:', register(route) { routes.set(route.path, route.handler); return () => routes.delete(route.path); } });
const auth = new BrowserAuth(ctx, Buffer.alloc(32, 97), 1), connection = new HostConnectionService(ctx, [], auth);
registerLinuxControlRoutes(ctx, control);
const server = http.createServer((req, res) => {
  const path = new URL(req.url, 'http://localhost').pathname;
  if (path === '/') { if (connection.authorizeIndex(req, res)) res.end('index'); }
  else { const handler = routes.get(path); if (handler) handler(req, res); else { res.writeHead(404); res.end(); } }
});
server.listen(0, '127.0.0.1'); await once(server, 'listening');
const origin = `http://127.0.0.1:${server.address().port}`;
async function request(path, body, cookie) {
  return new Promise((resolve, reject) => {
    const req = http.request(origin + path, { method: body ? 'POST' : 'GET', headers: {
      ...(cookie ? { cookie } : {}), ...(body ? { 'content-type': 'application/json' } : {}),
    } }, res => {
      const chunks = []; let length = 0;
      res.on('data', bytes => { length += bytes.length; if (length > 98304) req.destroy(Object.assign(new Error('bounded HTTP response'), { code: 'ERR_PROXY_RESEARCH_HTTP_LIMIT' })); else chunks.push(bytes); });
      res.on('error', reject); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, value: Buffer.concat(chunks).toString() }));
    });
    req.on('error', reject); req.setTimeout(5000, () => req.destroy(Object.assign(new Error('HTTP deadline does not mean cancellation'), { code: 'ERR_PROXY_RESEARCH_HTTP_DEADLINE' })));
    req.end(body ? JSON.stringify(body) : undefined);
  });
}
const login = await request('/?token=' + encodeURIComponent(auth.launchToken)); expect(login.status === 303, 'actual BrowserAuth accepts the research session');
const cookie = login.headers['set-cookie'][0].split(';')[0];
async function status() { const response = await request('/dsh-go/v1/linux', undefined, cookie); expect(response.status === 200, 'authenticated status'); return JSON.parse(response.value); }
async function action(name, fields = {}) {
  const current = await status(), response = await request('/dsh-go/v1/linux', { v: 1, instanceId: current.instanceId,
    attemptId: current.attemptId, action: name, ...fields }, cookie);
  expect(response.status === 202, 'control action accepted: ' + name); return JSON.parse(response.value);
}
async function waitFor(predicate, milliseconds = 180000) {
  const deadline = Date.now() + milliseconds;
  while (Date.now() < deadline) {
    const state = await status(); if (predicate(state)) return state;
    if (['failed', 'unknown', 'unavailable'].includes(state.state)) throw Object.assign(new Error('control failed before observation'), { code: 'ERR_PROXY_RESEARCH_CONTROL' });
    await delay(50);
  }
  throw Object.assign(new Error('observation deadline; no completion inferred'), { code: 'ERR_PROXY_RESEARCH_DEADLINE' });
}
const bytes = value => Buffer.from(value.data, 'base64');
function safeJob(job) {
  return { id: job.id, state: job.state, started: job.started, cancelRequested: job.cancelRequested,
    outcome: job.outcome, proxyRevision: job.proxyRevision ?? null,
    diagnosticCategory: ['dns', 'connection', 'tls-interrupted', 'tls-certificate', 'unknown'].includes(job.diagnostic?.category) ? job.diagnostic.category : null,
    stdoutBytes: job.stdout.totalBytes, stderrBytes: job.stderr.totalBytes };
}
async function run(name, argv, { env = {}, stdin = '', exit = 0, outputCheck = () => true } = {}) {
  stage = name;
  const id = (await status()).nextRequestId, startNs = stamp();
  const original = { requestId: id, argv, cwd: '/workspace', env, stdin };
  await action('runPrivateGuest', original);
  const current = await waitFor(value => value.job?.id === id && value.job.state === 'settled', 60000);
  const endNs = stamp(), job = current.job;
  const passed = job.outcome.exitCode === exit && job.outcome.signal === null && !job.outcome.cancelled &&
    !job.stdout.truncated && !job.stderr.truncated && outputCheck(bytes(job.stdout));
  cases.push({ name, startNs, endNs, passed, job: safeJob(job),
    // Only the first, non-secret original request is compared across sources.
    originalProbeSha256: name === 'inherited-http-original' ? createHash('sha256').update(JSON.stringify(original)).digest('hex') : undefined });
  expect(passed, 'real guest case: ' + name); return current;
}
async function dataDescriptors() {
  let count = 0;
  for (const fd of await readdir('/proc/self/fd')) {
    try { const path = await readlink('/proc/self/fd/' + fd); if (path === directory || path.startsWith(directory + '/')) count++; } catch {}
  }
  return count;
}
const deadline = setTimeout(() => { process.stderr.write('ERR_PROXY_RESEARCH_PROCESS_DEADLINE\n'); process.exit(90); }, 360000);
let result;
try {
  await action('setEnabled', { enabled: true });
  const opened = await waitFor(value => value.admission);
  const active = { ...owner.active }, target = await stat(active.target, { bigint: true });
  expect(opened.bootMode === (phase === 'resume' ? 'resume' : 'install'), 'expected install or directboot path');
  expect(downloads === (phase === 'resume' ? 0 : 1), 'expected pinned-archive transport count');
  await run('inherited-http-original', settings.originalArgv, { exit: phase === 'baseline' ? 77 : 0,
    outputCheck: output => output.toString() === (phase === 'baseline' ? 'PROXY_HTTP_FAILURE\n' : 'PROXY_HTTP_OK\n') });
  if (phase !== 'baseline') {
    await run('install-public-test-ca', ['python3', '-c', 'import sys,pathlib;pathlib.Path("/workspace/proxy-research-ca.pem").write_text(sys.stdin.read());print("CA_READY")'],
      { stdin: settings.caPem, outputCheck: output => output.toString() === 'CA_READY\n' });
    const ca = '/workspace/proxy-research-ca.pem';
    const git = (host, resolve = false) => ['git', '-c', 'http.sslCAInfo=' + ca, '-c', 'http.proxySSLCAInfo=' + ca,
      ...(resolve ? ['-c', `http.curloptResolve=${host}:${settings.httpsOriginPort}:10.0.2.2`] : []),
      'ls-remote', `https://${host}:${settings.httpsOriginPort}/repo`];
    const gh = ['gh', 'api', '--hostname', 'proxy-target.invalid', 'meta'];
    const ghEnv = { GH_ENTERPRISE_TOKEN: 'fixture-no-account-token', GH_PROMPT_DISABLED: '1',
      GH_CONFIG_DIR: '/workspace/proxy-research-gh', SSL_CERT_FILE: ca };
    const ghOutput = output => { try { return JSON.parse(output.toString()).proxyResearch === 'ok'; } catch { return false; } };
    if (settings.classifyOriginalGh) {
      const program = `import subprocess,json\np=subprocess.run(['gh','api','--hostname','proxy-target.invalid:${settings.httpsOriginPort}','meta'],capture_output=True,timeout=20)\ne=p.stderr.lower()\nprint(json.dumps({'exitCode':p.returncode,'stdoutBytes':len(p.stdout),'stderrBytes':len(p.stderr),'invalidHostname':b'invalid hostname' in e,'usage':b'usage:' in e,'unknownFlag':b'unknown flag' in e,'runtimeFailure':any(t in e for t in [b'fatal error:',b'runtime:',b'newosproc',b'out of memory'])}))\n`;
      let classification;
      await run('gh-original-hostname-classifier', ['python3', '-c', program], { env: ghEnv, outputCheck: output => {
        try { const value = JSON.parse(output.toString());
          if (Object.keys(value).sort().join(',') !== 'exitCode,invalidHostname,runtimeFailure,stderrBytes,stdoutBytes,unknownFlag,usage' ||
              !['exitCode', 'stdoutBytes', 'stderrBytes'].every(key => Number.isSafeInteger(value[key]) && value[key] >= 0) ||
              !['invalidHostname', 'usage', 'unknownFlag', 'runtimeFailure'].every(key => typeof value[key] === 'boolean')) return false;
          classification = value; return true;
        } catch { return false; }
      } });
      cases.at(-1).classification = classification;
      expect(classification.exitCode === 1 && classification.invalidHostname && !classification.runtimeFailure && !classification.unknownFlag,
        'actual gh rejects hostname-with-port before any transport; only then use a bare hostname');
    }
    const manual = await action('setProxy', { proxy: { mode: 'manual', httpProxy: hostProxy } });
    expect(manual.proxy?.source === 'manual' && manual.proxy.httpConfigured && manual.proxy.httpsConfigured, 'safe manual proxy status');
    await run('git-http-connect', git('proxy-target.invalid'));
    await run('gh-http-connect', gh, { env: ghEnv, outputCheck: ghOutput });
    const secureProxy = `https://${encodeURIComponent(settings.username)}:${encodeURIComponent(settings.password)}@10.0.2.2:${settings.httpsProxyPort}/`;
    await action('setProxy', { proxy: { mode: 'manual', httpProxy: secureProxy } });
    await run('git-https-proxy', git('proxy-target.invalid'));
    await run('gh-https-proxy', gh, { env: ghEnv, outputCheck: ghOutput });
    await action('setProxy', { proxy: { mode: 'manual', httpProxy: hostProxy } });
    for (const host of ['gitee.com', 'repo.gitee.com', 'huaweicloud.com', 'repo.huaweicloud.com']) {
      await run('git-bypass-' + host, git(host, true));
    }
    const pythonDirect = `import socket,urllib.request\nnames=['gitee.com','repo.gitee.com','huaweicloud.com','repo.huaweicloud.com']\noriginal=socket.getaddrinfo\nsocket.getaddrinfo=lambda name,*args,**kwargs:original('10.0.2.2' if name in names else name,*args,**kwargs)\nfor name in names:\n data=urllib.request.urlopen('http://'+name+':${settings.httpOriginPort}/nonce',timeout=10).read(128)\n assert data==b'DSH_PROXY_RESEARCH_NONCE_V1\\n'\nprint('PYTHON_BYPASS_OK')\n`;
    await run('python-domestic-bypass', ['python3', '-c', pythonDirect], { outputCheck: output => output.toString() === 'PYTHON_BYPASS_OK\n' });
    await action('setProxy', { proxy: { mode: 'direct' } });
    const direct = `import urllib.request\ndata=urllib.request.urlopen('http://10.0.2.2:${settings.httpOriginPort}/nonce',timeout=10).read(128)\nassert data==b'DSH_PROXY_RESEARCH_NONCE_V1\\n'\nprint('DIRECT_OK')\n`;
    await run('direct-removes-inherited-proxy', ['python3', '-c', direct], { outputCheck: output => output.toString() === 'DIRECT_OK\n' });
  }
  stage = 'shutdown'; const shutdownStartedNs = stamp();
  await action('shutdown'); shutdown = await waitFor(value => value.shutdownComplete, 30000);
  const shutdownObservedNs = stamp();
  expect(shutdown.retirement?.cleanCheckpoint && shutdown.retirement.resourcesRetired &&
    shutdown.retirement.native?.joined === true && shutdown.retirement.native.retirementError === false,
    'fulfilled shutdown proves guest sync, native retirement and clean checkpoint');
  expect(shutdown.retirement.dataRetained && !shutdown.retirement.filesRemoved, 'published disk remains');
  expect(await dataDescriptors() === 0, 'private root and descendant data descriptors closed after retirement');
  const marker = JSON.parse(await readFile(join(active.directory, 'instance.json'), 'utf8'));
  expect(marker.state === 'clean' && marker.epoch === active.epoch, 'actual retained record is clean for this epoch');
  result = { passed: true, phase, pid: process.pid, checks, cases, downloads,
    active: { persistentInstanceId: active.persistentInstanceId, epoch: active.epoch },
    target: { dev: String(target.dev), ino: String(target.ino), bytes: String(target.size) },
    shutdown: { state: shutdown.state, shutdownComplete: shutdown.shutdownComplete, retirement: shutdown.retirement },
    shutdownStartedNs, shutdownObservedNs, dataDescriptors: 0,
    evidencePolicy: 'No proxy settings/credentials, job env/argv, raw HTTP, raw wire, stdout/stderr contents or credential-derived digests are recorded. Case results keep only bounded outcomes and explicit boolean checks.' };
} catch (error) {
  result = { passed: false, phase, pid: process.pid, stage, checks, cases,
    errorCode: typeof error?.code === 'string' && /^[A-Z0-9_]+$/.test(error.code) ? error.code : 'ERR_PROXY_RESEARCH_FAILURE' };
  process.exitCode = 1;
} finally {
  clearTimeout(deadline);
  try { await control.shutdown(); } catch { if (result) result.cleanupUnconfirmed = true; process.exitCode = 1; }
  if (result) {
    const current = control.status();
    result.cleanup = { state: current.state, shutdownComplete: current.shutdownComplete,
      retirement: current.retirement, dataDescriptors: await dataDescriptors() };
  }
  if (result) await writeFile(join(output, 'RESULT.json'), JSON.stringify(result, null, 2) + '\n', { mode: 0o600 });
  await ctx.fiber.dispose(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
}
