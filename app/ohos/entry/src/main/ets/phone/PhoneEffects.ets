import type { systemShare } from '@kit.ShareKit';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import notificationManager from '@ohos.notificationManager';
import settings from '@ohos.settings';
import pasteboard from '@ohos.pasteboard';
import call from '@ohos.telephony.call';
import calendarManager from '@ohos.calendarManager';
import { loadShareKit } from '../plugins/HmsKits';
import { PhoneReminders, PhoneReminderDenied, PhoneReminderRefused } from './PhoneReminders';

export class PhoneEffectDenied extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

export interface PhoneEffectResult {
  status: string;
  effect: string;
  evidence: string;
  dispatched: boolean;
  code: string;
  message: string;
}

function outcome(status: string, dispatched: boolean, code: string, message: string,
  effect: string = 'none', evidence: string = 'unknown'): PhoneEffectResult {
  return { status, effect, evidence, dispatched, code, message };
}

function text(args: Map<string, Object>, key: string): string {
  const value = args.get(key);
  return typeof value === 'string' ? value.trim() : '';
}

function rawText(args: Map<string, Object>, key: string): string {
  const value = args.get(key);
  return typeof value === 'string' ? value : '';
}

function required(args: Map<string, Object>, key: string): string {
  const value = args.get(key);
  if (typeof value !== 'string' || value.trim() === '') throw new PhoneEffectDenied('invalid_arguments', `缺少 ${key}。`);
  return value;
}

function unsupported(message: string): never { throw new PhoneEffectDenied('unsupported', message); }

// Validate the calendar fields before Date parsing; Date.parse alone normalizes
// invalid days such as February 30. Local date-times use the phone's time zone.
function timestamp(value: string): number {
  const match = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?(Z|[+-]\d{2}:\d{2})?$/.exec(value);
  if (!match) throw new PhoneEffectDenied('invalid_arguments', '日程时间格式无效。');
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days: number[] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  const zone = match[8] || '';
  if (month < 1 || month > 12 || day < 1 || day > days[month - 1] ||
    Number(match[4]) > 23 || Number(match[5]) > 59 || Number(match[6] || '0') > 59 ||
    (zone.length > 1 && (Number(zone.substring(1, 3)) > 18 || Number(zone.substring(4)) > 59 ||
      (Number(zone.substring(1, 3)) === 18 && Number(zone.substring(4)) !== 0)))) {
    throw new PhoneEffectDenied('invalid_arguments', '日程时间超出范围。');
  }
  const result = Date.parse(value.replace(' ', 'T'));
  if (!Number.isFinite(result)) throw new PhoneEffectDenied('invalid_arguments', '日程时间无法解析。');
  return result;
}

// Bare dates are phone-local civil dates, never Date.parse's UTC date-only form.
function calendarTimestamp(value: string): number {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return timestamp(value);
  const result = timestamp(value + 'T00:00');
  const date = new Date(result);
  if (date.getFullYear() !== Number(value.substring(0, 4)) ||
    date.getMonth() + 1 !== Number(value.substring(5, 7)) || date.getDate() !== Number(value.substring(8, 10))) {
    throw new PhoneEffectDenied('invalid_arguments', '日程日期在手机时区中不存在。');
  }
  return result;
}

function localDayStart(value: number): number {
  const date = new Date(value);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

function nextLocalDay(value: number): number {
  const date = new Date(localDayStart(value));
  date.setDate(date.getDate() + 1);
  return date.getTime();
}

// The caller validates the Android-compatible schema, owns the Ability lifetime,
// and supplies a synchronous native permit check. This class never owns a queue,
// retries an effect, reads the clipboard, or interprets UI launch as completion.
export class PhoneEffects {
  private context: common.UIAbilityContext;
  private static notificationSequence: number = 0;
  constructor(context: common.UIAbilityContext) { this.context = context; }

  async execute(tool: string, args: Map<string, Object>, beforeEffect: () => void): Promise<PhoneEffectResult> {
    let dispatched = false;
    const dispatch = (): void => { beforeEffect(); dispatched = true; };
    try {
      if (tool === 'mcp__phone__open') {
        if (args.get('background') === true) unsupported('鸿蒙不支持后台屏打开。');
        const app = text(args, 'app');
        const url = text(args, 'url');
        if ((app === '') === (url === '')) throw new PhoneEffectDenied('invalid_arguments', 'app 和 url 必须恰好提供一个。');
        if (url !== '') {
          dispatch();
          await this.context.openLink(url);
        } else {
          if (!/^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$/.test(app)) unsupported('请提供应用包名；无法可靠解析应用显示名。');
          const want: Want = { bundleName: app, action: 'ohos.want.action.home', entities: ['entity.system.home'] };
          dispatch();
          await this.context.startAbility(want);
        }
        return outcome('succeeded', true, 'opened_ui', '已请求打开目标界面，未确认其中的操作完成。', 'opened_ui', 'opened_ui');
      }
      if (tool === 'mcp__phone__notify') {
        const title = required(args, 'title');
        const body = required(args, 'text');
        if (!await notificationManager.isNotificationEnabled()) throw new PhoneEffectDenied('permission_denied', '请先在系统中允许通知。');
        const slotType = notificationManager.SlotType.SERVICE_INFORMATION;
        const slot = await notificationManager.getSlot(slotType);
        if (slot && (slot.enabled === false || slot.notificationLevel === notificationManager.SlotLevel.LEVEL_NONE)) {
          throw new PhoneEffectDenied('permission_denied', '服务通知通道已关闭。');
        }
        PhoneEffects.notificationSequence = (PhoneEffects.notificationSequence % 2147483646) + 1;
        const request: notificationManager.NotificationRequest = {
          id: PhoneEffects.notificationSequence,
          label: `dsh-phone:${Date.now()}:${PhoneEffects.notificationSequence}`,
          notificationSlotType: slotType,
          content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
            normal: { title, text: body } }
        };
        // publish creates a missing slot itself; no pre-permit addSlot mutation.
        dispatch();
        await notificationManager.publish(request);
        return outcome('succeeded', true, 'notification_published', '通知已发布，未确认用户已看到。', 'notification_published');
      }
      if (tool === 'mcp__phone__clipboard') {
        if (args.get('get') === true) {
          if (args.has('set')) throw new PhoneEffectDenied('invalid_arguments', '不能同时读写剪贴板。');
          unsupported('鸿蒙手机工具不读取剪贴板。');
        }
        const value = args.get('set');
        if (typeof value !== 'string') throw new PhoneEffectDenied('invalid_arguments', '需要 set 字符串。');
        const data = pasteboard.createPlainTextData(value);
        const board = pasteboard.getSystemPasteboard();
        dispatch();
        await board.setData(data);
        return outcome('succeeded', true, 'clipboard_written', '文字已写入剪贴板。', 'clipboard_written');
      }
      if (tool === 'mcp__phone__handoff') unsupported('交还等待与继续必须由当前原生 owner 处理。');
      if (tool !== 'mcp__phone__intent') unsupported('未实现的手机工具。');
      const kind = required(args, 'kind').trim();
      if (kind === 'alarm' || kind === 'timer') {
        await PhoneReminders.schedule(this.context, args, dispatch);
        return outcome('succeeded', true, 'reminder_scheduled', '系统已接受提醒；到点将由系统提醒，不代表引擎任务会自动运行。', 'reminder_scheduled');
      } else if (kind === 'dial') {
        const number = required(args, 'number').trim();
        if (!/^\+?[0-9][0-9 ()-]{1,30}$/.test(number)) throw new PhoneEffectDenied('invalid_arguments', '电话号码格式无效，不支持服务码。');
        const phoneNumber = number.replace(/ /g, '');
        dispatch();
        await call.makeCall(this.context, phoneNumber);
      } else if (kind === 'share') {
        const content = required(args, 'text');
        if (text(args, 'app') !== '') unsupported('公开分享面板不能强制指定目标应用。');
        const kit = await loadShareKit();
        const data = kit.createData({ utd: 'general.plain-text', content });
        const controller = kit.createController(data);
        const options: systemShare.ShareControllerOptions = { selectionMode: kit.single, previewMode: kit.preview };
        dispatch();
        await controller.show(this.context, options);
      } else if (kind === 'calendar') {
        const title = required(args, 'title');
        const begin = required(args, 'begin').trim();
        const allDayValue: Object | undefined = args.get('all_day');
        const allDay = typeof allDayValue === 'boolean' ? allDayValue : /^\d{4}-\d{2}-\d{2}$/.test(begin);
        const beginTime = calendarTimestamp(begin);
        const endText = text(args, 'end');
        const exclusiveEnd = endText === '' ? (allDay ? nextLocalDay(beginTime) : beginTime + 3600000) : calendarTimestamp(endText);
        if (exclusiveEnd < beginTime) throw new PhoneEffectDenied('invalid_arguments', '日程结束早于开始。');
        if (allDay && exclusiveEnd === beginTime) {
          throw new PhoneEffectDenied('invalid_arguments', '全天日程结束必须晚于开始。');
        }
        // Calendar Kit expands an all-day endTime to 24:00 of its own date.
        // The wire end is exclusive: midnight therefore belongs to the previous day.
        // editEvent uses the phone time zone and does not accept Event.timeZone.
        const startTime = allDay ? localDayStart(beginTime) : beginTime;
        const endTime = allDay ? exclusiveEnd - 1 : exclusiveEnd;
        const event: calendarManager.Event = { type: calendarManager.EventType.NORMAL, title, startTime, endTime,
          isAllDay: allDay, description: rawText(args, 'description'), location: { location: rawText(args, 'location') } };
        const calendar = calendarManager.getCalendarManager(this.context);
        dispatch();
        const id = await calendar.editEvent(event);
        if (id < 0) return outcome('cancelled', true, 'user_cancelled', '用户取消了日程创建。');
        if (!(id > 0)) return outcome('unknown', true, 'unknown', '日程界面没有返回有效结果。');
      } else if (kind === 'settings') {
        const page = required(args, 'page').trim();
        if (page === 'mobile_network') {
          dispatch();
          settings.openMobileNetworkSettingsPage(this.context);
        } else if (page === 'display') {
          dispatch();
          settings.openDisplaySettingsPage(this.context);
        } else if (page === 'sound') {
          dispatch();
          settings.openSoundSettingsPage(this.context);
        } else if (page === 'nfc') {
          dispatch();
          settings.openNfcSettingsPage(this.context);
        } else if (page === 'app_notifications') {
          const app = required(args, 'app').trim();
          if (app !== this.context.abilityInfo.bundleName) unsupported('公开通知设置接口只支持本应用，不能替换目标应用。');
          dispatch();
          await notificationManager.openNotificationSettings(this.context);
        } else {
          unsupported('此设置页尚无已验证的同义公开系统映射。');
        }
      } else if (kind === 'navigate') {
        if (text(args, 'map') !== '') unsupported('公开导航选择器不能强制指定地图应用。');
        const lat = args.get('lat');
        const lng = args.get('lng');
        if (lat === undefined && lng === undefined) unsupported('纯文本目的地不能可靠转换成路线规划坐标。');
        if (typeof lat !== 'number' || typeof lng !== 'number' || !Number.isFinite(lat) || !Number.isFinite(lng) || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
          throw new PhoneEffectDenied('invalid_arguments', '需要有效的 GCJ-02 经纬度。');
        }
        const mode = text(args, 'mode') || 'drive';
        const modes: string[] = ['drive', 'walk', 'ride', 'transit'];
        const vehicleType = modes.indexOf(mode);
        if (vehicleType < 0) throw new PhoneEffectDenied('invalid_arguments', '出行方式无效。');
        const params: Record<string, Object> = { 'sceneType': 1, 'destinationLatitude': lat, 'destinationLongitude': lng,
          'destinationName': text(args, 'destination'), 'vehicleType': vehicleType };
        let panelError = false;
        const callback: common.AbilityStartCallback = { onError: (_code: number, _name: string, _message: string): void => { panelError = true; } };
        dispatch();
        await this.context.startAbilityByType('navigation', params, callback);
        if (panelError) return outcome('unknown', true, 'sdk_failed', '导航选择器没有确认打开。');
      } else {
        unsupported(`鸿蒙暂未实现 ${kind} 的同义公开系统事务。`);
      }
      return outcome('succeeded', true, 'opened_ui', '已打开系统界面，未确认目标事务完成。', 'opened_ui', 'opened_ui');
    } catch (error) {
      if (error instanceof PhoneReminderRefused) return outcome('failed', true, 'reminder_refused', error.message);
      if (dispatched) return outcome('unknown', true, 'sdk_failed', '系统调用未返回可靠结果；请确认实际状态，不要自动重试。');
      if (error instanceof PhoneEffectDenied || error instanceof PhoneReminderDenied) {
        const status = error.code === 'cancelled' ? 'cancelled' : error.code === 'deadline_expired' ? 'timed_out' : 'failed';
        return outcome(status, false, error.code, error.message);
      }
      return outcome('failed', false, 'preparation_failed', '系统动作准备失败，没有派发。');
    }
  }
}
