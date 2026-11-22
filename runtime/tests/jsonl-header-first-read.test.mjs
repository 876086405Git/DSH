import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';
import { zstdCompressSync } from 'node:zlib';

test('listing a complete Zstandard header in the first file read avoids copying that read', {
  skip: !process.env.DSH_PREFIX && 'requires a prepared DSH_PREFIX',
}, async t => {
  const packages = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
  const load = name => import(pathToFileURL(join(packages, name, 'lib/index.js')));
  const [{ Context }, { Session }, { sessionFormatCatalog }, jsonl] = await Promise.all(
    ['cordis', 'dsh-session', 'dsh-session-format-catalog', 'dsh-session-persistence-jsonl'].map(load));
  const ctx = new Context();
  const root = await mkdtemp(join(tmpdir(), 'dsh-header-first-'));
  t.after(async () => { await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }); });
  await jsonl.apply(ctx, { root, compression: 'zstd' });
  const header = Session.create('header-first').header;
  const path = ctx.sessionPersistence.locate(header).path;
  const row = sessionFormatCatalog.encodeCurrentHeader({ ...header, delegationDepth: header.delegationDepth ?? 0 }, 0);
  const frame = zstdCompressSync(JSON.stringify(row) + '\n');
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, frame);
  let copied = 0;
  const concat = Buffer.concat;
  const probe = t.mock.method(Buffer, 'concat', function (parts, length) {
    if (parts.length === 2 && parts[0].length === 0 && parts[1].equals(frame)) copied += frame.length;
    return concat.call(this, parts, length);
  });
  let items;
  try { items = await ctx.sessionPersistence.list(); }
  finally { probe.mock.restore(); }
  assert.deepEqual(items.map(item => item.header.id), [header.id]);
  assert.equal(copied, 0);
});
