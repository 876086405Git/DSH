import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { once } from 'node:events';
import { mkdtemp, mkdir, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CommandRouter } from '../../ohos/process/command-router.mjs';
import { LinuxCommandBackend, linuxCommands } from '../../ohos/process/linux-backend.mjs';
import { LinuxControl } from '../../ohos/linux/control.mjs';
import { LinuxRuntimeBackend } from '../../ohos/linux/backend.mjs';
import { GuestPeer, until } from './linux-control-fixture.mjs';

// Production router, virtual shell Worker, Linux adapter, LinuxControl and
// LinuxRuntimeBackend. Only the guest is an explicit peer on a real socket that
// answers start frames the way the agent does; owner/native are not involved.
async function fixture(t, { enable = true, waitMs } = {}) {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'linux-routing-')));
  const work = join(root, 'work'), outside = join(root, 'outside'), spill = join(root, 'spill');
  await Promise.all([work, outside, spill].map(path => mkdir(path)));
  const server = net.createServer(); server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const accepted = once(server, 'connection'), socket = net.connect(server.address().port, '127.0.0.1');
  socket.on('error', () => {}); await once(socket, 'connect'); const [remote] = await accepted;
  const peer = new GuestPeer(remote); peer.epoch = 'ab'.repeat(32);
  const starts = [], replies = [];
  peer.on('command', command => {
    if (command.op === 'close') peer.frame('closed', { rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' });
    if (command.op === 'start') { starts.push(command); peer.frame('started', { job: command.job }); peer.frame('admitted', { job: command.job }); (replies.shift() ?? (() => finish(command.job)))(command); }
  });
  const sent = { stdout: 0, stderr: 0 };
  const write = (job, stream, text) => {
    const bytes = Buffer.from(text);
    peer.frame('data', { job, stream, offset: String(sent[stream]), data: bytes.toString('base64') }); sent[stream] += bytes.length;
  };
  async function finish(job, { exitCode = 0, cancelled = false } = {}) {
    for (const stream of ['stdout', 'stderr']) peer.frame('eof', { job, stream, through: String(sent[stream]) });
    await until(() => ['stdout', 'stderr'].every(stream => !sent[stream] ||
      peer.commands.some(command => command.op === 'ack' && command.job === job && command.stream === stream && command.through === String(sent[stream]))));
    peer.frame('complete', { job, exitCode: cancelled ? null : exitCode, signal: cancelled ? 'SIGKILL' : null, cancelled,
      produced: { stdout: String(sent.stdout), stderr: String(sent.stderr) } });
    sent.stdout = sent.stderr = 0;
  }
  let options;
  const control = new LinuxControl({ hostPaths: { directory: root, nativeLibraryDirectory: '/fixture/native' } }, { async loadModule() {
    return { async loadLinuxInstallationManifest() { return {}; }, createLinuxInstallationOwner(input) {
      options = input;
      return { state: 'active', bootMode: 'resume', persistentInstanceId: 'fixture', nativeOwnerCreated: true,
        async install() {
          const backend = new LinuxRuntimeBackend({ configPath: '/fixture/guest.cfg', epoch: peer.epoch, temporaryRoot: spill,
            exports: input.exports.map(item => item.tag) }, { createSession: () => ({ socket, requestStop() {},
            join: async () => ({ joined: true, retirementError: false, apiResult: -4 }) }) });
          setImmediate(() => peer.frame('opened', { capabilities: { streamingStdin: true, pidNamespace: true, workspaceLease: false, mounts: true } }));
          await backend.opened; this.backend = backend; return { backend };
        },
        async dispose() { await this.backend?.dispose(); return { resourcesRetired: true, filesRemoved: false, dataRetained: true, native: null }; } };
    } };
  } });
  const router = new CommandRouter({ workspaceRoots: [work] },
    { linux: roots => new LinuxCommandBackend({ control, ...roots }, { waitMs }) });
  t.after(async () => {
    await router.dispose(); await control.shutdown(); socket.destroy(); remote.destroy();
    await new Promise(resolve => server.close(resolve)); await rm(root, { recursive: true, force: true });
  });
  const command = (action, fields = {}) => { const state = control.status(); return control.command({ v: 1, instanceId: state.instanceId, attemptId: state.attemptId, action, ...fields }); };
  if (enable) { command('setEnabled', { enabled: true }); await until(() => control.status().admission); }
  const bash = (script, { mode = 'workspace-write', cwd = work, signal } = {}) => {
    const job = router.spawn({ argv: router.prepare(['bash', '-c', script], { mode, workspaceRoot: work }), cwd, graceMs: 1000, signal,
      env: {}, stdio: { stdin: 'ignore', stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } } });
    return job.done.then(outcome => ({ ...outcome, stdout: job.collected.stdout.snapshot().bytes.toString(), stderr: job.collected.stderr.snapshot().bytes.toString() }));
  };
  return { root, work, outside, router, control, peer, starts, replies, write, finish, command, bash, options: () => options };
}

test('an agent script runs gh, python3 and pip as guest jobs that see only their session directories', async t => {
  const f = await fixture(t);
  assert.deepEqual(f.router.capabilities.linuxCommands, linuxCommands);
  assert.deepEqual(f.control.exports.map(item => item.path), [f.router.temporaryRoot, f.work]);
  assert.deepEqual(f.options().exports, f.control.exports);
  f.replies.push(start => { f.write(start.job, 'stdout', '1\n'); f.finish(start.job); },
    start => { f.write(start.job, 'stdout', 'pip 26.2.2\n'); f.finish(start.job); },
    start => { f.write(start.job, 'stderr', 'gh: not logged in\n'); f.finish(start.job, { exitCode: 4 }); });
  const result = await f.bash("python3 -c 'print(1)' | cat; pip --version; gh auth status || echo \"gh=$?\"");
  assert.equal(result.exitCode, 0, result.stderr);
  assert.equal(result.stdout, '1\npip 26.2.2\ngh=4\n');
  assert.equal(result.stderr, 'gh: not logged in\n');
  const [python, pip, gh] = f.starts;
  assert.deepEqual(python.argv, ['python3', '-c', 'print(1)']);
  assert.equal(pip.argv[0], 'python3'); assert.equal(pip.argv[1], '-c'); assert.match(pip.argv[2], /ensurepip/); assert.deepEqual(pip.argv.slice(3), ['--version']);
  assert.deepEqual(gh.argv, ['gh', 'auth', 'status']);
  for (const start of f.starts) {
    assert.equal(start.cwd, f.work);
    assert.deepEqual(start.mounts, [{ tag: 'dsh1', source: '', target: f.work, readOnly: false },
      { tag: 'dsh0', source: '', target: f.router.temporaryRoot, readOnly: false }]);
    assert.equal(start.env.HOME, '/workspace'); assert.equal(start.env.TMPDIR, f.router.temporaryRoot);
    assert.match(start.env.PATH, /^\/workspace\/\.local\/bin:/); assert.equal(start.env.PIP_BREAK_SYSTEM_PACKAGES, '1');
  }
  // Statement-buffered, but the lane is free again after each job.
  f.replies.push(start => { f.write(start.job, 'stdout', 'x\n'); f.finish(start.job); });
  assert.equal((await f.bash('linux sh -c "echo x"')).stdout, 'x\n');
  assert.deepEqual(f.starts.at(-1).argv, ['sh', '-c', 'echo x']);
  assert.equal((await f.bash('python3 -m pip list')).exitCode, 0);
  assert.deepEqual(f.starts.at(-1).argv.slice(3), ['list']);
});

test('read-only sessions get read-only views; user-granted roots and other directories are refused', async t => {
  const f = await fixture(t);
  await f.bash('python3 -c "print(2)"', { mode: 'read-only' });
  assert.deepEqual(f.starts[0].mounts.map(item => item.readOnly), [true, true]);
  const linux = f.router.linux;
  assert.throws(() => linux.prepare(['python3'], { mode: 'workspace-write', workspaceRoot: '/workspaces/3f1e8a4c-0b9d-4c55-9a51-2f1d6c2b7e10' }),
    { code: 'ERR_WORKSPACE_SCOPE_UNSUPPORTED' });
  const plugin = f.router.spawnPlugin({ argv: ['python3', '-c', 'print(3)'], cwd: f.outside, graceMs: 1000,
    stdio: { stdin: 'ignore', stdout: { maxBytes: 4096 }, stderr: { maxBytes: 4096 } } });
  assert.deepEqual(await plugin.done, { exitCode: 126, signal: null });
  assert.match(plugin.collected.stderr.snapshot().bytes.toString(), /ERR_OHOS_LINUX_WORKSPACE_UNAVAILABLE: .*不在 App 交给 Linux 环境的工作区内/);
  assert.equal(f.starts.length, 1);
});

test('with Linux off a command ends with 127 and says where to turn it on; nothing starts', async t => {
  const f = await fixture(t, { enable: false });
  const result = await f.bash('python3 -c "print(1)"; echo "status=$?"');
  assert.match(result.stderr, /^ERR_OHOS_LINUX_DISABLED: Linux 环境未开启：请在 设置 · 能力 · Linux 环境 中打开后重试。\n$/);
  assert.equal(result.stdout, 'status=127\n');
  const last = await f.bash('gh --version');
  assert.equal(last.exitCode, 127);
  assert.match(last.stderr, /^ERR_OHOS_LINUX_DISABLED: [^\n]+\n$/);
  await assert.rejects(f.router.resolveExecutable('gh'), /Linux 环境未开启/);
  assert.equal(f.control.status().ownerRetained, false);
  assert.equal(f.starts.length, 0);
});

test('cancelling the agent script cancels its guest job, which releases the lane', async t => {
  const f = await fixture(t);
  f.replies.push(start => f.write(start.job, 'stdout', 'started\n'));
  const controller = new AbortController(), running = f.bash('python3 -c "import time; time.sleep(60)"', { signal: controller.signal });
  await until(() => f.starts.length === 1);
  controller.abort();
  await until(() => f.peer.commands.some(command => command.op === 'cancel'));
  f.peer.frame('cancel-requested', { job: f.starts[0].job }); await f.finish(f.starts[0].job, { cancelled: true });
  const outcome = await running;
  assert.equal(outcome.exitCode, null);
  await f.bash('python3 -c "print(1)"');
  assert.equal(f.starts.length, 2);
});

test('the single guest lane: a long-lived plugin server makes a later command fail as busy, not wait forever', async t => {
  const f = await fixture(t, { waitMs: 300 });
  f.replies.push(() => {});
  const server = f.router.spawnPlugin({ argv: ['python3', '-m', 'mcp_server'], cwd: f.work, graceMs: 1000,
    stdio: { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' } });
  server.stdout.resume(); server.stderr.resume();
  await server.started;
  const busy = await f.bash('gh --version');
  assert.match(busy.stderr, /ERR_OHOS_LINUX_BUSY: .*python3 占用/);
  assert.equal(f.starts.length, 1);
  assert.throws(() => f.command('runPrivateGuest', { requestId: f.control.status().nextRequestId, argv: ['true'], cwd: '/workspace' }), { code: 'ERR_OHOS_LINUX_BUSY' });
  server.terminate();
  await until(() => f.peer.commands.some(command => command.op === 'cancel'));
  f.peer.frame('cancel-requested', { job: f.starts[0].job }); await f.finish(f.starts[0].job, { cancelled: true });
  await server.done;
  f.replies.push(start => { f.write(start.job, 'stdout', 'gh version 2.97.0\n'); f.finish(start.job); });
  assert.equal((await f.bash('gh --version')).stdout, 'gh version 2.97.0\n');
});

test('the App proxy applies to routed jobs; switching Linux off cancels a running one', async t => {
  const f = await fixture(t);
  f.command('setProxy', { proxy: { mode: 'manual', httpProxy: 'http://127.0.0.1:7890' } });
  await f.bash('gh api user');
  assert.equal(f.starts[0].env.https_proxy, 'http://10.0.2.2:7890/');
  f.replies.push(() => {});
  const running = f.bash('python3 -c "import time; time.sleep(60)"');
  await until(() => f.starts.length === 2);
  f.command('setEnabled', { enabled: false });
  await until(() => f.peer.commands.some(command => command.op === 'cancel'));
  f.peer.frame('cancel-requested', { job: f.starts[1].job }); await f.finish(f.starts[1].job, { cancelled: true });
  // The guest killed it; the shell sees 128+SIGKILL, as from any killed command.
  assert.equal((await running).exitCode, 137);
  await until(() => f.control.status().state === 'stopped');
  assert.equal(f.control.status().shutdownComplete, true);
  assert.equal(f.control.status().restartRequired, true);
});

test('an unconfirmed guest exit is never reported as exited, and its output errors are handled', async t => {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'linux-unconfirmed-')));
  t.after(() => rm(root, { recursive: true, force: true }));
  const unhandled = [];
  const onUnhandled = reason => unhandled.push(reason);
  process.on('unhandledRejection', onUnhandled);
  t.after(() => process.off('unhandledRejection', onUnhandled));
  const quarantine = Object.assign(new Error('guest exit not confirmed'), { code: 'ERR_OHOS_LINUX_QUARANTINED' });
  const { PassThrough } = await import('node:stream');
  const control = {
    exports: [{ tag: 'fs0', path: root }],
    exportWorkspaces() {},
    status: () => ({ enabled: true }),
    async spawnRouted() {
      const job = { stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(),
        started: Promise.resolve(), done: Promise.reject(quarantine), terminate() {} };
      job.done.catch(() => {});
      // Quarantine destroys both outputs with the same error.
      setImmediate(() => { job.stdout.destroy(quarantine); job.stderr.destroy(quarantine); });
      return job;
    },
  };
  const backend = new LinuxCommandBackend({ control, workspaceRoots: [root], temporaryRoot: root });
  const job = backend.spawn({ argv: ['gh', '--version'], cwd: root, env: {}, graceMs: 1000,
    stdio: { stdin: 'ignore', stdout: { maxBytes: 4096 }, stderr: { maxBytes: 4096 } } });
  await assert.rejects(job.done, { code: 'ERR_OHOS_LINUX_QUARANTINED' });
  await assert.rejects(job.waitForExit(), { code: 'ERR_OHOS_LINUX_QUARANTINED' });
  await assert.rejects(backend.dispose(), { code: 'ERR_OHOS_LINUX_QUARANTINED' });
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(unhandled, []);
});
