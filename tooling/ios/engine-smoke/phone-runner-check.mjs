// Runs the phone runner on the Simulator and drives Settings with it, through the same RPC the app
// uses. A Simulator build has no signing and so no App Group; it's told where to publish instead.
// This exercises the authenticated helper and observation contract. The app's
// separate native approval/PiP admission is covered by its own tests; this
// fixture does not claim to reproduce a human granting a real phone task.
//
//   node phone-runner-check.mjs --simulator <udid> --work <new dir>
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, openSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: { simulator: { type: 'string' }, work: { type: 'string' } } });
const work = resolve(values.work);
mkdirSync(work, { recursive: true });
const clean = (text) => String(text).replace(/%/g, '%25').replace(/\r?\n/g, '%0A');
const notice = (title, text) => console.log(`::notice title=${title}::${clean(text).slice(0, 3500)}`);
const fail = (title, text) => console.log(`::error title=${title}::${clean(text).slice(0, 3500)}`);

const logFile = join(work, 'xcodebuild.log');
const log = openSync(logFile, 'a');
const runner = spawn('xcodebuild', ['test', '-project', 'ios/Runner.xcodeproj', '-scheme', 'PhoneRunner',
  '-destination', `id=${values.simulator}`, 'CODE_SIGNING_ALLOWED=NO'], {
  // xcodebuild passes these on to the test with the prefix removed. It only looks in its environment.
  cwd: 'app', stdio: ['ignore', log, log], env: { ...process.env, TEST_RUNNER_DSH_PHONE_RUNNER_DIR: work },
});
let exited = null;
runner.on('exit', (code, signal) => { exited = code ?? signal; });

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const endpointFile = join(work, 'endpoint.json');
const steps = [];

function finish(problem) {
  runner.kill('SIGTERM');
  // The runner's own diagnostics (numbers only): what kept a screen from holding still.
  const said = existsSync(logFile)
    ? readFileSync(logFile, 'utf8').split('\n').filter((line) => line.includes('[phone-runner]'))
    : [];
  if (said.length) notice('phone runner diagnostics', said.slice(-14).join('\n'));
  if (problem) {
    fail('phone runner', `${problem}\n${steps.join('\n')}`);
    const lines = existsSync(logFile) ? readFileSync(logFile, 'utf8').split('\n') : [];
    const errors = lines.filter((line) => /error:|Failed|failed to|BUILD FAILED|TEST FAILED/.test(line));
    notice('phone runner build', [...new Set(errors)].slice(0, 14).join('\n') || lines.slice(-25).join('\n'));
    process.exit(1);
  }
  notice('phone runner', steps.join('\n'));
  process.exit(0);
}

const deadline = Date.now() + 25 * 60 * 1000;
while (!existsSync(endpointFile)) {
  if (exited !== null) finish(`xcodebuild ended with ${exited} before the runner started`);
  if (Date.now() > deadline) finish('the runner never published its endpoint');
  await sleep(1000);
}
const endpoint = JSON.parse(readFileSync(endpointFile, 'utf8'));
const url = `http://127.0.0.1:${endpoint.port}/rpc`;
const started = Date.now();
steps.push(`up, ${endpoint.port}`);

async function rpc(method, params = {}, headers = { authorization: `Bearer ${endpoint.token}` }, metadata = {}) {
  const at = Date.now();
  const response = await fetch(url, {
    method: 'POST', headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify({ method, params, expiresAt: Date.now() + 110_000,
      controllerBundleID: 'io.github.ccch1mneyyy.dshgo', xctestDeniedBundleIDs: [], ...metadata }),
  });
  const body = await response.json();
  steps.push(`${method} ${JSON.stringify(params)} ${response.status} ${Date.now() - at}ms ${body.ok ? 'ok' : `error: ${body.error}`}`);
  return { status: response.status, ...body };
}

const must = (condition, problem) => { if (!condition) finish(problem); };
const idOf = (text, pattern) => {
  const line = text.split('\n').find((row) => pattern.test(row));
  return line ? Number(line.match(/^\[(\d+)\]/)?.[1]) : undefined;
};

try {
  // Who can call it.
  must((await rpc('screen', {}, {})).status === 401, 'answered with no token');
  must((await rpc('screen', {}, { authorization: 'Bearer wrong' })).status === 401, 'answered with a wrong token');
  must((await rpc('screen', {}, { authorization: `Bearer ${endpoint.token}`, origin: 'https://example.com' })).status === 401,
    'answered a web page');

  must((await rpc('key', { key: 'home' }, undefined, { expiresAt: Date.now() - 1 })).status === 410,
    'an expired queued action was not refused');

  // Reading and driving another app.
  const opened = await rpc('open', { app: 'com.apple.Preferences' });
  must(opened.ok, 'could not open Settings');
  await sleep(1500);
  let screen = await rpc('screen', { image: true });
  must(screen.ok && /屏幕 s\d+/.test(screen.text), 'no screen');
  must(typeof screen.image === 'string' && screen.image.length > 1000, 'no screenshot');
  notice('settings on screen', screen.text.slice(0, 1500));
  must(!(await rpc('tap_xy', { observation: 's0', x: 0, y: 0 })).ok, 'accepted an expired screenshot');
  must(!(await rpc('tap_xy', { observation: screen.screen, x: -1, y: 0 })).ok, 'accepted out-of-bounds screenshot coordinates');
  screen = await rpc('screen', { image: true });
  must(screen.ok, 'could not observe after rejected coordinates');
  const list = idOf(screen.text, /\] (列表|滚动区)(?: |$)/);
  must(list !== undefined, 'Settings exposes no scroll container in the element tree');
  const collected = await rpc('collect', { screen: screen.screen, list, max_pages: 1 });
  must(collected.ok && /General|通用/.test(collected.text), 'could not collect the selected Settings list');
  screen = await rpc('screen', { image: true });
  let general = idOf(screen.text, /General|通用/);
  must(general !== undefined, 'Settings has no General row in the tree');
  must(!(await rpc('tap', { screen: 's0', id: general })).ok, 'a stale screen number was accepted');
  screen = await rpc('screen', { image: true });
  must(screen.ok, 'could not observe after stale input refusal');
  general = idOf(screen.text, /General|通用/);
  must(general !== undefined, 'fresh Settings screen has no General row');
  const tapped = await rpc('tap', { screen: screen.screen, id: general });
  must(tapped.ok && /About|关于/.test(tapped.text), `tapping General didn't open it: ${tapped.text?.slice(0, 400)}`);

  const scrolled = await rpc('scroll', { screen: tapped.screen, direction: 'down' });
  must(scrolled.ok, 'could not scroll');
  const back = await rpc('key', { screen: scrolled.screen, key: 'back' });
  must(back.ok && /General|通用/.test(back.text), `back didn't return: ${back.text?.slice(0, 400)}`);

  // Something that takes no text says so, promptly, rather than claiming it worked.
  screen = back;
  const row = idOf(screen.text, /按钮 "/);
  must(row !== undefined, 'nothing to try typing into');
  const refused = await rpc('type', { screen: screen.screen, id: row, text: 'x' });
  must(!refused.ok, 'typing into a button claimed to work');
  screen = await rpc('screen');
  must(screen.ok, 'could not observe after rejected text target');
  must((await rpc('key', { screen: screen.screen, key: 'home' })).ok, 'home failed');

  // Typing, wherever a built-in app has a field on screen.
  let typed = null;
  for (const app of ['com.apple.MobileAddressBook', 'com.apple.mobilesafari', 'com.apple.Maps', 'com.apple.Preferences']) {
    const current = await rpc('open', { app });
    await sleep(2000);
    screen = await rpc('screen');
    const field = idOf(screen.text ?? '', /\] (搜索框|输入框)/);
    notice(`fields in ${app}`, (screen.text ?? current.error ?? '').split('\n').slice(0, 14).join('\n'));
    if (field === undefined) continue;
    typed = await rpc('type', { screen: screen.screen, id: field, text: 'wifi' });
    break;
  }
  must(typed !== null, 'no app had a text field on screen');
  must(typed.ok && /wifi/i.test(typed.text), `typing didn't reach the field: ${typed.error ?? typed.text?.slice(0, 400)}`);

  // Tools that have no real target here still have to answer.
  screen = await rpc('screen');
  must(screen.ok, 'could not observe before home');
  must((await rpc('key', { screen: screen.screen, key: 'home' })).ok, 'home failed');
  must((await rpc('apps')).ok, 'apps failed');
  must(!(await rpc('nonsense')).ok, 'an unknown tool succeeded');
  steps.push(`done in ${Date.now() - started} ms`);
  finish();
} catch (error) {
  finish(String(error?.stack ?? error));
}
