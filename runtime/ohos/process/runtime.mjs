import { lstatSync, mkdtempSync, realpathSync, statSync } from 'node:fs';
import { lstat, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, isAbsolute, join, resolve } from 'node:path';
import { PassThrough } from 'node:stream';
import { Worker } from 'node:worker_threads';
import { randomUUID } from 'node:crypto';
import { OutputCollector } from '@deepseek-ai/dsh-subprocess-local/output';
import { scrubbedParentEnv, SubprocessExecutableNotFoundError } from '@deepseek-ai/dsh-subprocess';
import { MAX_TIMER_DELAY_MS } from '@deepseek-ai/dsh-timeout';
import { capabilities, subprocessCommands, unavailableMessage } from './commands.mjs';
import { distinctRoots, isInside } from './paths.mjs';
import { createOwnedGitServer } from './owned-server.mjs';
import { createLinuxForwardServer } from './linux-forward.mjs';
import { createNodeScriptWorker, formatNodeScriptError, nodeScriptAvailable } from './node-script.mjs';
import { borrowProcessGrantAuthority, isLogicalWorkspacePath, processGrantNativeDirectory,
  processWorkspaceGrant, quarantineProcessGrantRetirement } from './files/process-authority.mjs';

const confinedProgram = '/dsh-go/ohos/confined';
const validateArgv = argv => {
  if (!argv.length || !argv[0] || argv.some(value => typeof value !== 'string' || value.includes('\0'))) throw new TypeError('argv 必须是无 NUL 的字符串数组，且命令名非空');
};
const commandName = command => {
  const name = basename(command);
  if (!subprocessCommands.includes(name)) return;
  if (command === name || [`/dsh-go/ohos/bin/${name}`, `/bin/${name}`, `/usr/bin/${name}`].includes(command)) return name;
};

export class VirtualSubprocessRuntime {
  capabilities = Object.freeze({ ...capabilities,
    nodeStreamingStdin: nodeScriptAvailable(),
    commands: nodeScriptAvailable() ? capabilities.commands : Object.freeze(capabilities.commands.filter(name => name !== 'node')),
    nodeScripts: nodeScriptAvailable() ? 'worker-rebased' : 'none' });
  live = new Set();
  lanes = { search: { queue: [] }, execution: { queue: [] } };
  closed = false;
  prepared = new Map();
  #temporaryOwner;
  #disposePromise;
  #resourceFailures = new Set();
  #createOwnedGitServer;
  #selectExternal;
  #linux;
  #concurrent;

  constructor({ workspaceRoots, temporaryRoot, onSpillFailure = () => {} } = {}, internals = {}) {
    // Explicit trusted test seam; never read from Worker messages or DSH config.
    this.#createOwnedGitServer = internals.createOwnedGitServer ?? createOwnedGitServer;
    this.#selectExternal = internals.selectExternal;
    // The owner's Linux backend, looked up when a shell starts.
    this.#linux = internals.linux ?? (() => undefined);
    this.#concurrent = internals.concurrent === true;
    if (typeof this.#createOwnedGitServer !== 'function') throw new TypeError('Invalid owned-resource server factory');
    if (!Array.isArray(workspaceRoots) || workspaceRoots.length === 0) {
      throw new TypeError('workspaceRoots 必须由宿主显式配置为非空的绝对工作区目录数组');
    }
    const directory = (path, label) => {
      if (typeof path !== 'string' || !isAbsolute(path) || path.includes('\0')) {
        throw new TypeError(`${label} 必须是无 NUL 的绝对目录路径`);
      }
      const canonical = realpathSync(path);
      if (canonical === '/' || !statSync(canonical).isDirectory()) {
        throw new Error(`${label} 必须是实际目录，不能授权整个文件系统根`);
      }
      return canonical;
    };
    // 验证所有宿主输入后才分配自身资源；配置拒绝不能留下新 mkdtemp。
    this.workspaceRoots = distinctRoots(workspaceRoots.map(root => isLogicalWorkspacePath(root)
      ? processWorkspaceGrant(root).mountPoint : directory(root, 'workspaceRoots')));
    if (temporaryRoot !== undefined) this.temporaryRoot = directory(temporaryRoot, 'temporaryRoot');
    else {
      this.temporaryRoot = mkdtempSync(join(tmpdir(), 'dsh-ohos-process-'));
      const identity = lstatSync(this.temporaryRoot, { bigint: true });
      this.#temporaryOwner = { path: this.temporaryRoot, dev: identity.dev, ino: identity.ino };
      this.temporaryRoot = realpathSync(this.temporaryRoot);
    }
    this.roots = distinctRoots([...this.workspaceRoots, this.temporaryRoot]);
    this.onSpillFailure = onSpillFailure;
  }

  prepare(argv, policy, signal) {
    if (this.closed) throw new Error('鸿蒙虚拟进程服务已关闭');
    signal?.throwIfAborted();
    validateArgv(argv);
    if (policy.mode !== 'read-only' && policy.mode !== 'workspace-write') throw new Error('非法的受限运行模式');
    const grant = isLogicalWorkspacePath(policy.workspaceRoot) ? processWorkspaceGrant(policy.workspaceRoot) : undefined;
    const workspaceRoot = grant?.mountPoint ?? realpathSync(policy.workspaceRoot);
    if (!grant && !this.roots.some(root => isInside(root, workspaceRoot))) throw Object.assign(new Error('EACCES: OHOS_SANDBOX_DENIED: 会话工作区未由宿主授权'), { code: 'EACCES' });
    const token = randomUUID();
    const cancel = () => this.prepared.delete(token);
    this.prepared.set(token, { argv: [...argv], policy: { ...policy, workspaceRoot }, grant, signal, cancel });
    signal?.addEventListener('abort', cancel, { once: true });
    return [confinedProgram, token];
  }

  async resolveExecutable(command, _env, signal) {
    signal?.throwIfAborted();
    if (!command || (!isAbsolute(command) && command.includes('/'))) throw new Error('必须使用虚拟命令名或绝对路径');
    const name = commandName(command);
    if (!name || (name === 'node' && !nodeScriptAvailable())) throw new SubprocessExecutableNotFoundError(unavailableMessage);
    return `/dsh-go/ohos/bin/${name}`;
  }

  async terminalEnvironment(signal) {
    signal?.throwIfAborted();
    return { platform: 'posix', defaultShell: '/dsh-go/ohos/bin/bash' };
  }

  async spawnTerminal() {
    throw Object.assign(new Error('鸿蒙本机没有 PTY，可以连接电脑执行'), { code: 'ERR_OHOS_PTY_UNAVAILABLE' });
  }

  spawn(spec) {
    if (this.closed) throw new Error('鸿蒙虚拟进程服务已关闭');
    if (!Number.isFinite(spec.graceMs) || spec.graceMs <= 0 || spec.graceMs > MAX_TIMER_DELAY_MS) throw new Error(`subprocess graceMs must be a positive finite number no greater than ${MAX_TIMER_DELAY_MS}`);
    if (spec.signal?.aborted) {
      let reason = 'aborted';
      try { reason = String(spec.signal.reason ?? reason); } catch {}
      throw new Error(`aborted before spawn: ${reason}`);
    }
    validateArgv(spec.argv);
    let argv = [...spec.argv];
    let policy, grant;
    if (argv[0] === confinedProgram) {
      const prepared = argv.length === 2 && this.prepared.get(argv[1]);
      if (!prepared) throw Object.assign(new Error('无效或已使用的鸿蒙执行票据'), { code: 'ERR_OHOS_INVALID_CONFINEMENT' });
      this.prepared.delete(argv[1]);
      prepared.signal?.removeEventListener('abort', prepared.cancel);
      argv = prepared.argv;
      policy = prepared.policy;
      grant = prepared.grant;
      validateArgv(argv);
    }
    const external = this.#selectExternal?.(argv, policy);
    if (external) {
      const routed = policy ? external.prepare(argv, policy, spec.signal) : argv;
      return external.spawn({ ...spec, argv: routed, ...(policy ? { policy } : {}) });
    }
    const lane = this.#concurrent ? { queue: [] } : this.lanes[commandName(argv[0]) === 'rg' ? 'search' : 'execution'];
    const state = { worker: undefined, resources: undefined, workspace: undefined, stopped: false, finishing: false,
      settled: false, outcome: undefined, failure: undefined, providerFailure: undefined, rangeFailure: undefined };
    const completion = Promise.withResolvers();
    const gone = Promise.withResolvers();
    const started = Promise.withResolvers();
    let didStart = false;
    started.promise.catch(() => {});
    // The original promises still reject to callers; attach internal observers
    // so a cleanup failure before a caller begins awaiting is never unhandled.
    completion.promise.catch(() => {});
    gone.promise.catch(() => {});
    const collected = {};
    const output = {};
    const input = spec.stdio.stdin === 'pipe' ? new PassThrough({ highWaterMark: 65536 }) : undefined;
    input?.on('error', () => {});
    for (const label of ['stdout', 'stderr']) {
      const mode = spec.stdio[label];
      if (mode === 'pipe') output[label] = new PassThrough();
      else if (mode !== 'inherit') collected[label] = new OutputCollector(mode.maxBytes, label, mode.spill && {
        maxBytes: mode.spill.maxBytes, dir: this.temporaryRoot, onFailure: this.onSpillFailure,
      });
    }
    const write = (label, bytes) => {
      if (collected[label]) collected[label].push(bytes);
      else if (output[label]) return output[label].write(bytes);
      else return process[label].write(bytes);
      return true;
    };
    const settle = cleanupFailure => {
      const providerErrors = new Set([cleanupFailure, state.providerFailure].filter(Boolean));
      spec.signal?.removeEventListener('abort', handle.terminate);
      input?.destroy();
      if (!didStart) started.reject(state.failure ?? Object.assign(new Error('任务在启动前已结束'), { code: 'ERR_OHOS_NOT_STARTED' }));
      for (const collector of Object.values(collected)) {
        try { collector.seal(); } catch (error) { providerErrors.add(error); }
      }
      for (const stream of Object.values(output)) {
        try { stream.end(); } catch (error) { providerErrors.add(error); }
      }
      state.settled = true;
      if (providerErrors.size) {
        state.rangeFailure = providerErrors.size === 1 ? [...providerErrors][0]
          : new AggregateError([...providerErrors], 'Virtual process resource cleanup failed');
        this.#resourceFailures.add(state.rangeFailure);
      }
      this.live.delete(handle);
      if (lane.active === handle) lane.active = undefined;
      if (state.rangeFailure) gone.reject(state.rangeFailure);
      else gone.resolve(true);
      if (state.rangeFailure) {
        const failures = [state.rangeFailure];
        if (state.failure && !state.stopped && state.failure !== state.rangeFailure) failures.push(state.failure);
        completion.reject(failures.length === 1 ? failures[0]
          : new AggregateError(failures, 'Virtual process and resource cleanup failed', { cause: failures[0] }));
      } else if (state.failure && !state.stopped) completion.reject(state.failure);
      else completion.resolve(state.stopped ? { exitCode: null, signal: state.stopSignal ?? 'SIGTERM' } : state.outcome);
      queueMicrotask(() => this.startNext(lane));
    };
    const finish = () => {
      if (state.settled || state.finishing) return;
      state.finishing = true;
      state.resources?.stop();
      // Worker exit plus stdout/stderr drain is the first barrier. Drain parent I/O and
      // replies, then exact cleanup/FD close/ledger release, before any lifetime
      // promise settles or this lane can start its following job.
      Promise.resolve().then(async () => {
        const failures = [];
        try { await state.resources?.finish({ cancelled: state.stopped }); } catch (error) { failures.push(error); }
        try {
          if (state.workspace && !state.workspace.retire()) throw Object.assign(new Error('ERR_WORKSPACE_DRAIN'), { code: 'ERR_WORKSPACE_DRAIN' });
        } catch (error) { quarantineProcessGrantRetirement(); failures.push(error); }
        if (failures.length === 1) throw failures[0];
        if (failures.length) throw new AggregateError(failures, 'Virtual process resources did not retire');
      }).then(() => settle(), settle);
    };
    const handle = {
      stdin: input, stdout: output.stdout, stderr: output.stderr, control: undefined, collected,
      done: completion.promise, started: started.promise,
      terminate: signal => {
        if (state.settled || state.stopped) return;
        state.stopSignal = typeof signal === 'string' ? signal : 'SIGTERM';
        state.stopped = true;
        try { state.workspace?.retire(); } catch (error) { state.providerFailure ??= error; }
        state.resources?.stop();
        if (state.worker) void state.worker.terminate().catch(error => { state.providerFailure ??= error; });
        else finish();
      },
      waitForExit: async signal => {
        if (state.settled) {
          if (state.rangeFailure) throw state.rangeFailure;
          return true;
        }
        if (signal?.aborted) return false;
        const interrupted = Promise.withResolvers();
        const abort = () => interrupted.resolve(false);
        signal?.addEventListener('abort', abort, { once: true });
        try { return await Promise.race([gone.promise, interrupted.promise]); }
        finally { signal?.removeEventListener('abort', abort); }
      },
      start: () => {
        // finish drains asynchronously. A queued start must not create a new
        // Worker after a same-stack cancel already began that finish barrier.
        if (state.stopped || state.finishing || state.settled || state.worker) return;
        lane.active = handle;
        try {
          const name = commandName(argv[0]);
          if (spec.stdio.control === 'pipe' || (spec.stdio.stdin === 'pipe' && name !== 'node')) {
            throw Object.assign(new Error('当前虚拟 shell 只支持批量 stdin；交互字节通道尚未实现'), { code: 'ERR_OHOS_STREAM_UNAVAILABLE' });
          }
          if (!name) {
            write('stderr', Buffer.from(unavailableMessage + '\n'));
            state.outcome = { exitCode: 127, signal: null };
            finish();
            return;
          }
          if (!grant && isLogicalWorkspacePath(spec.cwd)) {
            throw Object.assign(new Error('ERR_WORKSPACE_CONFINEMENT_REQUIRED'), { code: 'ERR_WORKSPACE_CONFINEMENT_REQUIRED' });
          }
          const cwd = grant ? resolve(spec.cwd) : realpathSync(resolve(spec.cwd));
          if (grant ? (!isAbsolute(spec.cwd) || spec.cwd !== cwd || !isInside(grant.mountPoint, cwd))
            : (!this.roots.some(root => isInside(root, cwd)) || !statSync(cwd).isDirectory())) {
            throw Object.assign(new Error('EACCES: 工作目录不在授权工作区内'), { code: 'EACCES' });
          }
          // 没有会话票据的调用只保守取得本次 cwd；不能推断它拥有其他宿主根。
          const roots = grant ? [this.temporaryRoot] : distinctRoots([policy?.workspaceRoot ?? cwd, this.temporaryRoot]);
          if (!grant && !roots.some(root => isInside(root, cwd))) {
            throw Object.assign(new Error('EACCES: OHOS_SANDBOX_DENIED: 工作目录不在本次会话授权根内'), { code: 'EACCES' });
          }
          const env = { ...scrubbedParentEnv(), ...spec.env, TMPDIR: this.temporaryRoot };
          for (const [key, value] of Object.entries(env)) if (value === undefined) delete env[key];
          // Worker 通过继承 --import 重新建立测试标记；环境变量不能启用仿真。
          const workerEnv = { ...env };
          if (grant) workerEnv.DSH_GO_OHOS_NATIVE_LIBRARY_DIR = processGrantNativeDirectory();
          if (globalThis[Symbol.for('dsh.go.ohos.sim')] === true && process.env.DSH_GO_OHOS_SIM_PLATFORM) {
            workerEnv.DSH_GO_OHOS_SIM_PLATFORM = process.env.DSH_GO_OHOS_SIM_PLATFORM;
          }
          const nodeTask = name === 'node';
          const linux = this.#linux();
          if (grant && (nodeTask || name === 'git')) throw Object.assign(new Error(
            'ERR_WORKSPACE_SCOPE_UNSUPPORTED: Node 脚本与 owned-git 尚未接入目录租约'), { code: 'ERR_WORKSPACE_SCOPE_UNSUPPORTED' });
          let worker;
          if (nodeTask) {
            try {
              worker = createNodeScriptWorker({ args: argv.slice(1), cwd, roots,
                workspaceRoots: [policy?.workspaceRoot ?? cwd], readOnly: policy?.mode === 'read-only', env: workerEnv,
                stdin: typeof spec.stdio.stdin === 'object' ? spec.stdio.stdin.data : '',
                streamStdin: spec.stdio.stdin === 'pipe' });
            } catch (error) {
              if (['ENOENT', 'ENOTDIR', 'ERR_OHOS_NODE_SCRIPT_ARGUMENTS', 'ERR_OHOS_NODE_PRELOAD_REQUIRED'].includes(error.code)) {
                didStart = true;
                started.resolve();
                queueMicrotask(() => {
                  write('stderr', Buffer.from(`${error.code}: ${error.message}\n`));
                  state.outcome = { exitCode: error.code === 'ERR_OHOS_NODE_SCRIPT_ARGUMENTS' ? 2 : error.code === 'ERR_OHOS_NODE_PRELOAD_REQUIRED' ? 127 : 1, signal: null };
                  finish();
                });
                return;
              }
              throw error;
            }
          } else {
            const send = message => state.worker.postMessage(message);
            if (!grant) state.resources = this.#createOwnedGitServer({
              roots, policy, send,
              onFailure: error => { state.providerFailure ??= error; handle.terminate(); },
            });
            if (!grant && linux) state.resources = createLinuxForwardServer({ linux, send, next: state.resources,
              workspaceRoot: policy?.workspaceRoot ?? cwd, mode: policy?.mode ?? 'workspace-write' });
            if (grant) state.workspace = borrowProcessGrantAuthority().issue([grant], {
              readOnly: policy.mode === 'read-only', workspaceRoot: policy.workspaceRoot,
            });
            worker = new Worker(new URL('./worker.mjs', import.meta.url), {
              workerData: {
                // This fixed provider entry is independent of DSH's plugin
                // profile. Do not bootstrap that profile in its scrubbed env.
                dshOhosVirtualProcess: { protocol: 1 },
                ...(state.workspace ? { dshOhosWorkspaceGrants: { mounts: state.workspace.mounts } } : {}),
                argv: [name, ...argv.slice(1)], cwd, policy,
                roots, linuxCommands: linux?.commands ?? [],
                env, stdin: typeof spec.stdio.stdin === 'object' ? spec.stdio.stdin.data : '',
              },
              env: workerEnv, stdout: true, stderr: true,
              resourceLimits: { maxOldGenerationSizeMb: 256 },
            });
          }
          state.worker = worker;
          didStart = true;
          started.resolve();
          if (input) {
            worker.stdin.on('error', error => input.destroy(error));
            input.pipe(worker.stdin);
          }
          let workerExited = false;
          const ended = new Set();
          const finishWorker = () => {
            if (workerExited && ended.size === 2) finish();
          };
          const drainListeners = [];
          for (const label of ['stdout', 'stderr']) {
            const resume = () => worker[label].resume();
            const sink = output[label] ?? process[label];
            drainListeners.push([sink, resume]);
            const end = () => { ended.add(label); finishWorker(); };
            worker[label].once('end', end);
            worker[label].once('close', end);
            worker[label].on('data', bytes => {
              if (!write(label, bytes) && !workerExited && !state.stopped) {
                worker[label].pause();
                sink.once('drain', resume);
              }
            });
          }
          if (!nodeTask) worker.on('message', message => {
            if (state.resources?.handle(message)) return;
            if (message.failure) state.failure = Object.assign(new Error(message.failure.message), message.failure);
            else state.outcome = { exitCode: message.exitCode, signal: null };
          });
          worker.once('error', error => {
            if (nodeTask) write('stderr', Buffer.from(formatNodeScriptError(error) + '\n'));
            else state.failure = error;
          });
          worker.once('exit', exitCode => {
            input?.destroy();
            // Worker events retain the script integer; the subprocess seam exposes a POSIX status.
            if (nodeTask) state.outcome = { exitCode: exitCode & 0xff, signal: null };
            if (!state.outcome && !state.failure && !state.stopped) state.failure = new Error(`虚拟进程 worker 未报告结果，退出码 ${exitCode}`);
            workerExited = true;
            // A paused Worker readable can still contain bytes after its exit
            // event. Drain that finite tail before sealing the public streams.
            // Once execution is gone, pending consumer backpressure must not
            // hold cancellation/join open indefinitely.
            for (const [sink, resume] of drainListeners) { sink.removeListener('drain', resume); resume(); }
            finishWorker();
          });
        } catch (error) {
          state.failure = error;
          finish();
        }
      },
    };
    this.live.add(handle);
    spec.signal?.addEventListener('abort', handle.terminate, { once: true });
    lane.queue.push(handle);
    queueMicrotask(() => this.startNext(lane));
    return handle;
  }

  startNext(lane) {
    if (lane.active || this.closed) return;
    while (lane.queue.length) {
      const next = lane.queue.shift();
      if (!this.live.has(next)) continue;
      next.start();
      break;
    }
  }

  dispose() {
    if (this.#disposePromise) return this.#disposePromise;
    this.closed = true;
    for (const prepared of this.prepared.values()) prepared.signal?.removeEventListener('abort', prepared.cancel);
    this.prepared.clear();
    const handles = [...this.live];
    for (const handle of handles) handle.terminate();
    for (const lane of Object.values(this.lanes)) lane.queue.length = 0;
    this.#disposePromise = (async () => {
      const observations = await Promise.allSettled(handles.map(handle => handle.waitForExit()));
      const failures = new Set(this.#resourceFailures);
      for (const result of observations) if (result.status === 'rejected') failures.add(result.reason);
      // Preserve unresolved ownership evidence, including a caller-independent
      // temporary root. Never recursively remove it after a resource failure.
      if (failures.size === 1) throw [...failures][0];
      if (failures.size) throw new AggregateError([...failures], 'Virtual process resources did not dispose cleanly');
      const owner = this.#temporaryOwner;
      if (!owner) return;
      const current = await lstat(owner.path, { bigint: true }).catch(error => {
        if (error.code !== 'ENOENT') throw error;
      });
      if (!current) return;
      if (!current.isDirectory() || current.dev !== owner.dev || current.ino !== owner.ino) {
        throw Object.assign(new Error('鸿蒙虚拟进程临时根的身份已改变，拒绝删除替换目录'), { code: 'ERR_OHOS_TEMP_ROOT_REPLACED' });
      }
      await rm(owner.path, { recursive: true });
    })();
    return this.#disposePromise;
  }
}
