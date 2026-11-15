import common from '@ohos.app.ability.common';
import { ContinuousTaskOwner } from './ContinuousTaskOwner';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { NativeHostModule } from './NativeHost';
import { HostLifecycleAck } from './RuntimeLifecycle';
import type { HostLifecycleSnapshot } from 'libdsh_host.so';

// Allow the one-second refresh cycle plus bounded ACK/scheduling delay.
const ACTIVITY_WINDOW_MS: number = 3000;

// Only RuntimeController's real Ability callbacks can reach this owner. No
// MethodChannel, host cookie, environment option or Node binding exposes writes.
export class TransientTaskOwner {
  private readonly host: NativeHostModule;
  private readonly continuous: ContinuousTaskOwner | null;
  private readonly wake: () => void;
  private owner: number;
  private foreground: boolean;
  private retired: boolean = false;
  private grant: number = 0;
  private requestId: number | null = null;
  private duration: number = 0;
  private waiting: boolean = false;
  private callbackArrived: boolean = false;
  private timer: number | null = null;
  private activityAt: number = -1;
  private activityRevision: number = -1;
  private activityBusy: boolean = false;
  private requestedAt: number = -1;
  private awaitingActivity: boolean = false;
  private idleAccepted: boolean = false;
  private cleanup: number[] = [];
  private cleanupAttempts: Map<number, number> = new Map<number, number>();
  private failure: string | null = null;

  constructor(host: NativeHostModule, foreground: boolean, wake: () => void, context?: common.UIAbilityContext) {
    this.host = host; this.foreground = foreground; this.wake = wake;
    this.owner = host.lifecycleUpdate('owner', 0, 0, foreground ? 1 : 0);
    this.continuous = context === undefined ? null : new ContinuousTaskOwner(context, host, this.owner, wake, (): void => {
      if (this.retired || this.foreground) return;
      try { this.requestShort(); }
      catch (_) { this.failure = 'ohos_transient_native_failed'; this.retire(); }
    });
  }

  observe(foreground: boolean): void {
    try { this.observeCurrent(foreground); }
    catch (_) { this.failure = 'ohos_transient_native_failed'; this.retire(); }
  }

  private observeCurrent(foreground: boolean): void {
    if (this.retired || foreground === this.foreground) return;
    const before = this.host.lifecycleSnapshot();
    const freshBusy = this.activityBusy && this.activityRevision === before.revision &&
      before.available === 1 && before.nowMs >= this.activityAt && before.nowMs - this.activityAt <= ACTIVITY_WINDOW_MS;
    this.foreground = foreground; this.idleAccepted = false;
    // Synchronous shared native state changes before any OS cancellation.
    this.host.lifecycleUpdate('foreground', this.owner, 0, foreground ? 1 : 0);
    this.release(); this.activityBusy = false;
    this.awaitingActivity = !foreground && (freshBusy || this.continuous?.eligible() === true) && this.owner !== 0;
    this.requestedAt = before.nowMs;
    this.wake();
  }

  private request(): void {
    if (this.continuous?.request() === true) return;
    this.requestShort();
  }

  private requestShort(): void {
    this.grant = this.host.lifecycleUpdate('begin', this.owner, 0, 0);
    if (this.grant === 0) return;
    const grant = this.grant;
    this.waiting = true; this.callbackArrived = false;
    try {
      const info = backgroundTaskManager.requestSuspendDelay('完成本机回合并保存结果', (): void => {
        if (this.retired || this.grant !== grant) return;
        try {
          this.callbackArrived = true; this.waiting = false;
          this.host.lifecycleUpdate('drain', this.owner, grant, 0);
          this.wake();
        } catch (_) { this.failure = 'ohos_transient_native_failed'; this.retire(); }
      });
      this.requestId = info.requestId; this.duration = info.actualDelayTime;
      if (this.retired || this.grant !== grant || this.callbackArrived ||
          !Number.isSafeInteger(this.duration) || this.duration <= 6000 || this.duration > 180000) {
        this.release(); return;
      }
      this.waiting = false;
      if (this.host.lifecycleUpdate('activate', this.owner, grant, this.duration) !== 1) {
        this.release(); return;
      }
      this.wake(); this.schedule();
    } catch (_) { this.failure = 'ohos_transient_request_failed'; this.release(); }
  }

  acknowledge(ack: HostLifecycleAck): void {
    try { this.receive(ack); }
    catch (_) { this.failure = 'ohos_transient_native_failed'; this.retire(); }
  }

  private receive(ack: HostLifecycleAck): void {
    this.idleAccepted = false;
    if (this.retired || ack === undefined || ack.nativeHost === null) return;
    const native = ack.nativeHost;
    const current = this.host.lifecycleSnapshot();
    if (native.engineGeneration !== current.engineGeneration || native.ownerGeneration !== this.owner ||
        native.revision !== current.revision || current.available !== 1 || current.clockFailed !== 0) return;
    this.idleAccepted = !ack.busy;
    if (this.continuous?.active() === true && (!ack.busy || ack.manualPaused)) this.release();
    if (this.foreground) {
      this.activityAt = native.nowMs; this.activityRevision = native.revision;
      this.activityBusy = ack.busy && !ack.manualPaused;
      return;
    }
    if (this.awaitingActivity) {
      this.awaitingActivity = false;
      // A fresh foreground fact alone can race round completion. Require a
      // second current background fact before spending any OS quota.
      if (ack.busy && !ack.manualPaused && current.nowMs >= this.requestedAt &&
          current.nowMs - this.requestedAt <= ACTIVITY_WINDOW_MS) this.request();
      return;
    }
    if (this.grant === 0 || native.grantGeneration !== this.grant) return;
    if (!ack.busy || current.phase === 5) { this.release(); return; }
    if (ack.manualPaused || current.phase === 3) {
      if (!this.callbackArrived) {
        this.callbackArrived = true;
        this.host.lifecycleUpdate('drain', this.owner, this.grant, 0); this.wake();
      }
      // A durable pause ACK is not proof that a model/tool already in flight
      // finished. Keep the remaining OS budget for completion/checkpointing;
      // tick() bounds cleanup before the original deadline regardless of ACKs.
    }
  }

  retire(): void {
    if (this.retired) return;
    this.retired = true; this.awaitingActivity = false; this.idleAccepted = false;
    try { this.host.lifecycleUpdate('retire', this.owner, 0, 0); }
    catch (_) { this.failure = 'ohos_transient_native_failed'; }
    this.release();
  }

  status(): Map<string, Object | null> {
    let phase: number = this.retired ? 4 : 6;
    let deadline: number | null = null;
    let drain: number | null = null;
    if (!this.retired) {
      try {
        const state = this.host.lifecycleSnapshot();
        if (state.ownerGeneration === this.owner) {
          phase = state.phase; deadline = state.deadlineMs; drain = state.drainAtMs;
        }
      } catch (_) { this.failure = 'ohos_transient_native_failed'; }
    }
    return new Map<string, Object | null>([['ownerGeneration', this.owner], ['retired', this.retired], ['foreground', this.foreground],
      ['phase', phase], ['deadlineMs', deadline], ['drainAtMs', drain],
      ['cleanupPending', this.cleanupPending()], ['error', this.failure ?? this.continuous?.error() ?? null]]);
  }

  cleanupPending(): boolean { return this.cleanup.length > 0 || this.continuous?.cleanupPending() === true; }

  canPausePolling(): boolean {
    if (this.retired || this.foreground || !this.idleAccepted || this.awaitingActivity || this.grant !== 0 ||
        this.continuous?.active() === true || this.cleanupPending()) return false;
    try {
      const current: HostLifecycleSnapshot = this.host.lifecycleSnapshot();
      return current.ownerGeneration === this.owner && current.available === 1 && current.clockFailed === 0 &&
        current.foreground === 0 && (current.phase === 0 || current.phase === 4);
    } catch (_) { return false; }
  }

  private retryableCleanup(): boolean {
    return this.cleanup.some((id: number): boolean => (this.cleanupAttempts.get(id) ?? 0) < 3);
  }

  private release(): void {
    this.continuous?.stop();
    if (this.grant !== 0) {
      try { this.host.lifecycleUpdate('release', this.owner, this.grant, 0); }
      catch (_) { this.failure = 'ohos_transient_native_failed'; }
    }
    this.grant = 0; this.waiting = false;
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
    if (this.requestId !== null) { this.cleanup.push(this.requestId); this.requestId = null; }
    this.retryCleanup();
    if (this.retryableCleanup()) this.schedule();
  }

  private retryCleanup(): void {
    const failed: number[] = [];
    this.cleanup.forEach((id: number): void => {
      const attempts = this.cleanupAttempts.get(id) ?? 0;
      if (attempts >= 3) { failed.push(id); return; }
      this.cleanupAttempts.set(id, attempts + 1);
      try { backgroundTaskManager.cancelSuspendDelay(id); this.cleanupAttempts.delete(id); }
      catch (_) { failed.push(id); this.failure = 'ohos_transient_cancel_failed'; }
    });
    this.cleanup = failed;
  }

  private schedule(): void {
    if (this.timer !== null) return;
    this.timer = setTimeout((): void => { this.timer = null; this.tick(); }, 1000);
  }

  private tick(): void {
    try { this.tickCurrent(); }
    catch (_) { this.failure = 'ohos_transient_native_failed'; this.retire(); }
  }

  private tickCurrent(): void {
    this.retryCleanup();
    if (!this.retired && this.grant !== 0) {
      const state = this.host.lifecycleSnapshot();
      if (state.available !== 1 || state.clockFailed !== 0 || state.phase === 5 ||
          (state.deadlineMs > 0 && state.nowMs >= state.deadlineMs - 1000)) {
        this.release(); return;
      }
      // Wakeups may fail, but every Node admission independently reads native
      // BOOTTIME. The timer is cleanup/activity refresh, never authorization.
      this.wake();
    }
    if (this.grant !== 0 || this.retryableCleanup()) this.schedule();
  }
}
