import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { getEnvironmentData, Worker } from 'node:worker_threads';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';

// This is an actual DSH registration and actual Worker test. The native addon
// and strict simulation are supplied by the caller's existing fixture, never
// copied into an internal command's environment by this test.
const registrationKey = '@deepseek-ai/dsh-app-boot/profile-resolution';
const prefix = resolve(process.env.DSH_PREFIX);
const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const [{ Context }, { PluginPackages, createRuntimeResolution, loadProfile }, { scrubbedParentEnv }] = await Promise.all([
  load('cordis'), load('dsh-app-boot'), load('dsh-subprocess'),
]);

test('DSH profile registration does not enter internal command Worker subtrees', { timeout: 90000 }, async t => {
  assert.equal(process.platform, 'openharmony', 'exercise the OH product branch');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true, 'explicit host fixture only');
  assert.equal(getEnvironmentData(registrationKey), undefined);
  assert.equal(typeof process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR, 'string');
  assert.equal(scrubbedParentEnv().DSH_GO_OHOS_NATIVE_LIBRARY_DIR, undefined);
  assert.equal(scrubbedParentEnv().DSH_GO_OHOS_SIM_ADDONS, undefined);
  const base = await mkdtemp(join(tmpdir(), 'ohos-internal-profile-'));
  const home = join(base, 'home'), profile = join(home, 'profiles/web');
  const workspace = join(base, 'workspace'), temporaryRoot = join(base, 'tmp');
  for (const dir of [profile, workspace, temporaryRoot]) await mkdir(dir, { recursive: true });
  await writeFile(join(profile, 'package.json'), JSON.stringify({
    name: 'internal-worker-boundary', private: true, dependencies: {}, dsh: { profile: { bundles: [] } },
  }));
  await writeFile(join(workspace, 'input.txt'), '真实中文命中\n');
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [workspace], temporaryRoot });
  let ctx;
  async function run(argv, env = {}) {
    const handle = runtime.spawn({ argv, cwd: workspace, env, graceMs: 1000,
      stdio: { stdin: { data: '' }, stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } } });
    const outcome = await handle.done;
    return { ...outcome, stdout: handle.collected.stdout.readFrom(0).text,
      stderr: handle.collected.stderr.readFrom(0).text };
  }
  const inspect = `JSON.stringify({
    registered: require('node:worker_threads').getEnvironmentData(${JSON.stringify(registrationKey)}) !== undefined,
    privatePaths: globalThis[Symbol.for('dsh.go.ohos.nodeWorker.paths')]?.protocol === 1,
    native: process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR ?? null,
    addons: process.env.DSH_GO_OHOS_SIM_ADDONS ?? null,
    cwd: process.cwd(), bytes: require('node:fs').readFileSync('./input.txt', 'utf8')
  })`;
  const expectedNode = { registered: false, privatePaths: true, native: null, addons: null,
    cwd: workspace, bytes: '真实中文命中\n' };
  const shellQuote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  try {
    await t.test('unregistered shell control keeps the original environment scrub', async () => {
      const result = await run(['bash', '-c', 'printf "ok|%s|%s" "$DSH_GO_OHOS_NATIVE_LIBRARY_DIR" "$DSH_GO_OHOS_SIM_ADDONS"']);
      assert.equal(result.exitCode, 0, result.stderr);
      assert.equal(result.stdout, 'ok||');
    });
    const installAnchor = join(prefix, 'node_modules/@deepseek-ai/dsh/package.json');
    const resolution = await createRuntimeResolution({ installAnchor, home,
      profile: loadProfile('dsh', 'web', installAnchor, home) });
    ctx = new Context();
    await ctx.plugin(PluginPackages, { resolution });
    const registered = getEnvironmentData(registrationKey);
    assert.notEqual(registered, undefined, 'real PluginPackages published the profile');

    await t.test('registered shell runs with both native loader inputs still scrubbed', async () => {
      const result = await run(['bash', '-c', 'printf "ok|%s|%s" "$DSH_GO_OHOS_NATIVE_LIBRARY_DIR" "$DSH_GO_OHOS_SIM_ADDONS"']);
      assert.equal(result.exitCode, 0, result.stderr);
      assert.equal(result.stdout, 'ok||');
    });
    await t.test('registered rg executes the real search provider', async () => {
      const result = await run(['rg', '真实中文', 'input.txt']);
      assert.equal(result.exitCode, 0, result.stderr);
      assert.match(result.stdout, /真实中文命中/);
    });
    await t.test('direct Node keeps private cwd and fs without profile or addon inputs', async () => {
      const result = await run(['node', '-p', inspect]);
      assert.equal(result.exitCode, 0, result.stderr);
      assert.deepEqual(JSON.parse(result.stdout), expectedNode);
    });
    await t.test('bash to Node clears the same profile before the second Worker starts', async () => {
      const result = await run(['bash', '-c', 'node -p ' + shellQuote(inspect)]);
      assert.equal(result.exitCode, 0, result.stderr);
      assert.deepEqual(JSON.parse(result.stdout), expectedNode);
    });
    await t.test('internal Node ESM imports child_process without a managed-plugin ancestor scan; guards remain installed', async () => {
      await writeFile(join(workspace, 'relative.mjs'), "export default 'relative-ok';\n");
      await writeFile(join(workspace, 'guarded.mjs'), `
        import assert from 'node:assert/strict';
        import { spawn } from 'node:child_process';
        import { readFileSync } from 'node:fs';
        import value from './relative.mjs';
        assert.equal(value, 'relative-ok');
        assert.equal(readFileSync('./input.txt', 'utf8'), '真实中文命中\\n');
        assert.throws(() => spawn('node', ['-e', '']), { code: 'ERR_OHOS_CHILD_PROCESS_UNAVAILABLE' });
        assert.throws(() => readFileSync('../outside.txt'), error => error.code === 'EACCES' && /OHOS_SANDBOX_DENIED/.test(error.message));
        console.log('internal-esm-guard-ok');
      `);
      for (const argv of [['node', 'guarded.mjs'], ['bash', '-c', 'node guarded.mjs']]) {
        const result = await run(argv);
        assert.equal(result.exitCode, 0, result.stderr);
        assert.equal(result.stdout, 'internal-esm-guard-ok\n');
      }
    });
    await t.test('a Node script ordinary descendant inherits no DSH profile registration', async () => {
      await writeFile(join(workspace, 'descendant.mjs'), `
        import { parentPort, getEnvironmentData } from 'node:worker_threads';
        parentPort.postMessage({ registered: getEnvironmentData(${JSON.stringify(registrationKey)}) !== undefined,
          native: process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR ?? null,
          addons: process.env.DSH_GO_OHOS_SIM_ADDONS ?? null,
          privatePaths: !!globalThis[Symbol.for('dsh.go.ohos.nodeWorker.paths')] });
      `);
      await writeFile(join(workspace, 'parent.mjs'), `
        import { Worker } from 'node:worker_threads';
        const worker = new Worker(new URL('./descendant.mjs', import.meta.url));
        const result = await new Promise((resolve, reject) => {
          worker.once('message', resolve); worker.once('error', reject);
          worker.once('exit', code => { if (code !== 0) reject(new Error('descendant exit ' + code)); });
        });
        console.log(JSON.stringify(result));
      `);
      for (const argv of [['node', 'parent.mjs'], ['bash', '-c', 'node parent.mjs']]) {
        const result = await run(argv);
        assert.equal(result.exitCode, 0, result.stderr);
        assert.deepEqual(JSON.parse(result.stdout), { registered: false, native: null, addons: null, privatePaths: false });
      }
    });
    await t.test('a user command env cannot opt into profile bootstrap or substitute a native library', async () => {
      const result = await run(['bash', '-c', 'printf explicit-env-ok'], {
        DSH_GO_OHOS_NATIVE_LIBRARY_DIR: '/nonexistent-untrusted-native',
        DSH_GO_OHOS_SIM_ADDONS: '[]',
        DSH_OHOS_WORKER_KIND: 'plugin',
      });
      assert.equal(result.exitCode, 0, result.stderr);
      assert.equal(result.stdout, 'explicit-env-ok');
    });
    await t.test('ordinary Workers retain the parent registration; unknown internal protocols do not clear it', async () => {
      const entry = join(base, 'ordinary.mjs');
      await writeFile(entry, `
        import { parentPort, getEnvironmentData } from 'node:worker_threads';
        parentPort.postMessage({ registered: getEnvironmentData(${JSON.stringify(registrationKey)}) !== undefined,
          hasWriter: !!globalThis[Symbol.for('dsh.go.ohos.plugins')] });
      `);
      for (const workerData of [undefined, { dshOhosVirtualProcess: { protocol: 2 } }, { dshOhosNodeScript: { protocol: 2 } }]) {
        const worker = new Worker(pathToFileURL(entry), { workerData });
        try {
          const value = await new Promise((resolve, reject) => {
            worker.once('message', resolve); worker.once('error', reject);
            worker.once('exit', code => { if (code !== 0) reject(new Error('ordinary exit ' + code)); });
          });
          assert.deepEqual(value, { registered: true, hasWriter: false });
        } finally { await worker.terminate(); }
      }
      assert.deepEqual(getEnvironmentData(registrationKey), registered, 'child clearing never changes the parent');
    });
    await ctx.fiber.dispose(); ctx = undefined;
    await t.test('disposing the real profile returns the parent to its original unregistered state', async () => {
      assert.equal(getEnvironmentData(registrationKey), undefined);
      const result = await run(['bash', '-c', 'printf after-profile-ok']);
      assert.equal(result.exitCode, 0, result.stderr);
      assert.equal(result.stdout, 'after-profile-ok');
    });
  } finally {
    await ctx?.fiber.dispose();
    await runtime.dispose();
    await rm(base, { recursive: true, force: true });
  }
});
