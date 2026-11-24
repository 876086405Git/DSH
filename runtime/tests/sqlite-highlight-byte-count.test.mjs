import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

test('正文搜索不替换已高亮全文，沿用原来的命中排序', {
  skip: !process.env.DSH_PREFIX && 'requires a prepared DSH_PREFIX',
}, async t => {
  const base = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
  const load = name => import(pathToFileURL(join(base, name, 'lib/index.js')));
  const [{ Context }, { SessionStore }, { SqliteSessionQueryEngine }, jsonl] = await Promise.all(
    ['cordis', 'dsh-session', 'dsh-session-query-sqlite', 'dsh-session-persistence-jsonl'].map(load));
  const ctx = new Context();
  const root = await mkdtemp(join(tmpdir(), 'dsh-highlight-'));
  let query;
  t.after(async () => { await query?.close(); await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }); });
  const sessions = new SessionStore(ctx);
  await jsonl.apply(ctx, { root: join(root, 'sessions'), compression: 'none' });
  const messages = ['zz foo xx', '\uFFFEfoo x', 'foo 🙂 foo'];
  const seed = messages.map((text, seq) => ({ type: 'user/message', seq, time: seq + 1,
    surfaceOp: 'append', data: { id: 'msg-' + seq, role: 'user', content: [{ type: 'text', text }], source: { kind: 'user' } } }));
  const session = sessions.prepare('ranking', { seed, meta: { delegationDepth: 0 } });
  const writer = await ctx.sessionPersistence.create(session.header);
  try { await writer.append(session.snapshotEvents()); } finally { await writer.close(); }
  const path = join(root, 'search.sqlite');
  const existing = new DatabaseSync(path);
  try { existing.exec("PRAGMA encoding='UTF-16le'; CREATE TABLE init(v); DROP TABLE init"); } finally { existing.close(); }
  query = new SqliteSessionQueryEngine(ctx, { path, openAt: 'first-search' });
  await query.searchSessions({ query: 'warmup' });
  assert.equal(query._db.prepare('PRAGMA encoding').get().encoding, 'UTF-16le');
  let replacements = 0;
  query._db.function('replace', { deterministic: true }, (value, before, after) => {
    if (before === '\uFDD0' && after === '') replacements++;
    return value.replaceAll(before, after);
  });
  const hits = await query.searchEvents({ sessionId: session.id, query: 'foo' });
  assert.deepEqual(hits.items.map(item => item.seq), [2, 1, 0]);
  assert.equal((await query.searchSessions({ query: 'foo' })).items[0].bestMatch.seq, 2);
  assert.equal(replacements, 0);
});
