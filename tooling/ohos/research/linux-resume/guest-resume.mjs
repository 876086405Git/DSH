import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { readFile, readdir, readlink, stat, writeFile } from 'node:fs/promises';
import { createReadStream, openSync, writeSync, closeSync, readFileSync } from 'node:fs';
import { Readable } from 'node:stream';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { Context } from '@deepseek-ai/cordis';
import { BrowserAuth, HostConnectionService } from './actual-browser-auth.mjs';
import { LinuxControl, registerLinuxControlRoutes } from './source/runtime/ohos/linux/control.mjs';
import { LinuxInstallationOwner, loadLinuxInstallationManifest } from './source/runtime/ohos/linux/owner.mjs';
import { loadLinuxNative } from './source/runtime/ohos/linux/native-session.mjs';
import { witnessCommands, validateWitnessResult } from './guest-witness.mjs';

const [nativeLibraryDirectory, assetsDirectory, archive, directory, output, phase] = process.argv.slice(2);
assert.ok(['write', 'read'].includes(phase));
const clock = () => process.hrtime.bigint().toString();
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const files = Object.fromEntries(['guest.bin', 'host.bin', 'frames.jsonl', 'events.jsonl', 'http-responses.bin', 'http-requests.bin', 'http.jsonl']
  .map(name => [name, openSync(join(output, name), 'wx', 0o600)]));
const rawLogBudgetBytes = 64 * 1024 * 1024;
let rawLogBytesWritten = 0;
function append(fd, value) {
  const data = Buffer.isBuffer(value) ? value : Buffer.from(value);
  if (data.length > rawLogBudgetBytes - rawLogBytesWritten) throw Object.assign(new Error('Raw research evidence budget exceeded; no measurement completion is inferred'), { code: 'ERR_RESEARCH_LOG_LIMIT' });
  for (let offset = 0; offset < data.length;) {
    const written = writeSync(fd, data, offset, data.length - offset);
    if (written <= 0) throw Object.assign(new Error('Raw research evidence write made no progress'), { code: 'ERR_RESEARCH_LOG_WRITE' });
    offset += written; rawLogBytesWritten += written;
  }
}
const positions = { guest: 0, host: 0, response: 0, request: 0 }, events = [], checks = [], observations = [];
const event = (kind, fields = {}) => {
  const value = { kind, atNs: clock(), ...fields }; events.push(value);
  append(files['events.jsonl'], JSON.stringify(value) + '\n'); return value;
};
const check = (name, pass, facts = {}) => { const row = { name, pass: !!pass, ...facts }; checks.push(row); console.log(JSON.stringify(row)); assert.ok(pass, name); };
const buffers = { guest: '', host: '' };
function wire(direction, bytes) {
  if (!Buffer.isBuffer(bytes)) bytes = Buffer.from(bytes);
  const offset = positions[direction]; positions[direction] += bytes.length;
  append(files[direction + '.bin'], bytes);
  buffers[direction] += bytes.toString('utf8'); let index;
  while ((index = buffers[direction].indexOf('\n')) >= 0) {
    const line = buffers[direction].slice(0, index); buffers[direction] = buffers[direction].slice(index + 1);
    const json = direction === 'guest' ? line.startsWith('DSHG1 ') && line.slice(6) : line;
    if (!json) continue;
    let frame; try { frame = JSON.parse(json); } catch { continue; }
    append(files['frames.jsonl'], JSON.stringify({ direction, atNs: clock(), chunkOffset: offset, frame }) + '\n');
    if (direction === 'guest' && ['opened', 'closed', 'close-failed'].includes(frame.kind)) event('guest-' + frame.kind, { frame });
    if (direction === 'host' && frame.op === 'close') event('host-close', { frame });
  }
  if (buffers[direction].length > 262144) buffers[direction] = buffers[direction].slice(-262144);
}
let owner, ownerCreations = 0, downloads = 0, creates = 0, shutdown, active, witness, config, beforeCreate;
const control = new LinuxControl({ hostPaths: { directory, nativeLibraryDirectory }, assetsDirectory }, {
  async loadModule() { return { loadLinuxInstallationManifest, createLinuxInstallationOwner(options) {
    ownerCreations++;
    owner = new LinuxInstallationOwner(options, {
      download: { fetch: async () => {
        downloads++; assert.equal(phase, 'write', 'a new process resuming the retained target must not download');
        return new Response(Readable.toWeb(createReadStream(archive)), { status: 200 });
      } },
      createSession(configPath) {
        creates++; config = JSON.parse(readFileSync(configPath, 'utf8'));
        const instanceDirectory = configPath.slice(0, configPath.lastIndexOf('/'));
        beforeCreate = JSON.parse(readFileSync(join(instanceDirectory, 'instance.json'), 'utf8'));
        assert.equal(beforeCreate.state, 'booting'); assert.equal(beforeCreate.guestClose, null);
        assert.ok(config.cmdline.includes('dsh.epoch=' + beforeCreate.epoch));
        event('native-create', { beforeCreate, config });
        const raw = loadLinuxNative({ nativeLibraryDirectory }).create(configPath);
        raw.socket.on('data', bytes => wire('guest', bytes));
        const write = raw.socket.write;
        raw.socket.write = function (bytes, encoding, callback) {
          wire('host', typeof bytes === 'string' ? Buffer.from(bytes, typeof encoding === 'string' ? encoding : 'utf8') : bytes);
          return Reflect.apply(write, this, arguments);
        };
        // Observation wrappers forward the real native calls and results. No
        // closed, join, data-FD or I/O result is fabricated by this driver.
        return { socket: raw.socket,
          requestStop() { event('native-stop-request'); return raw.requestStop(); },
          async join() { event('native-join-start'); const result = await raw.join(); event('native-join-return', { result }); return result; },
        };
      },
    }); return owner;
  } }; },
});
const ctx = new Context(), routes = new Map();
ctx.provide('webServer', { host: '127.0.0.1', protocol: 'http:', register(route) {
  routes.set(route.path, route.handler); return () => routes.delete(route.path);
} });
const auth = new BrowserAuth(ctx, Buffer.alloc(32, 93), 1), connection = new HostConnectionService(ctx, [], auth);
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
    const requestBytes = body ? Buffer.from(JSON.stringify(body)) : Buffer.alloc(0);
    const requestOffset = positions.request;
    // Preserve control payload bytes only. Never persist the login URL, cookie
    // or headers; the fixed probe supplies no real account/environment secrets.
    if (path === '/dsh-go/v1/linux') { append(files['http-requests.bin'], requestBytes); positions.request += requestBytes.length; }
    const req = http.request(origin + path, { method: body ? 'POST' : 'GET', headers: {
      ...(cookie ? { cookie } : {}), ...(body ? { 'content-type': 'application/json' } : {}),
    } }, res => {
      const chunks = []; let bytes = 0;
      res.on('data', chunk => { bytes += chunk.length; if (bytes > 98304) req.destroy(new Error('bounded response exceeded')); else chunks.push(chunk); });
      res.on('error', reject); res.on('end', () => {
        const value = Buffer.concat(chunks);
        if (path === '/dsh-go/v1/linux') {
          const offset = positions.response; positions.response += value.length; append(files['http-responses.bin'], value);
          append(files['http.jsonl'], JSON.stringify({ atNs: clock(), method: body ? 'POST' : 'GET', action: body?.action ?? null,
            requestOffset, requestBytes: requestBytes.length, responseOffset: offset, responseBytes: value.length, status: res.statusCode }) + '\n');
        }
        resolve({ status: res.statusCode, headers: res.headers, text: value.toString('utf8') });
      });
    });
    req.on('error', reject); req.setTimeout(5000, () => req.destroy(new Error('HTTP read deadline is not cancellation or native completion')));
    req.end(requestBytes);
  });
}
const login = await request('/?token=' + encodeURIComponent(auth.launchToken)); assert.equal(login.status, 303);
const cookie = login.headers['set-cookie'][0].split(';')[0];
async function status() {
  const response = await request('/dsh-go/v1/linux', undefined, cookie); assert.equal(response.status, 200); return JSON.parse(response.text);
}
async function command(action, fields = {}) {
  const before = await status(), response = await request('/dsh-go/v1/linux', { v: 1, instanceId: before.instanceId, attemptId: before.attemptId, action, ...fields }, cookie);
  observations.push({ action, requestId: fields.requestId ?? null, status: response.status }); assert.equal(response.status, 202); return JSON.parse(response.text);
}
async function waitFor(predicate, label, milliseconds = 180000) {
  const deadline = Date.now() + milliseconds; let state, progress;
  while (Date.now() < deadline) {
    state = await status();
    const key = state.progress?.stage + ':' + state.progress?.step;
    if (key !== progress && state.progress) { progress = key; console.log(JSON.stringify({ progress: state.progress })); }
    if (predicate(state)) return state;
    if (['unknown', 'failed', 'unavailable'].includes(state.state)) throw Object.assign(new Error(label + ': ' + state.state), { state });
    await delay(50);
  }
  throw Object.assign(new Error(label + ' deadline; no inferred completion'), { state });
}
const bytes = output => Buffer.from(output.data, 'base64');
async function run(argv) {
  const before = await status(), id = before.nextRequestId;
  await command('runPrivateGuest', { requestId: id, argv, cwd: '/workspace', env: {}, stdin: '' });
  const value = await waitFor(state => state.job?.id === id && state.job.state === 'settled', argv[0], 60000);
  assert.equal(value.job.outcome.exitCode, 0, JSON.stringify(value.job)); assert.equal(value.job.stdout.truncated, false);
  return value.job;
}
async function descriptors() {
  const found = [];
  for (const fd of await readdir('/proc/self/fd')) {
    try { const path = await readlink('/proc/self/fd/' + fd); if (path.startsWith(directory + '/')) found.push({ fd: Number(fd), path }); } catch {}
  }
  return found.sort((a, b) => a.fd - b.fd);
}
function info(value) { return { dev: String(value.dev), ino: String(value.ino), bytes: Number(value.size), mode: Number(value.mode & 0o777n), nlink: Number(value.nlink) }; }
const deadline = setTimeout(() => { console.error('PAIRED_GUEST_DEADLINE_WITHOUT_RETIREMENT_PROOF'); process.exit(90); }, 300000);
event('process-start', { pid: process.pid, phase, execArgv: process.execArgv });
try {
  const initial = await status(); check('GET is lazy and has no selected persistent instance', initial.state === 'disabled' && initial.persistentInstanceId === null && initial.bootMode === null && ownerCreations === 0);
  const accepted = await command('setEnabled', { enabled: true }); check('202 is acceptance before native completion', !accepted.admission && !accepted.shutdownComplete);
  const opened = await waitFor(value => value.admission, phase === 'write' ? 'initial installation' : 'directboot resume');
  active = { ...owner.active };
  check('actual opened selects the expected lifecycle', opened.bootMode === (phase === 'write' ? 'install' : 'resume') && opened.persistentInstanceId === active.persistentInstanceId && creates === 1 && ownerCreations === 1 && downloads === (phase === 'write' ? 1 : 0),
    { persistentInstanceId: opened.persistentInstanceId, bootMode: opened.bootMode, epoch: active.epoch, downloads });
  check('writable target identity matches the durable pre-create record', beforeCreate.target.name === 'target.ext4' && beforeCreate.target.ino === String((await stat(active.target, { bigint: true })).ino));
  if (phase === 'read') check('resume has only the same target as writable root', Object.keys(config).filter(key => /^drive/.test(key)).join(',') === 'drive0' && config.drive0.file === active.target && config.drive0.readOnly !== true && /root=\/dev\/vda rw /.test(config.cmdline));
  let job = await run(['python3', '-c', 'print(1)']); check('real python print(1)', bytes(job.stdout).toString() === '1\n');
  job = await run(['gh', '--version']); check('real gh version', /^gh version /.test(bytes(job.stdout).toString()));
  for (const item of witnessCommands({ phase })) {
    job = await run(item.argv); witness = validateWitnessResult({ phase, stdout: bytes(job.stdout) });
    await writeFile(join(output, 'WITNESS.json'), JSON.stringify(witness, null, 2) + '\n');
  }
  check('guest witness validates actual target mount, sources, bytes and ownership', !!witness, { kernelRelease: witness.uname.release, rootMounts: witness.rootMounts, targetDevice: witness.targetDevice });
  job = await run(['rg', 'normal-close-then-new-process', '/workspace/.config/dsh931/settings.json']);
  check('real rg reads the retained configuration', bytes(job.stdout).toString().includes('normal-close-then-new-process'));
  if (phase === 'write') {
    job = await run(['/bin/sh', '-c', 'set -eu; git init --bare -q /workspace/source931; git clone -q --no-hardlinks /workspace/source931 /workspace/clone931; git -C /workspace/clone931 rev-parse --is-inside-work-tree']);
  } else job = await run(['git', '-C', '/workspace/clone931', 'rev-parse', '--is-inside-work-tree']);
  check('real local git repository survives without creating a commit', bytes(job.stdout).toString() === 'true\n');
  const requestId = (await status()).nextRequestId;
  await command('runPrivateGuest', { requestId, argv: ['python3', '-c', 'import time;print("cancel-started",flush=True);time.sleep(60)'], cwd: '/workspace' });
  await waitFor(value => value.job?.id === requestId && value.job.started && bytes(value.job.stdout).toString().includes('cancel-started'), 'cancel started', 60000);
  // Ordinary off on an opened VM is the final barrier: cancel the job, close the guest, join.
  const closeRequested = event('shutdown-command'); await command('setEnabled', { enabled: false });
  shutdown = await waitFor(value => value.shutdownComplete && value.job?.state === 'settled', 'off retires the VM', 60000);
  check('off cancels with the actual SIGKILL outcome and keeps completed output', shutdown.job.cancelRequested && shutdown.job.outcome.cancelled === true && shutdown.job.outcome.signal === 'SIGKILL', { outcome: shutdown.job.outcome });
  const before = await status(), again = await request('/dsh-go/v1/linux', { v: 1, instanceId: before.instanceId, attemptId: before.attemptId, action: 'setEnabled', enabled: true }, cookie);
  observations.push({ action: 'setEnabled', requestId: null, status: again.status });
  check('after off this process refuses on and asks for an app restart, with no second VM', shutdown.state === 'stopped' && shutdown.restartRequired === true &&
    again.status === 409 && again.text.includes('ERR_OHOS_LINUX_CLOSED') && creates === 1 && ownerCreations === 1, { status: again.status });
  const checkpoint = JSON.parse(await readFile(join(active.directory, 'instance.json'), 'utf8'));
  event('checkpoint-confirmed', { state: checkpoint.state, cleanCheckpoint: shutdown.retirement.cleanCheckpoint });
  check('fulfilled shutdown confirms sync, native retirement and committed clean', shutdown.retirement.resourcesRetired && shutdown.retirement.cleanCheckpoint && shutdown.retirement.dataRetained && !shutdown.retirement.filesRemoved &&
    shutdown.retirement.guestClose.epoch === active.epoch && shutdown.retirement.guestClose.rootfsSync === true &&
    shutdown.retirement.native.joined === true && shutdown.retirement.native.retirementError === false && [-3, -4].includes(shutdown.retirement.native.apiResult) &&
    checkpoint.state === 'clean' && checkpoint.epoch === active.epoch && checkpoint.persistentInstanceId === active.persistentInstanceId);
  const closed = events.find(value => value.kind === 'guest-closed'), stop = events.find(value => value.kind === 'native-stop-request'), joined = events.find(value => value.kind === 'native-join-return');
  check('raw closed sync precedes actual stop and join', closed?.frame.epoch === active.epoch && closed.frame.rootfsSync === true && closed.frame.syncMethod === 'syncfs' && closed.frame.syncScope === 'rootfs' &&
    BigInt(closed.atNs) <= BigInt(stop.atNs) && BigInt(stop.atNs) <= BigInt(joined.atNs));
  const held = await descriptors(); check('all native and owner data descriptors are gone before harness cleanup', held.length === 0, { descriptors: held });
  const targetInfo = info(await stat(active.target, { bigint: true })), lockInfo = info(await stat(join(directory, '.lock'), { bigint: true }));
  const oldConfig = await readFile(join(active.directory, 'guest.cfg'));
  await writeFile(join(output, 'RESULT.json'), JSON.stringify({ passed: true, phase, pid: process.pid, checks, observations, opened, shutdown, active, checkpoint, config, beforeCreate,
    targetInfo, lockInfo, guestConfigSha256: digest(oldConfig), downloads, creates, ownerCreations, dataDescriptorsBeforeCleanup: held, rawLogBudgetBytes, rawLogBytesWritten,
    shutdownMilliseconds: Number(BigInt(joined.atNs) - BigInt(closeRequested.atNs)) / 1e6,
    scope: 'Research HTTP carrier with actual locked BrowserAuth/LinuxControl/owner/backend/linked flock/native TinyEMU/guest. Only verified archive fetch is replaced; session wrappers observe and forward real calls. No App/HAP/device/Huawei HTTP/account or power-loss claim.' }, null, 2) + '\n');
} finally {
  await control.shutdown(); await ctx.fiber.dispose(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
  clearTimeout(deadline); for (const fd of Object.values(files)) closeSync(fd);
}
