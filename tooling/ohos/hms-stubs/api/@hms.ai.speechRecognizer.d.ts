// 非官方，只为检查调用方逻辑。来源：用户 hms-contracts.md；最终以真实 HMS SDK 编译为准。
// NONOFFICIAL stub: derived solely from user hms-contracts.md section C1.
// This is NOT an HMS SDK declaration. Message/result type names are local scaffolding.
declare namespace speechRecognizer {
  interface CreateEngineParams { language: string; online: number; extraParams?: Record<string, Object>; }
  interface AudioInfo { audioType: string; sampleRate: number; sampleBit: number; soundChannel: number; }
  interface StartParams { sessionId: string; audioInfo: AudioInfo; extraParams?: Record<string, Object>; }
  interface ContractResult { isFinal: boolean; isLast: boolean; result: string; }
  interface RecognitionListener {
    onStart(sessionId: string, eventMessage: Object): void;
    onEvent(sessionId: string, eventCode: number, eventMessage: Object): void;
    onResult(sessionId: string, result: ContractResult): void;
    onComplete(sessionId: string, eventMessage: Object): void;
    onError(sessionId: string, errorCode: number, errorMessage: Object): void;
  }
  interface SpeechRecognitionEngine {
    setListener(listener: RecognitionListener): void;
    startListening(params: StartParams): void;
    finish(sessionId: string): void;
    cancel(sessionId: string): void;
    shutdown(): void;
  }
  function createEngine(params: CreateEngineParams): Promise<SpeechRecognitionEngine>;
}

export default speechRecognizer;
