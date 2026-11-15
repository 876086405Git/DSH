// dsh/voice / dsh/voice/events，沿用实际 Dart VoiceBridge 的方法、字节和 sessionId。
// 录音只用公开 OH API；识别的 HMS 适配在单独文件，尚未用 HMS SDK / 真机核实。
import common from '@ohos.app.ability.common';
import UIAbility from '@ohos.app.ability.UIAbility';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import {
  AbilityAware, AbilityPluginBinding, Any, EventChannel, EventSink, FlutterPlugin,
  FlutterPluginBinding, MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { VoiceFailure, VoiceNotice, VoiceResource, retiredVoice } from './VoiceTypes';
import { OhosVoiceRecorder } from './OhosVoiceRecorder';
import { HmsVoiceRecognizer } from './HmsVoiceRecognizer';

const MICROPHONE = 'ohos.permission.MICROPHONE';

class VoiceLease {
  owner: VoicePlugin;
  engine: FlutterPluginBinding;
  ability: AbilityPluginBinding;
  sessionId: number;
  recorder: boolean;
  valid: boolean = true;
  resource?: VoiceResource;
  preparing?: Promise<void>;
  constructor(owner: VoicePlugin, engine: FlutterPluginBinding, ability: AbilityPluginBinding,
    sessionId: number, recorder: boolean) {
    this.owner = owner; this.engine = engine; this.ability = ability; this.sessionId = sessionId; this.recorder = recorder;
  }
}

export default class VoicePlugin implements FlutterPlugin, AbilityAware {
  private static owner?: VoicePlugin;
  private static physical?: VoiceLease;
  private static permissionOpen: boolean = false;
  private static foregroundAbilities: WeakSet<UIAbility> = new WeakSet<UIAbility>();
  private binding?: FlutterPluginBinding;
  private ability?: AbilityPluginBinding;
  private methods?: MethodChannel;
  private events?: EventChannel;
  private sink?: EventSink;
  private session?: VoiceLease;

  getUniqueClassName(): string { return 'DshVoicePlugin'; }

  // EntryAbility forwards real lifecycle callbacks. A stale Ability cannot retire another one.
  static onForeground(ability: UIAbility): void { VoicePlugin.foregroundAbilities.add(ability); }

  static onBackground(ability: UIAbility): void {
    VoicePlugin.foregroundAbilities.delete(ability);
    const owner = VoicePlugin.owner;
    if (owner?.ability?.getAbility() === ability) owner.cancel().catch((): void => {});
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (VoicePlugin.owner) VoicePlugin.owner.retire();
    VoicePlugin.owner = this; this.binding = binding; this.ability = undefined; this.sink = undefined;
    const messenger = binding.getBinaryMessenger();
    this.methods = new MethodChannel(messenger, 'dsh/voice');
    this.events = new EventChannel(messenger, 'dsh/voice/events');
    this.methods.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (!['capabilities', 'permission', 'requestPermission', 'openSettings', 'startRecognizer', 'startRecorder', 'stop', 'cancel'].includes(call.method)) {
        try { result.notImplemented(); } catch (_) {} return;
      }
      this.handle(call, binding).then((value: Any): void => {
        try { result.success(value); } catch (_) { /* retired transport; never send a second reply */ }
      }).catch((error: Error): void => {
        const failure = error instanceof VoiceFailure ? error : new VoiceFailure('audio', '语音操作未完成，请重试。', 100);
        const details: Map<string, Any> = new Map<string, Any>([['code', failure.voiceCode]]);
        try { result.error(failure.code, failure.message, details); } catch (_) {}
      });
    } });
    this.events.setStreamHandler({
      onListen: (_args: Any, sink: EventSink): void => {
        if (this.binding === binding && VoicePlugin.owner === this) this.sink = sink;
      },
      onCancel: (_args: Any): void => {
        if (this.binding === binding) { this.sink = undefined; this.cancel().catch((): void => {}); }
      }
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.binding !== binding) return;
    this.retire(); this.methods?.setMethodCallHandler(null);
    binding.getBinaryMessenger().setMessageHandler('dsh/voice/events', null);
    this.binding = undefined; this.ability = undefined; this.methods = undefined; this.events = undefined;
    if (VoicePlugin.owner === this) VoicePlugin.owner = undefined;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability && this.ability !== binding) this.cancel().catch((): void => {});
    this.ability = binding;
  }

  onDetachedFromAbility(): void {
    this.ability = undefined; this.cancel().catch((): void => {});
  }

  private retire(): void {
    this.sink = undefined; this.ability = undefined;
    this.cancel().then((): Promise<void> => HmsVoiceRecognizer.releaseIdle()).catch((): void => {});
  }

  private live(lease: VoiceLease): boolean {
    return lease.valid && VoicePlugin.owner === this && this.binding === lease.engine && this.ability === lease.ability &&
      VoicePlugin.foregroundAbilities.has(lease.ability.getAbility());
  }

  private deliver(lease: VoiceLease, notice: VoiceNotice): void {
    if (!this.live(lease)) return;
    const event: Map<string, Any> = new Map<string, Any>([['type', notice.type], ['sessionId', lease.sessionId]]);
    if (notice.text !== undefined) event.set('text', notice.text);
    if (notice.value !== undefined) event.set('value', notice.value);
    if (notice.code !== undefined) event.set('code', notice.code);
    try { this.sink?.success(event); } catch (_) {}
    if (notice.type === 'end') {
      lease.valid = false; if (this.session === lease) this.session = undefined;
    }
  }

  private released(lease: VoiceLease): void {
    if (VoicePlugin.physical === lease) VoicePlugin.physical = undefined;
  }

  private async cancelLease(lease: VoiceLease): Promise<void> {
    lease.valid = false;
    try { await lease.preparing; } catch (_) {}
    if (lease.resource) await lease.resource.cancel();
    else this.released(lease);
  }

  private async cancel(): Promise<void> {
    const lease = this.session ?? (VoicePlugin.physical?.owner === this || VoicePlugin.physical?.valid === false ? VoicePlugin.physical : undefined);
    this.session = undefined;
    if (lease) await this.cancelLease(lease);
  }

  private async permitted(context: common.UIAbilityContext): Promise<boolean> {
    const manager = abilityAccessCtrl.createAtManager();
    return await manager.checkAccessToken(context.applicationInfo.accessTokenId, MICROPHONE) === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  }

  private permissionCurrent(binding: FlutterPluginBinding | undefined, ability: AbilityPluginBinding,
    ui: UIAbility): boolean {
    return binding !== undefined && this.binding === binding && this.ability === ability &&
      ability.getAbility() === ui && VoicePlugin.owner === this && VoicePlugin.foregroundAbilities.has(ui);
  }

  private async permission(settings: boolean): Promise<string> {
    const ability = this.ability;
    if (!ability || !VoicePlugin.foregroundAbilities.has(ability.getAbility())) throw new VoiceFailure('no_ability', '请回到应用前台后重试。', 9);
    const binding = this.binding;
    const ui = ability.getAbility();
    if (VoicePlugin.permissionOpen) throw new VoiceFailure('busy', '麦克风权限窗口尚未关闭。', 8);
    VoicePlugin.permissionOpen = true;
    try {
      const context = ui.context;
      const granted = await this.permitted(context);
      // A checkAccessToken promise can finish after the same Ability went to the
      // background. Recheck the actual UI owner immediately before either API
      // that can present a permission window; engine identity alone is not enough.
      if (!this.permissionCurrent(binding, ability, ui)) return 'denied';
      if (granted) return 'granted';
      const manager = abilityAccessCtrl.createAtManager();
      if (settings) {
        await manager.requestPermissionOnSetting(context, [MICROPHONE]);
        if (!this.permissionCurrent(binding, ability, ui)) return 'denied';
        const allowed = await this.permitted(context);
        return this.permissionCurrent(binding, ability, ui) && allowed ? 'granted' : 'denied';
      }
      const result = await manager.requestPermissionsFromUser(context, [MICROPHONE]);
      if (!this.permissionCurrent(binding, ability, ui)) return 'denied';
      if (result.authResults[0] === 0) return 'granted';
      // Missing dialog metadata is not evidence of a permanent denial.
      return result.authResults[0] === -1 && result.dialogShownResults?.[0] === false ? 'blocked' : 'denied';
    } catch (error) {
      if (error instanceof VoiceFailure) throw error as Error;
      throw new VoiceFailure('permission', '无法打开麦克风权限设置，请在系统设置中检查授权。', 9);
    } finally { VoicePlugin.permissionOpen = false; }
  }

  private async begin(call: MethodCall, recorder: boolean): Promise<void> {
    const binding = this.binding; const ability = this.ability;
    if (!binding || !ability || !VoicePlugin.foregroundAbilities.has(ability.getAbility())) {
      throw new VoiceFailure('no_ability', '请回到应用前台后重试。', 5);
    }
    const id: Any = call.argument('sessionId');
    if (typeof id !== 'number' || !Number.isSafeInteger(id) || id <= 0) {
      throw new VoiceFailure('arguments', '缺少有效的语音会话编号。', 5);
    }
    let seconds = 60;
    if (recorder) {
      const max: Any = call.argument('maxSeconds');
      if (typeof max !== 'number' || !Number.isSafeInteger(max)) throw new VoiceFailure('arguments', '录音时长无效。', 100);
      seconds = Math.max(1, Math.min(600, max));
    } else {
      const language: Any = call.argument('language');
      if (language !== undefined && language !== null && language !== 'zh-CN') {
        throw new VoiceFailure('language', '系统语音识别仅支持中文普通话（zh-CN）。', 12);
      }
    }
    if (VoicePlugin.physical) throw new VoiceFailure('busy', '上一语音会话尚未释放麦克风。', 8);
    const previous = this.session;
    const lease = new VoiceLease(this, binding, ability, id, recorder);
    VoicePlugin.physical = lease; this.session = lease;
    lease.preparing = (async (): Promise<void> => {
      if (previous) await this.cancelLease(previous);
      if (!this.live(lease)) throw retiredVoice();
      if (!await this.permitted(ability.getAbility().context)) throw new VoiceFailure('permission', '请先允许使用麦克风。', 9);
      if (!this.live(lease)) throw retiredVoice();
      const emit = (notice: VoiceNotice): void => this.deliver(lease, notice);
      const current = (): boolean => this.live(lease);
      const released = (): void => this.released(lease);
      lease.resource = recorder ? new OhosVoiceRecorder(seconds, emit, current, released) : new HmsVoiceRecognizer(emit, current, released);
      await lease.resource.start();
    })();
    try { await lease.preparing; }
    catch (error) {
      try { await this.cancelLease(lease); } catch (_) {}
      if (this.session === lease) this.session = undefined;
      if (error instanceof VoiceFailure) throw error as Error;
      throw new VoiceFailure(recorder ? 'audio' : 'recognizer', '无法启动语音服务，请检查权限或稍后重试。', recorder ? 100 : 5);
    }
  }

  private async stop(): Promise<Uint8Array | null> {
    const lease = this.session;
    if (!lease || !this.live(lease)) return null;
    try { await lease.preparing; } catch (error) { throw error as Error; }
    if (!this.live(lease) || !lease.resource) return null;
    const value = await lease.resource.finish();
    if (lease.recorder) { lease.valid = false; if (this.session === lease) this.session = undefined; }
    return value;
  }

  private async handle(call: MethodCall, binding: FlutterPluginBinding): Promise<Any> {
    if (this.binding !== binding || VoicePlugin.owner !== this) throw retiredVoice();
    switch (call.method) {
      case 'capabilities': {
        const recognizer = await HmsVoiceRecognizer.available();
        if (this.binding !== binding || VoicePlugin.owner !== this) throw retiredVoice();
        const value: Map<string, Any> = new Map<string, Any>([
          ['recognizer', recognizer], ['recorder', canIUse('SystemCapability.Multimedia.Audio.Capturer')],
          ['systemUnreliable', HmsVoiceRecognizer.unreliable], ['environmentId', null],
          ['languages', ['zh-CN']], ['recognizerRegion', 'CN'], ['recognizerOffline', true]
        ]);
        return value;
      }
      case 'permission': return this.ability && await this.permitted(this.ability.getAbility().context) ? 'granted' : 'denied';
      case 'requestPermission': return await this.permission(false);
      case 'openSettings': await this.permission(true); return null;
      case 'startRecognizer': await this.begin(call, false); return null;
      case 'startRecorder': await this.begin(call, true); return null;
      case 'stop': return await this.stop();
      case 'cancel': await this.cancel(); return null;
      default: throw new VoiceFailure('ohos_unsupported', '此语音操作尚不支持。', 5);
    }
  }
}
