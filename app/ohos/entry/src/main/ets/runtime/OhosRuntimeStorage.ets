// 未经 HarmonyOS SDK 编译、未在真机核实。公开 API 签名核对见 runtime-channel.md。
import fs from '@ohos.file.fs';
import fileHash from '@ohos.file.hash';
import resourceManager from '@ohos.resourceManager';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import { RuntimeChannelError, RuntimeFile, RuntimeManifest, RuntimeStorage, validPayloadPath } from './RuntimeCore';
import { OhosRuntimeArchive } from './OhosRuntimeArchive';

const SYNC_LANES = 16;

export class OhosRuntimeStorage implements RuntimeStorage {
  private static textWrites: Promise<void> = Promise.resolve();
  private static retiredFiles: fs.File[] = [];
  private static closes: Promise<void> = Promise.resolve();
  private filesDir: string;
  private archive: OhosRuntimeArchive;
  private installBase: string | null = null;
  private installDirectories: Set<string> | null = null;
  // Directories already checked as real directories during this install. Each of ~12k
  // files used to lstat every ancestor several times, which cost the phone minutes.
  private checkedDirectories: Set<string> | null = null;

  constructor(resources: resourceManager.ResourceManager, filesDir: string) {
    this.filesDir = filesDir;
    this.archive = new OhosRuntimeArchive(resources);
  }

  readBundledManifest(): Promise<RuntimeManifest> {
    return this.archive.readManifest();
  }

  withBundledRuntime(work: () => Promise<void>): Promise<void> {
    return this.archive.withBundledRuntime(work);
  }


  async withInstallFiles(base: string, ownedPaths: string[], work: () => Promise<void>): Promise<void> {
    if (this.installBase !== null) throw new RuntimeChannelError('install_busy', '运行时正在安装。');
    const relative = base.substring(this.filesDir.length + 1);
    if (!base.startsWith(this.filesDir + '/') || relative.split('/').some((part: string) =>
        part === '' || part === '.' || part === '..') || !ownedPaths.every((path: string) => validPayloadPath(path))) {
      throw new RuntimeChannelError('ohos_path_outside', '运行时安装目录或归属路径无效。');
    }
    await this.checkParents(base + '/tree');
    // Include the validated journal's OLD paths as well as the current manifest.
    // A previous interrupted batch may be reused by SHA or may already have
    // removed an obsolete directory; its surviving ancestors still need sync.
    const directories = new Set<string>([base, base + '/tree', base + '/staging']);
    for (const path of ownedPaths) {
      let parent = base + '/tree';
      for (const part of path.split('/').slice(0, -1)) {
        parent += '/' + part;
        directories.add(parent);
      }
    }
    this.installBase = base;
    this.installDirectories = directories;
    this.checkedDirectories = new Set<string>();
    try {
      await work();
      await this.flushInstallDirectories(base, directories);
    } finally {
      this.checkedDirectories = null;
      this.installDirectories = null;
      this.installBase = null;
    }
  }

  private async flushInstallDirectories(base: string, directories: Set<string>): Promise<void> {
    const levels = new Map<number, string[]>();
    for (const directory of directories) {
      const depth = directory.split('/').length;
      const level = levels.get(depth);
      if (level === undefined) levels.set(depth, [directory]);
      else level.push(directory);
    }
    const depths = Array.from(levels.keys()).sort((a: number, b: number) => a - b);
    const live: string[][] = [];
    const absent = new Set<string>();
    // Inspect top-down so a legitimate old directory replaced by a file does
    // not turn descendant lstat into ENOTDIR. Only actual ENOENT is ignored.
    // One depth at a time, its directories together: ~2.5k one by one took the phone seconds.
    for (const depth of depths) {
      const present: string[] = [];
      await this.inLanes(levels.get(depth) as string[], async (directory: string): Promise<void> => {
        const parent = directory.substring(0, directory.lastIndexOf('/'));
        if (absent.has(parent)) { absent.add(directory); return; }
        let stat: fs.Stat;
        try {
          stat = await fs.lstat(directory);
        } catch (error) {
          if ((error as BusinessError).code !== 13900002) throw error as Error;
          if (directory === base || directory === base + '/tree' || directory === base + '/staging') throw error as Error;
          absent.add(directory);
          return;
        }
        if (stat.isSymbolicLink()) throw new RuntimeChannelError('ohos_path_link', '运行时提交目录不能为符号链接。');
        if (!stat.isDirectory()) {
          if (!stat.isFile() || directory === base || directory === base + '/tree' || directory === base + '/staging') {
            throw new RuntimeChannelError('ohos_path_link', '运行时提交路径不是目录。');
          }
          absent.add(directory);
          return;
        }
        present.push(directory);
      });
      live.push(present);
    }
    // File data was already fsynced before each rename. Publish directory
    // entries children-first (a whole depth before its parents), before
    // installed.json or journal removal.
    for (const level of live.reverse()) {
      await this.inLanes(level, async (directory: string): Promise<void> => {
        await this.checkParents(directory + '/.entry');
        await this.syncDirectory(directory);
      });
    }
  }

  private async inLanes(items: string[], each: (item: string) => Promise<void>): Promise<void> {
    for (let i = 0; i < items.length; i += SYNC_LANES) {
      await Promise.all(items.slice(i, i + SYNC_LANES).map(each));
    }
  }

  private async statIfPresent(path: string): Promise<fs.Stat | null> {
    try {
      return await fs.lstat(path);
    } catch (error) {
      const code = (error as BusinessError).code;
      if (code === 13900002 || code === 13900018) return null;
      throw error as Error;
    }
  }

  private static closeRetiredFiles(): Promise<void> {
    const closing = OhosRuntimeStorage.closes.then(async () => {
      while (OhosRuntimeStorage.retiredFiles.length > 0) {
        const file = OhosRuntimeStorage.retiredFiles[0];
        await fs.close(file);
        OhosRuntimeStorage.retiredFiles.shift();
      }
    });
    OhosRuntimeStorage.closes = closing.catch(() => {});
    return closing;
  }

  private static closeOwned(file: fs.File): Promise<void> {
    // A rejected close must not erase the only owner of a real descriptor.
    // A later storage instance retries the retired file before opening a new
    // writable file; repeated failure stays explicit and keeps ownership.
    OhosRuntimeStorage.retiredFiles.push(file);
    return OhosRuntimeStorage.closeRetiredFiles();
  }

  private async present(path: string): Promise<boolean> {
    try {
      return await fs.access(path);
    } catch (error) {
      const code = (error as BusinessError).code;
      if (code === 13900002 || code === 13900018) return false;
      throw error as Error;
    }
  }

  private async checkParents(path: string): Promise<void> {
    if (!path.startsWith(this.filesDir + '/')) {
      throw new RuntimeChannelError('ohos_path_outside', '运行时写入路径越过应用文件目录。');
    }
    const parts = path.substring(this.filesDir.length + 1).split('/');
    let current = this.filesDir;
    for (const part of parts.slice(0, -1)) {
      current += '/' + part;
      if (this.checkedDirectories?.has(current)) continue;
      const stat = await fs.lstat(current);
      if (!stat.isDirectory() || stat.isSymbolicLink()) {
        throw new RuntimeChannelError('ohos_path_link', '运行时目录含符号链接或非目录项。');
      }
      this.checkedDirectories?.add(current);
    }
  }

  private forgetDirectory(path: string): void {
    const checked = this.checkedDirectories;
    if (checked === null) return;
    for (const directory of Array.from(checked)) {
      if (directory === path || directory.startsWith(path + '/')) checked.delete(directory);
    }
  }

  async exists(path: string): Promise<boolean> {
    if (!await this.present(path)) return false;
    await this.checkParents(path);
    return true;
  }

  async ensureDirectory(path: string): Promise<void> {
    if (!path.startsWith(this.filesDir + '/')) {
      throw new RuntimeChannelError('ohos_path_outside', '运行时目录越过应用文件目录。');
    }
    let current = this.filesDir;
    for (const part of path.substring(this.filesDir.length + 1).split('/')) {
      current += '/' + part;
      if (this.checkedDirectories?.has(current)) continue;
      let stat: fs.Stat | null = await this.statIfPresent(current);
      if (stat === null) {
        try {
          await fs.mkdir(current);
        } catch (error) {
          // Another diagnostics/start call may have created the same directory.
          if ((error as BusinessError).code !== 13900015) throw error as Error;
        }
        await this.syncParent(current);
        stat = await fs.lstat(current);
      }
      if (!stat.isDirectory() || stat.isSymbolicLink()) {
        throw new RuntimeChannelError('ohos_path_link', '运行时目录含符号链接或非目录项。');
      }
      this.checkedDirectories?.add(current);
    }
  }

  async readText(path: string): Promise<string> {
    await this.checkParents(path);
    const stat = await fs.lstat(path);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new RuntimeChannelError('ohos_path_link', '运行时记录必须为普通文件。');
    return await fs.readText(path);
  }

  writeTextAtomic(path: string, content: string): Promise<void> {
    // Metadata uses one fixed temporary path; serialize across storage instances.
    const write = OhosRuntimeStorage.textWrites.then(() => this.replaceText(path, content));
    OhosRuntimeStorage.textWrites = write.catch(() => {});
    return write;
  }

  private async replaceText(path: string, content: string): Promise<void> {
    await OhosRuntimeStorage.closeRetiredFiles();
    await this.checkParents(path);
    const temp = path + '.tmp';
    await this.removeFile(temp);
    const file = await fs.open(temp, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW);
    try {
      const bytes = content.length === 0 ? new Uint8Array(0) : new util.TextEncoder().encodeInto(content);
      let offset = 0;
      while (offset < bytes.byteLength) {
        const buffer = new ArrayBuffer(Math.min(64 * 1024, bytes.byteLength - offset));
        new Uint8Array(buffer).set(bytes.subarray(offset, offset + buffer.byteLength));
        const count = await fs.write(file.fd, buffer, {offset: offset});
        if (count === 0) throw new RuntimeChannelError('ohos_write_failed', '运行时记录写入未完成。');
        offset += count;
      }
      await fs.fsync(file.fd);
    } finally {
      await OhosRuntimeStorage.closeOwned(file);
    }
    await this.rename(temp, path);
  }

  async matches(path: string, file: RuntimeFile): Promise<boolean> {
    // Parents may not exist yet on the first install; they are created before writes.
    const stat = await this.statIfPresent(path);
    if (stat === null) return false;
    await this.checkParents(path);
    if (stat.isSymbolicLink()) throw new RuntimeChannelError('ohos_path_link', '运行时文件不能为符号链接。');
    if (!stat.isFile() || stat.size !== file.size) return false;
    return (await fileHash.hash(path, 'sha256')).toLowerCase() === file.sha256;
  }

  async copyRawFile(asset: string, target: string, file: RuntimeFile): Promise<void> {
    if (asset !== 'dsh-runtime/files/' + file.path) {
      throw new RuntimeChannelError('ohos_archive_invalid', '运行时归档成员与清单路径不一致。');
    }
    await OhosRuntimeStorage.closeRetiredFiles();
    await this.checkParents(target);
    await this.removeFile(target);
    const output = await fs.open(target, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW);
    try {
      let offset = 0;
      await this.archive.extract(file, async (buffer: ArrayBuffer, count: number): Promise<void> => {
        let written = 0;
        while (written < count) {
          const chunk: ArrayBuffer = written === 0 && count === buffer.byteLength ? buffer : buffer.slice(written, count);
          const n = await fs.write(output.fd, chunk, {offset: offset + written});
          if (!Number.isSafeInteger(n) || n <= 0 || n > count - written) {
            throw new RuntimeChannelError('ohos_write_failed', '运行时文件写入未完成。');
          }
          written += n;
        }
        offset += count;
      });
      if (offset !== file.size) throw new RuntimeChannelError('ohos_size_mismatch', '运行时解压长度与清单不符。');
      await fs.fsync(output.fd);
    } finally {
      await OhosRuntimeStorage.closeOwned(output);
    }
  }

  async rename(from: string, to: string): Promise<void> {
    await this.checkParents(from);
    await this.checkParents(to);
    const stat = await this.statIfPresent(to);
    if (stat !== null) {
      if (stat.isSymbolicLink()) throw new RuntimeChannelError('ohos_path_link', '拒绝替换运行时符号链接。');
      if (stat.isDirectory()) {
        if ((await fs.listFile(to, {recursion: false, listNum: 1})).length !== 0) {
          throw new RuntimeChannelError('ohos_install_path_conflict', '运行时文件位置存在非空目录，未删除未登记的内容。');
        }
        await fs.rmdir(to);
        this.forgetDirectory(to);
      }
    }
    await fs.rename(from, to);
    // A completed file write alone does not persist its directory entry.
    await this.syncParent(to);
  }

  private async syncParent(path: string): Promise<void> {
    const directory = path.substring(0, path.lastIndexOf('/'));
    const base = this.installBase;
    if (base !== null && this.installDirectories !== null &&
        (path === base + '/tree' || path.startsWith(base + '/tree/') ||
         path === base + '/staging' || path.startsWith(base + '/staging/'))) {
      this.installDirectories.add(directory);
      return;
    }
    await this.syncDirectory(directory);
  }

  private async syncDirectory(directory: string): Promise<void> {
    await OhosRuntimeStorage.closeRetiredFiles();
    const parent = await fs.open(directory, fs.OpenMode.READ_ONLY | fs.OpenMode.DIR | fs.OpenMode.NOFOLLOW);
    try {
      await fs.fsync(parent.fd);
    } finally {
      await OhosRuntimeStorage.closeOwned(parent);
    }
  }

  async removeFile(path: string, keepDirectory: boolean = false): Promise<void> {
    const stat = await this.statIfPresent(path);
    if (stat === null) return;
    await this.checkParents(path);
    if (keepDirectory && stat.isDirectory() && !stat.isSymbolicLink()) return;
    if (!stat.isFile() || stat.isSymbolicLink()) throw new RuntimeChannelError('ohos_path_link', '拒绝删除运行时清单以外的目录或链接。');
    await fs.unlink(path);
    await this.syncParent(path);
  }

  async removeEmptyParents(path: string, boundary: string): Promise<void> {
    let parent = path.substring(0, path.lastIndexOf('/'));
    while (parent.startsWith(boundary + '/')) {
      const stat = await this.statIfPresent(parent);
      if (stat !== null) {
        await this.checkParents(parent);
        if (!stat.isDirectory() || stat.isSymbolicLink()) return;
        if ((await fs.listFile(parent, {recursion: false, listNum: 1})).length > 0) return;
        await fs.rmdir(parent);
        this.forgetDirectory(parent);
        await this.syncParent(parent);
      }
      parent = parent.substring(0, parent.lastIndexOf('/'));
    }
  }
}
