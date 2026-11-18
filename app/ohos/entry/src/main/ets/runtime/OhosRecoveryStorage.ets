import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { OhosRuntimeStorage } from './OhosRuntimeStorage';
import { RuntimeChannelError } from './RuntimeCore';
import { RecoveryStorage } from './RuntimeRecovery';

const REMOVE_LANES = 16;

// Only this private reset transaction may remove these two fixed runtime roots.
// Existing RuntimeStorage remains the owner of atomic metadata writes.
export class OhosRecoveryStorage implements RecoveryStorage {
  private root: string;
  private metadata: OhosRuntimeStorage;
  private static retired: fs.File[] = [];
  private static closing: Promise<void> = Promise.resolve();

  constructor(context: common.Context) {
    this.root = context.filesDir;
    this.metadata = new OhosRuntimeStorage(context.resourceManager, context.filesDir);
  }

  private invalid(): never { throw new RuntimeChannelError('ohos_recovery_path', '恢复路径不是受管理的私有运行时路径。'); }

  private async parents(path: string): Promise<void> {
    if (!path.startsWith(this.root + '/') || path.includes('\0')) this.invalid();
    const parts = path.substring(this.root.length + 1).split('/');
    if (parts.some((part: string) => part === '' || part === '.' || part === '..')) this.invalid();
    let current = this.root;
    for (const part of parts.slice(0, -1)) {
      current += '/' + part;
      let stat: fs.Stat;
      try { stat = await fs.lstat(current); }
      catch (error) { if ((error as BusinessError).code === 13900002) return; throw error as Error; }
      if (!stat.isDirectory() || stat.isSymbolicLink()) this.invalid();
    }
  }

  async kind(path: string): Promise<string> {
    await this.parents(path);
    let stat: fs.Stat;
    try { stat = await fs.lstat(path); }
    catch (error) { if ((error as BusinessError).code === 13900002) return 'missing'; throw error as Error; }
    if (stat.isSymbolicLink()) return 'symlink';
    if (stat.isFile()) return 'file';
    if (stat.isDirectory()) return 'directory';
    this.invalid();
  }

  private record(path: string): void {
    if (!['boot.json', 'reset.json', 'mode.json', 'lkg.json', 'lkg-restore.json', 'lkg-restore-backup.json']
      .some((name: string): boolean => path === this.root + '/dsh-recovery/' + name)) this.invalid();
  }

  async read(path: string): Promise<string | null> {
    this.record(path);
    const kind = await this.kind(path);
    if (kind === 'missing') return null;
    if (kind !== 'file') this.invalid();
    return this.metadata.readText(path);
  }

  async write(path: string, text: string): Promise<void> {
    this.record(path);
    await this.parents(path);
    await this.metadata.writeTextAtomic(path, text);
  }

  async mkdir(path: string): Promise<void> {
    if (!(path === this.root + '/dsh-recovery' || path.startsWith(this.root + '/dsh-recovery/') ||
      path === this.root + '/runtime' || path === this.root + '/runtime/rootfs' || path.startsWith(this.root + '/runtime/rootfs/'))) this.invalid();
    await this.parents(path);
    await this.metadata.ensureDirectory(path);
  }

  private static closeRetired(): Promise<void> {
    const pending = OhosRecoveryStorage.closing.then(async (): Promise<void> => {
      while (OhosRecoveryStorage.retired.length > 0) {
        await fs.close(OhosRecoveryStorage.retired[0]);
        OhosRecoveryStorage.retired.shift();
      }
    });
    OhosRecoveryStorage.closing = pending.catch((): void => {});
    return pending;
  }

  private async syncDirectory(path: string): Promise<void> {
    await OhosRecoveryStorage.closeRetired();
    const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.DIR | fs.OpenMode.NOFOLLOW);
    try { await fs.fsync(file.fd); }
    finally {
      OhosRecoveryStorage.retired.push(file);
      await OhosRecoveryStorage.closeRetired();
    }
  }

  async move(from: string, to: string): Promise<void> {
    const guest = this.root + '/runtime/rootfs/';
    const kept = this.root + '/dsh-recovery/keep-';
    if (!((from.startsWith(guest) && to.startsWith(kept)) || (from.startsWith(kept) && to.startsWith(guest)))) this.invalid();
    const source = await this.kind(from);
    if (source !== 'file' && source !== 'directory') this.invalid();
    if (await this.kind(to) !== 'missing') throw new RuntimeChannelError('ohos_recovery_conflict', '恢复路径两端冲突，未覆盖任何数据。');
    await fs.rename(from, to);
    await this.syncDirectory(from.substring(0, from.lastIndexOf('/')));
    await this.syncDirectory(to.substring(0, to.lastIndexOf('/')));
  }

  async removeFile(path: string): Promise<void> {
    if (!['reset.json', 'lkg.json', 'lkg-restore.json', 'lkg-restore-backup.json']
      .some((name: string): boolean => path === this.root + '/dsh-recovery/' + name)) this.invalid();
    await this.metadata.removeFile(path);
  }

  async removeTree(path: string): Promise<void> {
    const relative = path.startsWith(this.root + '/') ? path.substring(this.root.length + 1) : '';
    if (relative !== 'dsh-runtime' && relative !== 'runtime/rootfs' && !/^dsh-recovery\/keep-[a-f0-9-]{36}$/.test(relative)) this.invalid();
    const kind = await this.kind(path);
    if (kind === 'missing') return;
    if (kind === 'symlink') this.invalid();
    await this.removeOwned(path);
    await this.syncDirectory(path.substring(0, path.lastIndexOf('/')));
  }

  private async removeOwned(path: string): Promise<void> {
    // Recheck every child. A symlink is unlinked, never traversed.
    const stat = await fs.lstat(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) { await fs.unlink(path); return; }
    while (true) {
      const entries = await fs.listFile(path, { recursion: false, listNum: 128 });
      if (entries.length === 0) break;
      for (const name of entries) {
        if (name === '' || name === '.' || name === '..' || name.includes('/') || name.includes('\0')) this.invalid();
      }
      // A reset clears ~12k runtime files; one at a time took the phone close to a minute.
      for (let i = 0; i < entries.length; i += REMOVE_LANES) {
        await Promise.all(entries.slice(i, i + REMOVE_LANES).map((name: string): Promise<void> => this.removeOwned(path + '/' + name)));
      }
    }
    await fs.rmdir(path);
  }
}
