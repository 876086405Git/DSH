// UNCOMPILED_HMS / 未在真机核实。文件操作仅使用公开 OH API；Linux 测试使用真实文件与原生 opener。
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { loadNativeHost } from '../runtime/NativeHost';
import { RuntimePaths } from '../runtime/RuntimePaths';
import {
  ShareError, ShareRequest, SHARE_OUT_MAX_BYTES, safeShareName
} from './HmsSharePolicy';

export class ShareBatch {
  directory: string;
  paths: string[] = [];
  constructor(directory: string) { this.directory = directory; }
}

class RetainedShare {
  path: string;
  mtime: number;
  constructor(path: string, mtime: number) { this.path = path; this.mtime = mtime; }
}

export class HmsShareStorage {
  private static protectedSlots: Set<string> = new Set<string>();
  private context: common.Context;
  constructor(context: common.Context) { this.context = context; }

  private async directory(path: string): Promise<void> {
    try { await fs.mkdir(path); }
    catch (error) { if ((error as BusinessError).code !== 13900015) throw error as Error; }
    const stat = await fs.lstat(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new ShareError('failed', '分享暂存目录不可用。');
  }

  async create(outgoing: boolean): Promise<ShareBatch> {
    const root = outgoing ? this.context.filesDir + '/dsh-share-out' : this.context.cacheDir + '/dsh-share-in';
    await this.directory(root);
    const batch = new ShareBatch(await fs.mkdtemp(root + '/slot-XXXXXX'));
    HmsShareStorage.protectedSlots.add(batch.directory);
    // 当前批与尚未交付的接收批不回收。旧完成批保留 4 个；不根据事件顺序推断接收方读完。
    await this.prune(root);
    return batch;
  }

  release(batch: ShareBatch): void { HmsShareStorage.protectedSlots.delete(batch.directory); }

  private async prune(root: string): Promise<void> {
    const old: RetainedShare[] = [];
    try {
      for (const name of await fs.listFile(root)) {
        if (!/^slot-[A-Za-z0-9]+$/.test(name)) continue;
        const path = root + '/' + name;
        if (HmsShareStorage.protectedSlots.has(path)) continue;
        const stat = await fs.lstat(path);
        if (stat.isDirectory() && !stat.isSymbolicLink()) old.push(new RetainedShare(path, stat.mtime));
      }
      old.sort((a: RetainedShare, b: RetainedShare) => b.mtime - a.mtime || a.path.localeCompare(b.path));
      for (const value of old.slice(4)) {
        for (const name of await fs.listFile(value.path)) {
          const path = value.path + '/' + name;
          const stat = await fs.lstat(path);
          if (stat.isFile() || stat.isSymbolicLink()) await fs.unlink(path);
        }
        if ((await fs.listFile(value.path)).length === 0) await fs.rmdir(value.path);
      }
    } catch (_error) { /* 不因旧缓存清理失败丢弃本次分享。 */ }
  }

  async discard(batch: ShareBatch): Promise<void> {
    try {
      for (const path of batch.paths) {
        try { await fs.unlink(path); } catch (_error) { /* 缓存也可能被 OS 清除。 */ }
      }
      const stat = await fs.lstat(batch.directory);
      if (stat.isDirectory() && !stat.isSymbolicLink() && (await fs.listFile(batch.directory)).length === 0) {
        await fs.rmdir(batch.directory);
      }
    } catch (_error) { /* 留给下一次有界清理。 */ }
    finally { this.release(batch); }
  }

  private async openLocal(path: string, context: common.Context, active: () => void): Promise<number> {
    const roots = [new RuntimePaths(this.context.filesDir).workspace, this.context.cacheDir, this.context.tempDir,
      context.cacheDir, context.tempDir];
    for (const root of roots) {
      if (path.startsWith(root + '/')) {
        const host = await loadNativeHost();
        active();
        return host.openUserFile(root, path.substring(root.length + 1));
      }
    }
    throw new ShareError('outside_workspace', '请先把文件保存到本机工作区或应用缓存后分享。');
  }

  async copy(input: number, batch: ShareBatch, name: string, limit: number, active: () => void): Promise<number> {
    active();
    const before = await fs.stat(input);
    if (!before.isFile() || !Number.isSafeInteger(before.size) || before.size < 0) {
      throw new ShareError('unreadable', '这个项目不是可读取的普通文件。');
    }
    if (before.size > limit) throw new ShareError('too_large', '文件超过本次分享的大小限制。');
    const target = batch.directory + '/' + batch.paths.length.toString() + '-' + safeShareName(name);
    batch.paths.push(target);
    let complete = false;
    try {
      active();
      const output = await fs.open(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const buffer = new ArrayBuffer(256 * 1024);
        let offset = 0;
        while (offset < before.size) {
          active();
          const count = await fs.read(input, buffer, { offset: offset, length: Math.min(buffer.byteLength, before.size - offset) });
          if (!Number.isInteger(count) || count < 1 || count > Math.min(buffer.byteLength, before.size - offset)) {
            throw new ShareError('unreadable', '文件在读取期间发生变化。');
          }
          let written = 0;
          while (written < count) {
            active();
            const n = await fs.write(output.fd, buffer.slice(written, count), { offset: offset + written });
            if (!Number.isInteger(n) || n < 1 || n > count - written) throw new ShareError('failed', '分享文件写入未完成。');
            written += n;
          }
          offset += count;
        }
        active();
        if ((await fs.stat(input)).size !== before.size) throw new ShareError('unreadable', '文件在读取期间发生变化。');
        await fs.fsync(output.fd);
        active();
        complete = true;
        return before.size;
      } finally { await fs.close(output); }
    } finally {
      if (!complete) { try { await fs.unlink(target); } catch (_error) { /* 保留到批清理。 */ } }
    }
  }

  async outgoing(request: ShareRequest, context: common.Context, active: () => void): Promise<ShareBatch | undefined> {
    if (request.paths.length === 0) return undefined;
    const batch = await this.create(true);
    let complete = false;
    try {
      let total = 0;
      for (const path of request.paths) {
        active();
        const fd = await this.openLocal(path, context, active);
        try {
          total += await this.copy(fd, batch, path.substring(path.lastIndexOf('/') + 1), SHARE_OUT_MAX_BYTES - total, active);
        } finally { await fs.close(fd); }
      }
      active(); complete = true;
      return batch;
    } finally { if (!complete) await this.discard(batch); }
  }
}
