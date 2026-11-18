// Drives real tool and lifecycle rounds on the iOS Simulator: the same
// five tools as runtime/ohos/sim/round.mjs, then Node Worker, git, rg, 2 MiB output,
// cancellation, stop during a Worker, persisted sessions and another round after restart.
//
//   node drive.mjs --simulator <udid> --smoke <binary> --frameworks <dir> --runtime <tree> \
//     --work <new dir> --ws <dir holding the ws package>
//
// The Simulator shares this Mac's filesystem and loopback, which is what makes this work.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import http from 'node:http';
import { appendFileSync, cpSync, existsSync, mkdirSync, realpathSync, writeFileSync } from 'node:fs';
import { readFile, stat, rm } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { startScenarios } from './scenarios.mjs';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: { ...Object.fromEntries(
  ['simulator', 'smoke', 'frameworks', 'runtime', 'work', 'ws'].map((name) => [name, { type: 'string' }])),
  direct: { type: 'boolean', default: false },
} });
for (const name of [...(values.direct ? [] : ['simulator']), 'smoke', 'frameworks', 'runtime', 'work', 'ws']) {
  if (!values[name]) throw new Error(`--${name} is required`);
}
const repo = fileURLToPath(new URL('../../..', import.meta.url));
const { WebSocket } = createRequire(join(resolve(values.ws), 'package.json'))('ws');

const work = resolve(values.work);
mkdirSync(work);
const guest = realpathSync(work) + '/guest';
const dshHome = `${guest}/root/.dsh`;
const workspace = `${guest}/root/workspace`;
const cache = realpathSync(work) + '/cache';
for (const directory of [dshHome, `${guest}/root/.agents`, workspace, cache]) mkdirSync(directory, { recursive: true });

const logFile = join(work, 'engine.log');
const report = { status: 'BLOCKED', stage: 'startup', approvals: 0, restart: 'not-run', eventTypes: [], scenarios: [] };
const fail = (message) => { throw new Error(message); };

const model = await startScenarios(workspace);
// The phone tools' backend, wired the way EngineChannel.preparePhone does it. Only the
// system actions themselves need the app.
const phoneRun = randomUUID();
const phoneDirectory = join(realpathSync(work), 'phone');
mkdirSync(phoneDirectory, { mode: 0o700 });
const phoneBackend = join(resolve(values.runtime), 'runtime/ios/phone');
cpSync(join(repo, 'runtime/ios/phone'), phoneBackend, { recursive: true });
cpSync(join(repo, 'runtime/ios/browser'), join(resolve(values.runtime), 'runtime/ios/browser'), { recursive: true });
cpSync(join(repo, 'runtime/ios/system'), join(resolve(values.runtime), 'runtime/ios/system'), { recursive: true });
writeFileSync(join(dshHome, 'ios-host.patch.json'), JSON.stringify([{ insert: [{
  id: 'dsh-go-ios-phone', name: join(phoneBackend, 'plugin.mjs'), config: { directory: phoneDirectory, runId: phoneRun },
}] }]));

const overlay = join(work, 'model.patch.yml');
writeFileSync(overlay, JSON.stringify([
  { id: 'llm-pi-ai', config: { providers: { 'ohos-fake': {
    api: 'openai-completions', baseURL: model.baseURL, apiKeyEnv: 'DSH_OHOS_TEST_KEY',
    retryPolicy: { mode: 'normal', maxRetries: 0 },
    models: [{ id: 'ohos-script', contextWindow: 32768, maxTokens: 4096, reasoningEfforts: false }],
  } } } },
  { id: 'agent-default-model', config: { provider: 'ohos-fake', model: 'ohos-script' } },
  { id: 'session-title-llm', disabled: true },
]));

const smokeArgs = [resolve(values.frameworks), resolve(values.runtime), guest, cache];
const engine = spawn(values.direct ? resolve(values.smoke) : 'xcrun', values.direct ? smokeArgs :
  ['simctl', 'spawn', values.simulator, resolve(values.smoke), ...smokeArgs], {
  env: {
    ...process.env,
    DSH_IOS_SMOKE_PATCH: overlay,
    DSH_IOS_SMOKE_PHONE_RUN: phoneRun,
    SIMCTL_CHILD_DSH_IOS_SMOKE_PATCH: overlay,
    SIMCTL_CHILD_DSH_IOS_SMOKE_PHONE_RUN: phoneRun,
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let exited = null;
let engineEnded = null;
let restarting = false;
const readyWaiters = [];
const readies = [];
let tail = [];
let buffered = '';
const repeats = new Map();
const noteLine = (line) => {
  line = line.replace(/([?&]token=)[^\s]+/gu, '$1<redacted>');
  appendFileSync(logFile, line + '\n');
  // A warning repeated thousands of times would push the cause out of the tail.
  const key = line.replace(/\d+/g, '#');
  const seen = (repeats.get(key) ?? 0) + 1;
  repeats.set(key, seen);
  if (seen > 3) {
    if (seen % 1000 === 0) tail.push(`[seen ${seen} times] ${line}`);
    return;
  }
  tail.push(line);
  if (tail.length > 200) tail.shift();
};
engine.stderr.on('data', (data) => String(data).split('\n').forEach((line) => line && noteLine('[smoke stderr] ' + line)));
engine.stdout.on('data', (data) => {
  buffered += data;
  const lines = buffered.split('\n');
  buffered = lines.pop();
  for (const line of lines) {
    if (line === '[]' || line === '') continue;
    let rows;
    try { rows = JSON.parse(line); } catch { noteLine('[raw] ' + line); continue; }
    for (const row of Array.isArray(rows) ? rows : [rows]) {
      if (row.kind === 'log') noteLine(`[${row.stream}] ${row.line}`);
      else if (row.kind === 'ready') {
        noteLine('[ready] ' + row.baseUrl);
        readies.push(row);
        for (const waiter of readyWaiters.splice(0)) waiter();
      } else {
        noteLine(JSON.stringify(row));
        // The one exit a restart asks for isn't the engine ending by itself.
        if (row.kind === 'exit' && restarting) restarting = false;
        else if (row.kind === 'exit' || row.kind === 'error' || row.kind === 'fatal') {
          engineEnded = row;
          for (const waiter of readyWaiters.splice(0)) waiter();
        }
      }
    }
  }
});
engine.on('error', (error) => {
  exited = { error: error.message };
  for (const waiter of readyWaiters.splice(0)) waiter();
});
engine.on('exit', (code, signal) => {
  exited = { code, signal };
  noteLine(`[smoke exited] ${code ?? signal}`);
  for (const waiter of readyWaiters.splice(0)) waiter();
});

async function waitReady(index, ms) {
  const deadline = Date.now() + ms;
  while (readies.length <= index) {
    if (exited) fail(`engine exited before readiness: ${exited.error ?? exited.code ?? exited.signal}`);
    if (engineEnded) fail(`engine ended before readiness: ${JSON.stringify(engineEnded)}`);
    if (Date.now() > deadline) fail('engine readiness deadline');
    await Promise.race([new Promise((done) => readyWaiters.push(done)), new Promise((done) => setTimeout(done, 1000))]);
  }
  return readies[index];
}

function exchange(url, { body, cookie } = {}) {
  return new Promise((accept, reject) => {
    const bytes = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
    const req = http.request(url, {
      method: bytes ? 'POST' : 'GET', headers: {
        ...(cookie ? { Cookie: cookie } : {}),
        ...(bytes ? { 'content-type': 'application/json', 'content-length': bytes.length } : {}),
      },
    }, (res) => {
      const chunks = [];
      res.on('data', (data) => chunks.push(data));
      res.on('end', () => accept({ status: res.statusCode, headers: res.headers, text: Buffer.concat(chunks).toString('utf8') }));
      res.on('error', reject);
    });
    req.on('error', reject);
    req.setTimeout(60000, () => req.destroy(new Error('test HTTP timeout')));
    req.end(bytes);
  });
}

async function login(ready) {
  const response = await exchange(`${ready.baseUrl}/?token=${encodeURIComponent(ready.token)}`);
  if (response.status !== 303) fail(`launch token exchange returned ${response.status}`);
  const cookie = response.headers['set-cookie']?.find((item) => item.startsWith('dsh-auth-'))?.split(';')[0];
  if (!cookie) fail('launch exchange did not return a dsh-auth cookie');
  const rpc = async (endpoint, args = {}) => {
    const rpcId = randomUUID();
    const reply = await exchange(new URL(`/api/${endpoint}`, ready.baseUrl), {
      cookie, body: { type: 'client-request', rpcId, method: endpoint, payload: { args } },
    });
    if (reply.status !== 200) fail(`RPC ${endpoint}: HTTP ${reply.status}`);
    const wire = JSON.parse(reply.text);
    if (wire.rpcId !== rpcId || wire.type !== 'server-response') fail(`RPC ${endpoint}: invalid envelope`);
    if (wire.result?.ok !== true) fail(`RPC ${endpoint}: ${wire.result?.error?.code}: ${wire.result?.error?.message}`);
    return wire.result.value;
  };
  return { cookie, rpc };
}

async function round(ready, { mode = 'normal', restore, resume = false } = {}) {
  const { cookie, rpc } = await login(ready);
  const frames = [];
  const waiters = new Set();
  const events = [];
  let clientId;
  let muxError;
  const failMux = (error) => { muxError = error; for (const waiter of [...waiters]) waiter.reject(error); };
  function waitFrame(predicate) {
    if (muxError) return Promise.reject(muxError);
    const found = frames.find(predicate);
    if (found) return Promise.resolve(found);
    return new Promise((accept, reject) => {
      const entry = { predicate, accept: (frame) => { clearTimeout(entry.timer); waiters.delete(entry); accept(frame); } };
      entry.timer = setTimeout(() => { waiters.delete(entry); reject(new Error(`mux deadline at ${report.stage}`)); }, 180000);
      entry.reject = (error) => { clearTimeout(entry.timer); waiters.delete(entry); reject(error); };
      waiters.add(entry);
    });
  }
  const socket = new WebSocket(ready.baseUrl.replace('http:', 'ws:') + '/api/remote.mux', { headers: { Cookie: cookie }, handshakeTimeout: 30000 });
  socket.on('error', failMux);
  socket.on('close', () => failMux(new Error('mux closed')));
  socket.on('message', (bytes) => {
    try {
      const frame = JSON.parse(bytes.toString());
      frames.push(frame);
      if (frame.type === 'error') { failMux(new Error(`mux ${frame.streamId}: ${frame.error?.code}`)); return; }
      const value = frame.value;
      if (value?.type === 'ready') clientId = value.clientId;
      if (value?.type === 'waterfall' && value.event === 'approval/request') {
        report.approvals++;
        rpc('$events/result', { clientId, eventId: value.eventId, outcome: { kind: 'result', value: 'allowed-once' } }).catch(failMux);
      }
      if (value?.type === 'event') {
        events.push(value.event);
        report.eventTypes.push(value.event.type);
      }
      for (const waiter of [...waiters]) if (waiter.predicate(frame)) waiter.accept(frame);
    } catch (error) { failMux(error); }
  });
  await once(socket, 'open', { signal: AbortSignal.timeout(30000) });
  socket.send(JSON.stringify({ type: 'open', streamId: 'host', endpoint: '$events', payload: { args: {} } }));
  await waitFrame((frame) => frame.streamId === 'host' && frame.value?.type === 'ready');
  report.stage = 'session/create';
  const sessionId = restore ?? (await rpc('session/create', { request: { cwd: workspace, agentPreset: 'standard' } })).sessionId;
  report.stage = 'session/follow';
  socket.send(JSON.stringify({ type: 'open', streamId: 'session', endpoint: 'session/follow', payload: { args: { request: { address: { kind: 'session', sessionId }, assistantDeltas: true } } } }));
  const snapshot = await waitFrame((frame) => frame.streamId === 'session' && frame.value?.type === 'snapshot');
  const close = () => { socket.removeAllListeners('close'); socket.terminate(); };
  if (restore) {
    const records = snapshot.value.records ?? [];
    if (!records.some((row) => row.event?.type === 'tool/result')) fail('restored session lost its real tool history');
    if (resume) {
      const before = events.length;
      await rpc('session/prompt', { request: { requestId: randomUUID(), sessionId, mode: 'queue',
        content: [{ type: 'text', text: '[DSH_IOS_SMOKE:resume] Continue the saved scripted conversation after restart.' }] } });
      const end = await waitFrame((frame) => frame.streamId === 'session' && frame.value?.event?.type === 'turn/end');
      if (end.value.event.data.reason?.kind !== 'completed') fail('restored session could not continue');
      const results = events.slice(before).filter((event) => event.type === 'tool/result');
      if (results.length !== 1 || results[0].data.message?.isError !== false ||
        !results[0].data.message.content.some((part) => part.text?.includes('修改后内容'))) {
        fail('restored session did not read its prior file');
      }
    }
    report.scenarios.push({ name: 'restore-session', sessionId, records: records.length, continued: resume });
    close();
    return sessionId;
  }
  await rm(model.file, { force: true }); // Only this new test workspace's own five-tool fixture.
  writeFileSync(join(workspace, 'scenario-mode.txt'), mode);
  report.stage = mode;
  const approvalsBefore = report.approvals;
  const before = events.length;
  await rpc('session/prompt', { request: { requestId: randomUUID(), sessionId, mode: 'queue', content: [{ type: 'text', text: '[DSH_IOS_SMOKE:round] iOS scripted file, search, shell and approval round.' }] } });
  if (mode !== 'normal') {
    const marker = join(workspace, 'started-' + mode);
    const deadline = Date.now() + 180000;
    while (!existsSync(marker)) {
      if (muxError) throw muxError;
      if (Date.now() > deadline) fail('long Worker never started: ' + mode);
      await delay(50);
    }
    if (mode === 'stop') {
      close();
      engineEnded = null;
      restarting = true;
      writeFileSync(`${guest}/restart`, '');
      report.scenarios.push({ name: 'stop-active-worker', sessionId });
      return sessionId;
    }
    await rpc('session/cancel', { request: { sessionId } });
  }
  const end = await waitFrame((frame) => frame.streamId === 'session' && frame.value?.event?.type === 'turn/end');
  const reason = end.value.event.data.reason;
  if (mode === 'cancel') {
    if (reason?.kind !== 'aborted') fail('cancel did not abort the running turn');
    await stoppedHeartbeat('cancel');
    report.scenarios.push({ name: 'cancel-active-worker', sessionId, reason: reason.kind });
    close();
    return sessionId;
  }
  if (reason?.kind !== 'completed') fail(`turn ended: ${JSON.stringify(reason).slice(0, 1500)}`);
  const results = events.slice(before).filter((event) => event.type === 'tool/result');
  if (results.length !== 5) fail(`expected five tool results, got ${results.length}`);
  const failed = results.findIndex((event) => event.data.message?.isError !== false);
  if (failed >= 0) fail(`tool ${failed} failed: ${JSON.stringify(results[failed].data.message?.content)?.slice(0, 400)}`);
  if (!results[4].data.message.content.some((part) => part.text?.includes('shell-ok'))) fail('bash result missing marker');
  if (await readFile(model.file, 'utf8') !== '修改后内容\n') fail('file side effect did not match the script');
  if (report.approvals <= approvalsBefore) fail('round did not exercise a fresh approval');
  const observation = JSON.parse(await readFile(join(workspace, 'worker-observation.json'), 'utf8'));
  if (observation.isMainThread !== false || observation.bytes !== 2 * 1024 * 1024) fail('Node Worker/output observation mismatch');
  if (!results[4].data.message.content.some((part) => part.text?.includes('large-output-tail-中文'))) fail('large output lost its tail');
  if (!(await readFile(join(workspace, 'git-status.txt'), 'utf8')).includes('中文 文件.txt')) fail('git did not stage the Chinese file');
  if (await readFile(join(workspace, 'rg-result.txt'), 'utf8') !== 'needle-中文\n') fail('rg did not read the Chinese file');
  report.scenarios.push({ name: 'worker-git-rg-large-output-unicode', sessionId, observation });
  close();
  return sessionId;
}

async function stoppedHeartbeat(mode) {
  const path = join(workspace, 'heartbeat-' + mode);
  const size = async () => (await stat(path).catch(() => ({ size: 0 }))).size;
  const before = await size();
  await delay(250);
  if (await size() !== before) fail(mode + ': Worker kept writing after settlement');
}

try {
  const startedAt = Date.now();
  const first = await waitReady(0, 240000);
  engineEnded = null;
  report.readyMs = Date.now() - startedAt;
  const completedSession = await round(first);
  await round(first, { mode: 'cancel' });
  report.status = 'ROUND_PASSED';
  report.stage = 'restart';
  const interruptedSession = await round(first, { mode: 'stop' });
  const restartedAt = Date.now();
  const second = await waitReady(1, 240000);
  report.restartReadyMs = Date.now() - restartedAt;
  await stoppedHeartbeat('stop');
  await round(second, { restore: completedSession, resume: true });
  await round(second, { restore: interruptedSession });
  await round(second);
  report.restart = 'passed';
  report.status = 'PASS';
  report.stage = 'complete';
} catch (error) {
  report.error = error.message;
}
if (!exited) {
  writeFileSync(`${guest}/quit`, '');
  await Promise.race([once(engine, 'exit'), new Promise((done) => setTimeout(done, 20000))]);
  if (!exited) engine.kill();
}
report.modelRequests = model.requests.map((row) => row.requestedTool);
report.phoneEndpoint = existsSync(join(phoneDirectory, 'endpoint.json'));
report.phoneTools = (model.requests[0]?.offeredTools ?? []).filter((name) => name?.startsWith('mcp__phone__')).length;
report.browserTools = (model.requests[0]?.offeredTools ?? []).filter((name) => name?.startsWith('mcp__browser__')).length;
report.systemTools = (model.requests[0]?.offeredTools ?? []).filter((name) => name?.startsWith('mcp__system__')).length;
await model.close();
report.nativeHost = existsSync(logFile) ? tail : [];
writeFileSync(join(work, 'report.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
process.exit(report.status === 'PASS' ? 0 : 1);
