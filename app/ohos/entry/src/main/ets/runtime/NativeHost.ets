// 动态 Native 模块的 default 对象遵循公开 ArkTS import 约定；目标装载仍待真机核实。
import type { HostState, HostEvent, HostOptions } from 'libdsh_host.so';
import { RuntimeChannelError } from './RuntimeCore';

export interface NativeHostModule {
  start(options: HostOptions): void;
  stop(): void;
  getState(): HostState;
  drainEvents(): HostEvent[];
  openUserFile(root: string, relative: string): number;
}

let loaded: NativeHostModule | null = null;
let loading: Promise<NativeHostModule> | null = null;

export function peekNativeHost(): NativeHostModule | null { return loaded; }

export function nativeHostState(): HostState {
  if (loaded !== null) return loaded.getState();
  return { phase: 'idle', consumed: false, baseUrl: null, token: null,
    exitCode: null, errorCode: null, errorMessage: null };
}

export function loadNativeHost(): Promise<NativeHostModule> {
  if (loading === null) {
    loading = import('libdsh_host.so').then((module: ESObject): NativeHostModule => {
      // A missing native library can resolve with an undefined default export.
      const host: NativeHostModule | undefined = module.default;
      if (host === undefined) throw new RuntimeChannelError('ohos_native_unavailable', '随包原生宿主无法加载，请检查安装包。');
      loaded = host;
      return host;
    }).catch((error: Error): NativeHostModule => {
      loading = null;
      throw error as Error;
    });
  }
  return loading;
}
