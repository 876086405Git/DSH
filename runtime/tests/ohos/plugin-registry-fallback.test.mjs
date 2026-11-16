import test from 'node:test';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { readFile } from 'node:fs/promises';
import { fixture, name, hash } from './plugin-package-harness.mjs';
const dispatcherModule = process.env.DSH_PLUGIN_DISPATCHER_MODULE
  ? pathToFileURL(resolve(process.env.DSH_PLUGIN_DISPATCHER_MODULE))
  : new URL('../../ohos/net/dispatcher.mjs', import.meta.url);
const { createHttpDispatcher } = await import(dispatcherModule);
const primary = 'https://registry.ohos-fixture.test', fallback = 'https://fallback.ohos-fixture.test';
for (const mode of ['disconnect', 'body-timeout', 'cancel', 'invalid-json']) {
  test(`actual manager registry ${mode} preserves fallback classification`, { timeout: 15000 }, async t => {
    const dispatcher = createHttpDispatcher({ proxyEnv: {}, bodyTimeout: mode === 'cancel' ? 3000 : 80, headersTimeout: 1000 });
    t.after(() => dispatcher.destroy());
    const bodyStarted = Promise.withResolvers(), requestedUrls = [];
    const f = await fixture(t, {}, { network: {
      fallbackRegistries: [fallback],
      onRequest(req, res) {
        if (req.url.startsWith('/primary/')) {
          res.writeHead(200, { 'content-type': 'application/json' });
          if (mode === 'invalid-json') res.end('{"versions":');
          else {
            res.write('{"versions":');
            if (mode === 'disconnect') setTimeout(() => res.destroy(), 20);
          }
          bodyStarted.resolve(); return true;
        }
        req.url = req.url.replace(/^\/fallback/, '');
        return false;
      },
      createFetch(localOrigin) {
        return (input, init) => {
          const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
          assert([primary, fallback].includes(url.origin)); assert.equal(url.protocol, 'https:');
          requestedUrls.push(url.href);
          return fetch(localOrigin + (url.origin === primary ? '/primary' : '/fallback') + url.pathname, { ...init, dispatcher });
        };
      },
    } });
    f.facts.transport = 'real global fetch with explicit OH createHttpDispatcher; fixed HTTPS fixture URLs mapped to own loopback HTTP transport';
    f.facts.registrySha256 = hash(await readFile(new URL('./registry.mjs', pathToFileURL(resolve(process.env.DSH_PLUGIN_BACKEND_MODULE)))));
    const before = await f.snapshot(true), controller = new AbortController();
    const pending = f.invoke('inspect', name + '@1.0.0', { registry: primary }, controller.signal);
    if (mode === 'cancel') {
      await Promise.race([bodyStarted.promise, pending.then(result => { throw Error('inspection ended before held body: ' + JSON.stringify(result)); })]);
      controller.abort(new Error('fixture user cancelled registry inspection'));
    }
    const result = await pending;
    f.facts.requestedHttpsUrls = requestedUrls;
    assert.deepEqual(await f.snapshot(true), before, 'inspection changes no profile file');
    const expected = mode === 'disconnect' || mode === 'body-timeout';
    if (expected) { assert.equal(result.status, 'accepted', JSON.stringify(result)); assert.equal(result.registry, fallback + '/'); }
    else {
      assert.equal(result.status, 'refused', JSON.stringify(result));
      assert.match(result.reason, mode === 'cancel' ? /fixture user cancelled/ : /invalid JSON metadata/);
    }
    assert.deepEqual(f.facts.requests, [`/primary/${name}`, ...(expected ? [`/fallback/${name}`] : [])]);
    assert.deepEqual(requestedUrls, [primary + '/' + name, ...(expected ? [fallback + '/' + name] : [])]);
  });
}
