import common from '@ohos.app.ability.common';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import notificationManager from '@ohos.notificationManager';
import reminderAgentManager from '@ohos.reminderAgentManager';
import { BusinessError } from '@ohos.base';

export class PhoneReminderDenied extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

// The service said no: nothing was scheduled, so this is not an unknown outcome.
// 1700002 is also how a device without the agent-powered reminder entitlement can
// answer, and only the permit's holder can tell the two apart.
export class PhoneReminderRefused extends Error {
  constructor(message: string) { super(message); }
}

function refusal(code: number): string | null {
  if (code === 201) return '系统没有授予提醒权限；这个版本可能还没开通系统代理提醒。';
  if (code === 1700001) return '请先在系统中允许通知，再设置提醒。';
  if (code === 1700002) return '系统没有接受提醒：有效提醒已达上限，或这个版本还没开通系统代理提醒。';
  return null;
}

function integer(args: Map<string, Object>, key: string, low: number, high: number): number {
  const value: Object | undefined = args.get(key);
  if (typeof value !== 'number' || !Number.isInteger(value) || value < low || value > high) {
    throw new PhoneReminderDenied('invalid_arguments', `${key} 超出有效范围。`);
  }
  return value;
}

// Only publication is serialized: querying the app's valid reminders and choosing
// a notification ID must not race another phone reminder. No retries or timers.
export class PhoneReminders {
  private static tail: Promise<void> = Promise.resolve();
  private static nextNotificationId: number = 1500000000;

  static async schedule(context: common.UIAbilityContext, args: Map<string, Object>, dispatch: () => void): Promise<void> {
    const request = PhoneReminders.request(args);
    const previous = PhoneReminders.tail;
    const pending = previous.then(async (): Promise<void> => {
      if (!canIUse('SystemCapability.Notification.ReminderAgent')) {
        throw new PhoneReminderDenied('unsupported', '当前设备没有系统代理提醒能力。');
      }
      const access = abilityAccessCtrl.createAtManager();
      const grant = await access.checkAccessToken(context.applicationInfo.accessTokenId, 'ohos.permission.PUBLISH_AGENT_REMINDER');
      if (grant !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        throw new PhoneReminderDenied('permission_denied', '系统提醒权限尚未授予；请检查应用签名和提醒权限。');
      }
      if (!await notificationManager.isNotificationEnabled()) {
        throw new PhoneReminderDenied('permission_denied', '请先在系统中允许通知，再设置提醒。');
      }
      const slot = await notificationManager.getSlot(notificationManager.SlotType.SERVICE_INFORMATION);
      if (slot && (slot.enabled === false || slot.notificationLevel === notificationManager.SlotLevel.LEVEL_NONE)) {
        throw new PhoneReminderDenied('permission_denied', '服务通知通道已关闭，不能设置提醒。');
      }
      // Existing IDs survive an Ability/process restart. Never overwrite or cancel
      // another valid reminder, including those created outside this phone tool.
      const existing = await reminderAgentManager.getAllValidReminders();
      const used = new Set<number>();
      existing.forEach((item: reminderAgentManager.ReminderInfo): void => {
        const id = item.reminderReq.notificationId;
        if (id !== undefined) used.add(id);
      });
      let id = PhoneReminders.nextNotificationId;
      while (used.has(id)) id = id >= 2147483646 ? 1500000000 : id + 1;
      request.notificationId = id;
      PhoneReminders.nextNotificationId = id >= 2147483646 ? 1500000000 : id + 1;
      const closeTitle = await context.resourceManager.getStringByName('phone_reminder_close');
      request.actionButton = [{ title: closeTitle, type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE }];
      // Recheck the original native permit after every asynchronous preparation,
      // immediately before the one real system side effect.
      dispatch();
      let reminderId: number;
      try {
        reminderId = await reminderAgentManager.publishReminder(request);
      } catch (error) {
        const refused = refusal((error as BusinessError).code);
        if (refused !== null) throw new PhoneReminderRefused(refused);
        throw error as Error;
      }
      if (!Number.isInteger(reminderId) || reminderId < 0) throw new Error('Invalid reminder receipt');
    });
    PhoneReminders.tail = pending.then((): void => {}, (): void => {});
    await pending;
  }

  private static request(args: Map<string, Object>): reminderAgentManager.ReminderRequest {
    const kind: Object | undefined = args.get('kind');
    const message: Object | undefined = args.get('message');
    if (message !== undefined && typeof message !== 'string') throw new PhoneReminderDenied('invalid_arguments', '提醒标签必须是文字。');
    const content = typeof message === 'string' ? message : '';
    if (kind === 'alarm') {
      const hour = integer(args, 'hour', 0, 23);
      const minute = args.has('minute') ? integer(args, 'minute', 0, 59) : 0;
      const rawDays: Object | undefined = args.get('days');
      const days: number[] = [];
      if (rawDays !== undefined) {
        if (!Array.isArray(rawDays)) throw new PhoneReminderDenied('invalid_arguments', '重复日期必须是星期列表。');
        const values: Object[] = rawDays as Object[];
        for (const value of values) {
          if (typeof value !== 'number' || !Number.isInteger(value) || value < 1 || value > 7) {
            throw new PhoneReminderDenied('invalid_arguments', '重复日期须为 1–7（周一至周日）。');
          }
          if (!days.includes(value)) days.push(value);
        }
      }
      days.sort((a: number, b: number): number => a - b);
      const alarm: reminderAgentManager.ReminderRequestAlarm = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_ALARM,
        hour, minute, daysOfWeek: days, title: 'DSH 闹钟', content,
        slotType: notificationManager.SlotType.SERVICE_INFORMATION
      };
      return alarm;
    }
    const seconds = integer(args, 'seconds', 1, 86400);
    const timer: reminderAgentManager.ReminderRequestTimer = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
      triggerTimeInSeconds: seconds, title: 'DSH 计时器', content,
      slotType: notificationManager.SlotType.SERVICE_INFORMATION
    };
    return timer;
  }
}
