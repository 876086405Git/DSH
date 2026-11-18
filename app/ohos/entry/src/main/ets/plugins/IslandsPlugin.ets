// Web islands, ArkTS side: MethodChannel `dsh/islands` (lib/ui/plugins/islands/island_platform.dart),
// the counterpart of android/.../islands/IslandsPlugin.kt.
//
// `id` is webview_flutter_ohos's identifier (OhosWebViewController.webViewIdentifier): its
// InstanceManager holds the WebViewPlatformView under it. Dark mode and the renderer callback live on
// that view because they are attributes of its Web component (tooling/ohos/fork-fixes), which may not
// exist yet: a view is only built once a WebViewWidget shows it, and a call that needs the component
// before then has nothing to act on. Dart treats every call but `attach` as best effort.
//
// The app is phone only, where ArkWeb's default is one renderer for every Web component, so Dart's
// "one renderer, every WebView goes with it" holds as on Android; each affected component reports.
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import appManager from '@ohos.app.ability.appManager';
import EnvironmentCallback from '@ohos.app.ability.EnvironmentCallback';
import hidebug from '@ohos.hidebug';
import {
  Any, FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { systemMemoryBytes } from './OhosDeviceFacts';

const WEBVIEW_PLUGIN: string = 'WebViewFlutterPlugin';

/** `MemoryLevel` as the `ComponentCallbacks2` level it means; null where IslandPolicy.forwardsTrim wouldn't forward. */
function trimLevel(level: AbilityConstant.MemoryLevel): number | null {
  switch (level) {
    case AbilityConstant.MemoryLevel.MEMORY_LEVEL_LOW: return 10;
    case AbilityConstant.MemoryLevel.MEMORY_LEVEL_CRITICAL: return 15;
    case AbilityConstant.MemoryLevel.MEMORY_LEVEL_BACKGROUND_MODERATE: return 40;
    case AbilityConstant.MemoryLevel.MEMORY_LEVEL_BACKGROUND_LOW: return 60;
    case AbilityConstant.MemoryLevel.MEMORY_LEVEL_BACKGROUND_CRITICAL: return 80;
    default: return null;
  }
}

export default class IslandsPlugin implements FlutterPlugin, MethodCallHandler {
  private binding: FlutterPluginBinding | null = null;
  private methods: MethodChannel | null = null;
  private memoryWatch: number | null = null;

  getUniqueClassName(): string { return 'DshIslandsPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.binding = binding;
    this.methods = new MethodChannel(binding.getBinaryMessenger(), 'dsh/islands');
    this.methods.setMethodCallHandler(this);
    const watcher: EnvironmentCallback = {
      onConfigurationUpdated: (): void => {},
      onMemoryLevel: (level: AbilityConstant.MemoryLevel): void => {
        const trim = trimLevel(level);
        if (trim === null) return;
        const args: Map<string, Any> = new Map<string, Any>();
        args.set('level', trim);
        this.methods?.invokeMethod('trimMemory', args);
      }
    };
    try {
      this.memoryWatch = binding.getApplicationContext().getApplicationContext().on('environment', watcher);
    } catch (_) { /* No pressure reports; the budget still holds. */ }
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    try {
      if (this.memoryWatch !== null) binding.getApplicationContext().getApplicationContext().off('environment', this.memoryWatch);
    } catch (_) {}
    this.memoryWatch = null;
    this.methods?.setMethodCallHandler(null);
    this.methods = null;
    this.binding = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'device':
        this.device().then((facts: Map<string, Any>): void => result.success(facts));
        return;
      case 'appPss':
        this.appPss(result);
        return;
      case 'attach':
        result.success(this.attach(call));
        return;
      case 'setDark':
        this.onWebView(call, result, (view: Any): void => view.setDarkMode(call.argument('dark') === true));
        return;
      case 'setTextZoom':
        this.onWebView(call, result, (view: Any): void => this.setTextZoom(view, call.argument('zoom')));
        return;
      case 'pause':
        this.onWebView(call, result, (view: Any): void => view.onInactive());
        return;
      case 'resume':
        this.onWebView(call, result, (view: Any): void => view.onActive());
        return;
      case 'destroy':
        this.onWebView(call, result, (view: Any): void => {
          view.setOnRenderExitedCallback(undefined);
          view.dispose();
        });
        return;
      default:
        result.notImplemented();
    }
  }

  /** The WebView `call` names, or null when there's no such WebView. */
  private webView(call: MethodCall): Any {
    const id: Any = call.argument('id');
    if (typeof id !== 'number' || !Number.isSafeInteger(id)) return null;
    const registry = this.binding?.getFlutterEngine().getPlugins();
    if (!registry || !registry.has(WEBVIEW_PLUGIN)) return null;
    const plugin: Any = registry.get(WEBVIEW_PLUGIN);
    return plugin.getInstanceManager()?.getInstance(id) ?? null;
  }

  /** No Web component to act on yet (17100001) is no error here: the call just has no effect. */
  private onWebView(call: MethodCall, result: MethodResult, action: (view: Any) => void): void {
    const view: Any = this.webView(call);
    try {
      if (view !== null) action(view);
    } catch (_) {}
    result.success(null);
  }

  private attach(call: MethodCall): boolean {
    const view: Any = this.webView(call);
    if (view === null) return false;
    const id: number = call.argument('id');
    try {
      view.setDarkMode(call.argument('dark') === true);
      this.setTextZoom(view, call.argument('textZoom'));
      view.setOnRenderExitedCallback((crashed: boolean): void => {
        const args: Map<string, Any> = new Map<string, Any>();
        args.set('id', id);
        args.set('crashed', crashed);
        this.methods?.invokeMethod('rendererGone', args);
      });
      return true;
    } catch (_) {
      return false; // The identifier of something that isn't a WebView.
    }
  }

  /** The fork's own text zoom: WebSettings drives the Web component's textZoomRatio. */
  private setTextZoom(view: Any, percent: Any): void {
    if (typeof percent === 'number') view.getWebSettings().setTextZoom(Math.min(300, Math.max(50, Math.round(percent))));
  }

  /** What the system won't say stays absent; no totalMem is Dart's IslandDevice.unknown. No provider string for `webView`. */
  private async device(): Promise<Map<string, Any>> {
    const facts: Map<string, Any> = new Map<string, Any>();
    const total = systemMemoryBytes();
    if (total !== null) {
      facts.set('totalMem', total);
      try {
        facts.set('availMem', Number(hidebug.getSystemMemInfo().availableMem) * 1024);
      } catch (_) {}
    }
    try {
      facts.set('lowRam', await appManager.isRamConstrainedDevice());
    } catch (_) {}
    return facts;
  }

  /** kB, as `Debug.getPss`. The async form: reading smaps_rollup is slow. */
  private appPss(result: MethodResult): void {
    const fail = (): void => result.error('ohos_islands_memory', 'App memory is unavailable.', null);
    try {
      hidebug.getAppNativeMemInfoAsync().then((info: hidebug.NativeMemInfo): void => result.success(Number(info.pss)), fail);
    } catch (_) {
      fail();
    }
  }
}
