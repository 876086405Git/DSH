import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('客户端合包直接编码各段并复用首次响应，不再编码完整中间字符串', {
  skip: !prefix && '请设置 DSH_PREFIX 指向已准备的引擎',
}, async t => {
  const packages = join(resolve(prefix), 'node_modules/@deepseek-ai');
  const load = name => import(pathToFileURL(join(packages, name, 'lib/index.js')));
  const [{ Context }, { ClientModuleRegistry }] = await Promise.all([load('cordis'), load('dsh-client-modules')]);
  const root = await mkdtemp(join(tmpdir(), 'client-combo-buffer-'));
  const ctx = new Context();
  t.after(async () => {
    try { await ctx.fiber.dispose(); }
    finally { await rm(root, { recursive: true, force: true }); }
  });
  const scripts = ['globalThis.first = "鲸鱼😀";\n', 'globalThis.second = "二";\n'];
  const entries = [];
  for (const [index, script] of scripts.entries()) {
    const name = `combo-fixture-${index}`;
    const dir = join(root, name);
    await mkdir(dir);
    await writeFile(join(dir, 'package.json'), JSON.stringify({
      name, dsh: { client: { platform: 'web' } }, exports: { './client': './client.js' },
    }));
    const client = join(dir, 'client.js');
    await writeFile(client, script + '//# sourceMappingURL=discarded.map\n');
    entries.push({ options: { name: pathToFileURL(client).href }, fiber: {},
      parent: { tree: { ctx: { baseUrl: pathToFileURL(root + '/').href } } } });
  }
  ctx.provide('loader', { entries: () => entries });
  await ctx.plugin(ClientModuleRegistry).await();
  const registry = ctx.clientModules;
  const batch = registry.graph().batches[0];
  const trailer = `??${batch.entries.map(id => `${id}/client.js.map`).join(',')}&rev=${batch.rev}`;
  const expected = scripts.map(script => script + ';\n').join('') + `//# sourceMappingURL=${trailer}\n`;
  const bytes = Buffer.from(expected);
  const from = Buffer.from;
  let joinedEncodings = 0;
  t.mock.method(Buffer, 'from', function (value, ...args) {
    if (value === expected) joinedEncodings++;
    return from.call(this, value, ...args);
  });
  const url = new URL(batch.url, 'http://client.example/');
  const read = async () => {
    const response = await registry.fetchBundle(new Request(url));
    assert.equal(response.status, 200);
    const reader = response.body.getReader();
    const { value } = await reader.read();
    assert.equal((await reader.read()).done, true);
    reader.releaseLock();
    return value;
  };
  const first = await read();
  assert.deepEqual(first, bytes);
  assert.equal(await read(), first);
  assert.equal(joinedEncodings, 0);
});
