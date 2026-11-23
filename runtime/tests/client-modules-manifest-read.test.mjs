import assert from 'node:assert/strict';
import fs from 'node:fs';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { setImmediate } from 'node:timers/promises';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('客户端插件本轮使用首次匹配的清单，下轮读取已替换的文件', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, async t => {
  const packages = join(resolve(prefix), 'node_modules/@deepseek-ai');
  const load = name => import(pathToFileURL(join(packages, name, 'lib/index.js')));
  const [{ Context }, { ClientModuleRegistry }] = await Promise.all([load('cordis'), load('dsh-client-modules')]);
  const dir = await mkdtemp(join(tmpdir(), 'client-manifest-'));
  const ctx = new Context();
  const filename = join(dir, 'package.json');
  const replacement = join(dir, 'replacement.json');
  const manifest = immediately => JSON.stringify({
    name: 'client-fixture', exports: { './client': './client.js' }, dsh: { client: { platform: 'web', immediately } },
  });
  const entry = { options: { name: pathToFileURL(join(dir, 'client.js')).href }, fiber: {},
    parent: { tree: { ctx: { baseUrl: pathToFileURL(dir + '/').href } } } };
  ctx.provide('loader', { entries: () => [entry] });
  const readFile = fs.readFileSync;
  let reads = 0;
  const hook = t.mock.method(fs, 'readFileSync', function (path, ...args) {
    const content = readFile.call(this, path, ...args);
    if (path === filename && ++reads === 1) fs.renameSync(replacement, filename);
    return content;
  });
  syncBuiltinESMExports();
  t.after(async () => {
    hook.mock.restore();
    syncBuiltinESMExports();
    try { await ctx.fiber.dispose(); }
    finally { await rm(dir, { recursive: true, force: true }); }
  });
  await writeFile(filename, manifest(false));
  await writeFile(replacement, manifest(true));
  await writeFile(join(dir, 'client.js'), 'void 0;');
  await ctx.plugin(ClientModuleRegistry).await();
  assert.equal(ctx.clientModules.graph().entries[0].immediately, undefined);
  assert.equal(reads, 1);
  ctx.emit('internal/plugin', { entry });
  await setImmediate();
  assert.equal(ctx.clientModules.graph().entries[0].immediately, true);
  assert.equal(reads, 2);
});
