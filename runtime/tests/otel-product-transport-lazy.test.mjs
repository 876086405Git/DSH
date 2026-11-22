import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('会话遥测独立启动，创建产品遥测时才加载专用 HTTP 客户端', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, async () => {
  let loads = 0;
  const hook = registerHooks({
    resolve(specifier, context, next) {
      if (specifier === 'got') loads++;
      return next(specifier, context);
    },
  });
  try {
    const packages = join(resolve(prefix), 'node_modules/@deepseek-ai');
    const load = name => import(pathToFileURL(join(packages, name, 'lib/index.js')));
    const [{ Context }, { default: OTel }] = await Promise.all(['cordis', 'dsh-otel'].map(load));
    const ctx = new Context();
    try {
      const service = new OTel(ctx);
      const options = {
        exporter: { url: 'http://127.0.0.1:9/v1/logs' },
        resourceAttributes: {},
        scope: { name: 'test' },
        onFailure: assert.fail,
      };
      const session = service.createSessionLogReporter(options);
      await session.shutdown();
      assert.equal(loads, 0);
      const product = service.createEventReporter(options);
      try { assert.equal(loads, 1); } finally { await product.shutdown(); }
    } finally { await ctx.fiber.dispose(); }
  } finally { hook.deregister(); }
});
