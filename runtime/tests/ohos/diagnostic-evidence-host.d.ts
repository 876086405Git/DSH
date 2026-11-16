// Finite public API type fixture only. This is not a HarmonyOS SDK declaration.
declare function canIUse(capability: string): boolean;
declare module '@ohos.base' { export interface BusinessError extends Error { code: number; } }
declare module '@ohos.file.fs' {
  namespace fs {
    interface File { fd: number; }
    interface Stat { size: number; isFile(): boolean; isDirectory(): boolean; isSymbolicLink(): boolean; }
    const OpenMode: { READ_ONLY: number; READ_WRITE: number; CREATE: number; NOFOLLOW: number; NONBLOCK: number; };
    function mkdir(path: string): Promise<void>;
    function lstat(path: string): Promise<Stat>;
    function open(path: string, mode: number): Promise<File>;
    function stat(fd: number): Promise<Stat>;
    function read(fd: number, buffer: ArrayBuffer, options: {offset: number; length: number}): Promise<number>;
    function write(fd: number, buffer: ArrayBuffer): Promise<number>;
    function truncate(fd: number, length: number): Promise<void>;
    function fsync(fd: number): Promise<void>;
    function close(file: File): Promise<void>;
    function rename(from: string, to: string): Promise<void>;
    function unlink(path: string): Promise<void>;
  }
  export default fs;
}
declare module '@ohos.util' {
  namespace util {
    class TextEncoder { encodeInto(value: string): Uint8Array; }
    class TextDecoder {
      static create(encoding: string, options: {fatal: boolean}): TextDecoder;
      decodeToString(value: Uint8Array): string;
    }
  }
  export default util;
}
declare module '@ohos.hiviewdfx.hiAppEvent' {
  namespace hiAppEvent {
    const domain: {OS: string};
    const event: {APP_CRASH: string; APP_FREEZE: string};
    interface AppEventInfo { domain: string; name: string; eventType: number; params: object; }
    interface AppEventPackage {packageId: number; row: number; size: number; data: string[]; appEventInfos: AppEventInfo[];}
    class AppEventPackageHolder { setRow(rows: number): void; takeNext(): AppEventPackage; }
    interface Watcher {
      name: string;
      appEventFilters?: {domain: string; names?: string[]}[];
      triggerCondition?: {row?: number; size?: number; timeOut?: number};
      onTrigger?: (rows: number, bytes: number, holder: AppEventPackageHolder) => void;
    }
    function addWatcher(watcher: Watcher): AppEventPackageHolder;
    function removeWatcher(watcher: Watcher): void;
  }
  export default hiAppEvent;
}
declare module '@ohos.app.ability.common' {
  namespace common {
    interface Context { filesDir: string; resourceManager: object; }
    interface UIAbilityContext extends Context { config: {fontSizeScale?: number}; }
  }
  export default common;
}
declare module '@ohos.bundle.bundleManager' {
  namespace bundleManager {
    const BundleFlag: {GET_BUNDLE_INFO_DEFAULT: number};
    interface BundleInfo { versionName: string; versionCode: number; }
    function getBundleInfoForSelf(flags: number): Promise<BundleInfo>;
  }
  export default bundleManager;
}
declare module '@ohos.display' {
  namespace display {
    interface Display { width: number; height: number; densityPixels: number; densityDPI: number; }
    function getDefaultDisplaySync(): Display;
  }
  export default display;
}
declare module '@ohos.file.statvfs' {
  namespace statvfs { function getFreeSize(path: string): Promise<number>; }
  export default statvfs;
}
declare module '@ohos/flutter_ohos' {
  import common from '@ohos.app.ability.common';
  export type Any = unknown;
  export interface FlutterPluginBinding { getBinaryMessenger(): object; getApplicationContext(): common.Context; }
  export interface AbilityPluginBinding { getAbility(): {context: common.UIAbilityContext}; }
  export interface FlutterPlugin { getUniqueClassName(): string; onAttachedToEngine(binding: FlutterPluginBinding): void; onDetachedFromEngine(binding: FlutterPluginBinding): void; }
  export interface AbilityAware { onAttachedToAbility(binding: AbilityPluginBinding): void; onDetachedFromAbility(): void; }
  export interface MethodCall { method: string; argument(name: string): Any; }
  export interface MethodResult { success(value: Any): void; error(code: string, message: string, details: Any): void; notImplemented(): void; }
  export class MethodChannel {
    constructor(messenger: object, name: string);
    setMethodCallHandler(handler: {onMethodCall(call: MethodCall, result: MethodResult): void} | null): void;
  }
}
