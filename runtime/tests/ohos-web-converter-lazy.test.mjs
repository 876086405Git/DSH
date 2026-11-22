import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

test('Web 工具首次转换 HTML 时才加载 Turndown、Domino 和 GFM', {
  skip: !process.env.DSH_PREFIX && '需要已应用覆片的 DSH_PREFIX',
}, async t => {
  const loaded = new Set();
  const hook = registerHooks({
    load(url, context, next) {
      const result = next(url, context);
      const match = /\/node_modules\/(turndown|@mixmark-io\/domino|@joplin\/turndown-plugin-gfm)\//.exec(url);
      if (match) loaded.add(match[1]);
      return result;
    },
  });
  t.after(() => hook.deregister());
  const file = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai/dsh-tool-web/lib/index.js');
  const { formatFetchOutput } = await import(pathToFileURL(file));
  const response = (kind, content) => ({
    url: 'https://example.org/', statusCode: 200, body: { kind, content }, truncated: false,
  });
  assert.match(formatFetchOutput(response('text', '<b>原文</b>'), 4096), /<b>原文<\/b>/);
  assert.equal(loaded.size, 0);
  assert.match(formatFetchOutput(response('html', '<h1>标题</h1>'), 4096), /# 标题/);
  assert.deepEqual([...loaded].sort(), ['@joplin/turndown-plugin-gfm', '@mixmark-io/domino', 'turndown']);
});
