import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { access, readFile, readdir, readlink, stat, writeFile } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { Readable } from 'node:stream';
import { join } from 'node:path';
import { Context } from '@deepseek-ai/cordis';
import { BrowserAuth, HostConnectionService } from './actual-browser-auth.mjs';
import { LinuxControl, registerLinuxControlRoutes } from './source/runtime/ohos/linux/control.mjs';
import { LinuxInstallationOwner, loadLinuxInstallationManifest } from './source/runtime/ohos/linux/owner.mjs';

const [nativeLibraryDirectory, assetsDirectory, archive, directory, resultPath] = process.argv.slice(2);
const checks = [], observations = []; let owner, ownerCreations = 0, downloads = 0, shutdown;
const check = (name, pass, facts = {}) => {
  const row = { name, pass: !!pass, ...facts }; checks.push(row); console.log(JSON.stringify(row)); assert.ok(pass, name);
};
const control = new LinuxControl({ hostPaths: { directory, nativeLibraryDirectory }, assetsDirectory }, {
  async loadModule() {
    return { loadLinuxInstallationManifest, createLinuxInstallationOwner(options) {
      ownerCreations++;
      // The only replaced operation is fetching the pinned archive. Native
      // createSession/requestStop/join, guest, owner and backend are unchanged.
      owner = new LinuxInstallationOwner(options, { download: { fetch: async () => {
        downloads++; return new Response(Readable.toWeb(createReadStream(archive)), { status: 200 });
      } } });
      return owner;
    } };
  },
});
const ctx = new Context(), routes = new Map();
ctx.provide('webServer', { host: '127.0.0.1', protocol: 'http:', register(route) {
  routes.set(route.path, route.handler); return () => routes.delete(route.path);
} });
const auth = new BrowserAuth(ctx, Buffer.alloc(32, 83), 1), connection = new HostConnectionService(ctx, [], auth);
registerLinuxControlRoutes(ctx, control);
const server = http.createServer((req, res) => {
  const path = new URL(req.url, 'http://localhost').pathname;
  if (path === '/') { if (connection.authorizeIndex(req, res)) res.end('index'); }
  else { const handler = routes.get(path); if (handler) handler(req, res); else { res.writeHead(404); res.end(); } }
});
server.listen(0, '127.0.0.1'); await once(server, 'listening');
const origin = `http://127.0.0.1:${server.address().port}`;
function request(path, body, cookie) {
  return new Promise((resolve, reject) => {
    const req = http.request(origin + path, { method: body ? 'POST' : 'GET', headers: {
      ...(cookie ? { cookie } : {}), ...(body ? { 'content-type': 'application/json' } : {}),
    } }, res => {
      const chunks = []; let bytes = 0;
      res.on('data', chunk => { bytes += chunk.length; if (bytes > 98304) req.destroy(new Error('bounded response exceeded')); else chunks.push(chunk); });
      res.on('error', reject); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject); req.setTimeout(5000, () => req.destroy(new Error('HTTP read timed out; operation outcome must be queried')));
    req.end(body ? JSON.stringify(body) : undefined);
  });
}
const login = await request('/?token=' + encodeURIComponent(auth.launchToken)); assert.equal(login.status, 303);
const cookie = login.headers['set-cookie'][0].split(';')[0];
async function status() {
  const response = await request('/dsh-go/v1/linux', undefined, cookie); assert.equal(response.status, 200);
  return JSON.parse(response.text);
}
async function command(action, fields = {}) {
  const before = await status(), response = await request('/dsh-go/v1/linux', { v: 1, instanceId: before.instanceId,
    attemptId: before.attemptId, action, ...fields }, cookie);
  observations.push({ action, requestId: fields.requestId ?? null, httpStatus: response.status });
  assert.equal(response.status, 202); return JSON.parse(response.text);
}
async function waitFor(predicate, label, milliseconds = 180000) {
  const deadline = Date.now() + milliseconds; let last, lastStage;
  while (Date.now() < deadline) {
    last = await status();
    const stage = last.progress?.stage + ':' + last.progress?.step;
    if (stage !== lastStage && last.progress) { console.log(JSON.stringify({ progress: last.progress, state: last.state })); lastStage = stage; }
    if (predicate(last)) return last;
    if (['unknown', 'failed', 'unavailable'].includes(last.state)) throw Object.assign(new Error(label + ': ' + last.state), { state: last });
    await delay(50);
  }
  throw Object.assign(new Error(label + ' deadline; no synthetic completion'), { state: last });
}
const text = output => Buffer.from(output.data, 'base64').toString('utf8');
async function run(argv) {
  const before = await status(), requestId = before.nextRequestId;
  const accepted = await command('runPrivateGuest', { requestId, argv, cwd: '/workspace', env: {}, stdin: '' });
  assert.equal(accepted.job.id, requestId);
  const result = await waitFor(state => state.job?.id === requestId && state.job.state === 'settled', argv[0], 60000);
  assert.equal(result.job.outcome.exitCode, 0, JSON.stringify(result.job)); return { job: result.job, requestId };
}
async function dataDescriptors() {
  const result = [];
  for (const fd of await readdir('/proc/self/fd')) {
    try { const target = await readlink('/proc/self/fd/' + fd); if (target.startsWith(directory + '/')) result.push({ fd: Number(fd), target }); } catch {}
  }
  return result.sort((a, b) => a.fd - b.fd);
}
const deadline = setTimeout(() => { console.error('REAL_GUEST_CONTROL_DEADLINE'); process.exit(90); }, 300000);
try {
  const initial = await status(); check('authenticated GET performs no install/native work', initial.state === 'disabled' && !initial.ownerRetained && downloads === 0 && ownerCreations === 0);
  const accepted = await command('setEnabled', { enabled: true });
  check('enable is 202 admission, not completion', accepted.state === 'installing' && accepted.admission === false);
  const opened = await waitFor(state => state.admission, 'real guest installation');
  const active = { ...owner.active }, descriptors = await dataDescriptors();
  check('real guest opened publishes one private installation', opened.workspaceLease === false && ownerCreations === 1 && downloads === 1 && descriptors.length >= 4,
    { ownerState: opened.ownerState, backendState: opened.backendState, openDataDescriptors: descriptors.length });
  let result = await run(['python3', '-c', 'print(1)']); check('python print(1)', text(result.job.stdout) === '1\n', { outcome: result.job.outcome, stdout: text(result.job.stdout) });
  result = await run(['gh', '--version']); check('gh --version', /^gh version /.test(text(result.job.stdout)), { outcome: result.job.outcome, stdout: text(result.job.stdout) });
  result = await run(['python3', '-c', 'import os,json;d=os.stat("/workspace");f=os.stat("/workspace/needle.txt");print(json.dumps([os.geteuid(),os.getegid(),d.st_uid,d.st_gid,d.st_mode&511,f.st_uid,f.st_gid]))']);
  check('fresh private workspace and seed file belong to the unchanged unprivileged job UID', JSON.stringify(JSON.parse(text(result.job.stdout))) === JSON.stringify([60081,60081,60081,60081,448,60081,60081]), { observed: JSON.parse(text(result.job.stdout)) });
  await run(['python3', '-c', 'from pathlib import Path;Path("needle.txt").write_text("alpha\\nbeta needle\\n");Path("persist930.txt").write_text("same guest\\n");print("prepared")']);
  result = await run(['rg', 'needle', '/workspace/needle.txt']); check('rg private file', text(result.job.stdout) === 'beta needle\n', { outcome: result.job.outcome, stdout: text(result.job.stdout) });
  result = await run(['/bin/sh', '-c', 'set -eu; git init --bare -q /workspace/source; git clone -q --no-hardlinks /workspace/source /workspace/clone; test -d /workspace/clone/.git; git -C /workspace/clone rev-parse --is-inside-work-tree']);
  check('git clones a real empty local guest repository without creating commits', text(result.job.stdout) === 'true\n', { outcome: result.job.outcome, stdout: text(result.job.stdout), stderr: text(result.job.stderr) });
  await command('setEnabled', { enabled: true }); await waitFor(state => state.admission, 'already enabled owner');
  result = await run(['python3', '-c', 'print(open("persist930.txt").read(),end="")']);
  check('repeated enable preserves the live owner epoch target and real guest data', ownerCreations === 1 && downloads === 1 && owner.active.epoch === active.epoch && owner.active.target === active.target && text(result.job.stdout) === 'same guest\n',
    { ownerCreations, downloads, sameOpenDataDescriptors: JSON.stringify(await dataDescriptors()) === JSON.stringify(descriptors) });
  const next = (await status()).nextRequestId;
  await command('runPrivateGuest', { requestId: next, argv: ['python3', '-c', 'import time;print("cancel-started",flush=True);time.sleep(60)'], cwd: '/workspace' });
  const running = await waitFor(state => state.job?.id === next && state.job.started && text(state.job.stdout).includes('cancel-started'), 'cancel job started', 60000);
  check('cancel target actually started and has no invented outcome', running.job.outcome === null);
  const off = await command('setEnabled', { enabled: false });
  check('ordinary off acceptance closes admission without claiming native join', !off.enabled && !off.admission && off.state === 'stopping' && off.shutdownComplete === false);
  const cancelled = await waitFor(state => state.job?.id === next && state.job.state === 'settled', 'real guest cancellation', 20000);
  check('off confirms true guest cancellation and sink completion', cancelled.job.cancelRequested && cancelled.job.outcome.cancelled === true && cancelled.job.outcome.signal === 'SIGKILL', { outcome: cancelled.job.outcome });
  shutdown = await waitFor(state => state.shutdownComplete, 'ordinary off native join', 30000);
  const reopen = await request('/dsh-go/v1/linux', { v: 1, instanceId: shutdown.instanceId,
    attemptId: shutdown.attemptId, action: 'setEnabled', enabled: true }, cookie);
  const rejected = JSON.parse(reopen.text);
  observations.push({ action: 'setEnabled', enabled: true, afterOrdinaryOff: true,
    httpStatus: reopen.status, errorCode: rejected.error?.code });
  check('retired same-process owner rejects reopen and requires App restart', reopen.status === 409 &&
    rejected.error?.code === 'ERR_OHOS_LINUX_CLOSED' && rejected.status?.restartRequired && ownerCreations === 1 && downloads === 1);
  const requested = await command('shutdown');
  check('explicit shutdown after ordinary off preserves the completed retirement', requested.shutdownComplete === true &&
    JSON.stringify(requested.retirement) === JSON.stringify(shutdown.retirement));
  check('ordinary off confirms real native join and drive retirement', shutdown.retirement.resourcesRetired && shutdown.retirement.native.joined === true && shutdown.retirement.native.retirementError === false,
    { retirement: shutdown.retirement });
  const marker = JSON.parse(await readFile(join(active.directory, 'instance.json'), 'utf8'));
  check('published target remains and no native data descriptor survives', shutdown.retirement.filesRemoved === false && shutdown.retirement.dataRetained &&
    marker.target.name === 'target.ext4' && marker.persistentInstanceId === active.persistentInstanceId && marker.state === 'clean' &&
    shutdown.retirement.cleanCheckpoint && marker.guestClose.epoch === active.epoch && (await stat(active.target)).size === 536870912 && (await dataDescriptors()).length === 0);
  await assert.rejects(access(join(active.directory, 'active.json')), { code: 'ENOENT' });
  check('retired owner does not implicitly create a replacement', ownerCreations === 1 && downloads === 1 && shutdown.restartRequired && !shutdown.admission);
  await writeFile(resultPath, JSON.stringify({ passed: true, checks, observations, shutdown,
    installed: { epoch: active.epoch, directory: active.directory, target: active.target, archiveSha256: active.archiveSha256 },
    ownerCreations, downloads,
    scope: 'Actual HTTP/BrowserAuth, production LinuxControl/owner/backend, real native TinyEMU and guest. Only pinned archive download transport is a fixture. This single lifetime checks clean close; cross-process recovery is a separate paired test. No HAP/device/Huawei HTTP claim.' }, null, 2) + '\n');
} finally {
  clearTimeout(deadline); await control.shutdown(); await ctx.fiber.dispose();
  server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
}
