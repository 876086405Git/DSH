// UNCOMPILED_HMS / 未在真机核实。纯协议与预算；HMS 边界见 hms-share.md。
import util from '@ohos.util';
import uniformTypeDescriptor from '@ohos.data.uniformTypeDescriptor';
import fileUri from '@ohos.file.fileuri';
import { Any } from '@ohos/flutter_ohos';

export const SHARE_UNAVAILABLE: string = 'dev.fluttercommunity.plus/share/unavailable';
export const SHARE_MAX_ITEMS: number = 9;
export const SHARE_MAX_FILE: number = 30 * 1024 * 1024;
export const SHARE_MAX_TOTAL: number = 60 * 1024 * 1024;
export const SHARE_MAX_TEXT: number = 200000;
export const SHARE_OUT_MAX_BYTES: number = 300 * 1024 * 1024;
export const SHARE_MAX_RECORDS: number = 500;
export const SHARE_METADATA_BUDGET: number = 180 * 1024;

export class ShareError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

export class ShareRequest {
  text: string = '';
  title: string = '';
  subject: string = '';
  link: boolean = false;
  paths: string[] = [];
  mimes: string[] = [];
  origin?: number[];
}

export function utf8Size(value: string): number {
  return new util.TextEncoder().encodeInto(value).byteLength;
}

function wellFormed(value: string): boolean {
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF) {
      const next = value.charCodeAt(++i);
      if (!(next >= 0xDC00 && next <= 0xDFFF)) return false;
    } else if (code >= 0xDC00 && code <= 0xDFFF) return false;
  }
  return true;
}

function field(raw: Map<string, Any>, key: string): string {
  const value: Any = raw.get(key);
  if (value === undefined || value === null) return '';
  if (typeof value !== 'string' || value.length > SHARE_MAX_TEXT || value.includes('\0') || !wellFormed(value)) {
    throw new ShareError('invalid', '分享内容格式或长度不受支持。');
  }
  return value;
}

export function parseShareRequest(raw: Any): ShareRequest {
  if (!(raw instanceof Map)) throw new ShareError('invalid', '分享参数格式不正确。');
  const request = new ShareRequest();
  request.text = field(raw, 'text');
  request.subject = field(raw, 'subject');
  request.title = field(raw, 'title');
  const link = field(raw, 'uri');
  if (link) {
    if (request.text || !/^https?:\/\/[^\s/?#]+(?:[/?#][^\s]*)?$/i.test(link)) {
      throw new ShareError('invalid', '分享链接必须是完整的 HTTP 或 HTTPS 地址。');
    }
    request.text = link; request.link = true;
  }
  const paths: Any = raw.get('paths');
  const mimes: Any = raw.get('mimeTypes');
  if (paths !== undefined && paths !== null) {
    if (!Array.isArray(paths) || paths.length < 1 || paths.length > SHARE_MAX_RECORDS ||
      !Array.isArray(mimes) || mimes.length !== paths.length) throw new ShareError('invalid', '分享文件列表不正确。');
    for (let i = 0; i < paths.length; i++) {
      const path: Any = paths[i]; const mime: Any = mimes[i];
      if (typeof path !== 'string' || !path.startsWith('/') || path.length > 16384 ||
        /[\x00-\x1f\x7f]/.test(path) || !wellFormed(path) ||
        typeof mime !== 'string' || mime.length > 200 || !/^[A-Za-z0-9!#$&^_.+*-]+\/[A-Za-z0-9!#$&^_.+*-]+$/.test(mime)) {
        throw new ShareError('invalid', '分享文件路径或类型不正确。');
      }
      request.paths.push(path); request.mimes.push(mime);
    }
  }
  if (!request.text && request.paths.length === 0) throw new ShareError('invalid', '没有可以分享的内容。');
  if (utf8Size(request.text) + utf8Size(request.title) + utf8Size(request.subject) > SHARE_METADATA_BUDGET) {
    throw new ShareError('too_large', '分享文字过长，请改为文件分享。');
  }
  const keys = ['originX', 'originY', 'originWidth', 'originHeight'];
  if (keys.some((key: string) => raw.has(key))) {
    const values: number[] = [];
    for (const key of keys) {
      const value: Any = raw.get(key);
      if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > 1000000) {
        throw new ShareError('invalid', '分享窗口的位置不正确。');
      }
      values.push(value);
    }
    if (values[2] > 0 && values[3] > 0) request.origin = values;
  }
  return request;
}

export function safeShareName(raw: string): string {
  const parts = raw.split(/[\\/]/);
  const cleaned = (parts[parts.length - 1] || 'shared').replace(/[\x00-\x1f\x7f\\/:*?"'`<>|]/g, '_').trim().replace(/^\.+/, '');
  const dot = cleaned.lastIndexOf('.');
  const extension = dot > 0 && utf8Size(cleaned.substring(dot)) <= 32 ? cleaned.substring(dot) : '';
  const stem = extension ? cleaned.substring(0, dot) : cleaned;
  let name = '';
  for (const character of stem) {
    if (utf8Size(name + character) + utf8Size(extension) > 240) break;
    name += character;
  }
  return name + extension || 'shared';
}

export function incomingShareName(uri: string, title?: string): string {
  if (title) return safeShareName(boundedShareText(title, 1000));
  try { return safeShareName(new fileUri.FileUri(uri).name); }
  catch (_error) { return 'shared'; }
}

export function externalShareUri(value: string, ownBundle: string): boolean {
  if (!value.startsWith('file://') || value.length > 65536 || /[\x00-\x1f\x7f?#]/.test(value)) return false;
  const slash = value.indexOf('/', 7);
  if (slash < 0) return false;
  const authority = value.substring(7, slash).toLowerCase();
  const own = ownBundle.toLowerCase();
  if (!own || !/^[a-z0-9_.-]+$/.test(authority) || authority === '.' || authority === '..' ||
    authority === own || authority.startsWith(own + '.')) return false;
  try {
    const decoded = decodeURIComponent(value.substring(slash));
    return !/[\x00-\x1f\x7f\\]/.test(decoded) &&
      decoded.split('/').every((part: string) => part !== '.' && part !== '..');
  } catch (_error) { return false; }
}

export function outgoingUtd(path: string, mime: string): string {
  let value = '';
  try { value = uniformTypeDescriptor.getUniformDataTypeByMIMEType(mime); } catch (_error) { /* Try suffix. */ }
  if (!value || value.startsWith('flex.') || value === uniformTypeDescriptor.UniformDataType.FILE) {
    const name = path.substring(path.lastIndexOf('/') + 1);
    const dot = name.lastIndexOf('.');
    if (dot > 0) {
      try { value = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(name.substring(dot).toLowerCase()); }
      catch (_error) { /* Generic file fallback is documented as a product inference. */ }
    }
  }
  return !value || value.startsWith('flex.') ? uniformTypeDescriptor.UniformDataType.FILE : value;
}

export function incomingMime(utd: string): string | null {
  try {
    const values = uniformTypeDescriptor.getTypeDescriptor(utd)?.mimeTypes;
    return values && values.length > 0 && values[0].length <= 200 ? values[0] : null;
  } catch (_error) { return null; }
}

export function boundedShareText(value: string, remaining: number): string {
  let end = Math.max(0, Math.min(value.length, remaining));
  if (end > 0 && value.charCodeAt(end - 1) >= 0xD800 && value.charCodeAt(end - 1) <= 0xDBFF) end--;
  return value.substring(0, end).replace(/\0/g, '');
}
