# P3d：普通通知与点击回到会话

初版基底 `c818155`；通知内容初次更新基于 `751db9d`，本轮在 `718c06a` 重放。本包新增 `dsh/notify`、`dsh/notify/taps`、`dsh/notify/actions` 的 ArkTS 插件，在 `configureFlutterEngine` 注册。**未编译、未在真机核实**；当前证据是 Linux 上执行真实产品 ETS 经 TypeScript 擦除后的行为、真实 HMAC/文件持久化，以及固定公开声明的 TypeScript 语义检查。不能据此宣布 hvigor、ArkTS、HAP 或设备通过。

## 协议与体验

| 方法或流 | 当前行为 |
| --- | --- |
| `status` | 查询应用通知总开关及 `SERVICE_INFORMATION` 槽位；缺槽位时创建该槽位。`enabled` 是应用开关，`done`/`attention` 是同一个槽位当前可用性；总开关关时二者保守为 false。不弹申请窗口，不把查询失败说成允许。 |
| `show` | 再查实际允许状态；使用 Dart 与 Android 共有的 `title`/`text`；非空 `fullText` 用公开长文本内容展示，折叠仍为 `title`/`text`。同一 group/key 使用稳定的 SHA256 标签更新同一通知。返回成功只表示系统 publish Promise 完成，不证明系统实际展示。 |
| `cancel` / `cancelGroup` | 与发送操作串行，使用相同的稳定标签/分组，防止后到的发送复活已取消项。 |
| `cancelAll` | 只取消本插件 id=0 且带 `dsh-chat:` 标签的普通会话提醒，不调用全应用 cancelAll。 |
| `requestPermission` | 调用 `requestEnableNotification` 弹一次系统授权窗口，之后返回 `isNotificationEnabled`；用户拒绝（1600004）返回 false，其余错误走错误通道。需要活着的 Ability。拒绝后窗口不会再弹，只能走 `openSettings`。该窗口 Promise 同样不阻塞发通知的队列。 |
| `openSettings` | 仅调用时打开真实 UIAbility 对应的应用通知设置；返回 true 表示 API 完成，不能解释为用户已开启权限。该窗口 Promise 不阻塞发通知的队列。 |
| taps | 系统 WantAgent 点击后，校验本次安装的 HMAC，再发 Dart 现有 Map：host、sessionId、kind、可选 eventId。冷启动等待订阅；同 Android 当前协议，尚未订阅时保留最后一次点击。 |
| actions / `actionResult` | 明确 `ohos_unsupported`。`canApprove` 的通知只有「打开应用处理」按钮；点击导航后在应用内看完整操作并批准，没有通知外批准/拒绝。 |
| `liveStatus` | supported=false、allowed=false、settings=true、xiaomiFocus=false。 |
| `live` | 禁用或清空时无已有活动可清，返回 null；请求实际活动时明确 unsupported，并提示在应用内看进度。 |
| `openLiveSettings` | 按 Dart 已有 fallback 约定打开普通应用通知设置，不谎称有可开启的第三方实况窗。 |

两类会话提醒使用同一个系统槽位；Dart 现有两类偏好仍分别决定是否请求发送。`openSettings(channel)` 也只能打开应用通知设置，不声称有两条独立的系统渠道。

### 通知正文与锁屏显示

通知接收现有 `title`、`text`、`fullText` 参数，不另设 `body` 键；有 `fullText` 时映射 `NotificationLongTextContent`，折叠为 `title`/`text`，展开为同一标题与 `fullText`。SDK26 要求标题和正文非空，所以缺失或空标题回退「DSH Go」，缺失或空正文依次回退 `publicText`、通用提醒；真实非空内容不做替换。错误类型以 `bad_args` 拒绝。SDK声明标题超过1024字节、正文/长文本超过3072字节的部分由系统截断，实际样式与显示长度待设备核实。

这里将真实内容交给系统通知服务。Android 端另外实现了 `VISIBILITY_PRIVATE`/`publicVersion` 和锁定期间主动改发公开内容、解锁后静默更新；OHOS 本次没有等价的应用侧强制删减实现，不声称锁屏必定只显示 `publicText`。`publicText` 只作空正文兼容回退。正文不进入点击 Want、HMAC 路由或诊断日志。

锁屏能否显示及是否展示内容由用户的系统设置控制。[华为官方 HarmonyOS 6.0/6.1 说明](https://consumer.huawei.com/cn/support/content/zh-cn16090725/)列出：应用的「允许通知」「锁屏通知」开关控制是否展示；系统「通知和状态栏 → 锁屏通知 → 显示锁屏通知内容」可选始终或已解锁时。[官方 HarmonyOS 5及以上排障说明](https://consumer.huawei.com/cn/support/content/zh-cn00445086/)还说明应用锁会隐藏锁屏内容，智能提醒/人脸识别也会影响内容展示。具体菜单与机型/版本相关。应用内现有提醒偏好控制是否发送，本包不新增隐私开关，也不改变用户的系统设置。

本次核对固定SDK `26.0.0.38` 的公开声明：`NotificationSlot.lockscreenVisibility` 仍标为保留、暂不支持；`NotificationSetting.lockScreenEnabled` 只报告是否启用锁屏通知，不能据它推断内容是否隐藏。没有设置这些字段来模拟 Android publicVersion，没有调用系统应用权限或HMS私有权益。锁定/解锁、人脸验证、应用锁、各内容显示选项及长文本展开均需真机验证。

当前 API 的 ActionButton 没有核实到 Android 通知审批所需的强制解锁契约，因此不把批准或拒绝映射成未经验证的系统按钮。公开 `LIVE_VIEW`/`SYSTEM_LIVE_VIEW` 亦说明第三方应用不能自行创建相应槽位/内容，需系统代理；另一路普通 LIVE_VIEW 的公开说明要求系统应用。`downloadTemplate` 是文件传输进度，不能用伪造百分比冒充 AI 执行进度。本包没有使用系统应用 API、假装有前台服务，或新增权限。

## 点击来源和生命周期

EntryAbility 可接收外部 Want，单凭 action 名称或参数不能证明是本应用通知。插件用公开 cryptoFramework 生成 256 位 HMAC-SHA256 密钥，保存在本应用 Preferences；完成 flush 后才使用。重启时从相同持久值转换密钥。flush 失败即拒绝发送；再次读取缓存值也先 flush，不能绕过前次写入失败。

Want 固定指向当前 Ability 的 bundleName/name，不接受 Dart 给定的目标；使用 `START_ABILITY`、`CONSTANT_FLAG` 和按签名区分的 URI。签名只包含 host 引用、sessionId、kind、eventId，不包含 API token 或通知正文。收到 Wants 时校验长度、签名格式/全部字节及 route 字段。有效旧点击可再次打开同一会话，不实施审批或任何工具动作；此处不宣称防止持有效签名者重放导航。

发送、单项/分组/全部取消共享一个串行队列。点击有独立的串行校验队列，保持到达顺序，也不会被待完成的通知发送阻塞。引擎更替期间正在验证的点击交给当前订阅者；没有当前订阅者则保留最后项。每个 Ability 的冷启动 Want 只消费一次，热启动的重复点击仍是独立事件。

只销毁 Ability 时保留应用 Context 和已取得的自有目标身份，允许继续普通后台提醒；不持有失效 Ability 引用。销毁 engine 则递增 generation，撤销本插件的 method/binary event handler、清订阅，并拒绝旧队列任务及尚未调用 publish 的旧异步发送。已经交给系统的 publish 没有公开撤回 Promise 的契约，可能在销毁之后完成；不伪造取消确认。随后的显式 cancel 按队列执行。

## 已运行验证

`runtime/tests/ohos/notify-channel.test.mjs` 执行产品 ETS，系统通知/WantAgent/Flutter 是显式替身，HMAC/SHA256、随机密钥与私有目录 JSON 持久化使用真实 Node/Linux。内容更新后共 **19 项通过**，覆盖：

- 精确三通道、未知方法、unsupported 边界、设置窗口错误及非阻塞性；
- 授权窗口需要活着的 Ability、用系统状态作答、拒绝不算失败、其余错误走错误通道、等待时不阻塞其他调用；
- 应用总开关/槽位关闭/最低级别/未知/查询失败、缺槽位创建、发送再次检查；
- 真实标题/正文/展开文字、空字段回退和错误类型；固定目标、不可变 Want、真实持久密钥与 HMAC，点击路由不携带正文或密钥；
- 标签的分组/键边界、更新、单项/组取消、本插件范围内 cancelAll；
- 待完成 publish 后的取消顺序、失败后队列恢复；
- 新 VM 模拟进程重启后验证持久密钥，冷/热点击、篡改/错误签名/超长/畸形输入；
- 校验途中引擎更替、事件顺序、最后待订阅点击、旧 handler 清理；
- 相同插件实例重挂载不复活旧请求，Ability 脱离后仍能发送；
- Preferences 写入失败/缓存重试、坏持久密钥关闭发送。

三个已保存的早期候选反例先失败：总开关被槽位覆盖、迟到发送在同实例重挂载后复活、flush 失败重试通过内存缓存发布。修复后完整 14 项通过。晚到事件与其它边界也由显式 Promise 控制交错，不靠固定睡眠碰时序。

另用锁定 TypeScript 5.9.3、完整固定 OH 公开 `.d.ts`、从固定 Flutter 公开签名抽取的最小声明检查产品源码，**0 诊断**。这仅验证静态调用关系，不运行 ArkTS 特有检查、系统服务或 hvigor。

## 主线接入与设备门

- 不需要 P1/P2 才能使用普通通知；与它们及 P3a/b/c 一起注册时，应保留所有插件。补丁在纯基底及已交包顺序组合中核验普通 `git apply`。
- `NotifyChannel.status()` 在现有 Dart 中捕获 PlatformException 后返回乐观的全 true。这是既有 UI/协议消费门：主线应为 OHOS 的查询失败显示未知或可重试状态。本插件仍返回明确错误，且 `show` 再查权限、`tryShow` 接收失败；没有用虚假的成功状态迁就该 fallback。
- 需要主线确认目标 API26 的公开类型/ArkTS 编译、设备 `Preferences.flush` 和 HMAC 算法、通知槽位的 enabled 返回、通知发布频率与系统展示、锁屏系统隐藏策略及展开正文、WantAgent 冷/热点击、后台冻结/恢复后的回调。
- 进度提醒在本包没有普通通知伪装成实况窗。若产品要另设明确标注的「普通进度提醒」fallback，需主线调整能力/UI契约后另包接入。
- 本包不改变 Flutter UI、Android 源、权限、构建版本串或运行时依赖。

## 固定公开依据

接口源固定为 OpenHarmony `interface_sdk-js` 修订 `8a86234f0d542e5062e24e948652f5a484d90904`：

- [notificationManager](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@ohos.notificationManager.d.ts)：publish、getSlot/addSlot、允许状态、cancel、getActiveNotifications、openNotificationSettings 与槽位类别。
- [NotificationSlot](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/notification/notificationSlot.d.ts) 与同目录 request/actionButton：权限标志、字段与公开能力边界。
- [WantAgent](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@ohos.app.ability.wantAgent.d.ts) 及 `wantAgent/wantAgentInfo.d.ts`：新 actionType/actionFlags、CONSTANT_FLAG。
- [Preferences](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@ohos.data.preferences.d.ts) 与 [cryptoFramework](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@ohos.security.cryptoFramework.d.ts)：私有持久化与 HMAC-SHA256。
- [华为官方对称密钥规格](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/crypto-sym-key-generation-conversion-spec-V5)：HMAC|SHA256 为 256 位；[官方 MAC 算法检查说明](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V5/ide_no-unsafe-mac-V5)给出 SHA256 MAC。

Flutter 接口固定为 oh-flutter 修订 `e5f752df3e25ec897da3c98a74bcced7c21b0bd3`：MethodChannel、EventChannel、BinaryMessenger、FlutterPluginBinding、AbilityPluginBinding。EventChannel 的 setStreamHandler 不接受 null，故按公开 nullable BinaryMessenger 接口精确注销两个事件通道；getPlugins 可空，注册使用可选链。没有复制其他鸿蒙移植实现。
