import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

test('裸查询按原有名称和路径分数排名，评分不截取文件名', {
  skip: !process.env.DSH_PREFIX && '需要已应用覆片的 DSH_PREFIX',
}, async t => {
  const entry = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai/dsh-file-reference-local/lib/index.js');
  const { WorkspaceFileSearch } = await import(pathToFileURL(entry));
  const root = await mkdtemp(join(tmpdir(), 'file-reference-name-match-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  for (const dir of ['cat', 'src']) await mkdir(join(root, dir));
  const files = ['src/cat', 'src/catalog', 'src/scatter', 'cat/log', 'src/c-a-t'];
  for (const path of files) await writeFile(join(root, path), '');
  const search = new WorkspaceFileSearch(root, { maxResults: 20, maxEntries: 100, excludedDirectories: [] });
  t.after(() => search.dispose());
  const signal = new AbortController().signal;
  await search.list('warm-index', signal);
  const names = new Set(files);
  const original = String.prototype.slice;
  let slices = 0;
  const observer = t.mock.method(String.prototype, 'slice', function (start, ...rest) {
    if (start === 4 && rest.length === 0 && names.has(String(this))) slices++;
    return original.call(this, start, ...rest);
  });
  const matches = await search.list('CAT', signal);
  observer.mock.restore();
  assert.deepEqual(matches.map(row => row.path), ['cat', ...files]);
  assert.equal(slices, 0);
});
