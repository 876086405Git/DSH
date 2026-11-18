// Host-only declarations transcribed from public API pages in media-video.md.
// These catch interface/type mistakes; they are not SDK headers or ArkTS proof.
declare function setTimeout(callback: () => void, milliseconds: number): number;
declare function clearTimeout(id: number): void;

declare module '@ohos.base' {
  export interface BusinessError extends Error { code: number; }
}
declare module '@ohos.app.ability.common' {
  namespace common {
    interface Context { filesDir: string; cacheDir: string; tempDir: string; }
    interface UIAbilityContext extends Context {}
  }
  export default common;
}
declare module '@ohos.app.ability.UIAbility' {
  import common from '@ohos.app.ability.common';
  export default class UIAbility { context: common.UIAbilityContext; }
}
declare module '@ohos.file.fs' {
  namespace fs {
    interface Stat { size: number; isFile(): boolean; }
    function stat(fd: number): Promise<Stat>;
    function close(fd: number): Promise<void>;
  }
  export default fs;
}
declare module '@ohos.multimedia.audio' {
  namespace audio {
    enum StreamUsage { STREAM_USAGE_MOVIE = 10 }
    enum InterruptMode { SHARE_MODE = 0, INDEPENDENT_MODE = 1 }
    enum InterruptType { INTERRUPT_TYPE_BEGIN = 1, INTERRUPT_TYPE_END = 2 }
    enum InterruptForceType { INTERRUPT_FORCE = 0, INTERRUPT_SHARE = 1 }
    enum InterruptHint { INTERRUPT_HINT_NONE = 0, INTERRUPT_HINT_RESUME = 1,
      INTERRUPT_HINT_PAUSE = 2, INTERRUPT_HINT_STOP = 3, INTERRUPT_HINT_DUCK = 4, INTERRUPT_HINT_UNDUCK = 5 }
    interface InterruptEvent { eventType: InterruptType; forceType: InterruptForceType; hintType: InterruptHint; }
    interface AudioRendererInfo { usage: StreamUsage; rendererFlags: number; }
  }
  export default audio;
}
declare module '@ohos.multimedia.image' {
  namespace image {
    interface Size { width: number; height: number; }
    interface ImageInfo { size: Size; }
    interface PixelMap { getImageInfo(): Promise<ImageInfo>; release(): Promise<void>; }
    interface PackingOption { format: string; quality: number; }
    interface ImagePacker {
      packToData(source: PixelMap, options: PackingOption): Promise<ArrayBuffer>;
      release(): Promise<void>;
    }
    function createImagePacker(): ImagePacker;
  }
  export default image;
}
declare module '@ohos.multimedia.media' {
  import audio from '@ohos.multimedia.audio';
  import image from '@ohos.multimedia.image';
  import { BusinessError } from '@ohos.base';
  namespace media {
    type AVPlayerState = 'idle' | 'initialized' | 'prepared' | 'playing' | 'paused' |
      'completed' | 'stopped' | 'released' | 'error';
    interface AVFileDescriptor { fd: number; offset?: number; length?: number; }
    enum SeekMode { SEEK_NEXT_SYNC = 0, SEEK_PREV_SYNC = 1, SEEK_CLOSEST = 2 }
    enum AVImageQueryOptions { AV_IMAGE_QUERY_NEXT_SYNC = 0, AV_IMAGE_QUERY_PREVIOUS_SYNC = 1,
      AV_IMAGE_QUERY_CLOSEST_SYNC = 2, AV_IMAGE_QUERY_CLOSEST = 3 }
    interface PixelMapParams { width?: number; height?: number; }
    interface AVMetadata { videoWidth?: string; videoHeight?: string; }
    interface AVPlayer {
      readonly state: AVPlayerState;
      readonly width: number; readonly height: number; readonly duration: number; readonly currentTime: number;
      fdSrc: AVFileDescriptor; surfaceId: string; audioRendererInfo: audio.AudioRendererInfo;
      audioInterruptMode: audio.InterruptMode; loop: boolean;
      prepare(): Promise<void>; play(): Promise<void>; pause(): Promise<void>; release(): Promise<void>;
      setVolume(volume: number): void; seek(timeMs: number, mode?: SeekMode): void;
      on(event: 'error', callback: (error: BusinessError) => void): void;
      on(event: 'stateChange', callback: (state: AVPlayerState, reason: number) => void): void;
      on(event: 'audioInterrupt', callback: (event: audio.InterruptEvent) => void): void;
      off(event: 'stateChange' | 'error' | 'audioInterrupt'): void;
    }
    interface AVMetadataExtractor { fdSrc: AVFileDescriptor; fetchMetadata(): Promise<AVMetadata>; release(): Promise<void>; }
    interface AVImageGenerator {
      fdSrc: AVFileDescriptor;
      fetchFrameByTime(timeUs: number, option: AVImageQueryOptions, params: PixelMapParams): Promise<image.PixelMap>;
      release(): Promise<void>;
    }
    function createAVPlayer(): Promise<AVPlayer>;
    function createAVMetadataExtractor(): Promise<AVMetadataExtractor>;
    function createAVImageGenerator(): Promise<AVImageGenerator>;
  }
  export default media;
}
declare module '@ohos/flutter_ohos' {
  import UIAbility from '@ohos.app.ability.UIAbility';
  import common from '@ohos.app.ability.common';
  export type Any = unknown;
  export interface SurfaceTextureEntry { getTextureId(): number; getSurfaceId(): number; }
  export interface TextureRegistry {
    getTextureId(): number; registerTexture(id: number): SurfaceTextureEntry;
    setTextureBufferSize(id: number, width: number, height: number): void; unregisterTexture(id: number): void;
  }
  export interface FlutterPluginBinding {
    getApplicationContext(): common.Context; getBinaryMessenger(): object; getTextureRegistry(): TextureRegistry;
  }
  export interface AbilityPluginBinding { getAbility(): UIAbility; }
  export interface FlutterPlugin {
    getUniqueClassName(): string;
    onAttachedToEngine(binding: FlutterPluginBinding): void; onDetachedFromEngine(binding: FlutterPluginBinding): void;
  }
  export interface AbilityAware {
    onAttachedToAbility(binding: AbilityPluginBinding): void; onDetachedFromAbility(): void;
  }
  export interface MethodCall { method: string; argument(name: string): Any; }
  export interface MethodResult {
    success(value: Any): void; error(code: string, message: string, details: Any): void; notImplemented(): void;
  }
  export interface MethodCallHandler { onMethodCall(call: MethodCall, result: MethodResult): void; }
  export class MethodChannel {
    constructor(messenger: object, name: string);
    setMethodCallHandler(handler: MethodCallHandler | null): void;
  }
}
