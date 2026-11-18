// Production bootstrap/provider/native-channel with a synthetic N-API boundary.
// The FD below is owned by this fixture; native Owner/Env lifetime has its own test.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { closeSync, constants, fstatSync, mkdirSync, mkdtempSync, openSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { installGuestOwner } from './runtime/ios/guest/bootstrap.mjs';

const key = Symbol.for('dsh.go.ios.guest.owner');
function fixture(t, invalidIdentity = false) {
  const base = mkdtempSync(join(tmpdir(), 'root-grants-channel-'));
  const root = join(base, 'root'), temporaryRoot = join(base, 'guest-temp'), workspace = join(base, 'work');
  for (const path of [root, temporaryRoot, workspace, join(root, 'data')]) mkdirSync(path);
  writeFileSync(join(root, 'meta.db'), 'fixture-only');
  writeFileSync(join(root, 'installed.json'), JSON.stringify({ schema: 1, version: '3.24.4',
    archiveSHA256: '4b14c18f7e90a063b61462ea1462a5732c154bf6adad594974fe6487cd98a8de' }));
  const fd = openSync(root, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  const held = fstatSync(fd, { bigint: true });
  const identity = Object.freeze({ expectedRootDevice: held.dev.toString(),
    expectedRootInode: (held.ino + (invalidIdentity ? 1n : 0n)).toString() });
  const observed = { identities: 0, starts: 0, approvals: 0 };
  let owner;
  t.after(async () => {
    try { await owner?.dispose(); }
    finally { closeSync(fd); if (globalThis[key] === owner) delete globalThis[key]; rmSync(base, { recursive: true, force: true }); }
  });
  const native = {
    status: () => ({ available: true, state: 'cold' }),
    rootIdentity(path) { assert.equal(path, root); observed.identities++; return identity; },
    start(_request, event) {
      const id = ++observed.starts;
      queueMicrotask(() => event({ id, type: 'exit', error: 35, errorCode: 'ios_guest_suspended',
        exitCode: -1, resourcesSettled: true, abandoned: false }));
      return id;
    },
    cancel() {}, kill() {}, abandon() {}, ack() {}, stdinWrite() { throw Error('No started task'); }, stdinClose() {},
  };
  const metadata = { v: 1, source: 'ios-native-owner', state: 'ready', installed: 'present',
    available: true, enforcement: 'partial', python: 'unknown' };
  const policy = { mode: 'danger-full-access', workspaceRoot: workspace };
  const call = new AbortController(), task = new AbortController(), argv = ['bash', '-c', 'true'];
  const authorize = () => owner.authorizeRootWrite({ reason: 'fixture root request', command: 'true',
    cwd: workspace, policy, agent: { session: {} }, callId: 'fixture-call', signal: call.signal,
    approver: { async request() { observed.approvals++; return 'allowed-once'; } } });
  return { fd, identity, observed, workspace, policy, task, argv, authorize,
    install() { return owner = installGuestOwner({ native, root, temporaryRoot, protectedPaths: [], readMetadata: () => metadata }); } };
}

test('bootstrap never substitutes a fresh lstat for a mismatched native identity', t => {
  const f = fixture(t, true);
  assert.throws(() => f.install(), { code: 'ERR_IOS_GUEST_ROOT_GRANT' });
  assert.equal(f.observed.identities, 1);
  assert.equal(f.observed.starts, 0);
  assert.equal(globalThis[key], undefined);
});

test('a real native-channel suspension latch blocks later root approval and staged authority', async t => {
  const f = fixture(t), owner = f.install();
  const policy = await f.authorize();
  const ticket = owner.prepareRootGrant(f.argv, policy, f.task.signal);
  let stderr = '';
  const execute = () => owner.provider.execute({ decision: { route: 'guest' }, argv: f.argv,
    cwd: f.workspace, policy: f.policy, env: {}, stdin: '', graceMs: 100,
    output: async (_, bytes) => { stderr += bytes; } });
  assert.equal((await execute()).exitCode, 126);
  assert.match(stderr, /ERR_IOS_GUEST_SUSPENDED/);
  assert.equal(owner.provider.metadata.suspended, true);
  assert.equal(f.observed.starts, 1);
  await assert.rejects(f.authorize(), { code: 'ERR_IOS_GUEST_SUSPENDED' });
  assert.equal(f.observed.approvals, 1);
  assert.throws(() => owner.activateRootGrant(ticket, f.argv, policy, f.workspace, f.task.signal), { code: 'ERR_IOS_GUEST_SUSPENDED' });
  assert.throws(() => owner.activateRootGrant(ticket, f.argv, policy, f.workspace, f.task.signal), { code: 'ERR_IOS_GUEST_ROOT_GRANT' });
  // The N-API status is still cold/available, as after a disk marker resume;
  // the existing JS owner keeps its latch and cannot acquire a new identity.
  assert.equal((await execute()).exitCode, 126);
  assert.equal(f.observed.starts, 1);
  assert.equal(f.observed.identities, 1);
  await owner.dispose();
  assert.equal(fstatSync(f.fd, { bigint: true }).ino.toString(), f.identity.expectedRootInode);
});
