// API 26 folder authorization and native FD handoff; device verification remains separate.
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import { loadNativeHost, peekNativeHost } from '../runtime/NativeHost';
import fileUri from '@ohos.file.fileuri';
import fileShare from '@ohos.fileshare';
import preferences from '@ohos.data.preferences';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import common from '@ohos.app.ability.common';
import UIAbility from '@ohos.app.ability.UIAbility';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import {
  AbilityAware, AbilityPluginBinding, Any, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { NativeFileError, nativeFileName, nativeFileUris } from './NativeFilePolicy';

const FOLDER_SELECTION: string = 'SystemCapability.FileManagement.UserFileService.FolderSelection';
const FOLDER_AUTHORIZATION: string = 'SystemCapability.FileManagement.AppFileService.FolderAuthorization';
const PERSIST_PERMISSION = 'ohos.permission.FILE_ACCESS_PERSIST';
const foreground: WeakSet<UIAbility> = new WeakSet();
const foregroundVersions: WeakMap<UIAbility, number> = new WeakMap();
const bootId: string = util.generateRandomUUID(false);

class WorkspaceError extends Error {
  code: string;
  details: Map<string, Any> | null;
  constructor(code: string, message: string, details: Map<string, Any> | null = null) {
    super(message); this.code = code; this.details = details;
  }
}

interface SavedWorkspace { id: string; uri: string; }

function folderUri(value: string): string {
  const selected = nativeFileUris([value], 1)[0];
  if (!selected.startsWith('file://docs/')) throw new WorkspaceError('invalid', '请选择文件管理中的文件夹。');
  return selected;
}

class WorkspaceRecord {
  readonly id: string;
  readonly uri: string;
  generation: number = 0;
  authorization: string = 'needsRestore';
  persistence: string = 'unknown';
  nativeGeneration: number = 0;
  nativeState: string = 'unattached';
  pendingFile: fs.File | null = null;
  nativeKey(): string { return bootId + ':' + this.id; }
  retireNative(): void {
    if (this.nativeGeneration === 0 || this.nativeState === 'quarantined') return;
    const host = peekNativeHost();
    if (host === null) { this.nativeState = 'quarantined'; return; }
    try {
      const result = host.workspaceGrant('retire', this.nativeKey(), this.nativeGeneration);
      this.nativeState = result.drained ? 'drained' : 'draining';
    } catch (_) { this.nativeState = 'quarantined'; }
  }
  constructor(id: string, uri: string) { this.id = id; this.uri = folderUri(uri); }
  change(authorization: string, persistence: string = this.persistence): void {
    this.retireNative();
    this.generation++; this.authorization = authorization; this.persistence = persistence;
  }
  metadata(): Map<string, Any> {
    const converted = new fileUri.FileUri(this.uri);
    let path: string | null = null;
    try { path = converted.path; } catch (_) { /* Conversion is not an access check. */ }
    return new Map<string, Any>([
      ['id', this.id], ['uri', this.uri], ['name', nativeFileName(converted.name)],
      ['candidatePath', path], ['generation', this.generation], ['authorization', this.authorization],
      ['persistence', this.persistence], ['nativeGrant', this.nativeState], ['nativeGeneration', this.nativeGeneration], ['nativeKey', this.nativeGeneration === 0 ? null : this.nativeKey()], ['nodeAccess', 'unverified'], ['engineAttached', false]
    ]);
  }
  policy(): fileShare.PolicyInfo {
    return { uri: this.uri, operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE };
  }
}

// Only IDs and picker-origin URIs are stored. OS persistence is queried on restore,
// never inferred from a local flag that could outlive revoke or a failed flush.
class WorkspaceRecords {
  private store: preferences.Preferences;
  private invalidationVersion: number = 0;
  values: WorkspaceRecord[];
  constructor(store: preferences.Preferences, values: WorkspaceRecord[]) { this.store = store; this.values = values; }
  static async load(context: common.Context): Promise<WorkspaceRecords> {
    const store = await preferences.getPreferences(context, { name: 'dsh-authorized-workspaces-v1' });
    const raw: Any = await store.get('records', '[]');
    if (typeof raw !== 'string') throw new WorkspaceError('storage', '工作区记录无法读取。');
    const saved: Any = JSON.parse(raw as string);
    if (!Array.isArray(saved)) throw new WorkspaceError('storage', '工作区记录无法读取。');
    const ids: Set<string> = new Set(); const uris: Set<string> = new Set();
    const values: WorkspaceRecord[] = [];
    for (const item of saved as SavedWorkspace[]) {
      if (typeof item.id !== 'string' || !/^[0-9a-f-]{36}$/.test(item.id) || typeof item.uri !== 'string' ||
          ids.has(item.id) || uris.has(item.uri)) throw new WorkspaceError('storage', '工作区记录无法读取。');
      values.push(new WorkspaceRecord(item.id, item.uri)); ids.add(item.id); uris.add(item.uri);
    }
    return new WorkspaceRecords(store, values);
  }
  async save(values: WorkspaceRecord[]): Promise<void> {
    const invalidationVersion = this.invalidationVersion;
    const saved: SavedWorkspace[] = values.map((value: WorkspaceRecord): SavedWorkspace => ({ id: value.id, uri: value.uri }));
    await this.store.put('records', JSON.stringify(saved));
    await this.store.flush();
    // New picker records are still local while put/flush is pending. A
    // background event must retire their access evidence before publication,
    // even when the ability returned to foreground before persistence ended.
    if (this.invalidationVersion !== invalidationVersion) {
      values.forEach((value: WorkspaceRecord): void => {
        if (['selected', 'activated'].includes(value.authorization)) value.change('needsRevalidation');
      });
    }
    this.values = values;
  }
  find(id: Any): WorkspaceRecord {
    const value = this.values.find((item: WorkspaceRecord): boolean => item.id === id);
    if (value === undefined) throw new WorkspaceError('not_found', '请先通过系统选择器授权此文件夹。');
    return value;
  }
  snapshot(): Map<string, Any> {
    return new Map<string, Any>([['protocol', 1], ['bootId', bootId], ['engineAttached', false],
      ['workspaces', this.values.map((value: WorkspaceRecord): Map<string, Any> => value.metadata())]]);
  }
  invalidate(): void {
    this.invalidationVersion++;
    this.values.forEach((value: WorkspaceRecord): void => value.change(
      ['selected', 'activated'].includes(value.authorization) ? 'needsRevalidation' : value.authorization));
  }
}

let records: WorkspaceRecords | null = null;
let loading: Promise<WorkspaceRecords> | null = null;
let physicalBusy: boolean = false;
let ownerEngine: FlutterPluginBinding | null = null;
let ownerAbility: UIAbility | null = null;

async function getRecords(context: common.Context): Promise<WorkspaceRecords> {
  if (records !== null) return records;
  if (loading === null) loading = WorkspaceRecords.load(context).then((value: WorkspaceRecords): WorkspaceRecords => {
    records = value; return value;
  }).catch((error: Error): WorkspaceRecords => { loading = null; throw error; });
  return loading;
}

function persistencePermission(context: common.Context): string {
  if (!canIUse('SystemCapability.Security.AccessToken')) return 'unknown';
  try {
    const value = abilityAccessCtrl.createAtManager().checkAccessTokenSync(context.applicationInfo.accessTokenId, PERSIST_PERMISSION);
    return value === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED ? 'granted' : 'denied';
  } catch (_) { return 'unknown'; }
}

class WorkspaceOperation {
  published: WorkspaceRecord | null = null;
  pending: MethodResult | null;
  active: boolean = true;
  timer: number = -1;
  foregroundVersion: number;
  constructor(result: MethodResult, version: number) { this.pending = result; this.foregroundVersion = version; }
}

export default class AuthorizedWorkspacesPlugin implements FlutterPlugin, AbilityAware {
  private engine: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private channel: MethodChannel | null = null;
  private operation: WorkspaceOperation | null = null;

  static onForeground(ability: UIAbility): void { foreground.add(ability); }
  static onBackground(ability: UIAbility): void {
    foreground.delete(ability); foregroundVersions.set(ability, (foregroundVersions.get(ability) ?? 0) + 1);
    if (ownerAbility === ability) records?.invalidate();
  }
  getUniqueClassName(): string { return 'DshAuthorizedWorkspacesPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (ownerEngine !== null && ownerEngine !== binding) records?.invalidate();
    ownerEngine = binding; ownerAbility = null;
    this.cancel(); this.channel?.setMethodCallHandler(null); this.engine = binding; this.ability = null;
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/authorized-workspaces');
    this.channel.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (this.engine !== binding || ownerEngine !== binding) { this.fail(result, new WorkspaceError('cancelled', '工作区通道已关闭。') as Error); return; }
      if (call.method === 'capabilities') {
        this.success(result, new Map<string, Any>([['protocol', 1], ['folderSelection', canIUse(FOLDER_SELECTION)],
          ['folderAuthorization', canIUse(FOLDER_AUTHORIZATION)],
          ['persistencePermission', persistencePermission(binding.getApplicationContext())], ['engineAttached', false]]));
      } else if (call.method === 'cancel') { this.cancel(); this.success(result, null); }
      else if (['list', 'select', 'attach', 'persist', 'activate', 'deactivate', 'revoke', 'forget'].includes(call.method)) this.start(call, result);
      else { try { result.notImplemented(); } catch (_) { /* Retired messenger. */ } }
    } });
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engine !== binding) return;
    if (ownerEngine === binding) { records?.invalidate(); ownerEngine = null; ownerAbility = null; }
    this.cancel(); this.channel?.setMethodCallHandler(null); this.channel = null; this.engine = null; this.ability = null;
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability !== binding) { this.cancel(); if (this.ability !== null && this.engine === ownerEngine) records?.invalidate(); }
    this.ability = binding; if (this.engine === ownerEngine) ownerAbility = binding.getAbility();
  }
  onDetachedFromAbility(): void {
    if (this.engine === ownerEngine) { records?.invalidate(); ownerAbility = null; }
    this.cancel(); this.ability = null;
  }

  private success(result: MethodResult, value: Any): void { try { result.success(value); } catch (_) { /* Retired messenger. */ } }
  private fail(result: MethodResult, error: Error): void {
    try {
      if (error instanceof WorkspaceError) result.error(error.code, error.message, error.details);
      else if (error instanceof NativeFileError) result.error(error.code, error.message, null);
      else result.error('failed', '工作区操作未完成，请重试。', null);
    } catch (_) { /* Retired messenger. */ }
  }
  private cancel(): void {
    const operation = this.operation;
    if (operation === null) return;
    operation.active = false; clearTimeout(operation.timer);
    // Publication can precede the asynchronous close of the borrowed URI FD.
    // Cancelling the response must retire that new grant immediately as well.
    operation.published?.change('needsRevalidation');
    operation.published = null;
    const pending = operation.pending; operation.pending = null;
    if (pending !== null) this.fail(pending, new WorkspaceError('cancelled', '工作区操作已取消。') as Error);
    // physicalBusy survives detach/timeout until the OS operation really returns.
  }
  private current(operation: WorkspaceOperation): void {
    if (!operation.active || this.operation !== operation || this.engine !== ownerEngine) throw new WorkspaceError('cancelled', '工作区操作已取消。');
  }
  private requireForeground(ability: AbilityPluginBinding | null, operation: WorkspaceOperation): void {
    if (ability === null || !foreground.has(ability.getAbility()) ||
        (foregroundVersions.get(ability.getAbility()) ?? 0) !== operation.foregroundVersion) {
      throw new WorkspaceError('user_gesture', '请回到应用前台，点击工作区操作。');
    }
  }
  private start(call: MethodCall, result: MethodResult): void {
    const engine = this.engine; const ability = this.ability;
    if (engine === null || (call.method !== 'list' && (ability === null ||
        !foreground.has(ability.getAbility()) || call.argument('userGesture') !== true))) {
      this.fail(result, new WorkspaceError('user_gesture', '请回到应用前台，点击工作区操作。') as Error); return;
    }
    if (physicalBusy) { this.fail(result, new WorkspaceError('busy', '上一项系统目录操作尚未结束，请稍后重试。') as Error); return; }
    const operation = new WorkspaceOperation(result, ability === null ? 0 : foregroundVersions.get(ability.getAbility()) ?? 0);
    this.operation = operation; physicalBusy = true;
    operation.timer = setTimeout((): void => this.cancel(), 5 * 60 * 1000);
    this.perform(call, engine.getApplicationContext(), ability, operation).then((value: Any): void => {
      const pending = operation.pending; operation.pending = null;
      this.finished(operation); if (pending !== null) this.success(pending, value);
    }, (error: Error): void => {
      const pending = operation.pending; operation.pending = null;
      this.finished(operation); if (pending !== null) this.fail(pending, error);
    });
  }
  private finished(operation: WorkspaceOperation): void {
    clearTimeout(operation.timer); physicalBusy = false;
    if (this.operation === operation) this.operation = null;
  }

  private async perform(call: MethodCall, context: common.Context, ability: AbilityPluginBinding | null,
    operation: WorkspaceOperation): Promise<Any> {
    const state = await getRecords(context); this.current(operation);
    if (call.method === 'list') {
      if (!canIUse(FOLDER_AUTHORIZATION) || persistencePermission(context) !== 'granted') {
        state.values.forEach((entry: WorkspaceRecord): void => {
          if (entry.authorization === 'needsRestore') entry.change('needsReauthorization', 'unavailable');
        });
      }
      return state.snapshot();
    }
    this.requireForeground(ability, operation);
    if (call.method === 'select') {
      if (!canIUse(FOLDER_SELECTION)) throw new WorkspaceError('unsupported', '此设备没有系统文件夹选择能力。');
      const options = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FOLDER; options.allowsMulFolderSelection = true;
      const selected = await new picker.DocumentViewPicker(ability!.getAbility().context).select(options);
      this.current(operation);
      const uris = nativeFileUris(selected, selected.length).map((value: string): string => folderUri(value));
      const values = state.values.slice();
      for (const uri of uris) {
        let entry = values.find((value: WorkspaceRecord): boolean => value.uri === uri);
        if (entry === undefined) { entry = new WorkspaceRecord(util.generateRandomUUID(false), uri); values.push(entry); }
        entry.change('selected', 'unknown');
      }
      if (uris.length > 0) await state.save(values);
      this.current(operation); return state.snapshot();
    }
    const id: Any = call.argument('id'); const entry = state.find(id);
    if (call.method === 'attach') {
      if (!['selected', 'activated'].includes(entry.authorization)) throw new WorkspaceError('reauthorize', '请重新选择或激活工作区。');
      if (entry.pendingFile !== null || entry.nativeState === 'quarantined') throw new WorkspaceError('native_quarantined', '上次目录句柄清理未确认，请重启后重新选择。');
      const generation = entry.generation;
      const host = await loadNativeHost(); this.current(operation); this.requireForeground(ability, operation);
      if (entry.generation !== generation) throw new WorkspaceError('reauthorize', '授权代际已失效，请重新选择。');
      if (entry.nativeGeneration > 0) {
        const previous = host.workspaceGrant('status', entry.nativeKey(), entry.nativeGeneration);
        if (previous.active && previous.generation === generation) return state.snapshot();
        if (!previous.drained) throw new WorkspaceError('native_draining', '旧工作区任务尚未释放，请等待其结束。');
      }
      try {
        entry.pendingFile = await fs.open(entry.uri, fs.OpenMode.READ_ONLY | fs.OpenMode.NONBLOCK);
        const stat = await fs.stat(entry.pendingFile.fd);
        this.current(operation); this.requireForeground(ability, operation);
        if (entry.generation !== generation) throw new WorkspaceError('reauthorize', '授权代际已失效，请重新选择。');
        if (!stat.isDirectory()) throw new WorkspaceError('not_directory', '所选资源没有可用的目录句柄。');
        // Picker temporary or explicitly activated READ|WRITE grant. Actual
        // operations still undergo OS checks; opening a directory is not proof of writable children.
        host.workspaceGrant('publish', entry.nativeKey(), generation, entry.pendingFile.fd, true);
        entry.nativeGeneration = generation; entry.nativeState = 'ready'; operation.published = entry;
      } catch (error) { entry.retireNative(); throw error as Error; }
      finally {
        if (entry.pendingFile !== null) {
          try { await fs.close(entry.pendingFile); entry.pendingFile = null; }
          catch (_) { entry.retireNative(); entry.nativeState = 'quarantined'; throw new WorkspaceError('native_close_failed', '目录句柄关闭未确认，工作区保持不可用。'); }
        }
      }
      this.current(operation); return state.snapshot();
    }
    if (call.method === 'forget') {
      entry.change('needsReauthorization');
      if (entry.pendingFile !== null || entry.nativeState === 'draining' || entry.nativeState === 'quarantined') throw new WorkspaceError('native_draining', '工作区资源尚未释放，暂不能移除记录。');
      // This is deliberately not a claim that an OS grant was revoked.
      await state.save(state.values.filter((value: WorkspaceRecord): boolean => value !== entry));
      this.current(operation);
      const result: Map<string, Any> = state.snapshot(); result.set('osGrantChanged', false); return result;
    }
    if (call.method === 'deactivate' || call.method === 'revoke') {
      entry.change('needsRevalidation');
      if (entry.nativeState === 'quarantined') throw new WorkspaceError('native_quarantined', '原生工作区退休未确认，不能报告撤销完成。');
    }
    if (!canIUse(FOLDER_AUTHORIZATION) || persistencePermission(context) !== 'granted') {
      throw new WorkspaceError('persistence_unavailable', '此安装没有可用的持久授权能力；请重新选择文件夹使用临时授权。');
    }
    const policy = [entry.policy()];
    try {
      if (call.method === 'persist') {
        if (!['selected', 'activated'].includes(entry.authorization)) {
          throw new WorkspaceError('reauthorize', '请重新选择文件夹后再保存授权。');
        }
        await fileShare.persistPermission(policy); entry.change(entry.authorization, 'persisted');
      } else {
        const persisted = await fileShare.checkPersistentPermission(policy); this.current(operation);
        this.requireForeground(ability, operation);
        if (persisted.length !== 1 || persisted[0] !== true) {
          entry.change('needsReauthorization', 'absent');
          if (call.method === 'revoke') return state.snapshot();
          throw new WorkspaceError('reauthorize', '没有可恢复的持久授权，请重新选择此文件夹。');
        }
        entry.persistence = 'persisted';
        if (call.method === 'activate') {
          const generation = entry.generation;
          await fileShare.activatePermission(policy);
          entry.change(entry.generation === generation ? 'activated' : 'needsRevalidation');
        } else if (call.method === 'deactivate') {
          await fileShare.deactivatePermission(policy); entry.change('needsActivation');
        } else if (call.method === 'revoke') {
          await fileShare.revokePermission(policy); entry.change('needsReauthorization', 'absent');
        }
      }
    } catch (error) {
      if (error instanceof WorkspaceError) throw error;
      const failure = error as BusinessError<fileShare.PolicyErrorResult[]>;
      const details: Map<string, Any> = new Map<string, Any>([['operation', call.method], ['id', entry.id], ['systemCode', failure.code]]);
      if (failure.data) {
        const policyFailure = failure.data.find((value: fileShare.PolicyErrorResult): boolean => value.uri === entry.uri);
        if (policyFailure !== undefined) details.set('policyCode', policyFailure.code);
      }
      entry.change('needsRevalidation');
      throw new WorkspaceError('system_authorization_failed', '系统未完成目录授权操作，请重新选择此文件夹。', details);
    }
    this.current(operation); return state.snapshot();
  }
}
