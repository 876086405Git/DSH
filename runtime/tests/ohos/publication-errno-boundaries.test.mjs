import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { chmodSync } from 'node:fs';
import { createRequire } from 'node:module';
import { createHash, randomUUID } from 'node:crypto';
import { tmpdir, constants } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
const self = fileURLToPath(import.meta.url), require = createRequire(import.meta.url);
const addon = resolve(process.env.M3_PUBLICATION_ADDON || '');
const moduleFile = resolve(process.env.M3_PUBLICATION_MODULE || '');
assert.ok(process.env.M3_PUBLICATION_ADDON && process.env.M3_PUBLICATION_MODULE, 'explicit native and core paths required');
const sha = value => createHash('sha256').update(value).digest('hex');
const addonSHA = sha(await fs.readFile(addon)), moduleSHA = sha(await fs.readFile(moduleFile));
assert.equal(addonSHA, process.env.M3_PUBLICATION_SHA256 || '2870d10332dd2bdb34102ac35de8d8e423592017cf4889a190ecf08ee941e823');
const native = require(addon), { renameNoReplace } = native, { createAtomicPublisher } = await import(pathToFileURL(moduleFile));
const { openOwnershipLedger } = await import(new URL('ledger.mjs', pathToFileURL(moduleFile)));
const openLedger = directory => openOwnershipLedger({ directory, ownerId: randomUUID(), lockExclusive: native.lockExclusive,
  setOwnershipMarker: native.setOwnershipMarker, getOwnershipMarker: native.getOwnershipMarker });
const info = error => ({ name: error.name, code: error.code, errno: error.errno, syscall: error.syscall, message: error.message });
const deniedLink = async () => { throw Object.assign(new Error('fixture: hard links unavailable'), { code: 'EACCES' }); };

if (process.argv[2] === '--permission-child') {
  const [source, target] = process.argv.slice(3);
  if (process.getuid() === 0) { process.setgid(65534); process.setuid(65534); }
  let fallbackCount = 0, nativeCalls = 0;
  const home = await fs.mkdtemp(join(tmpdir(), 'm3-publisher-ledger-'));
  const ledger = await openLedger(join(home, 'ownership'));
  const publish = createAtomicPublisher({ ledger, fs: { ...fs, link: deniedLink }, onFallback() { fallbackCount++; },
    renameNoReplace(stage, final) {
      nativeCalls++; chmodSync(dirname(final), 0o500);
      try { return renameNoReplace(stage, final); }
      finally { chmodSync(dirname(final), 0o700); }
    } });
  try { await publish(source, target); console.log(JSON.stringify({ ok: true, nativeCalls, fallbackCount })); }
  catch (error) { console.log(JSON.stringify({ ok: false, uid: process.getuid(), nativeCalls, fallbackCount, error: info(error), entries: await fs.readdir(dirname(target)) })); }
  finally { await ledger.close(); await fs.rm(home, { recursive: true, force: true }); }
} else {
  assert.equal(process.version, 'v24.22.1');
  const root = await fs.mkdtemp(join(tmpdir(), 'm3-publisher-error-'));
  const ledger = await openLedger(join(root, 'ownership'));
  const bytes = Buffer.alloc(131089, 0x78), rows = [];
  const fixture = async name => { const dir = join(root, name); await fs.mkdir(dir); const source = join(dir, 'source'); await fs.writeFile(source, bytes); return { dir, source, target: join(dir, 'final') }; };
  const check = (name, fn) => test(name, async () => { try { rows.push({ name, pass: true, ...await fn() }); } catch (error) { rows.push({ name, pass: false, error: info(error) }); throw error; } });
  const absent = path => assert.rejects(fs.lstat(path), { code: 'ENOENT' });
  for (const code of ['EXDEV', 'ENOENT', 'ENOTDIR', 'EEXIST']) check(`real native ${code} propagated through the existing publisher, fallback zero`, async () => {
    const { dir, source, target } = await fixture(code); let external, fallbackCount = 0, nativeCalls = 0, observed;
    if (code === 'EXDEV') external = await fs.mkdtemp(join(process.env.M3_OTHER_FILESYSTEM || '/dev/shm', 'm3-publisher-exdev-'));
    if (code === 'ENOTDIR') await fs.writeFile(join(dir, 'notdir'), 'owner');
    if (code === 'EEXIST') await fs.writeFile(target, 'prior');
    const publish = createAtomicPublisher({ ledger, fs: { ...fs, link: deniedLink }, onFallback() { fallbackCount++; },
      renameNoReplace(stage, final) {
        nativeCalls++;
        // The protocol normally chooses a same-directory temporary. These three
        // boundary probes deliberately change only the native call's operands.
        if (code === 'EXDEV') return renameNoReplace(stage, join(external, 'final'));
        if (code === 'ENOENT') return renameNoReplace(stage + '.missing', final);
        if (code === 'ENOTDIR') return renameNoReplace(stage, join(dir, 'notdir/final'));
        return renameNoReplace(stage, final);
      } });
    try {
      await assert.rejects(publish(source, target), error => { observed = info(error); assert.equal(error.code, code); assert.equal(error.errno, -constants.errno[code]); assert.equal(error.syscall, 'renameat2'); return true; });
      assert.equal(nativeCalls, 1); assert.equal(fallbackCount, 0); assert.equal(publish.pendingCount, 0); assert.deepEqual(await fs.readFile(source), bytes);
      if (code === 'EEXIST') assert.equal(await fs.readFile(target, 'utf8'), 'prior'); else await absent(target);
      assert.equal((await fs.readdir(dir)).some(name => name.startsWith('.dsh-ohos-publish-')), false);
      return { nativeCalls, fallbackCount, error: observed, sourceUnchanged: true, ownedTemporaryCleaned: true, boundaryOperandOverride: code !== 'EEXIST' };
    } finally { if (external) await fs.rm(external, { recursive: true, force: true }); }
  });
  check('real EACCES during native commit: no fallback after permission restoration', async () => {
    const { dir, source, target } = await fixture('EACCES'); await fs.chmod(root, 0o755);
    if (process.getuid() === 0) await fs.chown(dir, 65534, 65534); await fs.chmod(dir, 0o700);
    const child = spawn(process.execPath, [self, '--permission-child', source, target], { env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = ''; child.stdout.on('data', data => { stdout += data; }); child.stderr.on('data', data => { stderr += data; });
    const timer = setTimeout(() => child.kill('SIGKILL'), 10000);
    const result = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); }).finally(() => clearTimeout(timer));
    assert.equal(result.code, 0, stderr); assert.equal(result.signal, null);
    const report = JSON.parse(stdout); assert.equal(report.ok, false); assert.notEqual(report.uid, 0); assert.equal(report.nativeCalls, 1); assert.equal(report.fallbackCount, 0); assert.equal(report.error.code, 'EACCES'); assert.equal(report.error.errno, -constants.errno.EACCES);
    assert.deepEqual(report.entries, ['source']); await absent(target); assert.deepEqual(await fs.readFile(source), bytes); return report;
  });
  check('injected native ENOSYS is propagated, never treated as unsupported-fs EINVAL', async () => {
    const { source, target } = await fixture('ENOSYS'); let fallbackCount = 0;
    const expected = Object.assign(new Error('fixture native ENOSYS'), { code: 'ENOSYS', errno: -constants.errno.ENOSYS, syscall: 'renameat2' });
    const publish = createAtomicPublisher({ ledger, fs: { ...fs, link: deniedLink }, renameNoReplace() { throw expected; }, onFallback() { fallbackCount++; } });
    await assert.rejects(publish(source, target), error => error === expected); assert.equal(fallbackCount, 0); await absent(target); return { injected: true, fallbackCount };
  });
  check('injected EINVAL from fsync is propagated before native commit', async () => {
    const { source, target } = await fixture('sync-EINVAL'); let nativeCalls = 0, fallbackCount = 0;
    const expected = Object.assign(new Error('fixture sync EINVAL'), { code: 'EINVAL', errno: -constants.errno.EINVAL, syscall: 'fsync' });
    const activeFs = { ...fs, link: deniedLink, async open(path, ...args) { const handle = await fs.open(path, ...args); if (args[0] === 'wx') handle.sync = async () => { throw expected; }; return handle; } };
    const publish = createAtomicPublisher({ ledger, fs: activeFs, renameNoReplace() { nativeCalls++; }, onFallback() { fallbackCount++; } });
    await assert.rejects(publish(source, target), error => error === expected); assert.equal(nativeCalls, 0); assert.equal(fallbackCount, 0); await absent(target); return { injected: true, nativeCalls, fallbackCount };
  });
  check('injected native EINVAL is the explicit legacy-copy positive control', async () => {
    const { source, target } = await fixture('native-EINVAL'); const events = [];
    const expected = Object.assign(new Error('fixture unsupported FS'), { code: 'EINVAL', errno: -constants.errno.EINVAL, syscall: 'renameat2' });
    const publish = createAtomicPublisher({ ledger, fs: { ...fs, link: deniedLink }, renameNoReplace() { throw expected; }, onFallback(event) { events.push(event); } });
    assert.deepEqual(await publish(source, target), { method: 'exclusive-copy-fallback' }); assert.equal(events.length, 1); assert.equal(events[0].syscall, 'renameat2'); assert.match(events[0].risk, /partial final file/); assert.deepEqual(await fs.readFile(target), bytes);
    return { injected: true, fallbackCount: events.length, explicitlyRiskyFallback: true };
  });
  after(async () => {
    assert.equal(sha(await fs.readFile(moduleFile)), moduleSHA, 'publisher source stayed fixed during the run');
    const report = { scope: 'Actual publisher with forced unavailable link; real native errno calls for EXDEV/ENOENT/ENOTDIR/EEXIST/EACCES, explicit injected controls labeled separately. Not a device or kill/recovery test.', addonSHA256: addonSHA, publisherSHA256: moduleSHA, testSHA256: sha(await fs.readFile(self)), node: process.version, pass: rows.filter(row => row.pass).length, fail: rows.filter(row => !row.pass).length, rows };
    const output = process.env.M3_PUBLISHER_ERROR_REPORT; if (output) { await fs.mkdir(dirname(resolve(output)), { recursive: true }); await fs.writeFile(output, JSON.stringify(report, null, 2) + '\n'); }
    assert.deepEqual(JSON.parse(await fs.readFile(join(root, 'ownership/ledger.json'), 'utf8')).entries, [], 'every failed publication released its record');
    await ledger.close();
    await fs.rm(root, { recursive: true, force: true });
  });
}
