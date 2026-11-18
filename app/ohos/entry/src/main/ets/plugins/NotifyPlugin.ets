// 普通通知使用现有 title/text/fullText；锁屏内容隐藏由系统设置控制，待真机核实。
import notificationManager from '@ohos.notificationManager';
import commonEventManager from '@ohos.commonEventManager';
import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent';
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
const APPROVAL_ACTION = ACTION + '_APPROVAL';
const LABEL = 'dsh-chat:';
const LIVE_LABEL = LABEL + 'live';
const SLOT = notificationManager.SlotType.SERVICE_INFORMATION;
// requestEnableNotification's refusal, now or from an earlier dialog.
const REFUSED = 1600004;

interface NotifyRoute {
  sessionId: string;
  host: string;
  kind: string;
  eventId: string;
}

interface NotifyApproval {
  actionId: string;
  requestToken: number;
  group: string;
  key: string;
  sessionId: string;
  host: string;
  eventId: string;
  decision: string;
}

interface PendingApproval {
  action: NotifyApproval;
  request: notificationManager.NotificationRequest;
  openButton: notificationManager.NotificationActionButton;
  submitted: boolean;
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
  private actionSink?: EventSink;
  private actionEpoch: number = 0;
  private subscriber?: commonEventManager.CommonEventSubscriber;
  private subscriberEpoch: number = -1;
  private actionTask: Promise<void> = Promise.resolve();
  private approvals: Map<string, PendingApproval> = new Map<string, PendingApproval>();
  private bundleName: string = '';
  private abilityName: string = '';
  private generation: number = 0;
  private static pendingTap?: Map<string, Any>;
  private static receiver?: NotifyPlugin;
  private static launches: WeakSet<UIAbility> = new WeakSet<UIAbility>();
  private static queue: Promise<void> = Promise.resolve();
  private static tapQueue: Promise<void> = Promise.resolve();
  private static liveOwner?: NotifyPlugin;

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
      const mutate = ['show', 'cancel', 'cancelGroup', 'cancelAll', 'live'].includes(call.method);
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
        this.retireActions();
        this.actionSink = events;
      },
      onCancel: (_args: Any): void => { this.retireActions(); }
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.generation++;
    this.retireActions();
    // A pending publish records its owner before this queued cleanup runs.
    // An older engine must never cancel the replacement engine's live item.
    this.serial(async (): Promise<Any> => {
      if (NotifyPlugin.liveOwner === this) await this.clearLive();
      return null;
    }).catch((_error: Error) => { hilog.warn(0x3F00, 'DshNotify', '进度通知尚未撤销'); });
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
    }).catch((_error: Error) => { hilog.warn(0x3F00, 'DshNotify', '通知跳转校验未完成'); });
  }

  // A dynamic subscriber only works while this process and Dart listener live.
  // Retain the explicit open button for cold/frozen processes and failed replies.
  private retireActions(): void {
    this.actionEpoch++;
    this.actionSink = undefined;
    this.approvals.clear();
    this.actionTask = this.actionTask.then(() => this.unsubscribeActions()).catch((_error: Error) => {
      hilog.warn(0x3F00, 'DshNotify', '通知操作订阅尚未释放');
    });
  }

  private async unsubscribeActions(): Promise<void> {
    const subscriber = this.subscriber;
    if (!subscriber) return;
    await new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      commonEventManager.unsubscribe(subscriber, (error?: BusinessError): void => {
        if (error) reject(error); else resolve();
      });
    });
    this.subscriber = undefined;
    this.subscriberEpoch = -1;
  }

  private async enableActions(generation: number): Promise<boolean> {
    const epoch = this.actionEpoch;
    const current = (): boolean => this.generation === generation && this.actionEpoch === epoch && this.actionSink !== undefined;
    if (!current()) return false;
    this.actionTask = this.actionTask.then(async (): Promise<void> => {
      if (!current()) return;
      if (this.subscriber && this.subscriberEpoch === epoch) return;
      // A failed subscribe/unsubscribe keeps its one owned subscriber for retry.
      await this.unsubscribeActions();
      if (!current()) return;
      this.subscriber = await commonEventManager.createSubscriber({ events: [APPROVAL_ACTION], publisherBundleName: this.bundleName });
      if (!current()) { await this.unsubscribeActions(); return; }
      await commonEventManager.subscribeToEvent(this.subscriber, (data: commonEventManager.CommonEventData): void => {
        this.acceptAction(data, generation, epoch);
      });
      if (!current()) { await this.unsubscribeActions(); return; }
      this.subscriberEpoch = epoch;
    }).catch((_error: Error) => {
      hilog.warn(0x3F00, 'DshNotify', '通知操作订阅未就绪，保留打开入口');
    });
    await this.actionTask;
    return current() && this.subscriber !== undefined && this.subscriberEpoch === epoch;
  }

  private acceptAction(data: commonEventManager.CommonEventData, generation: number, epoch: number): void {
    if (data.event !== APPROVAL_ACTION || data.bundleName !== this.bundleName || !data.parameters) return;
    const payload: Any = data.parameters['dshNotifyActionPayload'];
    const signature: Any = data.parameters['dshNotifyActionMac'];
    const signer = this.signer;
    if (!signer || typeof payload !== 'string' || payload.length > 8192 || typeof signature !== 'string') return;
    this.serial(async (): Promise<Any> => {
      if (this.generation !== generation || this.actionEpoch !== epoch || !this.actionSink) return null;
      if (!await signer.verify(payload, signature)) return null;
      const action = JSON.parse(payload) as NotifyApproval;
      if (typeof action.group !== 'string' || typeof action.key !== 'string' ||
          (action.decision !== 'allowed-once' && action.decision !== 'rejected')) return null;
      const entry = this.approvals.get(await this.label(action.group, action.key));
      if (this.generation !== generation || this.actionEpoch !== epoch || !this.actionSink || !entry || entry.submitted ||
          entry.action.actionId !== action.actionId || entry.action.requestToken !== action.requestToken ||
          entry.action.host !== action.host || entry.action.sessionId !== action.sessionId || entry.action.eventId !== action.eventId) return null;
      entry.submitted = true;
      this.actionSink.success(new Map<string, Any>([
        ['group', action.group], ['key', action.key], ['host', action.host], ['sessionId', action.sessionId],
        ['eventId', action.eventId], ['decision', action.decision], ['actionId', action.actionId], ['requestToken', action.requestToken]
      ]));
      return null;
    }).catch((_error: Error) => { hilog.warn(0x3F00, 'DshNotify', '通知操作校验未完成'); });
  }

  private async approvalButton(action: NotifyApproval, title: string, signer: TapSigner): Promise<notificationManager.NotificationActionButton> {
    const payload = JSON.stringify(action);
    if (payload.length > 8192) throw new NotifyError('bad_args', '通知操作信息过长。');
    const signature = await signer.sign(payload);
    const agent = await wantAgent.getWantAgent({ wants: [{ bundleName: this.bundleName,
      action: APPROVAL_ACTION, uri: 'dsh-notification-action://' + signature,
      parameters: { dshNotifyActionPayload: payload, dshNotifyActionMac: signature } }], requestCode: 0,
      actionType: wantAgent.OperationType.SEND_COMMON_EVENT, actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG] });
    return { title: title, wantAgent: agent };
  }

  private async completeAction(call: MethodCall, generation: number): Promise<void> {
    this.ensureCurrent(generation);
    const label = await this.label(call.argument('group') as string, call.argument('key') as string);
    const entry = this.approvals.get(label);
    if (!entry || !entry.submitted || entry.action.actionId !== call.argument('actionId')) return;
    const result: Any = call.argument('result');
    if (!['handled', 'gone', 'failed'].includes(result as string)) throw new NotifyError('bad_args', '未知通知操作结果。');
    this.ensureCurrent(generation);
    this.approvals.delete(label);
    if (result === 'failed') {
      entry.request.actionButtons = [entry.openButton];
      entry.request.content = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: 'DSH Go', text: '未能完成审批，请打开应用处理。' }
      };
      await notificationManager.publish(entry.request);
    } else {
      await notificationManager.cancel(0, label);
    }
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

  private async openAgent(route: NotifyRoute, signer: TapSigner): Promise<WantAgent> {
    const payload = JSON.stringify(route);
    if (payload.length > 8192) throw new NotifyError('bad_args', '通知跳转信息过长。');
    const signature = await signer.sign(payload);
    return await wantAgent.getWantAgent({ wants: [{ bundleName: this.bundleName, abilityName: this.abilityName,
      action: ACTION, uri: 'dsh-notification://' + signature,
      parameters: { dshNotifyPayload: payload, dshNotifyMac: signature } }], requestCode: 0,
      actionType: wantAgent.OperationType.START_ABILITY, actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG] });
  }

  private async clearLive(): Promise<void> {
    // Query also finds a notification left by a prior process. Cancelling an
    // absent id is not assumed to succeed on the platform.
    const active = await notificationManager.getActiveNotifications();
    if (active.some((item: notificationManager.NotificationRequest): boolean => item.id === 0 && item.label === LIVE_LABEL)) {
      await notificationManager.cancel(0, LIVE_LABEL);
    }
    NotifyPlugin.liveOwner = undefined;
  }

  // This build has no Huawei LiveViewKit. Keep its ordinary fallback independent
  // of HMS types and report that capability separately from a system live view.
  private async showLive(call: MethodCall, generation: number): Promise<void> {
    const activity: Any = call.argument('activity');
    if (call.argument('enabled') !== true || activity === null || activity === undefined) {
      await this.clearLive(); return;
    }
    if (!(activity instanceof Map)) throw new NotifyError('bad_args', '进度通知缺少有效状态。');
    const data: Map<string, Any> = activity as Map<string, Any>;
    const kind: Any = data.get('kind');
    // ChatAlerts remains the sole owner of completion/error notifications.
    if (kind === 'done' || kind === 'failed') { await this.clearLive(); return; }
    if (kind !== 'running' && kind !== 'waiting') throw new NotifyError('bad_args', '进度通知状态无效。');
    const session: Any = data.get('sessionId');
    const host: Any = data.get('host');
    const text: Any = data.get('publicText');
    const eventId: Any = data.get('eventId') ?? '';
    if (typeof session !== 'string' || session.length === 0 || session.length > 200 ||
        typeof host !== 'string' || typeof text !== 'string' || text.length === 0 || typeof eventId !== 'string') {
      throw new NotifyError('bad_args', '进度通知缺少有效的会话或公开文字。');
    }
    const signer = this.signer;
    if (!signer) throw new NotifyError('ohos_detached', '通知通道已关闭。');
    if (this.bundleName === '' || this.abilityName === '') throw new NotifyError('no_ability', '请先打开应用窗口。');
    const permission = await this.permissions();
    if (!permission.enabled || !permission.slot) throw new NotifyError('permission', '系统未允许此类通知，请在通知设置中开启。');
    const route: NotifyRoute = { sessionId: session, host: host, kind: 'live', eventId: eventId };
    const agent = await this.openAgent(route, signer);
    const request: notificationManager.NotificationRequest = {
      id: 0, label: LIVE_LABEL, notificationSlotType: SLOT,
      tapDismissed: true, isAlertOnce: true, wantAgent: agent,
      content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: 'DSH Go', text: text } }
    };
    this.ensureCurrent(generation);
    await notificationManager.publish(request);
    NotifyPlugin.liveOwner = this;
    this.ensureCurrent(generation);
  }

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
    const label = await this.label(group, key);
    this.approvals.delete(label);
    const title = (call.argument('title') ?? 'DSH Go') as string;
    const text = (call.argument('text') ?? '') as string;
    const publicText = (call.argument('publicText') ?? '有新的会话提醒') as string;
    const fullText = (call.argument('fullText') ?? '') as string;
    if (typeof title !== 'string' || typeof text !== 'string' || typeof publicText !== 'string' || typeof fullText !== 'string') {
      throw new NotifyError('bad_args', '通知标题和正文必须是文字。');
    }
    // Public SDK content fields cannot be empty. Keep real nonempty content verbatim.
    const shownTitle = title || 'DSH Go';
    const shownText = text || publicText || '有新的会话提醒';
    let content: notificationManager.NotificationContent = {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: { title: shownTitle, text: shownText }
    };
    if (fullText !== '') content = {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_LONG_TEXT,
      longText: { title: shownTitle, text: shownText, longText: fullText,
        briefText: shownText, expandedTitle: shownTitle }
    };
    const permission = await this.permissions();
    if (!permission.enabled || !permission.slot) throw new NotifyError('permission', '系统未允许此类通知，请在通知设置中开启。');
    const agent = await this.openAgent(route, signer);
    const request: notificationManager.NotificationRequest = {
      id: 0, label: label, groupName: await this.group(group),
      notificationSlotType: SLOT, tapDismissed: true, isAlertOnce: true, wantAgent: agent,
      content: content
    };
    let pending: PendingApproval | undefined;
    const epoch = this.actionEpoch;
    if (call.argument('canApprove') === true) {
      const openButton: notificationManager.NotificationActionButton = { title: '打开应用处理', wantAgent: agent };
      request.actionButtons = [openButton];
      const token: Any = call.argument('requestToken');
      if (typeof token === 'number' && Number.isSafeInteger(token) && token > 0 && route.eventId !== '' && await this.enableActions(generation)) {
        try {
          const action: NotifyApproval = { actionId: util.generateRandomUUID(), requestToken: token,
            group: group, key: key, sessionId: route.sessionId, host: route.host, eventId: route.eventId, decision: 'rejected' };
          const reject = await this.approvalButton(action, '拒绝', signer);
          action.decision = 'allowed-once';
          const allow = await this.approvalButton(action, '允许本次', signer);
          if (this.actionEpoch === epoch && this.actionSink) {
            request.actionButtons = [reject, allow, openButton];
            pending = { action: action, request: request, openButton: openButton, submitted: false };
          }
        } catch (_error) {
          hilog.warn(0x3F00, 'DshNotify', '通知审批按钮不可用，保留打开入口');
        }
      }
    }
    this.ensureCurrent(generation);
    await notificationManager.publish(request);
    if (pending && this.generation === generation && this.actionEpoch === epoch && this.actionSink) this.approvals.set(label, pending);
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
        this.approvals.delete(label);
        await notificationManager.cancel(0, label); return null;
      }
      case 'cancelGroup': {
        const value = call.argument('group') as string;
        const group = await this.group(value);
        this.ensureCurrent(generation);
        this.approvals.forEach((entry: PendingApproval, label: string): void => {
          if (entry.action.group === value) this.approvals.delete(label);
        });
        await notificationManager.cancelGroup(group); return null;
      }
      case 'cancelAll': {
        this.approvals.clear();
        const active = await notificationManager.getActiveNotifications();
        for (const item of active) if (item.id === 0 && item.label?.startsWith(LABEL)) {
          this.ensureCurrent(generation);
          await notificationManager.cancel(0, item.label);
          if (item.label === LIVE_LABEL) NotifyPlugin.liveOwner = undefined;
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
      case 'liveStatus': {
        const permission = await this.permissions();
        return new Map<string, Any>([['supported', false], ['allowed', false], ['settings', true], ['xiaomiFocus', false],
          ['ordinaryFallback', true], ['ordinaryAllowed', permission.enabled && permission.slot], ['backend', 'ordinary']]);
      }
      case 'live': await this.showLive(call, generation); return null;
      case 'actionResult': return await this.serial(async (): Promise<Any> => { await this.completeAction(call, generation); return null; });
      default: return null;
    }
  }
}
