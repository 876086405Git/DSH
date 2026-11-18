// One physical microphone across ordinary dictation and native plugin activity.
// A failed SDK release retains the token. Business owners remain in each plugin.
import { VoiceFailure } from './VoiceTypes';

export class VoiceMicToken {
  readonly role: string;
  readonly close: () => Promise<void>;
  readonly retired?: () => boolean;
  constructor(role: string, close: () => Promise<void>, retired?: () => boolean) {
    this.role = role; this.close = close; this.retired = retired;
  }
}

export class VoiceMicLease {
  private static held?: VoiceMicToken;
  private static taking: boolean = false;
  static permissionOpen: boolean = false;

  static assertDictationAvailable(): void {
    if (VoiceMicLease.taking || VoiceMicLease.held?.role === 'dictation') {
      throw new VoiceFailure('busy', '上一语音会话尚未释放麦克风。', 8);
    }
  }

  static async dictation(token: VoiceMicToken): Promise<void> {
    if (VoiceMicLease.taking || VoiceMicLease.held?.role === 'dictation') {
      throw new VoiceFailure('busy', '上一语音会话尚未释放麦克风。', 8);
    }
    VoiceMicLease.taking = true;
    try {
      const previous = VoiceMicLease.held;
      if (previous) await previous.close();
      // A close Promise alone must not free a physical reservation. Only the
      // resource's actual onReleased callback can clear the old identity.
      if (VoiceMicLease.held) throw new VoiceFailure('busy', '上一语音会话尚未释放麦克风。', 8);
      VoiceMicLease.held = token;
    } finally { VoiceMicLease.taking = false; }
  }
  static plugin(token: VoiceMicToken): boolean {
    if (VoiceMicLease.taking || VoiceMicLease.held) return false;
    VoiceMicLease.held = token; return true;
  }
  static async retryRetiredDictation(): Promise<void> {
    const token = VoiceMicLease.held;
    // Preserve the existing dsh/voice explicit cancel recovery after engine
    // replacement; this never cancels an active plugin or active dictation.
    if (token?.role === 'dictation' && token.retired?.() === true) await token.close();
  }
  static release(token: VoiceMicToken): void {
    if (VoiceMicLease.held === token) VoiceMicLease.held = undefined;
  }
}
