// Explicit guest/session boundary: real child pipes and a real Python server,
// with the production Linux backend decoding a localhost TCP guest protocol.
// No VM, mount namespace, 9p, SDK or native retirement is claimed here.
import assert from 'node:assert/strict';
import net from 'node:net';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { GuestPeer } from './linux-control-fixture.mjs';

export async function waitFor(predicate, label, timeout = 5000) {
  const end = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() >= end) throw new Error('Observation deadline: ' + label);
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

export async function createProcessGuest({ python, command, cwd, record }) {
  const server = net.createServer();
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const accepted = once(server, 'connection');
  const socket = net.connect(server.address().port, '127.0.0.1');
  socket.on('error', error => record('host-socket-error', { code: error.code }));
  await once(socket, 'connect');
  const [remote] = await accepted;
  const peer = new GuestPeer(remote); peer.epoch = 'ab'.repeat(32);
  const jobs = new Map(), errors = [];
  const error = cause => {
    errors.push({ name: cause.name, code: cause.code, message: cause.message });
    record('guest-fixture-error', errors.at(-1));
  };
  const emitOutput = (state, stream, bytes) => {
    for (let offset = 0; offset < bytes.length; offset += 4096) {
      const chunk = bytes.subarray(offset, offset + 4096);
      peer.frame('data', { job: state.id, stream, offset: String(state.sent[stream]), data: chunk.toString('base64') });
      state.sent[stream] += chunk.length;
    }
  };
  const complete = async (state, code, signal) => {
    // 'close' is the real child event after both output pipes have closed.
    state.close = { code, signal };
    record('server-process-close', { job: state.id, pid: state.child.pid, code, signal });
    for (const stream of ['stdout', 'stderr']) {
      peer.frame('eof', { job: state.id, stream, through: String(state.sent[stream]) });
    }
    await waitFor(() => ['stdout', 'stderr'].every(stream => state.acked[stream] === state.sent[stream]),
      'production output consumption before completion');
    peer.frame('complete', { job: state.id, exitCode: code, signal, cancelled: state.cancelled,
      produced: { stdout: String(state.sent.stdout), stderr: String(state.sent.stderr) } });
    state.completed = true;
    record('guest-complete', { job: state.id, code, signal, cancelled: state.cancelled });
  };
  peer.on('command', message => {
    try {
      const visible = { ...message };
      if (visible.env) { visible.envKeys = Object.keys(visible.env).sort(); delete visible.env; }
      if (visible.data) { visible.dataBytes = Buffer.from(visible.data, 'base64').length; delete visible.data; }
      record('guest-command', { command: visible });
      if (message.op === 'close') {
        assert([...jobs.values()].every(state => state.close && state.completed));
        peer.frame('closed', { rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' });
        return;
      }
      if (message.op === 'start') {
        assert.deepEqual(message.argv, command);
        assert.equal(message.cwd, cwd);
        assert([...jobs.values()].every(state => state.close && state.completed), 'one actual server process at a time');
        // Resolve python only at this explicit host boundary. Never rewrite a
        // production command or replace its MCP response in the parent process.
        const child = spawn(python, message.argv.slice(1), { cwd: message.cwd, env: message.env,
          stdio: ['pipe', 'pipe', 'pipe'], shell: false });
        const state = { id: message.job, child, sent: { stdout: 0, stderr: 0 }, acked: { stdout: 0, stderr: 0 },
          received: 0, accepted: 0, inputEnded: false, cancelled: false, completed: false, close: null,
          mounts: message.mounts };
        jobs.set(message.job, state);
        child.on('error', error);
        child.stdin.on('error', cause => { if (!state.cancelled) error(cause); });
        child.stdout.on('data', bytes => emitOutput(state, 'stdout', bytes));
        child.stderr.on('data', bytes => emitOutput(state, 'stderr', bytes));
        child.once('spawn', () => {
          record('server-process-start', { job: state.id, pid: child.pid, executable: python });
          peer.frame('started', { job: state.id }); peer.frame('admitted', { job: state.id });
        });
        child.once('close', (code, signal) => { complete(state, code, signal).catch(error); });
        return;
      }
      const state = jobs.get(message.job);
      assert(state, 'known protocol job');
      if (message.op === 'ack') {
        state.acked[message.stream] = Number(message.through); return;
      }
      if (message.op === 'stdin') {
        assert.equal(state.inputEnded, false);
        const bytes = Buffer.from(message.data, 'base64');
        assert.equal(Number(message.offset), state.received);
        state.received += bytes.length;
        state.child.stdin.write(bytes, cause => {
          if (cause) { if (!state.cancelled) error(cause); return; }
          if (state.cancelled || state.completed) return;
          state.accepted += bytes.length;
          peer.frame('stdin-ack', { job: state.id, through: String(state.accepted) });
          record('server-pipe-write-accepted', { job: state.id, through: state.accepted });
        });
        return;
      }
      if (message.op === 'stdin-end') {
        assert.equal(state.inputEnded, false); state.inputEnded = true;
        state.child.stdin.end(); record('server-pipe-ended', { job: state.id }); return;
      }
      if (message.op === 'cancel') {
        assert.equal(state.cancelled, false); state.cancelled = true;
        peer.frame('cancel-requested', { job: state.id });
        state.child.kill('SIGTERM'); return;
      }
      throw new Error('Unexpected guest command: ' + message.op);
    } catch (cause) { error(cause); }
  });
  return {
    socket, peer, jobs, errors,
    opened() { peer.frame('opened', { capabilities: { streamingStdin: true, pidNamespace: true,
      workspaceLease: false, mounts: true } }); },
    async close() {
      for (const state of jobs.values()) if (!state.close) state.child.kill('SIGKILL');
      await waitFor(() => [...jobs.values()].every(state => state.close), 'real server processes closed');
      socket.destroy(); remote.destroy();
      await new Promise(resolve => server.close(resolve));
    },
  };
}
