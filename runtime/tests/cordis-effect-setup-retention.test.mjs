import test from 'node:test';
import assert from 'node:assert/strict';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const prefix = resolve(process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX);
const { Context, Fiber } = await import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai/cordis/lib/index.js')));

test('effect releases one-shot setup references and keeps the registration stack for a later rejection', async t => {
  const ctx = new Context();
  t.after(() => ctx.fiber.dispose());
  const gate = Promise.withResolvers();
  const setup = () => gate.promise;
  let registered;
  const execute = Fiber.prototype._execute;
  t.mock.method(Fiber.prototype, '_execute', function (runner) {
    if (runner.execute === setup) registered = runner;
    return execute.call(this, runner);
  });
  function registerPendingEffect() {
    return ctx.effect(setup, 'pending setup');
  }
  const dispose = registerPendingEffect();
  const setupAfterReturn = registered?.execute;
  const stackAfterReturn = registered?.getOuterStack;
  const settled = Promise.resolve(dispose);
  gate.reject('delayed rejection');
  await assert.rejects(settled, error => {
    assert.equal(error.message, 'delayed rejection');
    assert.match(error.stack, /registerPendingEffect/);
    return true;
  });
  assert.ok(registered);
  assert.equal(setupAfterReturn, undefined);
  assert.equal(stackAfterReturn, undefined);
});
