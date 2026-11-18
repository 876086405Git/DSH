import thermal from '@ohos.thermal';
import systemDateTime from '@ohos.systemDateTime';
import { Any } from '@ohos/flutter_ohos';

// Product hysteresis, not a measured cooling time. OH WARM means background
// services should stop/defer; all warmer levels, including ESCAPE, stay light.
export class OhosThermalPolicy {
  status: number | null = null;
  lightweight: boolean = false;
  coolSince: number | null = null;
  readonly recoveryMs: number = 30000;

  update(value: number, now: number | null): boolean {
    const oldStatus = this.status, oldLight = this.lightweight, oldSince = this.coolSince;
    if (!Number.isInteger(value) || value < thermal.ThermalLevel.COOL || value > thermal.ThermalLevel.ESCAPE) {
      this.status = null; this.coolSince = null;
    } else {
      this.status = value;
      if (value >= thermal.ThermalLevel.WARM) { this.lightweight = true; this.coolSince = null; }
      else if (this.lightweight) {
        if (now === null) this.coolSince = null;
        else if (this.coolSince === null || now < this.coolSince) this.coolSince = now;
        else if (now - this.coolSince >= this.recoveryMs) { this.lightweight = false; this.coolSince = null; }
      }
    }
    return oldStatus !== this.status || oldLight !== this.lightweight || oldSince !== this.coolSince;
  }

  endObservation(): void { this.status = null; this.coolSince = null; }
}

function uptime(): number | null {
  try {
    const value = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE);
    return Number.isFinite(value) && value >= 0 ? value : null;
  } catch (_) { return null; }
}

type ThermalObserver = () => void;

// Fixed OH 6.1 NAPI owns one callback per JS thread. A plugin instance must not
// overwrite another engine's callback or unregister it on a late detach.
class OhosThermalMonitor {
  private observers: Set<ThermalObserver> = new Set<ThermalObserver>();
  private policy: OhosThermalPolicy = new OhosThermalPolicy();
  private registered: boolean = false;
  private generation: number = 0;
  private timer: number | null = null;
  private listenerError: string | null = null;

  subscribe(observer: ThermalObserver): void {
    if (this.observers.size === 0) this.start();
    this.observers.add(observer);
    this.schedule();
  }
  unsubscribe(observer: ThermalObserver): void {
    this.observers.delete(observer);
    if (this.observers.size !== 0) return;
    if (this.timer !== null) { clearTimeout(this.timer); this.timer = null; }
    this.policy.endObservation();
    if (this.registered) {
      try { thermal.unregisterThermalLevelCallback(); this.registered = false; this.generation++; }
      catch (_) { this.listenerError = 'unregister_failed'; }
    }
  }
  private start(): void {
    if (!canIUse('SystemCapability.PowerManager.ThermalManager')) return;
    if (!this.registered) {
      const generation = ++this.generation;
      try {
        thermal.registerThermalLevelCallback((level: thermal.ThermalLevel): void => {
          if (generation !== this.generation || this.observers.size === 0) return;
          const changed = this.policy.update(level, uptime());
          this.schedule(); if (changed) this.publish();
        });
        this.registered = true; this.listenerError = null;
      } catch (_) { this.listenerError = 'register_failed'; }
    }
    this.refresh();
  }
  refresh(): void {
    if (!canIUse('SystemCapability.PowerManager.ThermalManager')) return;
    let changed: boolean;
    try { changed = this.policy.update(thermal.getLevel(), uptime()); }
    catch (_) { changed = this.policy.update(-1, null); this.listenerError = 'level_unavailable'; }
    this.schedule(); if (changed) this.publish();
  }
  private schedule(): void {
    if (this.timer !== null) { clearTimeout(this.timer); this.timer = null; }
    const since = this.policy.coolSince;
    if (this.observers.size === 0 || since === null) return;
    const now = uptime();
    if (now === null) return;
    this.timer = setTimeout((): void => {
      this.timer = null;
      // Re-read a current level before declaring recovery, including when a
      // platform callback was unavailable. Failed/unknown reads never cool.
      this.refresh();
    }, Math.max(1, since + this.policy.recoveryMs - now));
  }
  private publish(): void {
    this.observers.forEach((observer: ThermalObserver): void => { try { observer(); } catch (_) {} });
  }
  snapshot(): Map<string, Any> {
    const value: Map<string, Any> = new Map<string, Any>();
    value.set('platform', 'ohos');
    value.set('supported', canIUse('SystemCapability.PowerManager.ThermalManager'));
    value.set('listening', this.registered);
    value.set('status', this.policy.status);
    const names = ['cool', 'normal', 'warm', 'hot', 'overheated', 'warning', 'emergency', 'escape'];
    value.set('level', this.policy.status === null ? 'unknown' : names[this.policy.status]);
    value.set('lightweight', this.policy.lightweight);
    value.set('coolSinceUptimeMs', this.policy.coolSince);
    value.set('recoveryAfterMs', this.policy.recoveryMs);
    value.set('listenerError', this.listenerError);
    return value;
  }
}

export const ohosThermal: OhosThermalMonitor = new OhosThermalMonitor();
