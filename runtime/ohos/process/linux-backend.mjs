import { realpathSync } from 'node:fs';
import { constants } from 'node:os';
import { basename, relative, resolve } from 'node:path';
import { PassThrough } from 'node:stream';
import { finished } from 'node:stream/promises';
import { SubprocessExecutableNotFoundError } from '@deepseek-ai/dsh-subprocess';
import { OutputCollector } from '@deepseek-ai/dsh-subprocess-local/output';
import { distinctRoots, isInside } from './paths.mjs';
import { isLogicalWorkspacePath } from './files/process-authority.mjs';

// Agent shell names that run in the App's Linux guest; `linux` runs any guest program.
export const linuxCommands = Object.freeze(['gh', 'python3', 'python', 'pip', 'pip3', 'linux']);
const outputLimit = 64 * 1024 * 1024;
// These describe the host process, not the guest job.
const hostOnly = /^(?:PATH|HOME|PWD|OLDPWD|SHELL|SHLVL|TMPDIR|_|LD_\w+|NODE_\w+)$/;
// Alpine ships pip only as ensurepip's wheel; run it from there until pip is installed.
const pip = [
  'import glob, runpy, sys',
  'try:\n import pip',
  "except ImportError:\n sys.path[:0] = sorted(glob.glob(sys.base_prefix + '/lib/python3*/ensurepip/_bundled/pip-*.whl'))[-1:]",
  "sys.argv[0] = 'pip'",
  "runpy.run_module('pip', run_name='__main__', alter_sys=True)",
].join('\n');
const fail = (code, message, exitCode) => Object.assign(new Error(message), { code, exitCode });
const deferred = () => { const value = Promise.withResolvers(); value.promise.catch(() => {}); return value; };

function guestArgv([command, ...args]) {
  const name = basename(command);
  if (name === 'pip' || name === 'pip3') return ['python3', '-c', pip, ...args];
  if (/^python3?$/.test(name) && args[0] === '-m' && args[1] === 'pip') return ['python3', '-c', pip, ...args.slice(2)];
  return [command, ...args];
}

/**
 * The CommandRouter's Linux slot. The VM exports this router's own roots over
 * virtio-9p and each job mounts, at the same absolute paths, only the session
 * workspace and the private temporary root: writable for workspace-write,
 * read-only for read-only, as the guest kernel enforces. User-granted logical
 * roots are not exported.
 */
export class LinuxCommandBackend {
  capabilities = Object.freeze({ confinement: Object.freeze(['read-only', 'workspace-write']), stdin: 'stream', pty: false });
  commands = linuxCommands;
  live = new Set();
  closed = false;
  #control;
  #waitMs;
  #disposal;
  // One final-output drain per live handle; removed by that handle's settle.
  #outputDrains = new Set();
  // Jobs whose guest exit was never confirmed; dispose reports them.
  #failures = new Set();

  constructor({ control, workspaceRoots, temporaryRoot, onSpillFailure = () => {} }, { waitMs } = {}) {
    this.#control = control;
    this.#waitMs = waitMs;
    this.temporaryRoot = temporaryRoot;
    this.onSpillFailure = onSpillFailure;
    // TinyEMU has four 9P devices; a root beyond them is reported as not exported.
    control.exportWorkspaces(distinctRoots([temporaryRoot, ...workspaceRoots.filter(root => !isLogicalWorkspacePath(root))]).slice(0, 4));
  }

  prepare(argv, policy, signal) {
    signal?.throwIfAborted();
    if (isLogicalWorkspacePath(policy.workspaceRoot)) throw fail('ERR_WORKSPACE_SCOPE_UNSUPPORTED', 'Linux 命令尚未接入用户授权的目录；请在 App 工作区内运行');
    return [...argv];
  }

  async resolveExecutable(command, _env, signal) {
    signal?.throwIfAborted();
    // Whether the guest has it is known only by running it; whether Linux is on is known now.
    if (!this.#control.status().enabled) throw new SubprocessExecutableNotFoundError(`${command} 在 App 内 Linux 环境中运行；Linux 环境未开启`);
    return command;
  }

  #mounts(cwd, policy) {
    const workspaceRoot = policy?.workspaceRoot ?? cwd, readOnly = policy?.mode === 'read-only';
    if (isLogicalWorkspacePath(workspaceRoot) || isLogicalWorkspacePath(cwd)) {
      throw fail('ERR_WORKSPACE_SCOPE_UNSUPPORTED', 'Linux 命令尚未接入用户授权的目录；请在 App 工作区内运行', 126);
    }
    const mounts = distinctRoots([realpathSync(workspaceRoot), this.temporaryRoot]).map(target => {
      const exported = this.#control.exports.find(item => isInside(item.path, target));
      if (!exported) throw fail('ERR_OHOS_LINUX_WORKSPACE_UNAVAILABLE', `${target} 不在 App 交给 Linux 环境的工作区内`, 126);
      return { tag: exported.tag, source: relative(exported.path, target), target, readOnly };
    });
    if (!mounts.some(item => isInside(item.target, cwd))) {
      throw fail('ERR_OHOS_LINUX_WORKSPACE_UNAVAILABLE', `工作目录 ${cwd} 不在本次命令的工作区内`, 126);
    }
    return mounts;
  }

  #environment(env = {}) {
    const passed = Object.entries(env).filter(([key, value]) => value !== undefined && !hostOnly.test(key));
    return { PATH: '/workspace/.local/bin:/usr/local/bin:/usr/bin:/bin', HOME: '/workspace', TMPDIR: this.temporaryRoot,
      LANG: 'C.UTF-8', PIP_BREAK_SYSTEM_PACKAGES: '1', ...Object.fromEntries(passed) };
  }

  spawn(spec) {
    if (this.closed) throw fail('ERR_OHOS_PROCESS_CLOSED', 'App 内 Linux 命令服务已关闭');
    if (!spec.argv?.length || spec.argv.some(value => typeof value !== 'string' || value.includes('\0'))) throw new TypeError('argv 必须是无 NUL 的字符串数组，且命令名非空');
    if (spec.stdio.control === 'pipe') throw fail('ERR_OHOS_STREAM_UNAVAILABLE', 'Linux 命令没有控制通道');
    spec.signal?.throwIfAborted();
    const admission = new AbortController(), started = deferred(), done = deferred();
    const input = spec.stdio.stdin === 'pipe' ? new PassThrough() : undefined;
    const output = {}, collected = {};
    for (const label of ['stdout', 'stderr']) {
      const mode = spec.stdio[label];
      if (mode === 'pipe') output[label] = new PassThrough();
      else if (mode !== 'inherit') collected[label] = new OutputCollector(mode.maxBytes, label, mode.spill && {
        maxBytes: mode.spill.maxBytes, dir: this.temporaryRoot, onFailure: this.onSpillFailure });
    }
    let job, stopSignal, settled = false;
    const drainOutput = () => {
      // Final disposal abandons this adapter's output. Detach caller-owned
      // sinks without closing them, then consume both our pipes and the raw
      // guest streams (which may already have been unpiped by a closed sink).
      for (const stream of Object.values(output)) { stream.unpipe(); stream.resume(); }
      if (job) for (const label of ['stdout', 'stderr']) { job[label].unpipe(); job[label].resume(); }
    };
    const settle = (outcome, error) => {
      if (settled) return;
      settled = true;
      spec.signal?.removeEventListener('abort', handle.terminate);
      input?.destroy();
      try { for (const collector of Object.values(collected)) collector.seal(); } catch (cause) { error ??= cause; }
      for (const stream of Object.values(output)) stream.end();
      started.reject(Object.assign(new Error('任务在启动前已结束'), { code: 'ERR_OHOS_NOT_STARTED' }));
      this.live.delete(handle);
      this.#outputDrains.delete(drainOutput);
      if (error) { this.#failures.add(error); done.reject(error); } else done.resolve(outcome);
    };
    const handle = {
      stdin: input, stdout: output.stdout, stderr: output.stderr, control: undefined, collected,
      started: started.promise, done: done.promise,
      terminate: signal => {
        if (settled || stopSignal) return;
        stopSignal = signal === 'SIGKILL' ? 'SIGKILL' : 'SIGTERM';
        if (job) job.terminate(stopSignal); else admission.abort();
      },
      // An unconfirmed guest exit rejects here; it is never reported as exited.
      waitForExit: async signal => {
        if (settled) { await done.promise; return true; }
        if (signal?.aborted) return false;
        const interrupted = Promise.withResolvers(), abort = () => interrupted.resolve(false);
        const exited = done.promise.then(() => true);
        exited.catch(() => {});
        signal?.addEventListener('abort', abort, { once: true });
        try { return await Promise.race([exited, interrupted.promise]); }
        finally { signal?.removeEventListener('abort', abort); }
      },
    };
    this.live.add(handle);
    this.#outputDrains.add(drainOutput);
    spec.signal?.addEventListener('abort', handle.terminate, { once: true });
    (async () => {
      try {
        const cwd = realpathSync(resolve(spec.cwd));
        job = await this.#control.spawnRouted({ argv: guestArgv(spec.argv), cwd, env: this.#environment(spec.env),
          mounts: this.#mounts(cwd, spec.policy), graceMs: spec.graceMs,
          stdio: { stdin: input ? 'pipe' : spec.stdio.stdin, stdout: 'pipe', stderr: 'pipe' } },
        { signal: admission.signal, label: basename(spec.argv[0]), waitMs: this.#waitMs });
      } catch (error) {
        if (stopSignal) settle({ exitCode: null, signal: stopSignal });
        else if (error.code === 'ABORT_ERR' || error.name === 'AbortError') settle({ exitCode: null, signal: 'SIGTERM' });
        else {
          // Linux is off, still installing, busy or cannot see this directory.
          const message = Buffer.from(`${error.code ?? 'ERR_OHOS_LINUX_COMMAND'}: ${error.message}\n`);
          if (collected.stderr) collected.stderr.push(message); else (output.stderr ?? process.stderr).write(message);
          settle({ exitCode: error.exitCode ?? 126, signal: null });
        }
        return;
      }
      if (stopSignal) job.terminate(stopSignal);
      job.started.then(started.resolve, () => {});
      if (input) input.pipe(job.stdin);
      const drained = ['stdout', 'stderr'].map(label => {
        if (collected[label]) job[label].on('data', bytes => collected[label].push(bytes));
        else job[label].pipe(output[label] ?? process[label], { end: false });
        const drain = finished(job[label]);
        drain.catch(() => {});
        return drain;
      });
      // dispose may have run while spawnRouted was still returning this job.
      if (this.closed) drainOutput();
      try {
        const outcome = await job.done;
        await Promise.allSettled(drained);
        settle(outcome.cancelled ? { exitCode: null, signal: stopSignal ?? 'SIGKILL' } : { exitCode: outcome.exitCode, signal: outcome.signal });
      } catch (error) { settle(undefined, error); }
    })();
    return handle;
  }

  /** One just-bash statement: buffered output, like the virtual node command. */
  async forward({ argv, cwd, env, stdin, policy, signal }) {
    const output = { stdout: [], stderr: [] };
    let bytes = 0, overflow = false, job, outcome;
    try {
      job = this.spawn({ argv, cwd, env, policy, signal, graceMs: 10000, stdio: { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' } });
    } catch (error) {
      return { stdout: Buffer.alloc(0), stderr: Buffer.from(`${error.code ?? 'ERR_OHOS_LINUX_COMMAND'}: ${error.message}\n`), exitCode: 126 };
    }
    for (const label of ['stdout', 'stderr']) job[label].on('data', chunk => {
      bytes += chunk.length;
      if (bytes <= outputLimit) output[label].push(chunk);
      else if (!overflow) { overflow = true; job.terminate(); }
    });
    job.stdin.end(stdin);
    try { outcome = await job.done; }
    catch (error) {
      output.stderr.push(Buffer.from(`${error.code ?? 'ERR_OHOS_LINUX_UNKNOWN'}: ${error.message}\n`));
      outcome = { exitCode: 1 };
    }
    if (overflow) output.stderr.push(Buffer.from('ERR_OHOS_LINUX_OUTPUT_LIMIT: Linux 命令输出超过 64 MiB\n'));
    // A signalled command reports 128+N to the shell, as a POSIX shell would.
    const exitCode = overflow ? 1 : outcome.exitCode ?? 128 + (constants.signals[outcome.signal] ?? constants.signals.SIGKILL);
    return { stdout: Buffer.concat(output.stdout), stderr: Buffer.concat(output.stderr), exitCode };
  }

  dispose() {
    if (this.#disposal) return this.#disposal;
    this.closed = true;
    const jobs = [...this.live];
    // Publish before unpipe can synchronously reenter from a caller's sink.
    this.#disposal = Promise.allSettled(jobs.map(job => job.done)).then(() => {
      const errors = [...this.#failures];
      if (errors.length === 1) throw errors[0];
      if (errors.length) throw new AggregateError(errors, 'Linux 命令资源未全部确认退出');
    });
    for (const job of jobs) job.terminate();
    for (const drain of this.#outputDrains) drain();
    return this.#disposal;
  }
}

export const createLinuxCommandBackend = options => new LinuxCommandBackend(options);
