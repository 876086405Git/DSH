import assert from 'node:assert/strict';
import { appendFile, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('重建客户端模块图只读取一次每个缓存分块请求的路径', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, async t => {
  const packages = join(resolve(prefix), 'node_modules/@deepseek-ai');
  const load = name => import(pathToFileURL(join(packages, name, 'lib/index.js')));
  const [{ Context }, { ClientModuleRegistry }] = await Promise.all([load('cordis'), load('dsh-client-modules')]);
  const root = await mkdtemp(join(tmpdir(), 'client-module-rebuild-'));
  const ctx = new Context();
  t.after(async () => {
    try { await ctx.fiber.dispose(); }
    finally { await rm(root, { recursive: true, force: true }); }
  });
  const entries = [];
  for (const name of ['@sample/first', '@sample/second']) {
    const dir = join(root, name);
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, 'package.json'), JSON.stringify({
      name, dsh: { client: { platform: 'web' } }, exports: { './client': './client.js' },
    }));
    const client = join(dir, 'client.js');
    await writeFile(client, 'void 0;');
    entries.push({ options: { name: pathToFileURL(client).href }, fiber: {},
      parent: { tree: { ctx: { baseUrl: pathToFileURL(root + '/').href } } } });
  }
  await writeFile(join(root, '@sample/first/client.part.js'), 'void 1;');
  ctx.provide('loader', { entries: () => entries });
  await ctx.plugin(ClientModuleRegistry).await();
  const registry = ctx.clientModules;
  const row = registry.graph().entries.find(entry => entry.id === '@sample/first');
  const batch = registry.graph().batches[0];
  const chunk = new URL(batch.url, 'https://client.example/');
  chunk.pathname += row.id + '/client.part.js';
  chunk.search = '?rev=' + row.rev;
  const request = url => registry.fetchBundle(new Request(url));
  const first = await request(chunk);
  assert.equal(first.status, 200);
  const script = await first.text();
  const getPathname = Object.getOwnPropertyDescriptor(URL.prototype, 'pathname').get;
  const pathsRead = [];
  t.mock.getter(URL.prototype, 'pathname', function () {
    pathsRead.push(this);
    return getPathname.call(this);
  });
  await appendFile(join(root, '@sample/second/client.js'), '\nvoid 2;');
  registry.rebuilt('@sample/second');
  assert.ok(pathsRead.length > 0);
  assert.equal(pathsRead.length, new Set(pathsRead).size);
  assert.equal(await (await request(chunk)).text(), script);
  assert.equal((await request(new URL(batch.url, chunk.origin))).status, 200);
});
