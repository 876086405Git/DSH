// PCM activity only: no recording file, transcript or upload. SDK readData may
// reuse its buffer; compute a bounded frame statistic before returning.
import audio from '@ohos.multimedia.audio';
import { NativeMediaError } from './NativeMediaPolicy';

class ActivityGate {
  private floor: number = NaN;
  private loud: number = 0;
  private quiet: number = 0;
  private speaking: boolean = false;
  private playing: boolean = false;
  private settle: number = 0;
  setPlaying(value: boolean): void {
    if (value && !this.playing) this.settle = 20; // 400 ms of actual 20 ms PCM frames.
    this.playing = value; if (!value) { this.loud = 0; this.settle = 0; }
  }
  frame(level: number): boolean {
    if (Number.isNaN(this.floor)) this.floor = Math.min(level, -60);
    if (level < this.floor) this.floor += (level - this.floor) * 0.5;
    else if (!this.speaking && !this.playing) this.floor += (level - this.floor) * 0.01;
    // No AEC claim: VOICE_MESSAGE playback does not meet the SDK's 3A pairing.
    const start = Math.max(this.floor + (this.playing ? 30 : 15), this.playing ? -40 : -50);
    if (!this.speaking) {
      if (this.playing && this.settle > 0) { this.settle--; this.loud = 0; return false; }
      this.loud = level >= start ? this.loud + 1 : 0;
      if (this.loud >= (this.playing ? 10 : 6)) { this.speaking = true; this.loud = 0; this.quiet = 0; }
    } else {
      this.quiet = level < start - 6 ? this.quiet + 20 : 0;
      if (this.quiet >= 700) { this.speaking = false; this.quiet = 0; }
    }
    return this.speaking;
  }
}

export class OhosSpeechActivity {
  private capturer?: audio.AudioCapturer;
  private opening?: Promise<void>;
  private closing?: Promise<void>;
  private stopped: boolean = false;
  private released: boolean = false;
  private started: boolean = false;
  private subscribed: boolean = false;
  private interrupted: boolean = false;
  private queued: boolean = false;
  private desired: boolean = false;
  private edges: boolean[] = [];
  private count: number = 0;
  private power: number = 0;
  private gate: ActivityGate = new ActivityGate();
  private current: () => boolean;
  private edge: (speaking: boolean) => void;
  private fault: () => void;
  private releaseToken: () => void;
  private read: (buffer: ArrayBuffer) => void;
  private interrupt: (event: audio.InterruptEvent) => void;
  constructor(current: () => boolean, edge: (speaking: boolean) => void,
    fault: () => void, releaseToken: () => void) {
    this.current = current; this.edge = edge; this.fault = fault; this.releaseToken = releaseToken;
    this.read = (buffer: ArrayBuffer): void => this.receive(buffer);
    this.interrupt = (event: audio.InterruptEvent): void => {
      if ([audio.InterruptHint.INTERRUPT_HINT_STOP, audio.InterruptHint.INTERRUPT_HINT_PAUSE,
        audio.InterruptHint.INTERRUPT_HINT_MUTE].includes(event.hintType)) {
        this.interrupted = true; this.defer();
      }
    };
  }
  setPlaying(value: boolean): void { this.gate.setPlaying(value); }
  start(): Promise<void> { if (!this.opening) this.opening = this.open(); return this.opening; }
  private check(): void {
    if (this.stopped || !this.current()) throw new NativeMediaError('stale-owner', '语音活动检测已退役。');
  }
  private format(capturer: audio.AudioCapturer): void {
    const value = capturer.getStreamInfoSync();
    if (value.samplingRate !== audio.AudioSamplingRate.SAMPLE_RATE_16000 || value.channels !== audio.AudioChannel.CHANNEL_1 ||
      value.sampleFormat !== audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE || value.encodingType !== audio.AudioEncodingType.ENCODING_TYPE_RAW) {
      throw new NativeMediaError('capture', '设备未提供16kHz单声道PCM16。');
    }
  }
  private async open(): Promise<void> {
    this.check();
    const options: audio.AudioCapturerOptions = {
      streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000, channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
      capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION, capturerFlags: 0 }
    };
    const capturer = await audio.createAudioCapturer(options);
    if (!capturer) throw new NativeMediaError('capture', '无法创建语音活动采集。');
    this.capturer = capturer; this.check(); this.format(capturer);
    capturer.on('readData', this.read); this.subscribed = true;
    capturer.on('audioInterrupt', this.interrupt);
    this.started = true; await capturer.start(); this.check(); this.format(capturer);
    if (this.interrupted) throw new NativeMediaError('capture', '语音采集已被中断。');
  }
  private receive(buffer: ArrayBuffer): void {
    if (this.stopped || this.interrupted || !this.current()) return;
    // Bound callback CPU; a malformed/unbounded callback is an explicit failure,
    // never a silent partial frame that could produce a false activity edge.
    if (buffer.byteLength % 2 !== 0 || buffer.byteLength > 65536) { this.interrupted = true; this.defer(); return; }
    const samples = new DataView(buffer);
    for (let offset = 0; offset < buffer.byteLength; offset += 2) {
      const value = samples.getInt16(offset, true); this.power += value * value; this.count++;
      if (this.count === 320) {
        const rms = Math.sqrt(this.power / 320) / 32768;
        const next = this.gate.frame(rms <= 1e-5 ? -100 : 20 * Math.log10(rms));
        if (next !== this.desired) {
          if (this.edges.length >= 2) { this.interrupted = true; this.defer(); return; }
          this.desired = next; this.edges.push(next);
        }
        this.count = 0; this.power = 0;
      }
    }
    this.defer();
  }
  private defer(): void {
    if (this.queued) return; this.queued = true;
    Promise.resolve().then((): void => {
      this.queued = false;
      if (this.stopped || !this.current()) return;
      if (this.interrupted) { this.fault(); return; }
      const edges = this.edges; this.edges = [];
      for (const value of edges) { if (this.stopped || !this.current()) return; this.edge(value); }
    }).catch((): void => {});
  }
  stop(): Promise<void> {
    this.stopped = true;
    if (!this.closing) this.closing = this.close().catch((error: Error): void => { this.closing = undefined; throw error as Error; });
    return this.closing;
  }
  private async close(): Promise<void> {
    try { await this.opening; } catch (_) {}
    if (this.released) return;
    const capturer = this.capturer;
    if (capturer) {
      if (this.subscribed) {
        try { capturer.off('readData', this.read); } catch (_) {}
        try { capturer.off('audioInterrupt'); } catch (_) {}
        this.subscribed = false;
      }
      if (this.started) { try { await capturer.stop(); } catch (_) {} }
      // No releaseToken on rejection; later explicit stop/cancel may retry.
      await capturer.release();
    }
    this.capturer = undefined; this.released = true; this.count = 0; this.power = 0; this.edges = [];
    this.releaseToken();
  }
}
