# 后台运行：三方机制比较与 dsh-Go 的取舍

> 2026-11-19，静态源码比较，不是耗电、时长或抗杀实测。
> 主仓基线 `5996f1dae5e69f542e3b5fc05f1477ef86e14163`；
> WhyWhySeeYa fork `6c6c3b72852f2bda608c5aed3d337189e24b7ebf`；
> OpenMinis `1a71df0f381cefde80bf912b723de6f9831bc177`。

## 结论

没有“永远不被杀”的移动端保活。保住进程、获得后台执行时间、断线重连、恢复引擎、继续对话是五件不同的事。通知还在、Live Activity 显示 Running、唤醒锁已持有，都不能单独证明任务仍在执行。

- **Android 默认保留 dsh-Go 的前台服务、唤醒锁、厂商设置引导，补齐系统回收整个宿主后的有条件恢复。** Minis 的媒体播放服务类型不适合作为 AI 任务的默认身份。
- **iOS 默认保留系统持续处理任务和真实 PiP 的既有路径，修复暂停收尾额度申请过晚。** 按用户明确选择，另提供默认关闭的静音音频与后台定位增强模式，必须主动开启及授权，不把它们变成默认依赖。
- **Minis 比 fork 的增强保活工程更完整，但不能据此声称实机更稳或更省电。** 可学习任务限定、停止撤销、统一音频协调、状态展示与执行许可分离；不整套搬它的调度状态机。

## 实际差异

| 平台/项目 | 已核实机制 | 代价与边界 |
|---|---|---|
| dsh-Go Android 基线 | `specialUse` 前台服务；运行期间持有 `PARTIAL_WAKE_LOCK`；电池/厂商设置引导；子引擎被杀限次恢复 | 服务返回 `START_NOT_STICKY`，整个宿主消失后内存里的恢复代码无法执行；锁不免除内存回收、Doze 或厂商断网 |
| WhyWhySeeYa Android | 前台服务、锁、Manifest、启动器与主仓相同 | 新增保活实际在 iOS；该 fork 还落后部分主仓启动故障修复，不能把旧差异当新优化 |
| OpenMinis Android | `mediaPlayback` 前台服务、唤醒锁、厂商设置；全会话共享 shell 软预算 | 标签不是实际音频功能；`START_STICKY` 重建时若内存 tracker 无任务仍会停止，不是任意任务自动恢复 |
| dsh-Go iOS 基线 | iOS 26 `BGContinuedProcessingTask`；可选真实宠物 PiP 独立提供许可；短时额度用于暂停收尾 | 系统可拒绝/到期/取消；旧 iOS 无持续任务额度，短时收尾不是无限执行 |
| WhyWhySeeYa iOS | 原有持续任务外，加静音循环、后台定位和自建 Live Activity | 无任务也可在离前台时开启静音；绕过现有音频协调器；停止静音时未通知引擎撤回后台许可；位置权限、音频冲突、耗电和审核风险 |
| OpenMinis iOS | 用户可选增强保护、定位会话/更新、静音音频、持续处理任务和独立 Live Activity | 按任务和开关限定、音频有协调/退让、闲置有界收尾，比 fork 谨慎；仍占定位/音频资源，不能保证存活 |

### 为什么不复制“定位 + 静音”

fork 的静音播放器直接修改全局 `AVAudioSession`；`mixWithOthers` 不能防止覆盖本 App 的录音类别。其 `RunBackground.update(running: false)` 没有通知 `onActiveChanged(false)`，可能在实际音频停止后继续向引擎报后台许可。自建 Live Activity 没有授予 CPU 时间，进程暂停时卡片也可能残留。

Minis 的 iOS 实现更克制：有真实任务和用户开关才运行，后台定位有延迟 arming；iOS 17+ 使用 `CLBackgroundActivitySession` 和 `CLLocationUpdate.liveUpdates`；静音走最低优先级音频协调器，任务结束后安排一次 60 秒闲置收尾；这是代码设定，不是进程被系统暂停时仍按墙钟准时执行的保证。默认 `preferred` 模式下，持续处理任务运行时停用定位，静音仍可能保留；另有 fallback 模式。展示层另有节流、隐私开关和旧活动清理。

这些是资源所有权设计的参考，不是定位/音频用途合规的证明。Apple 对后台音频、位置使用均有实际功能要求；无需麦克风权限不等于无隐私、耗电或审核成本。dsh-Go 本来已有音频协调器和系统进度卡，因此增强模式独立复用协调器并明确用途与成本，不复制第三方常驻实现，也不新增第二套进度卡片。用户主动授权不等于平台审核认可这种用途，发行渠道仍须独立核对。

### Minis 的进程软预算值得学，但不能接错层

Android `GlobalShellThrottle` 将所有 AI 会话的 shell 入口排成共享队列，以 `/proc` 子孙进程观察控制准入：默认软预算 16，新命令预估 4，排队时每 250 ms 检查。它不是每条命令的硬限制，单命令内部仍能继续 fork；其他 App、孤儿进程和不同 ROM 也使观测不完整。不能把 AOSP 的默认 phantom 追踪池 32 解释成每个 App 各有 32。

若在 dsh-Go 引入，入口必须是 **Node 引擎的 bash/PTY/后台任务派生层**，并按实际基础进程数留余量；只给 Kotlin 的顶层引擎启动加锁挡不住 Ubuntu 内部并发。需要同时处理排队取消、执行超时与排队超时分离、交互终端、子代理和远程主机。本次没有移植这套预算，也没有修改全局 phantom-process 系统限制，更不会在结果不明时重放已经启动的命令。

## 本次实现

### Android：只恢复先前明确启动的引擎

实现入口：[DshService](../../app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/DshService.kt)、[RuntimeController](../../app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/RuntimeController.kt)、[RuntimeServiceRecovery](../../app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/RuntimeServiceRecovery.kt)。

- 明确的启动请求保存非敏感的 `phoneStorage` / `visualReplies`，编码仅含两个布尔值；安全模式和启动方式继续使用已有持久化来源。运行且快照更新已提交时才请求 `START_STICKY`。偏好沿用异步 `apply()`，不让前台通知或停止请求等待磁盘；若被杀时尚未落盘，新进程读不到快照就不启动，不用默认值猜恢复配置。若已有旧快照而新写入/删除尚未刷盘，突然被杀仍可能读回旧的两个布尔选项；这是 best-effort 恢复提示，不是事务检查点。已处理的手动停止由系统服务停止语义阻止重建，但尚未送达的停止请求不能承诺跨崩溃生效。
- 系统用空 intent 重建服务时，只有有效快照才启动；不存在快照就结束。未知 action 不启动引擎，安装不请求自动重建。
- 非空临时 `env` 只留在当前进程，不落盘，也不请求系统重建，避免换一套环境偷偷启动。正常 App 启动默认是空 `env`；用户已有的引擎配置文件不因此复制进偏好。
- 用户停止请求、接受的停止、安装、重置和最终失败撤销恢复快照；旧运行代的自动停止不能撤销新运行。自动停止还校验进程 owner，避免服务重建后代数从头计数导致碰撞。用户通知里的手动停止不受该自动停止隔离影响。
- 不添加开机自启、定时拉活、双进程互保或强停后复活。既有子引擎恢复仍限于就绪超过 60 秒的外部结束，10 分钟最多三次，退避 5/15/45 秒。

这是**重启引擎服务**，不是恢复被杀的 shell 内存或自动续跑对话/手机动作。是否恢复实际调度仍由 Android、用户后台设置和厂商策略决定。

### Android：可选的静音音频与粗略定位

两项默认关闭。由同一前台引擎服务持有资源，不开额外服务；仅在 App 不可见且当前选择本机、当前连接确认仍有运行中对话时启用。使用现有会话事件，每个已就绪连接只读一次初始快照，不轮询；连接失效、切换主机、任务结束、引擎停止或回到前台即释放。仅由系统原生恢复服务、尚无 App 连接时，不启动增强保护。

静音使用本地静态 PCM 循环，不申请音频焦点或录音权限，不把引擎服务冒充为媒体播放。定位只申请粗略位置；Android 10 起还需后台权限，启用时给运行服务加上真实的 location 类型，通过低频定位请求使用它，回调不读取、记录或上传坐标。授权状态和偏好分别显示；关闭开关不代替系统撤销权限。各 ROM 的收益和耗电都须真机验证，开关不能保证抗回收，也不改变原有的重启语义。

### iOS：先拿暂停收尾时间，再排队记录生命周期

[EngineChannel](../../app/ios/Runner/EngineChannel.swift) 原先先排到引擎串行队列，再回主线程申请 `beginBackgroundTask`；引擎队列忙时，申请可能晚于系统暂停。现在在主线程后台入口立即申请，再异步传递后台观察。

该额度只用于记录暂停，不设置 `continued = true`，不伪报前台，不申请新权限。非运行引擎及时释放；旧异步清理只可结束自己捕获的额度，不能结束下一次离前台的新额度。已有前台、生命周期应答和到期释放路径保留。

### iOS：用户可选的增强保护

静音音频和后台定位分别默认关闭，只有用户在后台运行页主动打开后才可使用；位置权限也只在显式操作时申请，不在启动 App 或读状态时弹窗。保护限于本机引擎运行、有本地回合或原生手机任务且 App 在后台。任务结束、引擎停止或关闭开关会撤销；不在空闲时偷偷常驻。定位不保存坐标。

音频复用原有协调器的最低优先级角色，不抢录音、通话、朗读或 PiP；被打断或抢占要停止并撤回音频来源。位置授权被拒、服务关闭或系统失败也不伪报 active。音频、定位、持续处理任务、PiP 各自拥有许可来源，结束其中一种不清掉其它实际仍活跃的来源。设置开关、位置授权和实际活跃状态分别报告；用户随时可以关闭。

该增强模式可能改善旧 iOS 或持续任务未获准时的后台运行机会，但增加电量、位置授权、音频占用和发行审核风险。不能据此保证永久运行、绕过强退、无视系统资源回收，也不以 Live Activity 充当运行证明。

### 鸿蒙：复用真实连续任务 owner，增加主动开关

鸿蒙已有连续任务申请、按任务 ID 停止、系统取消/挂起处理与短时收尾 owner。本次不仿造 Android 服务或 iOS 静音/定位，而是为真实长时任务增加默认关闭的用户开关。仅有当前本机任务、用户开启且系统资格通过时申请；`taskActive` 以系统返回任务 ID 和当前原生 owner 为准。关闭后撤销连续任务，短时暂停收尾保留。

普通权限、受限系统权限/签名 ACL、任务模式支持是不同前提。具备实现不等于获得资格，资格通过也不等于任务已经运行；需要受限签名资格时不能让用户在一个不存在的系统开关里解决。系统拒绝或收回就说明原因并退回暂停/前台/远程方案，不报假成功。

## 验证与未证明的部分

本机只做源码审查、Python AST 语法解析和 `git diff --check`。**未运行 Kotlin/Swift 回归、未构建 App、未取得本次远端 CI 或 Android/iPhone 真机结果**，不据此承诺熄屏时长、功耗或不会丢任务。

已增加/接入的自动检查：

- [Android 恢复策略测试](../../app/android/app/src/test/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/RuntimeServiceRecoveryTest.kt)：快照往返、临时环境、撤销、保存失败和跨代/跨进程自动停止；由现有 Android JVM CI 编译运行。不是完整 Service 生命周期真机测试。
- [iOS 暂停时序夹具](../../tooling/ios/engine-smoke/test-pause-task.py)：抽取真实生产方法，用确定性队列/UIKit 替身验证申请先于排队、到期、回前台、闲置、旧回调和系统拒绝；不能替代 iOS 系统实际授予额度。
- [iOS 生命周期夹具](../../tooling/ios/engine-smoke/test-engine-background.py)：对真实 `EngineLifecycle` 做回环 HTTP 应答，22 步核对 PiP、持续任务、音频、定位四个来源独立授权和撤回；修正过时的初始化、应答结构和前后台断言。
- [iOS 增强保护夹具](../../tooling/ios/engine-smoke/test-background-protection.py)：对生产控制器、音频协调器和生命周期执行系统边界替身检查，覆盖默认关闭、显式授权、后台有任务、结束释放、音频抢占/中断和定位撤回。三份 Swift 夹具接入 [iOS compile](../../.github/workflows/ios-compile.yml) 的 PR 也运行的 engine job。
- [Dart 桥接](../../app/test/runtime/background_protection_test.dart)与[实际页面场景](../../app/test/settings/background_protection_page_test.dart)：区分开启/实际状态、老版本、权限拒绝、异步更新和恢复入口。
- 鸿蒙既有 [资格](../../tooling/ohos/tests/lifecycle-host.test.mjs)、[任务 owner](../../tooling/ohos/tests/transient-task.test.mjs)、[通道](../../tooling/ohos/tests/runtime-channel.test.mjs)回归新增偏好与异步竞态断言，并接入 [主 CI](../../.github/workflows/ci.yml)；CI 先构建测试用 libz 边界，不能省略 addon 依赖。

真机验收应分别覆盖：Android 熄屏/切网、只杀引擎与整个宿主、手动停止后不恢复、安装/重置/临时环境、旧自动停止；iOS 持续任务获准/拒绝/取消/到期、切后台时引擎队列繁忙、回前台再离开、PiP/录音/来电打断。不可用强制停止等价代替普通内存回收。

## 固定来源与许可

仅学习机制并在主仓独立修改，没有合并、cherry-pick 或复制第三方实现。OpenMinis 的 [GPLv3](https://github.com/OpenMinis/OpenMinis/blob/1a71df0f381cefde80bf912b723de6f9831bc177/LICENSE) 与本仓 AGPLv3 的具体移植仍需逐目录核对并保留许可/来源，不因“开源”就免除义务。

- [主仓基线前台服务](https://github.com/ccch1mneyyy/dsh-Go/blob/5996f1dae5e69f542e3b5fc05f1477ef86e14163/app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/DshService.kt)、[iOS 持续处理任务](https://github.com/ccch1mneyyy/dsh-Go/blob/5996f1dae5e69f542e3b5fc05f1477ef86e14163/app/ios/Runner/ContinuedRun.swift)。
- [fork iOS 保活](https://github.com/WhyWhySeeYa/dsh-Go/blob/6c6c3b72852f2bda608c5aed3d337189e24b7ebf/app/ios/Runner/ContinuedRun.swift#L134-L343)、[额外后台声明](https://github.com/WhyWhySeeYa/dsh-Go/blob/6c6c3b72852f2bda608c5aed3d337189e24b7ebf/app/ios/Runner/Info.plist#L7-L17)。
- [Minis Android 服务](https://github.com/OpenMinis/OpenMinis/blob/1a71df0f381cefde80bf912b723de6f9831bc177/src/android/app/src/main/java/com/openminis/app/service/AgentForegroundService.kt)、[全局 shell 软预算](https://github.com/OpenMinis/OpenMinis/blob/1a71df0f381cefde80bf912b723de6f9831bc177/src/android/app/src/main/java/com/openminis/app/sandbox/GlobalShellThrottle.kt)。
- [Minis iOS 后台保护](https://github.com/OpenMinis/OpenMinis/blob/1a71df0f381cefde80bf912b723de6f9831bc177/src/ios/Agent/Background/BackgroundKeepAliveManager.swift)、[独立 Live Activity](https://github.com/OpenMinis/OpenMinis/blob/1a71df0f381cefde80bf912b723de6f9831bc177/src/ios/Agent/Background/AgentLiveActivityManager.swift)。
- Android 官方：[前台服务类型](https://developer.android.com/develop/background-work/services/fgs/service-types#special-use)、[Android 15、target 35 起的 dataSync/mediaProcessing 六小时限制](https://developer.android.com/develop/background-work/services/fgs/timeout)、[Doze 与豁免](https://developer.android.com/training/monitoring-device-state/doze-standby)。
- Apple 官方：[持续处理任务](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)、[短时后台任务](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:))、[后台音频用途](https://developer.apple.com/app-store/review/guidelines/#software-requirements)、[定位用途](https://developer.apple.com/app-store/review/guidelines/#location-services)、[Live Activity](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)。
