import assert from 'node:assert/strict';
import net from 'node:net';
import { once, EventEmitter } from 'node:events';
import { mkdtemp, mkdir, writeFile, rm, readFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { LinuxInstallationOwner } from '../../ohos/linux/owner.mjs';

export const tick = () => new Promise(resolve => setImmediate(resolve));
export async function until(predicate) {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  assert.fail('fixture observation did not arrive');
}

// The guest/native boundary is an explicit test double. Both endpoints really
// are net.Socket objects; the production controller/backend decode all bytes.
export class GuestPeer extends EventEmitter {
  commands = []; sequence = 0; epoch = undefined; buffer = '';
  constructor(socket) {
    super(); this.socket = socket; socket.on('error', () => {});
    socket.on('data', bytes => {
      this.buffer += bytes.toString('utf8'); let index;
      while ((index = this.buffer.indexOf('\n')) >= 0) {
        const command = JSON.parse(this.buffer.slice(0, index)); this.buffer = this.buffer.slice(index + 1);
        this.commands.push(command); this.emit('command', command);
      }
    });
  }
  frame(kind, fields = {}) {
    this.socket.write('DSHG1 ' + JSON.stringify({ v: 1, epoch: this.epoch,
      seq: ++this.sequence, kind, job: null, ...fields }) + '\n');
  }
  opened() { this.frame('opened', { capabilities: { streamingStdin: true, pidNamespace: true, workspaceLease: false } }); }
  async admitted() {
    await until(() => this.commands.some(command => command.op === 'start'));
    const command = this.commands.findLast(command => command.op === 'start');
    this.frame('started', { job: command.job }); this.frame('admitted', { job: command.job });
    await tick(); return command;
  }
  async complete(id, { stdout = Buffer.alloc(0), stderr = Buffer.alloc(0), cancelled = false } = {}) {
    if (cancelled) this.frame('cancel-requested', { job: id });
    for (const [stream, bytes] of Object.entries({ stdout, stderr })) {
      for (let offset = 0; offset < bytes.length; offset += 4096) {
        this.frame('data', { job: id, stream, offset: String(offset), data: bytes.subarray(offset, offset + 4096).toString('base64') });
      }
      this.frame('eof', { job: id, stream, through: String(bytes.length) });
    }
    await until(() => ['stdout', 'stderr'].every(stream => !({ stdout, stderr })[stream].length ||
      this.commands.some(command => command.op === 'ack' && command.stream === stream && command.through === String(({ stdout, stderr })[stream].length))));
    this.frame('complete', { job: id, exitCode: cancelled ? null : 0, signal: cancelled ? 'SIGKILL' : null,
      cancelled, produced: { stdout: String(stdout.length), stderr: String(stderr.length) } });
  }
}

export async function ownerFixture(t, { progress = () => {}, open = true, joinBarrier, retirementError = false, nativeResult } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-linux-control-'));
  const assets = join(directory, 'assets'), data = join(directory, 'private');
  await mkdir(assets); const hash = bytes => createHash('sha256').update(bytes).digest('hex');
  const manifest = {}, archive = Buffer.from('explicit archive transport boundary, not a bootable guest');
  for (const [key, file] of Object.entries({ bios: 'bbl64.bin', kernel: 'kernel-riscv64.bin', tools: 'tools.block', bootstrap: 'bootstrap.ext4.gz', empty: 'empty.ext4.gz' })) {
    const expanded = Buffer.alloc(1024, key.length), compressed = key === 'bootstrap' || key === 'empty';
    const bytes = compressed ? gzipSync(expanded) : expanded, path = join(assets, file); await writeFile(path, bytes);
    manifest[key] = { path, bytes: bytes.length, sha256: hash(bytes), ...(compressed ? { expandedBytes: expanded.length, expandedSha256: hash(expanded) } : {}) };
  }
  manifest.archive = { url: 'https://fixture.invalid/pinned-base', bytes: archive.length, sha256: hash(archive) };
  await writeFile(join(assets, 'install-manifest.json'), JSON.stringify(Object.fromEntries(Object.entries(manifest).map(([key, item]) =>
    [key, key === 'archive' ? item : { ...item, path: item.path.slice(assets.length + 1) }]))));
  const server = net.createServer(); server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const accepted = once(server, 'connection'), socket = net.connect(server.address().port, '127.0.0.1');
  socket.on('error', () => {}); await once(socket, 'connect'); const [remote] = await accepted;
  const peer = new GuestPeer(remote); peer.on('command', command => { if (command.op === 'close') peer.frame('closed', { rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' }); });
  let created = 0, stopped = 0, joined = 0, owner;
  const options = { directory: data, nativeLibraryDirectory: '/trusted/native', manifest, onProgress: progress };
  const internals = {
    // The session/guest are explicit controlled boundaries; exclusion is the
    // real linked native flock also used by production, never a JS mutex.
    lockExclusive: process._linkedBinding('dsh_ohos_publication').lockExclusive,
    download: { fetch: async () => new Response(archive, { status: 200 }) },
    createSession(configPath) {
      created++; const config = JSON.parse(readFileSync(configPath, 'utf8'));
      peer.epoch = config.cmdline.match(/dsh\.epoch=([a-f0-9]{64})/)[1];
      if (open) setImmediate(() => peer.opened());
      return { socket, requestStop() { stopped++; }, async join() {
        joined++; await joinBarrier; return nativeResult ?? { joined: true, ownerQuarantined: true, retirementError, apiResult: -4 };
      } };
    },
  };
  const createOwner = overrides => owner = new LinuxInstallationOwner({ ...options, ...overrides }, internals);
  t.after(async () => { socket.destroy(); remote.destroy(); await owner?.dispose().catch(() => {});
    await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true }); });
  return { directory, assets, data, manifest, peer, socket, createOwner, options, internals,
    counts: () => ({ created, stopped, joined }), read: path => readFile(path) };
}
