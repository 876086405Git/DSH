import fs from '@ohos.file.fs';
import util from '@ohos.util';
import type { BusinessError } from '@ohos.base';
import { WidgetValues, WidgetValue, widgetDecode, widgetMerge } from './CompanionWidgetData';

// A cache of transaction queues/failed-close handles, never a cache of widget data.
// Each process reopens snapshot.json under the same application-level file lock.
export class CompanionWidgetStore {
  private static stores: Map<string, CompanionWidgetStore> = new Map<string, CompanionWidgetStore>();
  private directory: string;
  private tail: Promise<void> = Promise.resolve();
  private queued: number = 0;
  private retained: fs.File[] = [];

  private constructor(filesDir: string) { this.directory = filesDir + '/companion-widget'; }

  static at(filesDir: string): CompanionWidgetStore {
    let store: CompanionWidgetStore | undefined = CompanionWidgetStore.stores.get(filesDir);
    if (!store) { store = new CompanionWidgetStore(filesDir); CompanionWidgetStore.stores.set(filesDir, store); }
    return store;
  }

  transact(patch: Map<string, WidgetValue> | undefined,
    publish: (values: WidgetValues) => Promise<void>): Promise<void> {
    // A stalled system update must not retain an unbounded number of channel replies.
    if (this.queued >= 16) return Promise.reject(new Error('Companion widget update queue is full'));
    this.queued++;
    const run: Promise<void> = this.tail.then((): Promise<void> => this.locked(patch, publish));
    this.tail = run.then((): void => { this.queued--; }, (): void => { this.queued--; });
    return run;
  }

  private async locked(patch: Map<string, WidgetValue> | undefined,
    publish: (values: WidgetValues) => Promise<void>): Promise<void> {
    while (this.retained.length > 0) { await fs.close(this.retained[0]); this.retained.shift(); }
    try { await fs.mkdir(this.directory); }
    catch (error) { if ((error as BusinessError).code !== 13900015) throw error as Error; }
    const directory: fs.Stat = await fs.lstat(this.directory);
    if (!directory.isDirectory() || directory.isSymbolicLink()) throw new Error('Invalid widget directory');
    const lock: fs.File = await fs.open(this.directory + '/lock',
      fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW);
    try {
      if (!(await fs.stat(lock.fd)).isFile()) throw new Error('Invalid widget lock');
      // Another process may be frozen inside updateForm. Never wait for it here,
      // and never time it out/unlock its transaction: a later refresh can retry.
      lock.tryLock(true);
      const values: WidgetValues = await this.read();
      if (patch !== undefined) await this.write(widgetMerge(values, patch));
      // Keep the lock until the physical update completes. Otherwise a late Form
      // refresh can overwrite a newer main-process update even with atomic files.
      await publish(values);
    } finally { await this.close(lock); }
  }

  private async close(file: fs.File): Promise<void> {
    try { await fs.close(file); }
    catch (error) { this.retained.push(file); throw error as Error; }
  }

  private async read(): Promise<WidgetValues> {
    let input: fs.File;
    try { input = await fs.open(this.directory + '/snapshot.json', fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW); }
    catch (error) { if ((error as BusinessError).code === 13900002) return new WidgetValues(); throw error as Error; }
    try {
      const stat: fs.Stat = await fs.stat(input.fd);
      if (!stat.isFile() || stat.size <= 0 || stat.size > 32768) throw new Error('Invalid widget snapshot size');
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const bytes: Uint8Array = new Uint8Array(buffer);
      let offset: number = 0;
      while (offset < bytes.length) {
        const part: ArrayBuffer = new ArrayBuffer(bytes.length - offset);
        const count: number = await fs.read(input.fd, part, { offset: offset, length: part.byteLength });
        if (count <= 0 || count > part.byteLength) throw new Error('Widget snapshot read made no progress');
        bytes.set(new Uint8Array(part, 0, count), offset);
        offset += count;
      }
      return widgetDecode(util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes));
    } finally { await this.close(input); }
  }

  private async write(values: WidgetValues): Promise<void> {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(JSON.stringify(values));
    if (bytes.byteLength > 32768) throw new Error('Widget snapshot is too large');
    const pending: string = this.directory + '/pending.json';
    const output: fs.File = await fs.open(pending,
      fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW);
    try {
      if (!(await fs.stat(output.fd)).isFile()) throw new Error('Invalid widget pending file');
      let offset: number = 0;
      while (offset < bytes.length) {
        const buffer: ArrayBuffer = new ArrayBuffer(bytes.length - offset);
        new Uint8Array(buffer).set(bytes.subarray(offset));
        const count: number = await fs.write(output.fd, buffer, { offset: offset });
        if (count <= 0 || count > buffer.byteLength) throw new Error('Widget snapshot write made no progress');
        offset += count;
      }
      await fs.fsync(output.fd);
    } finally { await this.close(output); }
    await fs.rename(pending, this.directory + '/snapshot.json');
    const parent: fs.File = await fs.open(this.directory, fs.OpenMode.READ_ONLY | fs.OpenMode.DIR | fs.OpenMode.NOFOLLOW);
    try { await fs.fsync(parent.fd); } finally { await this.close(parent); }
  }
}
