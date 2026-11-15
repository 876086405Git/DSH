import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import OhSubprocessRuntime from '../../ohos/process/index.mjs';
import OhSandboxProvider from '../../ohos/process/sandbox.mjs';

process.env.DSH_GO_OHOS_SIM = '1';
assert.notEqual(globalThis[Symbol.for('dsh.go.ohos.sim')], true, 'Android 对照不加载仿真预载，旧环境变量不得启用它');
const base = createRequire(join(resolve(process.env.OHOS_TEST_BASE_PREFIX), 'package.json'));
const patched = createRequire(join(resolve(process.env.OHOS_TEST_PROCESS_PREFIX), 'package.json'));
const load = (name, require = base) => import(pathToFileURL(require.resolve(`@deepseek-ai/${name}`)));
const [{ Context }, { SystemPrompt }, { ToolRuntime }, { LocalFileSystem }, { WorkingDirectoryService }, { ShellEnvRegistry }, { LocalBashExecutor }, { LocalSubprocessRuntime }, { SessionProjectionRegistry }, originalSearch, changedSearch, originalTool, changedTool] = await Promise.all([
  ...['cordis', 'dsh-system-prompt', 'dsh-tools', 'dsh-fs-local', 'dsh-working-directory', 'dsh-shell-env', 'dsh-bash-local', 'dsh-subprocess-local', 'dsh-session-projection'].map(name => load(name)),
  load('dsh-tool-fs-search'), load('dsh-tool-fs-search', patched), load('dsh-tool-bash'), load('dsh-tool-bash', patched),
]);
const platform = Object.getOwnPropertyDescriptor(process, 'platform');

test('Android携带旧环境变量且没有显式预载时两个鸿蒙服务拒绝装入，Node全局不改写', () => {
  const original = [Request, Response, Headers, FormData, process.cwd];
  Object.defineProperty(process, 'platform', { ...platform, value: 'android' });
  try {
    assert.throws(() => new OhSubprocessRuntime(new Context()), /只能由鸿蒙/);
    assert.throws(() => new OhSandboxProvider(new Context()), /只能由鸿蒙/);
    assert.deepEqual([Request, Response, Headers, FormData, process.cwd], original);
  } finally { Object.defineProperty(process, 'platform', platform); }
});

test('Android的resolveRgPath仍使用原resolver及Promise返回契约', async () => {
  Object.defineProperty(process, 'platform', { ...platform, value: 'android' });
  const observe = async fn => {
    const value = fn();
    assert.ok(value instanceof Promise);
    return value.then(path => ({ path }), error => ({ error: error.message, code: error.code }));
  };
  try { assert.deepEqual(await observe(changedSearch.resolveRgPath), await observe(originalSearch.resolveRgPath)); }
  finally { Object.defineProperty(process, 'platform', platform); }
});

test('Android原工具真实注册的description/schema逐字相同，virtual同名能力也不误触发', async () => {
  const describe = async plugin => {
    const ctx = new Context();
    try {
      await ctx.plugin(SystemPrompt, {});
      await ctx.plugin(ToolRuntime, { mode: 'native' });
      await ctx.plugin(SessionProjectionRegistry);
      await ctx.plugin(LocalFileSystem, { cwd: process.cwd() });
      await ctx.plugin(WorkingDirectoryService, { defaultDirectory: process.cwd() });
      await ctx.plugin(ShellEnvRegistry, { dshHome: process.cwd() });
      await ctx.plugin(LocalSubprocessRuntime);
      ctx.subprocess.capabilities = { kind: 'virtual', commands: ['android-fixture'] };
      await ctx.plugin(LocalBashExecutor, { cwd: process.cwd() });
      await ctx.plugin(plugin, { enableRunInBackground: false, promoteOnTimeout: false });
      const { description, parameters } = ctx.tools.get('bash');
      return { description, parameters };
    } finally { await ctx.fiber.dispose(); }
  };
  Object.defineProperty(process, 'platform', { ...platform, value: 'android' });
  try {
    const expected = await describe(originalTool), actual = await describe(changedTool);
    assert.deepEqual(actual, expected);
    assert.doesNotMatch(actual.description, /鸿蒙|android-fixture/);
  } finally { Object.defineProperty(process, 'platform', platform); }
});
