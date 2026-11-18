import { RuntimeChannelError } from './RuntimeCore';

export interface LkgPair { packageText: string; patchText: string | null; }
export interface LkgVersion { name: string; version: string | null; }
export interface LkgProfile { pair: LkgPair; bundles: string[]; dependencies: LkgVersion[]; }
export interface LkgBoot { identity: string; profile: LkgProfile; }
interface LkgRecord { schema: number; at: number; boot: LkgBoot; }
interface LkgIntent { schema: number; identity: string; before: LkgPair; target: LkgPair; }
export interface LkgStorage {
  identity(): Promise<string>;
  profile(): Promise<LkgProfile | null>;
  assertUnlocked(): Promise<void>;
  readRecord(name: string): Promise<string | null>;
  writeRecord(name: string, text: string): Promise<void>;
  removeIntent(): Promise<void>;
  writePair(pair: LkgPair): Promise<void>;
}
interface LkgPlan { target: string[]; disable: string[]; enable: string[]; changed: string[]; patchChanged: boolean; empty: boolean; }

function invalid(message: string): never { throw new RuntimeChannelError('ohos_lkg_invalid', message); }
function names(value: string[]): boolean {
  return Array.isArray(value) && value.length <= 4096 && value.every((name: string): boolean =>
    typeof name === 'string' && name.length > 0 && name.length <= 512 && !name.includes('\0')) && new Set(value).size === value.length;
}
function validPair(pair: LkgPair): boolean {
  if (pair === null || typeof pair !== 'object' || typeof pair.packageText !== 'string' || pair.packageText.length > 4 * 1024 * 1024 ||
    !(pair.patchText === null || (typeof pair.patchText === 'string' && pair.patchText.length <= 4 * 1024 * 1024))) return false;
  try {
    const pkg = JSON.parse(pair.packageText) as Record<string, Object>;
    if (!pkg || typeof pkg !== 'object' || Array.isArray(pkg)) return false;
    const dsh = pkg['dsh'] as Record<string, Object>;
    if (!dsh || typeof dsh !== 'object' || Array.isArray(dsh)) return false;
    const profile = dsh['profile'] as Record<string, Object>;
    return !!profile && typeof profile === 'object' && !Array.isArray(profile) && names(profile['bundles'] as string[]);
  } catch (_) { return false; }
}
function validBoot(boot: LkgBoot): boolean {
  if (!boot || typeof boot.identity !== 'string' || boot.identity.length === 0 || boot.identity.length > 65536 || !boot.profile ||
      !validPair(boot.profile.pair) || !names(boot.profile.bundles) || !Array.isArray(boot.profile.dependencies) || boot.profile.dependencies.length > 4096) return false;
  const dependencies = boot.profile.dependencies;
  return dependencies.every((item: LkgVersion): boolean => !!item && typeof item.name === 'string' && item.name.length > 0 &&
    (item.version === null || (typeof item.version === 'string' && item.version.length > 0 && item.version.length <= 512))) &&
    new Set(dependencies.map((item: LkgVersion): string => item.name)).size === dependencies.length;
}
function plan(saved: LkgProfile, current: LkgProfile): LkgPlan {
  const target = saved.bundles.filter((name: string): boolean => {
    const previous = saved.dependencies.find((item: LkgVersion): boolean => item.name === name);
    const present = current.dependencies.find((item: LkgVersion): boolean => item.name === name);
    // A former builtin shadowed by a third-party dependency is not the saved builtin.
    if (previous === undefined) return present === undefined;
    return previous.version !== null && present !== undefined && present.version === previous.version;
  });
  const disable = current.bundles.filter((name: string): boolean => !target.includes(name));
  const enable = target.filter((name: string): boolean => !current.bundles.includes(name));
  const changed = saved.bundles.filter((name: string): boolean => current.bundles.includes(name) && !target.includes(name) &&
    current.dependencies.some((item: LkgVersion): boolean => item.name === name));
  const patchChanged = saved.pair.patchText !== current.pair.patchText;
  return { target, disable, enable, changed, patchChanged,
    empty: !patchChanged && JSON.stringify(target) === JSON.stringify(current.bundles) };
}
function targetPair(current: LkgPair, bundles: string[], patch: string | null): LkgPair {
  const pkg = JSON.parse(current.packageText) as Record<string, Object>;
  if (!pkg || Array.isArray(pkg) || typeof pkg !== 'object') invalid('主配置不是有效对象。');
  const dsh = pkg['dsh'] as Record<string, Object>;
  const profile = dsh['profile'] as Record<string, Object>;
  profile['bundles'] = bundles.slice();
  return { packageText: JSON.stringify(pkg, null, 2) + '\n', patchText: patch };
}

// Capture/restore/recovery require no Node writer. Safe-running preview is read-only
// and grants no later write permission. This class never takes over a DSH writer lock.
export class RuntimeLastKnownGood {
  private storage: LkgStorage;
  private pending: boolean = false;
  constructor(storage: LkgStorage) { this.storage = storage; }
  blocked(): boolean { return this.pending; }

  async captureBoot(): Promise<LkgBoot | null> {
    await this.storage.assertUnlocked();
    const profile = await this.storage.profile();
    if (profile === null) return null;
    const boot: LkgBoot = { identity: await this.storage.identity(), profile };
    if (!validBoot(boot)) invalid('不能确认本次启动配置与运行时身份。');
    return JSON.parse(JSON.stringify(boot)) as LkgBoot;
  }

  // Called only after this normal run reached 120 seconds. No configuration read.
  async pinBooted(boot: LkgBoot | null, at: number): Promise<void> {
    if (boot === null) return;
    if (!validBoot(boot) || !Number.isSafeInteger(at) || at < 0) invalid('健康配置记录无效。');
    const record: LkgRecord = { schema: 1, at, boot };
    await this.storage.writeRecord('lkg.json', JSON.stringify(record));
  }

  private async record(): Promise<LkgRecord | null> {
    const text = await this.storage.readRecord('lkg.json');
    if (text === null) return null;
    const value = JSON.parse(text) as LkgRecord;
    if (!value || value.schema !== 1 || !Number.isSafeInteger(value.at) || value.at < 0 || !validBoot(value.boot)) invalid('上次正常配置记录损坏，未猜测恢复。');
    return value;
  }

  private result(record: LkgRecord | null, change: LkgPlan | null, reason: string | null = null): Map<string, Object | null> {
    return new Map<string, Object | null>([['available', record !== null && change !== null], ['at', record?.at ?? null],
      ['disable', change?.disable ?? []], ['enable', change?.enable ?? []], ['changed', change?.changed ?? []],
      ['patchChanged', change?.patchChanged ?? false], ['empty', change?.empty ?? true], ['reason', reason]]);
  }

  async preview(): Promise<Map<string, Object | null>> {
    if (this.pending || await this.storage.readRecord('lkg-restore.json') !== null) throw new RuntimeChannelError('ohos_lkg_pending', '配置恢复尚未完成，未预览半套配置。');
    const record = await this.record();
    if (record === null) return this.result(null, null);
    if (record.boot.identity !== await this.storage.identity()) return this.result(record, null, 'runtime_or_hap_changed');
    await this.storage.assertUnlocked();
    const current = await this.storage.profile();
    return current === null ? this.result(record, null, 'profile_missing') : this.result(record, plan(record.boot.profile, current));
  }

  async restore(): Promise<Map<string, Object | null>> {
    if (this.pending) throw new RuntimeChannelError('ohos_lkg_pending', '配置恢复尚未完成，请重新打开应用继续。');
    const record = await this.record();
    if (record === null || record.boot.identity !== await this.storage.identity()) invalid('没有与当前运行时和安装包匹配的正常配置。');
    await this.storage.assertUnlocked();
    const current = await this.storage.profile();
    if (current === null) invalid('找不到主配置，未创建猜测配置。');
    const change = plan(record.boot.profile, current);
    const intent: LkgIntent = { schema: 1, identity: record.boot.identity, before: current.pair,
      target: targetPair(current.pair, change.target, record.boot.profile.pair.patchText) };
    // Ambiguous durable-write failure must close admission, even before a caller
    // can establish whether intent rename reached disk.
    this.pending = true;
    await this.storage.writeRecord('lkg-restore-backup.json', JSON.stringify(intent));
    await this.storage.writeRecord('lkg-restore.json', JSON.stringify(intent));
    await this.applyIntent(intent);
    return this.result(record, change);
  }

  async recoverPending(): Promise<void> {
    const text = await this.storage.readRecord('lkg-restore.json');
    if (text === null) { this.pending = false; return; }
    this.pending = true;
    const intent = JSON.parse(text) as LkgIntent;
    if (!intent || intent.schema !== 1 || typeof intent.identity !== 'string' || !validPair(intent.before) || !validPair(intent.target)) invalid('配置恢复意图损坏，未写主配置。');
    await this.applyIntent(intent);
  }

  private async applyIntent(intent: LkgIntent): Promise<void> {
    if (intent.identity !== await this.storage.identity()) invalid('恢复意图属于另一运行时或安装包，未混用配置。');
    await this.storage.assertUnlocked();
    const current = await this.storage.profile();
    if (current === null || (current.pair.packageText !== intent.before.packageText && current.pair.packageText !== intent.target.packageText) ||
      (current.pair.patchText !== intent.before.patchText && current.pair.patchText !== intent.target.patchText)) {
      throw new RuntimeChannelError('ohos_lkg_conflict', '配置在恢复途中被更改，保留备份和当前文件，未覆盖。');
    }
    // Always re-establish durability after a previous uncertain rename/fsync.
    await this.storage.writePair(intent.target);
    const after = await this.storage.profile();
    if (after === null || after.pair.packageText !== intent.target.packageText || after.pair.patchText !== intent.target.patchText) invalid('配置恢复后字节不一致，未清除意图。');
    await this.storage.removeIntent();
    this.pending = false;
  }
}
