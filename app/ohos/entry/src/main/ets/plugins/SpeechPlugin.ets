// dsh/speech playback contract, aligned with the 8faafe6 Android snapshot.
// Call capture uses the Android energy fallback; no NeuralGate equivalence claim.
import UIAbility from '@ohos.app.ability.UIAbility';
import {
  AbilityAware, AbilityPluginBinding, Any, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { OhosPcmStream } from './OhosPcmStream';
import { OhosSpeechPlayback, SpeechPlaybackOwner } from './OhosSpeechPlayback';
import { PcmStreamBackend, PcmStreamListener, PcmStreamOptions, PcmTerminalKind } from './PcmStreamTypes';
import { OhosSpeechCall } from './OhosSpeechCall';
import { CallCaptureListener } from './OhosCallCapture';

// One pending callStart's choices, including changes before a capture owner exists.
class SpeechCallStart {
  muted: boolean;
  pause: string;
  constructor(muted: boolean, pause: string) { this.muted = muted; this.pause = pause; }
}

class SpeechOpenRequest {
  active: boolean = true;
  call: boolean = false;
  readonly engine: FlutterPluginBinding;
  readonly ability: AbilityPluginBinding;
  constructor(engine: FlutterPluginBinding, ability: AbilityPluginBinding) {
    this.engine = engine; this.ability = ability;
  }
}

class SpeechStreamOwner implements SpeechPlaybackOwner {
  stopPlayback: () => Promise<void>;
  active: boolean = true;
  call: boolean = false;
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
    this.stopPlayback = (): Promise<void> => plugin.closeOwner(this);
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
  private calls: OhosSpeechCall | null = null;
  private callGeneration: number = 0;
  private callStartRequest: SpeechCallStart | null = null;
  private externalPlaying: boolean = false;

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
    const listener: CallCaptureListener = {
      speechStart: (over: boolean): void => {
        const owner: SpeechStreamOwner | null = this.owner;
        if (over && owner?.call && owner.backend && this.current(owner)) {
          owner.backend.duck(true).catch((): void => {
            this.ended(owner, PcmTerminalKind.Error); this.closeOwner(owner).catch((): void => {});
          });
        }
        this.callEvent(binding, new Map<string, Any>([['type', 'speechStart'], ['over', over]]));
      },
      utterance: (wav: Uint8Array, ms: number): void => this.callEvent(binding,
        new Map<string, Any>([['type', 'utterance'], ['wav', wav], ['ms', ms]])),
      level: (value: number): void => this.callEvent(binding, new Map<string, Any>([['type', 'micLevel'], ['value', value]])),
      error: (reason: string): void => {
        this.callEvent(binding, new Map<string, Any>([['type', 'callError'], ['reason', reason]]));
        this.stopCallPlayback().catch((): void => {});
      }
    };
    const calls: OhosSpeechCall = new OhosSpeechCall(
      (): boolean => this.calls === calls && this.engine === binding && SpeechPlugin.currentPlugin === this && this.onScreen(),
      listener, async (on: boolean): Promise<void> => {
        const owner: SpeechStreamOwner | null = this.owner;
        if (owner?.call && owner.backend && this.current(owner)) await owner.backend.setSpeaker(on);
      });
    this.calls = calls;
    this.methods.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (!['open', 'write', 'waiting', 'end', 'stop', 'duck', 'callStart', 'callStop',
        'callMute', 'callBargeIn', 'callPause', 'callPlaying', 'callSpeaker'].includes(call.method)) {
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
      this.engine === owner.engine && this.ability === owner.ability && this.methods === owner.methods && this.onScreen() &&
      OhosSpeechPlayback.isCurrent(owner);
  }
  private emit(owner: SpeechStreamOwner, what: string): void {
    if (this.owner !== owner || this.engine !== owner.engine || this.methods !== owner.methods) return;
    const event: Map<string, Any> = new Map<string, Any>([['type', 'play'], ['what', what], ['id', owner.id]]);
    try { owner.methods.invokeMethod('event', event); } catch (_) { /* retired Flutter transport */ }
  }
  private emitLevel(owner: SpeechStreamOwner, value: number): void {
    if (!this.current(owner)) return;
    const event: Map<string, Any> = new Map<string, Any>([['type', 'playLevel'], ['id', owner.id], ['value', value]]);
    try { owner.methods.invokeMethod('event', event); } catch (_) {}
  }
  private callEvent(binding: FlutterPluginBinding, event: Map<string, Any>): void {
    if (this.engine !== binding || SpeechPlugin.currentPlugin !== this || !this.onScreen()) return;
    try { this.methods?.invokeMethod('event', event); } catch (_) { /* retired Flutter transport */ }
  }
  private syncCallPlaying(): void {
    const owner: SpeechStreamOwner | null = this.owner;
    this.calls?.setPlaying(this.externalPlaying || (owner !== null && owner.call && owner.started && this.current(owner)));
  }
  private ended(owner: SpeechStreamOwner, kind: PcmTerminalKind): void {
    if (owner.terminal) return;
    owner.terminal = true; owner.active = false;
    this.syncCallPlaying();
    this.emit(owner, kind);
    // Keep the resource handle. A terminal error does not prove release succeeded;
    // stop and the next open must join/retry the backend's physical close.
  }
  async closeOwner(owner: SpeechStreamOwner): Promise<void> {
    owner.active = false;
    this.syncCallPlaying();
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
    if (owner !== null) await OhosSpeechPlayback.release(owner);
  }
  private async stopCallPlayback(): Promise<void> {
    if (this.request?.call) { this.request.active = false; this.request = null; }
    const owner: SpeechStreamOwner | null = this.owner;
    if (owner?.call) await this.closeOwner(owner);
  }
  private retire(): void {
    this.callGeneration++; this.callStartRequest = null; this.externalPlaying = false;
    this.calls?.stop().catch((): void => {}); this.stop().catch((): void => {});
  }

  private async open(call: MethodCall, engine: FlutterPluginBinding): Promise<boolean> {
    const id: Any = call.argument('id');
    const rateValue: Any = call.argument('rate');
    const rate: Any = rateValue === null || rateValue === undefined ? 24000 : rateValue;
    const forCall: Any = call.argument('call');
    const levels: Any = call.argument('levels');
    if (typeof id !== 'string' || id.length === 0 || typeof rate !== 'number' || !Number.isInteger(rate) || rate !== 24000 ||
      (forCall !== null && forCall !== undefined && typeof forCall !== 'boolean') ||
      (levels !== null && levels !== undefined && typeof levels !== 'boolean')) return false;
    const ability = this.ability;
    const methods = this.methods;
    if (this.engine !== engine || SpeechPlugin.currentPlugin !== this || ability === null || methods === null || !this.onScreen()) return false;
    if (this.request !== null) this.request.active = false;
    const request = new SpeechOpenRequest(engine, ability); request.call = forCall === true; this.request = request;
    const previous = SpeechPlugin.physicalOwner ?? this.owner;
    if (previous !== null) {
      try { await previous.plugin.closeOwner(previous); } catch (_) { return false; }
    }
    if (!this.requestCurrent(request)) return false;
    const owner = new SpeechStreamOwner(id, engine, ability, methods, this); owner.call = forCall === true; this.owner = owner;
    try {
      if (!await OhosSpeechPlayback.claim(owner) || !this.requestCurrent(request) || !owner.active) {
        await OhosSpeechPlayback.release(owner); return false;
      }
    } catch (_) { return false; }
    SpeechPlugin.physicalOwner = owner;
    const options: PcmStreamOptions = { rate: rate, call: forCall === true, levels: levels === true, speaker: this.calls?.speaker ?? true };
    const listener: PcmStreamListener = {
      started: (): void => {
        if (!this.current(owner) || owner.started) return;
        owner.started = true; this.syncCallPlaying(); this.emit(owner, 'start');
      },
      level: (value: number): void => this.emitLevel(owner, value),
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
    const calls: OhosSpeechCall | null = this.calls;
    if (call.method === 'callStart') {
      const generation: number = ++this.callGeneration;
      const ability: AbilityPluginBinding | null = this.ability;
      if (!calls || !ability || !this.onScreen()) return 'unavailable';
      const pause: Any = call.argument('pause');
      const request: SpeechCallStart = new SpeechCallStart(call.argument('muted') === true,
        typeof pause === 'string' ? pause : 'normal');
      this.callStartRequest = request; this.externalPlaying = false;
      try {
        try { await this.stopCallPlayback(); } catch (_) { return 'unavailable'; }
        if (generation !== this.callGeneration || this.ability !== ability || !this.onScreen()) return 'unavailable';
        const outcome: string = await calls.start(ability.getAbility().context, call.argument('bargeIn') !== false,
          request.pause, (): boolean => request.muted, (): string => request.pause);
        if (generation !== this.callGeneration) return 'unavailable';
        this.syncCallPlaying(); return outcome;
      } finally {
        // A retired request may settle after the following call has begun.
        if (this.callStartRequest === request) this.callStartRequest = null;
      }
    }
    if (call.method === 'callStop') {
      this.callGeneration++; this.callStartRequest = null; this.externalPlaying = false;
      try { await calls?.stop(); } finally { await this.stopCallPlayback(); }
      return null;
    }
    if (call.method === 'callMute') {
      const on: boolean = call.argument('on') === true;
      if (this.callStartRequest) this.callStartRequest.muted = on;
      calls?.mute(on); return null;
    }
    if (call.method === 'callBargeIn') { calls?.bargeIn(call.argument('on') !== false); return null; }
    if (call.method === 'callPause') {
      const pause: Any = call.argument('pause');
      const value: string = typeof pause === 'string' ? pause : 'normal';
      if (this.callStartRequest) this.callStartRequest.pause = value;
      calls?.pause(value); return null;
    }
    if (call.method === 'callPlaying') { this.externalPlaying = call.argument('on') === true; this.syncCallPlaying(); return null; }
    if (call.method === 'callSpeaker') return calls ? await calls.setSpeaker(call.argument('on') !== false) : false;
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
