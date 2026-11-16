import test from 'node:test';
import assert from 'node:assert/strict';
import { Duplex } from 'node:stream';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { LinuxRuntimeBackend } from '../../ohos/linux/backend.mjs';
import { LinuxProxyPolicy } from '../../ohos/linux/proxy.mjs';

const epoch = '04'.repeat(32);
class Transport extends Duplex {
  commands = []; sequence = 0;
  _read() {}
  _write(bytes, _encoding, callback) {
    for (const line of bytes.toString().trimEnd().split('\n')) this.commands.push(JSON.parse(line));
    callback();
  }
  frame(kind, fields = {}) {
    this.push(Buffer.from('DSHG1 ' + JSON.stringify({ v: 1, epoch,
      seq: ++this.sequence, kind, job: null, ...fields }) + '\n'));
  }
}
async function commandEnvironment(t, env) {
  const root = await mkdtemp(join(tmpdir(), 'linux-environment-'));
  const socket = new Transport();
  const backend = new LinuxRuntimeBackend({ configPath: '/trusted/config', epoch, temporaryRoot: root }, {
    createSession: () => ({ socket, requestStop() {}, async join() {
      return { joined: true, ownerQuarantined: true, retirementError: false, apiResult: -4 };
    } }),
  });
  t.after(async () => { socket.destroy(); await rm(root, { recursive: true, force: true }); });
  socket.frame('opened', { capabilities: { streamingStdin: true, pidNamespace: true, workspaceLease: false } });
  await backend.opened;
  const job = backend.spawn({ argv: ['python3', '-c', 'print(1)'], cwd: '/workspace', env,
    graceMs: 1000, stdio: { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' } });
  await delay(0);
  const start = socket.commands.find(command => command.op === 'start'); assert.ok(start);
  socket.frame('started', { job: start.job }); socket.frame('admitted', { job: start.job });
  await job.started;
  for (const stream of ['stdout', 'stderr']) socket.frame('eof', { job: start.job, stream, through: '0' });
  await delay(0);
  socket.frame('complete', { job: start.job, exitCode: 0, signal: null, cancelled: false,
    produced: { stdout: '0', stderr: '0' } });
  await job.done;
  const closing = backend.dispose(); await delay(0);
  socket.frame('closed', { rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' });
  await closing;
  return start.env;
}

test('default guest environment does not inherit unrelated parent variables', async t => {
  const key = 'OHOS10_AMBIENT_NOTE', previous = process.env[key];
  process.env[key] = 'local-test-value';
  t.after(() => { if (previous === undefined) delete process.env[key]; else process.env[key] = previous; });
  const env = await commandEnvironment(t);
  assert.equal(Object.hasOwn(env, key), false, 'unrequested parent variable must be absent');
  assert.deepEqual(env, { PATH: '/usr/bin:/bin', HOME: '/workspace', TMPDIR: '/tmp', LANG: 'C.UTF-8' });
});

test('explicit values, guest defaults and undefined removals keep their contract', async t => {
  const env = await commandEnvironment(t, { PATH: '/bin', HOME: undefined, APP_SETTING: 'explicit' });
  assert.deepEqual(env, { PATH: '/bin', TMPDIR: '/tmp', LANG: 'C.UTF-8', APP_SETTING: 'explicit' });
});

test('the existing Linux proxy snapshot still supplies configured guest aliases', async t => {
  const policy = new LinuxProxyPolicy();
  policy.set({ mode: 'manual', httpProxy: 'http://127.0.0.1:18080' });
  const snapshot = policy.forRequest({ APP_SETTING: 'explicit' });
  const env = await commandEnvironment(t, snapshot.environment);
  assert.equal(snapshot.revision, 1);
  for (const key of ['http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY']) {
    assert.equal(env[key], 'http://10.0.2.2:18080/');
  }
  assert.equal(Object.hasOwn(env, 'all_proxy'), false);
  assert.equal(Object.hasOwn(env, 'ALL_PROXY'), false);
  assert.equal(env.APP_SETTING, 'explicit');
  assert.equal(env.HOME, '/workspace');
  assert.equal(env.no_proxy, env.NO_PROXY);
  assert.ok(env.NO_PROXY.split(',').includes('gitee.com'));
});
