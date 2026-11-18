// 桌面快捷方式。入口是 resources/base/profile/shortcuts_config.json 的静态声明，点击后系统带
// dshShortcut 参数启动 EntryAbility；Dart 协议与 Android ShortcutsPlugin 相同。未在真机核实。
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import {
  Any, FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';

export default class ShortcutsPlugin implements FlutterPlugin, MethodCallHandler {
  private static pending: Map<string, Any>[] = [];
  private static receiver?: ShortcutsPlugin;
  private channel?: MethodChannel;
  private ready: boolean = false;

  getUniqueClassName(): string { return 'DshShortcutsPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    ShortcutsPlugin.receiver = this;
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/shortcuts');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.ready = false;
    if (ShortcutsPlugin.receiver === this) ShortcutsPlugin.receiver = undefined;
    this.channel?.setMethodCallHandler(null);
    this.channel = undefined;
  }

  // 由 EntryAbility 的 onCreate、onNewWant 调用，所以每次点击只到这里一次。启动原因只在
  // LaunchParam 里，UIAbility 不保留，插件自己在 attach 时拿不到。
  static receive(want: Want, launch: AbilityConstant.LaunchParam): boolean {
    const kind: Any = want.parameters?.['dshShortcut'];
    if (kind !== 'new' && kind !== 'voice') return false;
    const event: Map<string, Any> = new Map<string, Any>();
    // EntryAbility 对外导出，任何应用都能带这个参数启动它。原因串只有系统应用能设，桌面才能
    // 直接打开麦克风（Android 用 EntryActivity 的 token 防同一件事）；其他来源只开新对话。
    event.set('kind', launch.launchReasonMessage === 'ReasonMessage_DesktopShortcut' ? kind : 'new');
    ShortcutsPlugin.pending.push(event);
    ShortcutsPlugin.flush();
    return true;
  }

  private static flush(): void {
    const receiver = ShortcutsPlugin.receiver;
    if (!receiver?.ready || !receiver.channel) return;
    while (ShortcutsPlugin.pending.length > 0) {
      receiver.channel.invokeMethod('entry', ShortcutsPlugin.pending.shift()!);
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'ready':
        this.ready = true;
        result.success(true);
        ShortcutsPlugin.flush();
        return;
      case 'setRecent':
        // 公开的 shortcutManager 只有显隐和查询，发布不了动态快捷方式，最近对话没有地方放。
        // 答成功而不做事：false 表示被限流，Dart 会在下次变化时重试。
        result.success(true);
        return;
      default: result.notImplemented();
    }
  }
}
