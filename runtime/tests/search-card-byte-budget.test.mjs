import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;

test('搜索卡超出字节预算时只编码一次整卡', { skip: !prefix && '缺少引擎前缀' }, async t => {
  const require = createRequire(join(resolve(prefix), 'package.json'));
  const { applyGrepTool } = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-tool-fs-search')));
  let tool;
  const caps = { maxMatches: 10, maxLineBytes: 2000, maxMetaBytes: 65536 };
  applyGrepTool({
    tools: { register(value) { tool = value; } },
    systemPrompt: { section() {}, getSectionOrder() { return 0; } },
    on() {},
  }, caps);
  const matches = ['第一', '😀', '引"号', '末尾'].map((line, i) => ({ path: '文件' + i, lineNumber: 1, line }));
  const project = () => tool.output.presentationMeta({}, { matches });
  const full = project();
  const expected = { ...full, files: full.files.slice(0, 2), truncated: true };
  caps.maxMetaBytes = Buffer.byteLength(JSON.stringify(expected));
  const stringify = t.mock.method(JSON, 'stringify');
  const actual = project();
  const cardEncodings = stringify.mock.calls.filter(call => call.arguments[0]?.shape === 'matches').length;
  stringify.mock.restore();
  assert.deepEqual(actual, expected);
  assert.equal(cardEncodings, 1);
});
