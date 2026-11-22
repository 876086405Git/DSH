import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';
import { zstdCompressSync } from 'node:zlib';

test('cold opening a Zstandard session uses at most one 1 MiB decoder output buffer', {
  skip: !process.env.DSH_PREFIX && 'requires a prepared DSH_PREFIX',
}, async t => {
  const packages = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
  const load = name => import(pathToFileURL(join(packages, name, 'lib/index.js')));
  const [{ Context }, { Session }, { sessionFormatCatalog }, jsonl] = await Promise.all(
    ['cordis', 'dsh-session', 'dsh-session-format-catalog', 'dsh-session-persistence-jsonl'].map(load));
  const root = await mkdtemp(join(tmpdir(), 'dsh-jsonl-decoder-'));
  const ctx = new Context();
  t.after(async () => { await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }); });
  await jsonl.apply(ctx, { root, compression: 'zstd' });
  const header = Session.create('cold-zstd').header;
  const path = ctx.sessionPersistence.locate(header).path;
  const stored = sessionFormatCatalog.encodeCurrentHeader({ ...header, delegationDepth: header.delegationDepth ?? 0 }, 0);
  const line = JSON.stringify(stored) + '\n';
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, zstdCompressSync(line));
  const alloc = Buffer.allocUnsafe;
  let largeBuffers = 0;
  const probe = t.mock.method(Buffer, 'allocUnsafe', function (size) {
    if (size === 1024 * 1024) largeBuffers++;
    return alloc.call(this, size);
  });
  let reader;
  try { reader = await ctx.sessionPersistence.open(header.id, 'read'); }
  finally { probe.mock.restore(); }
  t.after(() => reader.close());
  assert.ok(largeBuffers <= 1, `allocated ${largeBuffers} output buffers of 1 MiB`);
  assert.equal(reader.header.id, header.id);
  assert.deepEqual((await reader.read()).events, []);
});
