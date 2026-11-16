// The two speech outputs share playback; prewarming a TTS engine does not claim it.
export interface SpeechPlaybackOwner {
  stopPlayback: () => Promise<void>;
}

export class OhosSpeechPlayback {
  private static owner: SpeechPlaybackOwner | null = null;
  private static requested: SpeechPlaybackOwner | null = null;
  private static closing: Promise<void> | null = null;

  static async claim(next: SpeechPlaybackOwner): Promise<boolean> {
    OhosSpeechPlayback.requested = next;
    const previous: SpeechPlaybackOwner | null = OhosSpeechPlayback.owner;
    if (previous !== null && (previous !== next || OhosSpeechPlayback.closing !== null)) {
      await OhosSpeechPlayback.close(previous);
    }
    if (OhosSpeechPlayback.requested !== next) return false;
    OhosSpeechPlayback.owner = next;
    return true;
  }

  static isCurrent(owner: SpeechPlaybackOwner): boolean {
    return OhosSpeechPlayback.owner === owner && OhosSpeechPlayback.requested === owner;
  }

  static async release(owner: SpeechPlaybackOwner): Promise<void> {
    if (OhosSpeechPlayback.requested === owner) OhosSpeechPlayback.requested = null;
    if (OhosSpeechPlayback.owner === owner) await OhosSpeechPlayback.close(owner);
    else await owner.stopPlayback();
  }

  private static async close(owner: SpeechPlaybackOwner): Promise<void> {
    if (OhosSpeechPlayback.closing === null) OhosSpeechPlayback.closing = owner.stopPlayback();
    const work: Promise<void> = OhosSpeechPlayback.closing;
    try {
      await work;
      if (OhosSpeechPlayback.owner === owner) OhosSpeechPlayback.owner = null;
    } finally {
      // A failed shutdown keeps the owner so the next claim/stop can retry it.
      if (OhosSpeechPlayback.closing === work) OhosSpeechPlayback.closing = null;
    }
  }
}
