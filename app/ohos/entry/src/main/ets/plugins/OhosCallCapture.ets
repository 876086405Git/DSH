// Communication-source capture. AEC and device behavior are not device-verified.
import audio from '@ohos.multimedia.audio';
import systemDateTime from '@ohos.systemDateTime';
import { CallEnergyGate, CallEdge } from './CallEnergyGate';
import { VoiceFailure, retiredVoice } from './VoiceTypes';
import { VoicePcm } from './VoicePcm';
import { VoicePcmTap, VoicePcmTapToken } from './VoicePcmTap';

export interface CallCaptureListener {
  speechStart: (over: boolean) => void;
  utterance: (wav: Uint8Array, ms: number) => void;
  level: (value: number) => void;
  error: (reason: string) => void;
}
interface CallNotice {
  epoch: number;
  over?: boolean;
  level?: number;
  pcm?: VoicePcm;
}
interface CallTapFrame {
  epoch: number;
  tap: VoicePcmTapToken;
  bytes: Uint8Array;
}

export class OhosCallCapture {
  bargeIn: boolean = true;
  private gate: CallEnergyGate = new CallEnergyGate(false); // AEC requested, not proven active.
  private capturer?: audio.AudioCapturer;
  private opening?: Promise<void>;
  private closing?: Promise<void>;
  private stopped: boolean = false;
  private released: boolean = false;
  private started: boolean = false;
  private running: boolean = false;
  private subscribed: boolean = false;
  private interruptSubscribed: boolean = false;
  private fault: boolean = false;
  private errorSent: boolean = false;
  private scheduled: boolean = false;
  private mutedValue: boolean = false;
  private playing: boolean = false;
  private epoch: number = 0;
  private frame: Uint8Array = new Uint8Array(640);
  private filled: number = 0;
  private frameTap?: VoicePcmTapToken;
  private lastTap?: VoicePcmTapToken;
  private preroll: Uint8Array[] = [];
  private utterance?: VoicePcm;
  private tick: number = 0;
  private mutedBytes: number = 0;
  private notices: CallNotice[] = [];
  private tapFrames: CallTapFrame[] = [];
  private current: () => boolean;
  private listener: CallCaptureListener;
  private releaseToken: () => void;
  private read: (buffer: ArrayBuffer) => void;
  private interrupt: (event: audio.InterruptEvent) => void;

  constructor(current: () => boolean, listener: CallCaptureListener, releaseToken: () => void) {
    this.current = current; this.listener = listener; this.releaseToken = releaseToken;
    this.read = (buffer: ArrayBuffer): void => this.receive(buffer);
    this.interrupt = (event: audio.InterruptEvent): void => {
      if ([audio.InterruptHint.INTERRUPT_HINT_STOP, audio.InterruptHint.INTERRUPT_HINT_PAUSE,
        audio.InterruptHint.INTERRUPT_HINT_MUTE].includes(event.hintType)) this.fail();
    };
  }
  get muted(): boolean { return this.mutedValue; }
  set muted(value: boolean) {
    if (this.mutedValue === value) return;
    this.mutedValue = value; this.epoch++; this.clearAudio();
    if (!this.stopped && this.current()) {
      const tap: VoicePcmTapToken | undefined = VoicePcmTap.current('call');
      if (tap) { this.lastTap = tap; VoicePcmTap.reset(tap, value ? 'muted' : 'resumed'); }
    }
  }
  set pause(value: string) { this.gate.pause = value; }
  setPlaying(value: boolean): void {
    this.playing = value; this.gate.setPlaying(value, systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false));
  }
  start(): Promise<void> { if (!this.opening) this.opening = this.open(); return this.opening; }
  private ensureCurrent(): void { if (this.stopped || !this.current()) throw retiredVoice(); }
  private format(capturer: audio.AudioCapturer): void {
    const value: audio.AudioStreamInfo = capturer.getStreamInfoSync();
    if (value.samplingRate !== audio.AudioSamplingRate.SAMPLE_RATE_16000 || value.channels !== audio.AudioChannel.CHANNEL_1 ||
      value.sampleFormat !== audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE || value.encodingType !== audio.AudioEncodingType.ENCODING_TYPE_RAW) {
      throw new VoiceFailure('audio', '设备未提供16kHz单声道PCM16通话录音。', 100);
    }
  }
  private async open(): Promise<void> {
    this.ensureCurrent();
    const options: audio.AudioCapturerOptions = {
      streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000, channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
      capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION, capturerFlags: 0 }
    };
    const capturer: audio.AudioCapturer = await audio.createAudioCapturer(options);
    this.capturer = capturer; this.ensureCurrent(); this.format(capturer);
    capturer.on('readData', this.read); this.subscribed = true;
    capturer.on('audioInterrupt', this.interrupt); this.interruptSubscribed = true;
    this.started = true; await capturer.start(); this.ensureCurrent(); this.format(capturer);
    if (this.fault) throw new VoiceFailure('audio', '通话录音已被中断。', 100);
    this.running = true; this.defer();
  }
  private clearAudio(): void {
    this.filled = 0; this.frame.fill(0); this.frameTap = undefined; this.preroll = [];
    this.utterance?.discard(); this.utterance = undefined; this.gate.reset(); this.mutedBytes = 0;
    for (const notice of this.notices) notice.pcm?.discard();
    this.notices = [];
    for (const frame of this.tapFrames) frame.bytes.fill(0);
    this.tapFrames = [];
  }
  private fail(): void { this.fault = true; this.clearAudio(); this.defer(); }
  private queue(notice: CallNotice): void {
    if (this.notices.length >= 128) { notice.pcm?.discard(); this.fail(); return; }
    this.notices.push(notice); this.defer();
  }
  private receive(buffer: ArrayBuffer): void {
    if (this.stopped || this.fault || !this.current()) return;
    if (buffer.byteLength % 2 !== 0 || buffer.byteLength > 65536) { this.fail(); return; }
    // Check SDK overflow before any tap delivery queued by these frames.
    this.defer();
    if (this.mutedValue) {
      this.mutedBytes += buffer.byteLength;
      if (this.mutedBytes >= 1280) { this.mutedBytes %= 1280; this.queue({ epoch: this.epoch, level: 0 }); }
      return;
    }
    const bytes: Uint8Array = new Uint8Array(buffer);
    let offset: number = 0;
    while (offset < bytes.length && !this.fault) {
      if (this.filled === 0) {
        this.frameTap = VoicePcmTap.current('call'); if (this.frameTap) this.lastTap = this.frameTap;
      }
      const take: number = Math.min(bytes.length - offset, 640 - this.filled);
      this.frame.set(bytes.subarray(offset, offset + take), this.filled); offset += take; this.filled += take;
      if (this.filled === 640) { this.filled = 0; this.consume(); }
    }
  }
  private consume(): void {
    const epoch: number = this.epoch;
    const level: number = CallEnergyGate.levelOf(this.frame);
    if (this.frameTap) {
      // The SDK may invoke readData before its start Promise settles. Keep the
      // initial syllable, but admit it only after start and overflow validation.
      if (this.tapFrames.length >= 128) { this.fail(); return; }
      this.tapFrames.push({ epoch: epoch, tap: this.frameTap, bytes: this.frame.slice() });
    }
    if (++this.tick % 2 === 0) this.queue({ epoch: epoch, level: Math.max(0, Math.min(1, (level + 60) / 50)) });
    const edge: CallEdge = this.gate.consume(level, systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false));
    if (edge === CallEdge.Start && (!this.playing || this.bargeIn)) {
      const pcm: VoicePcm = new VoicePcm(110);
      for (const frame of this.preroll) pcm.append(frame.buffer as ArrayBuffer);
      pcm.append(this.frame.buffer as ArrayBuffer); this.utterance = pcm;
      this.queue({ epoch: epoch, over: this.playing });
    } else if (this.utterance) {
      const pcm: VoicePcm = this.utterance; pcm.append(this.frame.buffer as ArrayBuffer);
      if (edge === CallEdge.End || pcm.full) {
        if (edge !== CallEdge.End) this.gate.reset();
        this.utterance = undefined; this.queue({ epoch: epoch, pcm: pcm });
      }
    }
    this.preroll.push(this.frame.slice());
    if (this.preroll.length > 15) this.preroll.shift();
  }
  private defer(): void {
    if (this.scheduled) return; this.scheduled = true;
    Promise.resolve().then((): void => {
      this.scheduled = false;
      if (this.stopped || !this.current()) { this.clearAudio(); return; }
      if (!this.running && !this.fault) return;
      if (this.running && this.capturer) {
        try { if (this.capturer.getOverflowCountSync() !== 0) this.fault = true; }
        catch (_) { this.fault = true; }
      }
      if (this.fault) {
        this.clearAudio();
        if (!this.errorSent) { this.errorSent = true; this.listener.error('capture'); }
        this.stop().catch((): void => {}); return;
      }
      const frames: CallTapFrame[] = this.tapFrames; this.tapFrames = [];
      for (const frame of frames) {
        if (frame.epoch === this.epoch && !this.mutedValue) VoicePcmTap.offer(frame.tap, frame.bytes,
          (): boolean => this.running && !this.stopped && !this.fault && !this.mutedValue &&
            this.epoch === frame.epoch && this.current());
        frame.bytes.fill(0);
      }
      const notices: CallNotice[] = this.notices; this.notices = [];
      for (const notice of notices) {
        if (this.stopped || !this.current() || notice.epoch !== this.epoch) { notice.pcm?.discard(); continue; }
        if (notice.over !== undefined) this.listener.speechStart(notice.over);
        else if (notice.level !== undefined) this.listener.level(notice.level);
        else if (notice.pcm) {
          const ms: number = notice.pcm.length / 32;
          const wav: Uint8Array | null = notice.pcm.wav(); notice.pcm.discard();
          if (wav) this.listener.utterance(wav, ms);
        }
      }
    }).catch((): void => { this.fail(); });
  }
  stop(): Promise<void> {
    if (!this.stopped && this.lastTap) VoicePcmTap.reset(this.lastTap, 'stopped');
    this.stopped = true; this.running = false; this.epoch++; this.clearAudio();
    if (!this.closing) this.closing = this.close().catch((error: Error): void => { this.closing = undefined; throw error as Error; });
    return this.closing;
  }
  private async close(): Promise<void> {
    try { await this.opening; } catch (_) { /* release partially created / started capture */ }
    if (this.released) return;
    const capturer: audio.AudioCapturer | undefined = this.capturer;
    if (capturer) {
      if (this.subscribed) { try { capturer.off('readData', this.read); } catch (_) {} this.subscribed = false; }
      if (this.interruptSubscribed) { try { capturer.off('audioInterrupt'); } catch (_) {} this.interruptSubscribed = false; }
      if (this.started) { try { await capturer.stop(); } catch (_) {} }
      // Only a successful native release may relinquish VoiceMicLease.
      await capturer.release();
    }
    this.capturer = undefined; this.released = true; this.releaseToken();
  }
}
