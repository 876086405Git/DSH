import { SubprocessRuntime } from '@deepseek-ai/dsh-subprocess';
import { CommandRouter, bindPluginCommands } from './command-router.mjs';
import { createChildProcessFacade } from './plugin-process.mjs';
import { createLinuxCommandBackend } from './linux-backend.mjs';
import { createLinuxControl, registerLinuxControlRoutes } from '../linux/control.mjs';

export default class OhSubprocessRuntime extends SubprocessRuntime {
  constructor(ctx, config = {}) {
    if (process.platform !== 'openharmony' && globalThis[Symbol.for('dsh.go.ohos.sim')] !== true) throw new Error('鸿蒙虚拟进程后端只能由鸿蒙 profile 或仿真显式启用');
    super(ctx);
    const onSpillFailure = error => ctx.logger.error('鸿蒙虚拟进程无法保留完整输出', error);
    this.linux = createLinuxControl();
    // Agent and plugin commands such as gh, python3 and pip run in the App's Linux.
    this.backend = new CommandRouter({ ...config, onSpillFailure },
      { linux: roots => createLinuxCommandBackend({ control: this.linux, ...roots, onSpillFailure }) });
    this.pluginProcess = createChildProcessFacade(spec => this.backend.spawnPlugin(spec));
    this.capabilities = this.backend.capabilities;
    ctx.inject(['webServer'], webCtx => registerLinuxControlRoutes(webCtx, this.linux));
    ctx.effect(() => () => this.linux.shutdown(), 'ohos Linux joined shutdown');
    ctx.effect(() => () => this.backend.dispose(), 'ohos subprocess teardown');
    ctx.effect(() => bindPluginCommands(this.backend), 'ohos plugin command binding');
  }
  get temporaryRoot() { return this.backend.temporaryRoot; }
  spawn(spec) { return this.backend.spawn(spec); }
  prepare(...args) { return this.backend.prepare(...args); }
  resolveExecutable(...args) { return this.backend.resolveExecutable(...args); }
  terminalEnvironment(...args) { return this.backend.terminalEnvironment(...args); }
  spawnTerminal(...args) { return this.backend.spawnTerminal(...args); }
}
