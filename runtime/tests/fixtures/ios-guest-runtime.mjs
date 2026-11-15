// Executed only inside the generated, isolated test tree. Native execution is
// recorded, not emulated: these tests prove routing/approval, not iSH readiness.
import test from 'node:test';
import assert from 'node:assert/strict';
import { closeSync, constants, fstatSync, openSync } from 'node:fs';
import { mkdtemp, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { Context } from '@deepseek-ai/cordis';
import { SystemPrompt } from '@deepseek-ai/dsh-system-prompt';
import { ToolRuntime } from '@deepseek-ai/dsh-tools';
import * as nativeTools from '@deepseek-ai/dsh-tool-executor-native';
import { SessionProjectionRegistry } from '@deepseek-ai/dsh-session-projection';
import { SandboxPolicyService } from '@deepseek-ai/dsh-sandbox-policy';
import { LocalFileSystem } from '@deepseek-ai/dsh-fs-local';
import { WorkingDirectoryService } from '@deepseek-ai/dsh-working-directory';
import { ShellEnvRegistry } from '@deepseek-ai/dsh-shell-env';
import { ApprovalService } from '@deepseek-ai/dsh-user-approval';
import { SandboxBashExecutor } from '@deepseek-ai/dsh-bash-sandbox';
import { Session } from '@deepseek-ai/dsh-session';
import * as toolBash from '@deepseek-ai/dsh-tool-bash';
import Subprocess from './runtime/ohos/process/index.mjs';
import Sandbox from './runtime/ohos/process/sandbox.mjs';
import { GuestProvider } from './runtime/ios/guest/provider.mjs';
import { guestDescription } from './runtime/ios/guest/metadata.mjs';
import { createRootWriteGrants } from './runtime/ios/guest/root-grants.mjs';
import { installSuspendedGuestOwner } from './runtime/ios/guest/suspended.mjs';

const ownerKey = Symbol.for('dsh.go.ios.guest.owner');
const exists = path => stat(path).then(() => true, () => false);
let sequence = 0;
async function setup(t, { mode = 'workspace-write', guest = true, suspended = false } = {}) {
  // Like an iOS container, host mounts must not overlap the virtual /tmp alias.
  const base = await mkdtemp(join(homedir(), '.ios-tool-policy-'));
  const [work, temporary, guestTemp, guestRoot] = ['work', 'temp', 'guest-temp', 'guest-root'].map(name => join(base, name));
  await Promise.all([work, temporary, guestTemp, guestRoot].map(path => mkdir(path)));
  const ctx = new Context();
  let grants, rootFD, rootIdentity;
  t.after(async () => {
    try { await ctx.fiber.dispose(); }
    finally {
      grants?.close();
      if (rootFD !== undefined) closeSync(rootFD);
      delete globalThis[ownerKey];
      await rm(base, { recursive: true, force: true });
    }
  });
  const requests = [];
  const metadata = { v: 1, source: 'ios-native-owner', state: 'ready', installed: 'present', available: true,
    enforcement: 'partial', python: 'unknown' };
  const provider = guest && !suspended && new GuestProvider({ temporaryRoot: guestTemp, readMetadata: () => metadata,
    channel: {
      exec(request, output) {
        requests.push(request);
        const missing = request.argv.includes('echo before > marker; missing_linux_command');
        return { finished: Promise.resolve().then(async () => {
          await output(missing ? 'stderr' : 'stdout', Buffer.from(missing ? 'missing_linux_command: not found\n' : 'recorded-linux\n'));
          return { exitCode: missing ? 127 : 0, signal: null, resourcesSettled: true };
        }), signal() {}, abandon() {} };
      }, dispose() {},
    } });
  if (guest && suspended) installSuspendedGuestOwner({ readMetadata: () => metadata });
  else if (guest) {
    // Test-only identity owner: real native Owner lifetime is checked by its
    // separate N-API test. These tests use the production grant/approval path.
    rootFD = openSync(guestRoot, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    const held = fstatSync(rootFD, { bigint: true });
    rootIdentity = Object.freeze({ expectedRootDevice: held.dev.toString(), expectedRootInode: held.ino.toString() });
    grants = createRootWriteGrants({ root: guestRoot, identity: rootIdentity, readMetadata: () => provider.metadata });
    globalThis[ownerKey] = { provider, temporaryRoot: guestTemp, description: guestDescription,
      authorizeRootWrite: grants.authorize, prepareRootGrant: grants.prepare, activateRootGrant: grants.activate,
      async dispose() { try { await provider.dispose(); } finally { grants.close(); } } };
  }
  await ctx.plugin(SystemPrompt, {});
  await ctx.plugin(ToolRuntime);
  await ctx.plugin(nativeTools);
  await ctx.plugin(SessionProjectionRegistry);
  await ctx.plugin(SandboxPolicyService, { mode, workspaceRoot: work });
  await ctx.plugin(LocalFileSystem, { cwd: work });
  await ctx.plugin(WorkingDirectoryService, { defaultDirectory: work });
  await ctx.plugin(ShellEnvRegistry, { dshHome: temporary });
  await ctx.plugin(ApprovalService, { policy: 'ask' });
  await ctx.plugin(Subprocess, { workspaceRoots: [work], temporaryRoot: temporary });
  await ctx.plugin(Sandbox);
  await ctx.plugin(SandboxBashExecutor, { cwd: work, timeoutMs: 10000, maxTimeoutMs: 15000,
    maxOutputBytes: 65536, maxSpillBytes: 1048576, graceMs: 200 });
  await ctx.plugin(toolBash, { enableRunInBackground: false, promoteOnTimeout: false });
  const id = `ios-guest-${++sequence}`;
  const session = Session.create(id, undefined, { version: 4, id, createdAt: Date.now(), isSeeded: false, cwd: work });
  session.append('turn/start', { turn: 1 });
  const agent = { id, session, ctx, inject() {} };
  const execute = async (command, args = {}) => {
    const batch = await ctx.tools.execute({ agent, signal: new AbortController().signal,
      calls: [{ id: `call-${++sequence}`, name: 'bash', arguments: JSON.stringify({ description: 'iOS guest regression', command, ...args }) }] });
    return batch.results[0].result;
  };
  const spawn = argv => ctx.subprocess.spawn({ argv, cwd: work, env: {}, graceMs: 200,
    stdio: { stdin: 'ignore', stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } } });
  return { ctx, work, temporary, guestTemp, rootIdentity, requests, execute, spawn };
}

for (const mode of ['read-only', 'workspace-write', 'danger-full-access']) {
  test(`real tool and one-use policy reach Linux in ${mode}`, async t => {
    const { ctx, work, guestTemp, requests, execute } = await setup(t, { mode });
    const result = await execute('cat /etc/os-release');
    assert.equal(result.isError, false, JSON.stringify(result));
    assert.equal(result.value.exitCode, 0, JSON.stringify(result));
    assert.equal(result.value.stdout.text, 'recorded-linux\n');
    assert.equal(result.value.sandbox.mode, mode);
    assert.equal(result.value.sandbox.enforcement, 'partial');
    assert.equal(requests.length, 1);
    assert.deepEqual(requests[0].argv, ['/bin/sh', '-c', 'cat /etc/os-release']);
    assert.equal(requests[0].cwd, '/workspace');
    assert.equal(requests[0].mode, mode === 'read-only' ? 'read-only' : 'workspace-write');
    assert.equal(requests[0].rootWritable, false);
    assert.equal(Object.hasOwn(requests[0], 'expectedRootDevice'), false);
    assert.deepEqual(requests[0].mounts, [
      { host: work, guest: '/workspace', readOnly: mode === 'read-only' },
      { host: guestTemp, guest: '/tmp', readOnly: mode === 'read-only' },
    ]);
    assert.equal(ctx.subprocess.backend.prepared.size, 0);
  });
}

test('full-access escalation still waits for the real approval service', async t => {
  const { ctx, requests, execute } = await setup(t, { mode: 'read-only' });
  const asked = Promise.withResolvers(), answer = Promise.withResolvers();
  const off = ctx.on('approval/request', request => { asked.resolve(request); return answer.promise; });
  t.after(off);
  const running = execute('apk --version', { sandbox_permissions: 'danger-full-access', justification: 'Test approved Linux execution.' });
  await asked.promise;
  assert.equal(requests.length, 0);
  assert.equal(ctx.subprocess.backend.live.size, 0);
  answer.resolve('allowed-once');
  const result = await running;
  assert.equal(result.isError, false, JSON.stringify(result));
  assert.equal(result.value.exitCode, 0);
  assert.equal(result.value.sandbox.mode, 'danger-full-access');
  assert.equal(requests[0].mode, 'workspace-write');
});

test('a rejected escalation cannot reach the native channel', async t => {
  const { ctx, requests, execute } = await setup(t, { mode: 'read-only' });
  const off = ctx.on('approval/request', () => Promise.resolve('rejected'));
  t.after(off);
  const result = await execute('apk --version', { sandbox_permissions: 'danger-full-access', justification: 'Test rejection.' });
  assert.equal(result.isError, true);
  assert.equal(requests.length, 0);
  assert.equal(ctx.subprocess.backend.prepared.size, 0);
});

test('direct spawn has no inferred policy and cannot invoke Linux', async t => {
  const { requests, spawn } = await setup(t);
  const process = spawn(['bash', '-c', 'command -v apk']);
  const result = await process.done;
  assert.equal(result.exitCode, 126);
  assert.equal(requests.length, 0);
});

test('full-access tickets cannot be replayed or used after cancellation', async t => {
  const { ctx, work, spawn, requests } = await setup(t);
  const argv = ctx.subprocess.prepare(['bash', '-c', 'command -v apk'], { mode: 'danger-full-access', workspaceRoot: work });
  assert.equal((await spawn(argv).done).exitCode, 0);
  assert.equal(requests.length, 1);
  assert.throws(() => spawn(argv), { code: 'ERR_OHOS_INVALID_CONFINEMENT' });
  const controller = new AbortController();
  const cancelled = ctx.subprocess.prepare(['bash', '-c', 'apk --version'], { mode: 'danger-full-access', workspaceRoot: work }, controller.signal);
  controller.abort();
  assert.throws(() => spawn(cancelled), { code: 'ERR_OHOS_INVALID_CONFINEMENT' });
  assert.equal(requests.length, 1);
});

test('guest-only pipelines route atomically and do not perform virtual prefix writes', async t => {
  const { requests, work, execute } = await setup(t);
  const result = await execute('echo before > marker; apk --version | sed -n "1p"');
  assert.equal(result.value.exitCode, 0, JSON.stringify(result));
  assert.equal(requests.length, 1);
  assert.equal(await exists(join(work, 'marker')), false);
});

test('missing Linux commands return the guest error without virtual fallback', async t => {
  const { requests, work, execute } = await setup(t);
  const result = await execute('echo before > marker; missing_linux_command');
  assert.equal(result.value.exitCode, 127, JSON.stringify(result));
  assert.match(result.value.stderr.text, /missing_linux_command: not found/);
  assert.equal(requests.length, 1);
  assert.equal(await exists(join(work, 'marker')), false);
});

test('Node Worker remains real and mixed scripts are rejected before any prefix', async t => {
  const { requests, work, execute } = await setup(t);
  await writeFile(join(work, 'script.mjs'), 'process.stdout.write("actual-worker\\n");\n');
  const pure = await execute('node script.mjs | cat');
  assert.equal(pure.value.exitCode, 0, JSON.stringify(pure));
  assert.equal(pure.value.stdout.text, 'actual-worker\n');
  assert.equal(requests.length, 0);
  const mixed = await execute('echo before > marker; node script.mjs; apk --version');
  assert.equal(mixed.value.exitCode, 2, JSON.stringify(mixed));
  assert.match(mixed.value.stderr.text, /ERR_IOS_GUEST_MIXED/);
  assert.equal(requests.length, 0);
  assert.equal(await exists(join(work, 'marker')), false);
});

test('direct shell file and stdin argv route before the virtual interpreter reads them', async t => {
  const { ctx, work, spawn, requests } = await setup(t);
  for (const argv of [['sh', 'missing-script.sh'], ['bash', '-s']]) {
    const ticket = ctx.subprocess.prepare(argv, { mode: 'workspace-write', workspaceRoot: work });
    assert.equal((await spawn(ticket).done).exitCode, 0);
    assert.deepEqual(requests.at(-1).argv, ['/bin/sh', ...argv.slice(1)]);
  }
  assert.equal(requests.length, 2);
});

test('installed guest tool description does not advertise virtual Linux limitations', async t => {
  const { ctx } = await setup(t);
  const description = ctx.tools.get('bash').description;
  assert.match(description, /默认整段在 Linux/);
  assert.match(description, /Alpine ash/);
  assert.doesNotMatch(description, /iOS 本机使用虚拟 shell/);
  assert.doesNotMatch(description, /没有系统进程、PTY、Python 或 WASM/);
});

test('without a guest, full-access preserves the existing virtual backend', async t => {
  const { ctx, work, requests, execute } = await setup(t, { guest: false, mode: 'danger-full-access' });
  const result = await execute('printf virtual > output; cat output');
  assert.equal(result.value.exitCode, 0, JSON.stringify(result));
  assert.equal(result.value.stdout.text, 'virtual');
  assert.equal(await readFile(join(work, 'output'), 'utf8'), 'virtual');
  assert.equal(requests.length, 0);
  assert.equal(ctx.subprocess.guestMetadata, null);
  assert.match(ctx.tools.get('bash').description, /iOS 本机使用虚拟 shell/);
});

for (const mode of ['read-only', 'workspace-write', 'danger-full-access']) {
  test(`real root approval is independent and one-call only in ${mode}`, async t => {
    const { ctx, rootIdentity, requests, execute } = await setup(t, { mode });
    const asked = Promise.withResolvers(), answer = Promise.withResolvers();
    let approvals = 0;
    const off = ctx.on('approval/request', request => { approvals++; asked.resolve(request); return answer.promise; });
    t.after(off);
    const running = execute('echo persistent > /etc/test-root-grant', { linux_root_write: 'Test one persistent Linux change.' });
    const question = await asked.promise;
    assert.match(question.reason, /仅本次命令/);
    assert.equal(requests.length, 0);
    assert.equal(ctx.subprocess.backend.prepared.size, 0);
    answer.resolve('allowed-once');
    const result = await running;
    assert.equal(result.isError, false, JSON.stringify(result));
    assert.equal(result.value.exitCode, 0);
    assert.equal(result.value.sandbox.mode, mode);
    assert.equal(approvals, 1);
    assert.equal(requests[0].rootWritable, true);
    assert.equal(requests[0].expectedRootDevice, rootIdentity.expectedRootDevice);
    assert.equal(requests[0].expectedRootInode, rootIdentity.expectedRootInode);
    const next = await execute('cat /etc/test-root-grant');
    assert.equal(next.value.exitCode, 0);
    assert.equal(requests[1].rootWritable, false);
    assert.equal(approvals, 1);
  });
}

test('workspace escalation and root write require two ordered real approvals', async t => {
  const { ctx, requests, execute } = await setup(t, { mode: 'read-only' });
  const asked = [Promise.withResolvers(), Promise.withResolvers()];
  const answers = [Promise.withResolvers(), Promise.withResolvers()];
  let count = 0;
  const off = ctx.on('approval/request', request => {
    const index = count++;
    assert.ok(index < 2);
    asked[index].resolve(request);
    return answers[index].promise;
  });
  t.after(off);
  const running = execute('apk add fixture-package', { sandbox_permissions: 'danger-full-access',
    justification: 'Test workspace escalation.', linux_root_write: 'Test independent Linux package change.' });
  const workspace = await asked[0].promise;
  assert.match(workspace.reason, /workspace escalation/);
  assert.equal(requests.length, 0);
  answers[0].resolve('allowed-once');
  const root = await asked[1].promise;
  assert.match(root.reason, /Linux/);
  assert.equal(requests.length, 0);
  answers[1].resolve('allowed-once');
  const result = await running;
  assert.equal(result.isError, false, JSON.stringify(result));
  assert.equal(result.value.sandbox.mode, 'danger-full-access');
  assert.equal(count, 2);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].mode, 'workspace-write');
  assert.equal(requests[0].rootWritable, true);
});

test('real root approval rejection cannot publish an execution ticket', async t => {
  const { ctx, requests, execute } = await setup(t);
  let approvals = 0;
  const off = ctx.on('approval/request', () => { approvals++; return Promise.resolve('rejected'); });
  t.after(off);
  const result = await execute('apk add fixture-package', { linux_root_write: 'Test root rejection.' });
  assert.equal(result.isError, true);
  assert.equal(approvals, 1);
  assert.equal(requests.length, 0);
  assert.equal(ctx.subprocess.backend.prepared.size, 0);
});

for (const mode of ['workspace-write', 'danger-full-access']) {
test(`paused owner keeps virtual shell/Node Worker and skips root approval in ${mode}`, async t => {
  const { ctx, work, requests, execute } = await setup(t, { mode, suspended: true });
  let approvals = 0;
  const off = ctx.on('approval/request', () => { approvals++; return Promise.resolve('allowed-once'); });
  t.after(off);
  await writeFile(join(work, 'paused-node.mjs'), 'process.stdout.write("paused-node-ok\\n");\n');
  const node = await execute('node paused-node.mjs');
  assert.equal(node.value.exitCode, 0, JSON.stringify(node));
  assert.equal(node.value.stdout.text, 'paused-node-ok\n');
  const shell = await execute('printf virtual-ok > marker; cat marker');
  assert.equal(shell.value.exitCode, 0, JSON.stringify(shell));
  assert.equal(shell.value.stdout.text, 'virtual-ok');
  assert.equal(shell.value.sandbox.mode, mode);
  assert.equal(await readFile(join(work, 'marker'), 'utf8'), 'virtual-ok');
  const python = await execute('python3 -V');
  assert.equal(python.value.exitCode, 127, JSON.stringify(python));
  const root = await execute('apk add fixture-package', { linux_root_write: 'Test paused root request.' });
  assert.equal(root.isError, true);
  assert.match(JSON.stringify(root), /ERR_IOS_GUEST_SUSPENDED/);
  assert.equal(approvals, 0); // Standing mode already matches; no workspace escalation is requested.
  assert.equal(requests.length, 0);
  assert.equal(ctx.subprocess.backend.prepared.size, 0);
});
}
