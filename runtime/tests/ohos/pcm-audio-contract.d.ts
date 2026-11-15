// Host type fixture for the public AudioRenderer methods used by OhosPcmStream.
// This is NOT the HarmonyOS SDK and cannot establish ArkTS/API-26 compatibility.
// Public signatures: developer.huawei.com/consumer/en/doc/harmonyos-references/
// arkts-apis-audio-audiorenderer/ and arkts-apis-audio-i/ (checked 2026-11-14).
declare function canIUse(capability: string): boolean;
declare function setTimeout(callback: () => void, milliseconds: number): number;
declare function clearTimeout(id: number): void;

declare module '@ohos.multimedia.audio' {
  namespace audio {
    enum AudioSamplingRate { SAMPLE_RATE_24000 = 24000 }
    enum AudioChannel { CHANNEL_1 = 1 }
    enum AudioSampleFormat { SAMPLE_FORMAT_S16LE = 1 }
    enum AudioEncodingType { ENCODING_TYPE_RAW = 0 }
    enum StreamUsage { STREAM_USAGE_AUDIOBOOK = 12 }
    enum InterruptMode { INDEPENDENT_MODE = 1 }
    enum AudioState { STATE_PREPARED = 1, STATE_RUNNING = 2, STATE_STOPPED = 3, STATE_RELEASED = 4, STATE_PAUSED = 5 }
    enum InterruptHint {
      INTERRUPT_HINT_RESUME = 1, INTERRUPT_HINT_PAUSE = 2, INTERRUPT_HINT_STOP = 3,
      INTERRUPT_HINT_DUCK = 4, INTERRUPT_HINT_UNDUCK = 5, INTERRUPT_HINT_MUTE = 6
    }
    enum AudioDataCallbackResult { VALID = 0, INVALID = -1 }
    interface InterruptEvent { hintType: InterruptHint; forceType: number; }
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
      on(type: 'writeData', callback: (data: ArrayBuffer) => AudioDataCallbackResult | void): void;
      on(type: 'audioInterrupt', callback: (event: InterruptEvent) => void): void;
      on(type: 'stateChange', callback: (state: AudioState) => void): void;
      off(type: 'writeData', callback?: (data: ArrayBuffer) => AudioDataCallbackResult | void): void;
      off(type: 'audioInterrupt', callback?: (event: InterruptEvent) => void): void;
      off(type: 'stateChange', callback?: (state: AudioState) => void): void;
      setInterruptMode(mode: InterruptMode): Promise<void>;
      start(): Promise<void>;
      pause(): Promise<void>;
      flush(): Promise<void>;
      stop(): Promise<void>;
      release(): Promise<void>;
      drain(): Promise<void>;
      setVolume(volume: number): Promise<void>;
    }
    function createAudioRenderer(options: AudioRendererOptions): Promise<AudioRenderer>;
  }
  export default audio;
}
