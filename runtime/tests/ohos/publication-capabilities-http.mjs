// Coordinator runs outside O0; its real DSH children run under the strict O0
// preload, actual locked dependencies, and the current publication service.
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: Object.fromEntries(
  ['tree', 'prefix', 'linked', 'native-library-dir', 'out', 'base-profile'].map(name => [name, { type: 'string' }])) });
for (const name of ['tree', 'prefix', 'linked', 'native-library-dir', 'out', 'base-profile']) {
  if (!values[name]) throw new Error('Missing --' + name);
}
const tree = resolve(values.tree), out = resolve(values.out), prefix = resolve(values.prefix);
const here = fileURLToPath(new URL('.', import.meta.url));
const linked = resolve(values.linked), nativeLibraries = resolve(values['native-library-dir']), profile = resolve(values['base-profile']);
const addons = ['libdsh_require_builtin.so', 'libdsh_flock.so'].map(name => join(nativeLibraries, name));
const entry = join(prefix, 'node_modules/@deepseek-ai/dsh/lib/bin.js');
await mkdir(out, { recursive: false });
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const rows = [];
const route = '/dsh-go/v1/runtime-capabilities';
const { capabilities: subprocessCapabilities } = await import(pathToFileURL(join(tree, 'runtime/ohos/process/commands.mjs')));

function exchange(base, { path = route, method = 'GET', cookie, headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(new URL(path, base), { method, headers: { ...(cookie ? { Cookie: cookie } : {}), ...headers } }, res => {
      const chunks = []; let size = 0;
      res.on('data', bytes => { size += bytes.length; if (size > 65536) res.destroy(new Error('test response limit')); else chunks.push(bytes); });
      res.on('error', reject);
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject); req.setTimeout(10000, () => req.destroy(new Error('test HTTP timeout'))); req.end();
  });
}
function environment(home) {
  return { PATH: process.env.PATH, LANG: 'C.UTF-8', DSH_HOME: home, DSH_PERMISSION_MODE: 'workspace-write',
    DSH_GO_OHOS_SIM_PLATFORM: 'openharmony', DSH_GO_OHOS_SIM_ADDONS: JSON.stringify(addons),
    DSH_GO_OHOS_NATIVE_LIBRARY_DIR: nativeLibraries, NARB_DISABLE_NATIVE_CACHE: '1', LD_PRELOAD: linked };
}
async function snapshot(home) {
  const value = {};
  for (const name of ['atomic-state.json', 'ledger.json']) {
    const path = join(home, 'ohos-ownership', name);
    try {
      const info = await stat(path, { bigint: true });
      value[name] = { sha256: digest(await readFile(path)), inode: String(info.ino),
        device: String(info.dev), size: String(info.size), mtimeNs: String(info.mtimeNs) };
    } catch (error) { if (error.code === 'ENOENT') value[name] = null; else throw error; }
  }
  return value;
}
async function armAndKill(directory, home) {
  const barrier = join(directory, 'trying-barrier.json');
  const command = ['--jitless', '--import', join(tree, 'runtime/ohos/sim/preload.mjs'),
    join(here, 'publication-capabilities-arm.mjs'), tree, home, barrier];
  const child = spawn(process.execPath, command, { env: environment(home), stdio: ['ignore', 'pipe', 'pipe'] });
  let log = ''; child.stdout.on('data', x => { log += x; }); child.stderr.on('data', x => { log += x; });
  const closed = new Promise(resolve => child.once('close', (code, signal) => resolve({ code, signal })));
  try {
    const deadline = Date.now() + 10000;
    while (true) {
      try { await stat(barrier); break; } catch (error) { if (error.code !== 'ENOENT') throw error; }
      if (child.exitCode !== null || child.signalCode !== null || Date.now() > deadline) throw new Error('trying barrier not reached');
      await pause(10);
    }
    const state = JSON.parse(await readFile(join(home, 'ohos-ownership/atomic-state.json'), 'utf8'));
    assert.equal(state.state, 'trying');
    child.kill('SIGKILL');
    const exit = await closed; assert.equal(exit.signal, 'SIGKILL');
    return { command, barrier: JSON.parse(await readFile(barrier, 'utf8')), state, exit,
      afterDeath: await snapshot(home) };
  } finally {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    await closed; await writeFile(join(directory, 'arm-process.log'), log);
  }
}

for (const name of ['before-route', 'available', 'unsupported', 'disabled-after-crash']) {
  const directory = join(out, name), home = join(directory, 'home'), workspace = join(directory, 'workspace');
  await mkdir(directory); await mkdir(home, { mode: 0o700 }); await mkdir(workspace);
  const row = { case: name, assertions: [], status: 'FAIL' };
  rows.push(row);
  let child, closed, log = '', launchToken, cookie;
  try {
    if (name === 'disabled-after-crash') row.preparation = await armAndKill(directory, home);
    const profilePath = join(directory, 'capabilities.patch.yml');
    await writeFile(profilePath, JSON.stringify(name === 'before-route' ? [] : [{ insert: [{
      id: 'ohos-runtime-capabilities', name: pathToFileURL(join(tree, 'runtime/ohos/capabilities/index.mjs')).href,
    }] }], null, 2));
    const command = ['--jitless', '--import', join(tree, 'runtime/ohos/sim/preload.mjs'),
      '--import', join(here, 'publication-capabilities-test-preload.mjs'),
      '--import', join(tree, 'runtime/ohos/preload.mjs'), entry, 'web', '--patch', profile,
      '--patch', profilePath, '--host', '127.0.0.1', '--port', '0', '--no-open'];
    row.command = [process.execPath, ...command];
    child = spawn(process.execPath, command, { cwd: workspace,
      env: { ...environment(home), ...(name === 'unsupported' ? { M6_TEST_RENAME_RESULT: 'EINVAL' } : {}) },
      stdio: ['ignore', 'pipe', 'pipe', 'ipc'] });
    closed = new Promise(resolve => child.once('close', (code, signal) => resolve({ code, signal })));
    const ready = Promise.withResolvers();
    const timer = setTimeout(() => ready.reject(new Error('DSH readiness deadline')), 45000);
    const consume = bytes => {
      log += bytes;
      if (log.length > 4 * 1024 * 1024) ready.reject(new Error('engine log limit'));
      const match = /dsh web: (http:\/\/127\.0\.0\.1:\d+\/\?token=[A-Za-z0-9_-]+)/u.exec(log);
      if (match) ready.resolve(new URL(match[1]));
    };
    child.stdout.on('data', consume); child.stderr.on('data', consume);
    child.once('error', ready.reject); child.once('exit', (code, signal) => ready.reject(new Error(`DSH exited before readiness: ${code ?? signal}`)));
    let launch;
    try { launch = await ready.promise; } finally { clearTimeout(timer); }
    launchToken = launch.searchParams.get('token');
    const login = await exchange(launch.origin, { path: launch.pathname + launch.search });
    assert.equal(login.status, 303);
    cookie = login.headers['set-cookie']?.find(value => value.startsWith('dsh-auth-'))?.split(';')[0];
    assert.ok(cookie);
    const base = launch.origin;
    const invoke = (operation, extra = {}) => new Promise((resolve, reject) => {
      const id = randomUUID(), timeout = setTimeout(() => { child.off('message', onMessage); reject(new Error('test IPC deadline')); }, 15000);
      function onMessage(message) {
        if (message.id !== id) return;
        clearTimeout(timeout); child.off('message', onMessage);
        if (message.ok) resolve(message); else reject(Object.assign(new Error('test service operation failed'), { detail: message }));
      }
      child.on('message', onMessage); child.send({ id, operation, ...extra });
    });
    if (name === 'before-route') {
      const response = await exchange(base, { cookie });
      assert.equal(response.status, 404);
      row.assertions.push('same real DSH without the new plugin returns authenticated 404');
      row.status = 'PASS_EXPECTED_BEFORE_FAILURE';
      continue;
    }
    for (const [label, options, statuses] of [
      ['no cookie', {}, [401, 403]], ['invalid cookie', { cookie: 'dsh-auth-invalid=invalid' }, [401, 403]],
      ['bad Origin', { cookie, headers: { Origin: 'https://invalid.example' } }, [403]],
      ['bad Host', { cookie, headers: { Host: 'invalid.example' } }, [403]],
      ['POST', { cookie, method: 'POST' }, [405]], ['HEAD', { cookie, method: 'HEAD' }, [405]],
    ]) {
      const response = await exchange(base, options); assert.ok(statuses.includes(response.status), label + ':' + response.status);
      assert.ok(!response.body.includes('systemVersion') && !response.body.includes('publication'));
      row.assertions.push(label + ' rejected ' + response.status);
    }
    const initial = await exchange(base, { cookie }); assert.equal(initial.status, 200);
    assert.equal(initial.headers['cache-control'], 'no-store');
    assert.equal(initial.headers['content-type'], 'application/json; charset=utf-8');
    const first = JSON.parse(initial.body);
    assert.equal(first.v, 1); assert.equal(first.platform, 'openharmony'); assert.equal(first.arch, process.arch);
    assert.equal(first.nodeVersion, process.versions.node); assert.equal(first.simulated, true); assert.equal(typeof first.bootId, 'string');
    assert.equal(first.shell.kind, 'virtual');
    assert.deepEqual(first.shell.commands, subprocessCapabilities.commands);
    assert.equal(first.shell.pty, 'unsupported');
    assert.equal(first.processSpawn, 'unsupported');
    assert.equal(first.nodeScripts, subprocessCapabilities.nodeScripts);
    assert.equal(first.python, 'unsupported'); assert.equal(first.wasm, 'unsupported');
    assert.deepEqual(first.plugins, { bundled: 'supported', marketInstall: 'supported' });
    assert.equal(first.nativeModules, null);
    assert.deepEqual(first.storage, { sessionLock: 'main-thread' });
    assert.deepEqual(first.background, { policy: 'may-freeze', computePermission: 'unknown', resume: 'none' });
    row.assertions.push('O6 reads the live Cordis backend/command table and JSONL main-thread lock marker');
    assert.equal(first.publication.atomic, name === 'disabled-after-crash' ? name : 'untried');
    row.initial = first;
    const beforeRead = await snapshot(home), observedBefore = await invoke('observe');
    for (let i = 0; i < 21; i++) {
      const response = await exchange(base, { cookie }); assert.equal(response.status, 200);
      assert.deepEqual(JSON.parse(response.body), first);
    }
    assert.deepEqual(await snapshot(home), beforeRead);
    assert.equal((await invoke('observe')).nativeCalls, observedBefore.nativeCalls);
    row.assertions.push('21 authenticated reads preserve state/ledger inode/hash/mtime and native-call count');
    const source = join(workspace, 'source'), target = join(workspace, 'published');
    await writeFile(source, 'complete publication fixture\n');
    const published = await invoke('publish', { source, target });
    assert.equal(await readFile(target, 'utf8'), 'complete publication fixture\n');
    const after = JSON.parse((await exchange(base, { cookie })).body);
    assert.equal(after.publication.atomic, name); assert.equal(after.bootId, first.bootId);
    assert.equal(after.publication.systemVersion, first.publication.systemVersion);
    assert.equal(published.nativeCalls, name === 'disabled-after-crash' ? 0 : 1);
    assert.equal(published.result.method, name === 'available' ? 'rename-noreplace' : 'exclusive-copy-fallback');
    row.final = after; row.operation = published;
    row.assertions.push('HTTP dynamically reports the actual completed service state and publication method');
    if (name === 'disabled-after-crash') {
      assert.equal(after.publication.systemVersion, row.preparation.state.systemVersion);
      row.assertions.push('actual SIGKILL after durable trying; same-home DSH restart persists disabled and skips native');
    }
    row.status = 'PASS';
  } catch (error) { row.error = { name: error.name, message: error.message, code: error.code, detail: error.detail, stack: error.stack }; }
  finally {
    if (child) {
      if (child.exitCode === null && child.signalCode === null) {
        const force = setTimeout(() => child.kill('SIGKILL'), 5000); child.kill('SIGTERM'); await closed; clearTimeout(force);
      }
      row.engineExit = await closed;
    }
    if (launchToken) log = log.replaceAll(launchToken, '<launch-token>');
    if (cookie) log = log.replaceAll(cookie, '<session-cookie>');
    log = log.replace(/([?&]token=)[^\s\x1b]+/gu, '$1<redacted>');
    await writeFile(join(directory, 'engine.log'), log);
    await writeFile(join(out, 'progress.json'), JSON.stringify(rows, null, 2) + '\n');
    console.log(name, row.status);
  }
}
const inputs = [process.execPath, linked, ...addons, entry, profile,
  join(tree, 'runtime/ohos/capabilities/index.mjs'), join(tree, 'runtime/ohos/publication/capabilities.mjs'),
  join(tree, 'runtime/ohos/capabilities/snapshot.mjs'), join(tree, 'runtime/ohos/process/commands.mjs'),
  join(tree, 'runtime/ohos/publication/index.mjs'), join(tree, 'runtime/ohos/publication/atomic-fuse.mjs'),
  join(tree, 'runtime/ohos/publication/ledger.mjs'), join(tree, 'runtime/ohos/publication/atomic.mjs'),
  fileURLToPath(import.meta.url), join(here, 'publication-capabilities-arm.mjs'), join(here, 'publication-capabilities-test-preload.mjs')];
const report = { scope: 'Real locked DSH/Cordis/connection and authenticated HTTP under Linux O0; explicit deviceinfo fixture and EINVAL fault injection; no target device or Dart claim',
  inputSHA256: Object.fromEntries(await Promise.all(inputs.map(async path => [path, digest(await readFile(path))]))),
  counts: { cases: rows.length, passed: rows.filter(row => row.status.startsWith('PASS')).length,
    failed: rows.filter(row => row.status === 'FAIL').length }, cases: rows };
await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report.counts));
if (report.counts.failed) process.exitCode = 1;
