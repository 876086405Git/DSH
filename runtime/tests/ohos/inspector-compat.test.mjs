import assert from 'node:assert/strict';
import { createRequire, registerHooks, syncBuiltinESMExports } from 'node:module';
import { resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';
import workerThreads from 'node:worker_threads';

const BOOTSTRAP_PATH = '/api/experimental-inspector/bootstrap';

test('an enabled Inspector on Node without inspector publishes no debugging endpoint', { timeout: 5000 }, async (t) => {
  const require = createRequire(resolve(process.env.DSH_TEST_PREFIX, 'package.json'));
  t.mock.property(process.features, 'inspector', false);
  const spawn = t.mock.method(workerThreads, 'Worker', function () {
    assert.fail('Inspector must not spawn a Worker without native inspector support');
  });
  syncBuiltinESMExports();
  const hooks = registerHooks({ resolve(specifier, context, next) {
    assert.doesNotMatch(specifier, /^(?:node:)?inspector(?:\/promises)?$/);
    return next(specifier, context);
  } });
  t.after(() => {
    hooks.deregister();
    spawn.mock.restore();
    syncBuiltinESMExports();
  });

  const inspector = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-experimental-inspector')).href);
  await assert.rejects(inspector.startInspector(), { code: 'ERR_FEATURE_UNAVAILABLE_ON_PLATFORM' });

  const routes = new Map();
  const warn = t.mock.fn();
  const register = t.mock.fn();
  const registerUpgrade = t.mock.fn();
  const provide = t.mock.fn();
  const on = t.mock.fn();
  let dispose;
  const fetchBefore = globalThis.fetch;
  await inspector.apply({
    async effect(setup) { dispose = await setup(); },
    connection: { fetch: { register(route) {
      routes.set(route.path, route);
      return () => { routes.delete(route.path); };
    } } },
    webServer: { register, registerUpgrade },
    logger: { warn },
    provide,
    on,
  }, { captureFetch: true });

  assert.deepEqual([...routes.keys()], [BOOTSTRAP_PATH]);
  const route = routes.get(BOOTSTRAP_PATH);
  assert.deepEqual(route.methods, ['GET']);
  const response = await route.fetch(new Request('http://localhost' + BOOTSTRAP_PATH));
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(await response.text(), '');
  assert.equal(warn.mock.callCount(), 1);
  assert.match(warn.mock.calls[0].arguments[0], /Inspector is unavailable/);
  for (const absent of [spawn, register, registerUpgrade, provide, on]) {
    assert.equal(absent.mock.callCount(), 0);
  }
  assert.equal(globalThis.fetch, fetchBefore);
  await dispose();
  assert.equal(routes.size, 0);
});
