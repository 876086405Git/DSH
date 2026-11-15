// OH extension: existing 16kHz PCM tap -> Core Speech, never a second microphone.
// Public API only; NOT compiled against HMS SDK or verified on a phone.
import UIAbility from '@ohos.app.ability.UIAbility';
import {
  AbilityAware, AbilityPluginBinding, Any, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { CaptionNotice, HmsStreamingAsr } from './HmsStreamingAsr';

class CaptionLease {
  engine: FlutterPluginBinding;
  ability: AbilityPluginBinding;
  run: number;
  valid: boolean = true;
  resource: HmsStreamingAsr | null = null;
  retiring: CaptionLease | null = null;
  constructor(engine: FlutterPluginBinding, ability: AbilityPluginBinding, run: number) {
    this.engine = engine; this.ability = ability; this.run = run;
  }
}

class CaptionChannelHandler implements MethodCallHandler {
  private plugin: StreamingAsrPlugin;
  private binding: FlutterPluginBinding;
  constructor(plugin: StreamingAsrPlugin, binding: FlutterPluginBinding) {
    this.plugin = plugin; this.binding = binding;
  }
  onMethodCall(call: MethodCall, result: MethodResult): void { this.plugin.callBound(call, result, this.binding); }
}

export default class StreamingAsrPlugin implements FlutterPlugin, AbilityAware {
  private static owner: StreamingAsrPlugin | null = null;
  private static physical: CaptionLease | null = null;
  private static foreground: WeakSet<UIAbility> = new WeakSet<UIAbility>();
  private binding: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private channel: MethodChannel | null = null;
  private session: CaptionLease | null = null;

  getUniqueClassName(): string { return 'DshStreamingAsrPlugin'; }

  static onForeground(ability: UIAbility): void { StreamingAsrPlugin.foreground.add(ability); }
  static onBackground(ability: UIAbility): void {
    StreamingAsrPlugin.foreground.delete(ability);
    const owner: StreamingAsrPlugin | null = StreamingAsrPlugin.owner;
    if (owner?.ability?.getAbility() === ability) owner.retire('background');
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    StreamingAsrPlugin.owner?.retire('engine-replaced');
    StreamingAsrPlugin.owner = this; this.binding = binding;
    const channel: MethodChannel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/streaming_asr');
    this.channel = channel;
    channel.setMethodCallHandler(new CaptionChannelHandler(this, binding));
  }

  callBound(call: MethodCall, result: MethodResult, binding: FlutterPluginBinding): void {
    if (!['start', 'feed', 'stop'].includes(call.method)) {
      try { result.notImplemented(); } catch (_) {} return;
    }
    this.handle(call, binding).then((): void => {
      try { result.success(null); } catch (_) {}
    }, (error: Error): void => {
      try { result.error('streaming_asr', error.message, null); } catch (_) {}
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.binding !== binding) return;
    this.retire('engine-detached'); this.channel?.setMethodCallHandler(null);
    this.binding = null; this.ability = null; this.channel = null;
    if (StreamingAsrPlugin.owner === this) StreamingAsrPlugin.owner = null;
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability !== null && this.ability !== binding) this.retire('ability-replaced');
    this.ability = binding;
  }
  onDetachedFromAbility(): void { this.retire('ability-detached'); this.ability = null; }

  private live(lease: CaptionLease): boolean {
    return lease.valid && this.session === lease && StreamingAsrPlugin.owner === this &&
      this.binding === lease.engine && this.ability === lease.ability &&
      StreamingAsrPlugin.foreground.has(lease.ability.getAbility());
  }

  private deliver(lease: CaptionLease, notice: CaptionNotice): void {
    if (!this.live(lease)) return;
    const event: Map<string, Any> = new Map<string, Any>([['run', lease.run], ['type', notice.type]]);
    if (notice.text !== undefined) event.set('text', notice.text);
    if (notice.reason !== undefined) event.set('reason', notice.reason);
    try { this.channel?.invokeMethod('event', event); } catch (_) {}
    if (notice.type === 'error') lease.valid = false;
  }

  private retire(reason: string): void {
    const lease: CaptionLease | null = this.session;
    if (lease === null) return;
    // Lifecycle failures are explicit before ownership is invalidated.
    const event: Map<string, Any> = new Map<string, Any>([['run', lease.run], ['type', 'error'], ['reason', reason]]);
    if (lease.valid) { try { this.channel?.invokeMethod('event', event); } catch (_) {} }
    lease.valid = false; this.session = null;
    this.release(lease).catch((): void => {});
  }

  private async release(lease: CaptionLease): Promise<void> {
    lease.valid = false;
    const retiring: CaptionLease | null = lease.retiring;
    if (retiring !== null) { await this.release(retiring); lease.retiring = null; }
    if (lease.resource !== null) await lease.resource.stop(false);
    if (StreamingAsrPlugin.physical === lease) StreamingAsrPlugin.physical = null;
  }

  private async begin(run: number, binding: FlutterPluginBinding): Promise<void> {
    const ability: AbilityPluginBinding | null = this.ability;
    if (this.binding !== binding || StreamingAsrPlugin.owner !== this || ability === null ||
      !StreamingAsrPlugin.foreground.has(ability.getAbility())) throw new Error('no_ability');
    const lease: CaptionLease = new CaptionLease(binding, ability, run);
    const previous: CaptionLease | null = StreamingAsrPlugin.physical;
    if (this.session !== null) this.session.valid = false;
    this.session = lease; lease.retiring = previous;
    if (previous !== null) await this.release(previous);
    lease.retiring = null;
    if (!this.live(lease)) throw new Error('retired');
    const resource: HmsStreamingAsr = new HmsStreamingAsr(
      (notice: CaptionNotice): void => this.deliver(lease, notice), (): boolean => this.live(lease));
    lease.resource = resource; StreamingAsrPlugin.physical = lease;
    try { await resource.start(); }
    catch (error) {
      try { await this.release(lease); } catch (_) {}
      throw error as Error;
    }
  }

  private async handle(call: MethodCall, binding: FlutterPluginBinding): Promise<void> {
    if (this.binding !== binding || StreamingAsrPlugin.owner !== this) throw new Error('retired');
    const run: Any = call.argument('run');
    if (typeof run !== 'number' || !Number.isSafeInteger(run) || run <= 0) throw new Error('arguments');
    if (call.method === 'start') { await this.begin(run, binding); return; }
    const lease: CaptionLease | null = this.session;
    // A delayed Dart stop/feed cannot touch the newer recognizer.
    if (lease === null || lease.run !== run) {
      const retired: CaptionLease | null = StreamingAsrPlugin.physical;
      if (call.method === 'stop' && retired?.engine === binding && retired.run === run) await this.release(retired);
      return;
    }
    if (call.method === 'feed') {
      if (!this.live(lease) || lease.resource === null) throw new Error('retired');
      const bytes: Any = call.argument('bytes');
      if (!(bytes instanceof Uint8Array)) throw new Error('format');
      lease.resource.feed(bytes); return;
    }
    const finalize: Any = call.argument('finalize');
    if (typeof finalize !== 'boolean') throw new Error('arguments');
    if (finalize && this.live(lease) && lease.resource !== null) {
      await lease.resource.stop(true);
      lease.valid = false;
      if (StreamingAsrPlugin.physical === lease) StreamingAsrPlugin.physical = null;
    } else await this.release(lease);
    if (this.session === lease) this.session = null;
  }
}
