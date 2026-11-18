// Host-only declaration boundaries; not HarmonyOS SDK headers or ArkTS proof.
declare const console: { error(message: string): void };
declare module '@ohos.base' { export interface BusinessError extends Error { code: number; } }
declare module '@ohos.app.ability.common' {
  namespace common {
    interface Context { filesDir: string; getApplicationContext(): ApplicationContext; }
    interface ApplicationContext extends Context { applicationInfo: { name: string }; }
  }
  export default common;
}
declare module '@ohos.app.ability.Want' {
  export default interface Want { parameters?: Record<string, Object>; }
}
declare module '@ohos.util' {
  const util: {
    TextEncoder: new () => { encodeInto(text: string): Uint8Array };
    TextDecoder: { create(encoding: string, options: { fatal: boolean }): { decodeToString(input: Uint8Array): string } };
  }; export default util;
}
declare module '@ohos.file.fs' {
  namespace fs {
    enum OpenMode { READ_ONLY = 0, WRITE_ONLY = 1, READ_WRITE = 2, CREATE = 64, TRUNC = 512, NOFOLLOW = 131072, DIR = 65536 }
    interface Stat { size: number; isFile(): boolean; isDirectory(): boolean; isSymbolicLink(): boolean; }
    interface File { fd: number; tryLock(exclusive?: boolean): void; }
    function mkdir(path: string): Promise<void>;
    function lstat(path: string): Promise<Stat>;
    function stat(fd: number): Promise<Stat>;
    function open(path: string, mode: number): Promise<File>;
    function close(file: File): Promise<void>;
    function read(fd: number, buffer: ArrayBuffer, options: { offset: number; length: number }): Promise<number>;
    function write(fd: number, buffer: ArrayBuffer, options: { offset: number }): Promise<number>;
    function fsync(fd: number): Promise<void>;
    function rename(from: string, to: string): Promise<void>;
  } export default fs;
}
declare module '@kit.FormKit' {
  import common from '@ohos.app.ability.common';
  import Want from '@ohos.app.ability.Want';
  export namespace formBindingData {
    interface FormBindingData { data: Object; }
    function createFormBindingData(data?: Object | string): FormBindingData;
  }
  export namespace formInfo {
    enum FormParam { IDENTITY_KEY = 'ohos.extra.param.key.form_identity' }
    interface RunningFormInfo { formId: string; bundleName: string; moduleName: string; abilityName: string; formName: string; }
  }
  export namespace formProvider {
    function getPublishedRunningFormInfos(): Promise<formInfo.RunningFormInfo[]>;
    function updateForm(id: string, data: formBindingData.FormBindingData): Promise<void>;
  }
  export class FormExtensionAbility {
    context: common.Context;
    onAddForm(want: Want): formBindingData.FormBindingData;
    onUpdateForm(formId: string, wantParams?: Record<string, Object>): void;
    onCastToNormalForm(formId: string): void;
    onRemoveForm(formId: string): void;
    onStop?(): void;
  }
}
declare module '@ohos/flutter_ohos' {
  import common from '@ohos.app.ability.common';
  export interface FlutterPluginBinding { getApplicationContext(): common.Context; getBinaryMessenger(): Object; }
  export interface FlutterPlugin {
    getUniqueClassName(): string; onAttachedToEngine(binding: FlutterPluginBinding): void;
    onDetachedFromEngine(binding: FlutterPluginBinding): void;
  }
  // MethodCall.args verified against pinned official flutter.har MethodCall.ets.
  export interface MethodCall { method: string; args: Object | null | undefined; }
  export interface MethodResult { success(value: Object | null): void; error(code: string, message: string, details: Object | null): void; notImplemented(): void; }
  export interface MethodCallHandler { onMethodCall(call: MethodCall, result: MethodResult): void; }
  export class MethodChannel { constructor(messenger: Object, name: string); setMethodCallHandler(handler: MethodCallHandler | null): void; }
}
