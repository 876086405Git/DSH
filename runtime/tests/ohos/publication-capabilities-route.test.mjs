import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const require = createRequire(join(resolve(process.env.M6_TEST_PREFIX), 'package.json'));
const { Context } = await import(pathToFileURL(require.resolve('@deepseek-ai/cordis')));
const plugin = await import(pathToFileURL(resolve(process.env.M6_TEST_CAPABILITIES_MODULE)));
const platform = Object.getOwnPropertyDescriptor(process, 'platform');
const simulationSymbol = Symbol.for('dsh.go.ohos.sim');
assert.notEqual(globalThis[simulationSymbol], true, 'This gate test starts without the O0 marker');

for (const [label, value, marker, expected] of [
  ['Linux with old environment variable', 'linux', false, 0],
  ['Android with old environment variable', 'android', false, 0],
  ['OpenHarmony without connection', 'openharmony', false, 1],
  ['explicit simulation without connection', 'linux', true, 1],
]) {
  test(label, async () => {
    const oldEnv = process.env.DSH_GO_OHOS_SIM;
    process.env.DSH_GO_OHOS_SIM = '1';
    Object.defineProperty(process, 'platform', { ...platform, value });
    if (marker) globalThis[simulationSymbol] = true;
    const ctx = new Context(), routes = new Map();
    const server = http.createServer((req, res) => {
      const handler = routes.get(req.url)?.handler;
      if (handler) handler(req, res);
      else { res.writeHead(404); res.end(); }
    });
    try {
      await ctx.plugin({ name: 'test-web-server-registry', apply(context) {
        context.provide('webServer', { register(route) {
          routes.set(route.path, route); return () => routes.delete(route.path);
        } });
      } });
      await ctx.plugin(plugin);
      assert.equal(routes.size, expected);
      if (expected) {
        server.listen(0, '127.0.0.1'); await once(server, 'listening');
        const result = await new Promise((resolve, reject) => {
          http.get(`http://127.0.0.1:${server.address().port}/dsh-go/v1/runtime-capabilities`, res => {
            let body = ''; res.on('data', bytes => { body += bytes; });
            res.on('end', () => resolve({ status: res.statusCode, body, headers: res.headers }));
          }).on('error', reject);
        });
        assert.equal(result.status, 503);
        assert.equal(result.headers['cache-control'], 'no-store');
        assert.doesNotMatch(result.body, /publication|systemVersion|bootId/);
      }
      await ctx.fiber.dispose();
      assert.equal(routes.size, 0, 'Cordis disposal removes the exact route');
    } finally {
      await ctx.fiber.dispose();
      if (server.listening) await new Promise(resolve => server.close(resolve));
      if (marker) delete globalThis[simulationSymbol];
      Object.defineProperty(process, 'platform', platform);
      if (oldEnv === undefined) delete process.env.DSH_GO_OHOS_SIM;
      else process.env.DSH_GO_OHOS_SIM = oldEnv;
    }
  });
}
