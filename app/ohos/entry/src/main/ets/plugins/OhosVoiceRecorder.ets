// 公开 OH AudioCapturer；格式/权限/麦克风行为仍须实际设备验证。
import audio from '@ohos.multimedia.audio';
import { VoiceFailure, VoiceNotice, VoiceResource, retiredVoice } from './VoiceTypes';
import { VoicePcm } from './VoicePcm';

export class OhosVoiceRecorder implements VoiceResource {
  private pcm: VoicePcm;
  private capturer?: audio.AudioCapturer;
  private opening?: Promise<void>;
  private closing?: Promise<void>;
  private closeRequested: boolean = false;
  private released: boolean = false;
  private startAttempted: boolean = false;
  private accepting: boolean = false;
  private discarded: boolean = false;
  private subscribed: boolean = false;
  private interruptSubscribed: boolean = false;
  private scheduled: boolean = false;
  private limitSent: boolean = false;
  private errorSent: boolean = false;
  private fault: boolean = false;
  private emit: (notice: VoiceNotice) => void;
  private current: () => boolean;
  private onReleased: () => void;
  private read: (buffer: ArrayBuffer) => void;
  private interrupt: (event: audio.InterruptEvent) => void;

  constructor(seconds: number, emit: (notice: VoiceNotice) => void, current: () => boolean,
    onReleased: () => void) {
    this.pcm = new VoicePcm(seconds); this.emit = emit; this.current = current; this.onReleased = onReleased;
    this.read = (buffer: ArrayBuffer): void => this.receive(buffer);
    this.interrupt = (event: audio.InterruptEvent): void => {
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_MUTE) {
        this.fault = true; this.accepting = false; this.deferUpdates();
      }
    };
  }

  start(): Promise<void> {
    if (!this.opening) this.opening = this.open();
    return this.opening;
  }

  private ensureCurrent(): void {
    if (this.closeRequested || !this.current()) throw retiredVoice();
  }

  private checkFormat(capturer: audio.AudioCapturer): void {
    const actual = capturer.getStreamInfoSync();
    if (actual.samplingRate !== audio.AudioSamplingRate.SAMPLE_RATE_16000 ||
      actual.channels !== audio.AudioChannel.CHANNEL_1 ||
      actual.sampleFormat !== audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE ||
      actual.encodingType !== audio.AudioEncodingType.ENCODING_TYPE_RAW) {
      throw new VoiceFailure('audio', '此设备没有提供 16 kHz 单声道 PCM16 录音。', 100);
    }
  }

  private async open(): Promise<void> {
    this.ensureCurrent();
    const options: audio.AudioCapturerOptions = {
      streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1, sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
      capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_MESSAGE, capturerFlags: 0 }
    };
    const created = await audio.createAudioCapturer(options);
    if (!created) throw new VoiceFailure('audio', '无法创建录音流。', 100);
    this.capturer = created; this.ensureCurrent(); this.checkFormat(created);
    created.on('readData', this.read); this.subscribed = true;
    created.on('audioInterrupt', this.interrupt); this.interruptSubscribed = true;
    this.accepting = true; this.startAttempted = true;
    await created.start();
    // readData may reach the length limit before the start Promise resolves.
    // That is a normal stop request, not a discarded session.
    if (this.discarded || !this.current()) throw retiredVoice();
    this.checkFormat(created);
    if (this.fault) throw new VoiceFailure('audio', '录音流已被中断。', 100);
  }

  private receive(buffer: ArrayBuffer): void {
    if (!this.accepting || this.discarded || !this.current()) return;
    try { this.pcm.append(buffer); } catch (_) { this.fault = true; }
    if (this.pcm.full || this.fault) this.accepting = false;
    // No AudioCapturer API, Flutter callback or I/O runs inside readData.
    this.deferUpdates();
  }

  private deferUpdates(): void {
    if (this.scheduled) return;
    this.scheduled = true;
    Promise.resolve().then(async (): Promise<void> => {
      this.scheduled = false;
      if (this.discarded || !this.current()) return;
      this.emit({ type: 'level', value: this.pcm.level });
      if (this.fault || this.pcm.full) {
        try { await this.close(); } catch (_) { this.fault = true; }
        if (this.discarded || !this.current()) return;
        if (this.fault && !this.errorSent) {
          this.errorSent = true; this.emit({ type: 'error', code: 100 }); this.emit({ type: 'end' });
        } else if (!this.fault && !this.limitSent) {
          this.limitSent = true; this.emit({ type: 'limit' });
        }
      }
    }).catch((): void => { this.fault = true; });
  }

  private close(): Promise<void> {
    this.closeRequested = true; this.accepting = false;
    if (!this.closing) {
      this.closing = this.closeNative().catch((error: Error): void => {
        this.closing = undefined; throw error as Error;
      });
    }
    return this.closing;
  }

  private async closeNative(): Promise<void> {
    try { await this.opening; } catch (_) { /* still release a partially created / started stream */ }
    if (this.released) return;
    const capturer = this.capturer;
    if (capturer) {
      if (this.subscribed) { try { capturer.off('readData', this.read); } catch (_) {} this.subscribed = false; }
      if (this.interruptSubscribed) { try { capturer.off('audioInterrupt'); } catch (_) {} this.interruptSubscribed = false; }
      if (this.startAttempted) {
        try { if (capturer.getOverflowCountSync() !== 0) this.fault = true; } catch (_) { this.fault = true; }
        try { await capturer.stop(); } catch (_) { this.fault = true; }
      }
      // A failed release keeps the global microphone lease. A later cancel may retry.
      try { await capturer.release(); }
      catch (_) { this.fault = true; throw new VoiceFailure('audio', '录音流尚未释放，请重试取消或重新打开应用。', 100); }
    }
    this.capturer = undefined; this.released = true; this.onReleased();
  }

  async finish(): Promise<Uint8Array | null> {
    await this.close();
    if (this.discarded) return null;
    if (this.fault) { this.pcm.discard(); throw new VoiceFailure('audio', '录音中断或发生丢帧，请重试。', 100); }
    const wav = this.pcm.wav(); this.pcm.discard(); return wav;
  }

  async cancel(): Promise<void> {
    this.discarded = true; this.pcm.discard(); await this.close();
  }
}
