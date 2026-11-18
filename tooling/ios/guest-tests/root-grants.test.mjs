// Capability tests use synthetic ApprovalService answers. A fixture-owned FD
// emulates native.rootIdentity; native Owner teardown is tested separately.
import { createRootWriteGrants } from '../../../runtime/ios/guest/root-grants.mjs';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { closeSync, constants, fstatSync, lstatSync, mkdirSync, mkdtempSync, openSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const grantError = { code: 'ERR_IOS_GUEST_ROOT_GRANT' };
const pausedError = { code: 'ERR_IOS_GUEST_SUSPENDED' };
function fixture(t, mode = 'workspace-write') {
  const base = mkdtempSync(join(tmpdir(), 'root-grant-'));
  const root = join(base, 'root'), workspace = join(base, 'workspace');
  mkdirSync(root); mkdirSync(workspace);
  let fd, owner;
  t.after(() => { owner?.close(); if (fd !== undefined) closeSync(fd); rmSync(base, { recursive: true, force: true }); });
  fd = openSync(root, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  const held = fstatSync(fd, { bigint: true });
  const identity = Object.freeze({ expectedRootDevice: held.dev.toString(), expectedRootInode: held.ino.toString() });
  const state = { suspended: false, reads: 0, approvals: 0 };
  const readMetadata = () => { state.reads++; return { suspended: state.suspended }; };
  owner = createRootWriteGrants({ root, identity, readMetadata });
  const call = new AbortController(), task = new AbortController(), agent = { session: {} };
  const argv = ['bash', '-c', 'true'], policy = { mode, workspaceRoot: workspace };
  const argumentsForApproval = { reason: 'unit fixture', command: 'true', cwd: workspace,
    policy, agent, callId: 'call1', signal: call.signal,
    approver: { async request() { state.approvals++; return 'allowed-once'; } } };
  return { owner, root, workspace, fd, identity, state, readMetadata, call, task, agent, argv, policy,
    issue: overrides => owner.authorize({ ...argumentsForApproval, ...overrides }),
    activate: (ticket, policy) => owner.activate(ticket, argv, policy, workspace, task.signal) };
}

test('a root grant is consumed once at prepare and once at activate', async t => {
  const f = fixture(t), policy = await f.issue(), ticket = f.owner.prepare(f.argv, policy, f.task.signal);
  assert.deepEqual(f.activate(ticket, policy), f.identity);
  assert.throws(() => f.activate(ticket, policy), grantError);
  assert.throws(() => f.owner.prepare(f.argv, policy, f.task.signal), grantError);
  assert.equal(f.state.approvals, 1);
});

test('public flags and structured clones cannot convey root authority', async t => {
  const f = fixture(t), policy = await f.issue();
  assert.equal(f.owner.prepare(f.argv, { ...f.policy, rootWritable: true, linux_root_write: 'forged' }, f.task.signal), undefined);
  const cloned = structuredClone(policy);
  assert.equal(Object.getOwnPropertySymbols(cloned).length, 0);
  assert.equal(f.owner.prepare(f.argv, cloned, f.task.signal), undefined);
  const fake = { ...f.policy };
  Object.defineProperty(fake, Object.getOwnPropertySymbols(policy)[0], { get() { throw Error('getter executed'); } });
  assert.throws(() => f.owner.prepare(f.argv, fake, f.task.signal), grantError);
});

for (const mode of ['read-only', 'workspace-write', 'danger-full-access']) {
  test(`${mode} still needs independent root approval and retains its workspace mode`, async t => {
    const f = fixture(t, mode);
    assert.equal(f.owner.prepare(f.argv, f.policy, f.task.signal), undefined);
    const policy = await f.issue();
    assert.equal(policy.mode, mode);
    assert.equal(f.state.approvals, 1);
    assert.deepEqual(f.activate(f.owner.prepare(f.argv, policy, f.task.signal), policy), f.identity);
  });
}

for (const point of ['call-before-prepare', 'call-after-prepare', 'task-abort', 'wrong-signal',
  'wrong-command', 'wrong-cwd', 'wrong-workspace', 'wrong-mode', 'closed-owner']) {
  test(`changed or cancelled authority fails closed: ${point}`, async t => {
    const f = fixture(t), policy = await f.issue();
    assert.throws(() => {
      if (point === 'call-before-prepare') f.call.abort();
      if (point === 'wrong-command') f.argv[2] = 'false';
      if (point === 'wrong-workspace') policy.workspaceRoot = f.root;
      if (point === 'wrong-mode') policy.mode = 'danger-full-access';
      const ticket = f.owner.prepare(f.argv, policy, f.task.signal);
      if (point === 'call-after-prepare') f.call.abort();
      if (point === 'task-abort') f.task.abort();
      if (point === 'closed-owner') f.owner.close();
      f.owner.activate(ticket, f.argv, policy, point === 'wrong-cwd' ? f.root : f.workspace,
        point === 'wrong-signal' ? new AbortController().signal : f.task.signal);
    }, grantError);
  });
}

test('session changes during approval cannot issue a grant', async t => {
  const f = fixture(t);
  await assert.rejects(f.issue({ approver: { async request() { f.agent.session = {}; return 'allowed-once'; } } }), grantError);
});

test('only allowed-once can authorize root writes', async t => {
  const f = fixture(t);
  for (const outcome of ['denied', 'cancelled', 'allowed-always', undefined]) {
    await assert.rejects(f.issue({ approver: { async request() { return outcome; } } }), { code: 'ERR_IOS_GUEST_ROOT_APPROVAL' });
  }
});

test('known suspension rejects before a root approval request', async t => {
  const f = fixture(t); f.state.suspended = true;
  await assert.rejects(f.issue(), pausedError);
  assert.equal(f.state.approvals, 0);
});

test('suspension while an approval is pending prevents issuance', async t => {
  const f = fixture(t);
  await assert.rejects(f.issue({ approver: { async request() { f.state.suspended = true; return 'allowed-once'; } } }), pausedError);
});

for (const phase of ['prepare', 'activate']) {
  test(`suspension at ${phase} consumes authority permanently`, async t => {
    const f = fixture(t), policy = await f.issue();
    const ticket = phase === 'activate' ? f.owner.prepare(f.argv, policy, f.task.signal) : undefined;
    f.state.suspended = true;
    const consume = () => phase === 'prepare' ? f.owner.prepare(f.argv, policy, f.task.signal) : f.activate(ticket, policy);
    assert.throws(consume, pausedError);
    f.state.suspended = false;
    assert.throws(consume, grantError);
  });
}

test('plain no-grant prepare/activate never probe metadata or root paths', t => {
  const f = fixture(t); f.state.suspended = true; f.state.reads = 0;
  rmSync(f.root, { recursive: true });
  assert.equal(f.owner.prepare(f.argv, f.policy, f.task.signal), undefined);
  assert.equal(f.activate(undefined, f.policy), undefined);
  assert.equal(f.state.reads, 0);
});

test('native identity is mandatory, immutable, and checked on construction', t => {
  const f = fixture(t);
  for (const identity of [undefined, {}, { ...f.identity, expectedRootInode: '01' },
    { ...f.identity, expectedRootInode: '18446744073709551616' },
    { ...f.identity, expectedRootInode: (BigInt(f.identity.expectedRootInode) + 1n).toString() }]) {
    assert.throws(() => createRootWriteGrants({ root: f.root, identity, readMetadata: f.readMetadata }), grantError);
  }
});

for (const phase of ['approval', 'prepare', 'activate']) {
  test(`deletion/reinstallation after ${phase} cannot reuse an approval`, async t => {
    const f = fixture(t);
    let policy, ticket;
    const replace = () => { rmSync(f.root, { recursive: true }); mkdirSync(f.root); };
    if (phase === 'approval') {
      await assert.rejects(f.issue({ approver: { async request() { replace(); return 'allowed-once'; } } }), grantError);
    } else {
      policy = await f.issue();
      if (phase === 'activate') ticket = f.owner.prepare(f.argv, policy, f.task.signal);
      replace();
      assert.throws(() => phase === 'prepare' ? f.owner.prepare(f.argv, policy, f.task.signal) : f.activate(ticket, policy), grantError);
    }
    const replacement = lstatSync(f.root, { bigint: true });
    assert.notEqual(replacement.ino.toString(), f.identity.expectedRootInode);
    // Revocation must not close an anchor still owned by a native coordinator.
    f.owner.close(); f.owner.close();
    assert.equal(fstatSync(f.fd, { bigint: true }).ino.toString(), f.identity.expectedRootInode);
  });
}
