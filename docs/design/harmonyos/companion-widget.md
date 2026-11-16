# 伙伴桌面卡片：后端与本机接线合同（1310）

**桌面卡片界面与注册待本机，当前非整项可上桌面。** 本补丁提供 `dsh/companion_widget` 数据后端和 `CompanionFormAbility`；不包含卡片页面、图片资产、字符串资源或 manifest/profile 注册。保存成功只证明状态已持久化和本次已知实例的 SDK 调用完成，不能说明卡片已出现在桌面。目标 API 26 手机的 SDK 编译、冻结行为、桌面呈现均未在真机核实。

## 现有生产路径

`app/lib/ui/companion/companion_page.dart::_widgetUpdate` 已在伙伴状态和话语变化时调用 `companionWidgetProvider.update`，没有 Android 平台门。本补丁不修改此页面，也不修改 `app/lib/companion/companion_widget.dart`。原 Dart 合同会捕获原生异常；卡片保存/刷新失败不会影响伙伴页面，但也不会向页面假报“已添加”。

基底 Android 合同来自 `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/companion/CompanionWidget.kt`：通道仅有 `update`，成功返回 null，没有事件；非 Map 是无操作，未知方法 notImplemented。下面九个字段由当前真实生产者发送。字段缺省保留旧值，显式 null 删除，布尔/对象忽略。鸿蒙只保存这九个有消费者的键；未知键忽略。

| 字段 | 有效类型 | 意义 |
| --- | --- | --- |
| name | string | 伙伴名称，空字符串是有效值 |
| activity | string | idle 或正在进行的活动 |
| status | string | 忙碌时显示的本地化文字 |
| untilMs | number，截断为整数 | 活动到期的 Unix 毫秒 |
| statusAsleep / statusWaiting | string | 夜间/等待状态的本地化文字 |
| bond | number，截断为整数 | 绘制时限制为 -1～3 |
| line | string | 最近一句话 |
| saidAt | number，截断为整数 | 该话语的 Unix 毫秒 |

字符串每项最多 4096 个 UTF-16 单元，完整 UTF-8 JSON 最多 32768 字节；数字要求截断后仍是 JS 安全整数。当前页面的实际数据远小于此界限。错误类型或超限不截断成另一份内容。原生错误：`ohos_widget_invalid` 是协议无效；`ohos_widget_update` 是磁盘、锁忙、队列满或系统刷新失败；`ohos_widget_detached` 是原引擎已离开。Dart 仍按 Android 原合同吞掉这些错误。

## 时间与展示计算

每次重绘重新取 `new Date()` 的本地小时与毫秒，不缓存时区：23 点（含）至 6 点（不含）为夜间。`activity != idle` 且 `untilMs > now` 时优先显示 status；正好到期即恢复夜间/等待状态。夜间且不忙选 sleeping；否则 bond≥2 选 happy，其余 idle。bond=-1 隐藏圆点，0～3 显示一至四个实心圆点，总计四个。

话语仅在 `now - saidAt < 12 小时` 时保留，正好十二小时清空。多个实例逐个异步刷新时，每个实例派发前重新计算本地时间和 TTL，避免首个 SDK 调用长时间等待后给后面的实例沿用旧时间。未来 saidAt、时钟回拨导致负年龄时仍保留，和 Android 相同。系统周期刷新有调度延迟，不能承诺到期那一毫秒桌面立即变化；Android XML 本来也是 30 分钟刷新。

输出 `WidgetView` 是扁平绑定对象：`ready/name/nameDefault/status/statusDefault/line/pearls/pose/openUri`。`nameDefault=true` 表示页面应使用本地化默认名字；`statusDefault` 为 waiting/asleep 时由页面显示对应本地化字符串，空串表示显示 status（含有意留空）。`ready=false` 是尚未从盘上读完的初始绑定，不能显示为“已同步”。`pose` 只取 sleeping/happy/idle；`openUri` 固定为 `dshgo://open/companion`。行为空时页面隐藏话语区域。

## 独立进程、原子性和失败

FormExtension 与 UIAbility 是不同进程。两边都调用 `context.getApplicationContext()`，使用同一个应用级 `filesDir/companion-widget/`；不能用各自模块级 filesDir，也不以 static 字段共享数据。static Map 只缓存当前进程的事务队列和待重试关闭的 FD。每次事务都重新打开 snapshot.json。

目录仅包含稳定的 lock、snapshot.json 和最多一个失败遗留的 pending.json。写入经过完整短写循环、文件 fsync、close、同目录 rename、目录 fsync；读取检查普通文件、限制长度、完成短读、严格 UTF-8 与九字段类型验证。NOFOLLOW 拒绝符号链接。损坏快照会明确失败并保留原字节，不擅自清空用户状态。Android 源码和权限列表不变。

原子 rename 只解决“读到半份 JSON”；它不能阻止旧进程的延迟 `updateForm` 最后落地。因此两种进程都在同一独立 lock 文件上执行 `File.tryLock(true)`，锁覆盖读盘/写盘及整个物理 `updateForm` Promise。另一进程忙时立即失败，不阻塞等冻结进程，也不因超时解除旧事务锁。下一次页面更新或系统 `onUpdateForm` 可重试。旧 Promise 未完成时，本后端不声称已经退休；进程真正死亡后内核才回收其文件句柄与锁（Linux 已实测，HarmonyOS 待真机）。

同一进程顺序排队，最多包含在途事务在内 16 项；这是本实现的内存上限，不是 FormKit 系统配额。队列满明确失败。引擎 detach 后原 MethodResult 只结算一次；已接受的持久化仍按原队列顺序完成，新引擎后来的状态排在其后。close 失败会保留 FD，下一次事务先重试关闭，再开新的锁，防止逻辑失败被误认为物理资源已释放。

UI 更新先原子存储，再查询 API 20 `getPublishedRunningFormInfos()`，只更新同 bundle、module=entry、ability=CompanionFormAbility、form=companion_room 的实例。一张卡片失败不会跳过其他实例，最终给调用者失败；不存在实例时数据仍保存，不虚构已显示卡片。若目录 fsync 在 rename 之后失败，调用失败但盘上可能已有完整新状态，下次读到新状态是允许的。

`onAddForm` 同步返回 ready=false 的占位数据，随后异步读盘并 updateForm；`onUpdateForm` / `onCastToNormalForm` 读最新快照。remove/stop 会使尚未提交的旧刷新失效。扩展不导入 Node、Flutter runtime、音频、网络或 backgroundTaskManager，不设置定时器，不申请保活权限。

## 本机需完成的具体文件

1. **`app/ohos/entry/src/main/module.json5`**：在 extensionAbilities 注册 name=`CompanionFormAbility`、srcEntry=`./ets/formability/CompanionFormAbility.ets`、type=`form`；metadata 的 name 固定为 `ohos.extension.form`，resource 指向 `$profile:companion_form`。label/description 引用本机新增的本地化资源。保持现有权限列表；不要为本项加入 KEEP_BACKGROUND_RUNNING 或媒体读取权限。
2. **`app/ohos/entry/src/main/resources/base/profile/companion_form.json`**：forms 中 name=`companion_room`、uiSyntax=`arkts`、src 指向本机卡片页；updateEnabled=true、updateDuration=1（30 分钟）。页面的尺寸、设计宽度和支持大小由本机选择。不要启用 dataProxy/Push 或创建独立常驻服务。bundle/module/ability/form/dimension 是卡片身份的一部分，发布后改变需要按官方升级规则处理。
3. **`app/ohos/entry/src/main/ets/widget/pages/CompanionCard.ets`（建议路径）**：用 ArkTS 卡片数据存储绑定上面的九个输出字段；ready=false 提供初始/待刷新表现。nameDefault 和 statusDefault 解析本地化资源；line 空则隐藏；pose 映射三张本地图片；不在页面启动任何后台执行/通话。
4. **资源文件**：提供 companion_widget_idle / companion_widget_happy / companion_widget_sleeping 对应媒体和名称/等待/睡眠文案。本次 ZIP 源码只见 Android 对三张 drawable 的引用，没有图像文件字节，因此这里不复制或伪造它们。本机可沿用现有正式视觉资产生成流程。
5. **卡片点击**：只在用户 click 中调用 `postCardAction` 的 router 事件，目标 bundle 为本应用，uri 固定 `dshgo://open/companion`。不同时指定 abilityName（官方说它优先于 uri），不使用需要保活权限的 call 事件。现有 AppLinksPlugin 要求 Want.action=`ohos.want.action.viewData` 并接收 uri；本机必须实测 cold/warm 两种卡片 router 到达的 Want，确认进入伙伴页面。宿主链接回归不能代替这个系统路由实测。
6. **Flutter UI**：当前 `_widgetUpdate` 已发送，无需重新加一个平台门或复制伙伴逻辑。若本机加“添加桌面卡片”说明/入口，应在上述页面、注册、资源和真机流程齐备后呈现；本补丁没有宣称添加成功的接口。

## 官方来源与核验边界

- [FormExtension 生命周期](https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-app-form-formextensionability/)：API 9 基础能力；onStop API 12；空闲扩展可被回收，禁止引用音频/媒体/后台任务等模块。
- [进程模型](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/process-model-overview/) 与 [Context 目录层级](https://developer.huawei.com/consumer/en/doc/doccenter-capabilities/application-context-stage/)：独立扩展进程、应用级目录。
- [Form provider](https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-app-form-formprovider/)：updateForm Promise；已添加实例查询 getPublishedRunningFormInfos 从 API 20 起。
- [RunningFormInfo](https://developer.huawei.com/consumer/en/doc/doccenter-references/api/js-apis-app-form-forminfo/) 与 [绑定数据](https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-app-form-formbindingdata/)：实例身份字段、字段对象。
- [刷新规则](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/form-refresh-and-data-interaction/) 与 [配置文件](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/arkts-ui-widget-configuration/)：异步初始化、系统刷新及 metadata/profile。
- [FileKit](https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-file-fs/)：tryLock 非阻塞独占锁、fsync/rename/close；不使用阻塞 lock 等冻结进程。
- [postCardAction](https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-postcardaction/)：router 限用户点击、uri 从 API 11 起、abilityName 优先、call 要求保活权限。

实际 oh-flutter `MethodCall.args`、Map 解码和 Context 绑定已核对固定官方 HAR（3.47.9-ohos-1.0.0，仓库锁定提交 e5f752df3e25ec897da3c98a74bcced7c21b0bd3；HAR SHA256 b46e5e370827ef0b80b0d25b219e902680a4a0620c6a75fa6b3cef95a36ff15a），没有假设一个不存在的 `call.arguments` 成员。FormKit 声明依据是官方文档，宿主的 companion-widget-contract.d.ts 只是最小测试边界，不是目标 SDK 头。

宿主实测覆盖实际 ETS、真实 Linux 文件/短读短写/rename/fsync/FD、真实 flock 与独立 OS 进程；Dart 使用真实 Flutter 3.47./Dart 3.13.。不能据此宣称 HarmonyOS SDK 编译、系统锁语义、冻结恢复、桌面渲染或 router Want 已通过。本机需分别验证：两种进程真实目录一致、冻结挂起时 busy 与恢复重试、杀进程锁释放、重启读盘、时区/TTL、资源与大小、卡片点击冷/热启动。当前没有改动 HAP 构建或引入产品依赖。
