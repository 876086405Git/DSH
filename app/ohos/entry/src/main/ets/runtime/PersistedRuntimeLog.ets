// Only RuntimeLogs.append output may enter this store. Constructor/facts are pure memory.
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import { Any } from '@ohos/flutter_ohos';
import { RuntimeLogEntry } from './RuntimeCore';

const FILE_LIMIT: number = 1024 * 1024;
const QUEUE_LIMIT: number = 256 * 1024;

class LogBatch {
  readonly bytes: Uint8Array;
  readonly lines: number;
  readonly omitted: number;
  committed: boolean = false;
  constructor(bytes: Uint8Array, lines: number, omitted: number) {
    this.bytes = bytes; this.lines = lines; this.omitted = omitted;
  }
}
interface LogTail { lines: string[]; bytes: number; }

export class PersistedRuntimeLog {
  private static shared: PersistedRuntimeLog | null = null;
  private readonly filesDir: string;
  private readonly directory: string;
  private readonly path: string;
  private pending: Uint8Array[] = [];
  private pendingBytes: number = 0;
  private omitted: number = 0;
  private omittedTotal: number = 0;
  private failure: string | null = null;
  private draining: Promise<void> | null = null;
  private disk: Promise<void> = Promise.resolve();
  private held: fs.File | null = null;
  private rollback: number | null = null;

  static get(filesDir: string): PersistedRuntimeLog {
    if (PersistedRuntimeLog.shared === null) PersistedRuntimeLog.shared = new PersistedRuntimeLog(filesDir);
    if (PersistedRuntimeLog.shared.filesDir !== filesDir) throw new Error('诊断日志必须使用运行时同一个应用 Context。');
    return PersistedRuntimeLog.shared;
  }
  private constructor(filesDir: string) {
    this.filesDir = filesDir; this.directory = filesDir + '/dsh-runtime'; this.path = this.directory + '/engine.log';
  }

  append(entries: RuntimeLogEntry[]): void {
    const encoder = new util.TextEncoder();
    entries.forEach((entry: RuntimeLogEntry): void => {
      const bytes = encoder.encodeInto(entry.line + '\n');
      this.pending.push(bytes); this.pendingBytes += bytes.length;
      while (this.pendingBytes > QUEUE_LIMIT) {
        const removed = this.pending.shift();
        if (removed !== undefined) { this.pendingBytes -= removed.length; this.omitted++; this.omittedTotal++; }
      }
    });
    if (this.pending.length > 0 || this.omitted > 0) this.start();
  }
  private start(): void {
    if (this.draining !== null) return;
    const work = Promise.resolve().then((): Promise<void> => this.drain());
    this.draining = work;
    work.then((): void => {
      if (this.draining === work) this.draining = null;
      if (this.pending.length > 0 || this.omitted > 0) this.start();
    },
      (): void => { if (this.draining === work) this.draining = null; this.failure = 'persistence_failed'; });
  }
  private async drain(): Promise<void> {
    while (this.pending.length > 0 || this.omitted > 0) {
      const lines = this.pending, omitted = this.omitted;
      const marker = omitted === 0 ? new Uint8Array(0) : new util.TextEncoder().encodeInto('[OHOS host: ' + omitted + ' persistent log lines omitted]\n');
      const bytes = new Uint8Array(marker.length + this.pendingBytes); bytes.set(marker);
      let offset = marker.length;
      lines.forEach((line: Uint8Array): void => { bytes.set(line, offset); offset += line.length; });
      const batch = new LogBatch(bytes, lines.length, omitted);
      this.pending = []; this.pendingBytes = 0; this.omitted = 0;
      try { await this.serialize((): Promise<void> => this.writeBatch(batch)); this.failure = null; }
      catch (_) {
        if (!batch.committed) { this.omitted += batch.lines + batch.omitted; this.omittedTotal += batch.lines; }
        throw new Error('诊断日志持久化尚未完成。');
      }
    }
  }
  private serialize<T>(operation: () => Promise<T>): Promise<T> {
    const work = this.disk.then(operation);
    this.disk = work.then((): void => {}, (): void => {});
    return work;
  }
  // Call after producers have quiesced. A continuously writing producer can
  // extend this wait; status/guestRoot never call it. Success includes fsync/close.
  async flush(): Promise<void> {
    while (this.draining !== null || this.pending.length > 0 || this.omitted > 0) {
      if (this.draining === null) this.start();
      if (this.draining !== null) await this.draining;
    }
    await this.serialize((): Promise<void> => this.closeHeld());
  }
  facts(): Map<string, Any> {
    const value: Map<string, Any> = new Map<string, Any>();
    value.set('persistent', true); value.set('maxStoredBytes', FILE_LIMIT * 2);
    value.set('queuedBytes', this.pendingBytes); value.set('omittedLines', this.omittedTotal);
    value.set('error', this.failure); value.set('flushRequiredAfterProducerStops', true);
    return value;
  }

  private async closeHeld(): Promise<void> {
    if (this.held === null) return;
    if (this.rollback !== null) { await fs.truncate(this.held.fd, this.rollback); this.rollback = null; }
    await fs.close(this.held); this.held = null;
  }
  private async directoryReady(create: boolean): Promise<boolean> {
    if (create) {
      try { await fs.mkdir(this.directory); }
      catch (error) { if ((error as BusinessError).code !== 13900015) throw error as Error; }
    }
    try {
      const info = await fs.lstat(this.directory);
      if (info.isSymbolicLink() || !info.isDirectory()) throw new Error('诊断日志目录不是应用自有目录。');
      return true;
    } catch (error) {
      if (!create && (error as BusinessError).code === 13900002) return false;
      throw error as Error;
    }
  }
  private async open(path: string, mode: number): Promise<fs.Stat> {
    this.held = await fs.open(path, mode | fs.OpenMode.NOFOLLOW | fs.OpenMode.NONBLOCK);
    try {
      const stat = await fs.stat(this.held.fd);
      if (!stat.isFile()) throw new Error('诊断日志不是普通文件。');
      return stat;
    } catch (error) { try { await this.closeHeld(); } catch (_) {} throw error as Error; }
  }
  private async readRange(fd: number, start: number, length: number): Promise<Uint8Array> {
    const bytes = new Uint8Array(length); let offset = 0;
    while (offset < length) {
      const buffer = new ArrayBuffer(Math.min(65536, length - offset));
      const count = await fs.read(fd, buffer, { offset: start + offset, length: buffer.byteLength });
      if (!Number.isSafeInteger(count) || count < 0 || count > buffer.byteLength) throw new Error('诊断日志读取长度无效。');
      if (count === 0) break;
      bytes.set(new Uint8Array(buffer, 0, count), offset); offset += count;
    }
    return bytes.slice(0, offset);
  }
  private async writeBatch(batch: LogBatch): Promise<void> {
    try { await this.writeOpenBatch(batch); }
    catch (error) { try { await this.closeHeld(); } catch (_) {} throw error as Error; }
  }
  private async writeOpenBatch(batch: LogBatch): Promise<void> {
    await this.closeHeld(); await this.directoryReady(true);
    const mode = fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND;
    let stat = await this.open(this.path, mode);
    if (stat.size > FILE_LIMIT) throw new Error('诊断日志超过既定文件限额。');
    // A previous process may have died during a short write. Never merge the
    // unfinished line with a later entry after restart.
    let size = stat.size;
    if (size > 0) {
      const last = await this.readRange(this.held!.fd, size - 1, 1);
      if (last.length !== 1 || last[0] !== 10) {
        const prior = await this.readRange(this.held!.fd, 0, size);
        size = prior.lastIndexOf(10) + 1; await fs.truncate(this.held!.fd, size);
      }
    }
    if (size + batch.bytes.length > FILE_LIMIT) {
      await this.closeHeld();
      try { await fs.unlink(this.path + '.1'); }
      catch (error) { if ((error as BusinessError).code !== 13900002) throw error as Error; }
      await fs.rename(this.path, this.path + '.1');
      stat = await this.open(this.path, mode); size = stat.size;
      if (size !== 0) throw new Error('诊断日志轮转未得到空文件。');
    }
    this.rollback = size;
    let offset = 0;
    while (offset < batch.bytes.length) {
      const length = Math.min(65536, batch.bytes.length - offset);
      const buffer = new ArrayBuffer(length); new Uint8Array(buffer).set(batch.bytes.subarray(offset, offset + length));
      const count = await fs.write(this.held!.fd, buffer);
      if (!Number.isSafeInteger(count) || count <= 0 || count > length) throw new Error('诊断日志写入长度无效。');
      offset += count;
    }
    await fs.fsync(this.held!.fd); this.rollback = null; batch.committed = true;
    await this.closeHeld();
  }

  // Serializes behind the current disk operation, without waiting indefinitely
  // for a live producer's pending queue. This reads committed on-disk lines only.
  tail(maxBytes: number): Promise<string[]> {
    const limit = Math.max(1024, Math.min(4 * 1024 * 1024, Math.trunc(maxBytes)));
    return this.serialize(async (): Promise<string[]> => {
      await this.closeHeld();
      if (!await this.directoryReady(false)) return [];
      const current = await this.tailFile(this.path, limit);
      const older: LogTail = current.bytes < limit ? await this.tailFile(this.path + '.1', limit - current.bytes) : { lines: [], bytes: 0 };
      return older.lines.concat(current.lines);
    });
  }
  private async tailFile(path: string, limit: number): Promise<LogTail> {
    try { return await this.readOpenTail(path, limit); }
    catch (error) { try { await this.closeHeld(); } catch (_) {} throw error as Error; }
  }
  private async readOpenTail(path: string, limit: number): Promise<LogTail> {
    let stat: fs.Stat;
    try { stat = await this.open(path, fs.OpenMode.READ_ONLY); }
    catch (error) { if ((error as BusinessError).code === 13900002) return { lines: [], bytes: 0 }; throw error as Error; }
    const start = Math.max(0, stat.size - limit), bytes = await this.readRange(this.held!.fd, start, stat.size - start);
    await this.closeHeld();
    const first = start === 0 ? 0 : bytes.indexOf(10) + 1;
    const last = bytes.lastIndexOf(10) + 1;
    if ((start > 0 && first === 0) || last <= first) return { lines: [], bytes: bytes.length };
    const text = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes.subarray(first, last));
    return { lines: text.split('\n').slice(0, -1), bytes: bytes.length };
  }
}
