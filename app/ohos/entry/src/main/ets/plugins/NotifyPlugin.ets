// 未编译、未在真机核实。普通通知只发送publicText；实况窗和通知内直接审批明确不支持。
import notificationManager from '@ohos.notificationManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import preferences from '@ohos.data.preferences';
import cryptoFramework from '@ohos.security.cryptoFramework';
import util from '@ohos.util';
import hilog from '@ohos.hilog';
import {
  AbilityAware, AbilityPluginBinding, Any, EventChannel, EventSink, FlutterPlugin,
  FlutterPluginBinding, MethodCall, MethodChannel, MethodResult, NewWantListener
} from '@ohos/flutter_ohos';

const ACTION = 'io.github.ccch1mneyyy.dsh_app.NOTIFICATION';
const LABEL = 'dsh-chat:';
const SLOT = notificationManager.SlotType.SERVICE_INFORMATION;
// requestEnableNotification's refusal, now or from an earlier dialog.
const REFUSED = 1600004;

interface NotifyRoute {
  sessionId: string;
  host: string;
  kind: string;
  eventId: string;
}

interface NotifyPermission { enabled: boolean; slot: boolean; }

class NotifyError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes).map((value: number) => value.toString(16).padStart(2, '0')).join('');
}

async function digest(text: string): Promise<string> {
  const md = cryptoFramework.createMd('SHA256');
  await md.update({ data: new util.TextEncoder().encodeInto(text) });
  return hex((await md.digest()).data);
}

// The public EntryAbility accepts external Wants. Only a route signed by this
// installation may enter the notification-tap stream; it never approves a tool.
class TapSigner {
  private context: common.Context;
  private static key?: Promise<cryptoFramework.SymKey>;

  constructor(context: common.Context) { this.context = context; }

  private async loadKey(): Promise<cryptoFramework.SymKey> {
    const store = await preferences.getPreferences(this.context, { name: 'dsh-notify' });
    const saved = await store.get('hmacKey', '') as string;
    const generator = cryptoFramework.createSymKeyGenerator('HMAC|SHA256');
    if (saved === '') {
      const key = await generator.generateSymKey();
      await store.put('hmacKey', hex(key.getEncoded().data));
      await store.flush();
      return key;
    }
    if (!/^[0-9a-f]{64}$/.test(saved)) throw new NotifyError('ohos_notify_storage', '通知凭据不可用，请重新打开应用。');
    // A failed flush may have left a value in the Preferences memory cache.
    await store.flush();
    const bytes = new Uint8Array(32);
    for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(saved.substring(i * 2, i * 2 + 2), 16);
    return await generator.convertKey({ data: bytes });
  }

  async sign(text: string): Promise<string> {
    if (!TapSigner.key) {
      TapSigner.key = this.loadKey().catch((error: Error) => { TapSigner.key = undefined; throw error; });
    }
    const mac = cryptoFramework.createMac('SHA256');
    await mac.init(await TapSigner.key);
    await mac.update({ data: new util.TextEncoder().encodeInto(text) });
    return hex((await mac.doFinal()).data);
  }

  async verify(text: string, signature: string): Promise<boolean> {
    if (!/^[0-9a-f]{64}$/.test(signature)) return false;
    const expected = await this.sign(text);
    let difference = 0;
    for (let i = 0; i < expected.length; i++) difference |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
    return difference === 0;
  }
}

export default class NotifyPlugin implements FlutterPlugin, AbilityAware, NewWantListener {
  private context?: common.Context;
  private signer?: TapSigner;
  private ability?: AbilityPluginBinding;
  private methods?: MethodChannel;
  private taps?: EventChannel;
  private actions?: EventChannel;
  private sink?: EventSink;
  private bundleName: string = '';
  private abilityName: string = '';
  private generation: number = 0;
  private static pendingTap?: Map<string, Any>;
  private static receiver?: NotifyPlugin;
  private static launches: WeakSet<UIAbility> = new WeakSet<UIAbility>();
  private static queue: Promise<void> = Promise.resolve();
  private static tapQueue: Promise<void> = Promise.resolve();

  getUniqueClassName(): string { return 'DshNotifyPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.signer = new TapSigner(this.context);
    const messenger = binding.getBinaryMessenger();
    this.methods = new MethodChannel(messenger, 'dsh/notify');
    this.taps = new EventChannel(messenger, 'dsh/notify/taps');
    this.actions = new EventChannel(messenger, 'dsh/notify/actions');
    this.methods.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (!['status', 'show', 'cancel', 'cancelGroup', 'cancelAll', 'requestPermission', 'openSettings', 'actionResult', 'live', 'liveStatus', 'openLiveSettings'].includes(call.method)) {
        result.notImplemented(); return;
      }
      const mutate = ['show', 'cancel', 'cancelGroup', 'cancelAll'].includes(call.method);
      const generation = this.generation;
      const work: Promise<Any> = mutate ? this.serial(() => this.handle(call, generation)) : this.handle(call, generation);
      work.then((value: Any) => result.success(value)).catch((error: Error) => {
        if (error instanceof NotifyError) result.error(error.code, error.message, null);
        else result.error('ohos_notify_failed', '系统通知操作未完成，请检查通知设置后重试。', null);
      });
    } });
    this.taps.setStreamHandler({
      onListen: (_args: Any, events: EventSink): void => {
        this.sink = events;
        NotifyPlugin.receiver = this;
        if (NotifyPlugin.pendingTap) {
          const tap: Map<string, Any> = NotifyPlugin.pendingTap; NotifyPlugin.pendingTap = undefined; events.success(tap);
        }
      },
      onCancel: (_args: Any): void => {
        this.sink = undefined;
        if (NotifyPlugin.receiver === this) NotifyPlugin.receiver = undefined;
      }
    });
    this.actions.setStreamHandler({
      onListen: (_args: Any, events: EventSink): void => {
        events.error('ohos_unsupported', '请点通知进入应用查看并确认操作。', null);
        events.endOfStream();
      },
      onCancel: (_args: Any): void => {}
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.generation++;
    this.onDetachedFromAbility();
    this.methods?.setMethodCallHandler(null);
    binding.getBinaryMessenger().setMessageHandler('dsh/notify/taps', null);
    binding.getBinaryMessenger().setMessageHandler('dsh/notify/actions', null);
    this.methods = undefined; this.taps = undefined; this.actions = undefined;
    this.sink = undefined; this.context = undefined; this.signer = undefined;
    if (NotifyPlugin.receiver === this) NotifyPlugin.receiver = undefined;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.ability = binding;
    const ability = binding.getAbility();
    this.bundleName = ability.context.abilityInfo.bundleName;
    this.abilityName = ability.context.abilityInfo.name;
    binding.addOnNewWantListener(this);
    if (!NotifyPlugin.launches.has(ability)) {
      NotifyPlugin.launches.add(ability); this.accept(ability.launchWant);
    }
  }

  onDetachedFromAbility(): void {
    this.ability?.removeOnNewWantListener(this); this.ability = undefined;
  }

  onNewWant(want: Want, _launch: AbilityConstant.LaunchParam): void {
    if (this.ability) this.accept(want);
  }

  private accept(want: Want): void {
    if (want.action !== ACTION || !want.parameters) return;
    const payload = want.parameters['dshNotifyPayload'];
    const signature = want.parameters['dshNotifyMac'];
    const signer = this.signer;
    if (!signer || typeof payload !== 'string' || payload.length > 8192 || typeof signature !== 'string') return;
    NotifyPlugin.tapQueue = NotifyPlugin.tapQueue.then(async (): Promise<void> => {
      const valid = await signer.verify(payload, signature);
      if (!valid) return;
      const route = JSON.parse(payload) as NotifyRoute;
      if (typeof route.sessionId !== 'string' || route.sessionId.length === 0 || route.sessionId.length > 200 ||
          typeof route.host !== 'string' || typeof route.kind !== 'string' || typeof route.eventId !== 'string') return;
      const tap: Map<string, Any> = new Map<string, Any>([['host', route.host], ['sessionId', route.sessionId], ['kind', route.kind]]);
      if (route.eventId !== '') tap.set('eventId', route.eventId);
      const sink = NotifyPlugin.receiver?.sink;
      if (sink) sink.success(tap); else NotifyPlugin.pendingTap = tap;
    }).catch((_error: Error) => { hilog.warn(0xD003F00, 'DshNotify', '通知跳转校验未完成'); });
  }

  private serial(work: () => Promise<Any>): Promise<Any> {
    const next: Promise<Any> = NotifyPlugin.queue.then(work);
    NotifyPlugin.queue = next.then(() => {}).catch((_error: Error) => {});
    return next;
  }

  private ensureCurrent(generation: number): void {
    if (!this.context || this.generation !== generation) throw new NotifyError('ohos_detached', '通知通道已关闭。');
  }

  private async permissions(): Promise<NotifyPermission> {
    const enabled = await notificationManager.isNotificationEnabled();
    if (!enabled) return { enabled: false, slot: false };
    let slot = await notificationManager.getSlot(SLOT);
    if (slot === null) {
      await notificationManager.addSlot(SLOT);
      slot = await notificationManager.getSlot(SLOT);
    }
    if (slot === null || typeof slot.enabled !== 'boolean') throw new NotifyError('ohos_notify_failed', '系统通知渠道状态未知，请重试。');
    return { enabled: enabled, slot: slot.enabled && slot.notificationLevel !== notificationManager.SlotLevel.LEVEL_NONE };
  }

  private async label(group: string, key: string): Promise<string> { return LABEL + await digest(JSON.stringify([group, key])); }
  private async group(group: string): Promise<string> { return LABEL + await digest(group); }

  private async show(call: MethodCall, generation: number): Promise<void> {
    const signer = this.signer;
    if (!signer) throw new NotifyError('ohos_detached', '通知通道已关闭。');
    if (this.bundleName === '' || this.abilityName === '') throw new NotifyError('no_ability', '请先打开应用窗口。');
    const group = call.argument('group') as string;
    const key = call.argument('key') as string;
    const route: NotifyRoute = { sessionId: call.argument('sessionId') as string,
      host: (call.argument('host') ?? '') as string, kind: (call.argument('kind') ?? '') as string,
      eventId: (call.argument('eventId') ?? '') as string };
    if (!group || !key || !route.sessionId || route.sessionId.length > 200) throw new NotifyError('bad_args', '通知缺少有效的会话标识。');
    const permission = await this.permissions();
    if (!permission.enabled || !permission.slot) throw new NotifyError('permission', '系统未允许此类通知，请在通知设置中开启。');
    const payload = JSON.stringify(route);
    if (payload.length > 8192) throw new NotifyError('bad_args', '通知跳转信息过长。');
    const signature = await signer.sign(payload);
    const agent = await wantAgent.getWantAgent({ wants: [{ bundleName: this.bundleName, abilityName: this.abilityName,
      action: ACTION, uri: 'dsh-notification://' + signature,
      parameters: { dshNotifyPayload: payload, dshNotifyMac: signature } }], requestCode: 0,
      actionType: wantAgent.OperationType.START_ABILITY, actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG] });
    const request: notificationManager.NotificationRequest = {
      id: 0, label: await this.label(group, key), groupName: await this.group(group),
      notificationSlotType: SLOT, tapDismissed: true, isAlertOnce: true, wantAgent: agent,
      content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: 'DSH Go', text: (call.argument('publicText') || '有新的会话提醒') as string } }
    };
    if (call.argument('canApprove') === true) request.actionButtons = [{ title: '打开应用处理', wantAgent: agent }];
    this.ensureCurrent(generation);
    await notificationManager.publish(request);
  }

  private async handle(call: MethodCall, generation: number): Promise<Any> {
    this.ensureCurrent(generation);
    switch (call.method) {
      case 'status': {
        const permission = await this.permissions();
        return new Map<string, Any>([['enabled', permission.enabled], ['done', permission.slot], ['attention', permission.slot]]);
      }
      case 'show': await this.show(call, generation); return null;
      case 'cancel': {
        const label = await this.label(call.argument('group') as string, call.argument('key') as string);
        this.ensureCurrent(generation);
        await notificationManager.cancel(0, label); return null;
      }
      case 'cancelGroup': {
        const group = await this.group(call.argument('group') as string);
        this.ensureCurrent(generation);
        await notificationManager.cancelGroup(group); return null;
      }
      case 'cancelAll': {
        const active = await notificationManager.getActiveNotifications();
        for (const item of active) if (item.id === 0 && item.label?.startsWith(LABEL)) {
          this.ensureCurrent(generation);
          await notificationManager.cancel(0, item.label);
        }
        return null;
      }
      case 'requestPermission': {
        if (!this.ability) throw new NotifyError('no_ability', '请先回到应用窗口再打开通知设置。');
        try {
          await notificationManager.requestEnableNotification(this.ability.getAbility().context);
        } catch (error) {
          // The dialog comes up once: after a refusal only openSettings can turn them on.
          if ((error as BusinessError).code === REFUSED) return false;
          throw error as Error;
        }
        return await notificationManager.isNotificationEnabled();
      }
      case 'openSettings': case 'openLiveSettings': {
        if (!this.ability) throw new NotifyError('no_ability', '请先回到应用窗口再打开通知设置。');
        // Answers when the panel closes, so whoever reads the status next reads what was chosen there.
        await notificationManager.openNotificationSettingsWithResult(this.ability.getAbility().context);
        return true;
      }
      case 'liveStatus': return new Map<string, Any>([['supported', false], ['allowed', false], ['settings', true], ['xiaomiFocus', false]]);
      case 'live':
        if (call.argument('enabled') === false || !call.argument('activity')) return null;
        throw new NotifyError('ohos_unsupported', '当前公开接口不允许普通应用自行创建实况窗，请在应用内查看进度；回复提醒仍可使用普通通知。');
      case 'actionResult': throw new NotifyError('ohos_unsupported', '通知不直接执行审批，请打开应用查看并确认。');
      default: return null;
    }
  }
}
