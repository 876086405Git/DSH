import test from 'node:test';
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

test('current handle reads retain state identity and only materialize an absent or stale cell', async t => {
  const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
  assert.ok(prefix, 'Set DSH_TEST_PREFIX or DSH_PREFIX to a prepared runtime');
  const load = name => import(pathToFileURL(resolve(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
  const [{ Context }, { Session }, { SessionProjectionRegistry }, { modelSelectionProjectionDefinition }] =
    await Promise.all(['cordis', 'dsh-session', 'dsh-session-projection', 'dsh-agent'].map(load));
  const ctx = new Context();
  t.after(() => ctx.fiber.dispose());
  await ctx.plugin(SessionProjectionRegistry);
  const handle = await ctx.sessionProjections.register(modelSelectionProjectionDefinition);
  const slow = t.mock.method(SessionProjectionRegistry.prototype, 'cellFor');
  const session = Session.create('test-current-state');
  const read = handle.readerFor(session);
  const first = read();
  assert.equal(first.pending, null);
  assert.equal(read(), first);
  assert.equal(handle.stateOf(session), first);
  assert.equal(slow.mock.callCount(), 1);

  session.append('model/selection', { provider: 'p', model: 'a' });
  const next = read();
  assert.equal(next.pending.model, 'a');
  assert.equal(read(), next);
  await handle.dispose();
  session.append('model/selection', { provider: 'p', model: 'b' });
  const last = read();
  assert.equal(last.pending.model, 'b');
  assert.equal(handle.stateOf(session), last);
  assert.equal(slow.mock.callCount(), 3);
});
