import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

test('文件补全仅在当前页仍有机会时检查路径子序列', {
  skip: !process.env.DSH_PREFIX && '需要已应用覆片的 DSH_PREFIX',
}, async t => {
  const entry = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai/dsh-file-reference-local/lib/index.js');
  const { WorkspaceFileSearch } = await import(pathToFileURL(entry));
  const root = await mkdtemp(join(tmpdir(), 'file-reference-score-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const names = ['rt', 'rt1', 'z-r-t'];
  await Promise.all(names.map(name => writeFile(join(root, name), '')));
  const config = { maxResults: 1, maxEntries: 10, excludedDirectories: [] };
  const search = new WorkspaceFileSearch(root, config);
  t.after(() => search.dispose());
  const signal = new AbortController().signal;
  const indexOf = String.prototype.indexOf;
  let letters = 0;
  const spy = t.mock.method(String.prototype, 'indexOf', function (needle, start) {
    if (String(this) === 'z-r-t' && needle.length === 1) letters++;
    return indexOf.call(this, needle, start);
  });
  const page = await search.list('rt', signal);
  assert.equal(letters, 0);
  config.maxResults = 3;
  const all = await search.list('rt', signal);
  spy.mock.restore();
  assert.equal(letters, 2);
  assert.deepEqual(all.map(item => item.path), names);
  assert.deepEqual(page, [all[0]]);
  assert.equal(page[0], all[0]);
});
