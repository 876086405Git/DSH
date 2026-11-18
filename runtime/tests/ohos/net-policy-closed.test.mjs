import test from 'node:test';
import assert from 'node:assert/strict';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { bootstrapDshNetwork } from '../../ohos/net/bootstrap.mjs';

const prefix = resolve(process.env.OHOS_TEST_DSH_PREFIX);
const network = bootstrapDshNetwork(join(prefix, 'node_modules/@deepseek-ai/dsh/lib/bin.js'));
const { installProxyFromEnvironment } = await import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai/dsh-http-proxy/lib/index.js')));
const api = network.globalDispatcherApi;
let factories = 0;
const originalFactory = network.createDispatcher;
network.createDispatcher = (...args) => { factories++; return originalFactory(...args); };

for (const style of ['legacy', 'v8']) test(`real DSH closed policy reports one ${style} handler error and opens no transport`, async () => {
  const dispose = await installProxyFromEnvironment(new Map(), () => {}), dispatcher = api.getGlobalDispatcher();
  try {
    await dispatcher.close();
    const state = { errors: 0, starts: 0 }, completion = Promise.withResolvers();
    const error = failure => { state.errors++; state.code = failure.code; completion.resolve(); };
    const handler = style === 'legacy' ? { onConnect() { state.starts++; }, onError: error }
      : { onResponseError(controller, failure) { state.controller = controller; error(failure); } };
    let result;
    assert.doesNotThrow(() => { result = dispatcher.dispatch({ origin: 'http://127.0.0.1:1', path: '/', method: 'GET' }, handler); });
    await completion.promise; await new Promise(setImmediate);
    assert.equal(result, false); assert.equal(state.code, 'UND_ERR_CLOSED'); assert.equal(state.errors, 1); assert.equal(state.starts, 0);
    if (style === 'v8') assert.equal(state.controller, null);
    assert.equal(factories, 0);
  } finally { await dispose(); }
});
test.after(async () => { network.createDispatcher = originalFactory; await network.dispatcher.destroy(); });
