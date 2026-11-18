import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const mode = process.env.M6_DESCRIPTION_MODE;
assert(['jit', 'strict', 'android-old-env', 'linux-old-env', 'openharmony-no-marker'].includes(mode));
assert.equal(process.versions.node, '24.22.1');
if (mode === 'android-old-env' || mode === 'openharmony-no-marker') {
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], undefined);
  Object.defineProperty(process, 'platform', { value: mode === 'android-old-env' ? 'android' : 'openharmony' });
}
if (mode === 'strict') {
  assert(process.execArgv.includes('--jitless'));
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
}
const require = createRequire(join(process.env.M6_PROVIDER_PREFIX, 'package.json'));
const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
const [{ Context }, { SystemPrompt }, { ToolRuntime }] = await Promise.all([
  load('cordis'), load('dsh-system-prompt'), load('dsh-tools'),
]);
const notice = ' 鸿蒙本机不读取全局 gitignore 或 core.excludesFile；外部排除和反向放行规则均不参与，结果可能与桌面不同。';

async function registered(modulePath) {
  const provider = await import(pathToFileURL(modulePath));
  const ctx = new Context();
  try {
    await ctx.plugin(SystemPrompt, {});
    await ctx.plugin(ToolRuntime, {});
    provider.applyGrepTool(ctx, { maxMatches: 250, maxLineBytes: 500,
      maxMetaBytes: 131072, rawOutputMaxBytes: 1048576, graceMs: 200,
      stderrMaxBytes: 65536, timeoutMs: 15000 });
    const tool = ctx.tools.get('grep');
    assert(tool, 'real grep registration missing');
    return { name: tool.name, description: tool.description, parameters: tool.parameters };
  } finally {
    await ctx.fiber.dispose();
  }
}

test('真实 grep 注册说明只在 OH/显式标记出现，schema 和既有说明保持', async t => {
  const before = await registered(process.env.M6_DESCRIPTION_BEFORE);
  const after = await registered(process.env.M6_DESCRIPTION_AFTER);
  const positive = ['jit', 'strict', 'openharmony-no-marker'].includes(mode);
  assert.equal(after.description, before.description + (positive ? notice : ''));
  assert.equal(after.name, before.name);
  assert.deepEqual(after.parameters, before.parameters);
  t.diagnostic(JSON.stringify({ mode, platform: process.platform,
    marker: globalThis[Symbol.for('dsh.go.ohos.sim')] === true,
    wasm: typeof WebAssembly, description: after.description }));
});
