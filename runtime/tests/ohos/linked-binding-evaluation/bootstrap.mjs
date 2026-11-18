// Test instrumentation: deliberately dynamic addon registration after Node init.
import { isMainThread } from 'node:worker_threads';
import { createRequire } from 'node:module';
import { writeFileSync } from 'node:fs';
if (isMainThread) {
  let absent = false;
  try { process._linkedBinding('dsh_ohos_publication'); } catch (error) { absent = error.code === 'ERR_INVALID_MODULE'; }
  if (!absent) throw new Error('Experiment requires no earlier publication registration');
  const bootstrap = createRequire(import.meta.url)(process.env.DSH_M6_TEST_ADDON);
  bootstrap.registerModern('dsh_ohos_publication');
  writeFileSync(process.env.DSH_M6_BOOTSTRAP_SENTINEL, 'modern-bootstrap-ran\n');
}
