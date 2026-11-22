import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

test('JSONL 入队复用 Session 已冻结的核心事件和插件记录', {
  skip: !process.env.DSH_PREFIX && 'requires a prepared DSH_PREFIX',
}, async t => {
  const packages = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
  const load = name => import(pathToFileURL(join(packages, name, 'lib/index.js')));
  const [{ Context }, { SessionStore, appendPluginRecord }, jsonl] = await Promise.all(
    ['cordis', 'dsh-session', 'dsh-session-persistence-jsonl'].map(load));
  const root = await mkdtemp(join(tmpdir(), 'dsh-jsonl-live-'));
  const ctx = new Context();
  t.after(async () => { await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }); });
  const store = new SessionStore(ctx);
  await jsonl.apply(ctx, { root });
  const session = store.prepare('frozen-live', { meta: { delegationDepth: 0 } });
  const writer = await ctx.sessionPersistence.create(session.header);
  const detach = store.enter(session);
  try {
    store.announce(session);
    let clones = 0;
    const copy = globalThis.structuredClone;
    const probe = t.mock.method(globalThis, 'structuredClone', function (value, ...rest) {
      if (value?.type === 'turn/start' || value?.type === 'plugin:fixture/live') clones++;
      return copy(value, ...rest);
    });
    const input = { values: ['before'] };
    try {
      session.append('turn/start', { turn: 1 });
      appendPluginRecord(session, 'plugin:fixture/live', input);
    } finally { probe.mock.restore(); }
    input.values[0] = 'after';
    await ctx.sessionPersistence.flush();
    assert.equal(clones, 0);
    const { events } = await writer.read();
    assert.deepEqual(events.map(event => event.type), ['turn/start', 'plugin:fixture/live']);
    assert.deepEqual(events[1].data.values, ['before']);
  } finally {
    await writer.close();
    detach();
  }
});
