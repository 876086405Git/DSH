// Asks the engine for 120 while the app is moving. The engine votes its own rate on its
// OH_NativeVSync: 120 under a finger and for 100 ms after it lifts, 60 from 3 s after, and
// in between only what scrolls, routes and Heroes vote. The app's springs, sheets and
// streaming output don't vote. LTPODispatchHighFrameRate is the call the embedding makes
// for the back key, and to the engine it is a lift, so one every TICK_MS holds the 120.
import hilog from '@ohos.hilog';
import { ohosThermal } from './OhosThermalState';

// The 120 ends 100 ms after a call, then the engine waits four vsyncs before dropping it.
// 80 leaves room for a late timer on the main thread.
const TICK_MS: number = 80;
// Dart renews active about once a second while it draws (RefreshRateService). If it stops
// answering, auto gives up by itself after this many ticks, 4 s.
const LEASE_TICKS: number = 50;

export class OhosFrameRateKeeper {
  private mode: string = 'auto';
  private active: boolean = false;
  private visible: boolean = false;
  private closed: boolean = false;
  private lease: number = 0;
  private timer: number | null = null;
  private dispatch: () => boolean;
  private observer: () => void = (): void => { this.update('thermal'); };

  // dispatch answers false once there's no engine left to ask.
  constructor(dispatch: () => boolean) {
    this.dispatch = dispatch;
    ohosThermal.subscribe(this.observer);
  }

  setMode(mode: string): void {
    this.mode = mode;
    this.active = false;
    this.update('mode ' + mode);
  }

  setActive(active: boolean): void {
    this.active = active;
    this.lease = LEASE_TICKS;
    this.update(active ? 'active' : 'inactive');
  }

  // Like Android's onPause, leaving the screen also ends active: Dart asks again if it draws.
  setVisible(visible: boolean): void {
    this.visible = visible;
    if (!visible) this.active = false;
    this.update(visible ? 'foreground' : 'background');
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    ohosThermal.unsubscribe(this.observer);
    this.update('detached');
  }

  private update(reason: string): void {
    const wanted = this.mode === 'max' || (this.mode === 'auto' && this.active);
    const run = wanted && this.visible && !this.closed && ohosThermal.snapshot().get('lightweight') !== true;
    if (run === (this.timer !== null)) return;
    hilog.info(0x3F00, 'DshFrameRate', '%{public}s: %{public}s', run ? 'start' : 'stop', reason);
    if (run) {
      this.timer = setInterval((): void => { this.tick(); }, TICK_MS);
      this.lease = LEASE_TICKS;
      this.fire();
    } else {
      clearInterval(this.timer!);
      this.timer = null;
    }
  }

  private tick(): void {
    if (this.mode === 'auto' && --this.lease <= 0) {
      this.active = false;
      this.update('no renewal');
      return;
    }
    this.fire();
  }

  private fire(): void {
    let asked = false;
    try { asked = this.dispatch(); } catch (_) { /* A failed call is the same as no engine. */ }
    if (!asked) this.close();
  }
}
