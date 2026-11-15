// dsh/speech PCM playback; microphone ownership is handled separately.
export interface PcmStreamOptions {
  rate: number;
  call: boolean;
  levels: boolean;
  speaker?: boolean;
}

export enum PcmTerminalKind {
  Done = 'done',
  Stopped = 'stopped',
  Error = 'error'
}

export interface PcmStreamListener {
  started: () => void;
  level?: (value: number) => void;
  terminal: (kind: PcmTerminalKind, reason: string) => void;
}

export interface PcmStreamBackend {
  open(): Promise<boolean>;
  write(bytes: Uint8Array): number;
  waiting(): number;
  end(): void;
  stop(): Promise<void>;
  duck(on: boolean): Promise<void>;
  setSpeaker: (on: boolean) => Promise<void>;
}

export class PcmStreamFailure extends Error {
  reason: string;
  constructor(reason: string) {
    super(reason); this.reason = reason;
  }
}
