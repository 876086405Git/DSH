// Explicit host-only boundaries transcribed from the linked primary API pages.
// These are not real HMS/ArkTS SDK declarations or proof of device support.
type ESObject = any;
declare function canIUse(capability: string): boolean;
declare module '@ohos.base' { export interface BusinessError extends Error { code: number; } }
declare module '@ohos.deviceInfo' { const deviceInfo: { sdkApiVersion: number }; export default deviceInfo; }
declare module '@ohos.util' { const util: { generateRandomUUID(entropyCache?: boolean): string }; export default util; }
declare module '@ohos.app.ability.common' {
  namespace common {
    interface Context { filesDir: string; cacheDir: string; tempDir: string; }
    interface UIAbilityContext extends Context { abilityInfo: { bundleName: string; moduleName: string; name: string }; }
  }
  export default common;
}
declare module '@ohos.app.ability.UIAbility' {
  import common from '@ohos.app.ability.common';
  export default class UIAbility { context: common.UIAbilityContext; }
}
declare module '@ohos.app.ability.Want' {
  export default interface Want { bundleName?: string; moduleName?: string; abilityName?: string; }
}
declare module '@kit.AppGalleryKit' {
  import common from '@ohos.app.ability.common';
  import Want from '@ohos.app.ability.Want';
  export namespace productViewManager {
    interface CheckShortcutResult { code: number; tid?: string; expired?: number; limit?: number; }
    interface PinShortcutInfo { shortcutId: string; icon?: string; iconId?: number; label?: string; labelId?: number; want?: Want; }
    function checkPinShortcutPermitted(context: common.UIAbilityContext, shortcutId: string,
      want: Want, label: string, foregroundIcon: string, backgroundIcon: string): Promise<CheckShortcutResult>;
    function requestNewPinShortcut(context: common.UIAbilityContext, tid: string): Promise<void>;
    function getPinShortcutInfos(): Promise<PinShortcutInfo[]>;
  }
}
declare module '@ohos.file.fs' {
  namespace fs {
    enum OpenMode { CREATE = 64, WRITE_ONLY = 1, NOFOLLOW = 131072 }
    interface Stat { size: number; isDirectory(): boolean; isFile(): boolean; isSymbolicLink(): boolean; }
    interface File { fd: number; path: string; }
    interface WriteOptions { offset?: number; }
    function mkdir(path: string): Promise<void>;
    function lstat(path: string): Promise<Stat>;
    function listFile(path: string): Promise<string[]>;
    function open(path: string, mode: number): Promise<File>;
    function write(fd: number, data: ArrayBuffer, options: WriteOptions): Promise<number>;
    function fsync(fd: number): Promise<void>;
    function close(fd: number): Promise<void>;
    function unlink(path: string): Promise<void>;
    function rmdir(path: string): Promise<void>;
  }
  export default fs;
}
declare module '@ohos.multimedia.image' {
  namespace image {
    enum PixelMapFormat { RGBA_8888 = 3 }
    interface Size { width: number; height: number; }
    interface ImageInfo { size: Size; }
    interface DecodingOptions { desiredSize?: Size; desiredPixelFormat?: PixelMapFormat; }
    interface PackingOption { format: string; quality: number; bufferSize?: number; }
    interface PixelMap { getImageInfo(): Promise<ImageInfo>; release(): Promise<void>; }
    interface ImageSource {
      getImageInfo(): Promise<ImageInfo>; createPixelMap(options: DecodingOptions): Promise<PixelMap>;
      release(): Promise<void>;
    }
    interface ImagePacker { packToData(source: PixelMap, options: PackingOption): Promise<ArrayBuffer>; release(): Promise<void>; }
    function createImageSource(data: ArrayBuffer): ImageSource;
    function createImagePacker(): ImagePacker;
  }
  export default image;
}
declare module '@ohos/flutter_ohos' {
  import UIAbility from '@ohos.app.ability.UIAbility';
  import common from '@ohos.app.ability.common';
  export type Any = unknown;
  export interface FlutterPluginBinding { getBinaryMessenger(): object; getApplicationContext(): common.Context; }
  export interface AbilityPluginBinding { getAbility(): UIAbility; }
  export interface FlutterPlugin {
    getUniqueClassName(): string; onAttachedToEngine(binding: FlutterPluginBinding): void;
    onDetachedFromEngine(binding: FlutterPluginBinding): void;
  }
  export interface AbilityAware { onAttachedToAbility(binding: AbilityPluginBinding): void; onDetachedFromAbility(): void; }
  export interface MethodCall { method: string; argument(name: string): Any; }
  export interface MethodResult { success(value: Any): void; error(code: string, message: string, details: Any): void; notImplemented(): void; }
  export interface MethodCallHandler { onMethodCall(call: MethodCall, result: MethodResult): void; }
  export class MethodChannel {
    constructor(messenger: object, name: string);
    setMethodCallHandler(handler: MethodCallHandler | null): void;
    invokeMethod(method: string, argument: Any): void;
  }
}
