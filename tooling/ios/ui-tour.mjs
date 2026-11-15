// Runs app/test/ios_tour/tour_main.dart on the Simulator, twice: once for a screenshot at each stop
// the app asks for, then once in real time for a video, which would slow the screenshots down. A stop
// that fails is reported and the tour goes on.
//
//   node ui-tour.mjs --simulator <udid> --app <Runner.app> --out <new dir> --video <new dir>
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { parseArgs } from 'node:util';

const names = ['simulator', 'app', 'out', 'video'];
const { values } = parseArgs({ options: Object.fromEntries(names.map(name => [name, { type: 'string' }])) });
for (const key of names) if (!values[key]) throw new Error(`--${key} required`);

const bundleId = 'io.github.ccch1mneyyy.dshgo';
const out = resolve(values.out);
const videoDirectory = resolve(values.video);
mkdirSync(out, { recursive: true });
mkdirSync(videoDirectory, { recursive: true });
const simctl = (args, env) => execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8', env: { ...process.env, ...env } });
const notice = (kind, title, text) => console.log(`::${kind} title=${title}::${String(text).replace(/%/g, '%25').replace(/\s+/g, ' ').slice(0, 900)}`);

// The same clean status bar on every shot.
simctl(['status_bar', values.simulator, 'override', '--time', '9:41', '--batteryState', 'charged', '--batteryLevel', '100', '--cellularBars', '4', '--wifiBars', '3']);
simctl(['install', values.simulator, values.app]);
const tmp = join(simctl(['get_app_container', values.simulator, bundleId, 'data']).trim(), 'tmp');
mkdirSync(tmp, { recursive: true });
const log = join(tmp, 'dsh-ui-tour.log');

let errors = 0;

async function pass(mode, minutes) {
  rmSync(log, { force: true });
  // A stale answer would let the app run on without waiting for its screenshot.
  for (const name of readdirSync(tmp)) if (name.startsWith('dsh-ui-tour-ack-')) rmSync(join(tmp, name));
  writeFileSync(join(tmp, 'dsh-ui-tour-mode'), mode);
  simctl(['launch', '--terminate-running-process', values.simulator, bundleId]);
  let seen = 0;
  let finished = false;
  const deadline = Date.now() + minutes * 60 * 1000;
  while (Date.now() < deadline && !finished) {
    const lines = existsSync(log) ? readFileSync(log, 'utf8').split('\n').filter(Boolean) : [];
    for (const line of lines.slice(seen)) {
      seen++;
      const [kind, ...rest] = line.split(' ');
      if (kind === 'SHOT') {
        const [number, name] = rest;
        const started = Date.now();
        simctl(['io', values.simulator, 'screenshot', join(out, `${number.padStart(2, '0')}-${name}.png`)]);
        writeFileSync(join(tmp, `dsh-ui-tour-ack-${number}`), '');
        console.log(`shot ${number} ${name} in ${Date.now() - started} ms`);
      } else if (kind === 'DONE') {
        finished = true;
      } else if (errors++ < 8) {
        notice('warning', 'ui tour', line);
      }
    }
    await delay(100);
  }
  simctl(['terminate', values.simulator, bundleId]);
  notice(finished ? 'notice' : 'error', `ui tour (${mode})`, `${seen} lines, ${errors} errors so far${finished ? '' : ', did not finish'}`);
  return finished;
}

const shots = await pass('shots', 25);
const video = spawn('xcrun', ['simctl', 'io', values.simulator, 'recordVideo', '--codec=h264', '--force', join(videoDirectory, 'tour.mp4')], { stdio: 'ignore' });
await delay(1500);
await pass('video', 5);
await delay(500);
video.kill('SIGINT');
await new Promise(done => video.once('close', done));
process.exitCode = shots ? 0 : 1;
