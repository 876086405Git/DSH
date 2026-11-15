import { SandboxProvider } from '@deepseek-ai/dsh-sandbox';

// 保留 dsh-bash-sandbox 与 tool-bash 原有的逐调用 policy 和审批流程。
export default class OhSandboxProvider extends SandboxProvider {
  static inject = ['subprocess'];
  constructor(ctx) {
    if (process.platform !== 'openharmony' && globalThis[Symbol.for('dsh.go.ohos.sim')] !== true) throw new Error('鸿蒙沙箱后端只能由鸿蒙 profile 或仿真显式启用');
    super(ctx);
  }
  async confine(argv, policy, signal) {
    return {
      argv: this.ctx.subprocess.prepare(argv, policy, signal),
      // ReadWriteFs 使用路径检查，不能对抗外部宿主同时替换目录的竞态。
      enforcement: 'partial',
      denialSignatures: ['OHOS_SANDBOX_DENIED', 'EACCES', 'permission denied'],
      runnerFailureRules: [],
    };
  }
}
