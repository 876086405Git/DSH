// Runs env-probe-main.mjs in the Simulator under a named time zone, and puts the answers where they
// can be read without signing in. It records; it doesn't judge, so it never fails the build.
import { spawnSync } from 'node:child_process';
import { mkdirSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: Object.fromEntries(
  ['simulator', 'smoke', 'frameworks', 'runtime', 'work'].map(name => [name, { type: 'string' }])) });
for (const key of ['simulator', 'smoke', 'frameworks', 'runtime', 'work']) if (!values[key]) throw new Error(`--${key} required`);

const work = resolve(values.work);
mkdirSync(work, { mode: 0o700 });
const root = realpathSync(work);
const runtime = resolve(values.runtime);
const preload = join(root, 'runtime/ohos/preload.mjs');
mkdirSync(dirname(preload), { recursive: true, mode: 0o700 });
// Same single preload as the image check, so this reads the build the engine really runs on.
const publication = pathToFileURL(join(runtime, 'runtime/ohos/publication/preload.mjs')).href;
writeFileSync(preload, `await import(${JSON.stringify(publication)});\n`, { mode: 0o600 });
const home = join(root, 'home');
mkdirSync(home, { mode: 0o700 });
const nativeDirectory = resolve(values.frameworks);
const env = {
  ...process.env,
  DSH_GO_OHOS_NATIVE_LIBRARY_DIR: nativeDirectory, SIMCTL_CHILD_DSH_GO_OHOS_NATIVE_LIBRARY_DIR: nativeDirectory,
  DSH_IOS_IMAGE_RUNTIME: runtime, SIMCTL_CHILD_DSH_IOS_IMAGE_RUNTIME: runtime,
  DSH_HOME: home, SIMCTL_CHILD_DSH_HOME: home,
};
for (const key of ['NODE_OPTIONS', 'DSH_IOS_SMOKE_PATCH', 'DSH_IOS_SMOKE_IMPORT']) { delete env[key]; delete env[`SIMCTL_CHILD_${key}`]; }

const clean = text => String(text).replace(/%/g, '%25').replace(/\s+/g, ' ').slice(0, 3500);
const script = fileURLToPath(new URL('./env-probe-main.mjs', import.meta.url));
const library = join(nativeDirectory, 'DshNodeHost.framework/DshNodeHost');
for (const zone of [null, 'Asia/Shanghai']) {
  const zoned = { ...env };
  if (zone) zoned.SIMCTL_CHILD_TZ = zone;
  const run = spawnSync('xcrun', ['simctl', 'spawn', values.simulator, resolve(values.smoke), library, preload, script],
    { env: zoned, encoding: 'utf8', timeout: 120000 });
  const title = `node env (${zone ?? 'simulator default'})`;
  const answer = run.stdout?.split('\n').filter(Boolean).at(-1);
  console.log(`::notice title=${title}::${clean(answer ?? `no answer, status ${run.status}: ${run.stderr?.slice(-600)}`)}`);
}
