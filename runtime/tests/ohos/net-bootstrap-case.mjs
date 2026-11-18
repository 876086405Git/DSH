import { isMainThread, Worker } from 'node:worker_threads';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import http from 'node:http';
import { once } from 'node:events';

// This observer is a preload too; an inherited Worker must not execute the case again.
if (isMainThread) {
  const config = JSON.parse(process.env.OHOS_BOOTSTRAP_CASE);
  const prefix = resolve(config.prefix), root = resolve(config.netRoot);
  const require = createRequire(join(prefix, 'package.json'));
  const entry = join(prefix, 'node_modules/@deepseek-ai/dsh/lib/bin.js');
  const load = file => import(pathToFileURL(join(root, file)));
  const undiciPath = require.resolve('undici');
  const nativeFetch = globalThis[Symbol.for('dsh.ohos.test.nativeFetch')];
  const dispatchers = [], sockets = new Set();
  let server, network, result;
  const createServer = async () => {
    server = http.createServer((_request, response) => response.end('ok'));
    server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
    server.listen(0, '127.0.0.1'); await once(server, 'listening');
    return `http://127.0.0.1:${server.address().port}`;
  };
  const policy = () => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai/dsh-http-proxy/lib/index.js')));
  try {
    if (config.name === 'fresh' || config.name === 'custom' || config.name === 'worker') {
      network = globalThis[Symbol.for('dsh.go.ohos.net')];
      if (!network?.globalDispatcherApi) throw new Error('dedicated DSH preload did not run before the observer');
      const api = network.globalDispatcherApi, undici = require('undici'), url = await createServer();
      if (config.name === 'worker') {
        const worker = new Worker(new URL('./net-bootstrap-worker.mjs', import.meta.url), { env: { ...process.env, OHOS_BOOTSTRAP_TEST_URL: url } });
        try {
          const done = once(worker, 'exit');
          const [message] = await once(worker, 'message');
          const [code] = await done;
          result = { ...message, exitCode: code, beforeEntry: true };
        } finally { await worker.terminate(); }
      } else {
        let expected = api.baseDispatcher, calls = 0, repeated;
        if (config.name === 'custom') {
          const transport = network.createDispatcher({ proxyEnv: {} }); dispatchers.push(transport);
          expected = { dispatch(...args) { calls++; return transport.dispatch(...args); }, close: () => transport.close(), destroy: error => transport.destroy(error) };
          api.setGlobalDispatcher(expected);
          const { bootstrapDshNetwork } = await load('bootstrap.mjs');
          bootstrapDshNetwork(entry);
          repeated = api.getGlobalDispatcher() === expected;
        }
        const { installProxyFromEnvironment } = await policy();
        const dispose = await installProxyFromEnvironment(new Map(), () => {});
        await dispose();
        result = { beforeEntry: true, restoredSame: api.getGlobalDispatcher() === expected, repeatedPreserved: repeated,
          external: await (await undici.fetch(url)).text(), native: await (await nativeFetch(url)).text() };
        if (config.name === 'custom') result.customCalls = calls;
        api.setGlobalDispatcher(api.baseDispatcher);
      }
    } else if (config.name === 'cached-default' || config.name === 'cached-explicit' || config.name === 'esm-cached') {
      const undici = config.name === 'esm-cached' ? await import(pathToFileURL(undiciPath)) : require('undici');
      if (config.name === 'cached-explicit') {
        const { createHttpDispatcher } = await load('dispatcher.mjs');
        const explicit = createHttpDispatcher({ proxyEnv: {} }); dispatchers.push(explicit); undici.setGlobalDispatcher(explicit);
      }
      const previous = undici.getGlobalDispatcher(), previousFetch = globalThis.fetch;
      let code;
      try { await load('dsh-preload.mjs'); } catch (error) { code = error.code; }
      result = { code, cacheVisible: Object.hasOwn(require.cache, undiciPath), dispatcherSame: undici.getGlobalDispatcher() === previous, fetchSame: globalThis.fetch === previousFetch };
      if (config.name === 'cached-explicit') result.body = await (await undici.fetch(await createServer())).text();
    } else if (config.name === 'generic') {
      const { installFetch } = await load('fetch.mjs'); network = installFetch();
      const { installProxyFromEnvironment } = await policy();
      let code;
      try { await installProxyFromEnvironment(new Map(), () => {}); } catch (error) { code = error.code; }
      result = { code, externalUndiciLoaded: Object.hasOwn(require.cache, undiciPath), factoryBody: await (await network.fetch(await createServer())).text() };
    } else if (config.name === 'wrong-entry') {
      const previousFetch = globalThis.fetch;
      let code;
      try { await load('dsh-preload.mjs'); } catch (error) { code = error.code; }
      result = { code, fetchSame: globalThis.fetch === previousFetch, externalUndiciLoaded: Object.hasOwn(require.cache, undiciPath) };
    } else if (config.name === 'android-env') {
      Object.defineProperty(process, 'platform', { value: 'android' }); process.env.DSH_GO_OHOS_SIM = '1';
      const previousFetch = globalThis.fetch;
      await load('dsh-preload.mjs');
      result = { fetchSame: globalThis.fetch === previousFetch, networkInstalled: !!globalThis[Symbol.for('dsh.go.ohos.net')], externalUndiciLoaded: Object.hasOwn(require.cache, undiciPath) };
    } else throw new Error('unknown bootstrap fixture');
  } catch (error) {
    result = { failure: { name: error.name, code: error.code, message: error.message, cause: error.cause?.message } };
  } finally {
    for (const dispatcher of dispatchers) await dispatcher.destroy();
    await network?.dispatcher.destroy();
    for (const socket of sockets) socket.destroy();
    if (server) await new Promise(resolve => server.close(resolve));
  }
  console.log(JSON.stringify(result));
  // Stop before the real DSH bin is evaluated; this fixture measures the preload seam.
  process.exit(0);
}
