// One explicitly enabled 16 kHz PCM tap. Never owns or opens a microphone.
export class VoicePcmTapToken {
  readonly source: string;
  readonly id: number;
  readonly send: (tap: VoicePcmTapToken, bytes: Uint8Array) => void;
  readonly reset?: (tap: VoicePcmTapToken, reason: string) => void;
  constructor(source: string, id: number, send: (tap: VoicePcmTapToken, bytes: Uint8Array) => void,
    reset?: (tap: VoicePcmTapToken, reason: string) => void) {
    this.source = source; this.id = id; this.send = send; this.reset = reset;
  }
}

export class VoicePcmTap {
  private static tap?: VoicePcmTapToken;
  static enable(source: string, id: number, send: (tap: VoicePcmTapToken, bytes: Uint8Array) => void,
    reset?: (tap: VoicePcmTapToken, reason: string) => void): VoicePcmTapToken {
    const tap: VoicePcmTapToken = new VoicePcmTapToken(source, id, send, reset);
    VoicePcmTap.tap = tap; return tap;
  }
  static clear(tap: VoicePcmTapToken | undefined): void {
    if (VoicePcmTap.tap === tap) VoicePcmTap.tap = undefined;
  }
  static current(source: string): VoicePcmTapToken | undefined {
    const tap: VoicePcmTapToken | undefined = VoicePcmTap.tap;
    return tap?.source === source ? tap : undefined;
  }
  static offer(tap: VoicePcmTapToken, frame: Uint8Array, valid: () => boolean): void {
    if (VoicePcmTap.tap !== tap || !valid()) return;
    const bytes: Uint8Array = frame.slice();
    // SDK readData reuses its buffer and forbids Flutter calls from inside it.
    Promise.resolve().then((): void => {
      if (VoicePcmTap.tap === tap && valid()) tap.send(tap, bytes);
    }).catch((): void => { /* Flutter sink was detached. */ });
  }
  static reset(tap: VoicePcmTapToken, reason: string): void {
    Promise.resolve().then((): void => {
      if (VoicePcmTap.tap === tap) tap.reset?.(tap, reason);
    }).catch((): void => { /* Flutter sink was detached. */ });
  }
}

interface VoicePendingFrame {
  tap: VoicePcmTapToken;
  bytes: Uint8Array;
  valid: () => boolean;
}

export class VoicePcmFrames {
  private source: string;
  private tap?: VoicePcmTapToken;
  private frame: Uint8Array = new Uint8Array(640);
  private filled: number = 0;
  private pending: VoicePendingFrame[] = [];
  constructor(source: string) { this.source = source; }
  reset(): void {
    this.filled = 0; this.frame.fill(0); this.tap = undefined;
    for (const frame of this.pending) frame.bytes.fill(0);
    this.pending = [];
  }
  append(bytes: Uint8Array, valid: () => boolean): void {
    const tap: VoicePcmTapToken | undefined = VoicePcmTap.current(this.source);
    if (tap !== this.tap) { this.reset(); this.tap = tap; }
    if (!tap) return;
    let offset: number = 0;
    while (offset < bytes.length) {
      const take: number = Math.min(bytes.length - offset, 640 - this.filled);
      this.frame.set(bytes.subarray(offset, offset + take), this.filled);
      offset += take; this.filled += take;
      if (this.filled === 640) {
        if (this.pending.length >= 128) throw new Error('PCM tap admission backlog');
        this.pending.push({ tap: tap, bytes: this.frame.slice(), valid: valid }); this.filled = 0;
      }
    }
  }
  // Only the recorder may flush, after confirmed start and its overflow check.
  flush(): void {
    const pending: VoicePendingFrame[] = this.pending; this.pending = [];
    for (const frame of pending) {
      VoicePcmTap.offer(frame.tap, frame.bytes, frame.valid); frame.bytes.fill(0);
    }
  }
}
