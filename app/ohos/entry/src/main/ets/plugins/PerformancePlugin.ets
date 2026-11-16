// Public OH implementation of the existing Dart performance protocol.
import {
  Any, EventChannel, EventSink, FlutterManager, FlutterPlugin, FlutterPluginBinding, FlutterView,
  MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { performanceDeviceFacts } from './OhosDeviceFacts';
import { ohosThermal } from './OhosThermalState';

let performanceSequence: number = 0;
// Null until Dart chooses. Dart can answer before the window exists, so this outlives the
// call and EntryAbility applies it to the view it just created.
let frameCacheChoice: boolean | null = null;

export default class PerformancePlugin implements FlutterPlugin {
  private binding: FlutterPluginBinding | null = null;
  private methods: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private device: Map<string, Any> | null = null;
  private observer: (() => void) | null = null;
  private sequence: number = 0;

  // The engine's own frame cache, on by default: smoother, at slightly more touch delay.
  static applyFrameCache(): void {
    const enabled = frameCacheChoice;
    if (enabled === null) return;
    FlutterManager.getInstance().getFlutterViewList().forEach((view: FlutterView): void => {
      view.enableFrameCache(enabled);
    });
  }

  getUniqueClassName(): string { return 'DshPerformancePlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (this.binding !== null) this.onDetachedFromEngine(this.binding);
    this.binding = binding;
    this.methods = new MethodChannel(binding.getBinaryMessenger(), 'dsh/performance');
    this.events = new EventChannel(binding.getBinaryMessenger(), 'dsh/performance/events');
    this.methods.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (this.binding !== binding) { this.fail(result); return; }
      switch (call.method) {
        case 'snapshot':
          this.ensure(binding); ohosThermal.refresh();
          try { result.success(this.snapshot()); } catch (_) {}
          return;
        case 'setFrameCache': this.setFrameCache(call, result); return;
        default: try { result.notImplemented(); } catch (_) {}
      }
    } });
    this.events.setStreamHandler({
      onListen: (_args: Any, sink: EventSink): void => {
        if (this.binding !== binding) return;
        this.sink = sink; this.ensure(binding); this.emit();
      },
      onCancel: (_args: Any): void => { if (this.binding === binding) this.sink = null; }
    });
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.binding !== binding) return;
    if (this.observer !== null) ohosThermal.unsubscribe(this.observer);
    this.observer = null; this.device = null; this.sink = null; this.binding = null;
    this.methods?.setMethodCallHandler(null);
    binding.getBinaryMessenger().setMessageHandler('dsh/performance/events', null);
    this.methods = null; this.events = null;
  }
  private ensure(binding: FlutterPluginBinding): void {
    if (this.device !== null) return;
    this.device = performanceDeviceFacts(); this.sequence = ++performanceSequence;
    const observer = (): void => {
      if (this.binding !== binding) return;
      this.sequence = ++performanceSequence; this.emit();
    };
    this.observer = observer; ohosThermal.subscribe(observer);
  }
  private snapshot(): Map<string, Any> {
    const value: Map<string, Any> = new Map<string, Any>();
    value.set('sequence', this.sequence); value.set('device', this.device); value.set('thermal', ohosThermal.snapshot());
    return value;
  }
  private emit(): void { try { this.sink?.success(this.snapshot()); } catch (_) {} }
  private setFrameCache(call: MethodCall, result: MethodResult): void {
    const enabled: Any = call.argument('enabled');
    try {
      if (typeof enabled !== 'boolean') { result.error('bad_args', '帧缓存参数无效。', null); return; }
      frameCacheChoice = enabled;
      PerformancePlugin.applyFrameCache();
      result.success(null);
    } catch (_) { try { result.error('frame_cache', '帧缓存设置未生效。', null); } catch (_) {} }
  }
  private fail(result: MethodResult): void { try { result.error('detached', '性能通道已关闭。', null); } catch (_) {} }
}
