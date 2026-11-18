import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, readFile, lstat, readlink, symlink, statfs, chmod, rm, open } from 'node:fs/promises';
import { tmpdir, constants, release } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { spawn } from 'node:child_process';

const require = createRequire(import.meta.url);
const self = fileURLToPath(import.meta.url);
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const errorInfo = error => ({ name: error.name, code: error.code, errno: error.errno, syscall: error.syscall, message: error.message });
const identity = info => `${info.dev}:${info.ino}:${info.mode}`;

if (!isMainThread) {
  const { renameNoReplace } = require(workerData.addon);
  const gate = new Int32Array(workerData.gate);
  parentPort.postMessage({ type: 'ready' });
  Atomics.wait(gate, 0, 0);
  try { renameNoReplace(workerData.source, workerData.target); parentPort.postMessage({ type: 'result', ok: true }); }
  catch (error) { parentPort.postMessage({ type: 'result', ok: false, error: errorInfo(error) }); }
} else if (process.argv[2] === '--permission-child') {
  const [addon, source, target] = process.argv.slice(3);
  const { renameNoReplace } = require(addon);
  if (process.getuid() === 0) { process.setgid(65534); process.setuid(65534); }
  try { renameNoReplace(source, target); console.log(JSON.stringify({ ok: true, uid: process.getuid() })); }
  catch (error) { console.log(JSON.stringify({ ok: false, uid: process.getuid(), error: errorInfo(error) })); }
} else {
  assert.equal(process.version, 'v24.22.1');
  const addon = resolve(process.env.M3_PUBLICATION_ADDON || '');
  assert.ok(process.env.M3_PUBLICATION_ADDON, 'M3_PUBLICATION_ADDON required');
  const expectedSHA = process.env.M3_PUBLICATION_SHA256 || '2870d10332dd2bdb34102ac35de8d8e423592017cf4889a190ecf08ee941e823';
  const addonSHA = digest(await readFile(addon)); assert.equal(addonSHA, expectedSHA);
  const { renameNoReplace } = require(addon);
  const root = await mkdtemp(join(tmpdir(), 'm3-native-boundaries-'));
  const rows = [];
  const fixture = async name => { const path = join(root, name); await mkdir(path); return path; };
  const noFile = path => assert.rejects(lstat(path), { code: 'ENOENT' });
  const synced = async (path, bytes) => { const handle = await open(path, 'wx', 0o600); try { await handle.writeFile(bytes); await handle.sync(); } finally { await handle.close(); } };
  const expectError = (source, target, code) => {
    let found;
    assert.throws(() => renameNoReplace(source, target), error => {
      found = errorInfo(error);
      assert.equal(error.code, code); assert.equal(error.errno, -constants.errno[code]); assert.equal(error.syscall, 'renameat2');
      assert.ok(!error.message.includes(source) && !error.message.includes(target), 'native message omits paths');
      return true;
    });
    return found;
  };
  const check = (name, fn) => test(name, async () => {
    try { const result = await fn(); rows.push({ name, pass: true, ...result }); }
    catch (error) { rows.push({ name, pass: false, error: errorInfo(error) }); throw error; }
  });

  check('success moves one complete inode and returns undefined', async () => {
    const dir = await fixture('success'), source = join(dir, '临时😀'), target = join(dir, '完成中');
    const bytes = Buffer.alloc(196625, 0x72); await synced(source, bytes);
    const before = identity(await lstat(source));
    assert.equal(renameNoReplace(source, target), undefined);
    assert.equal(identity(await lstat(target)), before); assert.deepEqual(await readFile(target), bytes); await noFile(source);
    return { bytes: bytes.length, finalSHA256: digest(bytes), sourceGone: true };
  });

  for (const kind of ['empty', 'ordinary', 'directory', 'symlink', 'dangling-symlink']) check(`existing ${kind}: EEXIST preserves both paths and referent`, async () => {
    const dir = await fixture(kind), source = join(dir, 'stage'), target = join(dir, 'final'), referent = join(dir, 'referent');
    const staged = Buffer.alloc(131089, 0x73); await synced(source, staged);
    if (kind === 'empty') await writeFile(target, '');
    if (kind === 'ordinary') await writeFile(target, 'prior owner');
    if (kind === 'directory') { await mkdir(target); await writeFile(join(target, 'child'), 'prior child'); }
    if (kind === 'symlink') { await writeFile(referent, 'referent must survive'); await symlink('referent', target); }
    if (kind === 'dangling-symlink') await symlink('absent referent', target);
    const before = identity(await lstat(target));
    const error = expectError(source, target, 'EEXIST');
    assert.equal(identity(await lstat(target)), before); assert.deepEqual(await readFile(source), staged);
    if (kind === 'empty') assert.equal((await lstat(target)).size, 0);
    if (kind === 'ordinary') assert.equal(await readFile(target, 'utf8'), 'prior owner');
    if (kind === 'directory') assert.equal(await readFile(join(target, 'child'), 'utf8'), 'prior child');
    if (kind === 'symlink') { assert.equal(await readlink(target), 'referent'); assert.equal(await readFile(referent, 'utf8'), 'referent must survive'); }
    if (kind === 'dangling-symlink') { assert.equal(await readlink(target), 'absent referent'); await noFile(join(dir, 'absent referent')); }
    return { error, sourceSHA256: digest(staged), destinationIdentityUnchanged: true };
  });

  check('two waiting isolates submit together: one success, one EEXIST', async () => {
    const dir = await fixture('race'), target = join(dir, 'final');
    const sources = [join(dir, 'a.stage'), join(dir, 'b.stage')];
    const bytes = [Buffer.alloc(196625, 0x61), Buffer.alloc(262161, 0x62)];
    for (let index = 0; index < sources.length; index++) await synced(sources[index], bytes[index]);
    const gate = new SharedArrayBuffer(4), workers = [], ready = [], results = [];
    try {
      for (let index = 0; index < 2; index++) {
        const worker = new Worker(new URL(import.meta.url), { workerData: { addon, gate, source: sources[index], target }, execArgv: process.execArgv.filter(x => x === '--jitless') });
        workers.push(worker);
        let readyResolve, resultResolve, readyReject, resultReject;
        ready.push(new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; }));
        results.push(new Promise((resolve, reject) => { resultResolve = resolve; resultReject = reject; }));
        worker.on('message', message => { if (message.type === 'ready') readyResolve(); else if (message.type === 'result') resultResolve(message); });
        worker.on('error', error => { readyReject(error); resultReject(error); });
      }
      const timeout = setTimeout(() => workers.forEach(worker => worker.terminate()), 10000);
      let observed;
      try {
        await Promise.all(ready); Atomics.store(new Int32Array(gate), 0, 1); Atomics.notify(new Int32Array(gate), 0, 2);
        observed = await Promise.all(results);
      } finally { clearTimeout(timeout); }
      assert.equal(observed.filter(value => value.ok).length, 1);
      const winner = observed.findIndex(value => value.ok), loser = 1 - winner;
      assert.equal(observed[loser].error.code, 'EEXIST'); assert.equal(observed[loser].error.errno, -constants.errno.EEXIST);
      assert.deepEqual(await readFile(target), bytes[winner]); await noFile(sources[winner]); assert.deepEqual(await readFile(sources[loser]), bytes[loser]);
      return { observed, winner, finalSHA256: digest(await readFile(target)), loserStageRetained: true };
    } finally { await Promise.all(workers.map(worker => worker.terminate())); }
  });

  check('missing source: actual ENOENT, no final copy', async () => {
    const dir = await fixture('missing'), source = join(dir, 'absent'), target = join(dir, 'final');
    const error = expectError(source, target, 'ENOENT'); await noFile(source); await noFile(target); return { error };
  });
  check('non-directory target parent: actual ENOTDIR, stage retained', async () => {
    const dir = await fixture('notdir'), source = join(dir, 'stage'), parent = join(dir, 'parent');
    await synced(source, Buffer.from('complete')); await writeFile(parent, 'not directory');
    const error = expectError(source, join(parent, 'final'), 'ENOTDIR'); assert.equal(await readFile(source, 'utf8'), 'complete'); return { error };
  });
  check('cross-mounted filesystem: actual EXDEV, not EINVAL and no fallback', async () => {
    const dir = await fixture('cross-device'), source = join(dir, 'stage');
    const targetDir = await mkdtemp(join(process.env.M3_OTHER_FILESYSTEM || '/dev/shm', 'm3-native-boundaries-'));
    try {
      const target = join(targetDir, 'final'); const sourceDev = (await lstat(dir)).dev, targetDev = (await lstat(targetDir)).dev;
      assert.notEqual(sourceDev, targetDev, 'fixture must use distinct real filesystems'); await synced(source, Buffer.from('complete cross-device stage'));
      const error = expectError(source, target, 'EXDEV'); assert.equal(await readFile(source, 'utf8'), 'complete cross-device stage'); await noFile(target);
      return { error, sourceDev, targetDev, targetAbsent: true };
    } finally { await rm(targetDir, { recursive: true, force: true }); }
  });
  check('denied directory: actual EACCES as an unprivileged caller', async () => {
    const dir = await fixture('permission'), sourceDir = join(dir, 'writable'), targetDir = join(dir, 'denied');
    await chmod(root, 0o755); await chmod(dir, 0o755); await mkdir(sourceDir, { mode: 0o777 }); await chmod(sourceDir, 0o777); await mkdir(targetDir); await chmod(targetDir, 0);
    const source = join(sourceDir, 'stage'), target = join(targetDir, 'final'); await synced(source, Buffer.from('permission stage'));
    try {
      const child = spawn(process.execPath, [self, '--permission-child', addon, source, target], { stdio: ['ignore', 'pipe', 'pipe'] });
      let stdout = '', stderr = ''; child.stdout.on('data', data => { stdout += data; }); child.stderr.on('data', data => { stderr += data; });
      const timeout = setTimeout(() => child.kill('SIGKILL'), 10000);
      const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); }).finally(() => clearTimeout(timeout));
      assert.equal(status.code, 0, stderr); assert.equal(status.signal, null);
      const result = JSON.parse(stdout); assert.equal(result.ok, false); assert.notEqual(result.uid, 0); assert.equal(result.error.code, 'EACCES'); assert.equal(result.error.errno, -constants.errno.EACCES); assert.equal(result.error.syscall, 'renameat2');
      assert.equal(await readFile(source, 'utf8'), 'permission stage'); await chmod(targetDir, 0o700); await noFile(target);
      return result;
    } finally { await chmod(targetDir, 0o700); }
  });
  check('invalid argument type and embedded NUL do not reach a truncated path', async () => {
    const dir = await fixture('args'), source = join(dir, 'stage'), target = join(dir, 'final'); await synced(source, Buffer.from('complete'));
    for (const args of [[], [source], [null, target], [source, 1], [Buffer.from(source), target]]) assert.throws(() => renameNoReplace(...args), { code: 'ERR_INVALID_ARG_TYPE' });
    for (const args of [[source + '\0suffix', target], [source, target + '\0suffix']]) assert.throws(() => renameNoReplace(...args), { code: 'ERR_INVALID_ARG_VALUE' });
    assert.equal(await readFile(source, 'utf8'), 'complete'); await noFile(target); return { rejectedTypeCases: 5, rejectedNulCases: 2 };
  });

  after(async () => {
    const report = { scope: 'Real Linux thin native binding only; no OHOS device claim, no JS publication recovery or fallback-policy claim.', addonSHA256: addonSHA, testSHA256: digest(await readFile(self)), node: process.version, platform: process.platform, arch: process.arch, kernel: release(), fixtureFilesystemType: Number((await statfs(root)).type), pass: rows.filter(row => row.pass).length, fail: rows.filter(row => !row.pass).length, rows };
    const output = process.env.M3_NATIVE_REPORT;
    if (output) { await mkdir(dirname(resolve(output)), { recursive: true }); await writeFile(output, JSON.stringify(report, null, 2) + '\n'); }
    await rm(root, { recursive: true, force: true });
  });
}
