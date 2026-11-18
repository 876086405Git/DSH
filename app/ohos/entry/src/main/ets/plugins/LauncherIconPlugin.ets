// 桌面图标：bundleManager 的备用图标（API 26）。app.json5 的 alternateIcons 按 Dart 的图标名
// 声明，mist 是应用自己的图标，所以它等于没有备用图标。未在真机核实。
import bundleManager from '@ohos.bundle.bundleManager';
import { BusinessError } from '@ohos.base';
import {
  Any, FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';

const DEFAULT_ICON: string = 'mist';
const ALTERNATE_ICONS: string[] = ['night', 'frost', 'ink'];
// 取消备用图标时本来就没有启用的：已经是默认图标。
const NO_ALTERNATE_ENABLED: number = 17700309;

function iconReply(current: string): Map<string, Any> {
  const reply: Map<string, Any> = new Map<string, Any>();
  reply.set('current', current);
  return reply;
}

export default class LauncherIconPlugin implements FlutterPlugin, MethodCallHandler {
  private channel?: MethodChannel;

  getUniqueClassName(): string { return 'DshLauncherIconPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/launcher_icon');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = undefined;
  }

  // 系统的 mask 没有公开接口可读，不答 mask：Dart 用自己的圆角方形画预览。
  private async current(): Promise<string> {
    const enabled = (await bundleManager.getAlternateIcons()).filter((icon: bundleManager.AlternateIconInfo) => icon.enabled);
    if (enabled.length === 0) return DEFAULT_ICON;
    if (!ALTERNATE_ICONS.includes(enabled[0].iconName)) throw new Error('Unknown alternate icon');
    return enabled[0].iconName;
  }

  private async set(id: string): Promise<void> {
    try {
      await bundleManager.setAlternateIcon(id === DEFAULT_ICON ? '' : id);
    } catch (error) {
      if (id !== DEFAULT_ICON || (error as BusinessError).code !== NO_ALTERNATE_ENABLED) throw error as Error;
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'state':
        this.current().then((current: string) => result.success(iconReply(current)))
          .catch(() => result.error('failed', '无法读取当前的桌面图标。', null));
        return;
      case 'set': {
        const id: Any = call.argument('id');
        if (id !== DEFAULT_ICON && !ALTERNATE_ICONS.includes(id as string)) { result.error('unknown', '没有这个桌面图标。', null); return; }
        this.set(id as string).then(() => result.success(iconReply(id as string)))
          .catch(() => result.error('failed', '系统没有更换桌面图标。', null));
        return;
      }
      default: result.notImplemented();
    }
  }
}
