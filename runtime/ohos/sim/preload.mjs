// Test-only constraints. This is instrumentation, not an OS security boundary.
import cp from 'node:child_process';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { isAbsolute } from 'node:path';
import { syncBuiltinESMExports } from 'node:module';

import './marker.mjs';

const allowed = JSON.parse(process.env.DSH_GO_OHOS_SIM_ADDONS || '[]');
if (!Array.isArray(allowed) || allowed.some((path) => typeof path !== 'string' || !isAbsolute(path))) {
  throw new TypeError('DSH_GO_OHOS_SIM_ADDONS must be a JSON array of absolute addon paths');
}
const addons = new Set(allowed.map((path) => fs.realpathSync(path)));
const write = fs.writeSync;
function diagnosticStack(error) {
  return error.stack.split('\n').map((line, index) => {
    if (index === 0) return line;
    // V8 embeds data-URL source and eval origins in frame names.
    const frame = /\(?((?:file:\/\/\/|node:|\/)[^()\r\n]*?):(\d+):(\d+)\)?$/u.exec(line);
    if (!frame || line.includes('data:') || line.includes('eval at')) return '    at <dynamic source>';
    const source = frame[1].startsWith('file:') ? new URL(frame[1]).pathname : frame[1];
    return `    at ${source}:${frame[2]}:${frame[3]}`;
  }).join('\n');
}
function failure(category, operation, code) {
  const error = Object.assign(new Error(`OHOS simulation denied ${operation}`), { code });
  error.stack = diagnosticStack(error);
  // Never record command arguments, request URLs, environment or headers.
  write(2, `[ohos-sim] ${JSON.stringify({ category, operation, stack: error.stack })}\n`);
  return error;
}
for (const name of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork']) {
  cp[name] = function () { throw failure('spawn', `child_process.${name}`, 'ERR_OHOS_SIM_SPAWN'); };
}
cp.ChildProcess.prototype.spawn = function () {
  throw failure('spawn', 'ChildProcess.spawn', 'ERR_OHOS_SIM_SPAWN');
};
const dlopen = process.dlopen;
process.dlopen = function (module, filename, flags) {
  let path;
  try { path = fs.realpathSync(filename); } catch { /* Deny absent and non-whitelisted addons alike. */ }
  if (!addons.has(path)) throw failure('dlopen', 'process.dlopen', 'ERR_OHOS_SIM_DLOPEN');
  return Reflect.apply(dlopen, this, arguments);
};
fs.link = function (source, target, callback) {
  if (typeof callback !== 'function') throw new TypeError('link callback must be a function');
  const error = failure('link', 'fs.link', 'EACCES');
  process.nextTick(callback, error);
};
fs.linkSync = function () { throw failure('link', 'fs.linkSync', 'EACCES'); };
fsp.link = async function () { throw failure('link', 'fs.promises.link', 'EACCES'); };
if (process.env.DSH_GO_OHOS_SIM_PLATFORM === 'openharmony') {
  Object.defineProperty(process, 'platform', { value: 'openharmony' });
} else if (process.env.DSH_GO_OHOS_SIM_PLATFORM) {
  throw new TypeError('DSH_GO_OHOS_SIM_PLATFORM may only be openharmony or empty');
}
if (!Reflect.deleteProperty(globalThis, 'WebAssembly')) throw new Error('cannot disable WebAssembly');
syncBuiltinESMExports();
