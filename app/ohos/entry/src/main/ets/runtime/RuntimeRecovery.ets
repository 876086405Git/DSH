import { RuntimeChannelError } from './RuntimeCore';

// All paths come from Context.filesDir. The adapter must not follow links,
// overwrite an existing move target, or report a failed durable write as done.
export interface RecoveryStorage {
  read(path: string): Promise<string | null>;
  write(path: string, text: string): Promise<void>;
  kind(path: string): Promise<string>;
  mkdir(path: string): Promise<void>;
  move(from: string, to: string): Promise<void>;
  removeFile(path: string): Promise<void>;
  removeTree(path: string): Promise<void>;
}

export interface RecoveryFailure {
  kind: string;
  at: number;
  exitCode: number;
  safeMode: boolean;
  summary: string;
}
interface ActiveRun { id: string; at: number; phase: string; safeMode?: boolean; }
interface ModeRecord { schema: number; mode: string; }
interface BootRecord { schema: number; strikes: number; active: ActiveRun | null; failure: RecoveryFailure | null; }
interface ResetRecord { schema: number; id: string; keep: string[]; reinstall: boolean; stage: string; kept: string[]; restored: string[]; restorePending: string | null; }
export interface RecoveryStatus { nextMode: string; strikes: number; failure: RecoveryFailure | null; resetPending: boolean; waitingInstall: boolean; }

const UI_PATHS: string[] = ['root/.dsh/dsh-go', 'root/.dsh/skills', 'root/.agents/skills'];
const PLUGIN_PATHS: string[] = ['root/.dsh/profiles', 'root/.dsh/cordis.patch.yml', 'root/.dsh/.env'];
const STAGES: string[] = ['saving', 'deleting', 'waitingInstall', 'installing', 'restoring', 'complete'];
function fail(message: string): never { throw new RuntimeChannelError('ohos_recovery_invalid', message); }
function fresh(): BootRecord { return { schema: 1, strikes: 0, active: null, failure: null }; }
function validId(id: string): boolean { return typeof id === 'string' && /^[a-f0-9-]{36}$/.test(id); }
function keptPaths(keep: string[]): string[] {
  if (!Array.isArray(keep) || keep.length > 2 || keep.some((value: string) => value !== 'uiAndSkills' && value !== 'pluginsAndSettings') || new Set(keep).size !== keep.length) {
    fail('恢复保留选项无效，未删除任何运行时数据。');
  }
  return (keep.includes('uiAndSkills') ? UI_PATHS : []).concat(keep.includes('pluginsAndSettings') ? PLUGIN_PATHS : []);
}
function bootRecord(text: string | null): BootRecord {
  if (text === null) return fresh();
  const record = JSON.parse(text) as BootRecord;
  if (!record || record.schema !== 1 || !Number.isSafeInteger(record.strikes) || record.strikes < 0 || record.strikes > 2147483647 ||
    (record.active !== null && (!record.active || !validId(record.active.id) || !Number.isSafeInteger(record.active.at) || record.active.at < 0 || !['nativeLoad', 'engineRun'].includes(record.active.phase) ||
      (record.active.safeMode !== undefined && typeof record.active.safeMode !== 'boolean'))) ||
    (record.failure !== null && (!record.failure || !['killed', 'launchFailed'].includes(record.failure.kind) ||
      !Number.isSafeInteger(record.failure.at) || record.failure.at < 0 || !Number.isSafeInteger(record.failure.exitCode) || typeof record.failure.safeMode !== 'boolean' || typeof record.failure.summary !== 'string' || record.failure.summary.length > 500))) {
    fail('启动恢复记录损坏，请明确重置运行环境；未自动清空数据。');
  }
  return record;
}
function resetRecord(text: string): ResetRecord {
  const record = JSON.parse(text) as ResetRecord;
  if (!record || record.schema !== 1 || !validId(record.id) || !STAGES.includes(record.stage) || typeof record.reinstall !== 'boolean' || (record.stage === 'waitingInstall' && record.reinstall)) fail('重置事务记录无效，未猜测删除路径。');
  const paths = keptPaths(record.keep);
  if (!Array.isArray(record.kept) || record.kept.length > paths.length || new Set(record.kept).size !== record.kept.length || record.kept.some((path: string) => !paths.includes(path))) {
    fail('重置保留记录无效，未删除保留数据。');
  }
  if (!Array.isArray(record.restored) || new Set(record.restored).size !== record.restored.length || record.restored.some((path: string) => !record.kept.includes(path)) ||
    (record.restorePending !== null && (!record.kept.includes(record.restorePending) || record.restored.includes(record.restorePending))) ||
    (record.stage !== 'restoring' && record.restorePending !== null) ||
    (record.stage === 'complete' && record.restored.length !== record.kept.length) ||
    (['saving', 'deleting', 'waitingInstall', 'installing'].includes(record.stage) && record.restored.length !== 0)) fail('保留项恢复收据无效，未跳过恢复步骤。');
  return record;
}

// One instance per filesDir in the application process. initialize is idempotent;
// a later process alone interprets the persisted active run as an unclean exit.
export class RuntimeRecovery {
  readonly directory: string;
  readonly guestRoot: string;
  readonly payloadRoot: string;
  private storage: RecoveryStorage;
  private boot: BootRecord = fresh();
  private nextMode: string = 'normal';
  private pending: Promise<void> = Promise.resolve();
  private initialized: Promise<void> | null = null;
  private resetPending: boolean = false;
  private waitingInstall: boolean = false;

  constructor(storage: RecoveryStorage, filesDir: string) {
    if (!filesDir.startsWith('/') || filesDir === '/' || filesDir.endsWith('/') || filesDir.includes('\0') || filesDir.split('/').slice(1).some((part: string) => part === '' || part === '.' || part === '..')) fail('应用文件目录无效。');
    this.storage = storage;
    this.directory = filesDir + '/dsh-recovery';
    this.guestRoot = filesDir + '/runtime/rootfs';
    this.payloadRoot = filesDir + '/dsh-runtime';
  }

  private serial(work: () => Promise<void>): Promise<void> {
    const result = this.pending.then(work);
    this.pending = result.catch((): void => {});
    return result;
  }

  status(): RecoveryStatus {
    const failure = this.boot.failure;
    return { nextMode: this.nextMode, strikes: this.boot.strikes, resetPending: this.resetPending, waitingInstall: this.waitingInstall,
      failure: failure === null ? null : { kind: failure.kind, at: failure.at, exitCode: failure.exitCode,
        safeMode: failure.safeMode, summary: failure.summary } };
  }

  initialize(now: number, install: () => Promise<void>, nativeLoaded: () => boolean): Promise<void> {
    if (this.initialized === null) {
      this.initialized = this.serial(async (): Promise<void> => {
        await this.storage.mkdir(this.directory);
        const text = await this.storage.read(this.directory + '/reset.json');
        if (text !== null) {
          this.resetPending = true;
          if (nativeLoaded()) throw new RuntimeChannelError('ohos_restart_required', '运行时原生库已加载，请重新打开应用后完成重置。');
          await this.recoverReset(resetRecord(text), install, nativeLoaded);
          if (this.waitingInstall) { this.boot = fresh(); return; }
        }
        this.nextMode = this.readMode(await this.storage.read(this.directory + '/mode.json'));
        const boot = bootRecord(await this.storage.read(this.directory + '/boot.json'));
        if (boot.active !== null) {
          if (boot.active.safeMode !== true) boot.strikes = Math.min(2147483647, boot.strikes + 1);
          boot.failure = this.failure(boot.active.phase === 'nativeLoad' ? 'launchFailed' : 'killed', now, 0, boot.active.safeMode === true);
          boot.active = null;
          await this.storage.write(this.directory + '/boot.json', JSON.stringify(boot));
        }
        this.boot = boot;
      }).catch((error: Error): void => { this.initialized = null; throw error; });
    }
    return this.initialized;
  }

  private readMode(text: string | null): string {
    if (text === null) return 'normal';
    const record = JSON.parse(text) as ModeRecord;
    if (!record || record.schema !== 1 || !['normal', 'safe'].includes(record.mode)) fail('启动模式记录损坏，未猜测启动配置。');
    return record.mode;
  }

  async selectMode(mode: string | null): Promise<string> {
    await this.serial(async (): Promise<void> => {
      if (this.initialized === null || this.resetPending) fail('启动恢复尚未完成。');
      if (mode !== null && mode !== 'normal' && mode !== 'safe') fail('启动模式无效。');
      const selected = mode ?? this.readMode(await this.storage.read(this.directory + '/mode.json'));
      if (mode !== null) {
        const record: ModeRecord = { schema: 1, mode: selected };
        // Do not acknowledge/reopen after an uncertain durable write. Repeating
        // an explicit request writes again, even if rename had already happened.
        await this.storage.write(this.directory + '/mode.json', JSON.stringify(record));
      }
      this.nextMode = selected;
    });
    return this.nextMode;
  }

  arm(id: string, at: number, phase: string = 'engineRun', safeMode: boolean = false): Promise<void> {
    return this.serial(async (): Promise<void> => {
      if (!validId(id) || !Number.isSafeInteger(at) || at < 0 || !['nativeLoad', 'engineRun'].includes(phase)) fail('启动标识无效。');
      if (this.initialized === null || this.resetPending) fail('启动恢复尚未完成。');
      const boot = bootRecord(await this.storage.read(this.directory + '/boot.json'));
      if (boot.active !== null) fail('已有启动标记，不能重用执行代际。');
      boot.active = { id, at, phase, safeMode };
      await this.storage.write(this.directory + '/boot.json', JSON.stringify(boot));
      this.boot = boot;
    });
  }

  finish(id: string, clean: boolean, at: number, exitCode: number = 0, launchFailed: boolean = false): Promise<void> {
    return this.serial(async (): Promise<void> => {
      const boot = bootRecord(await this.storage.read(this.directory + '/boot.json'));
      if (boot.active === null || boot.active.id !== id) return;
      if (!Number.isSafeInteger(at) || at < 0 || !Number.isSafeInteger(exitCode)) fail('退出记录无效。');
      const nativeLoad = boot.active.phase === 'nativeLoad';
      const safeMode = boot.active.safeMode === true;
      boot.active = null;
      if (!clean || !nativeLoad) {
        if (!safeMode) boot.strikes = clean ? 0 : Math.min(2147483647, boot.strikes + 1);
        boot.failure = clean ? null : this.failure(launchFailed || nativeLoad ? 'launchFailed' : 'killed', at, exitCode, safeMode);
      }
      await this.storage.write(this.directory + '/boot.json', JSON.stringify(boot));
      this.boot = boot;
    });
  }

  // The current run got past starting up, so its end, whenever and however it comes,
  // doesn't say the next start will fail. Only short runs in a row add up.
  markHealthy(id: string): Promise<void> {
    return this.serial(async (): Promise<void> => {
      const boot = bootRecord(await this.storage.read(this.directory + '/boot.json'));
      if (boot.active === null || boot.active.id !== id || (boot.strikes === 0 && boot.failure === null)) return;
      boot.strikes = 0; boot.failure = null;
      await this.storage.write(this.directory + '/boot.json', JSON.stringify(boot));
      this.boot = boot;
    });
  }

  cancelBeforeStart(id: string): Promise<void> {
    return this.serial(async (): Promise<void> => {
      const boot = bootRecord(await this.storage.read(this.directory + '/boot.json'));
      if (boot.active === null || boot.active.id !== id) return;
      boot.active = null;
      await this.storage.write(this.directory + '/boot.json', JSON.stringify(boot));
      this.boot = boot;
    });
  }

  clearFailure(): Promise<void> {
    return this.serial(async (): Promise<void> => {
      const boot = bootRecord(await this.storage.read(this.directory + '/boot.json'));
      boot.failure = null;
      await this.storage.write(this.directory + '/boot.json', JSON.stringify(boot));
      this.boot = boot;
    });
  }

  requestReset(keep: string[], id: string, reinstall: boolean = false): Promise<void> {
    return this.serial(async (): Promise<void> => {
      keptPaths(keep);
      if (!validId(id) || typeof reinstall !== 'boolean') fail('重置标识或安装选择无效。');
      await this.storage.mkdir(this.directory);
      const previous = await this.storage.read(this.directory + '/reset.json');
      if (previous !== null) {
        resetRecord(previous);
        throw new RuntimeChannelError('ohos_reset_pending', '已有重置请求，请重新打开应用继续，未覆盖原保留选择。');
      }
      if (await this.storage.kind(this.directory + '/keep-' + id) !== 'missing') fail('重置保留目录已存在，未接管未知数据。');
      const record: ResetRecord = { schema: 1, id, keep: keep.slice(), reinstall, stage: 'saving', kept: [], restored: [], restorePending: null };
      // A failed acknowledgement can follow a committed rename. Admission must
      // remain closed in this process even when the request reports an error.
      this.resetPending = true;
      try { await this.saveReset(record); }
      catch (_) {
        // The storage boundary may fail before or after rename/fsync. Neither
        // file existence nor an exception proves a durable commit outcome.
        throw new RuntimeChannelError('ohos_reset_commit_unknown', '重置请求的持久提交结果未知，未自动重开应用。');
      }
    });
  }

  installPending(install: () => Promise<void>, nativeLoaded: () => boolean): Promise<void> {
    return this.serial(async (): Promise<void> => {
      const text = await this.storage.read(this.directory + '/reset.json');
      if (text === null) fail('没有等待安装的重置事务。');
      const record = resetRecord(text);
      if (record.stage !== 'waitingInstall') fail('重置尚未进入等待安装阶段。');
      if (nativeLoaded()) throw new RuntimeChannelError('ohos_restart_required', '原生库已经加载，请重开应用后安装。');
      this.resetPending = true;
      record.stage = 'installing';
      await this.saveReset(record);
      this.waitingInstall = false;
      await this.recoverReset(record, install, nativeLoaded);
      this.boot = bootRecord(await this.storage.read(this.directory + '/boot.json'));
    }).catch((error: Error): void => { if (this.resetPending) this.initialized = null; throw error; });
  }

  private failure(kind: string, at: number, exitCode: number, safeMode: boolean = false): RecoveryFailure {
    return { kind, at, exitCode, safeMode: safeMode,
      summary: kind === 'launchFailed' ? '本机引擎启动未完成。' : '上次引擎没有确认干净退出，具体原因未知。' };
  }

  private saveReset(record: ResetRecord): Promise<void> {
    return this.storage.write(this.directory + '/reset.json', JSON.stringify(record));
  }

  private async recoverReset(record: ResetRecord, install: () => Promise<void>, nativeLoaded: () => boolean): Promise<void> {
    const keepRoot = this.directory + '/keep-' + record.id;
    const assertUnloaded = (): void => {
      if (nativeLoaded()) throw new RuntimeChannelError('ohos_restart_required', '原生库已经加载，未继续删除或安装。');
    };
    assertUnloaded();
    if (record.stage === 'saving') {
      await this.storage.mkdir(keepRoot);
      for (const relative of keptPaths(record.keep)) {
        const from = this.guestRoot + '/' + relative;
        const to = keepRoot + '/' + relative;
        const sourceKind = await this.storage.kind(from);
        const targetKind = await this.storage.kind(to);
        if (sourceKind === 'symlink' || targetKind === 'symlink') fail('保留项是符号链接，未移动或删除目标。');
        if (record.kept.includes(relative) && sourceKind === 'missing' && targetKind === 'missing') fail('已记录的保留项缺失，未继续删除原数据。');
        if (sourceKind !== 'missing' && targetKind !== 'missing') fail('保留项两端均存在，未覆盖任何一端。');
        if (sourceKind !== 'missing') {
          await this.storage.mkdir(to.substring(0, to.lastIndexOf('/')));
          assertUnloaded();
          await this.storage.move(from, to);
        }
        if (sourceKind !== 'missing' || targetKind !== 'missing') {
          if (!record.kept.includes(relative)) record.kept.push(relative);
          await this.saveReset(record);
        }
      }
      record.stage = 'deleting'; await this.saveReset(record);
    }
    if (record.stage === 'deleting' || record.stage === 'waitingInstall' || record.stage === 'installing') {
      for (const relative of record.kept) {
        const kind = await this.storage.kind(keepRoot + '/' + relative);
        if (kind !== 'file' && kind !== 'directory') fail('已保留的数据不可读取，未继续删除或重装。');
      }
    }
    if (record.stage === 'deleting') {
      assertUnloaded(); await this.storage.removeTree(this.payloadRoot);
      assertUnloaded(); await this.storage.removeTree(this.guestRoot);
      // The last good config goes with the profile it describes, as Android's does
      // with its runtime directory. A restore cut short can't finish on what replaces it.
      for (const name of ['lkg-restore.json', 'lkg-restore-backup.json', 'lkg.json']) {
        await this.storage.removeFile(this.directory + '/' + name);
      }
      record.stage = record.reinstall ? 'installing' : 'waitingInstall'; await this.saveReset(record);
    }
    if (record.stage === 'waitingInstall') { this.waitingInstall = true; return; }
    if (record.stage === 'installing') {
      assertUnloaded(); await install();
      record.stage = 'restoring'; await this.saveReset(record);
    }
    if (record.stage === 'restoring') {
      for (const relative of record.kept) {
        const from = keepRoot + '/' + relative;
        const to = this.guestRoot + '/' + relative;
        const sourceKind = await this.storage.kind(from);
        const targetKind = await this.storage.kind(to);
        if (sourceKind === 'symlink' || targetKind === 'symlink') fail('恢复项为符号链接，未覆盖目标。');
        if (record.restored.includes(relative)) {
          if (sourceKind !== 'missing' || (targetKind !== 'file' && targetKind !== 'directory')) fail('已恢复项与收据不一致。');
          continue;
        }
        if (sourceKind !== 'missing' && targetKind !== 'missing') fail('恢复项两端均存在，保留原数据等待处理。');
        if (sourceKind === 'missing') {
          if (targetKind === 'missing' || record.restorePending !== relative) fail('缺少已保留数据或恢复意图，未接管未知目标。');
        } else {
          if (record.restorePending !== null && record.restorePending !== relative) fail('另一个保留项恢复尚未确认。');
          await this.storage.mkdir(to.substring(0, to.lastIndexOf('/')));
          record.restorePending = relative;
          await this.saveReset(record);
          assertUnloaded(); await this.storage.move(from, to);
        }
        record.restored.push(relative);
        record.restorePending = null;
        await this.saveReset(record);
      }
      record.stage = 'complete'; await this.saveReset(record);
    }
    // A persisted completion receipt does not replace checking the retained
    // bytes after reopening. Never clear pending after those bytes disappeared.
    for (const relative of record.restored) {
      const target = await this.storage.kind(this.guestRoot + '/' + relative);
      if ((target !== 'file' && target !== 'directory') || await this.storage.kind(keepRoot + '/' + relative) !== 'missing') {
        fail('已恢复保留项与完成记录不一致，未清除重置标记。');
      }
    }
    assertUnloaded();
    await this.storage.write(this.directory + '/boot.json', JSON.stringify(fresh()));
    const normal: ModeRecord = { schema: 1, mode: 'normal' };
    await this.storage.write(this.directory + '/mode.json', JSON.stringify(normal));
    this.nextMode = 'normal';
    await this.storage.removeTree(keepRoot);
    await this.storage.removeFile(this.directory + '/reset.json');
    this.resetPending = false;
    this.waitingInstall = false;
  }
}
