// Explicit lazy-loader type boundary for host TS only. Runtime tests execute the real HmsKits.ets.
import type { speechRecognizer } from '@kit.CoreSpeechKit';
export class SpeechKit {
  createEngine: (params: speechRecognizer.CreateEngineParams) => Promise<speechRecognizer.SpeechRecognitionEngine>;
}
export function loadSpeechKit(): Promise<SpeechKit>;
