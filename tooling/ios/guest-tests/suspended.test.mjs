import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { GuestProvider } from '../../../runtime/ios/guest/provider.mjs';
import { createGuestMetadataStore, guestMetadataView, guestSuspendedMessage } from '../../../runtime/ios/guest/metadata.mjs';
import { installSuspendedGuestOwner } from '../../../runtime/ios/guest/suspended.mjs';
import { createNativeGuestChannel } from '../../../runtime/ios/guest/native-channel.mjs';
import { SerialGuestChannel } from '../../../runtime/ios/guest/channel.mjs';

const run = promisify(execFile);
const suspended = { v: 1, source: 'ios-native-owner', state: 'suspended',
  installed: 'present', available: false, enforcement: 'partial', python: 'unknown' };
const request = { decision: { route: 'guest' }, argv: ['sh', '-c', 'python3 -V'] };

test('a suspended launch executes the real preload without loading the addon', async () => {
  const root = await mkdtemp(join(tmpdir(), 'ios-guest-suspended-'));
  try {
    await mkdir(join(root, 'runtime/ohos'), { recursive: true });
    await mkdir(join(root, 'runtime/ios'), { recursive: true });
    await symlink(fileURLToPath(new URL('../../../runtime/ios/guest', import.meta.url)), join(root, 'runtime/ios/guest'), 'dir');
    const preload = await readFile(new URL('../guest-preload.js.txt', import.meta.url), 'utf8');
    const fixture = `
      import assert from 'node:assert/strict';
      const snapshot = ${JSON.stringify({ installed: true, suspended: true, metadata: suspended })};
      let loads = 0;
      process.dlopen = () => { loads++; throw new Error('must not load guest'); };
      process._linkedBinding = name => {
        assert.equal(name, 'dsh_ios_guest_config');
        return { read: () => JSON.stringify(snapshot) };
      };
      ${preload}
      const owner = globalThis[Symbol.for('dsh.go.ios.guest.owner')];
      assert.equal(owner.provider.metadata.state, 'suspended');
      assert.equal(owner.provider.metadata.available, false);
      for (let attempt = 0; attempt < 2; attempt++) {
        let text = '';
        const result = await owner.provider.execute({ ...${JSON.stringify(request)}, output: async (_, bytes) => { text += bytes; } });
        assert.equal(result.exitCode, 126);
        assert.match(text, /ERR_IOS_GUEST_SUSPENDED/);
      }
      assert.equal(loads, 0);
      assert.equal(owner.temporaryRoot, undefined);
      await owner.dispose();
      assert.equal(globalThis[Symbol.for('dsh.go.ios.guest.owner')], undefined);
      console.log('suspended preload: dlopen=0, two attempts rejected');
    `;
    const file = join(root, 'runtime/ohos/test-preload.mjs');
    await writeFile(file, fixture);
    const { stdout } = await run(process.execPath, [file], { timeout: 10000 });
    assert.match(stdout, /dlopen=0/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('suspension remains visible without a native transport or after queue faults', () => {
  for (const hasTransport of [false, true]) {
    for (const queueState of [undefined, 'ready', 'faulted', 'closed']) {
      const value = guestMetadataView(suspended, hasTransport, queueState);
      assert.equal(value.state, 'suspended');
      assert.equal(value.suspended, true);
      assert.equal(value.suspendedReason, 'crashed');
      assert.equal(value.available, false);
    }
  }
  const store = createGuestMetadataStore();
  assert.equal(store.publishJSON(JSON.stringify({ ...suspended, state: 'ready', available: true, suspended: true })), true);
  assert.equal(store.read().available, false);
  assert.equal(store.read().state, 'suspended');
});

test('resuming the source does not unpause a running engine snapshot', async () => {
  const snapshot = { ...suspended };
  const owner = installSuspendedGuestOwner({ readMetadata: () => snapshot });
  try {
    snapshot.state = 'ready'; snapshot.available = true;
    let text = '';
    const result = await owner.provider.execute({ ...request, output: async (_, bytes) => { text += bytes; } });
    assert.equal(result.exitCode, 126);
    assert.match(text, /ERR_IOS_GUEST_SUSPENDED/);
    assert.equal(owner.provider.metadata.state, 'suspended');
  } finally { await owner.dispose(); }
});

test('a suspended provider rejects before resolving paths or starting a channel', async () => {
  let starts = 0;
  const provider = new GuestProvider({ readMetadata: () => suspended,
    channel: { exec() { starts++; throw new Error('must not start'); } } });
  let text = '';
  const result = await provider.execute({ ...request, output: async (_, bytes) => { text += bytes; } });
  assert.equal(result.exitCode, 126);
  assert.equal(text, guestSuspendedMessage + '\n');
  assert.equal(starts, 0);
  await provider.dispose();
});

test('native rejection of a stale startup snapshot reports suspension, independent of errno', async () => {
  let callback;
  const native = { start(_, cb) { callback = cb; return 3n; }, status() { return { state: 'cold' }; } };
  const channel = createNativeGuestChannel(native, { root: '/fixture/rootfs', readInstallation: () => 'present' });
  let text = '';
  const operation = channel.exec({ mounts: [{ host: '/fixture/work', guest: '/workspace' },
    { host: '/fixture/tmp', guest: '/tmp' }], mode: 'read-only', cwd: '/workspace',
    argv: ['/bin/sh', '-c', 'python3 -V'], env: {}, stdin: '' }, async (_, bytes) => { text += bytes; });
  callback({ id: 3n, type: 'exit', error: 12345, errorCode: 'ios_guest_suspended',
    exitCode: -1, abandoned: false, resourcesSettled: true });
  const result = await operation.finished;
  assert.equal(result.exitCode, 126);
  assert.equal(text, guestSuspendedMessage + '\n');
});

test('suspension latches before output settles and blocks already queued work until a new owner', async () => {
  let callback, starts = 0;
  const native = { start(_, cb) { starts++; callback = cb; return 7n; }, status() { return { state: 'cold' }; } };
  const channel = createNativeGuestChannel(native, { root: '/fixture/rootfs', readInstallation: () => 'present' });
  const serial = new SerialGuestChannel(channel);
  const queued = { mounts: [{ host: '/fixture/work', guest: '/workspace' },
    { host: '/fixture/tmp', guest: '/tmp' }], mode: 'read-only', cwd: '/workspace',
    argv: ['/bin/sh', '-c', 'python3 -V'], env: {}, stdin: '' };
  const gate = Promise.withResolvers();
  const first = serial.execute(queued, { graceMs: 100, output: async () => gate.promise });
  let secondText = '';
  const second = serial.execute(queued, { graceMs: 100, output: async (_, bytes) => { secondText += bytes; } });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(starts, 1);
  callback({ id: 7n, type: 'exit', error: 12345, errorCode: 'ios_guest_suspended',
    exitCode: -1, abandoned: false, resourcesSettled: true });
  assert.equal(channel.suspended, true);
  // Even if Settings has already cleared the persistent marker, this stable
  // native outcome belongs to the old generation and must remain suspended.
  native.status = () => ({ state: 'ready', available: true });
  const provider = new GuestProvider({ channel,
    readMetadata: () => ({ ...suspended, state: 'ready', available: true }) });
  assert.equal(provider.metadata.state, 'suspended');
  assert.equal(provider.metadata.available, false);
  gate.resolve();
  assert.equal((await first).exitCode, 126);
  assert.equal((await second).exitCode, 126);
  assert.match(secondText, /ERR_IOS_GUEST_SUSPENDED/);
  assert.equal(starts, 1);
  await serial.dispose();
  await provider.dispose();
  const fresh = createNativeGuestChannel(native, { root: '/fixture/rootfs' });
  assert.equal(fresh.suspended, false);
});
