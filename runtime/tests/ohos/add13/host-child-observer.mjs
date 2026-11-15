// Private test plugin. All successful child processes only execute owned-child.mjs.
import cp, { spawn as spawnAlias, spawnSync as spawnSyncAlias, exec as execAlias,
  execSync as execSyncAlias, execFile as execFileAlias, execFileSync as execFileSyncAlias,
  fork as forkAlias, ChildProcess } from 'node:child_process';
import * as namespace from 'node:child_process';
import { createRequire } from 'node:module';
import { promisify } from 'node:util';
import { isMainThread, Worker } from 'node:worker_threads';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join, isAbsolute } from 'node:path';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';

export const name = 'add13-owned-child-observer';
export const inject = ['webServer', 'connection'];
const named = { spawn: spawnAlias, spawnSync: spawnSyncAlias, exec: execAlias, execSync: execSyncAlias,
  execFile: execFileAlias, execFileSync: execFileSyncAlias, fork: forkAlias };
const cjs = createRequire(import.meta.url)('node:child_process');
const builtin = process.getBuiltinModule('child_process');
const err = error => ({ name: error?.name, code: error?.code, message: String(error?.message ?? error), stack: error?.stack });
const bytes = value => {
  const raw = Buffer.isBuffer(value) ? value : Buffer.from(value ?? '');
  return { bytes: raw.length, sha256: createHash('sha256').update(raw).digest('hex'), base64: raw.toString('base64'), text: raw.toString('utf8') };
};
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";

function waitChild(child) {
  return new Promise(resolve => {
    const stdout = [], stderr = [], errors = [], requested = [];
    child.stdout?.on('data', data => stdout.push(Buffer.from(data)));
    child.stderr?.on('data', data => stderr.push(Buffer.from(data)));
    child.on('error', error => errors.push(err(error)));
    const timer = setTimeout(() => {
      requested.push({ signal: 'SIGKILL', accepted: child.kill('SIGKILL') });
    }, 5000);
    child.once('close', (code, signal) => {
      clearTimeout(timer);
      resolve({ pid: child.pid, code, signal, errors, requested, stdout: bytes(Buffer.concat(stdout)), stderr: bytes(Buffer.concat(stderr)) });
    });
  });
}

export async function apply(ctx, config) {
  if (![config.directory, config.child, config.output, config.ordinaryWorker].every(isAbsolute)) throw new TypeError('Private child fixture paths must be absolute');
  await mkdir(config.directory, { recursive: false });
  const report = { scope: 'Actual product-preloaded main Host, legitimate owned child invocations; Linux process ABI with an explicit OH platform simulation',
    platform: process.platform, node: process.version, execArgv: process.execArgv, mainThread: isMainThread,
    noWasm: typeof WebAssembly === 'undefined', aliases: {}, cases: [] };
  for (const key of Object.keys(named)) report.aliases[key] = {
    namedEqualsNamespace: named[key] === namespace[key], namedEqualsDefault: named[key] === cp[key],
    namedEqualsCommonJS: named[key] === cjs[key], namedEqualsGetBuiltin: named[key] === builtin[key],
  };
  const environment = { PATH: process.env.PATH, LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8', HOME: config.directory, TMPDIR: config.directory };
  const options = { cwd: config.directory, env: environment, windowsHide: true };
  const childArgs = id => ['--jitless', config.child, id, config.directory];
  const command = id => [process.execPath, ...childArgs(id)].map(quote).join(' ');
  const asyncCases = new Set(['spawn', 'exec', 'execFile', 'fork', 'prototype.spawn', 'cjs.spawn', 'getBuiltin.spawn']);
  const names = ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork',
    'prototype.spawn', 'cjs.spawn', 'getBuiltin.spawn', 'promisify.exec', 'promisify.execFile'];
  let started;
  const run = () => started ??= (async () => {
    for (const id of names) {
      const row = { id, startedUtc: new Date().toISOString(), creationReturned: false };
      report.cases.push(row);
      try {
        let value;
        switch (id) {
          case 'spawn': value = spawnAlias(process.execPath, childArgs(id), { ...options, stdio: ['ignore', 'pipe', 'pipe'] }); break;
          case 'spawnSync': value = spawnSyncAlias(process.execPath, childArgs(id), { ...options, timeout: 5000, encoding: 'buffer' }); break;
          case 'exec': value = execAlias(command(id), { ...options, shell: '/bin/sh', timeout: 5000 }); break;
          case 'execSync': value = execSyncAlias(command(id), { ...options, shell: '/bin/sh', timeout: 5000, stdio: ['ignore', 'pipe', 'pipe'] }); break;
          case 'execFile': value = execFileAlias(process.execPath, childArgs(id), { ...options, timeout: 5000 }); break;
          case 'execFileSync': value = execFileSyncAlias(process.execPath, childArgs(id), { ...options, timeout: 5000, stdio: ['ignore', 'pipe', 'pipe'] }); break;
          case 'fork': value = forkAlias(config.child, [id, config.directory], { ...options, execPath: process.execPath, execArgv: ['--jitless'], silent: true }); break;
          case 'prototype.spawn': {
            value = new ChildProcess();
            value.spawn({ file: process.execPath, args: [process.execPath, ...childArgs(id)], cwd: config.directory,
              envPairs: Object.entries(environment).map(([key, val]) => `${key}=${val}`), stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
            break;
          }
          case 'cjs.spawn': value = cjs.spawn(process.execPath, childArgs(id), { ...options, stdio: ['ignore', 'pipe', 'pipe'] }); break;
          case 'getBuiltin.spawn': value = builtin.spawn(process.execPath, childArgs(id), { ...options, stdio: ['ignore', 'pipe', 'pipe'] }); break;
          case 'promisify.exec': value = await promisify(execAlias)(command(id), { ...options, shell: '/bin/sh', timeout: 5000 }); break;
          case 'promisify.execFile': value = await promisify(execFileAlias)(process.execPath, childArgs(id), { ...options, timeout: 5000 }); break;
          default: throw new Error('Unknown owned case');
        }
        row.creationReturned = true;
        if (asyncCases.has(id)) row.result = await waitChild(value);
        else if (id === 'spawnSync') row.result = { pid: value.pid, code: value.status, signal: value.signal,
          error: value.error && err(value.error), stdout: bytes(value.stdout), stderr: bytes(value.stderr) };
        else if (id.startsWith('promisify.')) row.result = { stdout: bytes(value.stdout), stderr: bytes(value.stderr) };
        else row.result = { stdout: bytes(value) };
      } catch (error) { row.error = err(error); }
      try {
        const raw = await readFile(join(config.directory, `${id}.json`));
        row.marker = { ...bytes(raw), parsed: JSON.parse(raw.toString('utf8')) };
      } catch (error) {
        if (error.code !== 'ENOENT') row.markerError = err(error);
        row.marker = null;
      }
      row.endedUtc = new Date().toISOString();
      await writeFile(config.output, JSON.stringify(report, null, 2) + '\n');
    }
    const worker = new Worker(pathToFileURL(config.ordinaryWorker), {
      workerData: { child: config.child, directory: config.directory }, stdout: true, stderr: true,
    });
    const stdout = [], stderr = [];
    worker.stdout.on('data', data => stdout.push(data)); worker.stderr.on('data', data => stderr.push(data));
    worker.on('message', message => { report.ordinaryWorker = message; });
    worker.on('error', error => { report.ordinaryWorkerError = err(error); });
    report.ordinaryWorkerExit = await new Promise(resolve => worker.once('exit', code => resolve({ code })));
    report.ordinaryWorkerStdout = bytes(Buffer.concat(stdout)); report.ordinaryWorkerStderr = bytes(Buffer.concat(stderr));
    await writeFile(config.output, JSON.stringify(report, null, 2) + '\n');
    return report;
  })();
  ctx.effect(() => ctx.webServer.register({ kind: 'exact', path: '/__add13_cp/run', handler: async (request, response) => {
    const rejection = ctx.connection.requestRejection(request);
    if (rejection !== undefined) { response.writeHead(rejection); response.end(); return; }
    if (request.method !== 'POST') { response.writeHead(405); response.end(); return; }
    const result = await run();
    const body = Buffer.from(JSON.stringify(result));
    response.writeHead(200, { 'content-type': 'application/json', 'content-length': body.length }); response.end(body);
  } }), 'add13.owned-child-observer');
  await writeFile(config.output, JSON.stringify(report, null, 2) + '\n');
}
