// dsh/speech playback contract, read from public dd130b31061e305cd9c06e103c3e5210fee1922f.
// Voice-call capture/model inference is not implemented by this playback plugin.
import UIAbility from '@ohos.app.ability.UIAbility';
import {
  AbilityAware, AbilityPluginBinding, Any, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { OhosPcmStream } from './OhosPcmStream';
import { PcmStreamBackend, PcmStreamListener, PcmStreamOptions, PcmTerminalKind } from './PcmStreamTypes';

class SpeechOpenRequest {
  active: boolean = true;
  readonly engine: FlutterPluginBinding;
  readonly ability: AbilityPluginBinding;
  constructor(engine: FlutterPluginBinding, ability: AbilityPluginBinding) {
    this.engine = engine; this.ability = ability;
  }
}

class SpeechStreamOwner {
  active: boolean = true;
  started: boolean = false;
  opened: boolean = false;
  terminal: boolean = false;
  backend: PcmStreamBackend | null = null;
  closing: Promise<void> | null = null;
  readonly id: string;
  readonly engine: FlutterPluginBinding;
  readonly ability: AbilityPluginBinding;
  readonly methods: MethodChannel;
  readonly plugin: SpeechPlugin;
  constructor(id: string, engine: FlutterPluginBinding, ability: AbilityPluginBinding, methods: MethodChannel,
    plugin: SpeechPlugin) {
    this.id = id; this.engine = engine; this.ability = ability; this.methods = methods; this.plugin = plugin;
  }
}

export default class SpeechPlugin implements FlutterPlugin, AbilityAware {
  private static currentPlugin: SpeechPlugin | null = null;
  private static physicalOwner: SpeechStreamOwner | null = null;
  private static foreground: WeakSet<UIAbility> = new WeakSet<UIAbility>();
  private engine: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private methods: MethodChannel | null = null;
  private request: SpeechOpenRequest | null = null;
  private owner: SpeechStreamOwner | null = null;

  getUniqueClassName(): string { return 'DshSpeechPlugin'; }

  static onForeground(ability: UIAbility): void { SpeechPlugin.foreground.add(ability); }
  static onBackground(ability: UIAbility): void {
    SpeechPlugin.foreground.delete(ability);
    const plugin = SpeechPlugin.currentPlugin;
    if (plugin?.ability?.getAbility() === ability) plugin.retire();
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    SpeechPlugin.currentPlugin?.retire();
    this.methods?.setMethodCallHandler(null);
    SpeechPlugin.currentPlugin = this;
    this.engine = binding; this.ability = null;
    this.methods = new MethodChannel(binding.getBinaryMessenger(), 'dsh/speech');
    this.methods.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (!['open', 'write', 'waiting', 'end', 'stop', 'duck', 'callStart', 'callStop',
        'callMute', 'callBargeIn', 'callPlaying', 'callSpeaker'].includes(call.method)) {
        try { result.notImplemented(); } catch (_) {} return;
      }
      this.handle(call, binding).then((value: Any): void => {
        try { result.success(value); } catch (_) { /* transport retired; exactly one reply attempt */ }
      }, (_error: Error): void => {
        try { result.error('speech-output', '音频输出操作未完成，请停止后重试。', null); } catch (_) {}
      });
    } });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engine !== binding) return;
    this.retire(); this.methods?.setMethodCallHandler(null);
    this.engine = null; this.ability = null; this.methods = null;
    if (SpeechPlugin.currentPlugin === this) SpeechPlugin.currentPlugin = null;
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability !== null && this.ability !== binding) this.retire();
    this.ability = binding;
  }
  onDetachedFromAbility(): void { this.retire(); this.ability = null; }

  private onScreen(): boolean {
    return this.ability !== null && SpeechPlugin.foreground.has(this.ability.getAbility());
  }
  private requestCurrent(request: SpeechOpenRequest): boolean {
    return request.active && this.request === request && SpeechPlugin.currentPlugin === this &&
      this.engine === request.engine && this.ability === request.ability && this.onScreen();
  }
  private current(owner: SpeechStreamOwner): boolean {
    return owner.active && !owner.terminal && this.owner === owner && SpeechPlugin.currentPlugin === this &&
      this.engine === owner.engine && this.ability === owner.ability && this.methods === owner.methods && this.onScreen();
  }
  private emit(owner: SpeechStreamOwner, what: string): void {
    if (this.owner !== owner || this.engine !== owner.engine || this.methods !== owner.methods) return;
    const event: Map<string, Any> = new Map<string, Any>([['type', 'play'], ['what', what], ['id', owner.id]]);
    try { owner.methods.invokeMethod('event', event); } catch (_) { /* retired Flutter transport */ }
  }
  private ended(owner: SpeechStreamOwner, kind: PcmTerminalKind): void {
    if (owner.terminal) return;
    owner.terminal = true; owner.active = false;
    this.emit(owner, kind);
    // Keep the resource handle. A terminal error does not prove release succeeded;
    // stop and the next open must join/retry the backend's physical close.
  }
  private async closeOwner(owner: SpeechStreamOwner): Promise<void> {
    owner.active = false;
    if (owner.closing !== null) return owner.closing;
    const backend = owner.backend;
    if (backend === null) return;
    let work: Promise<void>;
    try { work = backend.stop(); }
    catch (_) { this.ended(owner, PcmTerminalKind.Error); throw new Error('PCM close did not start'); }
    owner.closing = work;
    try {
      await work;
      if (SpeechPlugin.physicalOwner === owner) SpeechPlugin.physicalOwner = null;
    }
    catch (_) { this.ended(owner, PcmTerminalKind.Error); throw new Error('PCM resource not released'); }
    finally { if (owner.closing === work) owner.closing = null; }
  }
  private async stop(): Promise<void> {
    if (this.request !== null) this.request.active = false;
    this.request = null;
    const owner = SpeechPlugin.currentPlugin === this ? SpeechPlugin.physicalOwner ?? this.owner : this.owner;
    if (owner !== null) await owner.plugin.closeOwner(owner);
  }
  private retire(): void { this.stop().catch((): void => {}); }

  private async open(call: MethodCall, engine: FlutterPluginBinding): Promise<boolean> {
    const id: Any = call.argument('id');
    const rateValue: Any = call.argument('rate');
    const rate: Any = rateValue === null || rateValue === undefined ? 24000 : rateValue;
    const forCall: Any = call.argument('call');
    const levels: Any = call.argument('levels');
    if (typeof id !== 'string' || id.length === 0 || typeof rate !== 'number' || !Number.isInteger(rate) || rate !== 24000 ||
      (forCall !== null && forCall !== undefined && typeof forCall !== 'boolean') ||
      (levels !== null && levels !== undefined && typeof levels !== 'boolean') || forCall === true || levels === true) return false;
    const ability = this.ability;
    const methods = this.methods;
    if (this.engine !== engine || SpeechPlugin.currentPlugin !== this || ability === null || methods === null || !this.onScreen()) return false;
    if (this.request !== null) this.request.active = false;
    const request = new SpeechOpenRequest(engine, ability); this.request = request;
    const previous = SpeechPlugin.physicalOwner ?? this.owner;
    if (previous !== null) {
      try { await previous.plugin.closeOwner(previous); } catch (_) { return false; }
    }
    if (!this.requestCurrent(request)) return false;
    const owner = new SpeechStreamOwner(id, engine, ability, methods, this); this.owner = owner;
    SpeechPlugin.physicalOwner = owner;
    const options: PcmStreamOptions = { rate: rate, call: false, levels: false };
    const listener: PcmStreamListener = {
      started: (): void => {
        if (!this.current(owner) || owner.started) return;
        owner.started = true; this.emit(owner, 'start');
      },
      terminal: (kind: PcmTerminalKind, _reason: string): void => {
        // A failed preflight must not close Dart as a successful user stop.
        const result = kind === PcmTerminalKind.Stopped && !owner.opened && this.requestCurrent(request)
          ? PcmTerminalKind.Error : kind;
        this.ended(owner, result);
      }
    };
    const backend: PcmStreamBackend = new OhosPcmStream(options, (): boolean => this.current(owner), listener);
    owner.backend = backend;
    try {
      const opened = await backend.open();
      if (opened && this.requestCurrent(request) && this.current(owner)) { owner.opened = true; return true; }
      if (!opened && this.requestCurrent(request)) this.ended(owner, PcmTerminalKind.Error);
    } catch (_) { if (this.requestCurrent(request)) this.ended(owner, PcmTerminalKind.Error); }
    try { await this.closeOwner(owner); } catch (_) {}
    return false;
  }

  private async handle(call: MethodCall, binding: FlutterPluginBinding): Promise<Any> {
    if (this.engine !== binding || SpeechPlugin.currentPlugin !== this) {
      if (call.method === 'open') return false;
      if (call.method === 'write' || call.method === 'waiting') return -1;
      if (call.method === 'callStart') return 'unavailable';
      if (call.method === 'callSpeaker') return false;
      return null;
    }
    if (call.method === 'open') return this.open(call, binding);
    if (call.method === 'stop') { await this.stop(); return null; }
    // Voice calls require a separately verified microphone, turn detector and
    // inference path. Do not report success or request microphone permission.
    if (call.method === 'callStart') return 'unavailable';
    if (call.method === 'callSpeaker') return false;
    if (['callStop', 'callMute', 'callBargeIn', 'callPlaying'].includes(call.method)) return null;
    const owner = this.owner;
    if (owner === null || owner.id !== call.argument('id') || !this.current(owner) || owner.backend === null) {
      return call.method === 'write' || call.method === 'waiting' ? -1 : null;
    }
    const backend = owner.backend;
    if (call.method === 'waiting') return backend.waiting();
    if (call.method === 'write') {
      const bytes: Any = call.argument('bytes');
      if (!(bytes instanceof Uint8Array)) {
        this.ended(owner, PcmTerminalKind.Error);
        try { await this.closeOwner(owner); } catch (_) {}
        return -1;
      }
      try { return backend.write(bytes); }
      catch (_) {
        this.ended(owner, PcmTerminalKind.Error);
        try { await this.closeOwner(owner); } catch (_) {}
        return -1;
      }
    }
    if (call.method === 'end') {
      try { backend.end(); }
      catch (_) {
        this.ended(owner, PcmTerminalKind.Error);
        await this.closeOwner(owner);
      }
      return null;
    }
    if (call.method === 'duck') {
      try { await backend.duck(call.argument('on') === true); }
      catch (_) { this.ended(owner, PcmTerminalKind.Error); await this.closeOwner(owner); }
    }
    return null;
  }
}
