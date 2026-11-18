// 动态 Native 模块的 default 对象遵循公开 ArkTS import 约定；目标装载仍待真机核实。
import type { HostState, HostEvent, HostOptions, HostLifecycleSnapshot, HostPhoneSnapshot, HostPhoneKey } from 'libdsh_host.so';
import { RuntimeChannelError } from './RuntimeCore';

export interface WorkspaceGrantStatus { active: boolean; drained: boolean; writable: boolean; leases: number; generation: number; }

export interface NativeHostModule {
  workspaceGrant(operation: string, id: string, generation: number, fd?: number, writable?: boolean): WorkspaceGrantStatus;
  start(options: HostOptions): void;
  phoneAttach(ownerHash: string, engine: number, owner: number): number;
  phoneSnapshot(): HostPhoneSnapshot;
  phoneRetire(generation: number): boolean;
  phoneOperation(operation: string, key: HostPhoneKey, result?: string): string | boolean | null;
  lifecycleUpdate(operation: string, owner: number, grant: number, value: number): number;
  lifecycleSnapshot(): HostLifecycleSnapshot;
  stop(): void;
  getState(): HostState;
  drainEvents(): HostEvent[];
  openUserFile(root: string, relative: string): number;
}

// Configured synchronously by the process-wide RuntimeController. A consumer
// that arrives earlier must fail closed, never bypass recovery initialization.
export interface NativeRecoveryGate {
  prepare: () => Promise<void>;
  check: () => void;
  begin: () => Promise<string>;
  finish: (id: string, success: boolean) => Promise<void>;
}
let recovery: NativeRecoveryGate | null = null;
let loaded: NativeHostModule | null = null;
let loading: Promise<NativeHostModule> | null = null;
let touched: boolean = false;

export function configureNativeRecovery(gate: NativeRecoveryGate): void {
  if (recovery !== null && recovery !== gate) throw new RuntimeChannelError('ohos_recovery_owner', '原生恢复门已配置，不能替换执行代际。');
  recovery = gate;
}
export function nativeHostTouched(): boolean { return touched; }
export function peekNativeHost(): NativeHostModule | null { return loaded; }

export function nativeHostState(): HostState {
  if (loaded !== null) return loaded.getState();
  return { phase: 'idle', consumed: false, baseUrl: null, token: null,
    exitCode: null, errorCode: null, errorMessage: null };
}

async function importNative(gate: NativeRecoveryGate): Promise<NativeHostModule> {
  await gate.prepare();
  gate.check();
  const id = await gate.begin();
  let settled = false;
  try {
    // No await between this admission check and the only dynamic import.
    gate.check();
    touched = true;
    const module: ESObject = await import('libdsh_host.so');
    const host: NativeHostModule | undefined = module.default;
    if (host === undefined) throw new RuntimeChannelError('ohos_native_unavailable', '随包原生宿主无法加载，请检查安装包。');
    loaded = host;
    await gate.finish(id, true);
    settled = true;
    gate.check();
    return host;
  } catch (error) {
    if (!settled) await gate.finish(id, false);
    throw error as Error;
  }
}

export async function loadNativeHost(): Promise<NativeHostModule> {
  const gate = recovery;
  if (gate === null) throw new RuntimeChannelError('ohos_recovery_unconfigured', '原生恢复门尚未配置。');
  gate.check();
  if (loading === null) {
    loading = importNative(gate).catch((error: Error): NativeHostModule => {
      // Recovery preparation can fail before import is even attempted. Only
      // that shared task may be retried; a touched DSO remains process-sticky.
      if (!touched) loading = null;
      throw error;
    });
  }
  // Keep failures after touching the DSO, including missing exports or finish I/O.
  const host = await loading;
  gate.check();
  return host;
}
