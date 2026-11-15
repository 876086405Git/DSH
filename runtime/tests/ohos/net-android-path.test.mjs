import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { installFetch } from '../../ohos/net/fetch.mjs';

assert.ok(process.env.OHOS_TEST_BASE_PREFIX && process.env.OHOS_TEST_DSH_PREFIX, 'provide both unchanged and patched npm-ci verification trees');
// The old environment switch must not enable a production Android branch.
process.env.DSH_GO_OHOS_SIM = '1';
assert.notEqual(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
Object.defineProperty(process, 'platform', { value: 'android' });
let ohosCalls = 0;
globalThis[Symbol.for('dsh.go.ohos.net')] = { createDispatcher() { ohosCalls++; throw new Error('OHOS branch reached on Android'); } };

const load = (prefix, name) => import(pathToFileURL(join(resolve(prefix), 'node_modules', '@deepseek-ai', name, 'lib/index.js')).href);
const traces = [];

test('Android plus the obsolete environment switch leaves native fetch unchanged', () => {
  const original = globalThis.fetch;
  assert.equal(installFetch(), undefined);
  assert.equal(globalThis.fetch, original);
});

for (const [name, prefix] of [['base', process.env.OHOS_TEST_BASE_PREFIX], ['patched', process.env.OHOS_TEST_DSH_PREFIX]]) {
  test(`${name} uses the original Android proxy and pinned-fetch path`, async () => {
    const { installProxyFromEnvironment, proxyRouteFor } = await load(prefix, 'dsh-http-proxy');
    const { HttpFetchProvider } = await load(prefix, 'dsh-web-fetch-http');
    const seen = [];
    const server = http.createServer((q, r) => {
      seen.push({ method: q.method, url: q.url, host: q.headers.host });
      r.setHeader('content-type', 'text/plain'); r.end('same behavior');
    }).listen(0, '127.0.0.1');
    await once(server, 'listening');
    const proxyUrl = `http://127.0.0.1:${server.address().port}`;
    const values = new Map([['HTTP_PROXY', { value: proxyUrl }], ['NO_PROXY', { value: '.skip.invalid' }]]);
    const dispose = await installProxyFromEnvironment(values, () => {});
    try {
      const provider = new HttpFetchProvider({ maxResponseBytes: 1000, maxBodyChars: 1000, timeoutMs: 1000, maxRedirects: 2, userAgent: 'android-test' });
      const result = await provider.fetch({ url: 'http://public-fixture.invalid/document' });
      assert.equal(result.body.content, 'same behavior');
      assert.equal(proxyRouteFor(new URL('http://child.skip.invalid/')).proxied, false);
      assert.equal(proxyRouteFor(new URL('http://127.0.0.1/')).proxied, false);
      await assert.rejects(provider.fetch({ url: proxyUrl }), (error) => error.code === 'WEB_BLOCKED_URL');
      const local = new HttpFetchProvider({ maxResponseBytes: 1000, maxBodyChars: 1000, timeoutMs: 1000, maxRedirects: 2, userAgent: 'android-test' }, async () => [{ address: '127.0.0.1', family: 4 }]);
      const pinned = await local.fetch({ url: `http://pin.skip.invalid:${server.address().port}/pinned` });
      assert.equal(pinned.body.content, 'same behavior');
      traces.push(seen.map((entry) => ({ ...entry, host: entry.host.replace(/:[0-9]+$/, ':PORT') })));
    } finally {
      await dispose();
      server.closeAllConnections();
      await new Promise((done) => server.close(done));
    }
  });
}

test('Android traces are equal and never invoke the OHOS adapter', () => {
  assert.deepEqual(traces[1], traces[0]);
  assert.equal(ohosCalls, 0);
});
