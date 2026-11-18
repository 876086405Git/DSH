import fs from '@ohos.file.fs';
import fileHash from '@ohos.file.hash';
import util from '@ohos.util';
import common from '@ohos.app.ability.common';
import bundleManager from '@ohos.bundle.bundleManager';
import { BusinessError } from '@ohos.base';
import { RuntimeChannelError, resolveNativeLibraryDir } from './RuntimeCore';
import { OhosRuntimeStorage } from './OhosRuntimeStorage';
import { LkgStorage, LkgPair, LkgProfile, LkgVersion } from './RuntimeLastKnownGood';

export class OhosLastKnownGoodStorage implements LkgStorage {
  private context: common.Context;
  private metadata: OhosRuntimeStorage;
  private home: string;
  private records: string;
  private identityValue: Promise<string> | null = null;
  private static retired: fs.File[] = [];
  private static closing: Promise<void> = Promise.resolve();

  constructor(context: common.Context) {
    this.context = context;
    this.metadata = new OhosRuntimeStorage(context.resourceManager, context.filesDir);
    this.home = context.filesDir + '/runtime/rootfs/root/.dsh/profiles/web';
    this.records = context.filesDir + '/dsh-recovery';
  }
  private invalid(): never { throw new RuntimeChannelError('ohos_lkg_path', '恢复配置路径或文件类型无效。'); }
  private async parents(path: string): Promise<void> {
    const root = this.context.filesDir;
    if (!path.startsWith(root + '/') || path.includes('\0')) this.invalid();
    const parts = path.substring(root.length + 1).split('/');
    if (parts.some((part: string): boolean => part === '' || part === '.' || part === '..')) this.invalid();
    let parent = root;
    for (const part of parts.slice(0, -1)) {
      parent += '/' + part;
      let stat: fs.Stat;
      try { stat = await fs.lstat(parent); }
      catch (error) { if ((error as BusinessError).code === 13900002) return; throw error as Error; }
      if (!stat.isDirectory() || stat.isSymbolicLink()) this.invalid();
    }
  }
  private static closeRetired(): Promise<void> {
    const result = OhosLastKnownGoodStorage.closing.then(async (): Promise<void> => {
      while (OhosLastKnownGoodStorage.retired.length > 0) {
        await fs.close(OhosLastKnownGoodStorage.retired[0]);
        OhosLastKnownGoodStorage.retired.shift();
      }
    });
    OhosLastKnownGoodStorage.closing = result.catch((): void => {});
    return result;
  }
  private async close(file: fs.File): Promise<void> {
    OhosLastKnownGoodStorage.retired.push(file);
    await OhosLastKnownGoodStorage.closeRetired();
  }
  private async read(path: string, limit: number = 4 * 1024 * 1024): Promise<string | null> {
    await OhosLastKnownGoodStorage.closeRetired();
    await this.parents(path);
    let file: fs.File;
    try { file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW | fs.OpenMode.NONBLOCK); }
    catch (error) { if ((error as BusinessError).code === 13900002) return null; throw error as Error; }
    try {
      const stat = await fs.stat(file.fd);
      if (!stat.isFile() || stat.size > limit) this.invalid();
      const bytes = new Uint8Array(stat.size + 1);
      let used = 0;
      while (used < bytes.byteLength) {
        const chunk = new ArrayBuffer(Math.min(65536, bytes.byteLength - used));
        const count = await fs.read(file.fd, chunk, { offset: used, length: chunk.byteLength });
        if (count === 0) break;
        if (!Number.isSafeInteger(count) || count < 0 || count > chunk.byteLength) this.invalid();
        bytes.set(new Uint8Array(chunk, 0, count), used); used += count;
      }
      if (used !== stat.size) this.invalid();
      return util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(bytes.subarray(0, used));
    } finally { await this.close(file); }
  }
  private recordPath(name: string): string {
    if (!['lkg.json', 'lkg-restore.json', 'lkg-restore-backup.json'].includes(name)) this.invalid();
    return this.records + '/' + name;
  }
  readRecord(name: string): Promise<string | null> { return this.read(this.recordPath(name), 24 * 1024 * 1024); }
  async writeRecord(name: string, text: string): Promise<void> {
    const path = this.recordPath(name);
    if (text.length > 24 * 1024 * 1024) this.invalid();
    await this.metadata.ensureDirectory(this.records);
    await this.metadata.writeTextAtomic(path, text);
  }
  async removeIntent(): Promise<void> { await this.metadata.removeFile(this.recordPath('lkg-restore.json')); }

  async assertUnlocked(): Promise<void> {
    await this.parents(this.home + '/package.json');
    let entries: string[];
    try { entries = await fs.listFile(this.home, { recursion: false, listNum: 8193 }); }
    catch (error) { if ((error as BusinessError).code === 13900002) return; throw error as Error; }
    if (entries.length > 8192) this.invalid();
    if (entries.some((name: string): boolean => ['package.json.lock', 'cordis.patch.yml.lock'].some((lock: string): boolean =>
      name === lock || name.startsWith(lock + '.takeover-')))) {
      throw new RuntimeChannelError('ohos_lkg_locked', '主配置存在未结算写锁，未夺取或删除锁。');
    }
  }
  async profile(): Promise<LkgProfile | null> {
    const packageText = await this.read(this.home + '/package.json');
    if (packageText === null) return null;
    const pkg = JSON.parse(packageText) as Record<string, Object>;
    if (!pkg || typeof pkg !== 'object' || Array.isArray(pkg)) this.invalid();
    const dsh = pkg['dsh'] as Record<string, Object>;
    if (!dsh || typeof dsh !== 'object' || Array.isArray(dsh)) this.invalid();
    const profile = dsh['profile'] as Record<string, Object>;
    if (!profile || typeof profile !== 'object' || Array.isArray(profile)) this.invalid();
    const bundles = profile['bundles'] as string[];
    if (!Array.isArray(bundles) || bundles.length > 4096 || bundles.some((name: string): boolean => typeof name !== 'string' || name.length === 0 || name.length > 512) || new Set(bundles).size !== bundles.length) this.invalid();
    const deps = (pkg['dependencies'] ?? {}) as Record<string, Object>;
    if (typeof deps !== 'object' || Array.isArray(deps) || Object.keys(deps).length > 4096) this.invalid();
    const dependencies: LkgVersion[] = [];
    for (const name of Object.keys(deps)) {
      let version: string | null = null;
      // Unknown or symlinked third-party installation is never treated as a
      // proven matching version. Do not follow a package link out of this root.
      if (/^(?:@[A-Za-z0-9_.-]+\/)?[A-Za-z0-9_.-]+$/.test(name) && !name.split('/').some((part: string): boolean => part === '.' || part === '..')) {
        try {
          const text = await this.read(this.home + '/node_modules/' + name + '/package.json', 1024 * 1024);
          if (text !== null) {
            const installed = JSON.parse(text) as Record<string, Object>;
            if (typeof installed['version'] === 'string' && (installed['version'] as string).length > 0 && (installed['version'] as string).length <= 512) version = installed['version'] as string;
          }
        } catch (_) { /* unknown dependency version disables it during restore */ }
      }
      dependencies.push({ name, version });
    }
    const pair: LkgPair = { packageText, patchText: await this.read(this.home + '/cordis.patch.yml') };
    return { pair, bundles: bundles.slice(), dependencies };
  }
  async writePair(pair: LkgPair): Promise<void> {
    await this.assertUnlocked();
    await this.parents(this.home + '/package.json');
    await this.metadata.writeTextAtomic(this.home + '/package.json', pair.packageText);
    await this.assertUnlocked();
    if (pair.patchText === null) {
      await this.metadata.removeFile(this.home + '/cordis.patch.yml');
      // A prior unlink may have reached disk before its parent fsync failed.
      // Missing is not a durability receipt, so flush this fixed parent again.
      const file = await fs.open(this.home, fs.OpenMode.READ_ONLY | fs.OpenMode.DIR | fs.OpenMode.NOFOLLOW);
      try { await fs.fsync(file.fd); } finally { await this.close(file); }
    } else await this.metadata.writeTextAtomic(this.home + '/cordis.patch.yml', pair.patchText);
  }
  async identity(): Promise<string> {
    if (this.identityValue === null) this.identityValue = this.readIdentity().catch((error: Error): string => {
      this.identityValue = null; throw error;
    });
    const identity = this.identityValue;
    const hap = await identity;
    const manifest = this.context.filesDir + '/dsh-runtime/installed.json';
    if (await this.read(manifest, 16 * 1024 * 1024) === null) this.invalid();
    const manifestHash = await fileHash.hash(manifest, 'sha256');
    // Native HAP bytes are immutable for this process; installation can change
    // before first Node start, so the payload identity is deliberately uncached.
    return JSON.stringify({ hap, manifestHash });
  }
  private async readIdentity(): Promise<string> {
    const bundle = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_HAP_MODULE);
    const modules = bundle.hapModulesInfo.map((module: bundleManager.HapModuleInfo): string => {
      // A module only has a hash when its installer passed one, so a sideloaded HAP
      // has none. A config depends on the engine, and the native libraries and the
      // payload manifest still pin those bytes.
      if (!module.name || typeof module.hashValue !== 'string') this.invalid();
      return module.name + ':' + module.hashValue;
    }).sort();
    if (modules.length === 0) this.invalid();
    const directory = resolveNativeLibraryDir(this.context.bundleCodeDir, this.context.applicationInfo.nativeLibraryPath);
    const directoryStat = await fs.lstat(directory);
    if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) this.invalid();
    const entries = await fs.listFile(directory, { recursion: false, listNum: 1025 });
    if (entries.length > 1024 || !entries.includes('libnode.so') || !entries.includes('libdsh_host.so')) this.invalid();
    const libraries: string[] = [];
    for (const name of entries.filter((value: string): boolean => /\.so(?:\.[0-9]+)*$/.test(value)).sort()) {
      if (name.includes('/') || name.includes('\0') || name === '.' || name === '..') this.invalid();
      const path = directory + '/' + name;
      const stat = await fs.lstat(path);
      if (!stat.isFile() || stat.isSymbolicLink()) this.invalid();
      libraries.push(name + ':' + await fileHash.hash(path, 'sha256'));
    }
    return JSON.stringify({ bundle: bundle.name, version: bundle.versionCode, modules, libraries });
  }
}
