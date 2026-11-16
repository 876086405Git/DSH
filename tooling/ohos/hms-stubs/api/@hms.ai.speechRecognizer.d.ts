// 非官方，只检查调用方逻辑。来源：用户 C1 合同与公开 Core Speech API；最终以真实 HMS SDK 编译为准。
// NONOFFICIAL stub: user C1 plus public Core Speech API checked 2026-11-15.
// This is NOT an HMS SDK declaration. Message/result type names are local scaffolding.
declare namespace speechRecognizer {
  interface CreateEngineParams { language: string; online: number; extraParams?: Record<string, Object>; }
  interface AudioInfo { audioType: string; sampleRate: number; sampleBit: number; soundChannel: number; }
  interface StartParams { sessionId: string; audioInfo: AudioInfo; extraParams?: Record<string, Object>; }
  interface SpeechRecognitionResult { isFinal: boolean; isLast: boolean; result: string; }
  interface RecognitionListener {
    onStart(sessionId: string, eventMessage: string): void;
    onEvent(sessionId: string, eventCode: number, eventMessage: string): void;
    onResult(sessionId: string, result: SpeechRecognitionResult): void;
    onComplete(sessionId: string, eventMessage: string): void;
    onError(sessionId: string, errorCode: number, errorMessage: string): void;
  }
  interface SpeechRecognitionEngine {
    setListener(listener: RecognitionListener): void;
    startListening(params: StartParams): void;
    writeAudio(sessionId: string, audio: Uint8Array): void;
    isBusy(): boolean;
    finish(sessionId: string): void;
    cancel(sessionId: string): void;
    shutdown(): void;
  }
  function createEngine(params: CreateEngineParams): Promise<SpeechRecognitionEngine>;
}

export default speechRecognizer;
