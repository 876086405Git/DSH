# 实时活动（状态栏胶囊 / 灵动岛）

## 0. 结论

DSH 在干活、等你处理、操作手机时，挂一条常驻通知，请求 Android 16 把它提升为 Live Update（实时活动），显示在状态栏胶囊、通知栏顶部和锁屏上。HyperOS 3.1+、ColorOS 16、MagicOS 10 会把这类通知放进各自的岛里；Pixel 显示在状态栏胶囊里。

各厂商的私有灵动岛协议都要白名单，侧载 APK 走不通，所以不针对它们写私有协议。唯一的例外是小米焦点通知的模板：只在系统确认放行本 App 时才附上，不放行就不加。

## 1. 各厂商的路

| 厂商 | 私有协议 | 我们能不能用 | 标准 Live Updates |
|---|---|---|---|
| 小米 | 焦点通知 / 超级岛 `miui.focus.param` | 国行要企业认证、上架小米商店、绑签名、审核；国际版有用户开关 | HyperOS 3.1+ 进超级岛（社区实测，官方未写） |
| vivo | 原子岛 `notification.superx.*` | 要上架 vivo 商店、邮件审核，按包名 + 场景白名单 | 海外版 OriginOS 6 可以；国行 OriginOS 6 不行 |
| OPPO / 一加 | 流体云（意图共享 ContentProvider） | 要企业认证、OPPO 授权 | ColorOS 16 / OxygenOS 16 支持；部分版本的逐应用开关默认关 |
| 荣耀 | 灵动胶囊（Kit / 意图共享） | 要审核 | MagicOS 10 官方文档明确支持，不用审核 |
| 三星 | Now Bar 私有 extras | 包名白名单 | One UI 8 默认只放行三星自家应用，第三方要开发者选项 |
| 华为 | 实况窗 | 只支持鸿蒙 5 原生应用 | 不适用 |

### 1.1 真机证据（vivo X200，国行 OriginOS 6，`PD2405C_A_16.1.24.23`，2026-11-01）

- `sdk_full=36.0`，即 QPR0 底子。`framework.jar` 里 `android.app.FeatureFlagsImpl.uiRichOngoing()` 编译成常量 `false`，`Notification.hasPromotableCharacteristics()` 因而走旧分支（只认 ongoing CallStyle 或 colorized）。`canPostPromotedNotifications()` 对 targetSdk 28 和 36 都返回 false，系统也没有定义 `POST_PROMOTED_NOTIFICATIONS`。这台手机上谁都拿不到实时活动。
- 第三方 App 按 vivo 钱包的格式发 `notification.superx.island` 等 extras，系统会删掉岛相关字段，并把 tag `VIVO_SUPERX_TAG` 改成 null。白名单是 `vivo-services.jar` 里的 `mAllowAppSupportSuperXNoti`，数据来自 `/data/bbkcore/vivo_superx_info_list.xml`（云控，shell 无权读取）。

所以这台手机只能验证"不支持时什么都不发"，看不到岛的效果。

### 1.2 targetSdk 28 不受影响

AOSP 16.0 / QPR1 / QPR2 / 17 的 `Notification.hasPromotableCharacteristics()` 和 `NotificationManagerService.fixNotificationWithChannel` 都只检查通知本身、渠道重要性（不能是 MIN）和 `POST_PROMOTED_NOTIFICATIONS` 权限（`normal|appop`，安装时授予），没有 targetSdk 或 CompatChange。`EXTRA_REQUEST_PROMOTED_ONGOING`（`"android.requestPromotedOngoing"`）和权限常量到 SDK 36.1 才公开，所以代码里写字面量，不必升 compileSdk。

将来如果某个版本给提升路径加上 targetSdk 门槛，我们会最先失效：每个 Android 大版本都要在真机上回归一次。

## 2. 产品规则

### 2.1 什么时候显示

只在系统真的会提升时才发：`canPostPromotedNotifications()` 为真（Android 16 QPR1+ 且这个 App 的开关开着），或者 HyperOS 放行本 App 的焦点通知。其他手机上什么都不发，免得多出一条常驻通知。

| 来源 | 状态 | 胶囊 | 正文 |
|---|---|---|---|
| 手机操控（原生） | 任务进行中 | 「操作中」/「已暂停」 | 「DSH 正在操作手机」+ 当前动作，带「停止操作」 |
| 宠物 notification | 等你确认 / 回答 | 「待确认」/「待回答」 | 对话标题 + 「等你确认」 |
| 宠物 thinking / working / juggling / sweeping | 运行中 | 计时（从这轮开始算） | 对话标题 + 「正在思考 / 干活 / 子代理在帮忙 / 整理上下文」，多个对话时加「· N 个对话在跑」 |
| 宠物 attention / error | 做完了 / 出错了 | 「完成」/「出错」 | 只在 App 不在前台时显示宠物这一下，跟随「一轮完成」「出错或被停下」两个通知开关 |

- 手机操控优先：DSH 在动你的手机，这是最需要看见、也最需要能随时停下的事。
- 文案由宠物状态归约（`PetMood`）而来，岛和宠物说的永远一致；大图标是当前宠物在这个状态下的第一帧（Deepy 敲电脑、举牌、蹦跳），没选宠物就不放。
- 点击打开宠物的「最相关对话」，和点悬浮宠物去的是同一个地方。
- 审批按钮仍只放在「等你确认」通知上，实时活动不重复放。
- 锁屏隐藏敏感内容时只显示「DSH 正在干活」这类泛化文字，标题照 `alertTitle` 脱敏。

### 2.2 开关

「设置 → 通知 → 实时活动」，默认开，受通知总开关约束。系统不支持时开关置灰并写明；系统支持但没放行时（ColorOS 部分版本默认关）给出「去开启」，跳 `ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS`，解析不到就退回通知设置。

## 3. 实现

| 文件 | 作用 |
|---|---|
| `app/lib/notify/live_activity.dart` | 纯函数 `liveActivityOf`：宠物状态 → 文案、胶囊、计时起点、目标对话 |
| `app/lib/state/live_activity_state.dart` | 组合宠物状态、运行列表、待处理事项和通知开关，变化时推给 `dsh/notify` 的 `live` |
| `notify/LiveContent.kt` | 实时活动内容（纯 Kotlin），以及手机操控优先的取舍 |
| `notify/LiveActivity.kt` | 单线程发布：最短间隔 600 ms；内容不变不重发；4 分钟重发一次，10 分钟超时（完成态 15 秒），进程死了也不会把「干活中」留在通知栏 |
| `notify/XiaomiFocus.kt` | `canShowFocus` 放行时附上焦点模板，岛上放宠物和胶囊文字；模板不超过 3072 字节 |
| `pet/PetSprites.kt` | `portrait`：只解码一个格子，裁到不透明区域，像素画按整数倍放大 |
| `phone/PhoneControl.kt` | 任务起止和每次状态行变化时刷新实时活动 |

渠道 `dsh-live` 用默认重要度但不响铃、不振动：HyperOS 焦点路径上没有提升时，仍保留状态栏图标。

## 3A. iOS：灵动岛和锁屏（ActivityKit，iOS 16.2+）

同一个 `LivePush`，iOS 自己画。参考过 issue #1500 的做法（独立扩展 + App Group + 内联小图），这里改成：

- **不加扩展。** 活动放进现有的 `CompanionWidget` 扩展：按系统版本分两个 WidgetBundle（扩展最低 iOS 15，bundle 里写不了 `if #available`）。不用新的 Bundle ID 和描述文件，重签工具处理一个扩展就够。
- **不另起一套 Dart。** 归约、开关、文案都是安卓那套；iOS 只多带几样（`liveWith`）：主题色（浅 / 深）、按钮文字、能不能停、宠物静帧。
- **宠物图走共享 Keychain。** 扩展读不到 Flutter 资源和 App 沙盒（导入的宠物在 Documents 里），App 用 `PetSheets` 把这个状态的第一帧画成 PNG（最长边 180 px，像素画整数倍），存进伙伴小组件已在用的 Keychain 组（`LiveArtStore`）。不用 App Group：那要每份描述文件都带上组，侧载最容易丢。同一张图只过一次通道。
- **只在有事时出现。** 没有在跑的对话就没有卡片，不常驻一只空闲宠物。

| 位置 | 显示 |
|---|---|
| 收起的岛 | 左：宠物；右：计时，等你时换成琥珀色「待确认 / 待回答」，做完 ✓，出错 ! |
| 最小态 | 只有宠物，等你或出错时右上一个小点 |
| 展开的岛 | 宠物、对话标题（脱敏）、这一步在干什么、计时；能停时下面一个「停止」 |
| 锁屏 | 宠物、「正在思考 · 2 个对话在跑」这类不含内容的话、计时；**不显示对话标题** |

- 颜色只有主题强调色一种，琥珀只给「等你处理」，红只给出错。深色（岛）用 `seedDark`。
- 点卡片打开那个对话：`dshgo://live?…` 转成通知点击（`NotifyTaps`），和安卓一样走 `kind: live`。
- 「停止」（iOS 17+，`LiveActivityIntent`）在 App 进程里交给 Dart，就是悬浮宠物的停止，同样的检查（宠物的对话、App 当前连着的主机）；不要求解锁。
- iOS 只允许 App 在前台时开新活动：开不了就等回到前台再开。换对话时更新同一个活动，所以后台换对话也跟得上。
- 用户划掉后，这一段不再出现，直到没有在跑的或换了对话。
- App 活着时每分钟续一次过期时间；被系统挂起约 2.5 分钟后卡片变成「暂停更新」，计时变成暂停符号，不让一个可能已经停了的时钟继续走。
- 后台跑完时，运行先从列表里消失，「做完了 / 出错了」稍后才到；而后台开不了新卡，所以这张卡最多再留 20 秒等结果，等不到才收。
- 做完 / 出错：在锁屏留 15 分钟（显示用时），打开 App 就收掉。
- iOS 26 上后台继续跑的一轮还会有系统自己的进度卡（`ContinuedRun`），两张卡并存。

| 文件 | 作用 |
|---|---|
| `app/ios/CompanionWidget/LiveActivityShared.swift` | 两个 target 共用：内容状态、`LiveArtStore`、停止意图 |
| `app/ios/CompanionWidget/LiveActivityWidget.swift` | 岛和锁屏的样子 |
| `app/ios/Runner/IOSLiveActivity.swift` | 起、更新、结束，前台补开，续期，划掉，停止转给 Dart |
| `app/lib/notify/live_art.dart` | 宠物静帧 |

## 4. 验证

- 单测：`LiveContentTest`（JVM）、`test/notify/live_activity_test.dart`、`test/notify/live_ios_test.dart`。
- 真机：需要 Pixel（Android 16 QPR1+）、ColorOS 16、MagicOS 10 或 HyperOS 3.1+ 的设备，或 Android 16 QPR2 模拟器。检查胶囊计时、等你确认时的胶囊文字、锁屏脱敏、点击跳转、手机操控时的「停止操作」。国行 OriginOS 6 上应当什么都不发。
- iOS 真机：带灵动岛的 iPhone（iOS 16.2+；「停止」要 17+）。检查收起 / 展开 / 最小态、锁屏不出标题、点击进对话、等你确认时变琥珀、停止能停、切走 3 分钟后的「暂停更新」、做完后锁屏留卡和打开 App 收卡、导入宠物和像素宠物的图、自签包上宠物图是否还在（Keychain 组）。

## 5. 以后可以做

- **步骤进度条**：对话有 todo 列表时（`TodoWriteEvent`），用 `ProgressStyle` 按 todo 分段，宠物当进度条上的 tracker 图标往前跑。需要为后台对话订阅日志流，开销要先评估。
- **引擎解包 / 语音模型下载**：`DshService` 的进度通知改成 `ProgressStyle` Live Update，宠物沿进度条跑。
- **手机操控等你确认**：操控中的确认弹窗也让胶囊变成「待确认」。
- **岛上直接批准**：沿用悬浮宠物的规则，只在完整显示命令时给「允许本次 / 拒绝」，并要求解锁。
- **iOS 后台更新**：App 被挂起后卡片只能标「暂停更新」。要在后台也跟上远程主机的进度，得由主机发 ActivityKit 推送（APNs），需要推送证书和服务端配合。
- **厂商白名单**：vivo、小米都要求先上架各自的应用商店，OPPO 要企业认证。这是商务决定，不是技术问题。
