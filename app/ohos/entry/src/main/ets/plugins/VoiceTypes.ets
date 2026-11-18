// dsh/voice 使用已有 Dart / Android 的错误数字，不把 HMS 错误号冒充 Android ERROR_*。
export class VoiceFailure extends Error {
  code: string;
  voiceCode: number;
  constructor(code: string, message: string, voiceCode: number) {
    super(message); this.code = code; this.voiceCode = voiceCode;
  }
}

export interface VoiceNotice {
  type: string;
  text?: string;
  value?: number;
  code?: number;
}

export interface VoiceResource {
  start(): Promise<void>;
  finish(): Promise<Uint8Array | null>;
  cancel(): Promise<void>;
}

export function retiredVoice(): VoiceFailure {
  return new VoiceFailure('cancelled', '语音会话已取消。', 5);
}
