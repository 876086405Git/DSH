import { parentPort, workerData, isMainThread } from 'node:worker_threads';
import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
const errorRecord = error => ({ name: error?.name, code: error?.code, message: error?.message });
const report = { platform: process.platform, mainThread: isMainThread, noWasm: typeof WebAssembly === 'undefined',
  execArgv: process.execArgv, inheritedPreload: true, specialNodeScriptProtocol: false };
try {
  const child = spawn(process.execPath, ['--jitless', workerData.child, 'ordinary-worker', workerData.directory], {
    cwd: workerData.directory, env: { PATH: process.env.PATH, LANG: 'C.UTF-8', HOME: workerData.directory, TMPDIR: workerData.directory },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const stdout = [], stderr = [];
  child.stdout.on('data', data => stdout.push(data)); child.stderr.on('data', data => stderr.push(data));
  child.on('error', error => { report.childError = errorRecord(error); });
  const timer = setTimeout(() => { report.killRequested = child.kill('SIGKILL'); }, 5000);
  report.childExit = await new Promise(resolve => child.once('close', (code, signal) => resolve({ code, signal, pid: child.pid })));
  clearTimeout(timer);
  report.stdout = Buffer.concat(stdout).toString('utf8'); report.stderr = Buffer.concat(stderr).toString('utf8');
} catch (error) { report.error = errorRecord(error); }
try { report.marker = JSON.parse(await readFile(join(workerData.directory, 'ordinary-worker.json'), 'utf8')); }
catch (error) { if (error.code !== 'ENOENT') report.markerError = errorRecord(error); report.marker = null; }
parentPort.postMessage(report);
