import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import fs, { mkdtemp, mkdir, readFile, writeFile, rm, rename, readdir } from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { spawnSync, spawn } from 'node:child_process';
import { tmpdir } from 'node:os';
import { basename, dirname, join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CATALOG, HARD_LIMITS, Config, runtimeSnapshot, catalogModel } from '../src/config.js';
import { createMediaClient, createDescriptor } from '../src/adapters.js';
import { createHttpTransport } from '../src/http.js';
import { generateMedia, readReferences, validateReferencePins } from '../src/media-engine.js';
import { createStreamStager } from '../src/stream-staging.js';
import { admitGeneration, recoverAdmission } from '../src/budget.js';
import { createBudgetLedger } from '../src/budget-ledger.js';
import { selectedRequest } from '../src/index.js';
import { abortError } from '../src/errors.js';
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ6sAAAAASUVORK5CYII=', 'base64');
const MP4 = Buffer.from((await readFile(new URL('./fixtures/video.base64', import.meta.url), 'utf8')).trim(), 'base64');
const modelFor = profile => CATALOG.models.find(m => m.profile === profile && !m.editOnly);
function request(profile, extra = {}) {
  const model = extra.model ?? modelFor(profile);
  return { prompt: '蓝色圆形', n: 1, refs: [], service: { id: 'probe', provider: profile, profile, baseUrl: CATALOG.profiles[profile]?.origin ?? 'https://api.openai.com/v1' }, model, ...extra };
}
async function fixture(t, profile, behavior = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'media-v2-'));
  const workspace = join(directory, 'workspace'); await mkdir(workspace);
  const wires = []; let state = behavior.state ?? 'succeeded';
  const server = createServer(async (req, res) => {
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks)) : undefined;
    wires.push({ method: req.method, path: req.url, body, auth: req.headers.authorization });
    if (req.url === '/original.mp4' || req.url === '/original.png') { res.end(req.url.endsWith('mp4') ? MP4 : PNG); return; }
    const creating = req.method === 'POST' && !req.url.endsWith('/cancel') && !req.url.endsWith('/status');
    if (creating && behavior.drop) { req.socket.destroy(); return; }
    if (creating && behavior.stall) {
      // Time out only after submission, not during the preceding filesystem preparation.
      controller.abort(new DOMException('deadline', 'TimeoutError'));
      return;
    }
    if (creating && behavior.reject) { res.writeHead(behavior.reject); res.end(JSON.stringify({ error: behavior.error })); return; }
    if (req.method === 'DELETE' || req.url.endsWith('/cancel')) { state = 'cancelled'; res.end('{}'); return; }
    const url = 'https://result.example/original.' + (profile.includes('video') ? 'mp4' : 'png');
    let value;
    if (!profile.includes('video')) value = profile === 'ali-wan-image' ? { output: { choices: [{ message: { content: [{ image: url }] } }] } }
      : profile === 'silicon-image' ? { images: [{ url }] } : { data: [{ b64_json: PNG.toString('base64') }] };
    else if (creating) value = profile === 'ark-video' ? { id: 'task-1' } : profile === 'ali-video' ? { output: { task_id: 'task-1', task_status: 'PENDING' } } : { requestId: 'task-1' };
    else {
      if (behavior.queryError) { res.writeHead(503); res.end('{}'); return; }
      if (behavior.queryStall) return;
      value = profile === 'ark-video' ? { id: 'task-1', status: state === 'cancelled' ? 'cancelled' : state, error: behavior.error, content: { video_url: url } }
        : profile === 'ali-video' ? { output: { task_id: 'task-1', task_status: ({ queued: 'PENDING', running: 'RUNNING', succeeded: 'SUCCEEDED', failed: 'FAILED', cancelled: 'CANCELED' })[state], video_url: url } }
          : { status: ({ queued: 'InQueue', running: 'InProgress', succeeded: 'Succeed', failed: 'Failed' })[state], results: { videos: [{ url }] } };
    }
    if (behavior.nullImageUrl) value.data[0].url = null;
    res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(value));
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const origin = `http://127.0.0.1:${server.address().port}`;
  const local = createHttpTransport({ allowLoopback: true });
  const transport = (url, options) => {
    const parsed = new URL(url);
    assert.ok([new URL(request(profile).service.baseUrl).hostname, 'result.example'].includes(parsed.hostname));
    return local(origin + parsed.pathname, options);
  };
  const controller = new AbortController();
  const context = { hostStateDir: join(directory, 'host-state'), sessionId: 'session-1', keyRef: 'TEST_MEDIA_KEY',
    signal: controller.signal, limits: { ...HARD_LIMITS }, budget: { dailyMicros: 20_000_000, unknownHoldMicros: 20_000_000 },
    approve: async () => 'allowed-once', resolveCredential: async () => 'synthetic-key-not-real',
    authorizeWorkspace: async () => ({ cwd: workspace, workspaceRoot: workspace, mode: 'workspace-write' }),
    transport, client: createMediaClient({ transport, queryTimeoutMs: behavior.queryStall ? 30 : 30_000 }), pollMs: 1,
    stageDownload: (url, options) => { assert.equal(new URL(url).hostname, 'result.example'); return createStreamStager({ allowLoopback: true })(origin + new URL(url).pathname, options); },
  };
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true }); });
  return { directory, workspace, wires, controller, context, origin, setState(value) { state = value; } };
}
test('default DNS failure releases the unsent hold for another admission', t => {
  const child = spawnSync(process.execPath, [fileURLToPath(new URL('./fixtures/presend-dns-child.mjs', import.meta.url))], {
    encoding: 'utf8', timeout: 30_000,
  });
  if (child.stdout) t.diagnostic(child.stdout.trim());
  assert.ifError(child.error);
  assert.equal(child.status, 0, child.stderr);
});
test('image stage partial write failure preserves storage classification and submitted hold', async t => {
  const f = await fixture(t, 'openai-gpt-image'), req = request('openai-gpt-image');
  f.context.admission = await admitGeneration(req, f.context);
  const outputDirectory = join(f.workspace, 'generated', f.context.admission.outputDate);
  const originalOpen = fs.open;
  let failures = 0;
  const injected = t.mock.method(fs, 'open', async function (path, ...args) {
    const handle = await originalOpen.call(this, path, ...args);
    if (String(path).startsWith(outputDirectory + sep) && basename(String(path)) === '1.png') {
      const write = handle.writeFile.bind(handle);
      handle.writeFile = async bytes => {
        await write(bytes.subarray(0, 5));
        assert.equal((await handle.stat()).size, 5);
        failures++;
        throw Object.assign(new Error('controlled image write ENOSPC'), { code: 'ENOSPC' });
      };
    }
    return handle;
  });
  syncBuiltinESMExports();
  try { await assert.rejects(generateMedia(req, f.context), { code: 'storage' }); }
  finally { injected.mock.restore(); syncBuiltinESMExports(); }
  assert.equal(failures, 1);
  assert.equal(f.wires.length, 1);
  assert.equal(f.wires[0].method, 'POST');
  const ledger = await createBudgetLedger(join(f.context.hostStateDir, 'budget')).snapshot();
  assert.equal(ledger.requests[0].state, 'submission_unknown');
  assert.deepEqual(await readdir(outputDirectory), []);
  assert.deepEqual(await readdir(join(f.context.hostStateDir, 'works', f.context.admission.outputDate)), []);
});
test('store preparation failure rolls back staging and releases the unsent hold', async t => {
  const f = await fixture(t, 'openai-gpt-image'), req = request('openai-gpt-image');
  f.context.admission = await admitGeneration(req, f.context);
  const outputDirectory = join(f.workspace, 'generated', f.context.admission.outputDate);
  const target = join(f.context.hostStateDir, 'works');
  const originalMkdir = fs.mkdir;
  let failures = 0, pendingNames;
  const injected = t.mock.method(fs, 'mkdir', async function (path, options) {
    if (path === target) {
      pendingNames = await readdir(outputDirectory);
      failures++;
      throw Object.assign(new Error('controlled index directory ENOSPC'), { code: 'ENOSPC' });
    }
    return originalMkdir.call(this, path, options);
  });
  syncBuiltinESMExports();
  try { await assert.rejects(generateMedia(req, f.context), { code: 'storage' }); }
  finally { injected.mock.restore(); syncBuiltinESMExports(); }
  assert.equal(failures, 1);
  assert.equal(pendingNames.length, 1);
  assert.ok(pendingNames[0].endsWith('.pending'));
  assert.equal(f.wires.length, 0);
  const ledger = await createBudgetLedger(join(f.context.hostStateDir, 'budget')).snapshot();
  assert.equal(ledger.requests[0].state, 'released');
  assert.deepEqual(await readdir(outputDirectory), []);
  await assert.rejects(fs.stat(target), { code: 'ENOENT' });
});
for (const profile of ['openai-gpt-image', 'ark-video']) {
  test(`${profile}: publishes directly from staging with hard links unavailable`, async t => {
    const f = await fixture(t, profile), req = request(profile);
    f.context.admission = await admitGeneration(req, f.context);
    const { rid, outputDate } = f.context.admission;
    const indexPath = join(f.context.hostStateDir, 'works', outputDate, rid + '.json');
    const outputPath = join(f.workspace, 'generated', outputDate, rid + '-1.' + (profile === 'ark-video' ? 'mp4' : 'png'));
    let links = 0;
    const finalRenames = [];
    const originalRename = fs.rename;
    const blocked = t.mock.method(fs, 'link', async () => {
      links++;
      throw Object.assign(new Error('controlled app-domain hard-link refusal'), { code: 'EACCES' });
    });
    const observed = t.mock.method(fs, 'rename', async function (source, target) {
      if (target === outputPath || target === indexPath) {
        assert.equal(target === outputPath ? dirname(dirname(source)) : dirname(source), dirname(target));
        finalRenames.push(target);
      }
      return originalRename.call(this, source, target);
    });
    syncBuiltinESMExports();
    let result;
    try { result = await generateMedia(req, f.context); }
    finally { observed.mock.restore(); blocked.mock.restore(); syncBuiltinESMExports(); }
    assert.equal(links, 0);
    assert.deepEqual(finalRenames, [outputPath, indexPath]);
    assert.deepEqual(await readFile(outputPath), profile === 'ark-video' ? MP4 : PNG);
    assert.deepEqual(JSON.parse(await readFile(indexPath, 'utf8')).media, result.meta);
    assert.deepEqual(await readdir(dirname(outputPath)), [basename(outputPath)]);
    assert.deepEqual(await readdir(dirname(indexPath)), [basename(indexPath)]);
    assert.equal(f.wires.filter(wire => wire.method === 'POST').length, 1);
    assert.equal((await createBudgetLedger(join(f.context.hostStateDir, 'budget')).snapshot()).requests[0].state, 'settled');
  });
}
test('concurrent requests keep the accepted work when the other session loses permission after publication', async t => {
  const f = await fixture(t, 'openai-gpt-image'), req = request('openai-gpt-image');
  f.context.budget.dailyMicros *= 2;
  const first = { ...f.context }, second = { ...f.context, sessionId: 'session-2' };
  first.admission = await admitGeneration(req, first);
  second.admission = await admitGeneration(req, second);
  const indexDirectory = join(f.context.hostStateDir, 'works', first.admission.outputDate);
  const firstIndex = join(indexDirectory, first.admission.rid + '.json');
  first.authorizeWorkspace = async () => {
    const policy = await f.context.authorizeWorkspace();
    try { await readFile(firstIndex); return { ...policy, mode: 'read-only' }; }
    catch (error) { if (error.code !== 'ENOENT') throw error; return policy; }
  };
  const [failed, accepted] = await Promise.allSettled([generateMedia(req, first), generateMedia(req, second)]);
  assert.equal(failed.status, 'rejected');
  assert.equal(failed.reason.code, 'permission');
  assert.equal(accepted.status, 'fulfilled');
  const meta = accepted.value.meta;
  assert.deepEqual(await readFile(meta.items[0].path), PNG);
  assert.deepEqual(await readdir(dirname(meta.items[0].path)), [basename(meta.items[0].path)]);
  assert.deepEqual(await readdir(indexDirectory), [second.admission.rid + '.json']);
  assert.deepEqual(JSON.parse(await readFile(join(indexDirectory, second.admission.rid + '.json'), 'utf8')).media, meta);
  assert.equal(f.wires.filter(wire => wire.method === 'POST').length, 2);
  assert.deepEqual((await createBudgetLedger(join(f.context.hostStateDir, 'budget')).snapshot()).requests.map(row => row.state), ['settled', 'settled']);
});
test('gateway: base64 with a null URL saves the original image without a download', async t => {
  const f = await fixture(t, 'openai-gpt-image', { nullImageUrl: true });
  const req = request('openai-gpt-image', { model: catalogModel('gpt-image-2.5-flare') });
  f.context.admission = await admitGeneration(req, f.context);
  const result = await generateMedia(req, f.context);
  assert.deepEqual(await readFile(result.meta.items[0].path), PNG);
  assert.deepEqual(f.wires.map(wire => wire.method), ['POST']);
  assert.equal(f.wires[0].body.model, 'gpt-image-2.5-flare');
  assert.equal((await createBudgetLedger(join(f.context.hostStateDir, 'budget')).snapshot()).requests[0].state, 'settled');
});
for (const profile of ['openai-gpt-image', 'ark-image', 'ali-wan-image', 'silicon-image']) {
  test(`${profile}: real HTTP generation saves exact original and private index with budget`, async t => {
    const f = await fixture(t, profile), req = request(profile);
    f.context.admission = await admitGeneration(req, f.context);
    const result = await generateMedia(req, f.context);
    assert.equal(result.meta.kind, 'image'); assert.equal(result.meta.status, 'done'); assert.equal(result.meta.cost, undefined);
    assert.deepEqual(await readFile(result.meta.items[0].path), PNG);
    const ledger = await createBudgetLedger(join(f.context.hostStateDir, 'budget')).snapshot();
    assert.equal(ledger.requests[0].state, 'settled');
    assert.equal(f.wires.filter(w => w.method === 'POST').length, 1);
    assert.ok(!JSON.stringify(result).includes('synthetic-key'));
  });
  test(`${profile}: edit sends the approved reference using the provider's documented field`, async t => {
    const f = await fixture(t, profile), path = join(f.workspace, 'reference.png'); await writeFile(path, PNG);
    const model = CATALOG.models.find(m => m.profile === profile && m.edit);
    const req = request(profile, { model, refs: [path] });
    await generateMedia(req, f.context);
    const wire = f.wires[0];
    assert.ok(JSON.stringify(wire.body).includes('data:image/png;base64,'));
    if (profile === 'openai-gpt-image') { assert.equal(wire.path, '/v1/images/edits'); assert.ok(wire.body.images[0].image_url); }
    if (profile === 'silicon-image') { assert.equal(wire.body.image_size, undefined); assert.equal(wire.body.model, model.id); }
  });
  test(`${profile}: accepted POST then socket drop is submission_unknown, never retried/refunded`, async t => {
    const f = await fixture(t, profile, { drop: true }), req = request(profile);
    f.context.admission = await admitGeneration(req, f.context);
    await assert.rejects(generateMedia(req, f.context), { code: 'submission_unknown' });
    assert.equal(f.wires.length, 1);
    const ledger = await createBudgetLedger(join(f.context.hostStateDir, 'budget')).snapshot();
    assert.equal(ledger.requests[0].state, 'submission_unknown');
  });
  test(`${profile}: explicit authentication rejection is not presented as retryable uncertainty`, async t => {
    const f = await fixture(t, profile, { reject: 401 });
    await assert.rejects(generateMedia(request(profile), f.context), { code: 'authentication' });
    assert.equal(f.wires.length, 1);
  });
  test(`${profile}: create timeout has an uncertain submission outcome`, async t => {
    const f = await fixture(t, profile, { stall: true });
    await assert.rejects(generateMedia(request(profile), f.context), { code: 'submission_unknown' });
    assert.equal(f.wires.length, 1);
  });
}
for (const profile of ['ark-video', 'ali-video', 'silicon-video']) {
  test(`${profile}: real HTTP async video downloads bounded MP4 and derives actual metadata`, async t => {
    const f = await fixture(t, profile), req = request(profile);
    f.context.admission = await admitGeneration(req, f.context);
    const result = await generateMedia(req, f.context);
    assert.equal(result.meta.kind, 'video'); assert.equal(result.meta.items[0].width, 32); assert.equal(result.meta.items[0].height, 24);
    assert.equal(result.meta.items[0].duration, 1); assert.equal(result.meta.items[0].codec, 'h264');
    assert.deepEqual(await readFile(result.meta.items[0].path), MP4);
    const downloaded = f.wires.find(w => w.path === '/original.mp4'); assert.equal(downloaded.auth, undefined);
    assert.equal(f.wires.filter(w => w.method === 'POST' && !w.path.endsWith('/status')).length, 1);
  });
  test(`${profile}: image-to-video uses a validated workspace reference`, async t => {
    const f = await fixture(t, profile), path = join(f.workspace, 'first.png'); await writeFile(path, PNG);
    const model = CATALOG.models.find(m => m.profile === profile && m.maxRefs);
    await generateMedia(request(profile, { model, refs: [path] }), f.context);
    assert.ok(JSON.stringify(f.wires[0].body).includes('data:image/png;base64,'));
    if (profile === 'ark-video') assert.equal(f.wires[0].body.ratio, 'adaptive');
    if (profile === 'ali-video') assert.equal(f.wires[0].body.input.media[0].type, 'first_frame');
  });
  test(`${profile}: cancellation uses actual transport and requires a confirmed provider cancel`, async t => {
    const f = await fixture(t, profile, { state: 'queued' });
    f.context.job = { id: 'media-test', updateProgress(line) { if (line.includes('排队')) f.controller.abort(); } };
    await assert.rejects(generateMedia(request(profile), f.context), { code: profile === 'silicon-video' ? 'remote_may_continue' : 'cancelled' });
    const cancels = f.wires.filter(w => w.method === 'DELETE' || w.path.endsWith('/cancel'));
    assert.equal(cancels.length, profile === 'silicon-video' ? 0 : 1);
    if (profile === 'ark-video') assert.equal(cancels[0].method, 'DELETE');
    if (profile === 'ali-video') assert.equal(cancels[0].path, '/api/v1/tasks/task-1/cancel');
  });
  test(`${profile}: running tasks do not claim remote cancellation`, async t => {
    const f = await fixture(t, profile, { state: 'running' });
    f.context.job = { id: 'media-test', updateProgress(line) { if (line === '视频正在生成') f.controller.abort(); } };
    await assert.rejects(generateMedia(request(profile), f.context), { code: 'remote_may_continue' });
    assert.equal(f.wires.filter(w => w.method === 'DELETE' || w.path.endsWith('/cancel')).length, 0);
  });
  test(`${profile}: confirmed failure differs from query outage`, async t => {
    const failed = await fixture(t, profile, { state: 'failed' });
    await assert.rejects(generateMedia(request(profile), failed.context), { code: 'generation_failed' });
    const outage = await fixture(t, profile, { queryError: true });
    await assert.rejects(generateMedia(request(profile), outage.context), { code: 'remote_may_continue' });
  });
  test(`${profile}: internal query timeout never reports confirmed cancellation`, async t => {
    const f = await fixture(t, profile, { queryStall: true });
    await assert.rejects(generateMedia(request(profile), f.context), { code: 'remote_may_continue' });
    assert.equal(f.controller.signal.aborted, false);
    assert.equal(f.wires.filter(w => w.method === 'DELETE' || w.path.endsWith('/cancel')).length, 0);
  });
  test(`${profile}: create timeout is unknown and not re-submitted`, async t => {
    const f = await fixture(t, profile, { stall: true });
    await assert.rejects(generateMedia(request(profile), f.context), { code: 'submission_unknown' }); assert.equal(f.wires.length, 1);
  });
}

for (const [name, secret] of [
  ['quote', 'MOCK_ONLY_SECRET_"_QUOTE'],
  ['backslash', 'MOCK_ONLY_SECRET_\\_SLASH'],
]) {
  test(`media engine rejects ${name}-escaped credential in prompt before submission`, async t => {
    const f = await fixture(t, 'openai-gpt-image');
    const req = request('openai-gpt-image', { prompt: 'draw ' + secret });
    f.context.resolveCredential = async () => secret;
    f.context.admission = await admitGeneration(req, f.context);
    await assert.rejects(generateMedia(req, f.context), { code: 'credential' });
    assert.equal(f.wires.length, 0);
    const ledger = await createBudgetLedger(join(f.context.hostStateDir, 'budget')).snapshot();
    assert.equal(ledger.requests.length, 1);
    assert.equal(ledger.requests[0].state, 'released');
    assert.deepEqual(await readdir(join(f.workspace, 'generated', f.context.admission.outputDate)), []);
    assert.deepEqual(await readdir(join(f.context.hostStateDir, 'works', f.context.admission.outputDate)), []);
  });
}

test('escaped oversized metadata is rejected before any provider POST', async t => {
  const f = await fixture(t, 'openai-gpt-image');
  await assert.rejects(generateMedia(request('openai-gpt-image', { prompt: '\t'.repeat(4000) + 'x' }), f.context), { code: 'metadata' });
  assert.equal(f.wires.length, 0);
});
test('reference symlinks, foreign files and named pipes are rejected before provider I/O', async t => {
  const f = await fixture(t, 'ark-image'), path = join(f.workspace, 'pipe');
  assert.equal(spawnSync('mkfifo', [path]).status, 0);
  await assert.rejects(readReferences([path], f.context), { code: 'invalid_request' });
  await assert.rejects(readReferences([join(f.directory, 'foreign.png')], f.context));
  assert.equal(f.wires.length, 0);
});
test('reference approval pins reject replacing the file after consent', async t => {
  const f = await fixture(t, 'ark-image'), path = join(f.workspace, 'reference.png'); await writeFile(path, PNG);
  const pins = []; await readReferences([path], { ...f.context, captureReference: pin => pins.push(pin) });
  await rename(path, path + '.old'); await writeFile(path, PNG);
  await assert.rejects(validateReferencePins(pins), { code: 'permission' });
});
test('unknown price needs exact approval and request exposes no fake estimate', async t => {
  const f = await fixture(t, 'ark-image'); let reason;
  f.context.approve = async text => { reason = text; return 'rejected'; };
  await assert.rejects(admitGeneration(request('ark-image', { refs: [join(f.workspace, 'private.png')] }), f.context), { code: 'approval_required' });
  assert.ok(reason.includes('private.png')); assert.ok(reason.includes('https://ark.cn-beijing.volces.com')); assert.ok(reason.includes('不是报价'));
  assert.equal(f.wires.length, 0);
  assert.equal((await createBudgetLedger(join(f.context.hostStateDir, 'budget')).snapshot()).requests.length, 0);
});
test('daily reservations reject a second request without exceeding configured local budget', async t => {
  const f = await fixture(t, 'ark-image'); const req = request('ark-image');
  await admitGeneration(req, f.context);
  await assert.rejects(admitGeneration(req, f.context), { code: 'budget_exceeded' });
  assert.equal(f.wires.length, 0);
});
test('settled-but-unpublished video recovers after process-local state loss without another POST', async t => {
  const f = await fixture(t, 'ark-video'), req = request('ark-video');
  const original = await admitGeneration(req, f.context); await original.begin(); await original.submitted('task-1'); await original.settle();
  const restored = await recoverAdmission(original.rid, f.context);
  assert.equal(restored.providerTaskId, 'task-1');
  const result = await generateMedia(restored.request, { ...f.context, admission: restored.admission, resumeTaskId: restored.providerTaskId });
  assert.equal(result.meta.status, 'done'); assert.equal(result.meta.rid, original.rid);
  assert.equal(f.wires.filter(w => w.method === 'POST').length, 0);
  const completed = await recoverAdmission(original.rid, f.context);
  assert.equal(completed.completed.meta.items[0].path, result.meta.items[0].path);
  await assert.rejects(recoverAdmission(original.rid, { ...f.context, sessionId: 'foreign' }), { code: 'permission' });
});
test('completed video recovery rejects a missing original without changing its index', async t => {
  const f = await fixture(t, 'ark-video'), req = request('ark-video');
  f.context.admission = await admitGeneration(req, f.context);
  const result = await generateMedia(req, f.context);
  const indexPath = join(f.context.hostStateDir, 'works', f.context.admission.outputDate, result.meta.rid + '.json');
  const index = await readFile(indexPath), original = await readFile(result.meta.items[0].path);
  const movedPath = result.meta.items[0].path + '.moved';
  await rename(result.meta.items[0].path, movedPath);
  await assert.rejects(recoverAdmission(result.meta.rid, f.context), { code: 'storage' });
  assert.deepEqual(await readFile(indexPath), index);
  assert.deepEqual(await readFile(movedPath), original);
});
test('submission_unknown without a task id never becomes a new create on recovery', async t => {
  const f = await fixture(t, 'ark-video'), admission = await admitGeneration(request('ark-video'), f.context); await admission.begin();
  await assert.rejects(recoverAdmission(admission.rid, f.context), { code: 'recovery_unavailable' }); assert.equal(f.wires.length, 0);
});
test('internal request timeouts retain timeout identity', () => {
  const controller = new AbortController(); controller.abort(new DOMException('deadline', 'TimeoutError'));
  assert.equal(abortError(controller.signal).code, 'timeout');
});
test('native descriptors use only catalog-whitelisted fields, defaults do not invent SiliconFlow duration', () => {
  const req = request('silicon-video'); const wire = createDescriptor(req);
  assert.equal(wire.body.duration, undefined); assert.equal(wire.body.resolution, undefined);
  assert.equal(wire.body.image_size, '1280x720');
  const services = [{ id: 'img', enabled: true, keyRef: 'KEY', models: 'gpt-image-2' }, { id: 'vid', enabled: true, keyRef: 'KEY', provider: 'ark', profile: 'ark-video', baseUrl: 'https://ark.cn-beijing.volces.com', models: modelFor('ark-video').id }];
  const snapshot = runtimeSnapshot(Config({ services, defaults: { serviceId: 'img', modelId: 'gpt-image-2' } }));
  assert.equal(selectedRequest({ prompt: 'cat' }, snapshot, snapshot.services, 'generate_video').request.service.id, 'vid');
  assert.equal(selectedRequest({ prompt: 'cat', serviceId: 'vid' }, snapshot, snapshot.services, 'generate_video').request.model.id, modelFor('ark-video').id);
  assert.throws(() => selectedRequest({ prompt: 'cat', seconds: 10 }, snapshot, [{ ...snapshot.services[1], profile: 'silicon-video', modelIds: [modelFor('silicon-video').id] }], 'generate_video'));
});

test('Seedream Pro never receives the Lite-only sequential parameter', () => {
  const wire = createDescriptor(request('ark-image'));
  assert.equal(wire.body.model, 'doubao-seedream-5-0-pro-260628');
  assert.equal(wire.body.sequential_image_generation, undefined);
});

test('process exit after publishing MP4 before index can resume with new names and zero creates', async t => {
  const f = await fixture(t, 'ark-video'), req = request('ark-video');
  const admission = await admitGeneration(req, f.context);
  await admission.begin(); await admission.submitted('task-1'); await admission.settle();
  const moduleUrl = path => new URL('../src/' + path, import.meta.url).href;
  const script = `
    import { existsSync, readdirSync } from 'node:fs';
    import { join } from 'node:path';
    import { recoverAdmission } from ${JSON.stringify(moduleUrl('budget.js'))};
    import { generateMedia } from ${JSON.stringify(moduleUrl('media-engine.js'))};
    import { createMediaClient } from ${JSON.stringify(moduleUrl('adapters.js'))};
    import { createHttpTransport } from ${JSON.stringify(moduleUrl('http.js'))};
    import { createStreamStager } from ${JSON.stringify(moduleUrl('stream-staging.js'))};
    const workspace = ${JSON.stringify(f.workspace)}, hostStateDir = ${JSON.stringify(f.context.hostStateDir)};
    const origin = ${JSON.stringify(f.origin)}, rid = ${JSON.stringify(admission.rid)};
    const dated = join(workspace, 'generated', ${JSON.stringify(admission.outputDate)});
    const authorizeWorkspace = async () => {
      if (existsSync(dated) && readdirSync(dated).some(p => p.endsWith('.mp4'))) process.exit(77);
      return { cwd: workspace, workspaceRoot: workspace, mode: 'workspace-write' };
    };
    const local = createHttpTransport({ allowLoopback: true });
    const transport = (url, options) => local(origin + new URL(url).pathname, options);
    const context = { signal: new AbortController().signal, hostStateDir, sessionId: 'session-1',
      authorizeWorkspace, resolveCredential: async () => 'synthetic-key-not-real', limits: ${JSON.stringify(HARD_LIMITS)},
      client: createMediaClient({ transport }), transport,
      stageDownload: (url, options) => createStreamStager({ allowLoopback: true })(origin + new URL(url).pathname, options) };
    const saved = await recoverAdmission(rid, context);
    await generateMedia(saved.request, { ...context, admission: saved.admission, resumeTaskId: saved.providerTaskId });
    process.exit(9);
  `;
  const child = spawn(process.execPath, ['--input-type=module', '-e', script], { stdio: ['ignore', 'ignore', 'pipe'] });
  let stderr = ''; child.stderr.on('data', bytes => { stderr += bytes; });
  const [code] = await once(child, 'exit'); assert.equal(code, 77, stderr);
  const directory = join(f.workspace, 'generated', admission.outputDate);
  const orphan = (await readdir(directory)).find(name => name.endsWith('.mp4'));
  assert.ok(orphan); assert.deepEqual(await readFile(join(directory, orphan)), MP4);
  const restored = await recoverAdmission(admission.rid, f.context); assert.equal(restored.completed, undefined);
  const result = await generateMedia(restored.request, { ...f.context, admission: restored.admission, resumeTaskId: restored.providerTaskId });
  assert.equal(result.meta.status, 'done'); assert.notEqual(result.meta.items[0].path, join(directory, orphan));
  assert.deepEqual(await readFile(join(directory, orphan)), MP4);
  assert.equal((await recoverAdmission(admission.rid, f.context)).completed.meta.rid, admission.rid);
  assert.equal(f.wires.filter(w => w.method === 'POST').length, 0);
});

const defaultImageRow = {
  id: 'img', enabled: true, keyRef: 'DSH_MEDIA_ARK_API_KEY',
  provider: 'openai', baseUrl: 'https://api.openai.com/v1',
  profile: 'openai-gpt-image', models: 'gpt-image-2,gpt-image-2.5-flare',
};
const defaultVideoRow = {
  id: 'vid', enabled: true, keyRef: 'DSH_MEDIA_ARK_API_KEY',
  provider: 'ark', baseUrl: 'https://ark.cn-beijing.volces.com',
  profile: 'ark-video', models: 'doubao-seedance-2-5-260628',
};
const defaultSnapshot = defaults => runtimeSnapshot(Config({
  services: [defaultImageRow, defaultVideoRow], defaults,
}));

test('per-kind defaults select the image or video target and model', () => {
  const snapshot = defaultSnapshot({
    serviceId: 'vid', modelId: 'doubao-seedance-2-5-260628',
    imageServiceId: 'img', imageModelId: 'gpt-image-2.5-flare',
    videoServiceId: 'vid', videoModelId: 'doubao-seedance-2-5-260628',
  });
  const image = selectedRequest({ prompt: '猫' }, snapshot, snapshot.services, 'generate_image');
  assert.equal(image.request.service.id, 'img');
  assert.equal(image.request.model.id, 'gpt-image-2.5-flare');
  const edit = selectedRequest({ prompt: '猫', refs: ['/work/reference.png'] }, snapshot, snapshot.services, 'edit_image');
  assert.equal(edit.request.service.id, 'img');
  assert.equal(edit.request.model.id, 'gpt-image-2.5-flare');
  const video = selectedRequest({ prompt: '猫' }, snapshot, snapshot.services, 'generate_video');
  assert.equal(video.request.service.id, 'vid');
  assert.equal(video.request.model.id, 'doubao-seedance-2-5-260628');
});

test('invalid per-kind defaults fall back to the legacy pair and then the first candidate', () => {
  const snapshot = defaultSnapshot({
    serviceId: 'img', modelId: 'gpt-image-2',
    imageServiceId: 'removed', imageModelId: 'removed-model',
    videoServiceId: 'removed', videoModelId: 'removed-model',
  });
  const image = selectedRequest({ prompt: '猫' }, snapshot, snapshot.services, 'generate_image');
  assert.equal(image.request.service.id, 'img');
  assert.equal(image.request.model.id, 'gpt-image-2');
  const video = selectedRequest({ prompt: '猫' }, snapshot, snapshot.services, 'generate_video');
  assert.equal(video.request.service.id, 'vid');
  assert.equal(video.request.model.id, 'doubao-seedance-2-5-260628');
  // A kind service that exists but cannot serve this tool falls back silently.
  const unsupported = defaultSnapshot({ videoServiceId: 'img' });
  assert.equal(selectedRequest({ prompt: '猫' }, unsupported, unsupported.services, 'generate_video')
    .request.service.id, 'vid');
});

test('legacy-only defaults keep the old selection and fail-closed behavior', () => {
  const snapshot = defaultSnapshot({ serviceId: 'img', modelId: 'gpt-image-2.5-flare' });
  const image = selectedRequest({ prompt: '猫' }, snapshot, snapshot.services, 'generate_image');
  assert.equal(image.request.service.id, 'img');
  assert.equal(image.request.model.id, 'gpt-image-2.5-flare');
  // The legacy service is ready but cannot serve video, so selection moves on.
  const video = selectedRequest({ prompt: '猫' }, snapshot, snapshot.services, 'generate_video');
  assert.equal(video.request.service.id, 'vid');
  assert.equal(video.request.model.id, 'doubao-seedance-2-5-260628');
  // A missing legacy target still fails closed instead of silently changing service.
  const missing = defaultSnapshot({ serviceId: 'gone', modelId: 'gpt-image-2' });
  assert.throws(() => selectedRequest({ prompt: '猫' }, missing, missing.services, 'generate_image'),
    error => error.code === 'not_configured');
  // Explicit arguments still win over every default.
  const explicit = selectedRequest({ prompt: '猫', serviceId: 'vid' }, snapshot, snapshot.services, 'generate_video');
  assert.equal(explicit.request.service.id, 'vid');
});

for (const [phase, profile, errorCode] of [
  ['create', 'ark-image', 'OutputImageSensitiveContentDetected'],
  ['create', 'ark-video', 'InputImageSensitiveContentDetected'],
  ['query', 'ark-video', 'InputTextSensitiveContentDetected'],
]) {
  test(`${profile}: ${phase} moderation reports policy and keeps the submitted budget hold`, async t => {
    const f = await fixture(t, profile, { state: 'failed', error: { code: errorCode },
      ...(phase === 'create' ? { reject: 400 } : {}) });
    const req = request(profile);
    f.context.admission = await admitGeneration(req, f.context);
    await assert.rejects(generateMedia(req, f.context), { code: 'policy' });
    assert.deepEqual(f.wires.map(wire => wire.method), phase === 'create' ? ['POST'] : ['POST', 'GET']);
    const ledger = await createBudgetLedger(join(f.context.hostStateDir, 'budget')).snapshot();
    assert.equal(ledger.requests.length, 1);
    const record = ledger.requests[0];
    assert.equal(record.state, phase === 'create' ? 'submission_unknown' : 'submitted');
    assert.equal(record.providerTaskId, phase === 'create' ? undefined : 'task-1');
    assert.equal(record.estimateMicros, f.context.budget.unknownHoldMicros);
    assert.deepEqual(await readdir(join(f.workspace, 'generated', record.outputDate)), []);
  });
}
