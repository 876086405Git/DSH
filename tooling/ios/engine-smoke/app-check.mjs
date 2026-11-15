// Installs a built app on the Simulator and checks it, in one of two ways.
//
//   node app-check.mjs --simulator <udid> --app <Runner.app> --mode engine
//     The bundle built from integration_test/ios_engine_check.dart reports each step here.
//   node app-check.mjs --simulator <udid> --app <Runner.app> --mode launch --shot <file.png>
//     The real app: it has to come up and still be alive a while later.
//
// Failures become annotations, which can be read without signing in to GitHub. So does a
// small copy of the screenshot, since the artifact can't be.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: Object.fromEntries(
  ['simulator', 'app', 'mode', 'shot'].map((name) => [name, { type: 'string' }])) });
const bundleId = 'io.github.ccch1mneyyy.dshgo';
const clean = (text) => String(text).replace(/([?&]token=)[^\s&]+/g, '$1<redacted>')
  .replace(/%/g, '%25').replace(/\r?\n/g, '%0A');
const notice = (title, text) => console.log(`::notice title=${title}::${clean(text).slice(0, 3500)}`);
const fail = (title, text) => console.log(`::error title=${title}::${clean(text).slice(0, 3500)}`);
const simctl = (...args) => execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8' });
const quietly = (work) => { try { return work(); } catch (error) { return `(${String(error.message).split('\n')[0]})`; } };

const startedAt = Date.now();
const scratch = mkdtempSync(join(tmpdir(), 'dsh-app-check-'));
const stdoutFile = join(scratch, 'stdout.log');
const stderrFile = join(scratch, 'stderr.log');

function crashes() {
  const directory = join(homedir(), 'Library/Logs/DiagnosticReports');
  let names = [];
  try { names = readdirSync(directory); } catch { return []; }
  return names.filter((name) => /^Runner/.test(name) && statSync(join(directory, name)).mtimeMs >= startedAt)
    .map((name) => {
      const text = readFileSync(join(directory, name), 'utf8');
      const at = text.indexOf('"termination"');
      const frames = [...text.matchAll(/"symbol":"([^"]+)"/g)].slice(0, 14).map((match) => match[1]);
      return `${name}: ${text.slice(at, at + 400)} frames: ${frames.join(' < ')}`;
    });
}

function launch(environment = {}) {
  const printed = execFileSync('xcrun', ['simctl', 'launch', '--terminate-running-process',
    `--stdout=${stdoutFile}`, `--stderr=${stderrFile}`, values.simulator, bundleId],
  { encoding: 'utf8', env: { ...process.env, ...environment } });
  // Prints "<bundle id>: <pid>"; on the Simulator that's an ordinary Mac process.
  return Number(printed.trim().split(': ').pop());
}

function isAlive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

/** The path each thread is waiting in, deepest frame first. */
function threads(pid) {
  const file = join(scratch, 'sample.txt');
  execFileSync('/usr/bin/sample', [String(pid), '2', '-file', file], { stdio: 'ignore', timeout: 90000 });
  const lines = readFileSync(file, 'utf8').split('\n');
  const start = lines.findIndex((line) => line.startsWith('Call graph:'));
  const found = [];
  let thread = null;
  for (const line of lines.slice(start + 1)) {
    if (!line.trim()) break;
    const label = line.match(/^\s*\d+\s+(Thread_\d+.*)$/);
    if (label) {
      thread = { label: label[1].trim(), frames: [], indent: -1, done: false };
      found.push(thread);
      continue;
    }
    const frame = line.match(/^([\s+!:|]*)\d+\s+(.*)$/);
    if (!frame || !thread || thread.done) continue;
    // The first way down the tree is the heaviest path; a shallower line starts another.
    if (frame[1].length <= thread.indent) { thread.done = true; continue; }
    thread.indent = frame[1].length;
    thread.frames.push(frame[2].replace(/\s+\+ \d+.*$/, '').replace(/\s+\[0x.*$/, '').trim());
  }
  return found.map((item) => `${item.label}: ${item.frames.slice(-7).reverse().join(' < ')}`);
}

function annotateChunks(title, lines, report = notice, limit = 4) {
  let chunk = '';
  let sent = 0;
  for (const line of lines) {
    if (chunk && chunk.length + line.length > 3300) {
      if (++sent > limit) return;
      report(title, chunk);
      chunk = '';
    }
    chunk += `${line}\n`;
  }
  if (chunk && sent < limit) report(title, chunk);
}

/** Everything that says why the app stopped answering. */
function explain(pid) {
  for (const crash of crashes()) fail('app crash', crash);
  notice('app process', `pid ${pid}, ${isAlive(pid) ? 'still running' : 'gone'}`);
  if (isAlive(pid)) annotateChunks('app threads', [].concat(quietly(() => threads(pid))));
  for (const [name, file] of [['stdout', stdoutFile], ['stderr', stderrFile]]) {
    if (existsSync(file)) notice(`app ${name}`, readFileSync(file, 'utf8').slice(-3000) || '(empty)');
  }
  const log = quietly(() => simctl('spawn', values.simulator, 'log', 'show', '--last', '20m', '--style', 'compact',
    '--predicate', 'process == "Runner"'));
  notice('app log', log.split('\n').slice(-45).map((line) => line.slice(0, 220)).join('\n'));
}

function screenshot(file) {
  execFileSync('xcrun', ['simctl', 'io', values.simulator, 'screenshot', file], { stdio: 'ignore' });
  const small = join(scratch, 'small.jpg');
  execFileSync('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '30', '-Z', '220', file, '--out', small], { stdio: 'ignore' });
  const encoded = readFileSync(small).toString('base64');
  for (let at = 0, part = 1; at < encoded.length; at += 3000, part++) {
    notice(`screenshot ${part} of ${Math.ceil(encoded.length / 3000)}`, encoded.slice(at, at + 3000));
  }
}

/** Every reported observation is a gate: "done" alone says only that Dart got to the end. */
function engineProblem(steps) {
  const expected = ['main', 'guest root', 'status', 'install', 'install again', 'start', 'login', 'capabilities',
    'logs', 'stop', 'restart', 'performance', 'stop again', 'reset', 'install after reset', 'start after reset',
    'stop after reset', 'events', 'done'];
  if (steps.length !== expected.length || steps.some((step, index) => step.step !== expected[index])) {
    return 'The app did not report the whole check, in order.';
  }
  const by = Object.fromEntries(steps.map((step) => [step.step, step]));
  const checks = [
    ['absolute guest root', by['guest root'].absolute === true],
    ['install', by.install.phase === 'installed' && by['install again'].phase === 'installed'],
    ['start', by.start.phase === 'running' && by.start.mode === 'ios-embedded'],
    ['login', by.login.status === 303 && by.login.cookie === true],
    ['capabilities', by.capabilities.status === 200 && by.capabilities.v === 1 &&
      by.capabilities.platform === 'openharmony'],
    ['logs', Number.isSafeInteger(by.logs.entries) && by.logs.entries >= 0 &&
      Number.isSafeInteger(by.logs.through) && by.logs.through >= 0],
    ['stop', by.stop.phase === 'installed' && by['stop again'].phase === 'installed'],
    ['restart', by.restart.newToken === true && by.restart.login === 303 && by.restart.cookie === true &&
      by.restart.oldTokenLogin === 401 && by.restart.oldTokenCookie === false],
    ['reset', by.reset.phase === 'notInstalled' && by.reset.kept === true && by.reset.gone === true],
    ['back after reset', by['install after reset'].phase === 'installed' && by['start after reset'].login === 303 &&
      by['stop after reset'].phase === 'installed'],
    ['performance', ['low', 'medium'].includes(by.performance.tier)],
    ['events', Array.isArray(by.events.seen) && by.events.seen.includes('status')],
  ];
  const failed = checks.find(([, passed]) => !passed);
  return failed ? `The app check failed: ${failed[0]}.` : null;
}

simctl('install', values.simulator, values.app);

if (values.mode === 'launch') {
  const pid = launch();
  await new Promise((done) => setTimeout(done, 30000));
  const up = isAlive(pid);
  if (values.shot) quietly(() => screenshot(values.shot));
  // Xcode extracts these at build time and Siri reads only this. Without it they silently don't exist.
  const metadata = join(values.app, 'Metadata.appintents', 'extract.actionsdata');
  const intents = existsSync(metadata) ? readFileSync(metadata, 'utf8') : '';
  const missing = ['AskDshIntent', 'VoiceInputIntent', 'NewChatIntent'].filter((name) => !intents.includes(name));
  if (missing.length) fail('siri', `Not in the app's intent metadata: ${missing.join(', ')}`);
  // Without them the app runs fine and simply has no browser tools.
  const absent = ['agent.js', 'actions.mjs', 'catalog.json'].filter((name) => !existsSync(join(values.app, 'dsh-runtime/browser', name)));
  if (absent.length) fail('browser', `Not in the app bundle: ${absent.join(', ')}`);
  const noSystem = ['actions.mjs', 'results.mjs', 'catalog.json'].filter((name) => !existsSync(join(values.app, 'dsh-runtime/system', name)));
  if (noSystem.length) fail('system', `Not in the app bundle: ${noSystem.join(', ')}`);
  // Alive isn't enough: a launch screen that never leaves is a white screen over a working app.
  // The app notes each startup stage ([dsh-startup], lib/launch/startup_trace.dart).
  const said = [stdoutFile, stderrFile].map((file) => (existsSync(file) ? readFileSync(file, 'utf8') : ''))
    .concat(quietly(() => simctl('spawn', values.simulator, 'log', 'show', '--last', '5m', '--style', 'compact',
      '--predicate', 'process == "Runner" AND eventMessage CONTAINS "[dsh-startup]"'))).join('\n');
  const stages = [...new Set(said.split('\n').filter((line) => line.includes('[dsh-startup]'))
    .map((line) => line.slice(line.indexOf('[dsh-startup]') + 14).trim()))];
  const finished = stages.includes('finished');
  if (!stages.length) notice('app startup', 'No [dsh-startup] lines could be read.');
  else if (!finished) fail('app startup', `The launch screen is still up 30 seconds after launch. Stages: ${stages.join(' | ')}`);
  const passed = up && crashes().length === 0 && missing.length === 0 && absent.length === 0 && noSystem.length === 0 &&
    (finished || !stages.length);
  if (passed) {
    notice('app launch', 'The real app is still running 30 seconds after launch.');
    annotateChunks('app threads', [].concat(quietly(() => threads(pid))).slice(0, 3), notice, 1);
  } else {
    if (!up || crashes().length) {
      fail('app launch', up ? 'The real app produced a crash report.' : 'The real app is not running 30 seconds after launch.');
      explain(pid);
    }
  }
  quietly(() => simctl('terminate', values.simulator, bundleId));
  process.exit(passed ? 0 : 1);
}

// The app writes one JSON line per step, into a container an earlier build may have used.
const reports = join(simctl('get_app_container', values.simulator, bundleId, 'data').trim(), 'tmp', 'dsh-app-check.jsonl');
rmSync(reports, { force: true });
const pid = launch();
console.log(`launched as ${pid}`);

const steps = [];
let lastStepAt = Date.now();
let last = null;
while (!last) {
  await new Promise((done) => setTimeout(done, 1000));
  const text = existsSync(reports) ? readFileSync(reports, 'utf8') : '';
  // Only whole lines: the last one may still be being written.
  const lines = text.slice(0, text.lastIndexOf('\n') + 1).split('\n').filter(Boolean);
  for (const line of lines.slice(steps.length)) {
    const step = JSON.parse(line);
    steps.push(step);
    lastStepAt = Date.now();
    console.log(line);
    if (step.step === 'done' || step.step === 'failed') last = step;
  }
  // The app's own limits are shorter, so these only end a check that nothing else will.
  const quiet = Date.now() - lastStepAt;
  if (last) break;
  if (!isAlive(pid)) last = { step: 'failed', error: 'the app exited before finishing' };
  else if (steps.length === 0 && quiet > 3 * 60 * 1000) last = { step: 'failed', error: 'the app reported nothing within 3 minutes' };
  else if (quiet > 12 * 60 * 1000) last = { step: 'failed', error: 'no further result from the app within 12 minutes' };
}

const summary = steps.filter((step) => step.step !== 'failed').map((step) => JSON.stringify(step)).join('\n');
const problem = last.step === 'done' ? engineProblem(steps) : `${last.error ?? ''} ${last.stack ?? ''}`;
const passed = problem === null && crashes().length === 0;
if (passed) {
  notice('engine in the app', summary);
} else {
  fail('engine in the app', problem ?? 'The app produced a crash report.');
  if (summary) notice('engine in the app, as far as it got', summary);
  explain(pid);
}
quietly(() => simctl('terminate', values.simulator, bundleId));
process.exit(passed ? 0 : 1);
