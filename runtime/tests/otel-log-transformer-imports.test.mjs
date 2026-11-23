import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('创建会话日志通道无需加载指标 SDK', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, async () => {
  let metricsFiles = 0;
  const hook = registerHooks({
    load(url, context, next) {
      const result = next(url, context);
      if (url.includes('/node_modules/@opentelemetry/sdk-metrics/')) metricsFiles++;
      return result;
    },
  });
  try {
    const packages = join(resolve(prefix), 'node_modules/@deepseek-ai');
    const load = name => import(pathToFileURL(join(packages, name, 'lib/index.js')));
    const [{ Context }, { default: OTel }] = await Promise.all(['cordis', 'dsh-otel'].map(load));
    const ctx = new Context();
    try {
      const channel = new OTel(ctx).createSessionLogReporter({
        exporter: { url: 'http://127.0.0.1:9/v1/logs' },
        resourceAttributes: {},
        scope: { name: 'test' },
        onFailure: assert.fail,
      });
      await channel.shutdown();
      assert.equal(metricsFiles, 0);
    } finally { await ctx.fiber.dispose(); }
  } finally { hook.deregister(); }
});
