// Public OH filesystem adapter. UNCOMPILED_SDK / NOT_RUN_DEVICE.
// Parent checks prevent static link escapes; like the Android implementation,
// this is not a sandbox against an unrelated writer replacing parents mid-IO.
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import { ManagedSkillStorage, requireManagedSkillCurrent } from './ManagedSkillCore';

export class OhosManagedSkillStorage implements ManagedSkillStorage {
  private readonly guestRoot: string;
  private resolvedRoot: Promise<string> | null = null;

  constructor(guestRoot: string) { this.guestRoot = guestRoot; }

  root(): Promise<string> {
    if (this.resolvedRoot === null) {
      this.resolvedRoot = this.canonical(this.guestRoot).then((root: string) => {
        if (root.length === 0 || root === '/') throw new Error('Invalid managed skill root');
        return root;
      });
    }
    return this.resolvedRoot;
  }

  private missing(error: BusinessError): boolean { return error.code === 13900002 || error.code === 13900018; }

  async canonical(path: string): Promise<string> {
    if (!path.startsWith('/') || path.includes('\0')) return '';
    try {
      const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.DIR);
      try {
        // File.path canonicalizes the original string; it is used only for
        // admission equality, never represented as descriptor containment.
        return file.path;
      } finally { await fs.close(file); }
    } catch (error) {
      if (this.missing(error as BusinessError)) return '';
      throw error as Error;
    }
  }

  private async stat(path: string): Promise<fs.Stat | null> {
    try { return await fs.lstat(path); }
    catch (error) { if (this.missing(error as BusinessError)) return null; throw error as Error; }
  }

  private async permitsPath(path: string): Promise<boolean> {
    const root = await this.root();
    if (!path.startsWith(root + '/')) return false;
    const parts = path.substring(root.length + 1).split('/');
    if (parts.some((part: string) => part.length === 0 || part === '.' || part === '..' || part.includes('\0'))) return false;
    const rootStat = await this.stat(root);
    if (rootStat === null || !rootStat.isDirectory() || rootStat.isSymbolicLink()) return false;
    let current = root;
    for (let index = 0; index < parts.length; index++) {
      current += '/' + parts[index];
      const stat = await this.stat(current);
      if (stat === null) return true;
      if (stat.isSymbolicLink()) return false;
      if (index < parts.length - 1 && !stat.isDirectory()) throw new Error('Managed skill parent is not a directory');
    }
    return true;
  }

  private temporary(path: string): string {
    const index = path.lastIndexOf('/');
    // A leading dot cannot occur in a request path component. This reserved
    // sibling therefore cannot collide with another supplied bundle file.
    return path.substring(0, index + 1) + '.dsh-go-tmp-' + path.substring(index + 1);
  }

  async permits(directory: string, paths: string[]): Promise<boolean> {
    if (!await this.permitsPath(directory)) return false;
    for (const relative of paths) {
      const path = directory + '/' + relative;
      if (!await this.permitsPath(path) || !await this.permitsPath(this.temporary(path))) return false;
    }
    return true;
  }

  async isDirectory(path: string): Promise<boolean> {
    if (!await this.permitsPath(path)) return false;
    const stat = await this.stat(path);
    return stat !== null && stat.isDirectory() && !stat.isSymbolicLink();
  }

  async exists(path: string): Promise<boolean> { return await this.stat(path) !== null; }

  encode(text: string): Uint8Array {
    return text.length === 0 ? new Uint8Array(0) : new util.TextEncoder().encodeInto(text);
  }

  async readText(path: string, limit: number): Promise<string | null> {
    try {
      if (!await this.permitsPath(path)) return null;
      const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW | fs.OpenMode.NONBLOCK);
      try {
        const stat = await fs.stat(file.fd);
        if (!stat.isFile() || stat.size > limit) return null;
        const data = new Uint8Array(limit + 1);
        const chunk = new ArrayBuffer(Math.min(8192, limit + 1));
        let used = 0;
        while (used <= limit) {
          const count = await fs.read(file.fd, chunk, { offset: used, length: Math.min(chunk.byteLength, limit + 1 - used) });
          if (count === 0) break;
          if (count < 0 || count > Math.min(chunk.byteLength, limit + 1 - used)) throw new Error('Invalid managed skill read');
          data.set(new Uint8Array(chunk, 0, count), used); used += count;
          if (used > limit) return null;
        }
        const text = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(data.slice(0, used));
        return text.startsWith('\uFEFF') ? text.substring(1) : text;
      } finally { await fs.close(file); }
    } catch (_) { return null; }
  }

  private async ensureParent(path: string): Promise<void> {
    const root = await this.root();
    if (!await this.permitsPath(path)) throw new Error('Managed skill path is redirected');
    let current = root;
    for (const part of path.substring(root.length + 1).split('/').slice(0, -1)) {
      current += '/' + part;
      let stat = await this.stat(current);
      if (stat === null) {
        try { await fs.mkdir(current); }
        catch (error) { if ((error as BusinessError).code !== 13900015) throw error as Error; }
        stat = await this.stat(current);
      }
      if (stat === null || !stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Managed skill parent is redirected');
    }
  }

  async writeFile(path: string, bytes: Uint8Array, current: () => boolean): Promise<void> {
    requireManagedSkillCurrent(current);
    await this.ensureParent(path);
    const temporary = this.temporary(path);
    if (!await this.permitsPath(temporary)) throw new Error('Managed skill staging path is redirected');
    let opened = false;
    try {
      requireManagedSkillCurrent(current);
      const file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC |
        fs.OpenMode.NOFOLLOW | fs.OpenMode.NONBLOCK);
      opened = true;
      try {
        if (!(await fs.stat(file.fd)).isFile()) throw new Error('Managed skill staging is not a regular file');
        let offset = 0;
        while (offset < bytes.byteLength) {
          requireManagedSkillCurrent(current);
          const remaining = Math.min(64 * 1024, bytes.byteLength - offset);
          const buffer = new ArrayBuffer(remaining);
          new Uint8Array(buffer).set(bytes.subarray(offset, offset + remaining));
          const count = await fs.write(file.fd, buffer, { offset: offset });
          if (count <= 0 || count > remaining) throw new Error('Incomplete managed skill write');
          offset += count;
        }
        await fs.fsync(file.fd);
      } finally { await fs.close(file); }
      requireManagedSkillCurrent(current);
      if (!await this.permitsPath(path) || !await this.permitsPath(temporary)) throw new Error('Managed skill publication is redirected');
      requireManagedSkillCurrent(current);
      await fs.rename(temporary, path);
      opened = false;
      const parent = await fs.open(path.substring(0, path.lastIndexOf('/')), fs.OpenMode.READ_ONLY | fs.OpenMode.DIR | fs.OpenMode.NOFOLLOW);
      try { await fs.fsync(parent.fd); }
      finally { await fs.close(parent); }
    } finally {
      if (opened) {
        // Like Android's delete() in finally, cleanup is best effort; a later
        // managed attempt can replace its own uncommitted temporary file.
        try { await fs.unlink(temporary); } catch (_) {}
      }
    }
  }
}
