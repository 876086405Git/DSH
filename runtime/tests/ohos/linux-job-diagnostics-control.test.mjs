import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { LinuxControl } from '../../ohos/linux/control.mjs';

const tls = await readFile(new URL('./fixtures/linux-job-diagnostics/phone930-github.stderr', import.meta.url));
assert.equal(createHash('sha256').update(tls).digest('hex'), '972e8f182b0dfaef685ad478937dec8b7839bf48b3400178526b1b5b28c47930');
const tick = () => new Promise(resolve => setImmediate(resolve));
async function until(predicate) {
  for (let attempt = 0; attempt < 20; attempt++) { if (predicate()) return; await tick(); }
  assert.fail('control observation did not settle');
}

// Production control and status serialization, with an explicit completed-job
// backend boundary. The original phone bytes/outcome are real; this fixture
// does not run a guest, establish network causation or replace EOF/ACK tests.
async function fixture(stderr = tls, totalBytes = stderr.length) {
  const completion = Promise.withResolvers();
  completion.promise.catch(() => {});
  const outcome = { exitCode: 128, signal: null, cancelled: false };
  const collector = (bytes, total = bytes.length) => ({ snapshot: () => ({ bytes, totalBytes: total }) });
  const handle = { collected: { stdout: collector(Buffer.alloc(0)), stderr: collector(stderr, totalBytes) },
    started: Promise.resolve(), done: completion.promise, terminate() {},
    waitForExit: () => completion.promise.then(() => true) };
  const backend = { state: 'opened', closed: false, spawn: () => handle };
  const owner = { state: 'active', persistentInstanceId: '00000000-0000-0000-0000-000000000001', bootMode: 'install',
    install: async () => ({ backend }) };
  const control = new LinuxControl({ hostPaths: { directory: '/private/linux', nativeLibraryDirectory: '/signed/native' },
    assetsDirectory: '/signed/assets' }, { loadModule: async () => ({
    loadLinuxInstallationManifest: async () => ({}), createLinuxInstallationOwner: () => owner,
  }) });
  const command = (action, fields = {}) => { const state = control.status(); return control.command({
    v: 1, instanceId: state.instanceId, attemptId: state.attemptId, action, ...fields }); };
  command('setEnabled', { enabled: true }); await until(() => control.status().admission);
  command('runPrivateGuest', { requestId: 1, argv: ['git', 'clone', '--depth', '1', '--single-branch', '--no-tags', '--',
    'https://github.com/octocat/Hello-World.git', '/workspace/diagnostic-replay'], cwd: '/workspace', env: {}, stdin: '' });
  return { control, command, outcome, completion,
    settle: async value => { completion.resolve(value ?? outcome); await until(() => control.status().job.state === 'settled'); return control.status(); } };
}

test('phone TLS stderr through production control gets a hint without changing the observed outcome', async () => {
  const f = await fixture(); const state = await f.settle();
  assert.equal(state.state, 'enabled'); assert.equal(state.job.state, 'settled');
  assert.deepEqual(state.job.outcome, f.outcome); assert.equal(state.job.errorCode, null);
  assert.deepEqual(Buffer.from(state.job.stderr.data, 'base64'), tls);
  assert.equal(state.job.stderr.truncated, false);
  assert.equal(state.job.diagnostic?.category, 'tls-interrupted');
  assert.equal(state.job.diagnostic.evidence, 'stderr');
  assert.match(state.job.diagnostic.message, /TLS.*中途断开/);
});

test('a successful command with the same error-like bytes has no failure hint', async () => {
  const f = await fixture(); const state = await f.settle({ exitCode: 0, signal: null, cancelled: false });
  assert.equal(state.job.state, 'settled'); assert.equal(state.job.outcome.exitCode, 0);
  assert.equal(state.job.diagnostic, null);
});

test('cancelled SIGKILL with TLS-looking output stays cancellation, not a network failure', async () => {
  const f = await fixture(); f.command('setEnabled', { enabled: false });
  await until(() => f.control.status().job.cancelRequested);
  const outcome = { exitCode: null, signal: 'SIGKILL', cancelled: true, requestedSignal: 'SIGTERM' };
  const state = await f.settle(outcome);
  assert.deepEqual(state.job.outcome, outcome); assert.equal(state.job.cancelRequested, true);
  assert.equal(state.job.diagnostic, null);
});

test('unknown completion cannot be upgraded by recognizable stderr', async () => {
  const f = await fixture(); f.completion.reject(Object.assign(new Error('explicit fixture transport fault'), { code: 'ERR_OHOS_LINUX_UNKNOWN' }));
  await until(() => f.control.status().job.state === 'unknown');
  const state = f.control.status();
  assert.equal(state.state, 'unknown'); assert.equal(state.job.outcome, null);
  assert.equal(state.job.diagnostic, null);
});

test('a matching retained tail is unknown when production output marks it truncated', async () => {
  const f = await fixture(tls, tls.length + 4096); const state = await f.settle();
  assert.equal(state.job.stderr.truncated, true); assert.equal(state.job.stderr.totalBytes, tls.length + 4096);
  assert.equal(state.job.diagnostic?.category, 'unknown');
  assert.equal(state.job.diagnostic.evidence, 'none');
  assert.deepEqual(state.job.outcome, f.outcome);
});
