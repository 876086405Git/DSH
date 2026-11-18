// Actual Node Fetch (or its explicitly selected source bundle) plus real HTTP.
// The optional bundle is test input; no global constructor or builtin is patched.
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import test from 'node:test';
import { createHttpDispatcher } from '../../ohos/net/dispatcher.mjs';

const api = process.env.DSH_GO_UNDICI_BUNDLE
  ? createRequire(import.meta.url)(resolve(process.env.DSH_GO_UNDICI_BUNDLE)) : globalThis;
const reasons = [
  ['null', null], ['zero', 0], ['false', false], ['empty-string', ''],
  ['negative-zero', -0], ['NaN', NaN], ['bigint-zero', 0n],
  ['object', { detail: '保留原因' }], ['Error', new Error('original reason')],
  ['undefined-default', undefined],
];

async function fixture(t, complete = false) {
  const closed = Promise.withResolvers();
  const dispatcher = createHttpDispatcher({ headersTimeout: 5000, bodyTimeout: 5000 });
  const server = http.createServer((_request, response) => {
    response.on('close', closed.resolve);
    response.writeHead(200);
    if (complete) response.end('first');
    else response.write('first');
  }).listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => {
    await dispatcher.destroy();
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  });
  const controller = new AbortController();
  const response = await api.fetch(`http://127.0.0.1:${server.address().port}/`, {
    signal: controller.signal, dispatcher,
  });
  return { controller, response, closed: closed.promise };
}

for (const [label, reason] of reasons) {
  test(`body reader retains ${label} while a read is pending and the socket closes`, { timeout: 10000 }, async t => {
    const { controller, response, closed } = await fixture(t);
    const reader = response.body.getReader();
    assert.equal(new TextDecoder().decode((await reader.read()).value), 'first');
    const pending = reader.read().then(() => ({ resolved: true }), error => ({ error }));
    controller.abort(reason);
    const result = await pending;
    assert.equal(result.resolved, undefined);
    assert(Object.is(result.error, controller.signal.reason), `body reason changed for ${label}`);
    if (reason === undefined) assert.equal(result.error.name, 'AbortError');
    else assert(Object.is(result.error, reason));
    await closed;
  });

  test(`body text consumption retains ${label} rather than substituting EOF or another error`, { timeout: 10000 }, async t => {
    const { controller, response, closed } = await fixture(t);
    const pending = response.text().then(value => ({ value }), error => ({ error }));
    controller.abort(reason);
    const result = await pending;
    assert.equal(result.value, undefined);
    assert(Object.is(result.error, controller.signal.reason), `text reason changed for ${label}`);
    await closed;
  });
}

for (const reason of [null, 0, false]) {
  test(`cloned response streams both preserve ${String(reason)}`, { timeout: 10000 }, async t => {
    const { controller, response, closed } = await fixture(t);
    const clone = response.clone();
    const pending = [response.text(), clone.text()].map(p => p.then(() => ({ resolved: true }), error => ({ error })));
    controller.abort(reason);
    for (const result of await Promise.all(pending)) assert(Object.is(result.error, reason));
    await closed;
  });
}

test('abort after complete consumption leaves the completed result intact', async t => {
  const { controller, response, closed } = await fixture(t, true);
  const body = await response.text();
  controller.abort(false);
  assert.equal(body, 'first');
  assert.equal(response.bodyUsed, true);
  await closed;
});
