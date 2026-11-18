import { symlinkFixture } from './host-link-fixture.mjs';
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import OhSubprocessRuntime from '../../ohos/process/index.mjs';
import OhSandboxProvider from '../../ohos/process/sandbox.mjs';

const require = createRequire(join(resolve(process.env.OHOS_TEST_PROCESS_PREFIX), 'package.json'));
const load = name => import(pathToFileURL(require.resolve(`@deepseek-ai/${name}`)));
const { default: z } = await load('schemastery');
const { NativeToolExecutor } = await load('dsh-tool-executor-native');
const [{ Context }, { SystemPrompt }, { ToolRuntime }, { SessionProjectionRegistry }, { SandboxPolicyService }, { LocalFileSystem }, { WorkingDirectoryService }, { ShellEnvRegistry }, { ApprovalService }, { SandboxBashExecutor }, { Session }, toolBash] = await Promise.all([
  'cordis', 'dsh-system-prompt', 'dsh-tools', 'dsh-session-projection', 'dsh-sandbox-policy', 'dsh-fs-local', 'dsh-working-directory', 'dsh-shell-env', 'dsh-user-approval', 'dsh-bash-sandbox', 'dsh-session', 'dsh-tool-bash',
].map(load));
let root, work, temp, outside, ctx, id = 0;
before(async () => {
  root = await mkdtemp(join(tmpdir(), 'ohos-policy-test-'));
  [work, temp, outside] = ['work', 'temp', 'outside'].map(part => join(root, part));
  await Promise.all([work, temp, outside].map(path => mkdir(path)));
  ctx = new Context();
  await ctx.plugin(SystemPrompt, {});
  await ctx.plugin(ToolRuntime, {});
  ctx.tools.setExecutor(new NativeToolExecutor(ctx));
  await ctx.plugin(SessionProjectionRegistry);
  ctx.sessionProjections.register({
    key: 'ohos-test-approval-audit', stateVersion: 1,
    stateSchema: z.array(z.any()), init: () => [],
    apply: (events, event) => event.type.startsWith('approval/') ? [...events, event] : events,
  });
  await ctx.plugin(SandboxPolicyService, { mode: 'read-only', workspaceRoot: work });
  await ctx.plugin(LocalFileSystem, { cwd: work });
  await ctx.plugin(WorkingDirectoryService, { defaultDirectory: work });
  await ctx.plugin(ShellEnvRegistry, { dshHome: temp });
  await ctx.plugin(ApprovalService, { policy: 'ask' });
  await ctx.plugin(OhSubprocessRuntime, { workspaceRoots: [work], temporaryRoot: temp });
  await ctx.plugin(OhSandboxProvider);
  await ctx.plugin(SandboxBashExecutor, { cwd: work, timeoutMs: 4000, maxTimeoutMs: 5000, maxOutputBytes: 65536, maxSpillBytes: 1048576, graceMs: 200 });
  await ctx.plugin(toolBash, { enableRunInBackground: false, promoteOnTimeout: false });
});
after(async () => {
  await ctx?.fiber.dispose();
  await rm(root, { recursive: true, force: true });
});
const exists = path => stat(path).then(() => true, () => false);
function agent(cwd = work) {
  const name = `ohos-agent-${++id}`;
  const session = Session.create(name, undefined, { version: 4, id: name, createdAt: Date.now(), isSeeded: false, cwd });
  session.append('turn/start', { turn: 1 });
  return { id: name, session, ctx, inject() {} };
}
const execute = async (owner, command, args = {}) => (await ctx.tools.execute({
  calls: [{ id: `call-${++id}`, name: 'bash',
    arguments: JSON.stringify({ description: '验证鸿蒙虚拟 shell 权限', command, ...args }) }],
  agent: owner, signal: new AbortController().signal,
})).results[0].result;

test('真实tool-bash展示同源命令清单及现有sandbox审批参数', async () => {
  const tool = ctx.tools.get('bash');
  assert.equal(ctx.shell.sandboxMode, 'read-only');
  assert.match(tool.description, /鸿蒙本机使用虚拟 shell/);
  assert.match(tool.description, /rg/);
  assert.match(tool.description, /只支持批量 stdin/);
  assert.equal(ctx.subprocess.capabilities.streamingOutput, true);
  assert.match(tool.description, /外层语句完成后交付输出/);
  assert.match(tool.description, /单个命令、管道和复合语句内部仍有缓冲/);
  assert.match(tool.description, /命令执行计数上限为 100000/);
  assert.match(tool.description, /退出码 126/);
  assert.match(tool.description, /已经完成的写入不会回滚/);
  assert.ok(tool.parameters.properties.sandbox_permissions);
});

test('默认read-only真实tool-bash读成功、写失败，输出原拒绝标记', async () => {
  const owner = agent();
  await writeFile(join(work, 'readable'), 'readable');
  const read = await execute(owner, 'cat readable');
  assert.equal(read.isError, false);
  assert.equal(read.value.stdout.text, 'readable');
  const denied = await execute(owner, 'echo blocked > denied');
  assert.equal(denied.isError, false);
  assert.notEqual(denied.value.exitCode, 0);
  assert.deepEqual(denied.value.sandbox, { mode: 'read-only', denied: true, enforcement: 'partial' });
  assert.match(denied.content[0].text, /\[sandbox: file access denied under read-only mode\]/);
  assert.equal(await exists(join(work, 'denied')), false);
});

test('真实ApprovalService等待答复前不写；一次批准后才写并记录asked/decided', async () => {
  const owner = agent();
  const asked = Promise.withResolvers(), answer = Promise.withResolvers();
  const off = ctx.on('approval/request', request => { asked.resolve(request); return answer.promise; });
  try {
    const running = execute(owner, 'echo granted > approved', { sandbox_permissions: 'workspace-write', justification: '写入这个测试文件以验证一次批准生效。' });
    const request = await asked.promise;
    assert.equal(request.toolName, 'bash');
    assert.equal(await exists(join(work, 'approved')), false);
    assert.equal(ctx.subprocess.backend.live.size, 0);
    answer.resolve('allowed-once');
    const result = await running;
    assert.equal(result.isError, false, JSON.stringify(result));
    assert.equal(result.value.exitCode, 0);
    assert.equal(result.value.sandbox.mode, 'workspace-write');
    assert.equal(await readFile(join(work, 'approved'), 'utf8'), 'granted\n');
    const events = ctx.sessionProjections.stateOf(owner.session, 'ohos-test-approval-audit');
    assert.deepEqual(events.map(event => event.type), ['approval/asked', 'approval/decided']);
    assert.equal(events[1].data.outcome, 'allowed-once');
    const next = await execute(owner, 'echo forbidden > once-only');
    assert.equal(next.value.sandbox.mode, 'read-only');
    assert.equal(await exists(join(work, 'once-only')), false);
  } finally { off(); }
});

test('拒绝与缺失答复通道都在工具执行前关闭，保留审批审计', async () => {
  const owner = agent();
  let off = ctx.on('approval/request', () => Promise.resolve('rejected'));
  const args = { sandbox_permissions: 'workspace-write', justification: '仅作为拒绝回归测试。' };
  const rejected = await execute(owner, 'echo forbidden > rejection', args);
  off();
  assert.equal(rejected.isError, true);
  assert.equal(await exists(join(work, 'rejection')), false);
  const unavailable = await execute(agent(), 'echo forbidden > unavailable', args);
  assert.equal(unavailable.isError, true);
  assert.equal(await exists(join(work, 'unavailable')), false);
  assert.equal(ctx.subprocess.backend.live.size, 0);
});

test('workspace-write按调用Session根收窄，不能沿内部符号链接写入另一个授权工作区', async () => {
  const a = join(work, 'session-a'), b = join(work, 'session-b');
  await Promise.all([mkdir(a), mkdir(b)]);
  await writeFile(join(b, 'secret'), 'unchanged');
  await symlinkFixture(b, join(a, 'escape'));
  const owner = agent(a);
  owner.session.append('sandbox/mode', { mode: 'workspace-write' });
  const success = await execute(owner, 'echo own > own');
  assert.equal(success.value.exitCode, 0);
  for (const command of ['echo changed > ../session-b/secret', 'echo changed > escape/secret']) {
    const denied = await execute(owner, command);
    assert.notEqual(denied.value.exitCode, 0, JSON.stringify(denied));
  }
  assert.equal(await readFile(join(b, 'secret'), 'utf8'), 'unchanged');
});

test('已批准danger-full-access仍不能越过启动授权的宿主目录', async () => {
  const owner = agent();
  const off = ctx.on('approval/request', () => Promise.resolve('allowed-once'));
  try {
    const result = await execute(owner, `echo forbidden > '${join(outside, 'outside')}'`, { sandbox_permissions: 'danger-full-access', justification: '检查平台边界在已批准模式下仍有效。' });
    assert.equal(result.isError, false);
    assert.notEqual(result.value.exitCode, 0);
    assert.equal(await exists(join(outside, 'outside')), false);
  } finally { off(); }
});

test('受限argv票据不能伪造、不能重放，取消准备不留授权票据', async () => {
  const spec = { cwd: work, stdio: { stdin: 'ignore', stdout: { maxBytes: 100 }, stderr: { maxBytes: 100 } }, graceMs: 100 };
  assert.throws(() => ctx.subprocess.spawn({ ...spec, argv: ['/dsh-go/ohos/confined', 'forged'] }), { code: 'ERR_OHOS_INVALID_CONFINEMENT' });
  const prepared = await ctx.sandbox.confine(['bash', '-c', 'true'], { mode: 'read-only', workspaceRoot: work });
  await ctx.subprocess.spawn({ ...spec, argv: prepared.argv }).done;
  assert.throws(() => ctx.subprocess.spawn({ ...spec, argv: prepared.argv }), { code: 'ERR_OHOS_INVALID_CONFINEMENT' });
  const control = new AbortController();
  await ctx.sandbox.confine(['bash', '-c', 'true'], { mode: 'read-only', workspaceRoot: work }, control.signal);
  control.abort();
  assert.equal(ctx.subprocess.backend.prepared.size, 0);
});

test('真实tool-bash的NUL命令不能经prepare票据绕过spawn参数校验', async () => {
  const argv = ['bash', '-c', 'printf A\0B'];
  const spec = { cwd: work, stdio: { stdin: 'ignore', stdout: { maxBytes: 100 }, stderr: { maxBytes: 100 } }, graceMs: 100 };
  assert.throws(() => ctx.subprocess.spawn({ ...spec, argv }), TypeError);
  await assert.rejects(ctx.sandbox.confine(argv, { mode: 'read-only', workspaceRoot: work }), TypeError);
  const result = await execute(agent(), argv[2]);
  assert.equal(result.isError, true);
  assert.match(JSON.stringify(result), /NUL/);
  assert.equal(ctx.subprocess.backend.prepared.size, 0);
  assert.equal(ctx.subprocess.backend.live.size, 0);
});
