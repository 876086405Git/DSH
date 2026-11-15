// Test-owned network configuration through Undici's public dispatcher API.
// Native fetch/Request/Response/Headers identities are never replaced.
import assert from 'node:assert/strict';
import { before, after } from 'node:test';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { createHttpDispatcher } from '../../ohos/net/dispatcher.mjs';

if (!process.env.DSH_PREFIX) throw Error('DSH_PREFIX is required for the locked dispatcher API');
const require = createRequire(resolve(process.env.DSH_PREFIX, 'package.json'));
const { getGlobalDispatcher, setGlobalDispatcher } = require('undici');
const originals = [globalThis.fetch, globalThis.Request, globalThis.Response, globalThis.Headers];
let previous, dispatcher;
before(() => {
  previous = getGlobalDispatcher();
  dispatcher = createHttpDispatcher({ proxyEnv: {}, headersTimeout: 1000, bodyTimeout: 1000 });
  setGlobalDispatcher(dispatcher);
});
after(async () => {
  assert.equal(getGlobalDispatcher(), dispatcher, 'test retains its dispatcher ownership');
  setGlobalDispatcher(previous);
  await dispatcher.destroy();
  assert.deepEqual([globalThis.fetch, globalThis.Request, globalThis.Response, globalThis.Headers], originals);
});
