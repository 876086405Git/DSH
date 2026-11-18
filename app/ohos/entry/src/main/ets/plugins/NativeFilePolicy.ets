// Public OH SDK. Target compiler and device results belong to the integration report.
import uri from '@ohos.uri';
import { Any } from '@ohos/flutter_ohos';

export class NativeFileError extends Error {
  readonly code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

export class NativeFileBudget {
  readonly maxFiles: number;
  readonly maxBytes: number;
  readonly maxTotalBytes: number;
  private counts: Map<string, number> = new Map();
  private knownSizes: Map<string, number> = new Map();
  private total: number = 0;

  constructor(maxFiles: number, maxBytes: number, maxTotalBytes: number, own: boolean) {
    const fileLimit = own ? 30 * 1024 * 1024 : 8 * 1024 * 1024;
    const totalLimit = own ? fileLimit : 16 * 1024 * 1024;
    if (!Number.isSafeInteger(maxFiles) || maxFiles < 1 || maxFiles > (own ? 1 : 4) ||
        !Number.isSafeInteger(maxBytes) || maxBytes < 1 || maxBytes > fileLimit ||
        !Number.isSafeInteger(maxTotalBytes) || maxTotalBytes < 1 || maxTotalBytes > totalLimit) {
      throw new NativeFileError('invalid', '文件选择的数量或字节预算无效。');
    }
    this.maxFiles = maxFiles; this.maxBytes = maxBytes; this.maxTotalBytes = maxTotalBytes;
  }

  known(handle: string, size: number): void {
    if (!Number.isSafeInteger(size) || size < 0 || size > this.maxBytes) this.tooLarge();
    let sum = size;
    this.knownSizes.forEach((value: number, key: string): void => { if (key !== handle) sum += value; });
    if (sum > this.maxTotalBytes) this.tooLarge();
    this.knownSizes.set(handle, size);
  }

  chunkSize(handle: string): number {
    // A one-byte probe also detects growth or a dishonest provider at the exact limit.
    return Math.min(64 * 1024, this.maxBytes - (this.counts.get(handle) ?? 0) + 1,
      this.maxTotalBytes - this.total + 1);
  }

  accept(handle: string, count: number): void {
    const next = (this.counts.get(handle) ?? 0) + count;
    if (!Number.isSafeInteger(count) || count < 1 || count > 64 * 1024 ||
        next > this.maxBytes || this.total + count > this.maxTotalBytes) this.tooLarge();
    this.counts.set(handle, next); this.total += count;
  }

  private tooLarge(): never { throw new NativeFileError('too-large', '所选文件超过请求允许的字节预算。'); }
}

export class NativeFileRequest {
  readonly owner: string;
  readonly images: boolean;
  readonly visual: boolean;
  readonly budget: NativeFileBudget;
  private constructor(owner: string, images: boolean, visual: boolean, budget: NativeFileBudget) {
    this.owner = owner; this.images = images; this.visual = visual; this.budget = budget;
  }

  static parse(raw: Any): NativeFileRequest {
    if (!(raw instanceof Map)) throw new NativeFileError('invalid', '文件选择参数无效。');
    const owner: Any = raw.get('owner');
    const maxFiles: Any = raw.get('maxFiles') ?? 1;
    const maxBytes: Any = raw.get('maxBytes');
    const maxTotalBytes: Any = raw.get('maxTotalBytes');
    if (typeof owner !== 'string' || !/^[A-Za-z0-9_-]{32}$/.test(owner) ||
        typeof maxFiles !== 'number' || typeof maxBytes !== 'number' || typeof maxTotalBytes !== 'number') {
      throw new NativeFileError('invalid', '文件选择所有者或预算无效。');
    }
    if (raw.get('userGesture') !== true) throw new NativeFileError('unavailable', '请在应用前台点击选择文件。');
    return new NativeFileRequest(owner, raw.get('images') === true, raw.get('visual') === true,
      new NativeFileBudget(maxFiles, maxBytes, maxTotalBytes, raw.get('own') === true));
  }
}

export function nativeFileUris(values: string[], maxFiles: number): string[] {
  if (!Array.isArray(values) || values.length > maxFiles) {
    throw new NativeFileError('too-large', '所选文件数量超过请求上限。');
  }
  const output: string[] = [];
  for (let i = 0; i < values.length; i++) {
    const value: Any = values[i];
    if (typeof value !== 'string' || value.length > 16384 || /[\x00-\x1f\x7f\\]/.test(value) ||
        !/^file:\/\/(docs|media)\//.test(value) || /%(?![0-9a-fA-F]{2})/.test(value)) {
      throw new NativeFileError('invalid', '系统选择器返回了不支持的文件 URI。');
    }
    try {
      const parsed = new uri.URI(value);
      if (parsed.scheme !== 'file' || !['docs', 'media'].includes(parsed.authority) ||
          parsed.path.length < 2 || parsed.query.length > 0 || parsed.fragment.length > 0) {
        throw new Error('invalid URI');
      }
      // Check the original path too: a URI parser may normalize encoded dot
      // segments before exposing parsed.path.
      const segments = value.substring(value.indexOf('/', 7)).split('/');
      for (const part of segments) {
        const decoded = decodeURIComponent(part);
        if (decoded === '.' || decoded === '..' || /[\x00-\x1f\x7f/\\]/.test(decoded)) throw new Error('invalid path');
      }
    } catch (_) { throw new NativeFileError('invalid', '系统选择器返回了无效的文件 URI。'); }
    if (output.includes(value)) throw new NativeFileError('invalid', '系统选择器重复返回了同一个文件。');
    output.push(value);
  }
  return output;
}

export function nativeFileName(value: string): string {
  const parts = value.split(/[\\/]/);
  const last = parts[parts.length - 1] ?? '';
  const cleaned = last.replace(/[\x00-\x1f\x7f]/g, '');
  let name = '';
  let count = 0;
  for (const character of cleaned) { if (count++ === 128) break; name += character; }
  return name.length === 0 || name === '.' || name === '..' ? 'file' : name;
}

export function nativeFileMime(value: string): string {
  return /^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}\/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}$/.test(value)
    ? value : 'application/octet-stream';
}
