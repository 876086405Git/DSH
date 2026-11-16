// Device query only. The Android-only usage v1 envelope stays ineligible on OHOS.
import bundleManager from '@ohos.bundle.bundleManager';
import deviceInfo from '@ohos.deviceInfo';
import { Any, FlutterPlugin, FlutterPluginBinding, MethodCall, MethodChannel, MethodResult } from '@ohos/flutter_ohos';

export default class UsagePlugin implements FlutterPlugin {
  private binding: FlutterPluginBinding | null = null;
  private methods: MethodChannel | null = null;
  private generation: number = 0;

  getUniqueClassName(): string { return 'DshUsagePlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (this.binding !== null) this.onDetachedFromEngine(this.binding);
    this.binding = binding;
    const generation = ++this.generation;
    this.methods = new MethodChannel(binding.getBinaryMessenger(), 'dsh/usage');
    this.methods.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (this.binding !== binding || generation !== this.generation) { this.fail(result, 'ohos_detached'); return; }
      if (call.method !== 'device') { try { result.notImplemented(); } catch (_) {} return; }
      this.device().then((value: Map<string, Any>): void => {
        if (this.binding !== binding || generation !== this.generation) { this.fail(result, 'ohos_detached'); return; }
        try { result.success(value); } catch (_) { /* The retired messenger cannot receive a result. */ }
      }, (): void => this.fail(result, 'ohos_usage_unavailable'));
    } });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.binding !== binding) return;
    this.binding = null; this.generation++;
    this.methods?.setMethodCallHandler(null); this.methods = null;
  }

  private fail(result: MethodResult, code: string): void {
    try { result.error(code, '设备信息暂时不可用。', null); } catch (_) {}
  }

  private async device(): Promise<Map<string, Any>> {
    const info = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const api = deviceInfo.sdkApiVersion;
    if (!Number.isSafeInteger(api) || api < 1) throw new Error('invalid public API version');
    const abi = deviceInfo.abiList.split(',').map((value: string): string => value.trim())
      .find((value: string): boolean => value.length > 0) ?? '';
    const maker = deviceInfo.manufacture.toLowerCase().replace(/[^a-z0-9 ._-]/g, '')
      .replace(/^[^a-z0-9]+/, '').substring(0, 32).trim() || 'unknown';
    return new Map<string, Any>([['versionName', info.versionName], ['versionCode', info.versionCode],
      ['platform', 'ohos'], ['apiVersion', api],
      // sdk means Android API level in usage v1. Zero is the existing unknown
      // sentinel, so usageProblem rejects sending this as Android statistics.
      ['sdk', 0], ['abi', abi], ['maker', maker]]);
  }
}
