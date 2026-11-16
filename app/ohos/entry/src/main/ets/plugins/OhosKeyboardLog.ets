// Own-window geometry only. No input text, IME/system log scan, disk or polling.
import hilog from '@ohos.hilog';
import window from '@ohos.window';
import { Any } from '@ohos/flutter_ohos';
import { BusinessError } from '@ohos.base';

interface KeyboardAvoidRects {
  leftRect: window.Rect;
  topRect: window.Rect;
  rightRect: window.Rect;
  bottomRect: window.Rect;
}

interface KeyboardSample {
  timestamp: number;
  event: string;
  geometry: Map<string, Any>;
}

function rect(value: window.Rect): window.Rect | null {
  const numbers: Array<number> = [value.left, value.top, value.width, value.height];
  if (!numbers.every((n: number): boolean => Number.isFinite(n)) || value.width < 0 || value.height < 0) return null;
  return { left: value.left, top: value.top, width: value.width, height: value.height };
}

function coordinates(value: window.Rect): Array<number> {
  return [value.left, value.top, value.width, value.height];
}

export class OhosKeyboardLog {
  private target: window.Window | null = null;
  private generation: number = 0;
  private foreground: boolean = false;
  private supported: number = 0;
  private registrationFailed: boolean = false;
  private rows: Array<KeyboardSample> = [];
  private willShow: (info: window.KeyboardInfo) => void = (_info: window.KeyboardInfo): void => {};
  private willHide: (info: window.KeyboardInfo) => void = (_info: window.KeyboardInfo): void => {};
  private didShow: (info: window.KeyboardInfo) => void = (_info: window.KeyboardInfo): void => {};
  private didHide: (info: window.KeyboardInfo) => void = (_info: window.KeyboardInfo): void => {};
  private height: (height: number) => void = (_height: number): void => {};
  private avoidArea: (data: window.AvoidAreaOptions) => void = (_data: window.AvoidAreaOptions): void => {};

  setForeground(value: boolean): void {
    this.foreground = value;
    if (!value) this.rows = [];
  }

  attach(stage: window.WindowStage): void {
    this.detach();
    const generation: number = this.generation;
    this.quietly('getMainWindow', (): void => {
      const target: window.Window = stage.getMainWindowSync();
      this.target = target;
      this.willShow = (info: window.KeyboardInfo): void => { this.keyboard(generation, 'willShow', info); };
      this.willHide = (info: window.KeyboardInfo): void => { this.keyboard(generation, 'willHide', info); };
      this.didShow = (info: window.KeyboardInfo): void => { this.keyboard(generation, 'didShow', info); };
      this.didHide = (info: window.KeyboardInfo): void => { this.keyboard(generation, 'didHide', info); };
      this.height = (height: number): void => {
        if (!this.active(generation) || !Number.isFinite(height) || height < 0) return;
        const geometry: Map<string, Any> = new Map<string, Any>();
        geometry.set('height', height); this.record('height', geometry, String(height));
      };
      this.avoidArea = (data: window.AvoidAreaOptions): void => {
        if (!this.active(generation) || data.type !== window.AvoidAreaType.TYPE_KEYBOARD) return;
        const left: window.Rect | null = rect(data.area.leftRect);
        const top: window.Rect | null = rect(data.area.topRect);
        const right: window.Rect | null = rect(data.area.rightRect);
        const bottom: window.Rect | null = rect(data.area.bottomRect);
        if (left === null || top === null || right === null || bottom === null) return;
        const clean: KeyboardAvoidRects = { leftRect: left, topRect: top, rightRect: right, bottomRect: bottom };
        const geometry: Map<string, Any> = new Map<string, Any>();
        geometry.set('left', coordinates(left)); geometry.set('top', coordinates(top));
        geometry.set('right', coordinates(right)); geometry.set('bottom', coordinates(bottom));
        this.record('avoidArea', geometry, JSON.stringify(clean));
      };
      this.supported += this.quietly('keyboardWillShow', (): void => { target.on('keyboardWillShow', this.willShow); }, true) ? 1 : 0;
      this.supported += this.quietly('keyboardWillHide', (): void => { target.on('keyboardWillHide', this.willHide); }, true) ? 1 : 0;
      this.supported += this.quietly('keyboardDidShow', (): void => { target.on('keyboardDidShow', this.didShow); }, true) ? 1 : 0;
      this.supported += this.quietly('keyboardDidHide', (): void => { target.on('keyboardDidHide', this.didHide); }, true) ? 1 : 0;
      this.supported += this.quietly('keyboardHeightChange', (): void => { target.on('keyboardHeightChange', this.height); }, true) ? 1 : 0;
      this.supported += this.quietly('avoidAreaChange', (): void => { target.on('avoidAreaChange', this.avoidArea); }, true) ? 1 : 0;
    });
  }

  detach(): void {
    const target: window.Window | null = this.target;
    this.generation++; this.target = null; this.rows = []; this.supported = 0; this.registrationFailed = false;
    if (target === null) return;
    this.quietly('keyboardWillShow', (): void => { target.off('keyboardWillShow', this.willShow); });
    this.quietly('keyboardWillHide', (): void => { target.off('keyboardWillHide', this.willHide); });
    this.quietly('keyboardDidShow', (): void => { target.off('keyboardDidShow', this.didShow); });
    this.quietly('keyboardDidHide', (): void => { target.off('keyboardDidHide', this.didHide); });
    this.quietly('keyboardHeightChange', (): void => { target.off('keyboardHeightChange', this.height); });
    this.quietly('avoidAreaChange', (): void => { target.off('avoidAreaChange', this.avoidArea); });
  }

  snapshot(abilityAttached: boolean): Map<string, Any> {
    const now: number = Date.now(); this.trim(now);
    const events: Array<Map<string, Any>> = [];
    const code: string = !abilityAttached || this.target === null ? 'unavailable' : !this.foreground ? 'cancelled' :
      this.supported === 0 ? (this.registrationFailed ? 'unavailable' : 'unsupported') : this.rows.length === 0 ? 'noEvents' : 'ok';
    if (code === 'ok') {
      this.rows.forEach((row: KeyboardSample): void => {
        const geometry: Map<string, Any> = new Map<string, Any>();
        row.geometry.forEach((value: Any, key: string): void => {
          geometry.set(key, Array.isArray(value) ? value.slice() : value);
        });
        const event: Map<string, Any> = new Map<string, Any>();
        event.set('timestamp', row.timestamp); event.set('event', row.event);
        event.set('origin', 'ohosWindow'); event.set('fromUser', null); event.set('reason', 'unknown');
        event.set('geometry', geometry); events.push(event);
      });
    }
    const result: Map<string, Any> = new Map<string, Any>();
    result.set('source', 'ohosWindowGeometry'); result.set('ok', code === 'ok' || code === 'noEvents');
    result.set('code', code); result.set('capturedAt', now); result.set('events', events);
    return result;
  }

  private active(generation: number): boolean {
    return this.foreground && this.target !== null && generation === this.generation;
  }

  private keyboard(generation: number, event: string, info: window.KeyboardInfo): void {
    if (!this.active(generation)) return;
    const begin: window.Rect | null = rect(info.beginRect);
    const end: window.Rect | null = rect(info.endRect);
    if (begin === null || end === null) return;
    const clean: window.KeyboardInfo = { beginRect: begin, endRect: end };
    const geometry: Map<string, Any> = new Map<string, Any>();
    geometry.set('begin', coordinates(begin)); geometry.set('end', coordinates(end));
    if (info.animated !== undefined) { clean.animated = info.animated; geometry.set('animated', info.animated); }
    if (info.config !== undefined && Number.isFinite(info.config.curve)) {
      const config: window.WindowAnimationConfig = { curve: info.config.curve };
      geometry.set('curve', info.config.curve);
      if (info.config.duration !== undefined && Number.isFinite(info.config.duration) && info.config.duration >= 0 && info.config.duration <= 3000) {
        config.duration = info.config.duration; geometry.set('durationMs', info.config.duration);
      }
      if (info.config.param !== undefined && info.config.param.length <= 4 && info.config.param.every((n: number): boolean => Number.isFinite(n))) {
        config.param = info.config.param.slice(); geometry.set('curveParams', info.config.param.slice());
      }
      clean.config = config;
    }
    this.record(event, geometry, JSON.stringify(clean));
  }

  private record(event: string, geometry: Map<string, Any>, detail: string): void {
    const timestamp: number = Date.now(); this.trim(timestamp);
    const row: KeyboardSample = { timestamp: timestamp, event: event, geometry: geometry };
    this.rows.push(row);
    if (this.rows.length > 64) this.rows.shift();
    hilog.info(0x3F00, 'DshKeyboard', '%{public}s %{public}s', event, detail);
  }

  private trim(now: number): void {
    this.rows = this.rows.filter((row: KeyboardSample): boolean => row.timestamp >= now - 120000 && row.timestamp <= now);
  }

  private quietly(what: string, action: () => void, registration: boolean = false): boolean {
    try { action(); return true; } catch (caught) {
      const error: BusinessError | null | undefined = caught as BusinessError | null | undefined;
      if (registration && error?.code !== 801) this.registrationFailed = true;
      hilog.warn(0x3F00, 'DshKeyboard', 'no %{public}s', what); return false;
    }
  }
}
