import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('挂载 Office 预览和预先取消均不载入转换引擎', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, async () => {
  let loads = 0;
  const hook = registerHooks({
    resolve(specifier, context, next) {
      if (specifier === '@deepseek-ai/libreoffice-kit') loads++;
      return next(specifier, context);
    },
  });
  try {
    const packages = join(resolve(prefix), 'node_modules/@deepseek-ai');
    const load = name => import(pathToFileURL(join(packages, name, 'lib/index.js')));
    const [{ Context }, { OfficeToPdf, Config }] = await Promise.all(['cordis', 'dsh-office-to-pdf'].map(load));
    const ctx = new Context();
    try {
      const service = new OfficeToPdf(ctx, Config({}));
      const reason = new Error('取消预览');
      await assert.rejects(service.convert({}, AbortSignal.abort(reason)), error => error === reason);
      assert.equal(loads, 0);
    } finally { await ctx.fiber.dispose(); }
  } finally { hook.deregister(); }
});
