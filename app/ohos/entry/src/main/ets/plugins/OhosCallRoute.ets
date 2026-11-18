import audio from '@ohos.multimedia.audio';
import { retiredVoice } from './VoiceTypes';

// One CallOwner owns this app-level preference, including CoreSpeech's renderer.
// No scene or media routing change. API 20; 未在真机核实。
export class OhosCallRoute {
  private session: audio.AudioSessionManager | undefined;
  private previous: audio.DeviceType = audio.DeviceType.DEFAULT;
  private active: boolean = true;
  private activationAttempted: boolean = false;
  private lostSession: boolean = false;
  private preferenceAttempted: boolean = false;
  private subscribed: boolean = false;
  private work: Promise<void> = Promise.resolve();
  private closing: Promise<void> | undefined;
  private current: () => boolean;
  private lost: () => void;
  private interrupted: (event: audio.AudioSessionDeactivatedEvent) => void;

  constructor(current: () => boolean, lost: () => void) {
    this.current = current; this.lost = lost;
    this.interrupted = (_event: audio.AudioSessionDeactivatedEvent): void => {
      if (this.session) this.sessionLost();
    };
  }
  private sessionLost(): void {
    this.activationAttempted = false; this.lostSession = true;
    const notify: boolean = this.active && this.current(); this.active = false;
    if (notify) Promise.resolve().then(this.lost);
  }
  private check(): void { if (!this.active || !this.current()) throw retiredVoice(); }

  open(speaker: boolean): Promise<void> {
    this.work = (async (): Promise<void> => {
      this.check();
      const session: audio.AudioSessionManager = audio.getAudioManager().getSessionManager();
      // Do not adopt or later deactivate another owner's active app session.
      if (session.isAudioSessionActivated()) throw retiredVoice();
      this.previous = session.getDefaultOutputDevice(); this.session = session;
      this.subscribed = true; session.on('audioSessionDeactivated', this.interrupted);
      this.activationAttempted = true;
      await session.activateAudioSession({ concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_DEFAULT });
      this.check();
      await this.apply(speaker);
    })();
    return this.work;
  }
  setSpeaker(on: boolean): Promise<void> {
    const work: Promise<void> = this.work.catch((): void => {}).then((): Promise<void> => this.apply(on));
    this.work = work; return work;
  }
  private async apply(on: boolean): Promise<void> {
    this.check();
    const session: audio.AudioSessionManager | undefined = this.session;
    if (!session) throw retiredVoice();
    if (!session.isAudioSessionActivated()) { this.sessionLost(); throw retiredVoice(); }
    this.preferenceAttempted = true;
    await session.setDefaultOutputDevice(on ? audio.DeviceType.SPEAKER : audio.DeviceType.EARPIECE);
    if (!session.isAudioSessionActivated()) { this.sessionLost(); throw retiredVoice(); }
    this.check();
    // This confirms the SDK-accepted default, not the physical route: a headset
    // still takes precedence and some devices have no built-in earpiece.
  }
  close(): Promise<void> {
    this.active = false;
    if (!this.closing) {
      this.closing = (async (): Promise<void> => {
        try { await this.work; } catch (_) {}
        const session: audio.AudioSessionManager | undefined = this.session;
        if (!session) return;
        // A deactivation ends our activation ownership, not the persisted
        // default preference. Restore it while inactive; never stop a newly
        // active session whose ownership this API cannot identify.
        if (!session.isAudioSessionActivated()) this.activationAttempted = false;
        if (this.lostSession && session.isAudioSessionActivated()) throw retiredVoice();
        let failure: Error | undefined;
        if (this.preferenceAttempted) {
          try { await session.setDefaultOutputDevice(this.previous); this.preferenceAttempted = false; }
          catch (error) { failure = error as Error; }
        }
        if (this.activationAttempted) {
          try {
            if (session.isAudioSessionActivated()) await session.deactivateAudioSession();
            this.activationAttempted = false;
          } catch (error) { failure = error as Error; }
        }
        if (this.subscribed) {
          try { session.off('audioSessionDeactivated', this.interrupted); this.subscribed = false; }
          catch (error) { failure = error as Error; }
        }
        if (failure) throw failure;
        this.session = undefined;
      })().catch((error: Error): void => { this.closing = undefined; throw error as Error; });
    }
    return this.closing;
  }
}
