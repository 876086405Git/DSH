import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;

test('分行读取大文件时仅复制返回窗口', { skip: !prefix && '缺少引擎前缀' }, async t => {
  const require = createRequire(join(resolve(prefix), 'package.json'));
  const fsTools = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-tool-fs')));
  const first = '开头\ud800结尾';
  const file = first + '\r\n' + 'x'.repeat(65_536);
  const target = { displayPath: '/doc.txt' };
  let read;
  fsTools.apply({
    tools: { register(tool) { if (tool.name === 'read') read = tool; } },
    systemPrompt: { section() {}, getSectionOrder() { return 0; } },
    fs: {
      resolve: () => target,
      stat: () => ({ type: 'file', size: file.length }),
      readText: () => file,
      processPath: value => value.displayPath,
    },
    emit() {},
  }, { read: true, readLimit: 2000, readMaxLineLength: 2000, readMaxBytes: 51200, readStreamMinSize: 10485760 });
  const original = globalThis.structuredClone;
  const copied = [];
  t.mock.method(globalThis, 'structuredClone', function(value, ...rest) {
    if (Array.isArray(value) && value[0]?.text === first) copied.push(value.length);
    return Reflect.apply(original, this, [value, ...rest]);
  });
  const outcome = await read.execute({ file_path: '/doc.txt', limit: 1 }, { signal: new AbortController().signal });
  assert.deepEqual(outcome.lines, [{ number: 1, text: first }]);
  assert.equal(outcome.totalLines, 2);
  assert.deepEqual(copied, [1]);
});
