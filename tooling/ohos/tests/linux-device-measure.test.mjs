import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { endpoint, cloneUrl, decodeStatus, retirementConfirmed } from '../linux-device-measure.mjs';
import { witnessCommands } from '../research/linux-resume/guest-witness.mjs';

const execute = promisify(execFile);
const script = fileURLToPath(new URL('../linux-device-measure.mjs', import.meta.url));
const TOKEN = 'fixture-launch-token-930';
const COOKIE = 'dsh-auth-fixture=fixture.session';
const GH_TOKEN = 'fixture-only-gh-secret';
const inheritedSecret = 'unrelated-parent-gh-token';
const PERSISTENT = '11111111-1111-4111-8111-111111111111';
const PROXY = { mode: 'manual', httpProxy: 'http://fixture-proxy-user:fixture-proxy-password@127.0.0.1:18765', noProxy: 'gitee.com,repo.huaweicloud.com' };
const proxyFacts = extra => ({ source: 'inherit', revision: 0, httpConfigured: false, httpsConfigured: false, ...extra });
const closeProof = epoch => ({ epoch, rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' });
const stream = (bytes = Buffer.alloc(0), total = bytes.length) => ({ encoding: 'base64', data: bytes.toString('base64'),
  totalBytes: total, retainedBytes: bytes.length, truncated: total > bytes.length });
const snapshot = extra => ({ v: 1, instanceId: 'fixture-instance', attemptId: null, state: 'disabled', enabled: false,
  admission: false, guestOpened: false, ownerRetained: false, workspaceLease: false, restartRequired: false,
  shutdownComplete: false, nextRequestId: 1, ownerState: null, backendState: null, progress: null, lastErrorCode: null,
  job: null, retirement: null, ...extra });
const retired = extra => ({ resourcesRetired: true, filesRemoved: false, dataRetained: true, ownerQuarantined: true,
  native: { joined: true, retirementError: false, apiResult: -4 }, releaseErrorCode: null, ...extra });
const reply = (res, code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };

// Guest records are synthetic; actual immutable helper argv is checked below.
function witness(phase, extra = {}) {
  const { expected } = witnessCommands({ phase })[0], device = { major: 254, minor: phase === 'write' ? 32 : 0 };
  const metadata = (path, uid, gid, mode, inode) => ({ path, uid, gid, mode, inode, bytes: 4096,
    mtimeNs: '1794135000123456789', device: { ...device } });
  const file = (name, uid, gid, inode) => ({ ...metadata(expected[name].path, uid, gid, expected[name].mode, inode),
    bytes: expected[name].bytes, sha256: expected[name].sha256 });
  return { v: 1, phase, uid: 60081, gid: 60081, pythonVersion: '3.14.10',
    uname: { system: 'Linux', nodeName: 'synthetic', release: 'fixture-kernel', version: 'fixture', machine: 'riscv64' },
    root: metadata('/', 0, 0, '0o755', 2), rootMounts: [{ source: expected.targetDevice, target: '/', type: 'ext4',
      options: ['rw', 'relatime'], raw: expected.targetDevice + ' / ext4 rw,relatime 0 0' }],
    targetDevice: { path: expected.targetDevice, isBlock: true, ...device },
    workspace: metadata('/workspace', 60081, 60081, '0o700', 100),
    configDirectory: metadata('/workspace/.config/dsh931', 60081, 60081, '0o700', 101),
    agent: file('agent', 0, 0, 200), init: file('init', 0, 0, 201),
    data: file('data', 60081, 60081, 102), config: file('config', 60081, 60081, 103), ...extra };
}

// This is deliberately a control/guest test double over real local HTTP.
// It does not invoke git, gh, a VM, SDK, external service or an account.
async function fixture(options = {}) {
  let state = snapshot({ ...(options.protocol931 ? { persistentInstanceId: null, bootMode: null,
    nativeMemoryRelease: null, proxy: proxyFacts(options.proxy) } : {}), ...options.initial }), installationPolls = 0, jobPolls = 0, shutdownPolls = 0;
  let current, lastBody, dropping = !!options.dropFirstRun, replace = false, raced = false;
  let getCount = 0, jobExit = 0, proxyBody, proxyDrops = !!options.dropFirstProxy;
  const posts = [], requests = [], effects = new Map();
  const server = createServer(async (req, res) => {
    if (req.url === '/?token=' + TOKEN) {
      requests.push({ method: req.method, kind: 'login' });
      res.writeHead(303, { 'set-cookie': COOKIE + '; Path=/; HttpOnly', location: options.redirect ?? '/' }); res.end(); return;
    }
    requests.push({ method: req.method, kind: 'control' });
    assert.equal(req.url, '/dsh-go/v1/linux'); assert.equal(req.headers.cookie, COOKIE);
    if (req.method === 'GET') {
      getCount++;
      if (options.raceBeforeProxy && getCount === 2) {
        current = 'foreign'; state.job = { id: state.nextRequestId++, state: 'running', started: true,
          cancelRequested: false, outcome: null, errorCode: null, stdout: stream(), stderr: stream() };
      }
      if (replace) { state.instanceId = 'replacement-instance'; state.attemptId = 'replacement-attempt'; }
      if (options.overlong) { res.end('X'.repeat(65537)); return; }
      if (state.state === 'installing' && ++installationPolls >= 2) {
        state.state = 'enabled'; state.admission = true; state.guestOpened = true;
        state.ownerState = 'active'; state.backendState = 'opened'; state.progress = { stage: 'opened', done: 1, total: 1, step: null };
        if (options.protocol931) { state.persistentInstanceId = options.persistentId ?? PERSISTENT;
          state.bootMode = options.bootMode ?? 'install'; state.nativeMemoryRelease = 'process-exit'; }
      } else if (options.contradictoryAdmission && state.state === 'enabled' && state.job === null) {
        state.state = 'unknown'; // A contradictory peer must not authorize a run.
      }
      if (options.raceBeforeCancel && current === 'cancel') {
        // The accepted job ended, and another client used the next ID before
        // the measurement client could send its owner-wide disable request.
        current = 'foreign';
        state.job = { id: state.nextRequestId++, state: 'running', started: true, cancelRequested: false,
          outcome: null, errorCode: null, stdout: stream(), stderr: stream() };
      }
      if (state.job?.state === 'running' && current !== 'cancel' && current !== 'foreign' && ++jobPolls >= 2) {
        state.job.state = 'settled'; state.job.outcome = { exitCode: jobExit, signal: null, cancelled: false };
      }
      if (state.state === 'disabling') {
        state.state = 'disabled'; state.job.state = 'settled';
        state.job.outcome = { exitCode: null, signal: 'SIGKILL', cancelled: true, requestedSignal: 'SIGTERM' };
      }
      if (options.ordinaryOffFinal && state.state === 'stopping' && state.job?.cancelRequested && state.job.state === 'running') {
        state.job.state = 'settled';
        state.job.outcome = { exitCode: null, signal: 'SIGKILL', cancelled: true, requestedSignal: 'SIGTERM' };
      }
      if (state.state === 'stopping' && ++shutdownPolls >= 2) {
        state.state = state.job?.state === 'unknown' ? 'unknown' : 'stopped';
        state.shutdownComplete = !options.noJoin;
        if (options.ordinaryOffFinal) { state.guestOpened = false; state.backendState = 'closed'; state.restartRequired = true; }
        state.retirement = options.noJoin ? retired({ resourcesRetired: false,
          native: { joined: false, retirementError: null, apiResult: null } }) : retired();
        if (options.protocol931) { state.retirement.guestClose = closeProof(options.sameEpoch ? 'a'.repeat(64) : (options.bootMode === 'resume' ? 'b' : 'a').repeat(64));
          state.retirement.cleanCheckpoint = !options.noClean && !options.noJoin; }
      }
      reply(res, 200, state); return;
    }
    const chunks = []; for await (const bytes of req) chunks.push(bytes);
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8')); posts.push(body);
    if (body.instanceId !== state.instanceId || body.attemptId !== state.attemptId) {
      reply(res, 409, { v: 1, error: { code: 'ERR_OHOS_LINUX_STALE' }, status: state }); return;
    }
    if (body.action === 'setProxy') {
      assert.ok(options.protocol931); assert.deepEqual(Object.keys(body).sort(), ['action', 'attemptId', 'instanceId', 'proxy', 'v']);
      const serialized = JSON.stringify(body.proxy);
      if (serialized !== proxyBody) { proxyBody = serialized; state.proxy = proxyFacts({ source: body.proxy.mode,
        revision: state.proxy.revision + 1, httpConfigured: body.proxy.mode === 'manual' && !!body.proxy.httpProxy,
        httpsConfigured: body.proxy.mode === 'manual' && !!(body.proxy.httpsProxy || body.proxy.httpProxy) }); }
      if (proxyDrops) { proxyDrops = false; res.destroy(); return; }
    } else if (body.action === 'setEnabled') {
      state.enabled = body.enabled; state.admission = false;
      if (body.enabled) {
        state.attemptId ??= 'fixture-attempt'; state.state = 'installing'; state.ownerRetained = true;
        state.progress = { stage: 'download', done: 0, total: 100, step: null };
      } else { state.state = options.ordinaryOffFinal ? 'stopping' : 'disabling'; if (state.job) state.job.cancelRequested = true; }
    } else if (body.action === 'runPrivateGuest') {
      if (options.raceOnFirstRun && !raced) {
        raced = true; current = 'foreign'; state.nextRequestId++;
        state.job = { id: body.requestId, state: 'running', started: true, cancelRequested: false, outcome: null,
          errorCode: null, stdout: stream(), stderr: stream() };
        reply(res, 409, { v: 1, error: { code: 'ERR_OHOS_LINUX_REQUEST_REUSED' }, status: state }); return;
      }
      if (body.requestId === state.job?.id) {
        assert.equal(JSON.stringify(body), lastBody, 'the client must retry exactly the same request');
        reply(res, 202, state); return;
      }
      assert.equal(body.requestId, state.nextRequestId); assert.equal(body.cwd, '/workspace');
      assert.equal(body.env.GH_TOKEN, body.argv[0] === 'gh' && body.argv[1] === 'pr' ? GH_TOKEN : undefined);
      lastBody = JSON.stringify(body); effects.set(body.requestId, (effects.get(body.requestId) ?? 0) + 1);
      state.nextRequestId++; jobPolls = 0; jobExit = 0; current = 'normal'; let stdout = '', stderr = '';
      if (options.proxyBecomesDirect && state.nextRequestId > 2) state.proxy = proxyFacts({ source: 'direct', revision: 2 });
      if (body.argv[0] === 'gh' && body.argv[1] === '--version') stdout = 'gh version 2.97.0 (2026-10-14)\n';
      else if (body.argv[0] === 'python3' && ['write', 'read'].includes(body.argv[3])) {
        const phase = body.argv[3]; assert.deepEqual(body.argv, [...witnessCommands({ phase })[0].argv]);
        assert.match(body.argv[2], /os\.O_EXCL/); assert.match(body.argv[2], /os\.O_NOFOLLOW/);
        if (options.witnessExists && phase === 'write') { jobExit = 1; stderr = 'FileExistsError: fixed witness already exists\n'; }
        else { const record = witness(phase, options.witnessExtra); if (options.corruptWitness) record.data.inode++;
          stdout = JSON.stringify(record) + '\n'; }
      } else if (body.argv[0] === 'python3' && body.argv[1] === '--version') stdout = 'Python 3.14.10\n';
      else if (body.argv[0] === 'python3' && body.argv.includes('print(1)')) stdout = '1\n';
      else if (body.argv[0] === 'rg' && body.argv[1] === '--version') stdout = 'ripgrep 15.1.0\n';
      else if (body.argv[0] === 'rg') { assert.equal(body.stdin, 'alpha\nbeta needle\n'); stdout = '2:beta needle\n'; }
      else if (body.argv[0] === 'git' && body.argv[1] === '--version') stdout = 'git version 2.54.0\n';
      else if (body.argv[0] === 'sh') {
        assert.doesNotMatch(body.argv[2], /\b(?:commit|commit-tree|push)\b/);
        assert.match(body.argv[2], /git init --bare/); stdout = 'DSH_EMPTY_CLONE_OK\n';
      } else if (body.argv[0] === 'git' && body.argv[1] === 'clone') {
        assert.equal(body.argv[body.argv.indexOf('--') + 1], 'https://example.invalid/small.git');
        stdout = '';
      } else if (body.argv[0] === 'git' && body.argv.includes('rev-parse')) stdout = 'a'.repeat(40) + '\n';
      else if (body.argv[0] === 'gh' && body.argv[1] === 'pr') {
        assert.equal(body.argv[body.argv.indexOf('--repo') + 1], 'fixture-owner/fixture-repo'); stdout = '[]\n';
      } else if (body.argv[0] === 'python3' && body.argv[1] === '-u') { current = 'cancel'; stdout = 'DSH_CANCEL_READY\n'; }
      else throw new Error('unrecognized fixture request');
      state.job = { id: body.requestId, state: 'running', started: true, cancelRequested: false, outcome: null,
        errorCode: null, stdout: stream(Buffer.from(stdout)), stderr: stream(Buffer.from(options.echoProxy ? PROXY.httpProxy : stderr)) };
      if (options.binaryTailOnGh && body.argv[0] === 'gh' && body.argv[1] === '--version') state.job.stderr = stream(options.binaryTailOnGh, 1000);
      if (options.protocol931) { state.job.diagnostic = null; state.job.proxyRevision = state.proxy.revision; }
      if (options.unknownOnPython && body.argv.includes('print(1)')) {
        state.state = 'unknown'; state.admission = false; state.backendState = 'quarantined';
        state.job.state = 'unknown'; state.job.errorCode = 'ERR_OHOS_LINUX_UNKNOWN';
      }
      if (dropping) { dropping = false; replace = !!options.replaceAfterDrop; res.destroy(); return; }
    } else if (body.action === 'shutdown') {
      if (!options.ordinaryOffFinal || !state.shutdownComplete) state.state = 'stopping';
      state.enabled = false; state.admission = false;
    } else throw new Error('unexpected action');
    reply(res, 202, state);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  return { url: `http://127.0.0.1:${server.address().port}`, posts, requests, effects,
    close: async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); } };
}

async function run(fixture, extra = [], environment = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'linux-device-measure-'));
  const token = path.join(root, 'token'); await fs.writeFile(token, TOKEN + '\n', { mode: 0o600 });
  const env = path.join(root, 'guest-env.json'); await fs.writeFile(env, JSON.stringify({ GH_TOKEN }), { mode: 0o600 });
  const proxy = path.join(root, 'private-proxy-input.json'); await fs.writeFile(proxy, JSON.stringify(PROXY), { mode: 0o600 });
  const out = path.join(root, 'result');
  const args = [script, '--base-url', fixture.url, '--token-file', token, '--out', out, '--poll-ms', '10',
    '--request-timeout-ms', '250', '--install-timeout-ms', '500', '--job-timeout-ms', '500', '--shutdown-timeout-ms', '120',
    ...extra.map(value => value === '@ENV@' ? env : value === '@PROXY@' ? proxy : value)];
  let result;
  try { result = { code: 0, ...await execute(process.execPath, args, { env: { ...process.env, GH_TOKEN: inheritedSecret, ...environment }, timeout: 10000 }) }; }
  catch (error) { result = { code: error.code, stdout: error.stdout, stderr: error.stderr }; }
  let summary = null;
  try { summary = JSON.parse(await fs.readFile(path.join(out, 'SUMMARY.json'), 'utf8')); } catch { /* rejected arguments create no result directory */ }
  return { ...result, root, out, summary, proxyFile: proxy, cleanup: () => fs.rm(root, { recursive: true, force: true }) };
}

async function files(directory) {
  const result = [];
  for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
    const name = path.join(directory, entry.name);
    if (entry.isDirectory()) result.push(...await files(name)); else result.push(name);
  }
  return result;
}

test('only exact loopback control URLs and credential-free HTTPS clone URLs are accepted', () => {
  assert.equal(endpoint('http://127.0.0.1:12345/').port, 12345);
  for (const value of ['https://127.0.0.1:80', 'http://localhost:80', 'http://127.0.0.1:0', 'http://127.0.0.1:65536',
    'http://127.0.0.1:80/path', 'http://127.0.0.1:80?token=x', 'http://u@127.0.0.1:80', 'http://2130706433:80']) {
    assert.throws(() => endpoint(value), { code: 'ERR_MEASURE_ENDPOINT' });
  }
  assert.equal(cloneUrl('https://example.invalid/repo.git'), 'https://example.invalid/repo.git');
  for (const value of ['http://example.invalid/repo', 'file:///repo', 'https://u:p@example.invalid/repo',
    'https://@example.invalid/repo', 'https://example.invalid/repo?x=y', 'https://example.invalid/repo?', 'https://example.invalid/repo#',
    'https://example.invalid/a\n']) assert.throws(() => cloneUrl(value), { code: 'ERR_MEASURE_CLONE_URL' });
});

test('real CLI/HTTP retries the same job identity and keeps credentials out of evidence', async () => {
  const server = await fixture({ dropFirstRun: true }); let result;
  try {
    result = await run(server, ['--gh-pr-list', '--gh-repo', 'fixture-owner/fixture-repo', '--env-file', '@ENV@',
      '--clone-url', 'https://example.invalid/small.git']);
    assert.equal(result.code, 0, result.stderr + result.stdout); assert.equal(result.summary.status, 'PASS_SCOPED');
    assert.equal(result.summary.shutdownConfirmed, true); assert.ok(result.summary.cases.every(row => row.status === 'PASS'));
    const runs = server.posts.filter(row => row.action === 'runPrivateGuest');
    assert.equal(runs[0].requestId, runs[1].requestId); assert.deepEqual(runs[0], runs[1]);
    assert.ok([...server.effects.values()].every(count => count === 1));
    assert.equal(server.posts.filter(row => row.action === 'shutdown').length, 1);
    assert.equal(result.summary.finalStatus.retirement.filesRemoved, false);
    assert.equal(result.summary.finalStatus.retirement.dataRetained, true);
    assert.equal(result.summary.cancellation.cancelRequested, true);
    const eventLines = (await fs.readFile(path.join(result.out, 'events.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
    assert.ok(eventLines.some(row => row.kind === 'run-unconfirmed'));
    assert.ok(eventLines.some(row => row.kind === 'status' && row.status.progress?.stage === 'download'));
    for (const file of await files(result.out)) {
      const text = (await fs.readFile(file)).toString('utf8');
      for (const secret of [TOKEN, COOKIE, GH_TOKEN, inheritedSecret]) assert.ok(!text.includes(secret), path.basename(file));
      assert.equal((await fs.stat(file)).mode & 0o777, 0o600);
    }
    for (const secret of [TOKEN, COOKIE, GH_TOKEN, inheritedSecret]) assert.ok(!(result.stdout + result.stderr).includes(secret));
  } finally { await server.close(); await result?.cleanup(); }
});

test('default suite does no account or remote clone request and declares its local scope', async () => {
  const server = await fixture(); let result;
  try {
    result = await run(server, ['--env-file', '@ENV@']);
    assert.equal(result.code, 0, result.stdout + result.stderr); assert.equal(result.summary.status, 'PASS_LOCAL_ONLY');
    assert.equal(result.summary.cases.find(row => row.label === 'gh-pr-list').status, 'NOT_RUN');
    assert.equal(result.summary.cases.find(row => row.label === 'git-remote-clone').status, 'NOT_RUN');
    assert.ok(!server.posts.some(row => row.argv?.[0] === 'gh' && row.argv[1] === 'pr'));
    assert.ok(!server.posts.some(row => row.argv?.[0] === 'git' && row.argv[1] === 'clone'));
  } finally { await server.close(); await result?.cleanup(); }
});

test('a confirmed job stores exact non-UTF8 binary tails and never follows redirects or inherited proxies', async () => {
  const binary = Buffer.from([0, 255, 254, 65]); let trapCalls = 0;
  const trap = createServer((_req, res) => { trapCalls++; res.end(); }); trap.listen(0, '127.0.0.1'); await once(trap, 'listening');
  const foreign = `http://127.0.0.1:${trap.address().port}`;
  const server = await fixture({ redirect: foreign + '/unexpected', binaryTailOnGh: binary }); let result;
  try {
    result = await run(server, [], { HTTP_PROXY: foreign, HTTPS_PROXY: foreign, ALL_PROXY: foreign, NODE_USE_ENV_PROXY: '1' });
    assert.equal(result.code, 0, result.stdout + result.stderr); assert.equal(result.summary.status, 'PASS_LOCAL_ONLY');
    assert.equal(result.summary.cases[0].accepted, true); assert.equal(trapCalls, 0);
    assert.equal(result.summary.outputWithheld, false);
    const tail = result.summary.cases[0].stderr;
    assert.deepEqual(await fs.readFile(path.join(result.out, tail.file)), binary);
    assert.equal(tail.startOffset, 996); assert.equal(tail.truncated, true); assert.equal(tail.totalBytes, 1000);
  } finally { await server.close(); trap.closeAllConnections(); await new Promise(resolve => trap.close(resolve)); await result?.cleanup(); }
});

test('UNKNOWN and unconfirmed native retirement remain unresolved, never exit-code-zero success', async () => {
  const server = await fixture({ unknownOnPython: true, noJoin: true }); let result;
  try {
    result = await run(server);
    assert.equal(result.code, 2); assert.equal(result.summary.status, 'UNKNOWN');
    assert.equal(result.summary.shutdownConfirmed, false); assert.equal(result.summary.finalStatus.job.outcome, null);
    assert.equal(result.summary.finalStatus.retirement.native.joined, false);
    assert.ok(!server.posts.some(row => row.argv?.[0] === 'rg'));
  } finally { await server.close(); await result?.cleanup(); }
});

test('a changed runtime identity never receives a retried run or shutdown for the previous instance', async () => {
  const server = await fixture({ dropFirstRun: true, replaceAfterDrop: true }); let result;
  try {
    result = await run(server);
    assert.equal(result.code, 2); assert.equal(result.summary.shutdownConfirmed, false);
    assert.equal(server.posts.filter(row => row.action === 'runPrivateGuest').length, 1);
    assert.equal(server.posts.filter(row => row.action === 'shutdown').length, 0);
    assert.ok(result.summary.errors.some(row => row.code === 'ERR_MEASURE_STALE'));
  } finally { await server.close(); await result?.cleanup(); }
});

test('an existing active job is observed and preserved without taking over or shutting it down', async () => {
  const server = await fixture({ initial: { state: 'enabled', enabled: true, admission: true, guestOpened: true,
    attemptId: 'fixture-attempt', nextRequestId: 2, job: { id: 1, state: 'unknown', started: true, cancelRequested: false,
      outcome: null, errorCode: 'ERR_OHOS_LINUX_UNKNOWN', stdout: stream(), stderr: stream() } } }); let result;
  try {
    result = await run(server);
    assert.equal(result.code, 2); assert.equal(server.posts.length, 0);
    assert.equal(result.summary.outputWithheld, true);
    assert.ok(result.summary.errors.some(row => row.code === 'ERR_MEASURE_EXISTING_JOB'));
  } finally { await server.close(); await result?.cleanup(); }
});

test('a second client winning the ID after initial GET is not stopped by this client cleanup', async () => {
  const server = await fixture({ raceOnFirstRun: true }); let result;
  try {
    result = await run(server);
    assert.equal(result.code, 2);
    assert.equal(server.posts.filter(row => row.action === 'runPrivateGuest').length, 1);
    assert.equal(server.posts.filter(row => row.action === 'shutdown').length, 0);
    assert.ok(!server.posts.some(row => row.action === 'setEnabled' && row.enabled === false));
    assert.equal(result.summary.shutdownStatus, 'UNCONFIRMED_FOREIGN_JOB');
    assert.equal(result.summary.shutdownConfirmed, false);
    assert.equal(result.summary.finalStatus.job.state, 'running');
    assert.equal(result.summary.outputWithheld, true); assert.equal(result.summary.finalStatus.job.stdout.outputWithheld, true);
  } finally { await server.close(); await result?.cleanup(); }
});

test('a different observed job before cancellation receives neither off nor shutdown', async () => {
  const server = await fixture({ raceBeforeCancel: true }); let result;
  try {
    result = await run(server);
    assert.equal(result.code, 2);
    assert.equal(server.posts.filter(row => row.action === 'shutdown').length, 0);
    assert.ok(!server.posts.some(row => row.action === 'setEnabled' && row.enabled === false));
    assert.equal(result.summary.shutdownStatus, 'UNCONFIRMED_FOREIGN_JOB');
    assert.equal(result.summary.cases.at(-1).cancellationRequestedByClient, false);
    assert.equal(result.summary.finalStatus.job.state, 'running');
    assert.equal(result.summary.outputWithheld, true); assert.equal(result.summary.finalStatus.job.stdout.outputWithheld, true);
  } finally { await server.close(); await result?.cleanup(); }
});

test('an unknown state with contradictory admission true does not authorize any run', async () => {
  const server = await fixture({ contradictoryAdmission: true }); let result;
  try {
    result = await run(server);
    assert.equal(result.code, 2);
    assert.equal(server.posts.filter(row => row.action === 'runPrivateGuest').length, 0);
    assert.ok(result.summary.errors.some(row => row.code === 'ERR_MEASURE_ADMISSION'));
  } finally { await server.close(); await result?.cleanup(); }
});

test('retirement projection requires actual joined true and error false; raw output decoding is strict', () => {
  const valid = snapshot({ shutdownComplete: true, retirement: retired() }); assert.equal(retirementConfirmed(decodeStatus(valid)), true);
  for (const native of [{ joined: false, retirementError: false, apiResult: 0 }, { joined: true, retirementError: null, apiResult: null },
    { joined: true, retirementError: true, apiResult: -8 }]) assert.equal(retirementConfirmed(decodeStatus(snapshot({ shutdownComplete: true, retirement: retired({ native }) }))), false);
  const invalid = snapshot({ job: { id: 1, state: 'settled', started: true, cancelRequested: false,
    outcome: { exitCode: 0, signal: null, cancelled: false }, errorCode: null,
    stdout: { encoding: 'base64', data: '/w=', totalBytes: 1, retainedBytes: 1, truncated: false }, stderr: stream() } });
  assert.throws(() => decodeStatus(invalid), { code: 'ERR_MEASURE_OUTPUT_PROTOCOL' });
});

test('PR opt-in without an explicit repo/env and overlong responses fail without further operations', async () => {
  const server = await fixture({ overlong: true }); let missing, oversized;
  try {
    missing = await run(server, ['--gh-pr-list']);
    assert.equal(missing.code, 2); assert.equal(server.requests.length, 0);
    oversized = await run(server, ['--observe-only']);
    assert.equal(oversized.code, 2); assert.equal(server.posts.length, 0);
    assert.ok(oversized.summary.errors.some(row => row.code === 'ERR_MEASURE_RESPONSE_LIMIT'));
  } finally { await server.close(); await missing?.cleanup(); await oversized?.cleanup(); }
});

test('931 decoder preserves clean, memory, proxy and fixed diagnostic facts without arbitrary text', () => {
  const value = snapshot({ state: 'stopped', shutdownComplete: true, persistentInstanceId: PERSISTENT, bootMode: 'install',
    nativeMemoryRelease: 'process-exit', proxy: proxyFacts({ source: 'manual', revision: 2, httpConfigured: true, httpsConfigured: true }),
    retirement: retired({ guestClose: closeProof('a'.repeat(64)), cleanCheckpoint: true }),
    job: { id: 1, state: 'settled', started: true, cancelRequested: false, proxyRevision: 1,
      outcome: { exitCode: 128, signal: null, cancelled: false }, errorCode: null, stdout: stream(), stderr: stream(),
      diagnostic: { category: 'tls-interrupted', evidence: 'stderr', message: PROXY.httpProxy } } });
  const decoded = decodeStatus(value);
  assert.equal(decoded.persistentInstanceId, PERSISTENT); assert.equal(decoded.bootMode, 'install');
  assert.equal(decoded.nativeMemoryRelease, 'process-exit'); assert.equal(decoded.retirement.cleanCheckpoint, true);
  assert.deepEqual(decoded.retirement.guestClose, closeProof('a'.repeat(64)));
  assert.deepEqual(decoded.proxy, value.proxy); assert.equal(decoded.job.proxyRevision, 1);
  assert.match(decoded.job.diagnostic.message, /TLS.*中途断开/); assert.ok(!JSON.stringify(decoded).includes(PROXY.httpProxy));
  for (const mutate of [
    row => { row.bootMode = null; }, row => { row.retirement.guestClose.rootfsSync = false; },
    row => { row.retirement.native.joined = false; }, row => { row.nativeMemoryRelease = 'freed'; },
    row => { row.proxy.httpProxy = PROXY.httpProxy; }, row => { row.job.proxyRevision = null; }, row => { row.job.outcome.cancelled = true; },
    row => { row.job.state = 'unknown'; row.job.outcome = null; },
  ]) { const copy = structuredClone(value); mutate(copy); assert.throws(() => decodeStatus(copy)); }
  const legacy = decodeStatus(snapshot()); assert.equal(legacy.persistentInstanceId, null);
  assert.equal(legacy.nativeMemoryRelease, null); assert.equal(legacy.proxy, null);
});

test('931 decoder rejects explicit null and contradictory proxy configuration facts', () => {
  for (const proxy of [null, proxyFacts({ source: 'direct', httpConfigured: true }),
    proxyFacts({ source: 'direct', httpsConfigured: true }), proxyFacts({ source: 'manual' })]) {
    assert.throws(() => decodeStatus(snapshot({ proxy })), { code: 'ERR_MEASURE_PROXY_PROTOCOL' });
  }
});

test('explicit proxy retries idempotently and withholds all output without saving its configuration', async () => {
  const server = await fixture({ protocol931: true, dropFirstProxy: true, echoProxy: true }); let result;
  try {
    result = await run(server, ['--proxy-file', '@PROXY@']);
    assert.equal(result.code, 0, result.stdout + result.stderr);
    const settings = server.posts.filter(row => row.action === 'setProxy'); assert.equal(settings.length, 2);
    assert.deepEqual(settings[0], settings[1]); assert.deepEqual(settings[0].proxy, PROXY);
    assert.equal(result.summary.finalStatus.proxy.revision, 1); assert.equal(result.summary.outputWithheld, true);
    assert.equal(result.summary.finalStatus.job.stdout.outputWithheld, true);
    assert.equal(result.summary.finalStatus.job.stdout.reason, 'OUTPUT_OMITTED_PRIVACY');
    assert.equal(result.summary.cases[0].stdout.outputWithheld, true);
    for (const file of await files(result.out)) {
      assert.ok(!file.endsWith('.bin')); const text = (await fs.readFile(file)).toString('utf8');
      for (const value of [PROXY.httpProxy, PROXY.noProxy, 'fixture-proxy-user', 'fixture-proxy-password', result.proxyFile]) assert.ok(!text.includes(value));
    }
    for (const tail of [result.summary.finalStatus.job.stdout, result.summary.finalStatus.job.stderr, result.summary.cases[0].stdout]) {
      for (const key of ['file', 'sha256', 'bytes', 'data']) assert.equal(Object.hasOwn(tail, key), false);
    }
  } finally { await server.close(); await result?.cleanup(); }
});

test('observed proxy configuration makes privacy sticky after switching to direct', async () => {
  const server = await fixture({ protocol931: true, proxy: { source: 'manual', revision: 1, httpConfigured: true, httpsConfigured: true }, proxyBecomesDirect: true }); let result;
  try {
    result = await run(server); assert.equal(result.code, 0, result.stdout + result.stderr);
    assert.equal(result.summary.finalStatus.proxy.source, 'direct'); assert.equal(result.summary.outputWithheld, true);
    assert.ok((await files(result.out)).every(file => !file.endsWith('.bin')));
    assert.ok(result.summary.cases.filter(row => row.accepted).every(row => row.stdout.outputWithheld));
  } finally { await server.close(); await result?.cleanup(); }
});

test('a historical proxy job is never archived after the current setting has switched to direct', async () => {
  for (const extra of [[], ['--observe-only']]) {
    const server = await fixture({ protocol931: true, proxy: { source: 'direct', revision: 2 },
      initial: { state: 'enabled', enabled: true, admission: true, guestOpened: true, ownerRetained: true,
        ownerState: 'active', backendState: 'opened', attemptId: 'fixture-attempt', nextRequestId: 2,
        persistentInstanceId: PERSISTENT, bootMode: 'install', nativeMemoryRelease: 'process-exit',
        job: { id: 1, state: 'settled', started: true, cancelRequested: false, proxyRevision: 1, diagnostic: null,
          outcome: { exitCode: 128, signal: null, cancelled: false }, errorCode: null,
          stdout: stream(Buffer.from(PROXY.httpProxy)), stderr: stream(Buffer.from('fixture-proxy-password')) } } });
    let result;
    try {
      result = await run(server, extra); assert.equal(result.code, 0, result.stdout + result.stderr);
      if (extra.length) { assert.equal(result.summary.status, 'OBSERVED_ONLY'); assert.equal(server.posts.length, 0); }
      const entries = await files(result.out);
      assert.deepEqual(entries.filter(file => file.endsWith('.bin')), []);
      assert.equal(result.summary.outputWithheld, true);
      for (const file of entries) {
        const text = await fs.readFile(file, 'utf8');
        assert.ok(!text.includes(PROXY.httpProxy)); assert.ok(!text.includes('fixture-proxy-password'));
      }
      const statuses = (await fs.readFile(path.join(result.out, 'events.jsonl'), 'utf8')).trim().split('\n')
        .map(line => JSON.parse(line)).filter(row => row.kind === 'status' && row.status?.job);
      assert.ok(statuses.length > 0);
      for (const row of statuses) for (const stream of ['stdout', 'stderr']) {
        const tail = row.status.job[stream]; assert.equal(tail.outputWithheld, true);
        for (const key of ['file', 'sha256', 'bytes', 'data']) assert.equal(Object.hasOwn(tail, key), false);
      }
    } finally { await server.close(); await result?.cleanup(); }
  }
});

test('a GET-observed job before same-body 202 confirmation activates permanent privacy', async () => {
  const server = await fixture({ dropFirstRun: true }); let result;
  try {
    result = await run(server); assert.equal(result.code, 0, result.stdout + result.stderr);
    const runs = server.posts.filter(row => row.action === 'runPrivateGuest');
    assert.deepEqual(runs[0], runs[1]); assert.ok([...server.effects.values()].every(count => count === 1));
    assert.equal(result.summary.outputWithheld, true);
    assert.ok(result.summary.cases.filter(row => row.accepted).every(row => row.stdout.outputWithheld));
    assert.ok((await files(result.out)).every(file => !file.endsWith('.bin')));
  } finally { await server.close(); await result?.cleanup(); }
});

test('an env file activates privacy even when it does not opt in to account operations', async () => {
  const server = await fixture(); let result;
  try {
    result = await run(server, ['--env-file', '@ENV@']); assert.equal(result.code, 0, result.stdout + result.stderr);
    assert.equal(result.summary.status, 'PASS_LOCAL_ONLY'); assert.equal(result.summary.outputWithheld, true);
    assert.ok((await files(result.out)).every(file => !file.endsWith('.bin')));
  } finally { await server.close(); await result?.cleanup(); }
});

test('another observed job before setProxy receives neither a setting change nor shutdown', async () => {
  const server = await fixture({ protocol931: true, raceBeforeProxy: true, initial: { state: 'enabled', enabled: true,
    admission: true, guestOpened: true, attemptId: 'fixture-attempt', ownerState: 'active', backendState: 'opened' } }); let result;
  try {
    result = await run(server, ['--proxy-file', '@PROXY@']); assert.equal(result.code, 2);
    assert.equal(server.posts.length, 0); assert.equal(result.summary.shutdownConfirmed, false);
    assert.ok(result.summary.errors.some(row => row.code === 'ERR_MEASURE_FOREIGN_JOB'));
  } finally { await server.close(); await result?.cleanup(); }
});

test('two CLI processes verify fresh install write, new App resume read and both clean checkpoints', async () => {
  const first = await fixture({ protocol931: true, witnessExtra: { unrecognizedSecret: 'fixture-extra-not-for-summary' } });
  const second = await fixture({ protocol931: true, bootMode: 'resume', initial: { instanceId: 'second-app-instance' } }); let write, read;
  try {
    write = await run(first, ['--write-witness', '--proxy-file', '@PROXY@']);
    assert.equal(write.code, 0, write.stdout + write.stderr); assert.equal(write.summary.witness.phase, 'write');
    assert.equal(write.summary.witnessCleanCheckpoint, true); assert.equal(write.summary.finalStatus.retirement.cleanCheckpoint, true);
    assert.equal(write.summary.witness.unrecognizedSecret, undefined); assert.equal(write.summary.outputWithheld, true);
    read = await run(second, ['--resume-from', path.join(write.out, 'SUMMARY.json')]);
    assert.equal(read.code, 0, read.stdout + read.stderr); assert.equal(read.summary.witness.phase, 'read');
    assert.equal(read.summary.resumeConfirmed, true); assert.equal(read.summary.witnessComparison.fileIdentityPreserved, true);
    assert.equal(read.summary.finalStatus.persistentInstanceId, write.summary.finalStatus.persistentInstanceId);
    assert.notEqual(read.summary.instanceId, write.summary.instanceId);
    const firstWitness = first.posts.filter(row => row.argv?.[3] === 'write'); assert.equal(firstWitness.length, 1);
    const secondWitness = second.posts.filter(row => ['write', 'read'].includes(row.argv?.[3]));
    assert.equal(secondWitness.length, 1); assert.equal(secondWitness[0].argv[3], 'read');
  } finally { await first.close(); await second.close(); await write?.cleanup(); await read?.cleanup(); }
});

test('a prior summary without committed clean never starts a new control operation', async () => {
  const first = await fixture({ protocol931: true, noClean: true }); const second = await fixture({ protocol931: true, bootMode: 'resume' }); let write, read;
  try {
    write = await run(first, ['--write-witness']); assert.equal(write.code, 2); assert.equal(write.summary.witnessCleanCheckpoint, false);
    read = await run(second, ['--resume-from', path.join(write.out, 'SUMMARY.json')]);
    assert.equal(read.code, 2); assert.equal(second.requests.length, 0);
    assert.ok(read.summary.errors.some(row => row.code === 'ERR_MEASURE_RESUME_INPUT'));
  } finally { await first.close(); await second.close(); await write?.cleanup(); await read?.cleanup(); }
});

test('resume requires a new instance and the same persistent UUID before any witness command', async () => {
  const first = await fixture({ protocol931: true }); let write; const others = [], results = [];
  try {
    write = await run(first, ['--write-witness']); assert.equal(write.code, 0, write.stdout + write.stderr);
    for (const options of [
      { initial: { instanceId: 'fixture-instance' } },
      { initial: { instanceId: 'third-app-instance' }, persistentId: '22222222-2222-4222-8222-222222222222' },
      { initial: { instanceId: 'fourth-app-instance' }, bootMode: 'install' },
    ]) {
      const peer = await fixture({ protocol931: true, bootMode: 'resume', ...options }); others.push(peer);
      const result = await run(peer, ['--resume-from', path.join(write.out, 'SUMMARY.json')]); results.push(result);
      assert.equal(result.code, 2); assert.ok(!peer.posts.some(row => row.argv));
      assert.ok(result.summary.errors.some(row => row.code === 'ERR_MEASURE_RESUME_IDENTITY'));
    }
  } finally { await first.close(); for (const peer of others) await peer.close(); await write?.cleanup(); for (const result of results) await result.cleanup(); }
});

test('a changed persistence record or reused close epoch cannot produce resumeConfirmed', async () => {
  const first = await fixture({ protocol931: true }); let write; const others = [], results = [];
  try {
    write = await run(first, ['--write-witness']); assert.equal(write.code, 0, write.stdout + write.stderr);
    for (const options of [{ corruptWitness: true }, { sameEpoch: true }]) {
      const peer = await fixture({ protocol931: true, bootMode: 'resume', initial: { instanceId: 'another-app-instance' }, ...options }); others.push(peer);
      const result = await run(peer, ['--resume-from', path.join(write.out, 'SUMMARY.json')]); results.push(result);
      assert.equal(result.code, 2); assert.notEqual(result.summary.resumeConfirmed, true);
      assert.ok(!peer.posts.some(row => row.argv?.[3] === 'write'));
    }
  } finally { await first.close(); for (const peer of others) await peer.close(); await write?.cleanup(); for (const result of results) await result.cleanup(); }
});

test('exclusive fixed witness creation is not retried or overwritten after FileExistsError', async () => {
  const server = await fixture({ protocol931: true, witnessExists: true }); let result;
  try {
    result = await run(server, ['--write-witness']); assert.equal(result.code, 2);
    assert.equal(server.posts.filter(row => row.argv?.[3] === 'write').length, 1);
    assert.equal(result.summary.witness, undefined); assert.equal(result.summary.witnessCleanCheckpoint, false);
    assert.ok(result.summary.errors.some(row => row.code === 'ERR_MEASURE_WITNESS_FAILED'));
  } finally { await server.close(); await result?.cleanup(); }
});

test('observation and mutually exclusive witness options reject all mutations before HTTP', async () => {
  const server = await fixture({ protocol931: true }); const results = [];
  try {
    for (const args of [['--observe-only', '--proxy-file', '@PROXY@'], ['--observe-only', '--write-witness'],
      ['--observe-only', '--resume-from', '/absent'], ['--write-witness', '--resume-from', '/absent']]) {
      const result = await run(server, args); results.push(result); assert.equal(result.code, 2); assert.equal(result.summary, null);
    }
    assert.equal(server.requests.length, 0);
  } finally { await server.close(); for (const result of results) await result.cleanup(); }
});


for (const noJoin of [false, true]) {
  test(`ordinary off with final-retirement status keeps join admission strict: noJoin=${noJoin}`, async t => {
    const server = await fixture({ ordinaryOffFinal: true, noJoin }); let result;
    try {
      result = await run(server);
      const observed = { code: result.code, summary: result.summary,
        scope: 'Real CLI and local HTTP; explicit control/guest fixture, not a VM or device.' };
      if (process.env.DSH_1289_DEVICE_CASES) {
        await fs.mkdir(process.env.DSH_1289_DEVICE_CASES, { recursive: true });
        await fs.writeFile(path.join(process.env.DSH_1289_DEVICE_CASES, `ordinary-off-${noJoin ? 'unconfirmed' : 'joined'}.json`), JSON.stringify(observed, null, 2) + '\n');
      }
      t.diagnostic(JSON.stringify({ noJoin, code: observed.code, status: observed.summary?.status,
        shutdownConfirmed: observed.summary?.shutdownConfirmed, errors: observed.summary?.errors }));
      if (noJoin) {
        assert.notEqual(result.code, 0); assert.equal(result.summary.shutdownConfirmed, false);
        assert.ok(!result.summary.status.startsWith('PASS_'));
      } else {
        assert.equal(result.code, 0, result.stdout + result.stderr);
        assert.equal(result.summary.status, 'PASS_LOCAL_ONLY');
        assert.equal(result.summary.shutdownConfirmed, true);
        assert.equal(result.summary.finalStatus.state, 'stopped');
        assert.equal(result.summary.cancellation.jobSettled, true);
      }
    } finally { await server.close(); await result?.cleanup(); }
  });
}
