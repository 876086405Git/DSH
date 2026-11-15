import common from '@ohos.app.ability.common';
import wantAgent from '@ohos.app.ability.wantAgent';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { NativeHostModule } from './NativeHost';
import { backgroundComputePermission } from './BackgroundCompute';

// OS acceptance, not permission eligibility, grants the native background lease.
export class ContinuousTaskOwner {
  private readonly context: common.UIAbilityContext;
  private readonly host: NativeHostModule;
  private readonly owner: number;
  private readonly wake: () => void;
  private readonly fallback: () => void;
  private generation: number = 0;
  private wanted: boolean = false;
  private pending: number = 0;
  private unidentifiedTask: boolean = false;
  private task: number | null = null;
  private listening: boolean = false;
  private cancelled: Set<number> = new Set<number>();
  private cleanup: Set<number> = new Set<number>();
  private failure: string | null = null;
  private readonly onCancel = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => this.unavailable(info.id, true);
  private readonly onSuspend = (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => this.unavailable(info.continuousTaskId, false);

  private unavailable(id: number, cancelled: boolean): void {
    if (this.task === id) {
      this.task = null;
      this.closeNative();
      if (!cancelled) this.stopTask(id);
      this.wake();
      const retry = this.wanted;
      this.stop();
      if (retry) this.fallback();
    } else if (this.wanted && this.task === null) this.cancelled.add(id);
  }

  constructor(context: common.UIAbilityContext, host: NativeHostModule, owner: number,
    wake: () => void, fallback: () => void) {
    this.context = context; this.host = host; this.owner = owner; this.wake = wake; this.fallback = fallback;
  }

  eligible(): boolean { return backgroundComputePermission(this.context.applicationInfo.accessTokenId) === 'granted'; }

  request(): boolean {
    if (!this.eligible()) return false;
    this.wanted = true; this.cancelled.clear();
    const generation = ++this.generation;
    this.pending++;
    this.start(generation).catch((): void => {
      if (this.generation !== generation || !this.wanted) return;
      this.stop(); this.fallback();
    }).finally((): void => { this.pending--; if (!this.wanted) this.wake(); });
    return true;
  }

  private async start(generation: number): Promise<void> {
    backgroundTaskManager.on('continuousTaskCancel', this.onCancel); this.listening = true;
    backgroundTaskManager.on('continuousTaskSuspend', this.onSuspend);
    const request = new backgroundTaskManager.ContinuousTaskRequest();
    request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_TASK_KEEPING];
    request.wantAgent = await wantAgent.getWantAgent({ wants: [{
      bundleName: this.context.applicationInfo.name, abilityName: this.context.abilityInfo.name
    }], requestCode: 0, actionType: wantAgent.OperationType.START_ABILITY,
      actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG] });
    if (generation !== this.generation || !this.wanted) return;
    const result = await backgroundTaskManager.startBackgroundRunning(this.context, request);
    const id = result.continuousTaskId;
    if (id === undefined) {
      // A context-wide stop could cancel a replacement owner's task. Without
      // the returned id no safe targeted cleanup can be claimed.
      this.unidentifiedTask = true; this.failure = 'ohos_continuous_missing_id';
      throw new Error('Continuous task returned no ownership id');
    }
    if (generation !== this.generation || !this.wanted) { this.stopTask(id); return; }
    if (this.cancelled.has(id)) { this.stopTask(id); this.stop(); this.fallback(); return; }
    this.task = id;
    if (this.host.lifecycleUpdate('continuous', this.owner, 0, 1) !== 1) {
      this.stop(); return;
    }
    this.wake();
  }

  active(): boolean { return this.wanted; }
  cleanupPending(): boolean { return this.pending > 0 || this.unidentifiedTask || this.cleanup.size > 0; }
  error(): string | null { return this.failure; }

  stop(): void {
    this.wanted = false; this.generation++; this.cancelled.clear();
    const task = this.task; this.task = null;
    if (task !== null) {
      this.closeNative();
      this.stopTask(task);
    }
    if (this.listening) {
      try { backgroundTaskManager.off('continuousTaskCancel', this.onCancel); } catch (_) {}
      try { backgroundTaskManager.off('continuousTaskSuspend', this.onSuspend); } catch (_) {}
      this.listening = false;
    }
  }

  // A native failure can't leave the OS task running, or throw into an OS callback.
  private closeNative(): void {
    try { this.host.lifecycleUpdate('continuous', this.owner, 0, 0); }
    catch (_) { this.failure = 'ohos_continuous_native_failed'; }
  }

  private stopTask(id: number, attempt: number = 0): void {
    this.cleanup.add(id);
    backgroundTaskManager.stopBackgroundRunning(this.context, id).then((): void => {
      this.cleanup.delete(id); this.wake();
    }, (): void => {
      if (attempt < 2) setTimeout((): void => this.stopTask(id, attempt + 1), 1000);
      else this.failure = 'ohos_continuous_cancel_failed';
    });
  }
}
