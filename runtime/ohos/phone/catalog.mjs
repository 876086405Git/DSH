// Parameter schemas match PhoneToolCatalog.kt; permissions never change this list.
const field = (type, description) => ({ type, description });
const str = description => field('string', description);
const integer = description => field('integer', description);
const number = description => field('number', description);
const boolean = description => field('boolean', description);
const enumeration = (values, description) => ({ type: 'string', enum: values, description });
const schema = (properties, required = []) => ({ type: 'object', properties,
  ...(required.length ? { required } : {}), additionalProperties: false });

export const phoneCatalog = Object.freeze([
  { name: 'mcp__phone__open', description: '打开应用或链接（app 或 url 二选一）。鸿蒙仅支持前台公开系统能力，不支持后台屏或屏幕快照；无法解析的应用明确报错。',
    parameters: schema({ app: str('包名或应用名'), url: str('网址或深链'), background: boolean('在后台屏打开') }) },
  { name: 'mcp__phone__intent', description: '用系统公开能力办事（打开界面的事务仍需用户在对方界面确认），能办就别点界面。字段按 kind：' +
      'alarm(hour,minute,days?,message?)、timer(seconds,message?)、calendar(title,begin,end?,all_day?,location?,description?)、' +
      'dial(number)、sms_draft(number?,text)、share(text,app?)、navigate(destination|lat+lng,mode?,map?)、settings(page,app?)。' +
      '鸿蒙只用已实现的公开系统映射；闹钟和计时器由系统代理提醒，不承诺唤醒或运行引擎；不支持的事务明确报错，打开界面不代表事务已完成。',
    parameters: schema({
      kind: enumeration(['alarm', 'timer', 'calendar', 'dial', 'sms_draft', 'share', 'navigate', 'settings'], '事务类型'),
      hour: integer('时 0–23'), minute: integer('分 0–59'),
      days: { type: 'array', items: { type: 'integer' }, description: '重复的星期，1=周一 … 7=周日；省略只响一次' },
      seconds: integer('秒 1–86400'), message: str('闹钟 / 计时器标签'), title: str('日程标题'),
      begin: str('开始，如 2026-10-24T19:00（手机时区）；全天写 2026-10-24'),
      end: str('结束，省略 = 开始后 1 小时；全天事件省略 = 只占当天'), all_day: boolean('全天'), location: str('地点'),
      description: str('备注'), number: str('电话号码'), text: str('文字内容'),
      app: str('分享目标应用（省略弹分享面板）；settings:app_notifications 用哪个应用'),
      destination: str('目的地名称或地址'), lat: number('纬度 GCJ-02'), lng: number('经度 GCJ-02'),
      mode: enumeration(['drive', 'transit', 'walk', 'ride'], '出行方式，默认 drive'),
      map: enumeration(['amap', 'baidu'], '地图，默认先高德再百度'),
      page: enumeration(['home', 'wifi', 'bluetooth', 'mobile_network', 'airplane', 'display', 'sound', 'battery',
        'location', 'date', 'language', 'storage', 'nfc', 'app_notifications'], '设置页；app_notifications 还需 app'),
    }, ['kind']) },
  { name: 'mcp__phone__notify', description: '给用户发一条手机通知。鸿蒙要求本次执行时DSH在前台；发布成功不代表用户已看到。',
    parameters: schema({ title: str('标题'), text: str('正文') }, ['title', 'text']) },
  { name: 'mcp__phone__clipboard', description: '读写剪贴板：set 写入文字；get:true 读取（系统只允许前台应用读，DSH 不在前台时读不到）。鸿蒙仅支持set写入；get:true明确不支持。',
    parameters: schema({ set: str('要写入的文字'), get: boolean('读取剪贴板') }) },
  { name: 'mcp__phone__handoff', description: '把手机交给用户完成登录、验证码、支付或没把握的步骤；等用户点「继续」或「停止」，最长 10 分钟。鸿蒙不返回屏幕快照，继续仅证明本次点击，不证明第三方操作完成。',
    parameters: schema({ reason: str('要用户做什么，一句话') }, ['reason']) },
]);

export const phoneResultSchema = {
  type: 'object', additionalProperties: false,
  properties: {
    status: { type: 'string', enum: ['succeeded', 'failed', 'cancelled', 'timed_out', 'unknown'] },
    effect: { type: 'string', enum: ['none', 'opened_ui', 'notification_published', 'clipboard_written', 'reminder_scheduled'] },
    evidence: { type: 'string', enum: ['opened_ui', 'user_confirmed', 'unknown'] },
    dispatched: { type: 'boolean' }, code: { type: 'string' }, message: { type: 'string' },
  },
  required: ['status', 'effect', 'evidence', 'dispatched', 'code', 'message'],
};
