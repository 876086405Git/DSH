import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

test('冷会话只按 revision 更新索引，不再编码未使用的完整事件指纹', {
  skip: !process.env.DSH_PREFIX && 'requires a prepared DSH_PREFIX',
}, async t => {
  const packages = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
  const load = name => import(pathToFileURL(join(packages, name, 'lib/index.js')));
  const [{ Context }, { SessionStore }, { SqliteSessionQueryEngine }, jsonl] = await Promise.all(
    ['cordis', 'dsh-session', 'dsh-session-query-sqlite', 'dsh-session-persistence-jsonl'].map(load));
  const ctx = new Context();
  const root = await mkdtemp(join(tmpdir(), 'dsh-cold-fingerprint-'));
  let query;
  t.after(async () => { await query?.close(); await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }); });
  const sessions = new SessionStore(ctx);
  await jsonl.apply(ctx, { root, compression: 'none' });
  const seed = ['needle first', 'needle second'].map((text, seq) => ({ seq, time: seq + 1,
    type: 'user/message', surfaceOp: 'append', data: { id: `m-${seq}`, role: 'user',
      content: [{ type: 'text', text }], source: { kind: 'user' } } }));
  const session = sessions.prepare('cold-fingerprint', { seed, meta: { delegationDepth: 0 } });
  const writer = await ctx.sessionPersistence.create(session.header);
  try { await writer.append(session.snapshotEvents()); } finally { await writer.close(); }
  query = new SqliteSessionQueryEngine(ctx, { path: ':memory:', openAt: 'first-search' });
  let fingerprints = 0, eventClones = 0;
  const stringify = JSON.stringify, clone = globalThis.structuredClone;
  const encodingProbe = t.mock.method(JSON, 'stringify', function (value, ...rest) {
    if (value?.header?.id === session.id && Array.isArray(value.events)) fingerprints++;
    return stringify.call(this, value, ...rest);
  });
  const cloneProbe = t.mock.method(globalThis, 'structuredClone', function (value, ...rest) {
    if (value?.type === 'user/message' && Number.isSafeInteger(value.seq)) eventClones++;
    return clone.call(this, value, ...rest);
  });
  try {
    const cold = await query.searchSessions({ query: 'needle' });
    assert.deepEqual(cold.items.map(item => [item.header.id, item.persisted, item.live]), [[session.id, true, false]]);
    assert.equal(eventClones, 2, '两条 user/message 仍各自克隆一次');
    assert.deepEqual(await query.searchSessions({ query: 'needle' }), cold);
    assert.equal(eventClones, 2, '相同 revision 不重新读取事件');
    assert.equal(fingerprints, 0);
  } finally {
    encodingProbe.mock.restore();
    cloneProbe.mock.restore();
  }
});
