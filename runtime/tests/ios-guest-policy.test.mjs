import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { GuestProvider } from '../ios/guest/provider.mjs';

function fixture(t) {
  const base = realpathSync(mkdtempSync(join(tmpdir(), 'ios-guest-policy-')));
  const workspace = join(base, 'workspace');
  const temporary = join(base, 'temporary');
  const outside = join(base, 'outside');
  const protectedRoot = join(base, 'state');
  for (const path of [workspace, temporary, outside, protectedRoot]) mkdirSync(path);
  const requests = [];
  const channel = {
    exec(request) {
      requests.push(request);
      return {
        finished: Promise.resolve({ exitCode: 0, signal: null, resourcesSettled: true }),
        signal() {},
      };
    },
  };
  const provider = new GuestProvider({ channel, temporaryRoot: temporary, forbiddenRoots: [join(base, 'state')] });
  t.after(async () => {
    await provider.dispose();
    rmSync(base, { recursive: true, force: true });
  });
  const execute = async (policy, extra = {}) => {
    const stderr = [];
    const result = await provider.execute({
      decision: { route: 'guest' }, argv: ['bash', '-c', 'uname -a'],
      policy, cwd: workspace, env: {}, stdin: '', graceMs: 1000,
      output: async (stream, bytes) => { if (stream === 'stderr') stderr.push(bytes.toString()); },
      ...extra,
    });
    return { result, stderr: stderr.join('') };
  };
  return { workspace, temporary, outside, protectedRoot, requests, execute };
}

for (const mode of ['read-only', 'workspace-write', 'danger-full-access']) {
  test(`${mode} keeps the same two authorized mounts`, async t => {
    const { workspace, temporary, outside, requests, execute } = fixture(t);
    const policy = Object.freeze({ mode, workspaceRoot: workspace });
    const { result } = await execute(policy, {
      // Neither caller hints nor environment entries can add a host mount.
      temporaryRoot: outside, env: { HOME: outside, TMPDIR: outside, PATH: outside },
    });
    assert.equal(result.exitCode, 0);
    assert.equal(requests.length, 1);
    const request = requests[0];
    assert.equal(request.mode, mode === 'read-only' ? 'read-only' : 'workspace-write');
    assert.deepEqual(request.mounts, [
      { host: workspace, guest: '/workspace', readOnly: mode === 'read-only' },
      { host: temporary, guest: '/tmp', readOnly: mode === 'read-only' },
    ]);
    assert.equal(request.cwd, '/workspace');
    assert.deepEqual(request.argv, ['/bin/sh', '-c', 'uname -a']);
    assert.equal(request.env.HOME, '/tmp');
    assert.equal(request.env.TMPDIR, '/tmp');
    assert.notEqual(request.env.PATH, outside);
    assert.equal(policy.mode, mode);
  });
}

test('guest shell file and stdin requests preserve arguments', async t => {
  const { workspace, requests, execute } = fixture(t);
  const stdin = Buffer.from('printf guest\\n');
  for (const argv of [
    ['sh'], ['bash', '-s', '--', 'argument'],
    ['bash', './scripts/task.sh', 'one', 'two words'],
  ]) {
    requests.length = 0;
    const { result } = await execute({ mode: 'danger-full-access', workspaceRoot: workspace }, { argv, stdin });
    assert.equal(result.exitCode, 0);
    assert.equal(requests.length, 1);
    assert.deepEqual(requests[0].argv, ['/bin/sh', ...argv.slice(1)]);
    assert.equal(requests[0].stdin, stdin);
    assert.equal(requests[0].cwd, '/workspace');
  }
});

test('invalid shell executables and malformed argument arrays never reach native execution', async t => {
  const { workspace, requests, execute } = fixture(t);
  for (const argv of [undefined, null, {}, [], ['node', 'task.mjs'], ['/bin/sh', '-c', 'true'],
    ['bash', 1], ['sh', 'bad\u0000argument'], ['sh', undefined], ['sh', , '-s']]) {
    const { result, stderr } = await execute({ mode: 'danger-full-access', workspaceRoot: workspace }, { argv });
    assert.equal(result.exitCode, 2);
    assert.match(stderr, /ERR_IOS_GUEST_ROUTE/);
  }
  assert.equal(requests.length, 0);
});

test('missing and unknown policies never reach native execution', async t => {
  const { workspace, requests, execute } = fixture(t);
  for (const policy of [undefined, null, {}, { mode: 'administrator', workspaceRoot: workspace }]) {
    const { result, stderr } = await execute(policy);
    assert.equal(result.exitCode, 126);
    assert.match(stderr, /IOS_GUEST_POLICY_REQUIRED/);
  }
  assert.equal(requests.length, 0);
});

test('full access still requires an authorized workspace and cwd', async t => {
  const { workspace, temporary, outside, requests, execute } = fixture(t);
  await assert.rejects(execute({ mode: 'danger-full-access' }), { code: 'EACCES' });
  await assert.rejects(execute({ mode: 'danger-full-access', workspaceRoot: workspace }, { cwd: outside }), { code: 'EACCES' });
  const { result, stderr } = await execute({ mode: 'danger-full-access', workspaceRoot: workspace }, { cwd: temporary });
  assert.equal(result.exitCode, 2);
  assert.match(stderr, /ERR_IOS_GUEST_CWD/);
  assert.equal(requests.length, 0);
});

test('full access cannot overlap protected app state', async t => {
  const { protectedRoot, requests, execute } = fixture(t);
  await assert.rejects(execute({ mode: 'danger-full-access', workspaceRoot: protectedRoot }, { cwd: protectedRoot }), { code: 'EACCES' });
  assert.equal(requests.length, 0);
});

test('unsupported decisions cannot execute even with a full-access policy', async t => {
  const { workspace, requests, execute } = fixture(t);
  const { result, stderr } = await execute({ mode: 'danger-full-access', workspaceRoot: workspace }, { decision: { route: 'unsupported' } });
  assert.equal(result.exitCode, 2);
  assert.match(stderr, /ERR_IOS_GUEST_MIXED/);
  assert.equal(requests.length, 0);
});
