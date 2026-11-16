// Android SpeechGate / TurnPause energy fallback, not Silero or smart-turn.
export enum CallEdge { None, Start, End }

export class CallEnergyGate {
  private floor: number = NaN;
  private loud: number = 0;
  private quietMs: number = 0;
  private speaking: boolean = false;
  private playingSince: number = -1;
  private hangoverMs: number = 1000;
  private echoCancelled: boolean;

  constructor(echoCancelled: boolean) { this.echoCancelled = echoCancelled; }

  set pause(value: string) {
    switch (value.toLowerCase()) {
      case 'quick': this.hangoverMs = 700; break;
      case 'patient': this.hangoverMs = 1600; break;
      default: this.hangoverMs = 1000;
    }
  }
  setPlaying(on: boolean, nowMs: number): void {
    this.playingSince = on ? (this.playingSince >= 0 ? this.playingSince : nowMs) : -1;
    if (!on) this.loud = 0;
  }
  reset(): void { this.loud = 0; this.quietMs = 0; this.speaking = false; }

  consume(levelDb: number, nowMs: number): CallEdge {
    const playing: boolean = this.playingSince >= 0;
    if (Number.isNaN(this.floor)) this.floor = Math.min(levelDb, -60);
    if (levelDb < this.floor) this.floor += (levelDb - this.floor) * 0.5;
    else if (!this.speaking && !playing) this.floor += (levelDb - this.floor) * 0.01;
    const margin: number = playing ? (this.echoCancelled ? 24 : 30) : 15;
    const start: number = Math.max(this.floor + margin, playing ? -40 : -50);
    if (!this.speaking) {
      if (playing && nowMs - this.playingSince < 400) { this.loud = 0; return CallEdge.None; }
      this.loud = levelDb >= start ? this.loud + 1 : 0;
      if (this.loud >= (playing ? 10 : 6)) {
        this.speaking = true; this.loud = 0; this.quietMs = 0; return CallEdge.Start;
      }
      return CallEdge.None;
    }
    if (levelDb < start - 6) {
      this.quietMs += 20;
      if (this.quietMs >= this.hangoverMs) {
        this.speaking = false; this.quietMs = 0; return CallEdge.End;
      }
    } else this.quietMs = 0;
    return CallEdge.None;
  }

  static levelOf(frame: Uint8Array): number {
    const samples: DataView = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
    let power: number = 0;
    for (let i: number = 0; i < frame.byteLength; i += 2) {
      const value: number = samples.getInt16(i, true); power += value * value;
    }
    const rms: number = Math.sqrt(power / (frame.byteLength / 2)) / 32768;
    return rms <= 1e-5 ? -100 : 20 * Math.log10(rms);
  }
}
