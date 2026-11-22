import assert from 'node:assert/strict';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

test('作业终态可继续查询并消费结果，同时释放生产者取消回调', {
  skip: !process.env.DSH_PREFIX && '需要已应用覆片的 DSH_PREFIX',
}, async t => {
  const root = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
  const load = name => import(pathToFileURL(join(root, name, 'lib/index.js')));
  const [{ Context }, { LocalJobRegistry }] = await Promise.all([load('cordis'), load('dsh-jobs-local')]);
  const ctx = new Context();
  t.after(() => ctx.fiber.dispose());
  await ctx.plugin(LocalJobRegistry);
  const jobs = ctx.jobs;
  jobs.attachController('terminal-hook-test');
  const done = Promise.withResolvers();
  let cancelled = 0;
  const producer = { done: done.promise, cancel(reason) {
    assert.equal(this, producer);
    assert.equal(reason, 'user');
    cancelled++;
  } };
  const id = jobs.start({ kind: 'test', label: '取消', run: () => producer });
  assert.equal(jobs.kill(id, undefined, 'user'), 'requested');
  done.resolve({ status: 'killed', result: 'done' });
  assert.equal((await jobs.wait(id, 1000)).status, 'killed');
  assert.equal(jobs.read(id).result, 'done');
  assert.equal(jobs.read(id).result, undefined);
  assert.equal(jobs.kill(id), 'already-finished');
  assert.equal(cancelled, 1);
  assert.equal(jobs.store.get(id).cancel, undefined);
});
