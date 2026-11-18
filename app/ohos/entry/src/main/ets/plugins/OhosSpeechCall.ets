// dsh/speech call owner. Same physical microphone admission as dsh/voice.
import common from '@ohos.app.ability.common';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import window from '@ohos.window';
import { BusinessError } from '@kit.BasicServicesKit';
import { OhosCallCapture, CallCaptureListener } from './OhosCallCapture';
import { OhosCallRoute } from './OhosCallRoute';
import { VoiceMicLease, VoiceMicToken } from './VoiceMicLease';
import { retiredVoice } from './VoiceTypes';

class CallOwner {
  active: boolean = true;
  muted: boolean = false;
  bargeIn: boolean;
  pause: string;
  preparing?: Promise<void>;
  closing?: Promise<void>;
  capture?: OhosCallCapture;
  captureStarted: boolean = false;
  routePreparing: boolean = false;
  route?: OhosCallRoute;
  mic?: VoiceMicToken;
  window?: window.Window;
  previousKeepScreenOn: boolean = false;
  keepScreenAttempted: boolean = false;
  constructor(bargeIn: boolean, pause: string) { this.bargeIn = bargeIn; this.pause = pause; }
}

export class OhosSpeechCall {
  // Includes pending/failed route or window restoration after microphone release.
  private static physical?: OhosSpeechCall;
  private owner?: CallOwner;
  private generation: number = 0;
  private speakerValue: boolean = true;
  private speakerRequest: number = 0;
  private playing: boolean = false;
  private current: () => boolean;
  private listener: CallCaptureListener;
  private route: (on: boolean) => Promise<void>;

  constructor(current: () => boolean, listener: CallCaptureListener, route: (on: boolean) => Promise<void>) {
    this.current = current; this.listener = listener; this.route = route;
  }
  get speaker(): boolean { return this.speakerValue; }
  private live(owner: CallOwner): boolean { return owner.active && this.owner === owner && this.current(); }

  async start(context: common.UIAbilityContext, bargeIn: boolean, pause: string,
    currentMute: () => boolean = (): boolean => false, currentPause?: () => string): Promise<string> {
    if (!this.current()) return 'unavailable';
    this.speakerRequest++;
    const generation: number = ++this.generation;
    try {
      const previous: OhosSpeechCall | undefined = OhosSpeechCall.physical;
      if (previous && previous !== this) await previous.stop();
      if (this.owner) await this.closeOwner(this.owner);
      await VoiceMicLease.retryRetiredDictation();
      if (generation !== this.generation || !this.current()) return 'unavailable';
      if (!canIUse('SystemCapability.Multimedia.Audio.Capturer')) return 'unavailable';
      const grant: abilityAccessCtrl.GrantStatus = await abilityAccessCtrl.createAtManager().checkAccessToken(
        context.applicationInfo.accessTokenId, 'ohos.permission.MICROPHONE');
      if (generation !== this.generation || !this.current()) return 'unavailable';
      if (grant !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) return 'permission';
      VoiceMicLease.assertDictationAvailable();
      const owner: CallOwner = new CallOwner(bargeIn, currentPause ? currentPause() : pause);
      owner.muted = currentMute(); this.owner = owner;
      OhosSpeechCall.physical = this;
      const token: VoiceMicToken = new VoiceMicToken('dictation', (): Promise<void> => this.closeOwner(owner),
        (): boolean => !owner.active);
      owner.mic = token;
      owner.preparing = (async (): Promise<void> => {
        await VoiceMicLease.dictation(token);
        if (!this.live(owner)) throw retiredVoice();
        const listener: CallCaptureListener = {
          speechStart: (over: boolean): void => { if (this.live(owner)) this.listener.speechStart(over); },
          utterance: (wav: Uint8Array, ms: number): void => { if (this.live(owner)) this.listener.utterance(wav, ms); },
          level: (value: number): void => { if (this.live(owner)) this.listener.level(value); },
          error: (reason: string): void => {
            if (this.live(owner)) this.listener.error(reason);
            this.closeOwner(owner).catch((): void => {});
          }
        };
        const capture: OhosCallCapture = new OhosCallCapture((): boolean => this.live(owner), listener, (): void => {
          VoiceMicLease.release(token); if (owner.mic === token) owner.mic = undefined;
        });
        owner.capture = capture; capture.bargeIn = owner.bargeIn; capture.pause = owner.pause;
        capture.muted = owner.muted; capture.setPlaying(this.playing);
        const route: OhosCallRoute = new OhosCallRoute((): boolean => this.live(owner), (): void => {
          if (this.live(owner)) this.listener.error('audio-session');
          this.closeOwner(owner).catch((): void => {});
        });
        owner.route = route; owner.routePreparing = true; await route.open(this.speakerValue);
        owner.routePreparing = false;
        if (!this.live(owner)) throw retiredVoice();
        // The documented session ordering applies to recording as well as playback.
        await capture.start();
        if (!this.live(owner)) throw retiredVoice();
        owner.captureStarted = true;
        const target: window.Window = await window.getLastWindow(context);
        if (!this.live(owner)) throw retiredVoice();
        owner.window = target; owner.previousKeepScreenOn = target.getWindowProperties().isKeepScreenOn;
        if (!owner.previousKeepScreenOn) {
          owner.keepScreenAttempted = true;
          await target.setWindowKeepScreenOn(true);
          if (!this.live(owner)) throw retiredVoice();
        }
      })();
      try { await owner.preparing; return 'ok'; }
      catch (_) {
        try { await this.closeOwner(owner); } catch (_) {}
        return generation === this.generation && this.current() && !owner.captureStarted && !owner.routePreparing ? 'microphone' : 'unavailable';
      }
    } catch (_) { return generation === this.generation && this.current() ? 'microphone' : 'unavailable'; }
  }

  mute(on: boolean): void {
    const owner: CallOwner | undefined = this.owner;
    if (owner) { owner.muted = on; if (owner.capture) owner.capture.muted = on; }
  }
  bargeIn(on: boolean): void {
    const owner: CallOwner | undefined = this.owner;
    if (owner) { owner.bargeIn = on; if (owner.capture) owner.capture.bargeIn = on; }
  }
  pause(value: string): void {
    const owner: CallOwner | undefined = this.owner;
    if (owner) { owner.pause = value; if (owner.capture) owner.capture.pause = value; }
  }
  setPlaying(on: boolean): void { this.playing = on; this.owner?.capture?.setPlaying(on); }
  async setSpeaker(on: boolean): Promise<boolean> {
    if (!this.current()) throw retiredVoice();
    const request: number = ++this.speakerRequest;
    const owner: CallOwner | undefined = this.owner;
    if (owner && !this.live(owner)) throw retiredVoice();
    if (owner?.route) await owner.route.setSpeaker(on);
    else await this.route(on);
    // A slow old renderer can finish after stop and a newer accepted preference.
    // Reject the old method reply as well: Dart writes its Boolean after await.
    if (request !== this.speakerRequest || !this.current() || (owner && !this.live(owner))) throw retiredVoice();
    // An active call has requested the SDK default for PCM and system TTS.
    // Without a call, keep the existing preference for the next call stream.
    this.speakerValue = on; return on;
  }
  async stop(): Promise<void> {
    this.generation++; this.speakerRequest++; this.playing = false;
    const owner: CallOwner | undefined = this.owner;
    if (!owner) return;
    await this.closeOwner(owner);
    if (this.owner === owner) {
      this.owner = undefined; if (OhosSpeechCall.physical === this) OhosSpeechCall.physical = undefined;
    }
  }
  private closeOwner(owner: CallOwner): Promise<void> {
    owner.active = false;
    if (!owner.closing) {
      owner.closing = (async (): Promise<void> => {
        let failure: Error | undefined = undefined;
        // A pending window lookup/mutation must not keep recording alive.
        try { if (owner.capture) await owner.capture.stop(); } catch (error) { failure = error as Error; }
        try { await owner.preparing; } catch (_) {}
        if (!owner.capture && owner.mic) { VoiceMicLease.release(owner.mic); owner.mic = undefined; }
        try { if (owner.route) await owner.route.close(); } catch (error) { failure = error as Error; }
        try {
          if (owner.keepScreenAttempted && owner.window) {
            await owner.window.setWindowKeepScreenOn(owner.previousKeepScreenOn); owner.keepScreenAttempted = false;
          }
        } catch (error) {
          // A previously obtained window that was destroyed has no live screen flag.
          if ((error as BusinessError).code === 1300002) owner.keepScreenAttempted = false;
          else failure = error as Error;
        }
        if (failure) throw failure;
      })().catch((error: Error): void => { owner.closing = undefined; throw error as Error; });
    }
    return owner.closing;
  }
}
