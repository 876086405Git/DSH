import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

test('bare file mentions filter hidden segments without splitting indexed paths', {
  skip: !process.env.DSH_PREFIX && 'requires a prepared DSH_PREFIX',
}, async t => {
  const backend = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai/dsh-file-reference-local/lib/index.js');
  const { WorkspaceFileSearch } = await import(pathToFileURL(backend));
  const root = await mkdtemp(join(tmpdir(), 'dsh-hidden-paths-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const files = ['needle.txt', '.needle.txt', 'src/needle.mjs', 'src/mid.needle', 'src/.dot/needle.md', '.d/needle.log'];
  const directories = ['src', 'src/.dot', '.d'];
  for (const path of directories) await mkdir(join(root, path));
  for (const path of files) await writeFile(join(root, path), '');
  const search = new WorkspaceFileSearch(root, { maxResults: 20, maxEntries: 50_000, excludedDirectories: [] });
  t.after(() => search.dispose());
  const signal = new AbortController().signal;
  await search.list('warm-index', signal);

  const paths = new Set([...directories, ...files]);
  const split = String.prototype.split;
  let splits = 0;
  const probe = t.mock.method(String.prototype, 'split', function (separator, ...args) {
    if (separator === '/' && paths.has(String(this))) splits++;
    return split.call(this, separator, ...args);
  });
  const visible = await search.list('needle', signal);
  probe.mock.restore();
  assert.deepEqual(visible.map(row => row.path), ['needle.txt', 'src/needle.mjs', 'src/mid.needle']);
  assert.equal(splits, 0);
  assert.ok((await search.list('.needle', signal)).some(row => row.path === '.needle.txt'));
  assert.deepEqual(await search.list('src\\.dot\\nee', signal), [{ path: 'src/.dot/needle.md', kind: 'file' }]);
});
