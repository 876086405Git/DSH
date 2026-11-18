// 未编译、未在真机核实。公开接口和未实现边界见 app-links-channels.md。
import i18n from '@ohos.i18n';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import common from '@ohos.app.ability.common';
import wantConstant from '@ohos.app.ability.wantConstant';
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import util from '@ohos.util';
import {
  AbilityAware, AbilityPluginBinding, Any, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodCallHandler, MethodChannel, MethodResult, NewWantListener
} from '@ohos/flutter_ohos';
import { OhosFrameRateKeeper } from './OhosFrameRate';
import type { BusinessError } from '@ohos.base';
import type { scanBarcode } from '@kit.ScanKit';
import type { ScanKit } from './HmsKits';

class LinkArrival { event?: Map<string, Any>; }

// Scan Kit's documented code for "the user closed the scan page" (5.0.0(12)+).
const SCAN_CANCELED = 1000500002;

class ScanFailure extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

export default class AppLinksPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler, NewWantListener {
  private static launches: WeakSet<UIAbility> = new WeakSet<UIAbility>();
  private static pending: LinkArrival[] = [];
  private static receiver?: AppLinksPlugin;
  private static copying: number = 0;
  private static foreground: WeakSet<UIAbility> = new WeakSet<UIAbility>();
  private static attached: Set<AppLinksPlugin> = new Set<AppLinksPlugin>();
  private static scanning: boolean = false;
  private app?: MethodChannel;
  private links?: MethodChannel;
  private ability?: AbilityPluginBinding;
  private ready: boolean = false;
  private frames?: OhosFrameRateKeeper;

  static onForeground(ability: UIAbility): void {
    AppLinksPlugin.foreground.add(ability);
    AppLinksPlugin.attached.forEach((plugin: AppLinksPlugin): void => plugin.showFrames());
  }

  static onBackground(ability: UIAbility): void {
    AppLinksPlugin.foreground.delete(ability);
    AppLinksPlugin.attached.forEach((plugin: AppLinksPlugin): void => plugin.showFrames());
  }

  getUniqueClassName(): string { return 'DshAppLinksPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    AppLinksPlugin.receiver = this;
    AppLinksPlugin.attached.add(this);
    this.frames?.close();
    this.frames = new OhosFrameRateKeeper((): boolean => {
      const napi = binding.getFlutterEngine().getFlutterNapi();
      if (!napi.isAttached()) return false;
      napi.LTPODispatchHighFrameRate();
      return true;
    });
    const messenger = binding.getBinaryMessenger();
    this.app = new MethodChannel(messenger, 'dsh/app');
    this.links = new MethodChannel(messenger, 'dsh/links');
    this.app.setMethodCallHandler(this);
    this.links.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        if (call.method !== 'ready') { result.notImplemented(); return; }
        this.ready = true;
        result.success(true);
        AppLinksPlugin.flush();
      }
    });
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.onDetachedFromAbility();
    this.ready = false;
    AppLinksPlugin.attached.delete(this);
    this.frames?.close();
    this.frames = undefined;
    if (AppLinksPlugin.receiver === this) AppLinksPlugin.receiver = undefined;
    this.app?.setMethodCallHandler(null);
    this.links?.setMethodCallHandler(null);
    this.app = undefined;
    this.links = undefined;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.onDetachedFromAbility();
    this.ability = binding;
    this.showFrames();
    binding.addOnNewWantListener(this);
    const ability = binding.getAbility();
    if (!AppLinksPlugin.launches.has(ability) && this.take(ability.launchWant)) {
      AppLinksPlugin.launches.add(ability);
    }
  }

  onDetachedFromAbility(): void {
    this.ability?.removeOnNewWantListener(this);
    this.ability = undefined;
    this.showFrames();
  }

  private showFrames(): void {
    const ability = this.ability?.getAbility();
    this.frames?.setVisible(ability !== undefined && AppLinksPlugin.foreground.has(ability));
  }

  onNewWant(want: Want, _launchParams: AbilityConstant.LaunchParam): void {
    if (this.ability) this.take(want);
  }

  private take(want: Want): boolean {
    if (want.action !== 'ohos.want.action.viewData') return false;
    const uri = want.uri ?? '';
    if (uri.length === 0 || uri.length > 64 * 1024) return false;
    const colon = uri.indexOf(':');
    if (colon < 1) return false;
    const scheme = uri.slice(0, colon).toLowerCase();
    if (!['dshgo', 'https', 'http', 'file', 'content'].includes(scheme)) return false;
    const arrival = new LinkArrival();
    AppLinksPlugin.pending.push(arrival);
    const event: Map<string, Any> = new Map<string, Any>();
    switch (scheme) {
      case 'dshgo': case 'https': case 'http':
        event.set('uri', uri);
        break;
      case 'file': {
        if (AppLinksPlugin.copying >= 4) {
          event.set('error', 'unreadable'); event.set('name', null); break;
        }
        // 立即请求只读FD，不等先前复制完成；授权是否有效由OS实际open判定。
        const context = this.ability!.getAbility().context;
        AppLinksPlugin.copying++;
        this.copyIncoming(uri, want.flags ?? 0, context).then((path: string) => {
          event.set('uri', 'file://' + path.split('/').map((part: string) => encodeURIComponent(part)).join('/'));
        }).catch(() => {
          event.set('error', 'unreadable'); event.set('name', null);
        }).then(() => {
          AppLinksPlugin.copying--;
          arrival.event = event;
          AppLinksPlugin.flush();
        });
        return true;
      }
      case 'content':
        event.set('error', 'unreadable');
        event.set('name', null);
        break;
    }
    arrival.event = event;
    AppLinksPlugin.flush();
    return true;
  }

  private static flush(): void {
    const receiver = AppLinksPlugin.receiver;
    if (!receiver?.ready || !receiver.links) return;
    while (AppLinksPlugin.pending.length > 0 && AppLinksPlugin.pending[0].event) {
      const event: Map<string, Any> = AppLinksPlugin.pending.shift()!.event!;
      receiver.links.invokeMethod('link', event);
    }
  }

  private async copyIncoming(uri: string, flags: number, context: common.UIAbilityContext): Promise<string> {
    if ((flags & wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION) === 0 || !uri.startsWith('file://')) {
      throw new Error('Missing external file grant');
    }
    const slash = uri.indexOf('/', 7);
    const authority = slash < 0 ? '' : uri.substring(7, slash);
    if (!/^[A-Za-z0-9_.-]+$/.test(authority) || authority === '.' || authority === '..' ||
      authority.toLowerCase() === context.abilityInfo.bundleName.toLowerCase()) {
      throw new Error('Only external file authorities are accepted');
    }
    const path = decodeURIComponent(uri.substring(slash));
    if (uri.includes('?') || uri.includes('#') || path.includes('\0') ||
      path.split('/').some((part: string) => part === '.' || part === '..')) throw new Error('Invalid file URI path');
    const source = new fileUri.FileUri(uri);
    const cleaned = source.name.replace(/[\x00-\x1f\x7f\\/:*?"'`<>|{}\[\]]/g, '_').trim();
    const encoder = new util.TextEncoder();
    const dot = cleaned.lastIndexOf('.');
    const extension = dot > 0 && encoder.encodeInto(cleaned.substring(dot)).byteLength <= 32 ? cleaned.substring(dot) : '';
    const stem = extension.length > 0 ? cleaned.substring(0, dot) : cleaned;
    const limit = 240 - encoder.encodeInto(extension).byteLength;
    let name = '';
    for (const character of stem) {
      if (encoder.encodeInto(name + character).byteLength > limit) break;
      name += character;
    }
    name += extension;
    if (name === '' || name === '.' || name === '..') name = 'file';
    const input = await fs.open(uri, fs.OpenMode.READ_ONLY | fs.OpenMode.NONBLOCK);
    let directory: string | undefined;
    let target: string | undefined;
    let complete = false;
    try {
      const stat = await fs.stat(input.fd);
      if (!stat.isFile() || stat.size > 30 * 1024 * 1024) throw new Error('File size or kind unsupported');
      directory = await fs.mkdtemp(context.cacheDir + '/dsh-incoming-XXXXXX');
      target = directory + '/' + name;
      const output = await fs.open(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const buffer = new ArrayBuffer(256 * 1024);
        let offset = 0;
        while (offset < stat.size) {
          const count = await fs.read(input.fd, buffer, { offset: offset, length: Math.min(buffer.byteLength, stat.size - offset) });
          if (count === 0) throw new Error('Source shortened');
          let written = 0;
          while (written < count) {
            const n = await fs.write(output.fd, buffer.slice(written, count), { offset: offset + written });
            if (n === 0) throw new Error('Write made no progress');
            written += n;
          }
          offset += count;
        }
        if ((await fs.stat(input.fd)).size !== stat.size) throw new Error('Source size changed');
        await fs.fsync(output.fd);
      } finally { await fs.close(output); }
      complete = true;
      return target;
    } finally {
      try { await fs.close(input); }
      finally {
        if (!complete && directory) {
          if (target) { try { await fs.unlink(target); } catch (_error) { /* OS may already remove cache. */ } }
          try {
            const stat = await fs.lstat(directory);
            if (stat.isDirectory() && !stat.isSymbolicLink() && (await fs.listFile(directory)).length === 0) {
              await fs.rmdir(directory);
            }
          } catch (_error) { /* Leave an unremovable cache entry for the OS. */ }
        }
      }
    }
  }

  // 扫码配对电脑: the system scan page (Scan Kit default view) owns the camera and its
  // album entry, so the app needs no camera permission. Cancel answers null.
  private scanQrCode(result: MethodResult): void {
    const ability = this.ability?.getAbility();
    if (!ability || !AppLinksPlugin.foreground.has(ability)) {
      result.error('no_ability', '应用窗口当前不可用。', null);
      return;
    }
    if (AppLinksPlugin.scanning) { result.error('busy', '扫码页面已经打开。', null); return; }
    AppLinksPlugin.scanning = true;
    AppLinksPlugin.scan(ability.context).then((text: string | null): void => {
      AppLinksPlugin.scanning = false;
      try { result.success(text); } catch (_error) { /* The engine left while the scan page was open. */ }
    }).catch((error: Error): void => {
      AppLinksPlugin.scanning = false;
      const failure = error instanceof ScanFailure ? error : new ScanFailure('failed', '系统扫码没有完成。');
      try { result.error(failure.code, failure.message, null); } catch (_error) { /* Engine left. */ }
    });
  }

  // Scan Kit loads on the first scan only: a device without it answers 'unavailable'
  // and nothing else on dsh/app depends on it.
  private static async scan(context: common.UIAbilityContext): Promise<string | null> {
    if (!canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) throw new ScanFailure('unavailable', '这台设备没有系统扫码。');
    let kit: ScanKit;
    try {
      kit = await import('./HmsKits').then((kits: ESObject): Promise<ScanKit> => kits.loadScanKit());
    } catch (_error) {
      throw new ScanFailure('unavailable', '这台设备没有系统扫码。');
    }
    let scanned: scanBarcode.ScanResult;
    try {
      scanned = await kit.startScan(context, { scanTypes: [kit.qrCode], enableMultiMode: false, enableAlbum: true });
    } catch (error) {
      if ((error as BusinessError).code === SCAN_CANCELED) return null;
      throw new ScanFailure('failed', '系统扫码没有完成。');
    }
    const text = scanned.originalValue;
    if (typeof text !== 'string' || text.length === 0) throw new ScanFailure('failed', '没有读到二维码内容。');
    return text;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'getTimeZoneId':
        try { result.success(i18n.getTimeZone().getID()); }
        catch (_error) { result.error('ohos_timezone', '无法读取系统时区，请重试。', null); }
        return;
      case 'bringToFront': {
        const ability = this.ability?.getAbility();
        if (!ability) { result.error('no_ability', '应用窗口当前不可用。', null); return; }
        try {
          const info = ability.context.abilityInfo;
          ability.context.startAbility({ bundleName: info.bundleName, abilityName: info.name })
            .then(() => result.success(null))
            .catch(() => result.error('ohos_foreground', '系统未允许回到前台，请从应用图标打开。', null));
        } catch (_error) {
          result.error('ohos_foreground', '系统未允许回到前台，请从应用图标打开。', null);
        }
        return;
      }
      case 'setRefreshRateMode': {
        const mode: string = call.argument('mode');
        if (!['auto', 'max', 'system'].includes(mode)) {
          result.error('ohos_unsupported', '未知的刷新率模式。', null);
          return;
        }
        this.frames?.setMode(mode);
        result.success(null);
        return;
      }
      case 'scanQrCode':
        this.scanQrCode(result);
        return;
      case 'setFrameActive': {
        const active: Any = call.argument('active');
        if (typeof active === 'boolean') this.frames?.setActive(active);
        result.success(null);
        return;
      }
      default: result.notImplemented();
    }
  }
}
