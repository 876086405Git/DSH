// Standalone near-heap-limit smoke; Simulator shares this Mac's filesystem.
import {spawn} from 'node:child_process';
import {mkdirSync, writeFileSync, realpathSync} from 'node:fs';
import {resolve, join, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';

const {values} = parseArgs({options: Object.fromEntries(
  ['simulator', 'smoke', 'frameworks', 'work', 'linux-preload', 'library', 'native-dir'].map(name => [name, {type: 'string'}]))});
for (const key of ['smoke', 'work']) if (!values[key]) throw new Error(`--${key} required`);
if (!values['linux-preload'] && (!values.simulator || !values.frameworks)) throw new Error('--simulator and --frameworks required');
if (values['linux-preload'] && !values.library) throw new Error('--library required for Linux verification');
const work = resolve(values.work);
mkdirSync(work, {mode: 0o700});
const root = realpathSync(work);
const preload = join(root, 'runtime/ohos/preload.mjs');
mkdirSync(dirname(preload), {recursive: true, mode: 0o700});
writeFileSync(preload, '// Empty diagnostic preload: isolate main-heap recovery, not a full DSH session.\n', {mode: 0o600});
const library = values.library ? resolve(values.library) : join(resolve(values.frameworks), 'DshNodeHost.framework/DshNodeHost');
const nativeDirectory = resolve(values['native-dir'] ?? values.frameworks ?? dirname(library));
const env = {...process.env, DSH_GO_OHOS_NATIVE_LIBRARY_DIR: nativeDirectory, SIMCTL_CHILD_DSH_GO_OHOS_NATIVE_LIBRARY_DIR: nativeDirectory};
for (const key of ['NODE_OPTIONS', 'DSH_IOS_SMOKE_PATCH', 'DSH_IOS_SMOKE_IMPORT']) { delete env[key]; delete env['SIMCTL_CHILD_' + key]; }
const argv = [library, preload, fileURLToPath(new URL('./heap-main.mjs', import.meta.url))];
let command, args;
if (values['linux-preload']) { command = resolve(values.smoke); args = argv; env.LD_PRELOAD = resolve(values['linux-preload']); }
else { command = 'xcrun'; args = ['simctl', 'spawn', values.simulator, resolve(values.smoke), ...argv]; }
const report = {status: 'BLOCKED', scope: values['linux-preload'] ? 'Linux official Node; Apple NOT_RUN' : 'iOS Simulator prepared NodeMobile framework',
  rows: [], errors: [], exit: null, stderrTail: '', command: [command, ...args], nativeDirectory};
const child = spawn(command, args, {env, stdio: ['ignore', 'pipe', 'pipe']});
let stdout = '', stderr = '';
const deadline = setTimeout(() => { report.errors.push('observer deadline'); child.kill('SIGKILL'); }, 150000);
const collect = (name, chunk) => {
  if ((name === 'stdout' ? stdout.length : stderr.length) + chunk.length > 1024 * 1024) {
    if (!report.errors.includes('observer output limit')) report.errors.push('observer output limit');
    child.kill('SIGKILL'); return;
  }
  if (name === 'stdout') stdout += chunk; else stderr += chunk;
};
child.stdout.on('data', chunk => collect('stdout', chunk));
child.stderr.on('data', chunk => collect('stderr', chunk));
await new Promise(done => {
  child.once('error', error => { report.errors.push(error.message); done(); });
  child.once('exit', (code, signal) => { report.exit = {code, signal}; });
  child.once('close', done);
});
clearTimeout(deadline);
for (const line of stdout.split('\n').filter(Boolean)) {
  try { report.rows.push(JSON.parse(line)); } catch { report.errors.push('unexpected non-JSON stdout'); }
}
// The report is the only part of a failed run anyone can read without signing in.
report.stderrTail = stderr.slice(-1500);
const rows = report.rows;
const expectedKinds = ['js-start', 'native-result', 'js-start', 'recovery-ok', 'native-result'];
const valid = report.exit?.code === 0 && report.errors.length === 0 && rows.length === 5 &&
  rows.every((row, index) => row !== null && typeof row === 'object' && row.kind === expectedKinds[index] && row.pid > 0 && row.round === (index < 2 ? 1 : 2)) &&
  new Set(rows.map(row => row.pid)).size === 1 &&
  rows.filter(row => row.kind !== 'native-result').every(row => row.heapLimit >= 256 * 1024 * 1024 && row.heapLimit <= 300 * 1024 * 1024) &&
  rows[1].engineCode === 70 && rows[1].expectedCode === 70 && rows[1].pass === true &&
  rows[3].workerCode === 0 && rows[3].workerValue === 42 &&
  rows[4].engineCode === 0 && rows[4].expectedCode === 0 && rows[4].pass === true &&
  stderr.includes('ERR_IOS_HOST_HEAP_LIMIT: engine stopped at heap limit');
if (valid) report.status = 'PASS';
writeFileSync(join(root, 'stdout.log'), stdout);
writeFileSync(join(root, 'stderr.log'), stderr);
writeFileSync(join(root, 'report.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
process.exitCode = valid ? 0 : 1;
