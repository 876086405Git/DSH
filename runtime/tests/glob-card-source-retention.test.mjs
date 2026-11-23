import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;

test('glob 只独立复制实际省略了路径的最终展示页', { skip: !prefix && '缺少引擎前缀' }, async t => {
  const require = createRequire(join(resolve(prefix), 'package.json'));
  const { applyGlobTool } = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-tool-fs-search')));
  let glob;
  applyGlobTool({
    tools: { register(tool) { glob = tool; } },
    systemPrompt: { section() {}, getSectionOrder() { return 0; } },
    on() {},
  }, { maxResults: 100, maxMetaBytes: 1, sampleOverCapGlobResults: false });
  const original = globalThis.structuredClone;
  const copied = [];
  t.mock.method(globalThis, 'structuredClone', function(value, ...rest) {
    if (value?.shape === 'paths') copied.push(value.paths.length);
    return Reflect.apply(original, this, [value, ...rest]);
  });
  const first = 'src/带空格 的文件\ud800.dart';
  for (const paths of [[first], [first, 'src/second.dart']]) {
    const meta = glob.output.presentationMeta({}, { root: '.', paths: Object.freeze(paths) });
    assert.deepEqual(meta, { shape: 'paths', paths: [first], truncated: true, total: paths.length });
  }
  assert.deepEqual(copied, [1]);
});
