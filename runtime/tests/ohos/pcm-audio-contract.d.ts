// Host type fixture for the public AudioRenderer methods used by OhosPcmStream.
// This is NOT the HarmonyOS SDK and cannot establish ArkTS/API-26 compatibility.
// Public signatures: developer.huawei.com/consumer/en/doc/harmonyos-references/
// arkts-apis-audio-audiorenderer/ and arkts-apis-audio-i/ (checked 2026-11-14).
declare function canIUse(capability: string): boolean;
declare function setTimeout(callback: () => void, milliseconds: number): number;
declare function clearTimeout(id: number): void;

declare module '@ohos.base' {
  export interface BusinessError extends Error { code: number; }
}

declare module '@ohos.multimedia.audio' {
  namespace audio {
    enum AudioSamplingRate { SAMPLE_RATE_24000 = 24000, SAMPLE_RATE_16000 = 16000 }
    enum AudioChannel { CHANNEL_1 = 1 }
    enum AudioSampleFormat { SAMPLE_FORMAT_S16LE = 1 }
    enum AudioEncodingType { ENCODING_TYPE_RAW = 0 }
    enum StreamUsage { STREAM_USAGE_AUDIOBOOK = 12, STREAM_USAGE_VOICE_COMMUNICATION = 2 }
    enum DeviceType { EARPIECE = 1, SPEAKER = 2, DEFAULT = 1000 }
    enum InterruptMode { INDEPENDENT_MODE = 1 }
    enum AudioState { STATE_PREPARED = 1, STATE_RUNNING = 2, STATE_STOPPED = 3, STATE_RELEASED = 4, STATE_PAUSED = 5 }
    enum InterruptHint {
      INTERRUPT_HINT_RESUME = 1, INTERRUPT_HINT_PAUSE = 2, INTERRUPT_HINT_STOP = 3,
      INTERRUPT_HINT_DUCK = 4, INTERRUPT_HINT_UNDUCK = 5, INTERRUPT_HINT_MUTE = 6
    }
    enum AudioDataCallbackResult { VALID = 0, INVALID = -1 }
    interface InterruptEvent { hintType: InterruptHint; forceType: number; }
    interface AudioStreamDeviceChangeInfo { devices: unknown[]; changeReason: number; }
    interface AudioStreamInfo {
      samplingRate: AudioSamplingRate; channels: AudioChannel;
      sampleFormat: AudioSampleFormat; encodingType: AudioEncodingType;
    }
    interface AudioRendererOptions {
      streamInfo: AudioStreamInfo;
      rendererInfo: { usage: StreamUsage; rendererFlags: number; };
    }
    interface AudioRenderer {
      readonly state: AudioState;
      getStreamInfoSync(): AudioStreamInfo;
      getBufferSizeSync(): number;
      getAudioTimestampInfoSync(): AudioTimestampInfo;
      on(type: 'writeData', callback: (data: ArrayBuffer) => AudioDataCallbackResult | void): void;
      on(type: 'audioInterrupt', callback: (event: InterruptEvent) => void): void;
      on(type: 'stateChange', callback: (state: AudioState) => void): void;
      on(type: 'outputDeviceChangeWithInfo', callback: (event: AudioStreamDeviceChangeInfo) => void): void;
      off(type: 'writeData', callback?: (data: ArrayBuffer) => AudioDataCallbackResult | void): void;
      off(type: 'audioInterrupt', callback?: (event: InterruptEvent) => void): void;
      off(type: 'stateChange', callback?: (state: AudioState) => void): void;
      off(type: 'outputDeviceChangeWithInfo', callback?: (event: AudioStreamDeviceChangeInfo) => void): void;
      setDefaultOutputDevice(device: DeviceType): Promise<void>;
      setInterruptMode(mode: InterruptMode): Promise<void>;
      start(): Promise<void>;
      pause(): Promise<void>;
      flush(): Promise<void>;
      stop(): Promise<void>;
      release(): Promise<void>;
      drain(): Promise<void>;
      setVolume(volume: number): Promise<void>;
    }
    interface AudioTimestampInfo { readonly framePos: number; readonly timestamp: number; }
    function createAudioRenderer(options: AudioRendererOptions): Promise<AudioRenderer>;
    enum SourceType { SOURCE_TYPE_VOICE_COMMUNICATION = 7 }
    interface AudioCapturerOptions {
      streamInfo: AudioStreamInfo;
      capturerInfo: { source: SourceType; capturerFlags: number; };
    }
    interface AudioCapturer {
      getStreamInfoSync(): AudioStreamInfo;
      getOverflowCountSync(): number;
      on(type: 'readData', callback: (data: ArrayBuffer) => void): void;
      on(type: 'audioInterrupt', callback: (event: InterruptEvent) => void): void;
      off(type: 'readData', callback?: (data: ArrayBuffer) => void): void;
      off(type: 'audioInterrupt', callback?: (event: InterruptEvent) => void): void;
      start(): Promise<void>;
      stop(): Promise<void>;
      release(): Promise<void>;
    }
    function createAudioCapturer(options: AudioCapturerOptions): Promise<AudioCapturer>;
    // AudioSessionManager API12 activation and API20 default output, official
    // arkts-apis-audio-audiosessionmanager; explicit host fixture, not SDK.
    enum AudioConcurrencyMode { CONCURRENCY_DEFAULT = 0 }
    interface AudioSessionStrategy { concurrencyMode: AudioConcurrencyMode; }
    interface AudioSessionDeactivatedEvent { reason: number; }
    interface AudioSessionManager {
      isAudioSessionActivated(): boolean;
      getDefaultOutputDevice(): DeviceType;
      setDefaultOutputDevice(device: DeviceType): Promise<void>;
      activateAudioSession(strategy: AudioSessionStrategy): Promise<void>;
      deactivateAudioSession(): Promise<void>;
      on(type: 'audioSessionDeactivated', callback: (event: AudioSessionDeactivatedEvent) => void): void;
      off(type: 'audioSessionDeactivated', callback?: (event: AudioSessionDeactivatedEvent) => void): void;
    }
    interface AudioManager { getSessionManager(): AudioSessionManager; }
    function getAudioManager(): AudioManager;

  }
  export default audio;
}
