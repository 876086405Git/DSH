// dsh/speech playback subset. Call capture and heard-time levels are not available here.
export interface PcmStreamOptions {
  rate: number;
  call: boolean;
  levels: boolean;
}

export enum PcmTerminalKind {
  Done = 'done',
  Stopped = 'stopped',
  Error = 'error'
}

export interface PcmStreamListener {
  started(): void;
  terminal(kind: PcmTerminalKind, reason: string): void;
}

export interface PcmStreamBackend {
  open(): Promise<boolean>;
  write(bytes: Uint8Array): number;
  waiting(): number;
  end(): void;
  stop(): Promise<void>;
  duck(on: boolean): Promise<void>;
}

export class PcmStreamFailure extends Error {
  reason: string;
  constructor(reason: string) {
    super(reason); this.reason = reason;
  }
}
