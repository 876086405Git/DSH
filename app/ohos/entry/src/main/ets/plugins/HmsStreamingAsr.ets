// External 16kHz PCM captions. Public Core Speech API; UNCOMPILED_HMS/device unverified.
import type { speechRecognizer } from '@kit.CoreSpeechKit';
import { loadSpeechKit, SpeechKit } from './HmsKits';
import { HmsVoiceRecognizer } from './HmsVoiceRecognizer';
import { HmsAsrLease, HmsAsrToken } from './HmsAsrLease';

export interface CaptionNotice { type: string; text?: string; reason?: string; }
interface CaptionRecognizerOption { enablePartialResult: boolean; }

class CaptionListener implements speechRecognizer.RecognitionListener {
  private owner: HmsStreamingAsr;
  constructor(owner: HmsStreamingAsr) { this.owner = owner; }
  onStart(id: string, _message: string): void { this.owner.started(id); }
  onEvent(_id: string, _code: number, _message: string): void {}
  onResult(id: string, result: speechRecognizer.SpeechRecognitionResult): void { this.owner.result(id, result); }
  onComplete(id: string, _message: string): void { this.owner.completed(id); }
  onError(id: string, code: number, _message: string): void { this.owner.failed(id, code); }
}

export class HmsStreamingAsr {
  private static serial: number = 0;
  private readonly token: HmsAsrToken = new HmsAsrToken();
  private readonly emit: (notice: CaptionNotice) => void;
  private readonly current: () => boolean;
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private opening: Promise<void> | null = null;
  private creating: Promise<void> | null = null;
  private closing: Promise<void> | null = null;
  private finalizing: Promise<void> | null = null;
  private resolveStart: (() => void) | null = null;
  private rejectStart: ((error: Error) => void) | null = null;
  private resolveFinish: (() => void) | null = null;
  private rejectFinish: ((error: Error) => void) | null = null;
  private live: boolean = true;
  private ready: boolean = false;
  private finishing: boolean = false;
  private finishRequested: boolean = false;
  private rotating: boolean = false;
  private errorSent: boolean = false;
  private sessionId: string = '';
  private samples: number = 0;
  private timer: number = -1;
  private queue: Array<Uint8Array> = [];
  private latest: string = '';

  constructor(emit: (notice: CaptionNotice) => void, current: () => boolean) {
    this.emit = emit; this.current = current;
  }

  start(): Promise<void> {
    if (this.opening !== null) return this.opening;
    if (!this.live || !this.current()) return Promise.reject(new Error('retired'));
    this.opening = new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      this.resolveStart = resolve; this.rejectStart = reject;
    });
    this.creating = this.acquire().catch((error: Error): void => {
      this.rejectOpening(error); this.fail(error.message);
    });
    return this.opening;
  }

  private async acquire(): Promise<void> {
    if (!canIUse('SystemCapability.AI.SpeechRecognizer')) throw new Error('unavailable');
    // A prewarmed ordinary dictation engine may be released; an active one may not.
    await HmsVoiceRecognizer.releaseIdle();
    if (!this.live || !this.current()) return;
    if (!HmsAsrLease.claim(this.token)) throw new Error('busy');
    const kit: SpeechKit = await loadSpeechKit();
    if (!this.live || !this.current()) return;
    const params: speechRecognizer.CreateEngineParams = {
      language: 'zh-CN', online: 1, extraParams: { locate: 'CN', recognizerMode: 'long' }
    };
    const engine: speechRecognizer.SpeechRecognitionEngine = await kit.createEngine(params);
    this.engine = engine;
    engine.setListener(new CaptionListener(this));
    if (!this.live || !this.current()) return;
    this.startSession();
  }

  private startSession(): void {
    const engine: speechRecognizer.SpeechRecognitionEngine | null = this.engine;
    if (!this.live || !this.current() || engine === null) return;
    this.sessionId = 'dsh_caption_' + (++HmsStreamingAsr.serial).toString(36);
    this.ready = false; this.finishRequested = false;
    this.samples = 0; this.latest = '';
    const option: CaptionRecognizerOption = { enablePartialResult: true };
    const params: speechRecognizer.StartParams = {
      sessionId: this.sessionId,
      audioInfo: { audioType: 'pcm', sampleRate: 16000, sampleBit: 16, soundChannel: 1 },
      extraParams: { recognitionMode: 1, maxAudioDuration: 60000, recognizerOption: option }
    };
    engine.startListening(params);
  }

  private matches(id: string): boolean {
    return id === this.sessionId && this.live && this.current();
  }

  started(id: string): void {
    if (!this.matches(id)) return;
    this.ready = true; this.rotating = false;
    const resolve: (() => void) | null = this.resolveStart;
    this.resolveStart = null; this.rejectStart = null; resolve?.();
    this.schedule();
  }

  result(id: string, result: speechRecognizer.SpeechRecognitionResult): void {
    if (!this.matches(id)) return;
    if (result.result.length > 200000) { this.fail('text-limit'); return; }
    this.latest = result.isFinal ? '' : result.result;
    this.emit({ type: result.isFinal ? 'final' : 'partial', text: result.result });
    // isFinal is a sentence boundary, isLast is not a physical release signal.
  }

  failed(id: string, code: number): void {
    if (this.matches(id)) this.fail('recognizer-' + code.toString());
  }

  completed(id: string): void {
    if (!this.matches(id)) return;
    if (this.latest.length > 0) this.emit({ type: 'final', text: this.latest });
    this.latest = ''; this.ready = false; this.sessionId = '';
    if (this.rotating && (!this.finishing || this.queue.length > 0)) {
      // Never call the service again from its own result/completion listener.
      Promise.resolve().then((): void => {
        if (this.live && this.current()) this.startSession();
      }).catch((error: Error): void => this.fail(error.message));
      return;
    }
    if (!this.finishing) { this.fail('ended'); return; }
    this.live = false; this.clearQueue();
    this.close().then((): void => this.resolveFinish?.(), (error: Error): void => this.rejectFinish?.(error));
  }

  feed(pcm: Uint8Array): void {
    if (!this.live || !this.current() || this.finishing) throw new Error('retired');
    if (pcm.byteLength !== 640) { this.fail('format'); throw new Error('format'); }
    if (this.queue.length >= 50) { this.fail('queue'); throw new Error('queue'); }
    this.queue.push(pcm.slice()); this.schedule();
  }

  private schedule(): void {
    if (this.timer !== -1 || !this.live || !this.current() || !this.ready || this.rotating) return;
    if (this.queue.length === 0) {
      if (this.finishing) this.requestFinish();
      return;
    }
    // Core Speech specifies 640 bytes per 20ms. No burst catch-up after a pause.
    this.timer = setTimeout((): void => {
      this.timer = -1;
      const engine: speechRecognizer.SpeechRecognitionEngine | null = this.engine;
      if (!this.live || !this.current() || !this.ready || engine === null) return;
      const pcm: Uint8Array = this.queue.shift()!;
      try { engine.writeAudio(this.sessionId, pcm); }
      catch (_) { this.fail('write'); return; }
      this.samples += 320;
      // The writeAudio API still states 60s even though long mode permits 8h.
      // Bound each input session; transition latency remains in the finite queue.
      if (this.samples >= 55000 * 16 && !this.finishing) {
        this.rotating = true; this.ready = false; this.requestFinish(); return;
      }
      this.schedule();
    }, 20);
  }

  private requestFinish(): void {
    if (this.finishRequested || this.engine === null || !this.live || !this.current()) return;
    this.finishRequested = true;
    try { this.engine.finish(this.sessionId); }
    catch (_) { this.fail('finish'); }
  }

  stop(finalize: boolean): Promise<void> {
    if (!finalize || (!this.ready && !this.rotating) || !this.live) {
      this.live = false; this.ready = false; this.clearQueue();
      this.rejectOpening(new Error('cancelled'));
      this.rejectFinish?.(new Error('cancelled'));
      return this.close();
    }
    if (this.finalizing !== null) return this.finalizing;
    this.finishing = true;
    this.finalizing = new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      this.resolveFinish = resolve; this.rejectFinish = reject;
    });
    this.schedule(); return this.finalizing;
  }

  private rejectOpening(error: Error): void {
    const reject: ((error: Error) => void) | null = this.rejectStart;
    this.rejectStart = null; this.resolveStart = null; reject?.(error);
  }

  private fail(reason: string): void {
    if (!this.live) return;
    this.live = false; this.ready = false; this.clearQueue();
    const error: Error = new Error(reason);
    this.rejectOpening(error); this.rejectFinish?.(error);
    if (!this.errorSent && this.current()) {
      this.errorSent = true; this.emit({ type: 'error', reason });
    }
    this.close().catch((): void => {});
  }

  private clearQueue(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    this.queue = []; this.latest = '';
  }

  private close(): Promise<void> {
    if (this.closing !== null) return this.closing;
    const work: Promise<void> = Promise.resolve().then(async (): Promise<void> => {
      try { await this.creating; } catch (_) {}
      const engine: speechRecognizer.SpeechRecognitionEngine | null = this.engine;
      if (engine !== null) {
        if (this.sessionId.length > 0) { try { engine.cancel(this.sessionId); } catch (_) {} }
        // Successful shutdown is the physical release boundary. A failure keeps
        // engine and token for stop retry and prevents a second ASR allocation.
        engine.shutdown(); this.engine = null;
      }
      HmsAsrLease.release(this.token);
    });
    this.closing = work;
    work.then((): void => { if (this.closing === work) this.closing = null; },
      (): void => { if (this.closing === work) this.closing = null; });
    return work;
  }
}
