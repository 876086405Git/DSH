// AppGallery custom-resource shortcuts. SDK declarations/phone behaviour still
// require local verification; see docs/design/harmonyos/picture-shortcut.md.
import type { productViewManager } from '@kit.AppGalleryKit';
import type common from '@ohos.app.ability.common';
import type Want from '@ohos.app.ability.Want';
import { BusinessError } from '@ohos.base';
import fs from '@ohos.file.fs';
import image from '@ohos.multimedia.image';
import util from '@ohos.util';
import deviceInfo from '@ohos.deviceInfo';

const ICON_LIMIT: number = 100000; // Conservative interpretation of the API's 100 KB.
const SLOT_LIMIT: number = 16;
const RETIRE_AGE_MS: number = 24 * 60 * 60 * 1000;
const SLOT_NAME: RegExp = /^[0-9]{13}-[0-9a-f]{32}$/;

export interface PictureShortcutOutcome { supported: boolean; requested: boolean; }

class PictureKit {
  check: (context: common.UIAbilityContext, id: string, want: Want, label: string,
    foreground: string, background: string) => Promise<productViewManager.CheckShortcutResult>;
  request: (context: common.UIAbilityContext, tid: string) => Promise<void>;
  list: () => Promise<productViewManager.PinShortcutInfo[]>;
  constructor(api: ESObject) {
    this.check = (context: common.UIAbilityContext, id: string, want: Want, label: string,
      foreground: string, background: string): Promise<productViewManager.CheckShortcutResult> =>
      api.checkPinShortcutPermitted(context, id, want, label, foreground, background);
    this.request = (context: common.UIAbilityContext, tid: string): Promise<void> => api.requestNewPinShortcut(context, tid);
    this.list = (): Promise<productViewManager.PinShortcutInfo[]> => api.getPinShortcutInfos();
  }
}

let loading: Promise<PictureKit> | null = null;
let active: PictureShortcutAttempt | null = null;

function loadKit(): Promise<PictureKit> {
  if (loading === null) {
    loading = import('./HmsPictureShortcutKit').then((module: ESObject): PictureKit => {
      if (module.productViewManager === undefined) throw new Error('AppGallery Kit is unavailable');
      return new PictureKit(module.productViewManager);
    }).catch((error: Error): PictureKit => { loading = null; throw error as Error; });
  }
  return loading;
}

export function pictureShortcutSupported(): boolean {
  return deviceInfo.sdkApiVersion >= 14 && canIUse('SystemCapability.AppGalleryService.Distribution.Recommendations');
}

function noRequest(supported: boolean = true): PictureShortcutOutcome { return { supported: supported, requested: false }; }
function missing(error: Error): boolean { return (error as BusinessError).code === 13900002; }

// Android uses 24 Unicode code points, not 24 UTF-16 code units.
export function pictureShortcutLabel(value: string): string {
  const cleaned: string = value.replace(/\s+/g, ' ').trim() || 'DSH Go';
  let end: number = 0;
  for (let count: number = 0; count < 24 && end < cleaned.length; count++) {
    const first: number = cleaned.charCodeAt(end++);
    if (first >= 0xD800 && first <= 0xDBFF && end < cleaned.length) {
      const second: number = cleaned.charCodeAt(end);
      if (second >= 0xDC00 && second <= 0xDFFF) end++;
    }
  }
  return cleaned.substring(0, end);
}

export class PictureShortcutAttempt {
  cancelled: boolean = false;
  submitted: boolean = false;
  finished: boolean = false;
  private readonly context: common.UIAbilityContext;
  private readonly label: string;
  private readonly png: Uint8Array;
  private readonly foreground: () => boolean;
  private source: image.ImageSource | null = null;
  private pixels: image.PixelMap | null = null;
  private packer: image.ImagePacker | null = null;
  private output: fs.File | null = null;
  private directory: string = '';
  private icon: string = '';
  private keepIcon: boolean = false;
  private releasing: Promise<boolean> | null = null;

  constructor(context: common.UIAbilityContext, label: string, png: Uint8Array, foreground: () => boolean) {
    this.context = context; this.label = label; this.png = png; this.foreground = foreground;
  }

  private current(): void {
    if (this.cancelled || !this.foreground()) throw new Error('Picture-shortcut request is no longer foreground');
  }

  private async directoryFor(kit: PictureKit): Promise<string> {
    const root: string = this.context.filesDir + '/picture-shortcuts';
    try { await fs.mkdir(root); } catch (error) {
      if ((error as BusinessError).code !== 13900015) throw error as Error;
    }
    const info: fs.Stat = await fs.lstat(root); this.current();
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('Invalid shortcut icon directory');
    let pinned: Set<string> | null = null;
    if (deviceInfo.sdkApiVersion >= 24) {
      try {
        const existing: productViewManager.PinShortcutInfo[] = await kit.list();
        const reported: Set<string> = new Set<string>();
        existing.forEach((item: productViewManager.PinShortcutInfo): void => {
          if (typeof item.shortcutId !== 'string') throw new Error('Invalid shortcut list');
          reported.add(item.shortcutId);
        });
        pinned = reported;
      } catch (_) { /* Failure is not evidence that any installed shortcut disappeared. */ }
      this.current();
    }
    const names: string[] = await fs.listFile(root); this.current();
    let retained: number = 0;
    for (let index: number = 0; index < names.length; index++) {
      const name: string = names[index];
      if (!SLOT_NAME.test(name)) continue;
      retained++;
      if (pinned === null || pinned.has('picture:' + name) || Date.now() - Number(name.substring(0, 13)) < RETIRE_AGE_MS) continue;
      const slot: string = root + '/' + name;
      try {
        const slotInfo: fs.Stat = await fs.lstat(slot);
        if (!slotInfo.isDirectory() || slotInfo.isSymbolicLink()) continue;
        const children: string[] = await fs.listFile(slot);
        if (children.some((child: string): boolean => child !== 'icon.png')) continue;
        if (children.length === 1) {
          const iconInfo: fs.Stat = await fs.lstat(slot + '/icon.png');
          if (!iconInfo.isFile() || iconInfo.isSymbolicLink()) continue;
          await fs.unlink(slot + '/icon.png');
        }
        await fs.rmdir(slot); retained--;
      } catch (_) { /* Keep uncertain files and count them toward the fixed budget. */ }
      this.current();
    }
    if (retained >= SLOT_LIMIT) throw new Error('Shortcut icon storage is full');
    const name: string = Date.now().toString() + '-' + util.generateRandomUUID(false).replace(/-/g, '');
    if (!SLOT_NAME.test(name)) throw new Error('Invalid shortcut resource name');
    const slot: string = root + '/' + name;
    await fs.mkdir(slot); this.directory = slot; this.current();
    return name;
  }

  private async encodedIcon(): Promise<ArrayBuffer> {
    const encoded: ArrayBuffer = new ArrayBuffer(this.png.byteLength);
    const copied: Uint8Array = new Uint8Array(encoded); copied.set(this.png);
    this.source = image.createImageSource(encoded);
    const info: image.ImageInfo = await this.source.getImageInfo(); this.current();
    const width: number = info.size.width;
    const height: number = info.size.height;
    if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0 || width * height > 16 * 1024 * 1024) {
      throw new Error('Invalid shortcut picture dimensions');
    }
    this.packer = image.createImagePacker();
    const bounds: number[] = [432, 256, 128];
    for (let index: number = 0; index < bounds.length; index++) {
      const bound: number = bounds[index];
      const ratio: number = Math.min(1, bound / width, bound / height);
      const size: image.Size = { width: Math.max(1, Math.floor(width * ratio)), height: Math.max(1, Math.floor(height * ratio)) };
      const options: image.DecodingOptions = { desiredSize: size, desiredPixelFormat: image.PixelMapFormat.RGBA_8888 };
      this.pixels = await this.source.createPixelMap(options); this.current();
      const actual: image.ImageInfo = await this.pixels.getImageInfo(); this.current();
      if (actual.size.width !== size.width || actual.size.height !== size.height) throw new Error('Shortcut resize was not applied');
      const packing: image.PackingOption = { format: 'image/png', quality: 100, bufferSize: 2 * 1024 * 1024 };
      const data: ArrayBuffer = await this.packer.packToData(this.pixels, packing); this.current();
      await this.pixels.release(); this.pixels = null;
      if (data.byteLength > 0 && data.byteLength <= ICON_LIMIT) return data;
    }
    throw new Error('Shortcut icon exceeds the AppGallery size limit');
  }

  private async writeIcon(data: ArrayBuffer): Promise<void> {
    this.icon = this.directory + '/icon.png';
    this.output = await fs.open(this.icon, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
    this.current();
    let offset: number = 0;
    while (offset < data.byteLength) {
      const written: number = await fs.write(this.output.fd, data.slice(offset), { offset: offset }); this.current();
      if (!Number.isInteger(written) || written <= 0 || written > data.byteLength - offset) throw new Error('Shortcut icon write did not progress');
      offset += written;
    }
    await fs.fsync(this.output.fd); this.current();
    await fs.close(this.output.fd); this.output = null;
  }

  async execute(): Promise<PictureShortcutOutcome> {
    let kit: PictureKit;
    try { kit = await loadKit(); } catch (_) { return noRequest(false); }
    this.current();
    const name: string = await this.directoryFor(kit); this.current();
    const data: ArrayBuffer = await this.encodedIcon(); this.current();
    // No system prompt while codec resources have an unresolved release failure.
    if (!(await this.releaseImages())) throw new Error('Shortcut image release failed');
    this.current(); await this.writeIcon(data); this.current();
    const want: Want = { bundleName: this.context.abilityInfo.bundleName,
      moduleName: this.context.abilityInfo.moduleName, abilityName: this.context.abilityInfo.name };
    const checked: productViewManager.CheckShortcutResult = await kit.check(
      this.context, 'picture:' + name, want, this.label, this.icon, '');
    this.current();
    if (checked.code !== 0 || typeof checked.tid !== 'string' || checked.tid.length === 0 ||
      (checked.expired !== undefined && (!Number.isFinite(checked.expired) || checked.expired <= 0))) return noRequest();
    this.submitted = true;
    await kit.request(this.context, checked.tid);
    // The official flow returns the adding result only after the user's decision.
    // Preserve the icon even if the old engine detached during that system dialog.
    this.keepIcon = true;
    return { supported: true, requested: true };
  }

  private async releaseImages(): Promise<boolean> {
    try {
      if (this.pixels !== null) { await this.pixels.release(); this.pixels = null; }
      if (this.packer !== null) { await this.packer.release(); this.packer = null; }
      if (this.source !== null) { await this.source.release(); this.source = null; }
      return true;
    } catch (_) { return false; }
  }

  release(): Promise<boolean> {
    if (this.releasing !== null) return this.releasing;
    this.releasing = this.releaseOwned().finally((): void => { this.releasing = null; });
    return this.releasing;
  }

  private async releaseOwned(): Promise<boolean> {
    if (!(await this.releaseImages())) return false;
    try {
      if (this.output !== null) { await fs.close(this.output.fd); this.output = null; }
      if (!this.keepIcon) {
        if (this.icon.length > 0) {
          try { await fs.unlink(this.icon); } catch (error) { if (!missing(error as Error)) throw error as Error; }
          this.icon = '';
        }
        if (this.directory.length > 0) {
          try { await fs.rmdir(this.directory); } catch (error) { if (!missing(error as Error)) throw error as Error; }
          this.directory = '';
        }
      }
      return true;
    } catch (_) { return false; }
  }
}

// One physical user dialog/resource owner across engine replacements. Failed
// release retains its handles and can be retried by the next explicit request.
export async function pinPictureShortcut(attempt: PictureShortcutAttempt): Promise<PictureShortcutOutcome> {
  if (active !== null) {
    const previous: PictureShortcutAttempt = active;
    if (!previous.finished || !(await previous.release()) || active !== previous) return noRequest();
    active = null;
  }
  if (attempt.cancelled) return noRequest();
  active = attempt;
  let outcome: PictureShortcutOutcome = noRequest();
  try { outcome = await attempt.execute(); } catch (_) { /* Android reports supported=true/requested=false. */ }
  attempt.finished = true;
  if (await attempt.release()) { if (active === attempt) active = null; }
  return outcome;
}
