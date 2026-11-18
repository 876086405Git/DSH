// Real web prompt -> official mock model -> official schedule_create -> user question.
// Timeout executes the real authorization callback via a test-only clock; never waits 120 seconds.
// DSH_PREFIX=<patched rc.1> DSH_MOCK_PREFIX=<rc.1 prefix with official mock> node this-file
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { mkdtemp, mkdir, readFile, writeFile, symlink, copyFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
assert.ok(process.env.DSH_PREFIX, 'DSH_PREFIX is required');
const prefix = resolve(process.env.DSH_PREFIX);
const mockPrefix = resolve(process.env.DSH_MOCK_PREFIX ?? prefix);
const pkg = (name, base = prefix) => join(base, 'node_modules/@deepseek-ai', name);
assert.equal(JSON.parse(await readFile(join(pkg('dsh'), 'package.json'))).version, '0.2.2-rc.1');
assert.equal(JSON.parse(await readFile(join(pkg('dsh-llm-mock-server', mockPrefix), 'package.json'))).version, '0.2.2-rc.1');
const { startMockLlmServer } = await import(pathToFileURL(join(pkg('dsh-llm-mock-server', mockPrefix), 'lib/index.js')));
const { default: WebSocket } = await import(pathToFileURL(join(prefix, 'node_modules/ws/wrapper.mjs')));
const root = await mkdtemp(join(tmpdir(), 'dsh022-schedule-tool-'));
const results = [];
async function stop(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const ended = once(child, 'exit'); child.kill('SIGTERM');
  const timeout = setTimeout(() => child.kill('SIGKILL'), 10000);
  try { await ended; } finally { clearTimeout(timeout); }
}
try {
  for (const mode of ['native']) for (const decision of ['allowed-once', 'rejected', 'cancelled', 'timeout']) {
    const directory = join(root, mode + '-' + decision), home = join(directory, 'home'), work = join(directory, 'work');
    await mkdir(home, { recursive: true }); await mkdir(work);
    

    await symlink(join(prefix, 'node_modules'), join(directory, 'node_modules'), 'dir');
    const clock = join(directory, 'deadline-clock.mjs');
    await copyFile(new URL('./fixtures/schedule-deadline-clock.mjs', import.meta.url), clock);
    const apiKey = 'SYNTHETIC_WEB_APPROVAL_KEY';
    const mock = await startMockLlmServer({ host: '127.0.0.1', port: 0, apiKey, sequence: ['tool_call_success', 'success'],
      toolName: 'schedule_create',
      toolArguments: JSON.stringify({ title: 'Synthetic scheduled task', prompt: 'Never executed', rrule: 'DTSTART:20990101T000000Z\nRRULE:FREQ=DAILY;COUNT=1', target: 'new_once' }),
      successText: 'SYNTHETIC_WEB_TURN_FINISHED', repeatLast: false });
    const rows = ['session-title-llm', 'llm-pi-ai', 'llm-deepseek-account', 'session-telemetry-otel', 'web-search-deepseek', 'web-deepseek-api', 'web-fetch-http', 'tool-web'].map(id => ({ id, disabled: true }));
    rows.push({ id: 'llm-deepseek', config: { baseURL: mock.baseURL + '/v1', apiKeyEnv: 'DSH_WEB_TEST_KEY', thinking: 'disabled', maxTokens: 2048 } },
      { id: 'sandbox-policy', config: { mode: 'danger-full-access', workspaceRoot: work } },
      { id: 'approval', config: { policy: 'ask' } },
      { id: 'permission', config: { presets: { 'web-test-ask': { sandbox: 'danger-full-access', approval: 'ask' } }, defaultPreset: 'web-test-ask' } },
      { id: 'agent-default-model', config: { provider: 'deepseek-official', model: 'deepseek-flash' } },
      { id: 'session-persistence-jsonl', config: { root: join(home, 'sessions'), compression: 'none' } },
      { id: 'tool-executor-native', disabled: mode !== 'native' }, { id: 'tool-executor-ptc', disabled: mode !== 'ptc' },
      { id: 'ptc-runtime', config: { executionMode: 'per-call' } });
    if (decision === 'timeout') rows.push({ insert: [{ id: 'schedule-deadline-clock', name: clock }] });
    const patch = join(directory, 'patch.json'); await writeFile(patch, JSON.stringify(rows));
    const reservation = createServer(); reservation.listen(0, '127.0.0.1'); await once(reservation, 'listening');
    const port = reservation.address().port; await new Promise(done => reservation.close(done));
    const origin = `http://127.0.0.1:${port}`;
    const env = Object.fromEntries(['PATH', 'LANG', 'LC_ALL', 'TMPDIR'].filter(k => process.env[k]).map(k => [k, process.env[k]]));
    Object.assign(env, { HOME: home, DSH_HOME: join(home, 'dsh'), DSH_TELEMETRY_DISABLED: '1', DSH_WEB_TEST_KEY: apiKey });
    const child = spawn(process.execPath, [join(pkg('dsh'), 'lib/bin.js'), 'web', '--patch', patch, '--host', '127.0.0.1', '--port', String(port), '--no-open'], { env, cwd: work, stdio: ['ignore', 'pipe', 'pipe'] });
    let hostOutput = '', socket, token;
    const lifetime = AbortSignal.timeout(40000);
    try {
      token = await new Promise((done, fail) => {
        const aborted = () => fail(Error('Synthetic Host startup timed out'));
        lifetime.addEventListener('abort', aborted, { once: true });
        child.once('error', fail); child.once('exit', code => fail(Error(`Synthetic Host startup exited (${code})`)));
        const capture = chunk => { hostOutput += chunk; const match = hostOutput.match(/token=([\w-]+)/); if (match) { lifetime.removeEventListener('abort', aborted); done(match[1]); } };
        child.stdout.on('data', capture); child.stderr.on('data', capture);
      });
      const login = await fetch(`${origin}/?token=${token}`, { redirect: 'manual', signal: lifetime });
      assert.equal(login.status, 303);
      const cookie = login.headers.getSetCookie().map(v => v.split(';')[0]).join('; '); assert.ok(cookie);
      const page = await fetch(origin + '/', { headers: { cookie }, signal: lifetime }); assert.equal(page.status, 200); await page.arrayBuffer();
      let sequence = 0, prompts = 0, replies = 0;
      async function rpc(method, args = {}, raw = false) {
        if (method === 'session/prompt') prompts++;
        if (method === '$events/result') replies++;
        const res = await fetch(`${origin}/api/${method}`, { method: 'POST', headers: { cookie, 'content-type': 'application/json' },
          body: JSON.stringify({ type: 'client-request', rpcId: `web-probe-${++sequence}`, method, payload: { args } }), signal: lifetime });
        assert.equal(res.status, 200); const body = await res.json(); if (raw) return body.result; assert.equal(body.result.ok, true, JSON.stringify(body.result.error)); return body.result.value;
      }
      async function clockAction(action) {
        const res = await fetch(origin + '/schedule-deadline-clock', { method: 'POST', headers: { cookie, 'content-type': 'application/json' }, body: JSON.stringify({ action }), signal: lifetime });
        assert.equal(res.status, 200); return res.json();
      }
      const messages = [], waiters = [];
      socket = new WebSocket(origin.replace('http:', 'ws:') + '/api/remote.mux', { headers: { cookie, origin } });
      socket.on('message', data => {
        const frame = JSON.parse(String(data)); if (frame.type !== 'item' || frame.streamId !== 'events') return;
        const i = waiters.findIndex(w => w.match(frame.value)); if (i < 0) messages.push(frame.value); else waiters.splice(i, 1)[0].resolve(frame.value);
      });
      function next(match) {
        const i = messages.findIndex(match); if (i >= 0) return Promise.resolve(messages.splice(i, 1)[0]);
        return new Promise((resolve, reject) => { waiters.push({ match, resolve }); lifetime.addEventListener('abort', () => reject(Error('Synthetic remote event timed out')), { once: true }); });
      }
      await once(socket, 'open'); socket.send(JSON.stringify({ type: 'open', streamId: 'events', endpoint: '$events', payload: { args: {} } }));
      const ready = await next(f => f.type === 'ready');
      const created = await rpc('session/create', { request: { cwd: work } }); const sessionId = created.sessionId;
      if (decision === 'timeout') {
        const denied = await fetch(origin + '/schedule-deadline-clock', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ action: 'arm' }), signal: lifetime });
        assert.equal(denied.status, 401); await denied.arrayBuffer();
        assert.deepEqual(await clockAction('arm'), { armed: true, count: 0, unexpected: 0, fired: false, cleared: false });
      }
      const receipt = await rpc('session/prompt', { request: { sessionId, requestId: 'schedule-tool-single-prompt', mode: 'queue', content: [{ type: 'text', text: 'Propose the synthetic future schedule once; await user authorization.' }] } });
      assert.equal(receipt.accepted, true);
      const question = await next(f => f.type === 'waterfall' && f.event === 'user-questions/request');
      assert.equal(question.agentId, sessionId); assert.equal(question.request.purpose, 'schedule-authorization');
      assert.equal((await rpc('schedule/catalog')).length, 0);
      assert.equal(mock.requests.length, 1);
      assert.ok(mock.requests[0].body.tools.some(tool => tool.name === 'schedule_create'));
      assert.equal(prompts, 1);
      const began = Date.now();
      if (decision === 'cancelled') await rpc('session/cancel', { request: { sessionId } });
      else if (decision === 'timeout') {
        assert.deepEqual(await clockAction('state'), { armed: true, count: 1, unexpected: 0, fired: false, cleared: false });
        const fired = await clockAction('fire'); assert.equal(fired.fired, true);
      }
      else await rpc('$events/result', { clientId: ready.clientId, eventId: question.eventId,
        outcome: { kind: 'result', value: { answers: [{ id: question.request.questions[0].id, selected: [decision === 'allowed-once' ? '授权 / Authorize' : '拒绝 / Reject'] }] } } });
      const finished = await rpc('session/wait', { request: { sessionId, timeoutMs: 15000 } });
      assert.equal(finished.reason, 'idle');
      assert.equal(replies, ['cancelled', 'timeout'].includes(decision) ? 0 : 1);
      const tasks = await rpc('schedule/catalog');
      assert.equal(tasks.length, decision === 'allowed-once' ? 1 : 0);
      if (tasks.length) assert.equal(tasks[0].target.kind, 'new_once');
      if (decision !== 'cancelled') {
        assert.equal(mock.requests.length, 2);
        const deniedCode = decision === 'rejected' ? 'authorization_rejected' : 'authorization_required';
        assert.ok(JSON.stringify(mock.requests[1].body).includes(decision === 'allowed-once' ? 'Synthetic scheduled task' : deniedCode));
      }
      if (decision === 'timeout') {
        const state = await clockAction('state');
        assert.deepEqual(state, { armed: false, count: 1, unexpected: 0, fired: true, cleared: true });
        const late = await rpc('$events/result', { clientId: ready.clientId, eventId: question.eventId,
          outcome: { kind: 'result', value: { answers: [{ id: question.request.questions[0].id, selected: ['授权 / Authorize'] }] } } }, true);
        assert.equal(late.ok, true, 'transport can acknowledge a stale result without approving');
        assert.equal((await rpc('schedule/catalog')).length, 0);
        await clockAction('restore');
      }
      results.push({ mode, decision, modelRequests: mock.requests.length, saved: tasks.length, elapsedMs: Date.now() - began });
      socket.terminate(); await stop(child);
    } catch (error) {
      // Never expose launch tokens, cookies, mock headers, or configured keys.
      throw Error(`${mode}/${decision}: ${String(error.message).replaceAll(token ?? 'NO_TOKEN', '<redacted>').replaceAll(apiKey, '<redacted>')}`);
    } finally { socket?.terminate(); await stop(child); await mock.close(); }
  }
  console.log(JSON.stringify({ status: 'PASS_REAL_WEB_SCHEDULE_AUTHORIZATION', results, limits: ['native executor and real official mock model; no external model account', 'timeout uses a uniquely captured real 120000ms callback, not elapsed wall time', 'no Android UI or actual device action'] }, null, 2));
} finally { await rm(root, { recursive: true, force: true }); }
