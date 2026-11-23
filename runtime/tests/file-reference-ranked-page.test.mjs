import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

test('文件补全返回相同的首选项，排序批次最多包含两页', {
  skip: !process.env.DSH_PREFIX && '需要已应用覆片的 DSH_PREFIX',
}, async t => {
  const entry = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai/dsh-file-reference-local/lib/index.js');
  const { WorkspaceFileSearch } = await import(pathToFileURL(entry));
  const root = await mkdtemp(join(tmpdir(), 'file-reference-page-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  // Unpadded names: shorter ones rank first but are listed after file-10..file-19,
  // so the page needs winners that arrive after the first batch was cut.
  const names = Array.from({ length: 99 }, (_, i) => `file-${i}`)
    .sort((a, b) => a.length - b.length || (a < b ? -1 : 1));
  await Promise.all(names.map(name => writeFile(join(root, name), '')));
  const config = { maxResults: 5, maxEntries: 100, excludedDirectories: [] };
  const search = new WorkspaceFileSearch(root, config);
  t.after(() => search.dispose());
  const signal = new AbortController().signal;
  await search.list('warm', signal);
  const sort = Array.prototype.sort;
  let peak = 0;
  Array.prototype.sort = function (compare) {
    if (this[0]?.candidate && typeof this[0].score === 'number') peak = Math.max(peak, this.length);
    return sort.call(this, compare);
  };
  let page;
  try {
    page = await search.list('file', signal);
  } finally {
    Array.prototype.sort = sort;
  }
  assert.deepEqual(page.map(item => item.path), names.slice(0, 5));
  assert.ok(peak > 0 && peak <= 2 * config.maxResults, `最大排序批次 ${peak}`);
  config.maxResults = Number.MAX_SAFE_INTEGER;
  const all = await search.list('file', signal);
  assert.deepEqual(all.map(item => item.path), names);
  assert.equal(page[0], all[0]);
});
