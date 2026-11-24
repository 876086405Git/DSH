import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';
import { zstdCompressSync } from 'node:zlib';

test('concurrent cold opens keep their own bytes and only decode identical input once', {
  skip: !process.env.DSH_PREFIX && 'requires a prepared DSH_PREFIX',
}, async t => {
  const packages = resolve(process.env.DSH_PREFIX, 'node_modules/@deepseek-ai');
  const load = name => import(pathToFileURL(join(packages, name, 'lib/index.js')));
  const [{ Context }, { Session }, { sessionFormatCatalog }, jsonl] = await Promise.all(
    ['cordis', 'dsh-session', 'dsh-session-format-catalog', 'dsh-session-persistence-jsonl'].map(load));
  const root = await fs.mkdtemp(join(tmpdir(), 'jsonl-cold-read-'));
  const ctx = new Context();
  t.after(async () => {
    t.mock.restoreAll();
    syncBuiltinESMExports();
    await ctx.fiber.dispose();
    await fs.rm(root, { recursive: true, force: true });
  });
  await jsonl.apply(ctx, { root, compression: 'zstd' });
  const backend = ctx.sessionPersistence;
  const header = Session.create('cold-read').header;
  const path = backend.locate(header).path;
  const record = sessionFormatCatalog.encodeCurrentHeader({ ...header, delegationDepth: header.delegationDepth ?? 0 }, 0);
  await fs.mkdir(dirname(path), { recursive: true });
  await fs.writeFile(path, zstdCompressSync(JSON.stringify(record) + '\n'));
  const gates = Array.from({ length: 3 }, () => ({ entered: Promise.withResolvers(), release: Promise.withResolvers() }));
  const readFile = fs.readFile;
  const held = [];
  t.mock.method(fs, 'readFile', async (file, ...options) => {
    const bytes = await readFile(file, ...options);
    if (file !== path) return bytes;
    const gate = gates[held.length];
    held.push(bytes); // Keep the first weak target alive for this deterministic test.
    if (held.length === 3) bytes[0] ^= 0xff; // Same revision and length, different contents.
    gate.entered.resolve();
    await gate.release.promise;
    return bytes;
  });
  syncBuiltinESMExports();
  const decode = t.mock.method(Object.getPrototypeOf(backend), 'readZstdPrefix');
  const reads = [];
  for (const gate of gates) {
    reads.push(backend.open(header.id, 'read'));
    await gate.entered.promise;
  }
  for (let i = 0; i < 2; ++i) {
    gates[i].release.resolve();
    const reader = await reads[i];
    assert.equal(reader.header.id, header.id);
    await reader.close();
  }
  gates[2].release.resolve();
  await assert.rejects(reads[2], /stored log is corrupt/u);
  assert.equal(held.length, 3);
  assert.equal(decode.mock.callCount(), 2);
});
