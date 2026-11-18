// Runs NativeToolsTests in the app's own process on the Simulator, then puts what each tool answered
// through the same checks the engine applies to it. The permissions are granted up front, since
// nobody is there to answer a prompt; only the app's own sheet gets tapped, by the test.
//
//   node tools-check.mjs --simulator <udid> --app <Runner.app> --work <new dir>
import { checkSiriRows } from './siri-results.mjs';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, openSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { actionFor as browserAction } from '../../../runtime/ios/browser/actions.mjs';
import { actionFor as systemAction } from '../../../runtime/ios/system/actions.mjs';
import { resultFor } from '../../../runtime/ios/system/results.mjs';

const { values } = parseArgs({ options: { simulator: { type: 'string' }, app: { type: 'string' }, work: { type: 'string' } } });
for (const key of ['simulator', 'app', 'work']) if (!values[key]) throw new Error(`--${key} required`);
const work = resolve(values.work);
mkdirSync(work, { recursive: true });
const bundleId = 'io.github.ccch1mneyyy.dshgo';
const clean = (text) => String(text).replace(/%/g, '%25').replace(/\r?\n/g, '%0A');
const notice = (title, text) => console.log(`::notice title=${title}::${clean(text).slice(0, 3500)}`);
const fail = (title, text) => console.log(`::error title=${title}::${clean(text).slice(0, 3500)}`);

const simctl = (...args) => {
  const done = spawnSync('xcrun', ['simctl', ...args], { encoding: 'utf8' });
  if (done.status !== 0) notice('native tools setup', `simctl ${args.join(' ')}: ${done.status} ${done.stderr}`);
};
simctl('install', values.simulator, resolve(values.app));
for (const service of ['reminders', 'contacts', 'location']) simctl('privacy', values.simulator, 'grant', service, bundleId);
simctl('location', values.simulator, 'set', '31.2304,121.4737');

const logFile = join(work, 'xcodebuild.log');
const log = openSync(logFile, 'a');
const runner = spawn('xcodebuild', ['test', '-workspace', 'ios/Runner.xcworkspace', '-scheme', 'Runner',
  '-destination', `id=${values.simulator}`, '-only-testing:RunnerTests/NativeToolsTests', '-parallel-testing-enabled', 'NO',
  '-resultBundlePath', join(work, 'result.xcresult'),
  'CODE_SIGNING_ALLOWED=NO'], {
  // xcodebuild passes these on to the test with the prefix removed. It only looks in its environment.
  cwd: 'app', stdio: ['ignore', log, log], env: { ...process.env, TEST_RUNNER_DSH_TOOLS_CHECK_DIR: work },
});
let timedOut = false;
const deadline = setTimeout(() => { timedOut = true; runner.kill('SIGTERM'); }, 20 * 60 * 1000);
const code = await new Promise((done) => {
  runner.once('error', (error) => { notice('native tools setup', error.message); done(-1); });
  runner.once('exit', (exit, signal) => done(exit ?? signal));
});
clearTimeout(deadline);

const rowsFile = join(work, 'rows.jsonl');
const rows = existsSync(rowsFile) ? readFileSync(rowsFile, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line)) : [];
const problems = checkSiriRows(rows);
const shareRows = rows.filter((row) => row.group === 'share');
const files = shareRows.filter((row) => row.name === 'file-collection');
const total = shareRows.filter((row) => row.name === 'total-byte-limit');
if (shareRows.length !== 2 || files.length !== 1 || files[0].files !== 9
  || files[0].uniqueNames !== 9 || JSON.stringify(files[0].skipped) !== '["too_large","too_many"]'
  || total.length !== 1 || total[0].files !== 2 || total[0].bytes !== 400 * 1024 * 1024
  || JSON.stringify(total[0].skipped) !== '["too_large"]') {
  problems.push('share: missing or incorrect collection result');
}
const lines = [];
// A page read is mostly a list of elements, and what matters is whether it saw the page.
const brief = (row) => {
  const text = String(row.text);
  if (row.group === 'browser' && row.name === 'read' && !row.isError) {
    try {
      const page = JSON.parse(text.slice(text.indexOf('{')));
      return `${page.title} | ${page.elements.length} elements | ${String(page.text).replace(/\s+/g, ' ').slice(0, 60)}`;
    } catch { /* Shown as it came. */ }
  }
  return text.replace(/\s+/g, ' ').slice(0, row.isError ? 200 : 90);
};
for (const row of rows) {
  const wrong = row.timedOut || (row.expect === 'ok' && row.isError) || (row.expect === 'refused' && !row.isError);
  let contract = '';
  try {
    if (row.group === 'system') {
      const action = systemAction(row.name, row.args);
      if (!row.isError) resultFor(action, JSON.parse(row.text));
    } else if (row.group === 'browser') browserAction(row.name, row.args);
    else if (!['siri', 'share'].includes(row.group)) throw new Error(`unknown group ${row.group}`);
  } catch (error) {
    contract = ` CONTRACT: ${error.message}`;
    problems.push(`${row.group} ${row.name}: ${error.message}`);
  }
  if (wrong) problems.push(`${row.group} ${row.name}: ${row.timedOut ? 'ran out of time' : `expected ${row.expect}`}`);
  const answer = brief(row);
  const shown = JSON.stringify(row.args).slice(0, 60);
  lines.push(`${wrong ? 'WRONG ' : ''}${row.name} ${shown} ${row.ms}ms ${row.isError ? 'error' : 'ok'}${row.imageBytes ? ` image ${row.imageBytes}` : ''}: ${answer}${contract}`);
}
for (const group of ['system', 'browser', 'siri', 'share']) {
  const all = lines.filter((_, index) => rows[index].group === group).join('\n') || 'no calls recorded';
  // An annotation holds about 4 KB.
  for (let at = 0, part = 1; at < all.length; at += 3400, part++) notice(`${group} tools ${part}`, all.slice(at, at + 3400));
}

const logged = existsSync(logFile) ? readFileSync(logFile, 'utf8').split('\n') : [];
const failures = [...new Set(logged.filter((line) => /error:|BUILD FAILED|TEST FAILED|TEST EXECUTE FAILED/.test(line)))]
  .map((line) => line.slice(0, 400)).slice(0, 25);
// A failed assertion only reaches the log as a summary line. Each one, with its line, is in the
// result bundle's tree of tests.
const tree = spawnSync('xcrun', ['xcresulttool', 'get', 'test-results', 'tests', '--path', join(work, 'result.xcresult'), '--compact'],
  { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
const failedAssertions = (nodes = []) => nodes.flatMap((node) => [
  ...(node.nodeType === 'Failure Message' ? [String(node.name).replace(/\s+/g, ' ').slice(0, 300)] : []),
  ...failedAssertions(node.children),
]);
try {
  problems.push(...new Set(failedAssertions(JSON.parse(tree.stdout).testNodes)));
} catch { /* A build that failed leaves no result to read; the log has why. */ }
if (timedOut) problems.push('xcodebuild ran out of time');
if (code !== 0) problems.push(`xcodebuild ended with ${code}`);
if (!rows.length) problems.push('no tool was called');
if (problems.length) {
  fail('native tools', [...problems, ...failures].join('\n'));
  if (!failures.length) notice('native tools build', logged.slice(-25).join('\n'));
  process.exit(1);
}
notice('native tools', `${rows.length} calls, all as expected`);
