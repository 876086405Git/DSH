import assert from 'node:assert/strict';
import { createRequire, registerHooks } from 'node:module';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('列出检查工具不载入生成目录，首次查询服务才载入', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, async () => {
  const require = createRequire(join(resolve(prefix), 'package.json'));
  const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
  let catalogs = 0;
  const hook = registerHooks({
    load(url, context, next) {
      const result = next(url, context);
      if (url.endsWith('/dsh-tool-cordis/lib/types/api-catalog.js')) catalogs++;
      return result;
    },
  });
  try {
    const [{ Context }, { CordisInspectRegistryService }] = await Promise.all([
      load('cordis'), load('dsh-cordis-host-runner'),
    ]);
    const ctx = new Context();
    try {
      ctx.provide('tools', { schemas: () => [] });
      const registry = new CordisInspectRegistryService(ctx, 1000);
      await ctx.plugin(await load('dsh-tool-cordis/host'));
      assert.deepEqual(registry.list().map(p => p.id), ['Service', 'Event', 'Config', 'Tool']);
      assert.equal(catalogs, 0);
      const value = await registry.query('host', 'Service', 'listService', { service: 'tools' }, undefined, new AbortController().signal);
      assert.equal(value.service.key, 'tools');
      assert.equal(catalogs, 1);
    } finally { await ctx.fiber.dispose(); }
  } finally { hook.deregister(); }
});
