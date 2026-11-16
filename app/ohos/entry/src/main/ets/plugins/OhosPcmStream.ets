import audio from '@ohos.multimedia.audio';
import { BusinessError } from '@ohos.base';
import { PcmByteQueue } from './PcmByteQueue';
import { PcmStreamBackend, PcmStreamFailure, PcmStreamListener, PcmStreamOptions,
  PcmTerminalKind } from './PcmStreamTypes';

// A failed native release must keep physical exclusivity across Flutter engines.
let playbackLease: OhosPcmStream | null = null;
const MAX_QUEUED_BYTES: number = 2 * 1024 * 1024;
const MAX_CALLBACK_BYTES: number = 64 * 1024;

interface PcmLevelMark { frame: number; value: number; }

// PCM16LE mono, 24 kHz. API 12+ callback rendering; no deprecated write() API.
// open() is an actual create/start preflight, not a guarantee of future focus.
export class OhosPcmStream implements PcmStreamBackend {
  private readonly rate: number;
  private readonly call: boolean;
  private readonly levels: boolean;
  private speaker: boolean;
  private readonly current: () => boolean;
  private readonly listener: PcmStreamListener;
  private renderer: audio.AudioRenderer | null = null;
  private queue: PcmByteQueue | null = null;
  private begun: boolean = false;
  private live: boolean = true;
  private ready: boolean = false;
  private ended: boolean = false;
  private startAttempted: boolean = false;
  private stopConfirmed: boolean = false;
  private released: boolean = false;
  private writeSubscribed: boolean = false;
  private interruptSubscribed: boolean = false;
  private stateSubscribed: boolean = false;
  private routeSubscribed: boolean = false;
  private submitted: boolean = false;
  private startPending: boolean = false;
  private startSent: boolean = false;
  private drainReady: boolean = false;
  private opening: Promise<void> | null = null;
  private openResult: Promise<boolean> | null = null;
  private closing: Promise<void> | null = null;
  private draining: Promise<void> | null = null;
  private volumeWork: Promise<void> | null = null;
  private routeWork: Promise<void> | null = null;
  private scheduled: number = -1;
  private levelScheduled: number = -1;
  private levelFrames: number = 0;
  private levelSum: number = 0;
  private submittedFrames: number = 0;
  private lastPlayFrame: number = 0;
  private levelQueue: Array<PcmLevelMark> = [];
  private terminalKind: PcmTerminalKind | null = null;
  private terminalReason: string = '';
  private terminalSent: boolean = false;
  private readonly writeCallback: (buffer: ArrayBuffer) => audio.AudioDataCallbackResult;
  private readonly interruptCallback: (event: audio.InterruptEvent) => void;
  private readonly stateCallback: (state: audio.AudioState) => void;
  private readonly routeCallback: (event: audio.AudioStreamDeviceChangeInfo) => void;

  constructor(options: PcmStreamOptions, current: () => boolean, listener: PcmStreamListener) {
    this.rate = options.rate; this.call = options.call; this.levels = options.levels;
    this.speaker = options.speaker !== false;
    this.current = current; this.listener = listener;
    this.writeCallback = (buffer: ArrayBuffer): audio.AudioDataCallbackResult => this.fill(buffer);
    this.interruptCallback = (event: audio.InterruptEvent): void => {
      if (!this.live) return;
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_MUTE) {
        this.finish(PcmTerminalKind.Stopped, 'focus');
      }
      // A resume/unduck hint must never restart an invalidated stream.
    };
    this.stateCallback = (state: audio.AudioState): void => {
      if (!this.live || !this.startAttempted) return;
      // The platform may deliver its forced stop/pause state before audioInterrupt.
      if (state === audio.AudioState.STATE_PAUSED || state === audio.AudioState.STATE_STOPPED) {
        this.finish(PcmTerminalKind.Stopped, 'renderer-state');
      } else if (state === audio.AudioState.STATE_RELEASED) {
        this.finish(PcmTerminalKind.Error, 'renderer-state');
      }
    };
    this.routeCallback = (_event: audio.AudioStreamDeviceChangeInfo): void => {
      // A route can reset and pass the previous framePos between two polls.
      // Its event retires the old PCM epoch without inventing a sample offset.
      if (this.live && this.levels && this.submitted) {
        this.finish(PcmTerminalKind.Error, 'playback-route-changed');
      }
    };
  }

  open(): Promise<boolean> {
    if (!this.live || this.released || !this.current()) return Promise.resolve(false);
    if (this.openResult !== null) return this.openResult;
    if (this.begun) return Promise.resolve(false);
    this.begun = true;
    // Save the acquisition before any platform hook can synchronously re-enter stop().
    this.opening = Promise.resolve().then((): Promise<void> => this.acquire());
    this.openResult = this.opening.then((): boolean | Promise<boolean> => {
      if (this.live && this.ready && this.current()) return true;
      return this.failOpen(PcmTerminalKind.Stopped, 'cancelled');
    }, (error: Error): Promise<boolean> => this.failOpen(PcmTerminalKind.Error,
      error instanceof PcmStreamFailure ? error.reason : 'open'));
    return this.openResult;
  }

  private async failOpen(kind: PcmTerminalKind, reason: string): Promise<boolean> {
    if (this.terminalKind === null) this.chooseTerminal(kind, reason);
    this.live = false; this.ready = false;
    try { await this.close(); } catch (_) { /* terminal error and physical lease are retained */ }
    return false;
  }

  private ensureCurrent(): void {
    if (!this.live || !this.current()) throw new PcmStreamFailure('cancelled');
  }

  private checkFormat(renderer: audio.AudioRenderer): void {
    const actual = renderer.getStreamInfoSync();
    if (actual.samplingRate !== audio.AudioSamplingRate.SAMPLE_RATE_24000 ||
      actual.channels !== audio.AudioChannel.CHANNEL_1 ||
      actual.sampleFormat !== audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE ||
      actual.encodingType !== audio.AudioEncodingType.ENCODING_TYPE_RAW) {
      throw new PcmStreamFailure('format');
    }
  }

  private async acquire(): Promise<void> {
    this.ensureCurrent();
    if (this.rate !== 24000 ||
      !canIUse('SystemCapability.Multimedia.Audio.Renderer')) throw new PcmStreamFailure('unsupported');
    const previous = playbackLease;
    if (previous !== null && !previous.live) {
      if (previous.closing !== null) { try { await previous.closing; } catch (_) {} }
      this.ensureCurrent();
      if (playbackLease === previous) await previous.close();
    }
    this.ensureCurrent();
    if (playbackLease !== null) throw new PcmStreamFailure('busy');
    playbackLease = this;
    this.queue = new PcmByteQueue(MAX_QUEUED_BYTES);
    const options: audio.AudioRendererOptions = {
      streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_24000,
        channels: audio.AudioChannel.CHANNEL_1, sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
      rendererInfo: { usage: this.call ? audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION :
        audio.StreamUsage.STREAM_USAGE_AUDIOBOOK, rendererFlags: 0 }
    };
    const created = await audio.createAudioRenderer(options);
    if (!created) throw new PcmStreamFailure('create');
    this.renderer = created; this.ensureCurrent(); this.checkFormat(created);
    if (this.call) {
      await created.setDefaultOutputDevice(this.speaker ? audio.DeviceType.SPEAKER : audio.DeviceType.EARPIECE);
      this.ensureCurrent();
    }
    const bufferSize = created.getBufferSizeSync();
    if (!Number.isSafeInteger(bufferSize) || bufferSize <= 0 || bufferSize % 2 !== 0 ||
      bufferSize > MAX_CALLBACK_BYTES) throw new PcmStreamFailure('buffer-size');
    created.on('audioInterrupt', this.interruptCallback); this.interruptSubscribed = true;
    created.on('stateChange', this.stateCallback); this.stateSubscribed = true;
    if (this.levels) {
      created.on('outputDeviceChangeWithInfo', this.routeCallback); this.routeSubscribed = true;
    }
    await created.setInterruptMode(audio.InterruptMode.INDEPENDENT_MODE);
    this.ensureCurrent();
    created.on('writeData', this.writeCallback); this.writeSubscribed = true;
    this.startAttempted = true;
    await created.start();
    this.ensureCurrent(); this.checkFormat(created);
    if (created.state !== audio.AudioState.STATE_RUNNING) throw new PcmStreamFailure('start-state');
    this.ready = true;
  }

  write(bytes: Uint8Array): number {
    if (!this.ready || !this.live || this.ended || !this.current()) return -1;
    const queue = this.queue;
    if (queue === null) return -1;
    if (!queue.append(bytes)) { this.finish(PcmTerminalKind.Error, 'queue-limit'); return -1; }
    return queue.size;
  }

  waiting(): number {
    if (!this.ready || !this.live || !this.current()) return -1;
    const queue = this.queue;
    return queue === null ? -1 : queue.size;
  }

  end(): void {
    if (!this.ready || !this.live || this.ended || !this.current()) return;
    this.ended = true;
    const queue = this.queue;
    if (queue === null) { this.finish(PcmTerminalKind.Error, 'queue'); return; }
    if (queue.size % 2 !== 0) { this.finish(PcmTerminalKind.Error, 'truncated-sample'); return; }
    if (queue.size === 0 && !this.submitted) this.finish(PcmTerminalKind.Done, '');
    // Otherwise the next empty callback proves the previous VALID buffer has
    // left the JS callback and entered the native renderer queue before drain.
  }

  private fill(buffer: ArrayBuffer): audio.AudioDataCallbackResult {
    if (!this.live || !this.current()) return audio.AudioDataCallbackResult.INVALID;
    try {
      const length = buffer.byteLength;
      if (!Number.isSafeInteger(length) || length <= 0 || length % 2 !== 0 ||
        length > MAX_CALLBACK_BYTES) throw new PcmStreamFailure('callback-size');
      const queue = this.queue;
      if (queue === null || !this.ready || this.draining !== null) return audio.AudioDataCallbackResult.INVALID;
      if (queue.size === 0 && this.ended) {
        this.drainReady = true; this.deferSignals();
        return audio.AudioDataCallbackResult.INVALID;
      }
      if (queue.size < length && !this.ended) return audio.AudioDataCallbackResult.INVALID;
      const take = Math.min(queue.size, length);
      if (take <= 0 || take % 2 !== 0) throw new PcmStreamFailure('truncated-sample');
      const destination = new Uint8Array(buffer);
      queue.take(destination, take);
      if (this.levels) this.appendLevels(destination, take);
      // The service consumes the ENTIRE callback buffer when VALID is returned.
      // Only the final EOF callback may be short; initialise its whole tail.
      if (take < length) destination.fill(0, take);
      this.submitted = true;
      if (!this.startSent) { this.startPending = true; this.deferSignals(); }
      if (this.levelQueue.length > 0) this.deferSignals();
      return audio.AudioDataCallbackResult.VALID;
    } catch (_) {
      this.finish(PcmTerminalKind.Error, 'callback');
      return audio.AudioDataCallbackResult.INVALID;
    }
  }

  private deferSignals(): void {
    if (this.scheduled !== -1) return;
    // A new event-loop task, not a microtask inside native napi_call_function.
    // No AudioRenderer API, MethodChannel callback or I/O runs in writeData.
    this.scheduled = setTimeout((): void => {
      this.scheduled = -1;
      if (this.startPending && !this.startSent && this.live && this.current()) {
        this.startPending = false; this.startSent = true;
        try { this.listener.started(); } catch (_) {}
      }
      if (!this.live) { this.close().catch((): void => {}); return; }
      this.scheduleLevels();
      if (this.drainReady && this.draining === null && this.current()) this.beginDrain();
    }, 0);
  }

  private appendLevels(bytes: Uint8Array, length: number): void {
    const frameSamples: number = this.rate * 40 / 1000;
    for (let at: number = 0; at < length; at += 2) {
      const sample: number = (bytes[at] | (bytes[at + 1] << 8)) << 16 >> 16;
      this.levelSum += sample * sample;
      this.levelFrames++; this.submittedFrames++;
      if (this.levelFrames === frameSamples) {
        const rms: number = Math.sqrt(this.levelSum / frameSamples) / 32768;
        const db: number = rms <= 1e-5 ? -100 : 20 * Math.log10(rms);
        this.levelQueue.push({ frame: this.submittedFrames, value: Math.max(0, Math.min(1, (db + 50) / 40)) });
        this.levelFrames = 0; this.levelSum = 0;
        if (this.levelQueue.length * frameSamples * 2 > MAX_QUEUED_BYTES) throw new PcmStreamFailure('level-queue-limit');
      }
    }
  }

  private scheduleLevels(): void {
    if (this.levelScheduled !== -1 || !this.live || !this.current() || this.levelQueue.length === 0) return;
    this.levelScheduled = setTimeout((): void => {
      this.levelScheduled = -1;
      const renderer: audio.AudioRenderer | null = this.renderer;
      if (!this.live || !this.current() || renderer === null) return;
      let position: number;
      try { position = renderer.getAudioTimestampInfoSync().framePos; }
      catch (error) {
        // Before the first played frame, the SDK may still reject the timestamp.
        if (this.lastPlayFrame === 0 && (error as BusinessError).code === 6800103) {
          this.scheduleLevels(); return;
        }
        this.finish(PcmTerminalKind.Error, 'playback-position'); return;
      }
      if (!Number.isFinite(position) || position < 0) {
        this.finish(PcmTerminalKind.Error, 'playback-position'); return;
      }
      if (position < this.lastPlayFrame) {
        // A route/flush reset loses the relation to this PCM stream. Do not
        // invent heard text by treating a new hardware epoch as the old one.
        this.finish(PcmTerminalKind.Error, 'playback-position-reset'); return;
      }
      this.lastPlayFrame = position;
      while (this.levelQueue.length > 0 && this.levelQueue[0].frame <= position && this.live && this.current()) {
        const mark: PcmLevelMark = this.levelQueue.shift()!;
        try { this.listener.level?.(mark.value); } catch (_) {}
      }
      this.scheduleLevels();
    }, 40);
  }

  private beginDrain(): void {
    const renderer = this.renderer;
    if (renderer === null || !this.live) return;
    this.drainReady = false;
    // The last payload passed the native submission path after a PREVIOUS
    // callback. Detach empty requests and await the platform drain contract;
    // this boundary alone does not prove acoustic playback or absence of drops.
    try {
      if (this.writeSubscribed) { renderer.off('writeData', this.writeCallback); this.writeSubscribed = false; }
      const work = renderer.drain();
      this.draining = work;
      work.then((): void => {
        if (this.live && this.current()) this.finish(PcmTerminalKind.Done, '');
      }, (): void => {
        if (this.live) this.finish(PcmTerminalKind.Error, 'drain');
      });
    } catch (_) { this.finish(PcmTerminalKind.Error, 'drain'); }
  }

  async duck(on: boolean): Promise<void> {
    if (!this.ready || !this.live || !this.current()) return;
    const previous = this.volumeWork;
    const work = Promise.resolve().then(async (): Promise<void> => {
      if (previous !== null) { try { await previous; } catch (_) {} }
      if (!this.live || !this.current() || this.renderer === null) return;
      await this.renderer.setVolume(on ? 0.25 : 1.0);
    });
    this.volumeWork = work;
    try { await work; }
    catch (_) { if (this.live) this.finish(PcmTerminalKind.Error, 'volume'); }
  }

  async setSpeaker(on: boolean): Promise<void> {
    if (!this.call || !this.ready || !this.live || !this.current()) throw new PcmStreamFailure('route');
    const previous: Promise<void> | null = this.routeWork;
    const work: Promise<void> = Promise.resolve().then(async (): Promise<void> => {
      if (previous !== null) { try { await previous; } catch (_) {} }
      this.ensureCurrent();
      const renderer: audio.AudioRenderer | null = this.renderer;
      if (renderer === null) throw new PcmStreamFailure('route');
      await renderer.setDefaultOutputDevice(on ? audio.DeviceType.SPEAKER : audio.DeviceType.EARPIECE);
      this.speaker = on;
    });
    this.routeWork = work;
    await work;
  }

  stop(): Promise<void> {
    this.chooseTerminal(PcmTerminalKind.Stopped, '');
    this.live = false; this.ready = false;
    if (this.queue !== null) this.queue.clear();
    this.clearLevels();
    return this.close();
  }

  private chooseTerminal(kind: PcmTerminalKind, reason: string): void {
    if (this.terminalSent) return;
    if (this.terminalKind === null || kind === PcmTerminalKind.Error ||
      (this.terminalKind === PcmTerminalKind.Done && kind === PcmTerminalKind.Stopped)) {
      this.terminalKind = kind; this.terminalReason = reason;
    }
  }

  private finish(kind: PcmTerminalKind, reason: string): void {
    this.chooseTerminal(kind, reason);
    this.live = false; this.ready = false;
    if (this.queue !== null) this.queue.clear();
    this.clearLevels();
    this.deferSignals();
  }

  private clearLevels(): void {
    if (this.levelScheduled !== -1) { clearTimeout(this.levelScheduled); this.levelScheduled = -1; }
    this.levelQueue = []; this.levelFrames = 0; this.levelSum = 0;
  }

  private close(): Promise<void> {
    if (this.closing !== null) return this.closing;
    const work = Promise.resolve().then((): Promise<void> => this.releaseNative());
    this.closing = work;
    work.then((): void => { if (this.closing === work) this.closing = null; },
      (): void => { if (this.closing === work) this.closing = null; });
    return work;
  }

  private pausedOrStopped(renderer: audio.AudioRenderer): boolean {
    // An asynchronous platform operation can change this readonly API property.
    const state = renderer.state;
    return state === audio.AudioState.STATE_PAUSED || state === audio.AudioState.STATE_STOPPED;
  }

  private async releaseNative(): Promise<void> {
    this.clearLevels();
    if (this.scheduled !== -1) { clearTimeout(this.scheduled); this.scheduled = -1; }
    if (this.opening !== null) { try { await this.opening; } catch (_) {} }
    const renderer = this.renderer;
    if (renderer !== null && !this.released) {
      if (this.writeSubscribed) {
        try { renderer.off('writeData', this.writeCallback); } catch (_) {}
        this.writeSubscribed = false;
      }
      if (this.interruptSubscribed) {
        try { renderer.off('audioInterrupt', this.interruptCallback); } catch (_) {}
        this.interruptSubscribed = false;
      }
      if (this.stateSubscribed) {
        try { renderer.off('stateChange', this.stateCallback); } catch (_) {}
        this.stateSubscribed = false;
      }
      if (this.routeSubscribed) {
        try { renderer.off('outputDeviceChangeWithInfo', this.routeCallback); } catch (_) {}
        this.routeSubscribed = false;
      }
      // Native stop may drain its old buffer. An abort first requests pause and
      // discards that buffer; natural completion has already awaited drain.
      // Issue pause before awaiting our outstanding drain Promise. The service
      // may serialise its own operations; do not invent an immediate-device claim.
      if (this.startAttempted && this.terminalKind !== PcmTerminalKind.Done) {
        if (renderer.state === audio.AudioState.STATE_RUNNING) {
          try { await renderer.pause(); }
          catch (_) {
            if (!this.pausedOrStopped(renderer)) this.chooseTerminal(PcmTerminalKind.Error, 'pause');
          }
        }
        if (renderer.state === audio.AudioState.STATE_RUNNING || renderer.state === audio.AudioState.STATE_PAUSED ||
          renderer.state === audio.AudioState.STATE_STOPPED) {
          try { await renderer.flush(); }
          catch (_) { this.chooseTerminal(PcmTerminalKind.Error, 'flush'); }
        }
      }
      if (this.startAttempted && !this.stopConfirmed) {
        try {
          if (renderer.state !== audio.AudioState.STATE_STOPPED) await renderer.stop();
          this.stopConfirmed = true;
        } catch (_) {
          // A forced stop can win after the state read but before stop settles.
          if (renderer.state === audio.AudioState.STATE_STOPPED) this.stopConfirmed = true;
          else this.chooseTerminal(PcmTerminalKind.Error, 'stop');
        }
      }
      if (this.draining !== null) { try { await this.draining; } catch (_) {} }
      if (this.volumeWork !== null) { try { await this.volumeWork; } catch (_) {} }
      if (this.routeWork !== null) { try { await this.routeWork; } catch (_) {} }
      try { await renderer.release(); }
      catch (_) {
        this.chooseTerminal(PcmTerminalKind.Error, 'release'); this.sendTerminal();
        throw new PcmStreamFailure('release');
      }
      this.renderer = null;
    }
    this.released = true; this.queue = null;
    if (playbackLease === this) playbackLease = null;
    this.sendTerminal();
  }

  private sendTerminal(): void {
    if (this.terminalSent || this.terminalKind === null) return;
    this.terminalSent = true;
    // current() is an admission check. The plugin separately checks engine and
    // stream identity before forwarding this final resource result.
    try { this.listener.terminal(this.terminalKind, this.terminalReason); } catch (_) {}
  }
}
