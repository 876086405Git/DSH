import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const execute = promisify(execFile);
const prefix = resolve(process.env.OHOS_TEST_DSH_PREFIX);
const netRoot = fileURLToPath(new URL('../../ohos/net/', import.meta.url));
const simRoot = fileURLToPath(new URL('../../ohos/sim/', import.meta.url));
const observer = fileURLToPath(new URL('./net-bootstrap-case.mjs', import.meta.url));
const capture = fileURLToPath(new URL('./net-bootstrap-capture.mjs', import.meta.url));
const entry = join(prefix, 'node_modules/@deepseek-ai/dsh/lib/bin.js');

async function run(name, mode) {
  const args = mode === 'strict' ? ['--jitless'] : [];
  args.push('--import', capture);
  if (name !== 'android-env') args.push('--import', join(simRoot, mode === 'strict' ? 'preload.mjs' : 'marker.mjs'));
  if (['fresh', 'custom', 'worker'].includes(name)) args.push('--import', join(netRoot, 'dsh-preload.mjs'));
  args.push('--import', observer, name === 'wrong-entry' ? observer : entry);
  const env = { ...process.env, OHOS_BOOTSTRAP_CASE: JSON.stringify({ name, prefix, netRoot }) };
  for (const key of ['NODE_OPTIONS', 'NODE_USE_ENV_PROXY', 'DSH_GO_OHOS_SIM', 'DSH_GO_OHOS_SIM_PLATFORM', 'HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy', 'NO_PROXY', 'no_proxy', 'ALL_PROXY', 'all_proxy']) delete env[key];
  const { stdout } = await execute(process.execPath, args, { env, timeout: 15000, maxBuffer: 1024 * 1024 });
  const outcome = JSON.parse(stdout.trim());
  assert.equal(outcome.failure, undefined, JSON.stringify(outcome));
  return outcome;
}

for (const mode of ['jit', 'strict']) {
  test(`${mode}: actual DSH argv entry primes a safe default before policy installation and disposal`, async () => {
    assert.deepEqual(await run('fresh', mode), { beforeEntry: true, restoredSame: true, external: 'ok', native: 'ok' });
  });
  test(`${mode}: custom dispatcher installed after the owned base survives repeat bootstrap and disposal`, async () => {
    assert.deepEqual(await run('custom', mode), { beforeEntry: true, restoredSame: true, repeatedPreserved: true, external: 'ok', native: 'ok', customCalls: 2 });
  });
  test(`${mode}: a real Worker inherits the DSH preload without interpreting its own entry as the CLI`, async () => {
    assert.deepEqual(await run('worker', mode), { body: 'ok', installed: true, hasDshApi: false, simulated: true, workerEntry: true, exitCode: 0, beforeEntry: true });
  });
  for (const name of ['cached-default', 'cached-explicit', 'esm-cached']) test(`${mode}: ${name} causes a startup-order error without replacing the existing dispatcher`, async () => {
    assert.deepEqual(await run(name, mode), { code: 'ERR_OHOS_NET_BOOTSTRAP_ORDER', cacheVisible: true, dispatcherSame: true, fetchSame: true, ...(name === 'cached-explicit' ? { body: 'ok' } : {}) });
  });
  test(`${mode}: generic factories work while global policy requires the dedicated bootstrap`, async () => {
    assert.deepEqual(await run('generic', mode), { code: 'ERR_OHOS_NET_BOOTSTRAP_REQUIRED', externalUndiciLoaded: false, factoryBody: 'ok' });
  });
  test(`${mode}: an unrelated main entry fails before changing fetch or loading Undici`, async () => {
    assert.deepEqual(await run('wrong-entry', mode), { code: 'ERR_OHOS_NET_DSH_ENTRY', fetchSame: true, externalUndiciLoaded: false });
  });
  test(`${mode}: Android with the obsolete environment variable does not install the DSH bootstrap`, async () => {
    assert.deepEqual(await run('android-env', mode), { fetchSame: true, networkInstalled: false, externalUndiciLoaded: false });
  });
}
