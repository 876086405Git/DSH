// Runs image-main.mjs on the prepared framework in the Simulator, and reports what it says.
import { spawn } from 'node:child_process';
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
// The one part of the real preload the store needs: it won't write a file without the publisher.
const publication = pathToFileURL(join(runtime, 'runtime/ohos/publication/preload.mjs')).href;
writeFileSync(preload, `await import(${JSON.stringify(publication)});\n`, { mode: 0o600 });
const home = join(root, 'home');
mkdirSync(home, { mode: 0o700 });
const library = join(resolve(values.frameworks), 'DshNodeHost.framework/DshNodeHost');
const nativeDirectory = resolve(values.frameworks);
const env = {
  ...process.env,
  DSH_GO_OHOS_NATIVE_LIBRARY_DIR: nativeDirectory, SIMCTL_CHILD_DSH_GO_OHOS_NATIVE_LIBRARY_DIR: nativeDirectory,
  DSH_IOS_IMAGE_RUNTIME: runtime, SIMCTL_CHILD_DSH_IOS_IMAGE_RUNTIME: runtime,
  DSH_HOME: home, SIMCTL_CHILD_DSH_HOME: home,
};
for (const key of ['NODE_OPTIONS', 'DSH_IOS_SMOKE_PATCH', 'DSH_IOS_SMOKE_IMPORT']) { delete env[key]; delete env[`SIMCTL_CHILD_${key}`]; }
const script = fileURLToPath(new URL('./image-main.mjs', import.meta.url));
const child = spawn('xcrun', ['simctl', 'spawn', values.simulator, resolve(values.smoke), library, preload, script],
  { env, stdio: ['ignore', 'pipe', 'pipe'] });
const report = { status: 'BLOCKED', exit: null, stderrTail: '', errors: [], rows: [] };
let stdout = '';
let stderr = '';
const deadline = setTimeout(() => { report.errors.push('observer deadline'); child.kill('SIGKILL'); }, 300000);
child.stdout.on('data', chunk => { stdout += chunk; });
child.stderr.on('data', chunk => { stderr += chunk; });
await new Promise(done => {
  child.once('error', error => { report.errors.push(error.message); done(); });
  child.once('exit', (code, signal) => { report.exit = { code, signal }; });
  child.once('close', done);
});
clearTimeout(deadline);
for (const line of stdout.split('\n').filter(Boolean)) {
  try { report.rows.push(JSON.parse(line)); } catch { report.errors.push(`not JSON: ${line.slice(0, 200)}`); }
}
report.stderrTail = stderr.slice(-1500);
const done = report.rows.find(row => row.name === 'done');
const good = report.exit?.code === 0 && report.errors.length === 0 && done?.failures === 0 &&
  report.rows.filter(row => row.pass === true).length >= 9;
if (good) report.status = 'PASS';
writeFileSync(join(root, 'report.json'), `${JSON.stringify(report, null, 2)}\n`);
console.log(JSON.stringify(report, null, 2));
process.exitCode = good ? 0 : 1;
