// 16 kHz、单声道、PCM16LE；不依赖文件、原生音频对象或 HMS。
import { VoiceFailure } from './VoiceTypes';

export class VoicePcm {
  private bytes: Uint8Array;
  private used: number = 0;
  private discarded: boolean = false;
  level: number = 0;

  constructor(maxSeconds: number) {
    if (!Number.isInteger(maxSeconds) || maxSeconds < 1 || maxSeconds > 600) {
      throw new VoiceFailure('arguments', '录音时长必须在 1 到 600 秒之间。', 100);
    }
    this.bytes = new Uint8Array(maxSeconds * 16000 * 2);
  }

  get full(): boolean { return this.used === this.bytes.length; }
  get length(): number { return this.used; }

  append(buffer: ArrayBuffer): void {
    if (this.discarded || this.full) return;
    if (buffer.byteLength % 2 !== 0) throw new VoiceFailure('audio', '录音数据格式不完整。', 100);
    const size = Math.min(buffer.byteLength, this.bytes.length - this.used);
    // AudioCapturer may reuse its buffer immediately after readData returns.
    this.bytes.set(new Uint8Array(buffer, 0, size), this.used); this.used += size;
    if (size === 0) return;
    const samples = new DataView(buffer, 0, size);
    // Bound metering work even if a platform callback supplies an unusually large chunk.
    const stride = Math.max(1, Math.ceil(size / 2 / 1024));
    let power = 0; let count = 0;
    for (let i = 0; i < size / 2; i += stride) {
      const sample = samples.getInt16(i * 2, true) / 32768;
      power += sample * sample; count++;
    }
    const db = 20 * Math.log10(Math.max(Math.sqrt(power / count), 1e-6));
    this.level = Math.max(0, Math.min(1, (db + 50) / 40));
  }

  discard(): void { this.discarded = true; this.bytes = new Uint8Array(0); this.used = 0; }

  wav(): Uint8Array | null {
    if (this.discarded || this.used === 0) return null;
    const result = new Uint8Array(44 + this.used);
    result.set([82, 73, 70, 70], 0); result.set([87, 65, 86, 69, 102, 109, 116, 32], 8);
    result.set([100, 97, 116, 97], 36);
    const view = new DataView(result.buffer);
    view.setUint32(4, 36 + this.used, true); view.setUint32(16, 16, true);
    view.setUint16(20, 1, true); view.setUint16(22, 1, true); view.setUint32(24, 16000, true);
    view.setUint32(28, 32000, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
    view.setUint32(40, this.used, true); result.set(this.bytes.subarray(0, this.used), 44);
    return result;
  }
}
