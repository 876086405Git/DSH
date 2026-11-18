// Explicit test-only predecessor. Product startup never imports this observer.
import { isMainThread } from 'node:worker_threads';
import { createRequire } from 'node:module';
const config = JSON.parse(process.env.OHOS_STARTUP_CASE);
if (isMainThread) {
  globalThis.__ohosStartupSnapshot = { fetch: globalThis.fetch,
    Request: globalThis.Request, Response: globalThis.Response,
    Headers: globalThis.Headers, FormData: globalThis.FormData };
  if (config.name === 'android-env') Object.defineProperty(process, 'platform', { value: 'android' });
  if (config.name === 'late-undici') createRequire(config.entry)('undici');
  process.on('uncaughtExceptionMonitor', error => {
    console.log(JSON.stringify({ failure: error.code,
      network: !!globalThis[Symbol.for('dsh.go.ohos.net')],
      publication: !!globalThis[Symbol.for('dsh.go.ohos.publication')] }));
  });
}
