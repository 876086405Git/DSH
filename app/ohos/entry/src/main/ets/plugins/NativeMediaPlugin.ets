// Native media: voice remains unadvertised until the application injects its
// real visible-stop indicator. Overlay is independent and still unsupported.
import UIAbility from '@ohos.app.ability.UIAbility';
import common from '@ohos.app.ability.common';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import {
  AbilityAware, AbilityPluginBinding, Any, EventChannel, EventSink, FlutterPlugin,
  FlutterPluginBinding, MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { NativeMediaError, NativeMediaKey, NativeVoiceIndicator, nativeClipRelative } from './NativeMediaPolicy';
import { NativeClipOpener, OhosClipPlayer } from './OhosClipPlayer';
import { VoiceMicLease, VoiceMicToken } from './VoiceMicLease';
import { OhosSpeechActivity } from './OhosSpeechActivity';

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
  voiceGeneration: number = 0;
  voiceGranted: boolean = false;
  voice: OhosSpeechActivity | null = null;
  voiceMic: VoiceMicToken | null = null;
  voiceOpening: Promise<void> | null = null;
  voiceClosing: Promise<void> | null = null;
  voiceDraining: boolean = false;
  voiceEdges: boolean[] = [];
  voiceAnnounced: boolean = false;
  indicatorRequested: boolean = false;
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
  private readonly indicator?: NativeVoiceIndicator;
  private engine: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private methods: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private owner: MediaOwner | null = null;
  private activating: boolean = false;

  constructor(opener: NativeClipOpener, indicator?: NativeVoiceIndicator) { this.opener = opener; this.indicator = indicator; }
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
  private notice(owner: MediaOwner, kind: string, reason: string = '', localStopped: boolean = false): void {
    if (this.engine !== owner.engine || this.owner !== owner || this.sink !== owner.sink) return;
    const event: Map<string, Any> = new Map<string, Any>();
    event.set('owner', owner.key.owner); event.set('generation', owner.key.generation); event.set('lease', owner.key.lease);
    event.set('kind', kind); if (reason.length > 0) event.set('reason', reason);
    if (localStopped) event.set('localStopped', true);
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
    let failed = false;
    // Start both retirements before awaiting either one: a pending indicator or
    // capturer allocation must never keep the owner's clip playing in background.
    const voiceClosed = this.stopVoice(owner).catch((): void => { failed = true; });
    const player = owner.player;
    const audioClosed: Promise<void> = player === null ? Promise.resolve() : player.stop().then((): void => {
      if (owner.player === player) owner.player = null;
    }, (): void => { failed = true; });
    await voiceClosed; await audioClosed;
    if (failed) throw new NativeMediaError('close', '媒体资源尚未确认关闭。');
  }

  private async grantVoice(owner: MediaOwner): Promise<boolean> {
    this.assertCurrent(owner);
    if (VoiceMicLease.permissionOpen) throw new NativeMediaError('busy', '麦克风权限窗口尚未关闭。');
    VoiceMicLease.permissionOpen = true;
    try {
      const context = owner.ability.getAbility().context;
      const manager = abilityAccessCtrl.createAtManager();
      const allowed = await manager.checkAccessToken(context.applicationInfo.accessTokenId, 'ohos.permission.MICROPHONE');
      this.assertCurrent(owner);
      if (allowed === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) { owner.voiceGranted = true; return true; }
      const answer = await manager.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
      this.assertCurrent(owner); owner.voiceGranted = answer.authResults[0] === 0; return owner.voiceGranted;
    } catch (error) {
      if (error instanceof NativeMediaError) throw error as Error;
      throw new NativeMediaError('permission', '无法确认麦克风权限。');
    } finally { VoiceMicLease.permissionOpen = false; }
  }
  private voiceCurrent(owner: MediaOwner, generation: number): boolean {
    return this.current(owner) && owner.voiceGeneration === generation;
  }
  private async startVoice(owner: MediaOwner): Promise<void> {
    this.assertCurrent(owner);
    if (!this.indicator) throw new NativeMediaError('indicator', '主线应用尚未接入可见的停止控件。');
    if (!owner.voiceGranted) throw new NativeMediaError('permission', '请先允许使用麦克风。');
    if (owner.voice || owner.voiceOpening || owner.voiceClosing) throw new NativeMediaError('busy', '上一语音活动检测尚未关闭。');
    const generation = ++owner.voiceGeneration;
    const work = this.openVoice(owner, generation); owner.voiceOpening = work;
    try { await work; }
    catch (error) {
      try { await this.stopVoice(owner); } catch (_) { throw new NativeMediaError('close', '麦克风尚未确认释放。'); }
      if (error instanceof NativeMediaError) throw error as Error;
      throw new NativeMediaError('capture', '语音活动采集未能启动。');
    } finally { if (owner.voiceOpening === work) owner.voiceOpening = null; }
  }
  private async openVoice(owner: MediaOwner, generation: number): Promise<void> {
    if (!canIUse('SystemCapability.Multimedia.Audio.Capturer')) throw new NativeMediaError('capture', '当前设备不支持音频采集。');
    const context = owner.ability.getAbility().context;
    const grant = await abilityAccessCtrl.createAtManager().checkAccessToken(context.applicationInfo.accessTokenId, 'ohos.permission.MICROPHONE');
    if (!this.voiceCurrent(owner, generation)) throw new NativeMediaError('stale-owner', '语音活动检测已退役。');
    if (grant !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) throw new NativeMediaError('permission', '麦克风权限已关闭。');
    const token = new VoiceMicToken('plugin', async (): Promise<void> => {
      await this.closeOwner(owner); this.notice(owner, 'owner.revoked', 'dictation');
      if (this.owner === owner) this.owner = null;
    });
    if (!VoiceMicLease.plugin(token)) throw new NativeMediaError('busy', '听写正在使用麦克风。');
    owner.voiceMic = token;
    const indicator = this.indicator;
    if (!indicator) throw new NativeMediaError('indicator', '没有可见的停止控件。');
    owner.indicatorRequested = true; // Attempt ownership, not proof that UI is visible.
    await indicator.show(owner.key, (): void => { if (this.owner === owner) this.retire('user'); });
    if (!this.voiceCurrent(owner, generation)) throw new NativeMediaError('stale-owner', '语音活动检测已退役。');
    const capture = new OhosSpeechActivity(
      (): boolean => this.voiceCurrent(owner, generation),
      (speaking: boolean): void => {
        if (!this.voiceCurrent(owner, generation)) return;
        if (owner.voiceEdges.length >= 2) { this.retire('capture'); return; }
        owner.voiceEdges.push(speaking); this.drainVoice(owner, generation).catch((): void => this.retire('capture'));
      }, (): void => {
        if (!this.voiceCurrent(owner, generation)) return;
        this.stopVoice(owner).then((): void => this.notice(owner, 'voice.error', 'capture'), (): void => this.closeError(owner));
      },
      (): void => { VoiceMicLease.release(token); if (owner.voiceMic === token) owner.voiceMic = null; });
    owner.voice = capture; capture.setPlaying(owner.player !== null);
    await capture.start();
    if (!this.voiceCurrent(owner, generation)) throw new NativeMediaError('stale-owner', '语音活动检测已退役。');
  }
  private async drainVoice(owner: MediaOwner, generation: number): Promise<void> {
    if (owner.voiceDraining) return; owner.voiceDraining = true;
    try {
      while (this.voiceCurrent(owner, generation) && owner.voiceEdges.length > 0) {
        const speaking = owner.voiceEdges.shift();
        if (speaking === owner.voiceAnnounced) continue;
        if (speaking) {
          owner.audioGeneration++;
          const player = owner.player;
          if (player) { await player.stop(); if (owner.player === player) owner.player = null; }
          if (!this.voiceCurrent(owner, generation)) return;
          owner.voice?.setPlaying(false); owner.voiceAnnounced = true;
          this.notice(owner, 'voice.speechStart', '', true);
        } else { owner.voiceAnnounced = false; this.notice(owner, 'voice.speechEnd'); }
      }
    } finally { owner.voiceDraining = false; }
  }
  private stopVoice(owner: MediaOwner): Promise<void> {
    owner.voiceGeneration++; owner.voiceGranted = false;
    if (owner.voiceClosing) return owner.voiceClosing;
    const work = this.closeVoice(owner); owner.voiceClosing = work;
    work.then((): void => { if (owner.voiceClosing === work) owner.voiceClosing = null; },
      (): void => { if (owner.voiceClosing === work) owner.voiceClosing = null; });
    return work;
  }
  private async closeVoice(owner: MediaOwner): Promise<void> {
    try { if (owner.voiceOpening) await owner.voiceOpening; } catch (_) {}
    if (owner.voice) {
      try { await owner.voice.stop(); } catch (_) { throw new NativeMediaError('close', '麦克风尚未确认释放。'); }
      owner.voice = null;
    }
    else if (owner.voiceMic) { VoiceMicLease.release(owner.voiceMic); owner.voiceMic = null; }
    owner.voiceEdges = []; owner.voiceAnnounced = false;
    if (owner.indicatorRequested && this.indicator) { await this.indicator.hide(owner.key); owner.indicatorRequested = false; }
  }

  private async handle(call: MethodCall, binding: FlutterPluginBinding): Promise<Any> {
    if (this.engine !== binding) throw new NativeMediaError('stale-owner', '媒体通道已关闭。');
    if (call.method === 'capabilities') {
      const value: Map<string, Any> = new Map<string, Any>();
      const features: string[] = canIUse('SystemCapability.Multimedia.Media.AVPlayer') ? ['audio'] : [];
      if (this.indicator && canIUse('SystemCapability.Multimedia.Audio.Capturer')) features.push('voice');
      value.set('features', features); return value;
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
    if (call.method === 'stopVoice') { await this.stopVoice(owner); return null; }
    if (call.method === 'stop') {
      owner.voice?.setPlaying(false);
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
    if (call.method === 'requestVoiceGrant') {
      // No system prompt for a microphone this build can't listen with.
      if (!this.indicator) throw new NativeMediaError('unsupported', '此媒体通道尚未启用语音活动检测。');
      return await this.grantVoice(owner);
    }
    if (call.method === 'startVoice') { await this.startVoice(owner); return null; }
    if (['showOverlay', 'updateOverlay', 'hideOverlay'].includes(call.method)) {
      throw new NativeMediaError('unsupported', '此媒体通道尚未启用原生字幕。');
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
            if (this.current(owner) && owner.player === player) { owner.voice?.setPlaying(false); this.notice(owner, kind, reason); }
          }, (): void => { if (this.owner === owner && owner.player === player) this.closeError(owner); });
        owner.player = player; owner.voice?.setPlaying(true);
        await player.start(owner.context.cacheDir, relative);
        this.assertCurrent(owner);
        return null;
      }
      if (owner.player === null) throw new NativeMediaError('audio', '没有当前音频片段。');
      await owner.player.setPlaying(call.method === 'resume');
      owner.voice?.setPlaying(call.method === 'resume');
      this.assertCurrent(owner); return null;
    } finally { owner.busy = false; }
  }
}
