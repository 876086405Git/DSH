// 未经 HarmonyOS SDK 编译、未在真机核实。Node 停止的 Linux 证据不替代 OH NAPI 验证。
import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import connection from '@ohos.net.connection';
import UIAbility from '@ohos.app.ability.UIAbility';
import type { HostState, HostEvent, HostOptions } from 'libdsh_host.so';
import { loadNativeHost, peekNativeHost, nativeHostState } from './NativeHost';
import { RuntimeChannelError, RuntimeManifest, RuntimeFile, RuntimeInstaller, RuntimeLogs, RuntimeLogEntry,
  InstallProgress, validateEnvironment, validateStartOptions, resolveNativeLibraryDir } from './RuntimeCore';
import { OhosRuntimeStorage } from './OhosRuntimeStorage';
import { RuntimePaths } from './RuntimePaths';
import { ManagedSkillService, ManagedSkillScope } from './ManagedSkillService';
import { PersistedRuntimeLog } from './PersistedRuntimeLog';
import { RuntimeLifecycle } from './RuntimeLifecycle';
import { OhosLifecycleTransport } from './OhosLifecycleTransport';
import { backgroundComputePermission } from './BackgroundCompute';

type RuntimeSink = (event: Map<string, Object | null>) => void;
const LIFECYCLE_NOTICE = '前后台状态尚未同步，本机任务可能仍在暂停或运行；正在重试。';

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
  private lastLifecycleError: string | null = null;
  private sinks: RuntimeSink[] = [];
  private initialized: Promise<void> | null = null;
  private manifest: RuntimeManifest | null = null;
  private installed: RuntimeManifest | null = null;
  private setupError: string | null = null;
  private lastError: string | null = null;
  private failureLines: string[] = [];
  private pending: string | null = null;
  private startCancelled: boolean = false;
  private requestedStop: boolean = false;
  private timer: number | null = null;
  private lastNative: HostState | null = null;
  private runtimeGeneration: number = 0;

  static get(context: common.Context): RuntimeController {
    if (RuntimeController.shared === null) RuntimeController.shared = new RuntimeController(context);
    return RuntimeController.shared;
  }

  static onForeground(ability: UIAbility): void {
    RuntimeController.ability = ability; RuntimeController.foreground = true;
    RuntimeController.shared?.lifecycle.observe(true);
  }

  static onBackground(ability: UIAbility): void {
    if (RuntimeController.ability !== ability) return;
    RuntimeController.foreground = false;
    RuntimeController.shared?.lifecycle.observe(false);
  }

  static onDestroy(ability: UIAbility): void {
    RuntimeController.onBackground(ability);
    if (RuntimeController.ability === ability) RuntimeController.ability = null;
  }

  constructor(context: common.Context) {
    this.context = context;
    this.persistedLogs = PersistedRuntimeLog.get(context.filesDir);
    this.lifecycle = new RuntimeLifecycle(new OhosLifecycleTransport(),
      (): string => backgroundComputePermission(context.applicationInfo.accessTokenId),
      (): void => this.lifecycleChanged());
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
    this.startPolling();
  }

  initialize(): Promise<void> {
    if (this.initialized === null) this.initialized = this.readInstallation();
    return this.initialized;
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
    if (this.manifest === null || this.installed === null ||
        this.manifest.runtimeVersion !== this.installed.runtimeVersion ||
        this.manifest.dshVersion !== this.installed.dshVersion ||
        this.manifest.nodeVersion !== this.installed.nodeVersion ||
        this.manifest.files.length !== this.installed.files.length) return false;
    const files = new Map<string, RuntimeFile>();
    this.installed.files.forEach((file: RuntimeFile) => files.set(file.path, file));
    return this.manifest.files.every((file: RuntimeFile) => {
      const other = files.get(file.path);
      return other !== undefined && other.sha256 === file.sha256 && other.size === file.size;
    });
  }

  snapshot(): Map<string, Object | null> {
    const native = nativeHostState();
    this.syncManagedSkills(native);
    let phase = this.current() ? 'installed' : 'notInstalled';
    if (this.pending === 'install') phase = 'installing';
    else if (this.pending === 'start') phase = 'starting';
    else if (native.phase === 'starting' || native.phase === 'running' || native.phase === 'stopping') phase = native.phase;
    else if (native.phase === 'error' || (native.phase === 'exited' && !this.requestedStop)) phase = 'error';
    else if (this.lastError !== null || this.setupError !== null) phase = 'error';
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
      ['mode', 'normal'], ['safeState', 'off'], ['safeReason', null], ['strikes', 0], ['autoSafe', false],
      ['failure', null], ['mainFailure', null], ['healthyAt', null], ['networkBlocked', false], ['networkBlockedAt', null],
      ['directEngineEnabled', false], ['directEngineAvailable', false], ['directEngineActive', false],
      ['directEngineFallbackReason', null], ['currentExecutionMode', active ? 'ohos-embedded' : null],
      ['launchSelectedMode', native.consumed ? 'ohos-embedded' : null], ['launchSpawned', native.consumed],
      ['launchFailureReason', failure], ['tidyingFiles', false], ['lifecycle', this.lifecycle.status()]
    ]);
  }

  private lifecycleChanged(): void {
    const error = this.lifecycle.failureCode();
    if (error !== null && error !== this.lastLifecycleError) {
      this.emit(new Map<string, Object | null>([['type', 'notice'], ['text', LIFECYCLE_NOTICE]]));
    }
    this.lastLifecycleError = error;
    this.emitStatus();
  }

  subscribe(sink: RuntimeSink): void {
    this.sinks.push(sink);
    this.initialize().then(() => {
      if (this.sinks.includes(sink)) sink(new Map<string, Object | null>([['type', 'status'], ['status', this.snapshot()]]));
    });
  }

  unsubscribe(sink: RuntimeSink): void {
    this.sinks = this.sinks.filter((other: RuntimeSink) => other !== sink);
  }

  private emit(event: Map<string, Object | null>): void {
    this.sinks.forEach((sink: RuntimeSink) => sink(event));
  }

  private emitStatus(): void {
    this.emit(new Map<string, Object | null>([['type', 'status'], ['status', this.snapshot()]]));
  }

  private startPolling(): void {
    const state = nativeHostState();
    if (this.timer === null && ['starting', 'running', 'stopping'].includes(state.phase)) {
      this.timer = setInterval(() => this.collect(), 100);
    }
  }

  collect(): void {
    const state = nativeHostState();
    const finished = (state.phase === 'exited' || state.phase === 'error') && this.lastNative?.phase !== state.phase;
    this.lifecycle.runtime(state.phase === 'running' && !this.requestedStop ? state.baseUrl : null,
      state.phase === 'running' && !this.requestedStop ? state.token : null);
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
    if (!['starting', 'running', 'stopping'].includes(state.phase) && this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  async install(dropKept: boolean): Promise<void> {
    if (dropKept) throw new RuntimeChannelError('ohos_unsupported', '鸿蒙没有 Android 的保留数据恢复事务。');
    if (this.pending !== null) throw new RuntimeChannelError('install_busy', '运行时正在安装或启动。');
    if (nativeHostState().consumed) throw new RuntimeChannelError('ohos_restart_required', '本进程已经启动过 Node，请关闭并重新打开 App 后安装。');
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
      const manifest: RuntimeManifest = this.manifest;
      await this.storage.withBundledRuntime(async (): Promise<void> => {
        await this.installer.install(manifest, (progress: InstallProgress) => this.emit(new Map<string, Object | null>([
          ['type', 'progress'], ['step', progress.step], ['done', progress.done], ['total', progress.total]
        ])));
      });
      this.installed = await this.installer.installed();
      this.setupError = null;
    } catch (error) {
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
    if (native.phase === 'starting' || native.phase === 'running' || this.pending === 'start') return;
    if (native.consumed) throw new RuntimeChannelError('ohos_restart_required', '一个 App 进程只启动一次 Node，请关闭并重新打开 App。');
    if (this.pending !== null) throw new RuntimeChannelError('start_busy', '运行时正在安装。');
    this.pending = 'start'; this.startCancelled = false; this.lastError = null;
    this.emitStatus();
    try {
      await this.initialize();
      this.installed = await this.installer.installed();
      if (!this.current()) throw new RuntimeChannelError('ohos_install_required', '运行时尚未完整安装到当前版本，请先安装。');
      const nativeLibraryDir = resolveNativeLibraryDir(this.context.bundleCodeDir, this.context.applicationInfo.nativeLibraryPath);
      const dshHome = this.paths.dshHome;
      const workspace = this.paths.workspace;
      const cache = this.context.cacheDir + '/dsh-runtime';
      await this.storage.ensureDirectory(dshHome);
      await this.storage.ensureDirectory(this.paths.agentsHome);
      await this.storage.ensureDirectory(this.paths.outputs);
      await new OhosRuntimeStorage(this.context.resourceManager, this.context.cacheDir).ensureDirectory(cache);
      await this.writeInstructions(dshHome, workspace, visualReplies);
      if (this.startCancelled) throw new RuntimeChannelError('ohos_start_cancelled', '启动已取消。');
      Object.keys(environment).forEach((key: string) => this.logs.rememberSecret(environment[key]));
      const options: HostOptions = { runtimeRoot: this.installer.root, guestRoot: this.paths.guestRoot, dshHome: dshHome,
        workspaceRoots: [workspace], cacheDir: cache, nativeLibraryDir: nativeLibraryDir, env: environment };
      this.requestedStop = false;
      this.runtimeGeneration++;
      const host = await loadNativeHost();
      if (this.startCancelled) throw new RuntimeChannelError('ohos_start_cancelled', '启动已取消。');
      host.start(options);
      this.startPolling();
    } catch (error) {
      if (!(error instanceof RuntimeChannelError && error.code === 'ohos_start_cancelled')) {
        this.lastError = error instanceof RuntimeChannelError ? error.message : '本机引擎启动失败，请检查随包原生库和运行时。';
      }
      throw error as Error;
    } finally {
      this.pending = null; this.collect(); this.emitStatus();
    }
  }

  stop(): void {
    if (this.pending === 'start') this.startCancelled = true;
    this.requestedStop = true;
    this.lifecycle.runtime(null, null);
    this.managedSkills.stop(this.runtimeGeneration);
    const state = nativeHostState();
    if (['starting', 'running', 'stopping'].includes(state.phase)) {
      peekNativeHost()?.stop();
      this.startPolling();
      this.emitStatus();
    }
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

  clearFailure(): void {
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
