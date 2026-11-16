// NONOFFICIAL minimum call surface, based on Huawei's textToSpeech API reference.
// https://developer.huawei.com/consumer/en/doc/harmonyos-references/hms-ai-texttospeech/
// Not an HMS SDK header or implementation; SDK 26 and device checks remain required.
declare namespace textToSpeech {
  interface CreateEngineParams { language: string; person: number; online: number; extraParams?: Record<string, Object>; }
  interface SpeakParams { requestId: string; extraParams?: Record<string, Object>; }
  interface StartResponse { audioType: string; sampleRate: number; sampleBit: number; audioChannel: number; compressRate: number; }
  interface CompleteResponse { type: number; message: string; }
  interface StopResponse { type: number; message: string; }
  interface SpeakListener {
    onStart(requestId: string, response: StartResponse): void;
    onComplete(requestId: string, response: CompleteResponse): void;
    onStop(requestId: string, response: StopResponse): void;
    onError(requestId: string, errorCode: number, errorMessage: string): void;
  }
  interface TextToSpeechEngine {
    setListener(listener: SpeakListener): void;
    speak(text: string, params: SpeakParams): void;
    stop(): void;
    shutdown(): void;
  }
  function createEngine(params: CreateEngineParams): Promise<TextToSpeechEngine>;
}
export default textToSpeech;
