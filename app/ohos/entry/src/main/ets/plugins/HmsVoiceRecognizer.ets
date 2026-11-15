// UNCOMPILED_HMS：仅此文件依赖用户 hms-contracts.md 的 CoreSpeechKit 合约。
// 使用 short / zh-CN / offline；境外行为与 isFinal/isLast 的真机时序仍未核实。
import type { speechRecognizer } from '@kit.CoreSpeechKit';
import { loadSpeechKit } from './HmsKits';
import { BusinessError } from '@ohos.base';
import { VoiceFailure, VoiceNotice, VoiceResource, retiredVoice } from './VoiceTypes';

interface HmsVoiceResult { isFinal: boolean; isLast: boolean; result: string; }

function voiceCode(code: number): number {
  return code === 1002200012 ? 9 : (code === 1002200002 || code === 1002200006 ? 8 : 5);
}

export class HmsVoiceRecognizer implements VoiceResource {
  private static engine?: speechRecognizer.SpeechRecognitionEngine;
  private static creating?: Promise<speechRecognizer.SpeechRecognitionEngine>;
  private static active?: HmsVoiceRecognizer;
  private static serial: number = 0;
  private static unavailable: boolean = false;
  private static poisoned: boolean = false;
  private nativeId: string;
  private opening?: Promise<void>;
  private closing?: Promise<void>;
  private cancelled: boolean = false;
  private released: boolean = false;
  private started: boolean = false;
  private finishing: boolean = false;
  private finalSent: boolean = false;
  private latest: string = '';
  private emit: (notice: VoiceNotice) => void;
  private current: () => boolean;
  private onReleased: () => void;

  constructor(emit: (notice: VoiceNotice) => void, current: () => boolean, onReleased: () => void) {
    this.emit = emit; this.current = current; this.onReleased = onReleased;
    HmsVoiceRecognizer.serial++;
    this.nativeId = 'dsh_' + HmsVoiceRecognizer.serial.toString(36);
  }

  private static async getEngine(): Promise<speechRecognizer.SpeechRecognitionEngine> {
    if (HmsVoiceRecognizer.poisoned) throw new VoiceFailure('recognizer', '语音服务尚未释放，请重新打开应用。', 5);
    if (HmsVoiceRecognizer.engine) return HmsVoiceRecognizer.engine;
    if (!HmsVoiceRecognizer.creating) {
      HmsVoiceRecognizer.creating = HmsVoiceRecognizer.create().finally((): void => {
        HmsVoiceRecognizer.creating = undefined;
      });
    }
    return HmsVoiceRecognizer.creating;
  }

  private static async create(): Promise<speechRecognizer.SpeechRecognitionEngine> {
    const params: speechRecognizer.CreateEngineParams = {
      language: 'zh-CN', online: 1, extraParams: { locate: 'CN', recognizerMode: 'short' }
    };
    const kit = await loadSpeechKit();
    const engine = await kit.createEngine(params);
    const listener: speechRecognizer.RecognitionListener = {
      onStart: (): void => {},
      onEvent: (): void => {},
      onResult: (id: string, result: HmsVoiceResult): void => {
        HmsVoiceRecognizer.active?.result(id, result.result, result.isLast);
      },
      onComplete: (id: string): void => HmsVoiceRecognizer.active?.complete(id),
      onError: (id: string, code: number): void => HmsVoiceRecognizer.active?.failed(id, code)
    };
    // No isBusy/start/finish/etc. before setListener.
    HmsVoiceRecognizer.engine = engine;
    try { engine.setListener(listener); }
    catch (error) {
      // Do not forget an allocation whose shutdown failed and create another singleton.
      try { engine.shutdown(); HmsVoiceRecognizer.engine = undefined; }
      catch (_) { HmsVoiceRecognizer.poisoned = true; }
      throw error as Error;
    }
    HmsVoiceRecognizer.unavailable = false; return engine;
  }

  static async available(): Promise<boolean> {
    // This tests factory availability, not microphone permission, geography, or recognition accuracy.
    // No startListening / microphone capture / user permission prompt occurs here.
    try { await HmsVoiceRecognizer.getEngine(); return true; }
    catch (_) { HmsVoiceRecognizer.unavailable = true; return false; }
  }

  static get unreliable(): boolean { return HmsVoiceRecognizer.unavailable; }

  static async releaseIdle(): Promise<void> {
    try { await HmsVoiceRecognizer.creating; } catch (_) {}
    if (HmsVoiceRecognizer.active) return;
    const engine = HmsVoiceRecognizer.engine;
    if (engine) { engine.shutdown(); HmsVoiceRecognizer.engine = undefined; HmsVoiceRecognizer.poisoned = false; }
  }

  start(): Promise<void> {
    if (!this.opening) this.opening = this.open().catch((error: Error): void => {
      if (error instanceof VoiceFailure) throw error as Error;
      const code = voiceCode((error as BusinessError).code);
      throw new VoiceFailure(code === 9 ? 'permission' : (code === 8 ? 'busy' : 'recognizer'),
        code === 9 ? '请先允许使用麦克风。' : '语音识别服务暂时不可用，请稍后重试。', code);
    });
    return this.opening;
  }

  private async open(): Promise<void> {
    if (HmsVoiceRecognizer.active) throw new VoiceFailure('busy', '语音识别服务仍在处理上一会话。', 8);
    HmsVoiceRecognizer.active = this;
    const engine = await HmsVoiceRecognizer.getEngine();
    if (this.cancelled || !this.current()) throw retiredVoice();
    const params: speechRecognizer.StartParams = {
      sessionId: this.nativeId,
      audioInfo: { audioType: 'pcm', sampleRate: 16000, sampleBit: 16, soundChannel: 1 },
      extraParams: { recognitionMode: 0, maxAudioDuration: 60000, recognizerOption: { enablePartialResult: true } }
    };
    this.started = true; engine.startListening(params);
    if (this.released && !this.cancelled) return;
    if (this.cancelled || !this.current()) throw retiredVoice();
  }

  private matches(id: string): boolean {
    return id === this.nativeId && HmsVoiceRecognizer.active === this && !this.released;
  }

  private result(id: string, text: string, last: boolean): void {
    if (!this.matches(id) || this.cancelled || !this.current() || this.finalSent) return;
    if (typeof text !== 'string' || text.length > 200000) { this.failed(id, 1002200011); return; }
    // Short utterance mode: keep the latest hypothesis verbatim. Do not invent segment concatenation.
    this.latest = text;
    if (last) { this.finalSent = true; this.emit({ type: 'final', text }); }
    else this.emit({ type: 'partial', text });
  }

  private release(): void {
    if (this.released) return;
    this.released = true;
    if (HmsVoiceRecognizer.active === this) HmsVoiceRecognizer.active = undefined;
    this.onReleased();
  }

  private complete(id: string): void {
    if (!this.matches(id)) return;
    const deliver = !this.cancelled && this.current();
    // Completion establishes that this task ended; retain the engine for another task.
    this.release();
    if (deliver) {
      if (!this.finalSent) { this.finalSent = true; this.emit({ type: 'final', text: this.latest }); }
      this.emit({ type: 'end' });
    }
  }

  private failed(id: string, code: number): void {
    if (!this.matches(id)) return;
    const deliver = !this.cancelled && this.current();
    this.cancelled = true;
    const mapped = voiceCode(code);
    if (mapped !== 9) HmsVoiceRecognizer.unavailable = true;
    // Run shutdown outside a native listener. Failed shutdown keeps the microphone lease.
    Promise.resolve().then(async (): Promise<void> => {
      try { await this.cancel(); } catch (_) {}
      if (deliver && this.current()) { this.emit({ type: 'error', code: mapped }); this.emit({ type: 'end' }); }
    }).catch((): void => {});
  }

  async finish(): Promise<Uint8Array | null> {
    try { await this.opening; } catch (error) { throw error as Error; }
    if (this.released || this.cancelled || this.finishing) return null;
    if (!this.current()) { await this.cancel(); return null; }
    const engine = HmsVoiceRecognizer.engine;
    if (!engine) throw new VoiceFailure('recognizer', '语音识别服务不可用。', 5);
    this.finishing = true; engine.finish(this.nativeId); return null;
  }

  cancel(): Promise<void> {
    this.cancelled = true;
    if (!this.closing) this.closing = this.close().catch((error: Error): void => {
      this.closing = undefined; throw error as Error;
    });
    return this.closing;
  }

  private async close(): Promise<void> {
    try { await this.opening; } catch (_) {}
    if (this.released) return;
    const engine = HmsVoiceRecognizer.engine;
    if (engine && HmsVoiceRecognizer.active === this) {
      if (this.started) { try { engine.cancel(this.nativeId); } catch (_) {} }
      try { engine.shutdown(); }
      catch (_) { throw new VoiceFailure('recognizer', '语音服务尚未释放，请重试取消或重新打开应用。', 5); }
      HmsVoiceRecognizer.engine = undefined;
      HmsVoiceRecognizer.poisoned = false;
    }
    this.release();
  }
}
