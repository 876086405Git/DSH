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

class LinkArrival { event?: Map<string, Any>; }

export default class AppLinksPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler, NewWantListener {
  private static launches: WeakSet<UIAbility> = new WeakSet<UIAbility>();
  private static pending: LinkArrival[] = [];
  private static receiver?: AppLinksPlugin;
  private static copying: number = 0;
  private app?: MethodChannel;
  private links?: MethodChannel;
  private ability?: AbilityPluginBinding;
  private ready: boolean = false;

  getUniqueClassName(): string { return 'DshAppLinksPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    AppLinksPlugin.receiver = this;
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
    if (AppLinksPlugin.receiver === this) AppLinksPlugin.receiver = undefined;
    this.app?.setMethodCallHandler(null);
    this.links?.setMethodCallHandler(null);
    this.app = undefined;
    this.links = undefined;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.onDetachedFromAbility();
    this.ability = binding;
    binding.addOnNewWantListener(this);
    const ability = binding.getAbility();
    if (!AppLinksPlugin.launches.has(ability) && this.take(ability.launchWant)) {
      AppLinksPlugin.launches.add(ability);
    }
  }

  onDetachedFromAbility(): void {
    this.ability?.removeOnNewWantListener(this);
    this.ability = undefined;
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
      case 'setRefreshRateMode':
        if (call.argument('mode') === 'system') result.success(null);
        else result.error('ohos_unsupported', '当前由鸿蒙与 Flutter 管理刷新率，请选择系统默认。', null);
        return;
      case 'setFrameActive':
        // system 模式不强制帧率，也不新增周期性VSync请求。
        result.success(null);
        return;
      default: result.notImplemented();
    }
  }
}
