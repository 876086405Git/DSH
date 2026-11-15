// Same bounded, content-free record contract as Android DiagnosticsEvidence.
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import { Any } from '@ohos/flutter_ohos';

const KINDS: string[] = ['appErrors', 'voiceStages', 'processExits'];
const STAGES: string[] = ['preparing', 'listening', 'stopping', 'transcribing', 'completed', 'cancelled', 'error',
  'call_started', 'capture_started', 'utterance_ready', 'recognizing', 'recognized', 'reply_received',
  'synthesis_requested', 'playback_opening', 'playback_started', 'interrupted', 'call_ended', 'failed'];
const BACKENDS: string[] = ['deepseek', 'cloud', 'system', 'local', 'unknown'];
const ERROR_TYPES: string[] = ['StateError', 'ArgumentError', 'RangeError', 'TypeError', 'FormatException',
  'TimeoutException', 'PlatformException', 'MissingPluginException', 'FlutterError', 'AssertionError',
  'SocketException', 'HttpException', 'FileSystemException', 'UnsupportedError', 'OtherError'];
const LOCATION: RegExp = /^package:(?:dsh_app|flutter)\/[A-Za-z0-9_/.-]{1,120}\.dart:[0-9]{1,7}:[0-9]{1,7}$/;
// Only logs named by these OS events, in their documented app-sandbox directory.
const FAULT_LOG: RegExp = /^\/data\/storage\/el2\/log\/hiappevent\/APP_(?:CRASH|FREEZE)_[0-9]{1,20}_[0-9]{1,10}\.log$/;

export interface EvidenceFields {
  at?: Any; source?: Any; errorType?: Any; stack?: Any;
  stage?: Any; backend?: Any; code?: Any; event?: Any; crashType?: Any; logs?: Any;
}
export class DiagnosticEvidenceRow {
  at: number = 0;
  source?: string;
  errorType?: string;
  stack?: string;
  stage?: string;
  backend?: string;
  code?: number;
  event?: string;
  crashType?: string;
  // Internal cleanup journal only; never included in MethodChannel output.
  logs?: string[];
}
export class DiagnosticEvidenceError extends Error {
  readonly code: string;
  constructor(code: string) { super(code); this.code = code; }
}

export function diagnosticEvidenceRow(kind: string, fields: EvidenceFields, at: number): DiagnosticEvidenceRow | null {
  if (!Number.isSafeInteger(at) || at < 0) return null;
  const row: DiagnosticEvidenceRow = new DiagnosticEvidenceRow(); row.at = at;
  if (kind === 'appErrors') {
    if (typeof fields.source !== 'string' || !['flutter', 'platform', 'session'].includes(fields.source)) return null;
    row.source = fields.source;
    row.errorType = typeof fields.errorType === 'string' && ERROR_TYPES.includes(fields.errorType) ? fields.errorType : 'OtherError';
    const stack: string = typeof fields.stack === 'string' && fields.stack.length <= 2048 ? fields.stack : '';
    row.stack = stack.split(/\r\n|\n|\r/).filter((line: string): boolean => line.length <= 160 && LOCATION.test(line)).slice(0, 6).join('\n');
  } else if (kind === 'voiceStages') {
    const backend: Any = fields.backend ?? 'unknown';
    if (typeof fields.stage !== 'string' || !STAGES.includes(fields.stage) || typeof backend !== 'string' || !BACKENDS.includes(backend)) return null;
    row.stage = fields.stage; row.backend = backend;
    if (typeof fields.code === 'number' && Number.isInteger(fields.code) && fields.code >= -2147483648 && fields.code <= 2147483647) row.code = fields.code;
  } else if (kind === 'processExits') {
    if (fields.source !== 'hiAppEvent' || typeof fields.event !== 'string' || !['APP_CRASH', 'APP_FREEZE'].includes(fields.event)) return null;
    row.source = 'hiAppEvent'; row.event = fields.event;
    if (row.event === 'APP_CRASH' && typeof fields.crashType === 'string' && ['NativeCrash', 'JsError'].includes(fields.crashType)) row.crashType = fields.crashType;
    if (Array.isArray(fields.logs)) {
      row.logs = (fields.logs as Any[]).slice(0, 8).filter((path: Any): boolean => typeof path === 'string' && FAULT_LOG.test(path)) as string[];
    }
  } else return null;
  return row;
}

export class OhosDiagnosticEvidence {
  private static shared: OhosDiagnosticEvidence | null = null;
  private readonly filesDir: string;
  private readonly directory: string;
  private disk: Promise<void> = Promise.resolve();
  private queued: number = 0;
  private held: fs.File | null = null;
  private failed: Set<string> = new Set<string>();

  static get(filesDir: string): OhosDiagnosticEvidence {
    if (OhosDiagnosticEvidence.shared === null) OhosDiagnosticEvidence.shared = new OhosDiagnosticEvidence(filesDir);
    if (OhosDiagnosticEvidence.shared.filesDir !== filesDir) throw new Error('diagnostic_context');
    return OhosDiagnosticEvidence.shared;
  }
  private constructor(filesDir: string) { this.filesDir = filesDir; this.directory = filesDir + '/diagnostic-evidence'; }

  record(kind: string, fields: EvidenceFields): Promise<void> {
    const row: DiagnosticEvidenceRow | null = diagnosticEvidenceRow(kind, fields, Date.now());
    if (row === null || kind === 'processExits') return Promise.reject(new DiagnosticEvidenceError('invalid_evidence'));
    return this.serialize(kind, async (): Promise<void> => { await this.append(kind, row); });
  }
  fault(row: DiagnosticEvidenceRow): Promise<void> {
    return this.serialize('processExits', async (): Promise<void> => {
      // Do not rotate away a failed cleanup journal before it can be retried.
      try { await this.cleanFaults(); }
      catch (error) { if (!(error instanceof DiagnosticEvidenceError) || error.code !== 'invalid_storage') throw error as Error; }
      await this.append('processExits', row);
      await this.cleanFaults();
    });
  }
  clean(): Promise<void> { return this.serialize('processExits', (): Promise<void> => this.cleanFaults()); }

  snapshot(faultAvailability: string): Promise<Map<string, Any>> {
    return this.serialize('', async (): Promise<Map<string, Any>> => {
      const value: Map<string, Any> = new Map<string, Any>();
      const availability: Map<string, Any> = new Map<string, Any>();
      for (let kindIndex: number = 0; kindIndex < KINDS.length; kindIndex++) {
        const kind: string = KINDS[kindIndex];
        let rows: DiagnosticEvidenceRow[] = [];
        let state: string = 'available';
        try { rows = await this.read(kind); if (this.failed.has(kind)) state = 'unavailable'; }
        catch (_) { state = 'unavailable'; }
        if (kind === 'processExits') rows = rows.sort((left: DiagnosticEvidenceRow, right: DiagnosticEvidenceRow): number => left.at - right.at).slice(-this.rowLimit(kind));
        if (kind === 'processExits' && faultAvailability !== 'available') state = faultAvailability;
        value.set(kind, rows.map((row: DiagnosticEvidenceRow): Map<string, Any> => this.publicRow(kind, row)));
        availability.set(kind, state);
      }
      const limits: Map<string, Any> = new Map<string, Any>(); limits.set('maxEntries', 40); limits.set('maxBytes', 64 * 1024);
      value.set('availability', availability); value.set('limits', limits); return value;
    });
  }

  private publicRow(kind: string, row: DiagnosticEvidenceRow): Map<string, Any> {
    const result: Map<string, Any> = new Map<string, Any>(); result.set('at', row.at);
    if (kind === 'appErrors') { result.set('source', row.source); result.set('errorType', row.errorType); result.set('stack', row.stack); }
    if (kind === 'voiceStages') { result.set('stage', row.stage); result.set('backend', row.backend); if (row.code !== undefined) result.set('code', row.code); }
    if (kind === 'processExits') { result.set('source', 'hiAppEvent'); result.set('event', row.event); if (row.crashType !== undefined) result.set('crashType', row.crashType); }
    return result;
  }
  private serialize<T>(kind: string, operation: () => Promise<T>): Promise<T> {
    if (this.queued >= 64) {
      if (kind !== '') this.failed.add(kind);
      return Promise.reject(new DiagnosticEvidenceError('evidence_unavailable'));
    }
    this.queued++;
    const work: Promise<T> = this.disk.then(async (): Promise<T> => { await this.closeHeld(); return operation(); });
    this.disk = work.then((): void => { this.queued--; if (kind !== '') this.failed.delete(kind); },
      (): void => { this.queued--; if (kind !== '') this.failed.add(kind); });
    return work;
  }
  private fileLimit(kind: string): number { return kind === 'processExits' ? 8 * 1024 : 24 * 1024; }
  private rowLimit(kind: string): number { return kind === 'processExits' ? 8 : 40; }
  // Eight public metadata rows plus one durable cleanup debt. A late OS event
  // can be outside the metadata window and still own an external log to delete.
  private storageRowLimit(kind: string): number { return this.rowLimit(kind) + (kind === 'processExits' ? 1 : 0); }
  private async directoryReady(create: boolean): Promise<boolean> {
    if (create) {
      try { await fs.mkdir(this.directory); }
      catch (error) { if ((error as BusinessError).code !== 13900015) throw error as Error; }
    }
    try {
      const stat: fs.Stat = await fs.lstat(this.directory);
      if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('evidence_directory');
      return true;
    } catch (error) { if (!create && (error as BusinessError).code === 13900002) return false; throw error as Error; }
  }
  private async closeHeld(): Promise<void> { if (this.held !== null) { await fs.close(this.held); this.held = null; } }
  private async open(path: string, mode: number): Promise<fs.Stat> {
    this.held = await fs.open(path, mode | fs.OpenMode.NOFOLLOW | fs.OpenMode.NONBLOCK);
    const stat: fs.Stat = await fs.stat(this.held.fd);
    if (!stat.isFile()) throw new Error('evidence_file');
    return stat;
  }
  private async read(kind: string): Promise<DiagnosticEvidenceRow[]> {
    await this.closeHeld();
    if (!await this.directoryReady(false)) return [];
    let bytes: Uint8Array;
    try {
      const stat: fs.Stat = await this.open(this.directory + '/' + kind + '.json', fs.OpenMode.READ_ONLY);
      if (!Number.isSafeInteger(stat.size) || stat.size < 0 || stat.size > this.fileLimit(kind)) throw new DiagnosticEvidenceError('invalid_storage');
      bytes = new Uint8Array(stat.size); let offset: number = 0;
      while (offset < bytes.length) {
        const buffer: ArrayBuffer = new ArrayBuffer(bytes.length - offset);
        const count: number = await fs.read(this.held!.fd, buffer, { offset: offset, length: buffer.byteLength });
        if (!Number.isSafeInteger(count) || count <= 0 || count > buffer.byteLength) throw new DiagnosticEvidenceError('invalid_storage');
        bytes.set(new Uint8Array(buffer, 0, count), offset); offset += count;
      }
      await this.closeHeld();
    } catch (error) {
      try { await this.closeHeld(); } catch (_) {}
      if ((error as BusinessError).code === 13900002) return [];
      throw error as Error;
    }
    let raw: Any;
    try { raw = JSON.parse(util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes)); }
    catch (_) { throw new DiagnosticEvidenceError('invalid_storage'); }
    if (!Array.isArray(raw)) throw new DiagnosticEvidenceError('invalid_storage');
    const result: DiagnosticEvidenceRow[] = [];
    const items: Any[] = (raw as Any[]).slice(-this.storageRowLimit(kind));
    for (let itemIndex: number = 0; itemIndex < items.length; itemIndex++) {
      const item: Any = items[itemIndex];
      if (item === null || typeof item !== 'object') continue;
      const fields: EvidenceFields = item as EvidenceFields;
      if (typeof fields.at !== 'number') continue;
      const row: DiagnosticEvidenceRow | null = diagnosticEvidenceRow(kind, fields, fields.at);
      if (row !== null) result.push(row);
    }
    return result;
  }
  private async append(kind: string, row: DiagnosticEvidenceRow): Promise<void> {
    let rows: DiagnosticEvidenceRow[];
    try { rows = await this.read(kind); }
    catch (error) { if (!(error instanceof DiagnosticEvidenceError) || error.code !== 'invalid_storage') throw error as Error; rows = []; }
    if (kind === 'processExits') rows = rows.filter((old: DiagnosticEvidenceRow): boolean => old.at !== row.at || old.event !== row.event || old.crashType !== row.crashType);
    rows.push(row);
    if (kind === 'processExits') rows.sort((left: DiagnosticEvidenceRow, right: DiagnosticEvidenceRow): number => left.at - right.at);
    // cleanFaults has already retired any previous debt before fault appends.
    // Keep this event even when sorting places it before all eight old rows.
    rows = rows.slice(-this.storageRowLimit(kind));
    await this.write(kind, rows);
  }
  private async write(kind: string, rows: DiagnosticEvidenceRow[]): Promise<void> {
    const encoder: util.TextEncoder = new util.TextEncoder();
    let bytes: Uint8Array = encoder.encodeInto(JSON.stringify(rows));
    // A cleanup journal is never discarded to satisfy the byte budget. The
    // sanitized eight metadata rows plus one <=8-path debt fit the same 8 KiB.
    while (kind !== 'processExits' && bytes.length > this.fileLimit(kind) && rows.length > 1) { rows.shift(); bytes = encoder.encodeInto(JSON.stringify(rows)); }
    if (bytes.length > this.fileLimit(kind)) throw new Error('evidence_limit');
    await this.directoryReady(true);
    const target: string = this.directory + '/' + kind + '.json';
    try {
      await this.open(target + '.tmp', fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      await fs.truncate(this.held!.fd, 0);
      let offset: number = 0;
      while (offset < bytes.length) {
        const buffer: ArrayBuffer = new ArrayBuffer(bytes.length - offset); new Uint8Array(buffer).set(bytes.subarray(offset));
        const count: number = await fs.write(this.held!.fd, buffer);
        if (!Number.isSafeInteger(count) || count <= 0 || count > buffer.byteLength) throw new Error('evidence_write');
        offset += count;
      }
      await fs.fsync(this.held!.fd); await this.closeHeld(); await fs.rename(target + '.tmp', target);
    } catch (error) { try { await this.closeHeld(); } catch (_) {} throw error as Error; }
  }
  private async cleanFaults(): Promise<void> {
    const rows: DiagnosticEvidenceRow[] = await this.read('processExits');
    let changed: boolean = false;
    for (let rowIndex: number = 0; rowIndex < rows.length; rowIndex++) {
      const row: DiagnosticEvidenceRow = rows[rowIndex];
      if (row.logs === undefined || row.logs.length === 0) continue;
      const logs: string[] = row.logs;
      for (let logIndex: number = 0; logIndex < logs.length; logIndex++) {
        const path: string = logs[logIndex];
        try { await fs.unlink(path); }
        catch (error) { if ((error as BusinessError).code !== 13900002) throw error as Error; }
      }
      row.logs = undefined; changed = true;
    }
    if (changed || rows.length > this.rowLimit('processExits')) {
      rows.sort((left: DiagnosticEvidenceRow, right: DiagnosticEvidenceRow): number => left.at - right.at);
      await this.write('processExits', rows.slice(-this.rowLimit('processExits')));
    }
  }
}
