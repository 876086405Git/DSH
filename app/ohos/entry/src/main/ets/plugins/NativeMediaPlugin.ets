// Audio stage of dsh/native-media. Voice/overlay are not advertised until their
// visible-stop UI and shared dictation microphone arbiter are integrated.
import UIAbility from '@ohos.app.ability.UIAbility';
import common from '@ohos.app.ability.common';
import {
  AbilityAware, AbilityPluginBinding, Any, EventChannel, EventSink, FlutterPlugin,
  FlutterPluginBinding, MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { NativeMediaError, NativeMediaKey, nativeClipRelative } from './NativeMediaPolicy';
import { NativeClipOpener, OhosClipPlayer } from './OhosClipPlayer';

class MediaOwner {
  readonly key: NativeMediaKey;
  readonly engine: FlutterPluginBinding;
  readonly ability: AbilityPluginBinding;
  readonly context: common.Context;
  readonly sink: EventSink;
  active: boolean = true;
  busy: boolean = false;
  audioGeneration: number = 0;
  player: OhosClipPlayer | null = null;
  constructor(key: NativeMediaKey, engine: FlutterPluginBinding, ability: AbilityPluginBinding, sink: EventSink) {
    this.key = key; this.engine = engine; this.ability = ability; this.sink = sink;
    // Fixed path_provider 2.1.6-ohos.2 switches to this same UIAbility context
    // on attach, and its getTemporaryDirectory returns that context.cacheDir.
    this.context = ability.getAbility().context;
  }
}
const foregroundMediaAbilities: WeakSet<UIAbility> = new WeakSet();
const mediaPlugins: Set<NativeMediaPlugin> = new Set();

export default class NativeMediaPlugin implements FlutterPlugin, AbilityAware {
  private readonly opener: NativeClipOpener;
  private engine: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private methods: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private owner: MediaOwner | null = null;
  private activating: boolean = false;

  constructor(opener: NativeClipOpener) { this.opener = opener; }
  getUniqueClassName(): string { return 'DshNativeMediaPlugin'; }
  static onForeground(ability: UIAbility): void { foregroundMediaAbilities.add(ability); }
  static onBackground(ability: UIAbility): void {
    foregroundMediaAbilities.delete(ability);
    mediaPlugins.forEach((plugin: NativeMediaPlugin): void => {
      if (plugin.ability?.getAbility() === ability) plugin.retire('background');
    });
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.retire('detached'); this.methods?.setMethodCallHandler(null);
    this.engine = binding; this.ability = null; this.sink = null;
    mediaPlugins.add(this);
    const messenger = binding.getBinaryMessenger();
    this.methods = new MethodChannel(messenger, 'dsh/native-media');
    this.events = new EventChannel(messenger, 'dsh/native-media/events');
    this.methods.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (!['capabilities', 'activate', 'play', 'pause', 'resume', 'stop', 'disposeOwner',
        'requestVoiceGrant', 'startVoice', 'stopVoice', 'showOverlay', 'updateOverlay', 'hideOverlay'].includes(call.method)) {
        try { result.notImplemented(); } catch (_) {} return;
      }
      this.handle(call, binding).then((value: Any): void => { try { result.success(value); } catch (_) {} },
        (error: Error): void => {
          const failure = error instanceof NativeMediaError ? error : new NativeMediaError('audio', '音频操作未完成。');
          try { result.error(failure.code, failure.message, null); } catch (_) {}
        });
    } });
    this.events.setStreamHandler({
      onListen: (_args: Any, sink: EventSink): void => {
        if (this.engine !== binding) return;
        if (this.sink !== null && this.sink !== sink) this.retire('stream');
        this.sink = sink;
      },
      onCancel: (_args: Any): void => { if (this.engine === binding) { this.sink = null; this.retire('stream'); } }
    });
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engine !== binding) return;
    this.retire('detached'); this.methods?.setMethodCallHandler(null);
    binding.getBinaryMessenger().setMessageHandler('dsh/native-media/events', null);
    mediaPlugins.delete(this); this.sink = null; this.engine = null; this.ability = null;
    this.methods = null; this.events = null;
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability !== null && this.ability !== binding) this.retire('detached'); this.ability = binding;
  }
  onDetachedFromAbility(): void { this.retire('detached'); this.ability = null; }

  private onScreen(): boolean { return this.ability !== null && foregroundMediaAbilities.has(this.ability.getAbility()); }
  private current(owner: MediaOwner): boolean {
    return this.owner === owner && owner.active && this.engine === owner.engine && this.ability === owner.ability &&
      this.sink === owner.sink && this.onScreen();
  }
  private assertCurrent(owner: MediaOwner): void {
    if (!this.current(owner)) throw new NativeMediaError('stale-owner', '媒体操作的所有者已失效。');
  }
  private notice(owner: MediaOwner, kind: string, reason: string = ''): void {
    if (this.engine !== owner.engine || this.owner !== owner || this.sink !== owner.sink) return;
    const event: Map<string, Any> = new Map<string, Any>();
    event.set('owner', owner.key.owner); event.set('generation', owner.key.generation); event.set('lease', owner.key.lease);
    event.set('kind', kind); if (reason.length > 0) event.set('reason', reason);
    try { this.sink?.success(event); } catch (_) {}
  }
  private closeError(owner: MediaOwner): void {
    owner.active = false;
    if (this.engine !== owner.engine || this.owner !== owner || this.sink !== owner.sink) return;
    // A stream failure makes Dart request disposal; no terminal event claims the
    // resource/file is closed when AVPlayer.release or fs.close failed.
    try { this.sink?.error('close', '音频资源尚未确认关闭。', null); } catch (_) {}
  }
  private retire(reason: string): void {
    const owner = this.owner;
    if (owner === null) return;
    owner.active = false;
    this.closeOwner(owner).then((): void => {
      this.notice(owner, 'owner.revoked', reason);
      if (this.owner === owner) this.owner = null;
    }, (): void => this.closeError(owner));
  }
  private async closeOwner(owner: MediaOwner): Promise<void> {
    owner.active = false; owner.audioGeneration++;
    if (owner.player !== null) {
      const player = owner.player;
      try { await player.stop(); }
      catch (_) { throw new NativeMediaError('close', '音频资源尚未确认关闭。'); }
      if (owner.player === player) owner.player = null;
    }
  }

  private async handle(call: MethodCall, binding: FlutterPluginBinding): Promise<Any> {
    if (this.engine !== binding) throw new NativeMediaError('stale-owner', '媒体通道已关闭。');
    if (call.method === 'capabilities') {
      const value: Map<string, Any> = new Map<string, Any>();
      value.set('features', canIUse('SystemCapability.Multimedia.Media.AVPlayer') ? ['audio'] : []); return value;
    }
    if (call.method === 'activate') {
      const key = NativeMediaKey.parse(call);
      const ability = this.ability;
      const sink = this.sink;
      if (ability === null || !this.onScreen()) throw new NativeMediaError('not-foreground', '请先回到应用窗口。');
      if (sink === null) throw new NativeMediaError('stale-owner', '媒体事件通道已经关闭。');
      if (this.activating) throw new NativeMediaError('busy', '上一项媒体授权尚未关闭。');
      this.activating = true;
      try {
        if (this.owner !== null) await this.closeOwner(this.owner);
        if (this.engine !== binding || this.ability !== ability || this.sink !== sink || !this.onScreen()) throw new NativeMediaError('stale-owner', '媒体操作已取消。');
        this.owner = new MediaOwner(key, binding, ability, sink); return null;
      } finally { this.activating = false; }
    }
    const owner = this.owner;
    if (owner === null || !owner.key.matches(call)) {
      if (call.method === 'disposeOwner') return null;
      throw new NativeMediaError('stale-owner', '不是当前媒体操作的所有者。');
    }
    if (call.method === 'disposeOwner') {
      await this.closeOwner(owner); if (this.owner === owner) this.owner = null; return null;
    }
    if (call.method === 'stop') {
      // Stop is also a retry path for a previous close failure of this exact owner.
      owner.audioGeneration++;
      if (owner.player !== null) {
        const player = owner.player;
        try { await player.stop(); } catch (_) { throw new NativeMediaError('close', '音频资源尚未确认关闭。'); }
        if (owner.player === player) owner.player = null;
      }
      return null;
    }
    this.assertCurrent(owner);
    if (['requestVoiceGrant', 'startVoice', 'stopVoice', 'showOverlay', 'updateOverlay', 'hideOverlay'].includes(call.method)) {
      throw new NativeMediaError('unsupported', '此媒体通道尚未启用语音活动检测或原生字幕。');
    }
    if (owner.busy) throw new NativeMediaError('busy', '上一项播放器操作尚未完成。');
    owner.busy = true;
    try {
      if (call.method === 'play') {
        const generation = ++owner.audioGeneration;
        if (!canIUse('SystemCapability.Multimedia.Media.AVPlayer')) throw new NativeMediaError('unsupported', '当前设备不支持音频播放。');
        const relative = nativeClipRelative(owner.context.cacheDir, owner.key, call.argument('privatePath'), call.argument('contentType'));
        if (owner.player !== null) await owner.player.stop();
        this.assertCurrent(owner);
        if (owner.audioGeneration !== generation) throw new NativeMediaError('stale-owner', '音频请求已被停止。');
        const player: OhosClipPlayer = new OhosClipPlayer(this.opener,
          (): boolean => this.current(owner) && owner.audioGeneration === generation,
          (kind: string, reason: string): void => {
            if (this.current(owner) && owner.player === player) this.notice(owner, kind, reason);
          }, (): void => { if (this.owner === owner && owner.player === player) this.closeError(owner); });
        owner.player = player;
        await player.start(owner.context.cacheDir, relative);
        this.assertCurrent(owner);
        return null;
      }
      if (owner.player === null) throw new NativeMediaError('audio', '没有当前音频片段。');
      await owner.player.setPlaying(call.method === 'resume');
      this.assertCurrent(owner); return null;
    } finally { owner.busy = false; }
  }
}
