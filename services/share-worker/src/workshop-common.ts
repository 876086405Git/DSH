import { record, validVersion as catalogVersion } from './pet-catalog';

export const UPLOAD_CAP = 50 * 1024 * 1024;
/** The cap until 2026-11-15. Apps from before then reject a whole catalog
 *  holding a larger entry, so those entries are listed apart (catalog). */
export const LEGACY_UPLOAD_CAP = 20 * 1024 * 1024;
export const EXPANDED_CAP = 128 * 1024 * 1024;
export const MEMBER_CAP = 16 * 1024 * 1024;
export const PREVIEW_CONTRACT = { schema: 1, sources: ['pet-idle', 'companion-preview'], format: 'png',
  maxWidth: 512, maxHeight: 512, maxPixels: 262144, maxBytes: 2097152 } as const;
export type PreviewSource = typeof PREVIEW_CONTRACT.sources[number];
export interface PublicPreview { path: string; sha256: string; size: number; width: number; height: number }
export const KINDS = ['pet', 'companion'] as const;
export type WorkshopKind = typeof KINDS[number];
export const LICENSES = ['CC0-1.0', 'CC-BY-4.0', 'CC-BY-SA-4.0', 'MIT', 'Apache-2.0', 'BSD-2-Clause', 'BSD-3-Clause', 'LicenseRef-Author-Permission'] as const;
export class WorkshopError extends Error {
  constructor(readonly code: string, readonly status = 400, readonly headers: Record<string, string> = {}) { super(code); }
}
export function requireWorkshop(condition: unknown, code: string, status = 400): asserts condition {
  if (!condition) throw new WorkshopError(code, status);
}
export const encoder = new TextEncoder();
export const hash = (value: unknown): value is string => typeof value === 'string' && value.length === 64 && /^[a-f0-9]{64}$/.test(value);
export const validVersion = (value: unknown): value is string => catalogVersion(value) && !/[\r\n]/.test(value);
export const kind = (value: unknown): value is WorkshopKind => value === 'pet' || value === 'companion';
export const id = (value: unknown): value is string => typeof value === 'string' && /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value) && value.length <= 40 && value.trim() === value;
// Dart VM String.trim also treats NEXT LINE as whitespace. This predicate
// checks nonblankness only; metadata and reasons retain their original text.
const blankText = /^[\s\u0085]*$/u;
export const text = (value: unknown, cap: number): value is string => typeof value === 'string' && !blankText.test(value) && Array.from(value).length <= cap && !/[\u0000-\u001f\ud800-\udfff]/u.test(value);
export const whole = (value: unknown, min: number, max: number): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value >= min && value <= max;
export const finite = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value);
export async function sha256(bytes: Uint8Array | string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', typeof bytes === 'string' ? encoder.encode(bytes) : bytes);
  return Array.from(new Uint8Array(digest), x => x.toString(16).padStart(2, '0')).join('');
}
export interface SubmissionMeta {
  kind: WorkshopKind; id: string; version: string; minApp: string;
  title: { zh: string; en: string }; author: string; license: string; source: string;
  description?: string; tags?: string[]; previewSource?: PreviewSource;
  sha256: string; size: number; rightsConfirmed: true;
}
export function validMeta(value: unknown): value is SubmissionMeta {
  if (!record(value) || !kind(value.kind) || !id(value.id) || !validVersion(value.version) || !validVersion(value.minApp) ||
    !record(value.title) || !text(value.title.zh, 120) || !text(value.title.en, 120) ||
    !text(value.author, 256) || typeof value.license !== 'string' || !LICENSES.includes(value.license as typeof LICENSES[number]) ||
    !text(value.source, 2048) || !hash(value.sha256) || !whole(value.size, 1, UPLOAD_CAP) || value.rightsConfirmed !== true ||
    value.description !== undefined && value.description !== '' && !text(value.description, 512) ||
    value.previewSource !== undefined && value.previewSource !== (value.kind === 'pet' ? 'pet-idle' : 'companion-preview') ||
    value.tags !== undefined && (!Array.isArray(value.tags) || value.tags.length > 8 ||
      !value.tags.every(tag => text(tag, 32)) || new Set(value.tags).size !== value.tags.length)) return false;
  try {
    const url = new URL(value.source);
    return value.source.trim() === value.source && !/\s/.test(value.source) && url.protocol === 'https:' && !!url.hostname && !url.username && !url.password;
  } catch { return false; }
}
export function metadata(value: unknown): SubmissionMeta {
  requireWorkshop(validMeta(value), 'bad_metadata');
  return { kind: value.kind, id: value.id, version: value.version, minApp: value.minApp,
    title: { zh: value.title.zh, en: value.title.en }, author: value.author, license: value.license,
    source: value.source, sha256: value.sha256, size: value.size, rightsConfirmed: true,
    ...(value.description ? { description: value.description } : {}), ...(value.tags?.length ? { tags: [...value.tags] } : {}),
    ...(value.previewSource === undefined ? {} : { previewSource: value.previewSource }) };
}
export function blobKey(sha: string): string { return `workshop/blobs/${sha}.zip`; }
export function assetUrl(value: SubmissionMeta): string { return `/market/workshop/${value.kind}/${value.id}/${value.version}/${value.sha256}.zip`; }
export function previewKey(sha: string): string { return `workshop/previews/${sha}.png`; }
export function previewUrl(value: SubmissionMeta, sha: string): string {
  return `/market/workshop/${value.kind}/${value.id}/${value.version}/${value.sha256}/preview/${sha}.png`;
}
export function previewDimensions(width: unknown, height: unknown): boolean {
  return whole(width, 1, PREVIEW_CONTRACT.maxWidth) && whole(height, 1, PREVIEW_CONTRACT.maxHeight) && width * height <= PREVIEW_CONTRACT.maxPixels;
}
export function validPreview(value: unknown, meta: SubmissionMeta): value is PublicPreview {
  return record(value) && meta.previewSource !== undefined && hash(value.sha256) && whole(value.size, 1, PREVIEW_CONTRACT.maxBytes) &&
    previewDimensions(value.width, value.height) && value.path === previewUrl(meta, value.sha256) &&
    Object.keys(value).every(key => ['path', 'sha256', 'size', 'width', 'height'].includes(key));
}
export const identity = (value: { kind: WorkshopKind; id: string }) => `${value.kind}/${value.id}`;
export const releaseId = (value: { kind: WorkshopKind; id: string; version: string }) => `${identity(value)}/${value.version}`;
