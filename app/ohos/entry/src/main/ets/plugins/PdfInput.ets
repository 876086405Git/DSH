// Secure fd -> owned PDF snapshot. No HMS API and no arbitrary file:// grant conversion.
import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';

export class PdfChannelError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

const MAX_PDF_BYTES = 64 * 1024 * 1024;

export class PdfInput {
  private input?: number;
  private output?: number;
  private directory?: string;
  private created: boolean = false;
  private path: string = '';

  get snapshotPath(): string { return this.path; }

  async copy(cacheDir: string, path: string, openLocal: (path: string) => Promise<number>, current: () => void): Promise<void> {
    if (this.input !== undefined || this.directory !== undefined) throw new PdfChannelError('busy', 'PDF 快照仍在使用。');
    current(); this.input = await openLocal(path);
    try {
      current();
      const before = await fs.stat(this.input); current();
      if (!before.isFile() || !Number.isSafeInteger(before.size) || before.size <= 0 || before.size > MAX_PDF_BYTES) {
        throw new PdfChannelError('pdf_size', '内嵌预览支持不超过 64 MiB 的 PDF，请用系统应用打开此文件。');
      }
      const root = cacheDir + '/dsh-pdf';
      try { await fs.mkdir(root); }
      catch (error) { if ((error as BusinessError).code !== 13900015) throw error as Error; }
      current(); const directory = await fs.lstat(root);
      if (!directory.isDirectory() || directory.isSymbolicLink()) throw new PdfChannelError('pdf_cache', 'PDF 缓存目录不可用。');
      current(); this.directory = await fs.mkdtemp(root + '/page-XXXXXX'); current();
      this.path = this.directory + '/document.pdf';
      this.output = (await fs.open(this.path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW)).fd;
      this.created = true; current();
      const buffer = new ArrayBuffer(256 * 1024);
      let offset = 0;
      while (offset < before.size) {
        current(); const length = Math.min(buffer.byteLength, before.size - offset);
        const count = await fs.read(this.input, buffer, { offset, length }); current();
        if (!Number.isSafeInteger(count) || count <= 0 || count > length) throw new PdfChannelError('pdf_changed', 'PDF 在复制时发生变化，请重新打开。');
        let written = 0;
        while (written < count) {
          current(); const chunk = buffer.slice(written, count);
          const size = await fs.write(this.output, chunk, { offset: offset + written }); current();
          if (!Number.isSafeInteger(size) || size <= 0 || size > count - written) throw new PdfChannelError('pdf_cache', 'PDF 缓存写入未完成。');
          written += size;
        }
        offset += count;
      }
      const after = await fs.stat(this.input); current();
      if (after.size !== before.size) throw new PdfChannelError('pdf_changed', 'PDF 在复制时发生变化，请重新打开。');
      await fs.fsync(this.output); current();
    } finally { await this.closeFds(); }
  }

  private async closeFds(): Promise<void> {
    let failed = false;
    if (this.output !== undefined) {
      try { await fs.close(this.output); this.output = undefined; } catch (_) { failed = true; }
    }
    if (this.input !== undefined) {
      try { await fs.close(this.input); this.input = undefined; } catch (_) { failed = true; }
    }
    if (failed) throw new PdfChannelError('pdf_cache', 'PDF 文件句柄未能释放，请重新打开应用。');
  }

  async dispose(): Promise<void> {
    await this.closeFds();
    if (this.created) {
      try { await fs.unlink(this.path); }
      catch (error) {
        // cacheDir may be cleared by the system or user. Only the documented
        // "No such file or directory" result means this owned file is gone.
        if ((error as BusinessError).code !== 13900002) throw error as Error;
      }
      this.created = false;
    }
    if (this.directory) {
      try {
        const stat = await fs.lstat(this.directory);
        if (!stat.isDirectory() || stat.isSymbolicLink() || (await fs.listFile(this.directory)).length !== 0) {
          throw new PdfChannelError('pdf_cache', 'PDF 临时目录已变化，未删除非预期内容。');
        }
        // OH rmdir is recursive: only call it after proving this owned slot is empty.
        await fs.rmdir(this.directory);
      } catch (error) {
        // The same private slot can disappear between lstat/listFile/rmdir.
        // Permission, I/O, changed-type and non-empty errors retain ownership.
        if ((error as BusinessError).code !== 13900002) throw error as Error;
      }
      this.directory = undefined;
    }
    this.path = '';
  }
}
