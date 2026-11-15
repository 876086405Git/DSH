import { SubprocessRuntime } from '@deepseek-ai/dsh-subprocess';
import { VirtualSubprocessRuntime } from './runtime.mjs';

export default class OhSubprocessRuntime extends SubprocessRuntime {
  constructor(ctx, config = {}) {
    if (process.platform !== 'openharmony' && globalThis[Symbol.for('dsh.go.ohos.sim')] !== true) throw new Error('鸿蒙虚拟进程后端只能由鸿蒙 profile 或仿真显式启用');
    super(ctx);
    this.backend = new VirtualSubprocessRuntime({ ...config, onSpillFailure: error => ctx.logger.error('鸿蒙虚拟进程无法保留完整输出', error) });
    this.capabilities = this.backend.capabilities;
    ctx.effect(() => () => this.backend.dispose(), 'ohos subprocess teardown');
  }
  get temporaryRoot() { return this.backend.temporaryRoot; }
  spawn(spec) { return this.backend.spawn(spec); }
  prepare(...args) { return this.backend.prepare(...args); }
  resolveExecutable(...args) { return this.backend.resolveExecutable(...args); }
  terminalEnvironment(...args) { return this.backend.terminalEnvironment(...args); }
  spawnTerminal(...args) { return this.backend.spawnTerminal(...args); }
}
