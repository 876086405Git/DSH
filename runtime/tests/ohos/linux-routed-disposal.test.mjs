import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { once } from 'node:events';
import { mkdtemp, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Writable } from 'node:stream';
import { setTimeout as delay } from 'node:timers/promises';
import { LinuxControl } from '../../ohos/linux/control.mjs';
import { LinuxRuntimeBackend } from '../../ohos/linux/backend.mjs';
import { LinuxCommandBackend } from '../../ohos/process/linux-backend.mjs';
import { GuestPeer, until } from './linux-control-fixture.mjs';

const labels = ['stdout', 'stderr'];
const turn = () => new Promise(resolve => setImmediate(resolve));

// Actual Control, command adapter, runtime backend, streams and controller.
// Guest and native ownership are explicit fixtures on real TCP sockets; this
// is not a VM execution or a native stop/join test. The peer never exceeds a
// 64 KiB unacknowledged window and never sends complete before dual EOF/ACK.
async function fixture(t, { target = 512 * 1024, natural = false, holdComplete = false } = {}) {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'linux-routed-disposal-')));
  const server = net.createServer();
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const accepted = once(server, 'connection');
  const socket = net.connect(server.address().port, '127.0.0.1');
  socket.on('error', () => {}); await once(socket, 'connect');
  const [remote] = await accepted, peer = new GuestPeer(remote);
  peer.epoch = 'c4'.repeat(32);
  const jobs = [], handles = [], facts = { stops: 0, joins: 0, cancel: 0, complete: 0 };
  let current, runtime, adapter;
  function pump() {
    if (!current || current.completed) return;
    if (!current.cancelled) {
      for (const stream of labels) while (current.sent[stream] < target && current.sent[stream] - current.acked[stream] < 65536) {
        const bytes = Buffer.alloc(Math.min(4096, target - current.sent[stream]), stream === 'stdout' ? 0x61 : 0x62);
        const offset = current.sent[stream]; current.sent[stream] += bytes.length;
        peer.frame('data', { job: current.id, stream, offset: String(offset), data: bytes.toString('base64') });
      }
    }
    if ((current.cancelled || natural && labels.every(stream => current.sent[stream] === target)) && !current.eof) {
      current.eof = true;
      for (const stream of labels) peer.frame('eof', { job: current.id, stream, through: String(current.sent[stream]) });
    }
    if (!holdComplete && current.eof && labels.every(stream => current.acked[stream] === current.sent[stream])) {
      current.completed = true; facts.complete++;
      peer.frame('complete', { job: current.id, exitCode: current.cancelled ? null : 0,
        signal: current.cancelled ? 'SIGKILL' : null, cancelled: current.cancelled,
        produced: Object.fromEntries(labels.map(stream => [stream, String(current.sent[stream])])) });
    }
  }
  peer.on('command', command => {
    if (command.op === 'start') {
      current = { id: command.job, sent: { stdout: 0, stderr: 0 }, acked: { stdout: 0, stderr: 0 },
        cancelled: false, eof: false, completed: false };
      jobs.push(current);
      peer.frame('started', { job: command.job }); peer.frame('admitted', { job: command.job }); pump();
    } else if (command.op === 'ack') {
      assert.equal(command.job, current.id); assert.ok(labels.includes(command.stream));
      const through = Number(command.through);
      assert.ok(through > current.acked[command.stream] && through <= current.sent[command.stream]);
      current.acked[command.stream] = through; pump();
    } else if (command.op === 'cancel') {
      assert.equal(command.job, current.id); facts.cancel++;
      assert.equal(current.cancelled, false, 'one cancel per wire job');
      current.cancelled = true; peer.frame('cancel-requested', { job: command.job }); pump();
    } else if (command.op === 'close') {
      peer.frame('closed', { rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' });
    }
  });
  const control = new LinuxControl({ hostPaths: { directory: root, nativeLibraryDirectory: '/fixture/native' } }, {
    async loadModule() { return {
      async loadLinuxInstallationManifest() { return {}; },
      createLinuxInstallationOwner(options) { return {
        state: 'active', bootMode: 'resume', persistentInstanceId: 'fixture', nativeOwnerCreated: true,
        async install() {
          runtime = new LinuxRuntimeBackend({ configPath: '/fixture/guest.cfg', epoch: peer.epoch,
            temporaryRoot: root, exports: options.exports.map(item => item.tag) }, {
            createSession: () => ({ socket, requestStop() { facts.stops++; },
              async join() { facts.joins++; return { joined: true, retirementError: false, apiResult: -4 }; } }),
          });
          setImmediate(() => peer.frame('opened', { capabilities: { streamingStdin: true,
            pidNamespace: true, workspaceLease: false, mounts: true } }));
          await runtime.opened; return { backend: runtime };
        },
        async dispose() {
          await runtime?.dispose();
          return { resourcesRetired: true, filesRemoved: false, dataRetained: true, native: null };
        },
      }; },
    }; },
  });
  adapter = new LinuxCommandBackend({ control, workspaceRoots: [root], temporaryRoot: root });
  t.after(async () => {
    // Teardown only: a failed assertion must not leave a deliberate unread
    // fixture alive. No observation after this block is a product pass.
    for (const handle of handles) for (const stream of labels) handle[stream]?.resume();
    const timer = setTimeout(() => socket.destroy(), 2000);
    try { await adapter.dispose().catch(() => {}); await control.shutdown(); }
    finally {
      clearTimeout(timer); socket.destroy(); remote.destroy();
      await new Promise(resolve => server.close(resolve)); await rm(root, { recursive: true, force: true });
    }
  });
  const state = control.status();
  control.command({ v: 1, instanceId: state.instanceId, attemptId: state.attemptId, action: 'setEnabled', enabled: true });
  await until(() => control.status().admission);
  const spawn = () => {
    const handle = adapter.spawn({ argv: ['python3', '-m', 'fixture_server'], cwd: root,
      env: {}, graceMs: 300, stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
    handles.push(handle); return handle;
  };
  const pressure = async handle => {
    await handle.started;
    await until(() => labels.every(stream => handle[stream].writableNeedDrain &&
      jobs[0].sent[stream] - jobs[0].acked[stream] === 65536));
  };
  const healthy = () => {
    assert.equal(runtime.state, 'opened'); assert.equal(control.status().admission, true);
    assert.equal(facts.stops, 0); assert.equal(facts.joins, 0);
    assert.equal(adapter.live.size, 0); assert.equal(runtime.live.size, 0);
  };
  return { root, control, adapter, jobs, facts, peer, spawn, pressure, healthy, runtime: () => runtime };
}

test('final disposal drains unread stdout and stderr and is idempotent', { timeout: 5000 }, async t => {
  const f = await fixture(t), job = f.spawn(); await f.pressure(job);
  t.diagnostic(JSON.stringify({ before: f.jobs[0], buffers: labels.map(stream => ({ stream,
    readable: job[stream].readableLength, writable: job[stream].writableLength, needDrain: job[stream].writableNeedDrain })) }));
  const disposed = f.adapter.dispose(); assert.equal(f.adapter.dispose(), disposed);
  await disposed;
  assert.deepEqual(await job.done, { exitCode: null, signal: 'SIGTERM' });
  assert.equal(await job.waitForExit(), true);
  assert.equal(f.facts.cancel, 1); assert.equal(f.facts.complete, 1); f.healthy();
});

test('ordinary terminate retains output backpressure and every accepted output byte', { timeout: 5000 }, async t => {
  const f = await fixture(t), job = f.spawn(); await f.pressure(job);
  job.terminate('SIGKILL'); await until(() => f.jobs[0].cancelled); await turn();
  assert.equal(f.facts.complete, 0);
  assert.ok(labels.some(stream => f.jobs[0].acked[stream] < f.jobs[0].sent[stream]));
  const collected = { stdout: [], stderr: [] };
  for (const stream of labels) job[stream].on('data', bytes => collected[stream].push(bytes));
  assert.deepEqual(await job.done, { exitCode: null, signal: 'SIGKILL' });
  await Promise.all(labels.map(stream => job[stream].readableEnded ? undefined : once(job[stream], 'end')));
  for (const stream of labels) assert.deepEqual(Buffer.concat(collected[stream]),
    Buffer.alloc(f.jobs[0].sent[stream], stream === 'stdout' ? 0x61 : 0x62));
  assert.equal(f.adapter.closed, false); f.healthy();
});

test('final disposal detaches a blocked external sink without destroying or ending it', { timeout: 5000 }, async t => {
  const f = await fixture(t), job = f.spawn(), writes = [];
  const sink = new Writable({ highWaterMark: 1, write(bytes, encoding, callback) { writes.push(callback); } });
  job.stdout.pipe(sink);
  await f.pressure(job);
  await f.adapter.dispose(); await job.done;
  assert.equal(sink.destroyed, false); assert.equal(sink.writableEnded, false);
  assert.equal(writes.length, 1); assert.equal(f.facts.complete, 1); f.healthy();
  // The caller, not the Linux adapter, owns completion of this local sink.
  writes[0](); sink.destroy();
});

test('final disposal handles a closed pipe and an explicitly failed downstream sink', { timeout: 5000 }, async t => {
  const f = await fixture(t), job = f.spawn(); await f.pressure(job);
  const failure = new Error('caller-owned output sink failed'), errors = [];
  const sink = new Writable({ write(bytes, encoding, callback) { callback(failure); } });
  sink.on('error', error => errors.push(error));
  job.stderr.pipe(sink); job.stdout.destroy();
  await until(() => sink.destroyed && errors.length === 1);
  await f.adapter.dispose(); await job.done;
  assert.deepEqual(errors, [failure]); assert.equal(f.facts.complete, 1); f.healthy();
});

test('same-stack disposal also drains a raw job returned after disposal began', { timeout: 5000 }, async t => {
  const f = await fixture(t), job = f.spawn();
  // spawnRouted has created its raw handle, but the adapter is still at await.
  const disposed = f.adapter.dispose(); assert.equal(f.adapter.dispose(), disposed);
  await disposed;
  assert.deepEqual(await job.done, { exitCode: null, signal: 'SIGTERM' });
  assert.equal(f.jobs.length, 1); assert.equal(f.facts.cancel, 1); assert.equal(f.facts.complete, 1); f.healthy();
});

test('disposal cancels a real busy admission wait without starting a second guest job', { timeout: 5000 }, async t => {
  const f = await fixture(t), first = f.spawn(); await f.pressure(first);
  const queued = f.spawn(); assert.equal(f.adapter.live.size, 2);
  await f.adapter.dispose();
  assert.deepEqual(await first.done, { exitCode: null, signal: 'SIGTERM' });
  assert.deepEqual(await queued.done, { exitCode: null, signal: 'SIGTERM' });
  await assert.rejects(queued.started, { code: 'ERR_OHOS_NOT_STARTED' });
  assert.equal(f.jobs.length, 1); assert.equal(f.facts.cancel, 1); assert.equal(f.facts.complete, 1); f.healthy();
});

test('EOF and all ACKs without true complete still reject disposal with the original unknown cause', { timeout: 5000 }, async t => {
  const f = await fixture(t, { holdComplete: true }), job = f.spawn(); await f.pressure(job);
  let failure;
  await assert.rejects(f.adapter.dispose(), error => {
    failure = error; return error.code === 'ERR_OHOS_LINUX_UNKNOWN' && error.cause?.code === 'ERR_OHOS_LINUX_CANCEL_UNCONFIRMED';
  });
  await assert.rejects(job.done, error => error === failure);
  await assert.rejects(job.waitForExit(), error => error === failure);
  assert.equal(f.jobs[0].eof, true);
  for (const stream of labels) assert.equal(f.jobs[0].acked[stream], f.jobs[0].sent[stream]);
  assert.equal(f.facts.complete, 0); assert.equal(f.runtime().state, 'quarantined');
  assert.equal(f.control.status().state, 'unknown'); assert.equal(f.control.status().admission, false);
  assert.equal(f.runtime().live.size, 1);
});

test('final disposal drains a raw-complete job whose outer finished barrier is still blocked', { timeout: 5000 }, async t => {
  const f = await fixture(t, { target: 160 * 1024, natural: true }), job = f.spawn();
  await job.started;
  await until(() => f.facts.complete === 1 && f.runtime().live.size === 0);
  assert.equal(f.adapter.live.size, 1);
  const disposed = f.adapter.dispose();
  // This observer timeout is a failure-cleanup guard, not a production SLA.
  const completed = await Promise.race([disposed.then(() => true), delay(500).then(() => false)]);
  if (!completed) { for (const stream of labels) job[stream].resume(); await disposed; }
  assert.equal(completed, true, 'raw completion alone must not leave adapter disposal waiting on an abandoned sink');
  assert.deepEqual(await job.done, { exitCode: 0, signal: null });
  assert.equal(f.facts.cancel, 0); assert.equal(f.facts.complete, 1); f.healthy();
});

test('unpipe callback reentering final dispose receives the same promise', { timeout: 5000 }, async t => {
  const f = await fixture(t), job = f.spawn();
  const writes = [];
  const sink = new Writable({ highWaterMark: 1,
    write(bytes, encoding, callback) { writes.push(callback); } });
  job.stdout.pipe(sink);
  await f.pressure(job);
  let nested, calls = 0;
  sink.once('unpipe', () => {
    calls++;
    assert.equal(f.adapter.closed, true);
    assert.throws(() => f.spawn(), { code: 'ERR_OHOS_PROCESS_CLOSED' });
    nested = f.adapter.dispose();
  });
  const outer = f.adapter.dispose();
  t.diagnostic(JSON.stringify({ calls, nestedPresent: !!nested,
    samePromise: outer === nested, liveAtReturn: f.adapter.live.size }));
  await Promise.all([outer, nested]);
  assert.equal(calls, 1);
  assert.equal(f.facts.cancel, 1);
  assert.equal(f.facts.complete, 1);
  f.healthy();
  for (const callback of writes) callback();
  sink.destroy();
  assert.equal(nested, outer, 'final disposal must publish its idempotent promise before synchronous caller unpipe callbacks');
});
