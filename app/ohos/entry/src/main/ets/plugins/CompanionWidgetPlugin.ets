// 未经目标 SDK / 真机核实。仅数据后端，不代表桌面页面/profile 已注册。
import common from '@ohos.app.ability.common';
import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { WidgetValue, WidgetValues, widgetPatch } from '../companion/CompanionWidgetData';
import { CompanionWidgetStore } from '../companion/CompanionWidgetStore';
import { publishCompanionWidgets } from '../companion/CompanionWidgetForms';

export default class CompanionWidgetPlugin implements FlutterPlugin, MethodCallHandler {
  private channel?: MethodChannel;
  private context?: common.ApplicationContext;
  private pending: Set<MethodResult> = new Set<MethodResult>();

  getUniqueClassName(): string { return 'DshCompanionWidgetPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext().getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/companion_widget');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = undefined;
    this.context = undefined;
    this.pending.forEach((result: MethodResult): void => {
      try { result.error('ohos_widget_detached', '卡片数据通道已关闭。', null); } catch (_error) { /* Engine gone. */ }
    });
    this.pending.clear();
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'update') { result.notImplemented(); return; }
    let patch: Map<string, WidgetValue> | undefined;
    try { patch = widgetPatch(call.args); }
    catch (_error) { result.error('ohos_widget_invalid', '伙伴卡片数据无效。', null); return; }
    if (patch === undefined) { result.success(null); return; }
    const context: common.ApplicationContext | undefined = this.context;
    if (!context) { result.error('ohos_widget_detached', '卡片数据通道已关闭。', null); return; }
    this.pending.add(result);
    CompanionWidgetStore.at(context.filesDir).transact(patch, (values: WidgetValues): Promise<void> =>
      publishCompanionWidgets(context.applicationInfo.name, values)).then((): void => {
      if (this.pending.delete(result)) result.success(null);
    }, (): void => {
      if (this.pending.delete(result)) result.error('ohos_widget_update', '伙伴卡片数据保存或刷新失败。', null);
    });
  }
}
