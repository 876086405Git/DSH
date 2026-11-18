// URI validation uses the public OH URI parser. UNCOMPILED_SDK / NOT_RUN_DEVICE.
import uri from '@ohos.uri';

export class WebPickRequest {
  readonly owner: string;
  readonly multiple: boolean;
  readonly acceptTypes: string[];
  private constructor(owner: string, multiple: boolean, acceptTypes: string[]) {
    this.owner = owner; this.multiple = multiple; this.acceptTypes = acceptTypes;
  }

  static parse(raw: Map<string, Object | null> | null): WebPickRequest | null {
    if (!(raw instanceof Map)) return null;
    const owner = raw.get('owner'); const id = raw.get('webViewId'); const url = raw.get('url');
    const accepts = raw.get('acceptTypes') ?? [];
    if (typeof owner !== 'string' || owner.length === 0 || owner.length > 200 ||
        typeof id !== 'number' || !Number.isSafeInteger(id) || id < 0 ||
        typeof url !== 'string' || url.length === 0 || url.length > 16384 ||
        /[\x00-\x1f\x7f]/.test(url) || !/^https?:\/\/[^/?#\\\s]+(?:[/?#]|$)/i.test(url) ||
        !Array.isArray(accepts) || accepts.length > 100) return null;
    try {
      const parsed = new uri.URI(url);
      if (!['http', 'https'].includes(parsed.scheme.toLowerCase()) || parsed.authority.length === 0) return null;
    } catch (_) { return null; }
    const values: string[] = [];
    let size = 0;
    for (const value of accepts as Object[]) {
      if (typeof value !== 'string') return null;
      size += value.length;
      if (size > 16384) return null;
      values.push(value);
    }
    return new WebPickRequest(owner, raw.get('multiple') === true, values);
  }
}

export function webFileSuffixFilters(raw: string[], extensionsForMime: (mime: string) => string[]): string[] {
  const suffix = /^\.[a-z0-9][a-z0-9._+-]*$/;
  const mime = /^[a-z0-9!#$&^_.+-]+\/([a-z0-9!#$&^_.+-]+|\*)$/;
  const result: string[] = [];
  for (const entry of raw) {
    for (const part of entry.split(',')) {
      const value = part.trim().toLowerCase();
      if (value === '*/*' || (mime.test(value) && value.endsWith('/*'))) return [];
      let extensions: string[];
      if (suffix.test(value)) extensions = [value];
      else if (mime.test(value)) {
        try { extensions = extensionsForMime(value); }
        catch (_) { return []; }
        // accept is a UI hint. Do not exclude an unknown MIME by silently
        // narrowing a mixed request to only the extensions we happen to know.
        if (extensions.length === 0 || extensions.some((item: string) => !suffix.test(item.toLowerCase()))) return [];
      } else continue;
      for (const extension of extensions) {
        const normalized = extension.toLowerCase();
        if (!result.includes(normalized)) result.push(normalized);
        if (result.length > 100) return [];
      }
    }
  }
  // One combined filter expresses the union; separate entries would initially
  // display only whichever individual suffix the system selected by default.
  return result.length === 0 ? [] : [result.join(',')];
}

export function webFileSelection(uris: string[], multiple: boolean): string[] {
  if (!Array.isArray(uris) || uris.length > 500 || (!multiple && uris.length > 1)) return [];
  for (const raw of uris) {
    if (typeof raw !== 'string' || raw.length > 16384 || /[\x00-\x1f\x7f]/.test(raw) ||
        !/^file:\/\/(docs|media)\//.test(raw) || /%(?![0-9a-fA-F]{2})/.test(raw)) return [];
    try {
      const parsed = new uri.URI(raw);
      if (parsed.scheme !== 'file' || !['docs', 'media'].includes(parsed.authority) || parsed.path.length < 2) return [];
    } catch (_) { return []; }
  }
  return Array.from(new Set(uris));
}
