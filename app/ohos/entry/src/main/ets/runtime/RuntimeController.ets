// 未经 HarmonyOS SDK 编译、未在真机核实。Node 停止的 Linux 证据不替代 OH NAPI 验证。
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import connection from '@ohos.net.connection';
import UIAbility from '@ohos.app.ability.UIAbility';
import preferences from '@ohos.data.preferences';
import type { HostState, HostEvent, HostOptions, HostLifecycleSnapshot } from 'libdsh_host.so';
import { loadNativeHost, peekNativeHost, nativeHostState, nativeHostTouched, configureNativeRecovery, NativeRecoveryGate } from './NativeHost';
import { RuntimeChannelError, RuntimeManifest, RuntimeFile, RuntimeInstaller, RuntimeLogs, RuntimeLogEntry,
  InstallProgress, validateEnvironment, validateStartOptions, resolveNativeLibraryDir } from './RuntimeCore';
import { OhosRuntimeStorage } from './OhosRuntimeStorage';
import { RuntimeRecovery } from './RuntimeRecovery';
import { OhosRecoveryStorage } from './OhosRecoveryStorage';
import { RuntimeLastKnownGood, LkgBoot } from './RuntimeLastKnownGood';
import { OhosLastKnownGoodStorage } from './OhosLastKnownGoodStorage';
import { RuntimePaths } from './RuntimePaths';
import { ManagedSkillService, ManagedSkillScope } from './ManagedSkillService';
import { PersistedRuntimeLog } from './PersistedRuntimeLog';
import { TransientTaskOwner } from './TransientTaskOwner';
import { RuntimeLifecycle, HostLifecycleAck } from './RuntimeLifecycle';
import { OhosLifecycleTransport } from './OhosLifecycleTransport';
import { LinuxControl, LinuxRunRequest } from './LinuxControl';
import type { LinuxProxyConfiguration } from './LinuxControl';
import { agentReminderAccess, backgroundComputePermission, backgroundComputeStatus } from './BackgroundCompute';

type RuntimeSink = (event: Map<string, Object | null>) => void;
const LIFECYCLE_NOTICE = '前后台状态尚未同步，本机任务可能仍在暂停或运行；正在重试。';
// Short of Android's two minutes: the system ending a suspended app is ordinary here,
// and a phone app is often only on screen for a moment. Long enough to outlast a start
// that crashes.
const HEALTHY_MS = 30000;

const PROGRESS_BYTES = 512 * 1024;

// Optional in-memory counts of existing calls, not CPU time or completed work.
class IdleDiagnosticsWindow {
  readonly id: string;
  readonly startedAtMs: number;
  stoppedAtMs: number | null = null;
  pollTicks: number = 0;
  collectCalls: number = 0;
  snapshotCalls: number = 0;
  emitStatusCalls: number = 0;
  lifecycleRefreshRequests: number = 0;
  manifestPairChecks: number = 0;

  constructor(id: string, startedAtMs: number) {
    this.id = id; this.startedAtMs = startedAtMs;
  }

  toMap(): Map<string, Object | null> {
    return new Map<string, Object | null>([
      ['id', this.id], ['startedAtMs', this.startedAtMs], ['stoppedAtMs', this.stoppedAtMs],
      ['counters', new Map<string, Object | null>([
        ['pollTicks', this.pollTicks], ['collectCalls', this.collectCalls],
        ['snapshotCalls', this.snapshotCalls], ['emitStatusCalls', this.emitStatusCalls],
        ['lifecycleRefreshRequests', this.lifecycleRefreshRequests], ['manifestPairChecks', this.manifestPairChecks]
      ])]
    ]);
  }
}

export class RuntimeController {
  private static shared: RuntimeController | null = null;
  private static foreground: boolean = false;
  private static ability: UIAbility | null = null;
  readonly paths: RuntimePaths;
  readonly managedSkills: ManagedSkillService;
  private context: common.Context;
  private storage: OhosRuntimeStorage;
  private installer: RuntimeInstaller;
  private logs: RuntimeLogs = new RuntimeLogs();
  private persistedLogs: PersistedRuntimeLog;
  private lifecycle: RuntimeLifecycle;
  private taskOwner: TransientTaskOwner | null = null;
  private ownerlessIdle: HostLifecycleSnapshot | null = null;
  private retiredOwners: TransientTaskOwner[] = [];
  private ownerAbility: UIAbility | null = null;
  private lifecycleElapsedMs: number = 0;
  private idleDiagnosticsEnabled: boolean = false;
  private workspaceRecovery: boolean = false;
  private idleDiagnosticsWindow: IdleDiagnosticsWindow | null = null;
  private lastLifecycleError: string | null = null;
  private sinks: RuntimeSink[] = [];
  private initialized: Promise<void> | null = null;
  private manifest: RuntimeManifest | null = null;
  private installed: RuntimeManifest | null = null;
  private comparedManifest: RuntimeManifest | null = null;
  private comparedInstalled: RuntimeManifest | null = null;
  private comparedCurrent: boolean = false;
  private setupError: string | null = null;
  private lastError: string | null = null;
  private failureLines: string[] = [];
  private pending: string | null = null;
  private startCancelled: boolean = false;
  private startBegan: number = 0;
  private requestedStop: boolean = false;
  private stopping: Promise<void> | null = null;
  private linux: LinuxControl = new LinuxControl();
  private timer: number | null = null;
  private qualificationTimer: number | null = null;
  private pollIntervalMs: number = 100;
  private lastNative: HostState | null = null;
  private runtimeGeneration: number = 0;
  private recovery: RuntimeRecovery;
  private resetRequested: boolean = false;
  private attempt: string | null = null;
  private longTaskAllowed: boolean | null = null;
  private taskEnabled: boolean = false;
  private backgroundStore: preferences.Preferences | null = null;
  private backgroundLoaded: Promise<void> | null = null;
  private backgroundWrite: Promise<void> = Promise.resolve();
  private backgroundRevision: number = 0;
  private backgroundError: string | null = null;
  private runningSince: number | null = null;
  private markedHealthy: boolean = false;
  private runMode: string = 'normal';
  private lastGood: RuntimeLastKnownGood;
  private bootProfile: LkgBoot | null = null;
  private pinnedProfile: boolean = false;
  private lkgPin: Promise<void> | null = null;
  private lkgRecovering: boolean = false;

  static get(context: common.Context): RuntimeController {
    if (RuntimeController.shared === null) RuntimeController.shared = new RuntimeController(context);
    return RuntimeController.shared;
  }

  static onForeground(ability: UIAbility): void {
    RuntimeController.ability = ability; RuntimeController.foreground = true;
    RuntimeController.shared?.abilityForeground(ability);
  }

  static onBackground(ability: UIAbility): void {
    if (RuntimeController.ability !== ability) return;
    RuntimeController.foreground = false;
    RuntimeController.shared?.taskOwner?.observe(false);
    RuntimeController.shared?.lifecycle.observe(false);
    RuntimeController.shared?.startPolling();
  }

  static onDestroy(ability: UIAbility): void {
    if (RuntimeController.ability !== ability) return;
    RuntimeController.foreground = false; RuntimeController.ability = null;
    RuntimeController.shared?.retireOwner();
    RuntimeController.shared?.lifecycle.observe(false);
    RuntimeController.shared?.startPolling();
  }

  constructor(context: common.Context) {
    this.context = context;
    this.recovery = new RuntimeRecovery(new OhosRecoveryStorage(context), context.filesDir);
    this.lastGood = new RuntimeLastKnownGood(new OhosLastKnownGoodStorage(context));
    this.persistedLogs = PersistedRuntimeLog.get(context.filesDir);
    this.lifecycle = new RuntimeLifecycle(new OhosLifecycleTransport(),
      (): string => backgroundComputePermission(context.applicationInfo.accessTokenId),
      (): void => this.lifecycleChanged(),
      (ack: HostLifecycleAck): void => {
        this.ownerlessIdle = this.taskOwner === null && !ack.busy ? ack.nativeHost : null;
        this.taskOwner?.acknowledge(ack);
      });
    this.lifecycle.observe(RuntimeController.foreground);
    this.paths = new RuntimePaths(context.filesDir);
    this.runtimeGeneration = nativeHostState().consumed ? 1 : 0;
    this.managedSkills = new ManagedSkillService(this.paths.guestRoot, (scope: ManagedSkillScope): boolean => {
      const state = nativeHostState();
      return !this.requestedStop && this.pending === null && state.phase === 'running' &&
        scope.runtimeGeneration === this.runtimeGeneration && scope.token === state.token;
    });
    this.storage = new OhosRuntimeStorage(context.resourceManager, context.filesDir);
    this.installer = new RuntimeInstaller(this.storage, context.filesDir + '/dsh-runtime');
    const gate: NativeRecoveryGate = {
      prepare: (): Promise<void> => this.initialize(),
      check: (): void => this.checkRecovery(),
      begin: async (): Promise<string> => {
        const id = util.generateRandomUUID();
        await this.recovery.arm(id, Date.now(), 'nativeLoad');
        return id;
      },
      finish: (id: string, success: boolean): Promise<void> => this.recovery.finish(id, success, Date.now())
    };
    configureNativeRecovery(gate);
    this.startPolling();
  }

  private checkRecovery(): void {
    if (this.pending === 'restore' || this.lkgRecovering || this.lastGood.blocked()) throw new RuntimeChannelError('ohos_lkg_pending', '配置恢复尚未完成，未允许启动原生引擎。');
    if (this.recovery.status().waitingInstall) throw new RuntimeChannelError('ohos_install_required', '运行时已移除，请明确安装后继续。');
    if (this.resetRequested || this.recovery.status().resetPending) throw new RuntimeChannelError('ohos_restart_required', '重置尚未完成，请重新打开应用。');
  }

  private abilityForeground(ability: UIAbility): void {
    if (this.ownerAbility !== ability) this.bindOwner();
    this.taskOwner?.observe(true);
    this.lifecycle.observe(true);
    this.collect();
  }

  private bindOwner(): void {
    this.retireOwner();
    const host = peekNativeHost();
    if (host === null || RuntimeController.ability === null ||
        !['starting', 'running'].includes(host.getState().phase)) return;
    this.ownerAbility = RuntimeController.ability;
    this.taskOwner = new TransientTaskOwner(host, RuntimeController.foreground,
      (): void => this.lifecycle.observe(RuntimeController.foreground), RuntimeController.ability.context);
    this.taskOwner.setTaskEnabled(this.taskEnabled);
  }

  private retireOwner(): void {
    this.ownerlessIdle = null;
    if (this.taskOwner !== null) {
      this.taskOwner.retire();
      if (this.taskOwner.cleanupPending()) this.retiredOwners.push(this.taskOwner);
    }
    this.taskOwner = null; this.ownerAbility = null;
  }

  phoneContext(ability: UIAbility | undefined): common.UIAbilityContext | null {
    if (ability === undefined || ability !== RuntimeController.ability || !RuntimeController.foreground ||
      this.requestedStop || this.pending !== null) return null;
    return ability.context;
  }

  private applyTaskEnabled(enabled: boolean): void {
    this.taskEnabled = enabled;
    this.taskOwner?.setTaskEnabled(enabled);
  }

  private loadBackgroundProtection(): Promise<void> {
    if (this.backgroundLoaded === null) {
      this.backgroundLoaded = (async (): Promise<void> => {
        const store = await preferences.getPreferences(this.context, { name: 'dsh-background-protection' });
        const enabled = await store.get('taskEnabled', false);
        this.backgroundStore = store;
        if (this.backgroundRevision === 0) this.applyTaskEnabled(enabled === true);
        this.backgroundError = null;
      })().catch((): void => {
        this.backgroundLoaded = null; this.backgroundStore = null;
        this.backgroundError = 'ohos_background_storage_failed';
        this.applyTaskEnabled(false);
      });
    }
    return this.backgroundLoaded;
  }

  async backgroundProtection(): Promise<Map<string, Object | null>> {
    await this.backgroundWrite;
    await this.loadBackgroundProtection();
    const status = backgroundComputeStatus(this.context.applicationInfo.accessTokenId);
    status.delete('computePermission');
    status.set('taskEnabled', this.taskEnabled);
    status.set('taskActive', this.taskOwner?.continuousActive() === true);
    status.set('cleanupPending', this.taskOwner?.cleanupPending() === true ||
      this.retiredOwners.some((owner: TransientTaskOwner): boolean => owner.cleanupPending()));
    const failure = this.backgroundError ?? this.taskOwner?.continuousError() ??
      this.retiredOwners.find((owner: TransientTaskOwner): boolean => owner.cleanupPending())?.continuousError() ?? null;
    if (failure !== null) {
      status.set('error', failure);
      status.set('actionRequired', failure === 'ohos_background_storage_failed' ? 'retry_saving_preference' : 'return_to_app_and_retry');
    }
    return status;
  }

  setBackgroundProtection(enabled: boolean): Promise<Map<string, Object | null>> {
    const revision = ++this.backgroundRevision;
    // Revocation closes native admission before any asynchronous storage work.
    if (!enabled) this.applyTaskEnabled(false);
    this.backgroundWrite = this.backgroundWrite.then(async (): Promise<void> => {
      await this.loadBackgroundProtection();
      const store = this.backgroundStore;
      if (store === null) return;
      try {
        await store.put('taskEnabled', enabled);
        await store.flush();
        if (revision === this.backgroundRevision) {
          this.backgroundError = null; this.applyTaskEnabled(enabled);
        }
      } catch (_) {
        if (revision === this.backgroundRevision) {
          this.backgroundError = 'ohos_background_storage_failed'; this.applyTaskEnabled(false);
        }
      }
    });
    return this.backgroundWrite.then((): Promise<Map<string, Object | null>> => this.backgroundProtection());
  }

  // This read and the toggle deliberately do not initialize, collect or emit.
  getIdleDiagnostics(): Map<string, Object | null> {
    return new Map<string, Object | null>([
      ['schema', 1], ['enabled', this.idleDiagnosticsEnabled], ['observedAtMs', Date.now()],
      ['window', this.idleDiagnosticsWindow?.toMap() ?? null]
    ]);
  }

  setIdleDiagnosticsEnabled(enabled: boolean): Map<string, Object | null> {
    if (enabled && !this.idleDiagnosticsEnabled) {
      this.idleDiagnosticsWindow = new IdleDiagnosticsWindow(util.generateRandomUUID(), Date.now());
      this.idleDiagnosticsEnabled = true;
    } else if (!enabled && this.idleDiagnosticsEnabled) {
      if (this.idleDiagnosticsWindow !== null) this.idleDiagnosticsWindow.stoppedAtMs = Date.now();
      this.idleDiagnosticsEnabled = false;
    }
    return this.getIdleDiagnostics();
  }

  initialize(): Promise<void> {
    if (this.initialized === null) this.initialized = this.prepareRecovery().catch((error: Error): void => {
      this.initialized = null;
      this.setupError = error instanceof RuntimeChannelError ? error.message : '启动恢复未完成，未加载原生库。';
      throw error;
    });
    return this.initialized;
  }

  private async prepareRecovery(): Promise<void> {
    await this.loadBackgroundProtection();
    if (this.resetRequested) throw new RuntimeChannelError('ohos_restart_required', '重置已请求，请重新打开应用后继续。');
    const recovering = this.recovery.status().resetPending;
    await this.readInstallation();
    this.workspaceRecovery = await this.storage.exists(this.workspaceRecoveryPath());
    await this.recovery.initialize(Date.now(), (): Promise<void> => this.installPayload(), nativeHostTouched);
    this.lkgRecovering = true;
    try { this.assertLkgStopped(); await this.lastGood.recoverPending(); }
    finally { this.lkgRecovering = false; }
    if (this.manifest !== null) {
      this.installed = await this.installer.installed();
      if (this.current() && !(await this.storage.exists(this.installer.base + '/installing.json'))) {
        this.setupError = null;
        if (recovering && !this.recovery.status().resetPending) this.lastError = null;
      }
    }
  }

  private async installPayload(): Promise<void> {
    if (this.manifest === null) throw new RuntimeChannelError('ohos_payload_missing', this.setupError ?? 'HAP 中没有运行时载荷。');
    const manifest: RuntimeManifest = this.manifest;
    const began = Date.now();
    let step = '';
    let reported = -1;
    await this.storage.withBundledRuntime(async (): Promise<void> => {
      await this.installer.install(manifest, (progress: InstallProgress) => {
        if (progress.step !== step) {
          hilog.info(0x3F00, 'DshRuntime', 'install %{public}s at %{public}d ms', progress.step, Date.now() - began);
          step = progress.step;
        }
        // Dart draws one bar over unpacked bytes, as Android reports it: the per-file
        // check before it restarted the bar, and an event per file cost the phone minutes.
        if (progress.step !== 'extract') return;
        if (reported >= 0 && progress.done < progress.total && progress.done - reported < PROGRESS_BYTES) return;
        reported = progress.done;
        this.emit(new Map<string, Object | null>([
          ['type', 'progress'], ['step', progress.step], ['done', progress.done], ['total', progress.total]
        ]));
      });
    });
    hilog.info(0x3F00, 'DshRuntime', 'install finished in %{public}d ms', Date.now() - began);
  }

  private async readInstallation(): Promise<void> {
    try {
      this.manifest = await this.storage.readBundledManifest();
      this.installed = await this.installer.installed();
      if (await this.storage.exists(this.installer.base + '/installing.json')) this.setupError = '上次运行时安装未完成，请重新安装以继续。';
    } catch (error) {
      this.setupError = error instanceof RuntimeChannelError ? error.message : '无法读取随包运行时或安装记录，请检查 HAP 运行时载荷。';
    }
  }

  private current(): boolean {
    const manifest = this.manifest;
    const installed = this.installed;
    if (manifest === null || installed === null) {
      this.comparedManifest = null; this.comparedInstalled = null; this.comparedCurrent = false;
      return false;
    }
    // These private parsed records are read-only after acquisition. A successful
    // installed() re-read returns a new object, even when its version is unchanged.
    if (manifest === this.comparedManifest && installed === this.comparedInstalled) return this.comparedCurrent;
    if (this.idleDiagnosticsEnabled && this.idleDiagnosticsWindow !== null) this.idleDiagnosticsWindow.manifestPairChecks++;
    let matches = false;
    if (manifest.runtimeVersion === installed.runtimeVersion && manifest.dshVersion === installed.dshVersion &&
        manifest.nodeVersion === installed.nodeVersion && manifest.files.length === installed.files.length) {
      const files = new Map<string, RuntimeFile>();
      installed.files.forEach((file: RuntimeFile) => files.set(file.path, file));
      matches = manifest.files.every((file: RuntimeFile) => {
        const other = files.get(file.path);
        return other !== undefined && other.sha256 === file.sha256 && other.size === file.size;
      });
    }
    this.comparedManifest = manifest; this.comparedInstalled = installed; this.comparedCurrent = matches;
    return matches;
  }

  snapshot(): Map<string, Object | null> {
    if (this.idleDiagnosticsEnabled && this.idleDiagnosticsWindow !== null) this.idleDiagnosticsWindow.snapshotCalls++;
    const native = nativeHostState();
    this.syncManagedSkills(native);
    let phase = this.current() ? 'installed' : 'notInstalled';
    if (this.pending === 'install') phase = 'installing';
    else if (this.pending === 'start') phase = 'starting';
    else if (native.phase === 'starting' || native.phase === 'running' || native.phase === 'stopping') phase = native.phase;
    else if (native.phase === 'error' || (native.phase === 'exited' && !this.requestedStop)) phase = 'error';
    else if (this.lastError !== null || this.setupError !== null) phase = 'error';
    const recovery = this.recovery.status();
    if (recovery.failure !== null && phase === 'installed') phase = 'error';
    const recoveryFailure = recovery.failure === null ? null : new Map<string, Object | null>([
      ['kind', recovery.failure.kind], ['at', recovery.failure.at], ['exitCode', recovery.failure.exitCode],
      ['safeMode', recovery.failure.safeMode], ['summary', recovery.failure.summary], ['causeUnknown', true]
    ]);
    const active = native.phase === 'running';
    const failure = native.errorCode ?? (native.phase === 'exited' && !this.requestedStop ? 'ohos_node_exited' : null);
    return new Map<string, Object | null>([
      ['abi', 'arm64-v8a'], ['bundledVersion', this.manifest?.runtimeVersion ?? null],
      ['installedVersion', this.installed?.runtimeVersion ?? null], ['dshVersion', this.manifest?.dshVersion ?? null],
      ['nodeVersion', this.manifest?.nodeVersion ?? null], ['phase', phase],
      ['baseUrl', active ? native.baseUrl : null], ['token', active ? native.token : null],
      ['managedSkillGeneration', active ? this.managedSkills.generationFor(native.token) : null],
      ['error', this.lastError ?? this.setupError ?? native.errorMessage ??
        (native.phase === 'exited' && !this.requestedStop ? '本机引擎已退出；请关闭并重新打开 App 后再启动。' :
          this.lifecycle.failureCode() !== null ? LIFECYCLE_NOTICE : null)],
      ['mode', native.consumed ? this.runMode : recovery.nextMode],
      ['safeState', recovery.nextMode === 'safe' ? 'on' : 'off'],
      ['safeReason', recovery.nextMode === 'safe' ? 'manual' : null], ['strikes', recovery.strikes], ['autoSafe', false],
      ['failure', recoveryFailure], ['mainFailure', null], ['healthyAt', null], ['networkBlocked', false], ['networkBlockedAt', null],
      ['workspaceRecovery', this.workspaceRecovery],
      ['directEngineEnabled', false], ['directEngineAvailable', false], ['directEngineActive', false],
      ['directEngineFallbackReason', null], ['currentExecutionMode', active ? 'ohos-embedded' : null],
      ['launchSelectedMode', native.consumed ? 'ohos-embedded' : null], ['launchSpawned', native.consumed],
      ['launchFailureReason', failure], ['resetPending', recovery.resetPending], ['waitingInstall', recovery.waitingInstall], ['tidyingFiles', false], ['lifecycle', this.lifecycle.status()],
      ['longTaskEligible', native.consumed && this.longTaskEligible()],
      ['transientTask', this.taskOwner?.status() ?? null],
      ['transientCleanup', this.retiredOwners.filter((owner: TransientTaskOwner): boolean => owner.cleanupPending())
        .map((owner: TransientTaskOwner): Map<string, Object | null> => owner.status())]
    ]);
  }

  // Eligibility only: whether the system accepts a task when asked is a later answer.
  // Asked once the engine has started; a remote-only app has no turn to keep going.
  private longTaskEligible(): boolean {
    if (this.longTaskAllowed === null) {
      this.longTaskAllowed = backgroundComputePermission(this.context.applicationInfo.accessTokenId) === 'granted';
    }
    return this.longTaskAllowed;
  }

  private lifecycleChanged(): void {
    const error = this.lifecycle.failureCode();
    if (error !== null && error !== this.lastLifecycleError) {
      this.emit(new Map<string, Object | null>([['type', 'notice'], ['text', LIFECYCLE_NOTICE]]));
    }
    this.lastLifecycleError = error;
    this.emitStatus();
    if (this.canPausePolling()) this.collect();
    else if (!RuntimeController.foreground && this.timer === null) this.startPolling();
  }

  subscribe(sink: RuntimeSink): void {
    this.sinks.push(sink);
    this.initialize().then(() => {
      if (this.sinks.includes(sink)) sink(new Map<string, Object | null>([['type', 'status'], ['status', this.snapshot()]]));
    }).catch((): void => this.emitStatus());
  }

  unsubscribe(sink: RuntimeSink): void {
    this.sinks = this.sinks.filter((other: RuntimeSink) => other !== sink);
  }

  private emit(event: Map<string, Object | null>): void {
    this.sinks.forEach((sink: RuntimeSink): void => {
      try { sink(event); }
      catch (_) { /* Observer delivery must not alter runtime operation admission or completion. */ }
    });
  }

  private emitStatus(): void {
    if (this.idleDiagnosticsEnabled && this.idleDiagnosticsWindow !== null) this.idleDiagnosticsWindow.emitStatusCalls++;
    this.emit(new Map<string, Object | null>([['type', 'status'], ['status', this.snapshot()]]));
  }

  private canPausePolling(): boolean {
    if (RuntimeController.foreground || this.requestedStop || this.pending !== null || !this.lifecycle.synchronized() ||
        this.retiredOwners.some((owner: TransientTaskOwner): boolean => owner.cleanupPending())) return false;
    if (this.taskOwner !== null) return this.taskOwner.canPausePolling();
    // An Ability can be destroyed while the process remains alive. There is no
    // owner to grant CPU then; require a fresh idle ACK of that retired state.
    const acknowledged: HostLifecycleSnapshot | null = this.ownerlessIdle;
    if (acknowledged === null) return false;
    try {
      const current: HostLifecycleSnapshot | undefined = peekNativeHost()?.lifecycleSnapshot();
      return current !== undefined && current.engineGeneration === acknowledged.engineGeneration &&
        current.ownerGeneration === acknowledged.ownerGeneration && current.revision === acknowledged.revision &&
        current.available === 0 && current.clockFailed === 0 && current.foreground === 0 &&
        (current.phase === 0 || current.phase === 4);
    } catch (_) { return false; }
  }

  private scheduleQualification(): void {
    if (this.qualificationTimer !== null) clearTimeout(this.qualificationTimer);
    this.qualificationTimer = null;
    if (this.attempt === null || this.runningSince === null || this.runMode === 'safe') return;
    let due: number | null = this.markedHealthy ? null : this.runningSince + HEALTHY_MS;
    if (this.runMode === 'normal' && this.bootProfile !== null && !this.pinnedProfile) {
      const pinDue: number = this.runningSince + 120000;
      if (due === null || pinDue < due) due = pinDue;
    }
    if (due === null) return;
    this.qualificationTimer = setTimeout((): void => {
      this.qualificationTimer = null;
      // collect re-reads native state before either existing qualification.
      this.collect();
    }, Math.max(1, due - Date.now()));
  }

  private startPolling(state: HostState = nativeHostState()): void {
    const active: boolean = ['starting', 'running', 'stopping'].includes(state.phase);
    if (state.phase === 'running' && this.canPausePolling()) {
      if (this.timer !== null) clearInterval(this.timer);
      this.timer = null;
      this.scheduleQualification();
      return;
    }
    if (this.qualificationTimer !== null) clearTimeout(this.qualificationTimer);
    this.qualificationTimer = null;
    // Busy background work keeps its one-second owner heartbeat. Foreground,
    // startup and stop retain 100 ms; parked logs wait for the next collection.
    const interval: number = state.phase === 'running' && !RuntimeController.foreground && !this.requestedStop ? 1000 : 100;
    if (this.timer !== null && active && interval === this.pollIntervalMs) return;
    if (this.timer !== null) clearInterval(this.timer);
    this.timer = null;
    if (!active) return;
    this.pollIntervalMs = interval;
    this.timer = setInterval(() => {
      if (this.idleDiagnosticsEnabled && this.idleDiagnosticsWindow !== null) this.idleDiagnosticsWindow.pollTicks++;
      this.lifecycleElapsedMs += this.pollIntervalMs;
      this.collect();
    }, interval);
  }

  collect(): void {
    if (this.idleDiagnosticsEnabled && this.idleDiagnosticsWindow !== null) this.idleDiagnosticsWindow.collectCalls++;
    const state = nativeHostState();
    this.retiredOwners = this.retiredOwners.filter((owner: TransientTaskOwner): boolean => owner.cleanupPending());
    const finished = (state.phase === 'exited' || state.phase === 'error') && this.lastNative?.phase !== state.phase;
    this.lifecycle.runtime(state.phase === 'running' && !this.requestedStop ? state.baseUrl : null,
      state.phase === 'running' && !this.requestedStop ? state.token : null);
    if (finished) {
      this.retireOwner();
      const attempt = this.attempt;
      if (attempt !== null) {
        this.attempt = null;
        this.recovery.finish(attempt, this.requestedStop && state.phase === 'exited' && state.exitCode === 0,
          Date.now(), state.exitCode ?? 0, state.phase === 'error').then((): void => this.emitStatus()).catch((): void => {
            this.lastError = '退出恢复记录未确认落盘，下次启动将保守报告未正常退出。'; this.emitStatus();
          });
      }
    }
    this.noteHealthy(state);
    this.noteLastGood(state);
    if (this.lifecycleElapsedMs >= 1000) {
      this.lifecycleElapsedMs = 0;
      if (this.idleDiagnosticsEnabled && this.idleDiagnosticsWindow !== null) this.idleDiagnosticsWindow.lifecycleRefreshRequests++;
      this.lifecycle.refresh();
    }
    this.syncManagedSkills(state);
    if (state.token !== null) this.logs.rememberSecret(state.token);
    const batch: RuntimeLogEntry[] = [];
    const events: HostEvent[] = peekNativeHost()?.drainEvents() ?? [];
    for (const event of events) {
      if (event.kind === 'ready' && event.token !== undefined) this.logs.rememberSecret(event.token);
      if (event.kind === 'log' && event.line !== undefined && event.stream !== undefined) {
        batch.push(this.logs.append(event.line, event.stream));
      }
      if (event.kind === 'exit') batch.push(this.logs.append(`Node 已退出（code=${event.exitCode}）；再次启动需要关闭并重新打开 App。`, 'system'));
      if (event.kind === 'error') this.lastError = (event.errorCode ?? 'ohos_native_error') + ': ' + (event.message ?? '本机引擎出错，请重新打开 App。');
    }
    if (batch.length > 0) {
      this.persistedLogs.append(batch);
      this.emit(new Map<string, Object | null>([
        ['type', 'logs'], ['entries', batch.map((entry: RuntimeLogEntry) => entry.toMap())]
      ]));
    }
    if (finished) this.persistedLogs.flush().catch((): void => {
      console.warn('运行时诊断日志尚未完整落盘，请查看诊断中的持久化状态。');
    });
    if (this.lastNative === null || state.phase !== this.lastNative.phase || state.exitCode !== this.lastNative.exitCode ||
        state.errorCode !== this.lastNative.errorCode || state.token !== this.lastNative.token) {
      if (state.phase === 'error' || (state.phase === 'exited' && !this.requestedStop)) this.failureLines = this.recentLogs(300);
      this.lastNative = state;
      this.emitStatus();
    }
    this.startPolling(state);
  }

  private noteHealthy(state: HostState): void {
    if (state.phase !== 'running' || this.attempt === null || this.markedHealthy || this.runMode === 'safe') return;
    const now = Date.now();
    if (this.runningSince === null) this.runningSince = now;
    if (now - this.runningSince < HEALTHY_MS) return;
    this.markedHealthy = true;
    // Unconfirmed, the run just stays counted as unclean: the safe side.
    this.recovery.markHealthy(this.attempt).then((): void => this.emitStatus()).catch((): void => {});
  }

  private noteLastGood(state: HostState): void {
    if (state.phase !== 'running' || this.requestedStop || this.attempt === null || this.runMode !== 'normal' ||
      this.pinnedProfile || this.bootProfile === null || this.runningSince === null || Date.now() - this.runningSince < 120000) return;
    this.pinnedProfile = true;
    // The running interval qualified this captured launch image. A later stop
    // does not substitute a newer disk configuration into this write.
    this.lkgPin = this.lastGood.pinBooted(this.bootProfile, Date.now()).catch((): void => {
      this.logNote('上次正常配置尚未确认保存；本次运行仍可继续。');
    });
  }

  reminderAccess(): string { return agentReminderAccess(this.context.applicationInfo.accessTokenId); }

  // For the log. Notices reach the person as they are, and these name the engine's
  // internals; what they need to know the app says itself, in their language.
  private logNote(text: string): void {
    const entry = this.logs.append(text, 'system');
    this.persistedLogs.append([entry]);
    this.emit(new Map<string, Object | null>([['type', 'logs'], ['entries', [entry.toMap()]]]));
  }

  private assertLkgStopped(): void {
    const state = nativeHostState();
    if ((nativeHostTouched() && peekNativeHost() === null) ||
      !((!state.consumed && state.phase === 'idle') || state.phase === 'exited' || state.phase === 'error')) {
      throw new RuntimeChannelError('ohos_lkg_engine_active', '请先停止本机引擎并等待真实退出，再恢复配置。');
    }
  }

  async lastKnownGood(): Promise<Map<string, Object | null>> {
    if (this.pending !== null) throw new RuntimeChannelError('ohos_lkg_busy', '运行时操作尚未完成。');
    const initialized = this.initialized;
    if (initialized === null || this.lkgRecovering || this.lastGood.blocked() || this.resetRequested || this.recovery.status().resetPending) {
      throw new RuntimeChannelError('ohos_lkg_pending', '启动或配置恢复尚未完成，未预览半套配置。');
    }
    this.pending = 'restore'; this.startPolling();
    try {
      // Read-only preview never initiates initialization or intent replay.
      await initialized;
      const state = nativeHostState();
      if (!(this.runMode === 'safe' && state.phase === 'running' && !this.requestedStop)) this.assertLkgStopped();
      await this.lkgPin;
      return await this.lastGood.preview();
    } finally { this.pending = null; this.startPolling(); }
  }

  async restoreLastKnownGood(): Promise<Map<string, Object | null>> {
    if (this.pending !== null) throw new RuntimeChannelError('ohos_lkg_busy', '运行时操作尚未完成。');
    if (this.resetRequested || this.recovery.status().resetPending) throw new RuntimeChannelError('ohos_restart_required', '重置尚未完成，请重新打开应用。');
    this.pending = 'restore'; this.startPolling();
    try {
      await this.initialize(); this.assertLkgStopped(); await this.lkgPin;
      const result = await this.lastGood.restore();
      this.logNote('主配置已恢复。');
      return result;
    } finally { this.pending = null; this.startPolling(); this.emitStatus(); }
  }

  async install(dropKept: boolean): Promise<void> {
    if (dropKept) throw new RuntimeChannelError('ohos_unsupported', '鸿蒙尚不支持丢弃已暂存的保留项，请先完成恢复。');
    if (this.pending !== null) throw new RuntimeChannelError('install_busy', '运行时正在安装或启动。');
    if (nativeHostTouched()) throw new RuntimeChannelError('ohos_restart_required', '本进程已尝试加载原生库，请重开应用后安装。');
    this.pending = 'install'; this.lastError = null;
    this.emitStatus();
    try {
      await this.initialize();
      if (this.manifest === null) {
        this.initialized = this.readInstallation();
        await this.initialized;
      }
      if (this.manifest === null) throw new RuntimeChannelError('ohos_payload_missing', this.setupError ?? 'HAP 中没有运行时载荷。');
      this.installed = null;
      if (this.recovery.status().waitingInstall) {
        await this.recovery.installPending((): Promise<void> => this.installPayload(), nativeHostTouched);
      } else {
        this.checkRecovery();
        await this.installPayload();
      }
      this.installed = await this.installer.installed();
      this.setupError = null;
    } catch (error) {
      if (this.recovery.status().resetPending) this.initialized = null;
      this.lastError = error instanceof RuntimeChannelError ? error.message : '运行时安装失败，保留中断记录；请重试安装。';
      throw error as Error;
    } finally {
      this.pending = null; this.emitStatus();
    }
  }

  async start(env: Map<string, Object> | null, phoneStorage: boolean, mode: string | null, visualReplies: boolean): Promise<void> {
    validateStartOptions(phoneStorage, mode);
    const environment = validateEnvironment(env);
    const native = nativeHostState();
    if (this.pending === 'start') return;
    if (this.pending !== null) throw new RuntimeChannelError('start_busy', '运行时正在安装。');
    this.pending = 'start'; this.startCancelled = false; this.lastError = null;
    this.startPolling();
    this.startBegan = Date.now();
    this.emitStatus();
    try {
      await this.initialize();
      this.traceStart('initialized');
      environment['DSH_APP_WORKSPACE_RECOVERY'] = this.workspaceRecovery ? '1' : '0';
      const selectedMode = await this.recovery.selectMode(mode);
      this.traceStart('mode ' + selectedMode);
      if ((native.phase === 'starting' || native.phase === 'running') && selectedMode === this.runMode) return;
      if (native.consumed) throw new RuntimeChannelError('ohos_restart_required', '启动模式已保存；一个 App 进程只启动一次 Node，请重新打开 App。');
      this.installed = await this.installer.installed();
      this.traceStart('installation read');
      if (!this.current()) throw new RuntimeChannelError('ohos_install_required', '运行时尚未完整安装到当前版本，请先安装。');
      const nativeLibraryDir = resolveNativeLibraryDir(this.context.bundleCodeDir, this.context.applicationInfo.nativeLibraryPath);
      const dshHome = this.paths.dshHome;
      const workspace = this.paths.workspace;
      const cache = this.context.cacheDir + '/dsh-runtime';
      await this.storage.ensureDirectory(dshHome);
      await this.storage.ensureDirectory(this.paths.agentsHome);
      await this.storage.ensureDirectory(this.paths.outputs);
      await this.storage.ensureDirectory(this.paths.linuxDirectory);
      await new OhosRuntimeStorage(this.context.resourceManager, this.context.cacheDir).ensureDirectory(cache);
      await this.writeInstructions(dshHome, workspace, visualReplies);
      this.traceStart('directories ready');
      if (this.startCancelled) throw new RuntimeChannelError('ohos_start_cancelled', '启动已取消。');
      if (selectedMode === 'safe') {
        this.logNote('安全模式使用独立的随包配置，不会改写原 web 配置；全局补丁和 .env 仍可能影响启动。');
      }
      Object.keys(environment).forEach((key: string) => this.logs.rememberSecret(environment[key]));
      const options: HostOptions = { runtimeRoot: this.installer.root, guestRoot: this.paths.guestRoot, dshHome: dshHome,
        workspaceRoots: [workspace], cacheDir: cache, nativeLibraryDir: nativeLibraryDir,
        linuxDirectory: this.paths.linuxDirectory, env: environment, safeMode: selectedMode === 'safe' };
      this.requestedStop = false;
      this.runtimeGeneration++;
      const host = await loadNativeHost();
      this.traceStart('native host loaded');
      this.bootProfile = null; this.pinnedProfile = false; this.runningSince = null; this.markedHealthy = false;
      if (selectedMode === 'normal') {
        try { this.bootProfile = await this.lastGood.captureBoot(); }
        catch (_) { this.logNote('本次启动配置无法建立可靠恢复快照；正常启动仍将继续。'); }
      }
      const attempt = util.generateRandomUUID();
      this.runMode = selectedMode;
      await this.recovery.arm(attempt, Date.now(), 'engineRun', selectedMode === 'safe');
      this.attempt = attempt;
      this.checkRecovery();
      if (this.startCancelled) throw new RuntimeChannelError('ohos_start_cancelled', '启动已取消。');
      host.start(options);
      this.traceStart('node started');
      this.bindOwner();
      this.startPolling();
    } catch (error) {
      if (this.attempt !== null && !nativeHostState().consumed) {
        const attempt = this.attempt; this.attempt = null;
        if (error instanceof RuntimeChannelError && (error.code === 'ohos_start_cancelled' || this.resetRequested)) await this.recovery.cancelBeforeStart(attempt);
        else await this.recovery.finish(attempt, false, Date.now(), 0, true);
      }
      if (!(error instanceof RuntimeChannelError && error.code === 'ohos_start_cancelled')) {
        this.lastError = error instanceof RuntimeChannelError ? error.message : '本机引擎启动失败，请检查随包原生库和运行时。';
      }
      throw error as Error;
    } finally {
      this.pending = null; this.collect(); this.emitStatus();
    }
  }

  private traceStart(step: string): void {
    hilog.info(0x3F00, 'DshRuntime', 'start %{public}s at %{public}d ms', step, Date.now() - this.startBegan);
  }

  // 下次启动改用独立的救援工作区索引；只在引擎停下时改，写入落盘后才算数。
  // 标记放在运行时目录里，重置时随运行时一起清掉，和 Android 一样。
  async setWorkspaceRecovery(enabled: boolean): Promise<void> {
    if (this.pending !== null || ['starting', 'running', 'stopping'].includes(nativeHostState().phase)) {
      throw new RuntimeChannelError('runtime_not_stopped', '引擎尚未停止，未切换工作区索引。');
    }
    try {
      if (enabled) await this.storage.writeTextAtomic(this.workspaceRecoveryPath(), '1\n');
      else await this.storage.removeFile(this.workspaceRecoveryPath());
    } catch (_error) {
      throw new RuntimeChannelError('workspace_recovery_save_failed', '工作区索引模式未保存。');
    }
    this.workspaceRecovery = enabled;
    this.emitStatus();
  }

  private workspaceRecoveryPath(): string {
    return this.installer.base + '/workspace-recovery';
  }

  async reset(keep: string[], reinstall: boolean): Promise<void> {
    // A restore cut short that can't finish must not lock out the one way past it:
    // the committed reset drops it on reopening. Only a write in progress waits.
    if (this.pending === 'restore' || this.lkgRecovering) throw new RuntimeChannelError('ohos_lkg_pending', '配置恢复尚未完成，未提交重置。');
    if (this.pending === 'install') throw new RuntimeChannelError('reset_busy', '安装进行中，未提交重置。');
    // Stop admission synchronously, including a loader currently awaiting I/O.
    this.resetRequested = true;
    await this.stop();
    await this.recovery.requestReset(keep, util.generateRandomUUID(), reinstall);
    try { this.emitStatus(); }
    finally {
      // Observer delivery cannot change the acknowledged durable transaction.
      throw new RuntimeChannelError('ohos_reset_committed', '重置请求已持久保存，需重新打开应用后继续。');
    }
  }

  stop(): Promise<void> {
    if (this.pending === 'start') this.startCancelled = true;
    this.requestedStop = true;
    this.startPolling();
    this.managedSkills.stop(this.runtimeGeneration);
    if (this.stopping !== null) return this.stopping;
    this.stopping = this.finishStop().finally((): void => { this.stopping = null; });
    return this.stopping;
  }

  private async finishStop(): Promise<void> {
    const state = nativeHostState();
    if (['starting', 'running'].includes(state.phase)) {
      // Linux can only be enabled through the authenticated, ready Node endpoint.
      // Keep JS and its native join callbacks alive until that service retires.
      if (state.baseUrl !== null && state.token !== null) {
        try { await this.linux.shutdown(state.baseUrl, state.token); }
        catch (error) {
          this.lastError = 'Linux 任务或资源收尾未确认，停止操作未完成；请查看 Linux 状态后重试。';
          this.emitStatus(); throw error as Error;
        }
      } else if (state.phase === 'running') {
        throw new RuntimeChannelError('ohos_linux_shutdown_unconfirmed', '运行中的引擎缺少可信控制入口，未停止 Node。');
      }
      this.retireOwner();
      this.lifecycle.runtime(null, null);
      peekNativeHost()?.stop();
      this.startPolling();
      this.emitStatus();
    }
  }

  private linuxHost(): HostState {
    const state = nativeHostState();
    if (state.phase !== 'running' || state.baseUrl === null || state.token === null) {
      throw new RuntimeChannelError('ohos_linux_engine_unavailable', '请先启动本机引擎；Linux 状态查询不会启动或安装引擎。');
    }
    return state;
  }

  getLinuxStatus(): Promise<string> {
    const state = this.linuxHost();
    return this.linux.getStatus(state.baseUrl as string, state.token as string);
  }

  setLinuxEnabled(enabled: boolean): Promise<string> {
    if (this.requestedStop || this.resetRequested) throw new RuntimeChannelError('ohos_linux_stopping', '引擎正在停止，未更改 Linux 开关。');
    const state = this.linuxHost();
    return this.linux.setEnabled(state.baseUrl as string, state.token as string, enabled);
  }

  setLinuxProxy(proxy: LinuxProxyConfiguration): Promise<string> {
    if (this.requestedStop || this.resetRequested) throw new RuntimeChannelError('ohos_linux_stopping', '引擎正在停止，未更改 Linux 代理。');
    const state = this.linuxHost();
    return this.linux.setProxy(state.baseUrl as string, state.token as string, proxy);
  }

  discardLinuxRetained(): Promise<string> {
    if (this.requestedStop || this.resetRequested) throw new RuntimeChannelError('ohos_linux_stopping', '引擎正在停止，未删除 Linux 数据。');
    const state = this.linuxHost();
    return this.linux.discardRetained(state.baseUrl as string, state.token as string);
  }

  runLinuxPrivateGuest(request: LinuxRunRequest): Promise<string> {
    if (this.requestedStop || this.resetRequested) throw new RuntimeChannelError('ohos_linux_stopping', '引擎正在停止，未开始 Linux 作业。');
    const state = this.linuxHost();
    return this.linux.runPrivateGuest(state.baseUrl as string, state.token as string, request);
  }

  private syncManagedSkills(state: HostState): void {
    if (state.phase === 'running' && state.token !== null && !this.requestedStop && this.pending === null) {
      this.managedSkills.ready(this.runtimeGeneration, state.token);
    } else if (state.phase === 'stopping' || this.requestedStop) {
      this.managedSkills.stop(this.runtimeGeneration);
    } else if (state.phase === 'idle' || state.phase === 'exited' || state.phase === 'error') {
      this.managedSkills.retire();
    }
  }

  recentLogs(lines: number): string[] {
    return this.logs.snapshot(lines).entries.map((entry: RuntimeLogEntry) => entry.line);
  }

  logSnapshot(lines: number): Map<string, Object | null> {
    return this.logs.snapshot(lines).toMap();
  }

  failureLog(): string[] { return this.failureLines.slice(); }

  async clearFailure(): Promise<void> {
    await this.recovery.clearFailure();
    this.failureLines = []; this.lastError = null; this.emitStatus();
  }

  async publishDiagnostics(markdown: string): Promise<Map<string, Object | null> | null> {
    const bytes = markdown.length === 0 ? new Uint8Array(0) : new util.TextEncoder().encodeInto(markdown);
    if (!this.current() || bytes.byteLength > 256 * 1024) return null;
    const directory = this.paths.dshHome + '/dsh-app';
    await this.storage.ensureDirectory(directory);
    const path = directory + '/diagnostics.md';
    await this.storage.writeTextAtomic(path, markdown);
    return new Map<string, Object | null>([['path', path], ['bytes', bytes.byteLength]]);
  }

  async networkMetered(): Promise<boolean | null> {
    try {
      const network = await connection.getDefaultNet();
      if (network.netId === 0) return null;
      const caps = (await connection.getNetCapabilities(network)).networkCap;
      return caps === undefined ? null : !caps.includes(connection.NetCap.NET_CAPABILITY_NOT_METERED);
    } catch (_) { return null; }
  }

  private async writeInstructions(home: string, workspace: string, visual: boolean): Promise<void> {
    const path = home + '/AGENTS.md';
    const marker = '<!-- dsh-app:managed';
    if (await this.storage.exists(path) && !(await this.storage.readText(path)).startsWith(marker)) return;
    let text = `${marker} — 删除这一行后，DSH App 不再覆盖本文件 -->\n# 运行环境（DSH 鸿蒙版）\n\n` +
      `- 你运行在鸿蒙 App 的进程内 Node 中，默认工作区是 \`${workspace}\`。\n` +
      `- 要交给用户的文件放在 \`${this.paths.outputs}\`；App 的产出列表只显示这个目录中的文件。\n` +
      '- bash、rg 和 git 等能力以引擎当前能力清单为准；没有 Android 的 Ubuntu、PRoot、apt 或 /sdcard 挂载。\n' +
      '- bash 里的 gh、python3、python、pip、pip3 交给 App 内 Linux 环境运行，看得到当前工作区；其他 Linux 程序用 `linux <命令>`。需要用户先在 设置 · 能力 · Linux 环境 打开；这些命令结束后一次性返回输出，同一时间只运行一个。\n' +
      '- 对不支持的命令说明限制，可请用户交给已连接的电脑执行；不能声称命令已经成功。\n' +
      '- 手机文件通过 App 的系统选择器导入或导出；不能遍历其他应用的数据。\n' +
      '- App 使用 Flutter 原生界面；不要把修改 Harness 网页当作修改 App 界面。\n';
    if (visual) text += '\n## 可视化回复（dsh-ui）\n\n' +
      '- 适合图表或卡片的真实数据可用 dsh-ui 围栏代码块，内容为单个 JSON 对象；普通对话用文字即可。\n' +
      '- 已支持的 type 包括 text、metric、chart、compare、steps、callout、options、confirm、stack、row；不知道字段时先查随包 dsh-go-ui 技能，不猜参数。\n' +
      '- 不在卡片收集密码、密钥或验证码；options/confirm 放在回复末尾，等待用户反馈后再继续。\n';
    await this.storage.writeTextAtomic(path, text);
  }
}
