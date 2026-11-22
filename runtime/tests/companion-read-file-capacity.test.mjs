import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

test('small receipt buffers follow the opened size and still reject post-stat growth beyond the cap', {
  skip: process.platform !== 'linux' ? 'requires Linux anchored receipt IO'
    : !process.env.DSH_PREFIX && 'requires a prepared DSH_PREFIX',
}, async t => {
  const packages = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
  const { Context } = await import(pathToFileURL(join(packages, 'cordis/lib/index.js')));
  const { LocalFileSystem } = await import(pathToFileURL(join(packages, 'dsh-fs-local/lib/index.js')));
  const root = await fs.mkdtemp(join(tmpdir(), 'dsh-receipt-capacity-'));
  const ctx = new Context();
  t.after(async () => { await ctx.fiber.dispose(); await fs.rm(root, { recursive: true, force: true }); });
  await ctx.plugin(LocalFileSystem, { cwd: root });
  const signal = new AbortController().signal;
  const name = 'receipt.txt', path = join(root, name);
  const bytes = Buffer.alloc(8192, 65);
  await fs.writeFile(path, bytes);
  const directory = await ctx.fs.dshGoBindNotesDirectory(await ctx.fs.resolve(root), signal);
  const [entry] = (await ctx.fs.dshGoListNotes(directory, signal)).entries;
  const read = await ctx.fs.dshGoReadReceipt(directory, entry, 4 * 1024 * 1024, signal);
  assert.deepEqual(read.bytes, bytes);
  assert.equal(read.sha256, createHash('sha256').update(bytes).digest('hex'));
  assert.ok(read.bytes.buffer.byteLength <= bytes.length + 1);

  const open = fs.open;
  const probe = t.mock.method(fs, 'open', async function (file, ...args) {
    const handle = await open.call(this, file, ...args);
    if (String(file).endsWith('/' + name)) {
      const originalRead = handle.read.bind(handle);
      handle.read = async (...parameters) => {
        handle.read = originalRead;
        await fs.appendFile(path, '++');
        return originalRead(...parameters);
      };
    }
    return handle;
  });
  syncBuiltinESMExports();
  try {
    await assert.rejects(ctx.fs.dshGoReadReceipt(directory, entry, bytes.length + 1, signal), { code: 'FS_TOO_LARGE' });
  } finally {
    probe.mock.restore();
    syncBuiltinESMExports();
  }
});
