import { EventEmitter } from 'node:events';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { spawnPluginCommand } from './command-router.mjs';

const failure = (code, message) => Object.assign(new Error(message), { code });
const unsupported = detail => { throw failure('ERR_OHOS_PROCESS_OPTION', `${detail} 在 App 内命令后端不可用；可连接电脑执行`); };
const validText = (value, label) => {
  if (typeof value !== 'string' || value.includes('\0')) throw new TypeError(`${label} must be a NUL-free string`);
  return value;
};

export class ChildProcess extends EventEmitter {
  pid = undefined;
  stdin = null;
  stdout = null;
  stderr = null;
  stdio = [null, null, null];
  exitCode = null;
  signalCode = null;
  killed = false;
  connected = false;
  _job;
  _closed = false;
  spawn() { unsupported('ChildProcess.prototype.spawn 的原生内部参数'); }
  kill(signal = 'SIGTERM') {
    if (!['SIGTERM', 'SIGKILL'].includes(signal)) unsupported(`signal ${signal}`);
    if (this._closed || this._closing || !this._job) return false;
    if (!this.killed) { this._job.terminate(signal); this.killed = true; }
    return true;
  }
  ref() { unsupported('ref'); }
  unref() { unsupported('unref'); }
  send() { unsupported('IPC'); }
  disconnect() { unsupported('IPC'); }
}

export function createChildProcessFacade(spawnJob) {
  function spawn(file, args = [], options = {}) {
    if (!Array.isArray(args)) { options = args ?? {}; args = []; }
    validText(file, 'file');
    if (!file) throw new TypeError('file must not be empty');
    args = args.map(value => validText(value, 'argument'));
    if (!options || typeof options !== 'object') throw new TypeError('options must be an object');
    if (options.detached || options.uid !== undefined || options.gid !== undefined
      || options.serialization !== undefined || options.argv0 !== undefined) unsupported('detached/uid/gid/IPC/argv0');
    if (options.shell) unsupported('spawn shell 选项；请使用 exec 或明确 sh -c');
    if (options.timeout !== undefined && (!Number.isFinite(options.timeout) || options.timeout < 0 || options.timeout > 2147483647)) throw new RangeError('timeout is outside timer range');
    if (options.killSignal !== undefined && !['SIGTERM', 'SIGKILL'].includes(options.killSignal)) unsupported('killSignal');
    const modes = options.stdio === undefined || options.stdio === 'pipe' ? ['pipe', 'pipe', 'pipe']
      : options.stdio === 'ignore' ? ['ignore', 'ignore', 'ignore']
        : options.stdio === 'inherit' ? ['inherit', 'inherit', 'inherit'] : options.stdio;
    if (!Array.isArray(modes) || modes.length > 3) unsupported('stdio descriptors/IPC');
    const io = [0, 1, 2].map(i => modes[i] ?? 'pipe');
    if (io.some(x => !['pipe', 'ignore', 'inherit'].includes(x)) || io[0] === 'inherit') unsupported('继承stdin或外部stdio句柄');
    const child = new ChildProcess();
    child.spawnfile = file; child.spawnargs = [file, ...args];
    const spec = { argv: child.spawnargs, cwd: options.cwd instanceof URL ? fileURLToPath(options.cwd) : options.cwd ?? process.cwd(),
      env: options.env, signal: options.signal, graceMs: 1000,
      stdio: { stdin: io[0], stdout: io[1] === 'ignore' ? { maxBytes: 0 } : io[1],
        stderr: io[2] === 'ignore' ? { maxBytes: 0 } : io[2] } };
    let job, timer, emittedError = false;
    const report = error => { if (!emittedError) { emittedError = true; child.emit('error', error); } };
    const closed = async outcome => {
      if (child._closing) return;
      child._closing = true; clearTimeout(timer);
      child.exitCode = outcome?.exitCode ?? null; child.signalCode = outcome?.signal ?? null;
      if (outcome) child.emit('exit', child.exitCode, child.signalCode);
      await Promise.all([child.stdout, child.stderr].filter(Boolean).map(stream => {
        if (stream.readableEnded || stream.destroyed) return;
        return new Promise(resolve => {
          const end = () => { stream.off('end', end); stream.off('close', end); resolve(); };
          stream.once('end', end); stream.once('close', end);
          if (stream.listenerCount('readable') === 0) stream.resume();
        });
      }));
      child._closed = true;
      child.emit('close', child.exitCode, child.signalCode);
    };
    try {
      if (options.signal?.aborted) throw failure('ABORT_ERR', 'The command was aborted before spawn');
      job = spawnJob(spec);
      child._job = job;
      for (const key of ['stdin', 'stdout', 'stderr']) child[key] = job[key] ?? null;
      child.stdio = [child.stdin, child.stdout, child.stderr];
      Promise.resolve(job.started).then(() => { if (!child._closed) child.emit('spawn'); }, error => {
        if (!child.killed || error.code !== 'ERR_OHOS_NOT_STARTED') report(error);
      });
      job.done.then(closed, error => { report(error); return closed(); });
      if (options.timeout) timer = setTimeout(() => child.kill(options.killSignal ?? 'SIGTERM'), options.timeout);
    } catch (error) {
      queueMicrotask(() => { report(error); closed(); });
    }
    return child;
  }

  function execFile(file, args = [], options = {}, callback) {
    if (typeof args === 'function') { callback = args; args = []; options = {}; }
    else if (!Array.isArray(args)) { callback = typeof options === 'function' ? options : callback; options = args ?? {}; args = []; }
    else if (typeof options === 'function') { callback = options; options = {}; }
    const max = options.maxBuffer ?? 1024 * 1024;
    if (typeof max !== 'number' || max < 0 || Number.isNaN(max)) throw new RangeError('maxBuffer must be nonnegative');
    const encoding = options.encoding ?? 'utf8';
    if (encoding !== 'buffer' && !Buffer.isEncoding(encoding)) throw new TypeError('unknown encoding');
    const child = spawn(file, args, { ...options, stdio: 'pipe' });
    const buffers = { stdout: [], stderr: [] }, sizes = { stdout: 0, stderr: 0 };
    let failure;
    child.on('error', error => { failure ??= error; });
    for (const label of ['stdout', 'stderr']) child[label]?.on('data', chunk => {
      if (failure?.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER') return;
      const bytes = Buffer.from(chunk), remaining = Math.max(0, max - sizes[label]);
      if (bytes.length > remaining) {
        if (remaining) buffers[label].push(bytes.subarray(0, remaining));
        failure = Object.assign(new RangeError(`${label} maxBuffer length exceeded`), { code: 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER' });
        child.kill();
      } else buffers[label].push(bytes);
      sizes[label] += bytes.length;
    });
    child.once('close', (code, signal) => {
      const decode = label => { const bytes = Buffer.concat(buffers[label]); return encoding === 'buffer' ? bytes : bytes.toString(encoding); };
      const stdout = decode('stdout'), stderr = decode('stderr');
      if (!failure && (code !== 0 || signal)) failure = Object.assign(new Error(`Command failed: ${file}`), { code, signal, killed: child.killed, cmd: [file, ...args].join(' ') });
      callback?.(failure ?? null, stdout, stderr);
    });
    child.stdin?.end();
    return child;
  }
  execFile[promisify.custom] = (file, args, options) => {
    let child;
    const promise = new Promise((resolve, reject) => { child = execFile(file, args, options, (error, stdout, stderr) => {
      if (error) reject(Object.assign(error, { stdout, stderr })); else resolve({ stdout, stderr });
    }); });
    promise.child = child; return promise;
  };
  function exec(command, options = {}, callback) {
    if (typeof options === 'function') { callback = options; options = {}; }
    validText(command, 'command');
    return execFile(typeof options.shell === 'string' ? options.shell : 'sh', ['-c', command], { ...options, shell: false }, callback);
  }
  exec[promisify.custom] = (command, options) => {
    let child;
    const promise = new Promise((resolve, reject) => { child = exec(command, options, (error, stdout, stderr) => {
      if (error) reject(Object.assign(error, { stdout, stderr })); else resolve({ stdout, stderr });
    }); });
    promise.child = child; return promise;
  };
  const sync = () => { throw failure('ERR_OHOS_SYNC_PROCESS_UNAVAILABLE', 'App 内命令仅支持异步执行；请改用 spawn/execFile 或连接电脑'); };
  const fork = () => unsupported('Node fork IPC');
  return Object.freeze({ spawn, execFile, exec, spawnSync: sync, execFileSync: sync, execSync: sync, fork, ChildProcess });
}
const facade = createChildProcessFacade(spawnPluginCommand);
export const { spawn, execFile, exec, spawnSync, execFileSync, execSync, fork } = facade;
export default facade;
export { facade as 'module.exports' };
