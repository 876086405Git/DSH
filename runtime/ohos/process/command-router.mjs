import { basename } from 'node:path';
import { VirtualSubprocessRuntime } from './runtime.mjs';
import { pythonCommandName } from './python-backend.mjs';

const error = (code, message) => Object.assign(new Error(message), { code });
const isNode = command => ['node', '/bin/node', '/usr/bin/node', '/dsh-go/ohos/bin/node', process.execPath].includes(command);
const virtualCommands = new Set(['bash', 'sh', 'rg', 'git', 'node']);
const accepts = (backend, policy) => Array.isArray(backend?.capabilities?.confinement)
  && backend.capabilities.confinement.includes(policy.mode) && typeof backend.prepare === 'function';

// Only the application owner installs backends. Neither argv nor env can enable one.
// A Linux factory receives this router's own roots: they are what its guest may mount.
export class CommandRouter {
  closed = false;
  #disposePromise;
  constructor(config, { linux, nativePython } = {}) {
    this.nativePython = nativePython;
    this.virtual = new VirtualSubprocessRuntime(config, { selectExternal: (argv, policy) => {
      if (virtualCommands.has(basename(argv[0]))) return;
      return this.select(argv, policy);
    }, linux: () => this.linux });
    this.pluginNode = new VirtualSubprocessRuntime({ ...config, temporaryRoot: this.virtual.temporaryRoot }, { concurrent: true });
    this.linux = typeof linux === 'function'
      ? linux({ workspaceRoots: this.virtual.workspaceRoots, temporaryRoot: this.virtual.temporaryRoot }) : linux;
    this.capabilities = Object.freeze({ ...this.virtual.capabilities,
      linuxCommands: Object.freeze([...this.linux?.commands ?? []]),
      pluginProcesses: Object.freeze({ node: this.virtual.capabilities.nodeScripts !== 'none',
        nativePython: !!nativePython, linux: !!this.linux }),
    });
  }
  get temporaryRoot() { return this.virtual.temporaryRoot; }
  get roots() { return this.virtual.roots; }
  get prepared() { return this.virtual.prepared; }
  get live() { return new Set([this.virtual, this.pluginNode, this.nativePython, this.linux].flatMap(backend => [...(backend?.live ?? [])])); }
  select(argv, policy) {
    let backend = pythonCommandName(argv[0]) && this.nativePython ? this.nativePython : this.linux;
    if (policy && backend && !accepts(backend, policy)) {
      backend = backend !== this.linux ? this.linux : undefined;
      if (!accepts(backend, policy)) throw error('ERR_OHOS_BACKEND_CONFINEMENT',
        '此命令后端尚未支持本次工作区授权与受限模式；请连接电脑执行');
    }
    return backend;
  }
  spawnPlugin(spec) {
    if (this.closed) throw error('ERR_OHOS_PROCESS_CLOSED', '插件命令服务已关闭');
    if (isNode(spec.argv[0])) return this.pluginNode.spawn({ ...spec, argv: ['node', ...spec.argv.slice(1)] });
    const backend = this.select(spec.argv);
    if (!backend) throw error('ERR_OHOS_NO_SPAWN', '此命令需要可用的 App 内 Linux 后端；也可连接电脑执行');
    return backend.spawn(spec);
  }
  spawn(spec) {
    if (this.closed) throw error('ERR_OHOS_PROCESS_CLOSED', '命令服务已关闭');
    return this.virtual.spawn(spec);
  }
  prepare(...args) {
    if (this.closed) throw error('ERR_OHOS_PROCESS_CLOSED', '命令服务已关闭');
    return this.virtual.prepare(...args);
  }
  async resolveExecutable(command, env, signal) {
    if (isNode(command)) return this.virtual.resolveExecutable('node', env, signal);
    if (virtualCommands.has(basename(command))) return this.virtual.resolveExecutable(command, env, signal);
    const backend = this.select([command]);
    if (!backend) return this.virtual.resolveExecutable(command, env, signal);
    signal?.throwIfAborted();
    return backend.resolveExecutable ? backend.resolveExecutable(command, env, signal) : command;
  }
  terminalEnvironment(...args) { return this.virtual.terminalEnvironment(...args); }
  spawnTerminal(...args) {
    if (this.closed) throw error('ERR_OHOS_PROCESS_CLOSED', '命令服务已关闭');
    return this.virtual.spawnTerminal(...args);
  }
  dispose() {
    if (this.#disposePromise) return this.#disposePromise;
    this.closed = true;
    for (const job of this.virtual.live) job.terminate();
    return this.#disposePromise = (async () => {
      const results = await Promise.allSettled([...new Set([this.pluginNode, this.nativePython, this.linux].filter(Boolean))].map(x => x.dispose()));
      const errors = results.filter(x => x.status === 'rejected').map(x => x.reason);
      if (errors.length) throw new AggregateError(errors, '命令后端资源未全部关闭');
      // The virtual owner may remove its private temporary root only after
      // every other provider sharing that root has really finished.
      await this.virtual.dispose();
    })();
  }
}

// Each Cordis effect owns its registration. Context-bound facades dispatch
// directly to their router; this compatibility entry requires one live owner.
const bindings = new Map();
export function bindPluginCommands(runtime) {
  const ticket = {};
  bindings.set(ticket, runtime);
  return () => { bindings.delete(ticket); };
}
export function spawnPluginCommand(spec) {
  const owners = new Set([...bindings.values()].filter(runtime => !runtime.closed));
  if (!owners.size) throw error('ERR_OHOS_NO_SPAWN', '插件命令服务尚未就绪');
  if (owners.size !== 1) throw error('ERR_OHOS_PROCESS_OWNER', '多个插件命令后端可用；请使用所属上下文的命令服务');
  return owners.values().next().value.spawnPlugin(spec);
}
