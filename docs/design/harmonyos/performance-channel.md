# 鸿蒙 `dsh/performance` 通道

本次收束基于 `530f183906be2a218b1b09000400e01c9a572dba`。三份性能产品模块保持原检查点字节，补入 EntryAbility 的唯一插件注册；不依赖包 37 或 NativeHost。Android、Dart、偏好存储、启动参数和权限没有改动。当前作者状态为 `CANDIDATE / WAITING_EXACT_ENTRY_ARKTS / NOT_RUN_DEVICE`。

## 实际消费者及行为

`app/lib/performance/performance_state.dart` 先调用 `dsh/performance.snapshot`，再订阅 `dsh/performance/events`。`PerformanceSnapshot.fromMap` 把 device map 当作“读取已完成”，按 sequence 忽略旧结果。`PerformanceDefaults.resolve` 确实用 tier 和 thermal.lightweight 控制默认轻量模式、模糊/动画、自动启动本地引擎与远程推荐；显式偏好继续由原 Dart 逻辑决定。因此这不是一组没有消费方的诊断字段。

| 输出 | 来源和限制 |
|---|---|
| `device.totalMemoryBytes` | 公开 `hidebug.getSystemMemInfo().totalMem`（KB）乘 1024；无能力、失败、零或非安全整数返回 null |
| `device.tier` | 按 Android `PerformanceRules.classify` 的门槛：已知低于 5 GiB 或不超过 2 核为 low；不低于 5 GiB、至少 4 核、屏幕支持 90Hz 及以上为 high；其余为 medium 默认，不是跑分 |
| `device.cpuCores / availableProcessors` | 公开 `process.ProcessManager.getSystemConfig`，即系统 libc 的 `sysconf`（`_SC_NPROCESSORS_CONF` 83、`_SC_NPROCESSORS_ONLN` 84）；失败或超出 1 到 128 返回 null |
| `device.supportedRefreshRates` | 公开 `display.getDefaultDisplaySync().supportedRefreshRates`（API 20），Android 没有这个键；失败或没有声明时为空数组 |
| `device.lowRam / mediaPerformanceClass` | null；不把 Android 专有事实映射成未知 OH 数值 |
| `device.apiVersion` | 公开 OH `deviceInfo.sdkApiVersion`，使用独立键，不填 Android `sdkInt` |
| `thermal.status / level` | OH 的八级 COOL、NORMAL、WARM、HOT、OVERHEATED、WARNING、EMERGENCY、ESCAPE，明确 `platform:'ohos'` |
| `thermal.lightweight` | WARM 或更热立即 true；COOL/NORMAL 持续 30 秒 active uptime 后才 false |
| `thermal.supported / listening / listenerError` | 系统能力、注册 API 返回情况、固定错误分类；没有把 Linux 替身注册当作设备已收到回调 |

5 GiB 和 30 秒都是既有产品策略值，不是本轮测量结果。Android 的 high 还要求厂商声明 media performance class，鸿蒙没有对应物，这里用屏幕声明的刷新率代替，90Hz 这个门槛是判断不是测量。OH API 号不参与 tier。Dart 和 Android 都只问 tier 是不是 low，所以 high 目前只影响诊断里的描述，真正改变行为的只有不超过 2 核这一条。未知内存或核数的 medium 是原消费者的保守默认分类，不是硬件性能已确认的结论。新通道也不把 NODE_OPTIONS 填成 Android 的内存策略，因为嵌入 Node 的启动约束由宿主负责。

## 帧缓存

`setFrameCache {enabled}` 把设置 → 性能里的「帧缓存」写给 `FlutterManager` 列出的每个 `FlutterView`。引擎默认开：多缓存一帧换帧率切换时的顺滑（`vsync_waiter_ohos.cpp` 的 `target_time` 加 4 ms）。开关留给真机对比，判断不了就不猜。

默认开所以启动时只有存过「关」才发。Dart 启动早于窗口（`FlutterAbility.onCreate` 里就跑 Dart，`onWindowStageCreate` 才建 view），选择会留在模块里，由 EntryAbility 在建好 view 后再写一次。

## 热状态与生命周期

公开 OH 声明把 WARM 描述为需要停止或延后部分非感知服务；当前产品在 WARM 起进入轻量默认。ESCAPE=7 同样保持轻量，不能复用 Android 0–6 的范围检查而漏掉它。未知数值、读取失败、时钟不可用均不能作为降温证据。

计时来自公开 `systemDateTime.getUptime(TimeType.ACTIVE)`，排除深睡时间，不使用可跳变的墙上时钟。重复的冷事件不会延后已开始的 30 秒窗口；重新升温清空窗口。在截止点再次读取当前 thermal.getLevel：缺少事件、未知值或读取失败都不能依靠旧冷样本恢复。观察中断时取消定时器并清空冷窗口；重新订阅需要新的完整窗口。

实际核对了固定 OpenHarmony 6.1 的 `powermgr_thermal_manager` commit `db69b3c9b9313f24d38d2ae497e8c338e4b22e2d`：`frameworks/napi/thermal_manager_napi.cpp` 使用 thread_local 的单个 ThermalLevelCallback。注册会先释放旧 JS callback，注销同样清空这个引用。因此同一 Entry 的多个 Flutter 引擎插件不能各自注册、各自注销。

本实现只持有一个模块级订阅，再向当前 observer 集合分发。最后一个插件解绑才注销；旧 binding 的迟到 detach/cancel 不影响新 binding。最后观察者移除后不保留恢复定时器或旧插件 observer。注销 API 抛错时保留那一个注册的所有权，后续插件可复用，snapshot 报 unregister_failed；不会当作已释放后再堆积第二个订阅。成功注销的旧回调由 registration generation 隔离。

`onListen` 立即交付当前 snapshot/sequence，闭合方法答复到事件订阅之间的热状态变化窗口。设备事实每个插件首次实际 snapshot/listen 才读一次，单纯构造和 onAttachedToEngine 不探测磁盘、不开 Node、不读设备 API。没有顶层 libdsh_host.so 导入。

## 接线

Entry 注册 `new PerformancePlugin()`，并在 `onWindowStageCreate` 里补上帧缓存；不需要 Ability、前后台或权限钩子。公开 OH imports 与 DSH NativeHost 无关。Diagnostics 后继可复用 `OhosDeviceFacts.ets` 的无标识信息 helper，但不能借此改动本检查点冻结字节。

## 已执行验证

16 项执行实际 ETS 方法体，覆盖内存单位/阈值、未知/超范围内存、八级热状态、30 秒恢复、重复冷样本、截止重新升温、未知/失败读取、墙时钟跳变、active clock 倒退、多个引擎共享订阅、snapshot/listen 间隙、迟到回调/解绑、能力缺失和注销失败恢复。OH 传感器、时钟与 Flutter 是显式替身，未伪称真实设备温度。

生成的八个 wire 样本又用 Dart 3.11.0 直接 import 未改 `app/lib/performance/performance_policy.dart`，验证 loaded/available、tier、轻量模式、blur、自动启动默认及 full 模式仍受热保护。不是重写一份客户端解析器。三产品模块另经 TypeScript 5.9.3 与固定公开 OH `.d.ts` 检查零诊断；严格 ArkTS 门仍由精确 Entry 组合执行。

公开 API 声明来自 `interface_sdk-js` commit `8a86234f0d542e5062e24e948652f5a484d90904` 的 `@ohos.hidebug`、`@ohos.deviceInfo`、`@ohos.thermal`、`@ohos.systemDateTime`。thermal NAPI 原文件 SHA256 `c281d47a11a9284969f763365326087e0a5da89bae88537579f47162176d5c64`，原字节和 URL 在交付包 inputs。它仅作行为证据，没有复制进产品。

运行：`python3 runtime/tests/ohos/performance-linux.py --node <Node24> --dart <Dart3.11> --typescript-prefix <TypeScript5.9.3前缀> --out <新证据目录>`。具体工具、命令、源码哈希、原始日志和消费者样本见交付包。


## 530 基底的收束边界

本包产品方法体与 `logs/arkts/integrated530-archive-life-hms-01` 的实际 44 源编译输入逐字相同；该组合的真实严格 ArkTS 结果为零错误。它包含其他通道的非官方 HMS 占位声明，不是本包独立 Entry 后像的编译记录，更不证明 HMS SDK 或设备功能。新主补丁和顺序增量的 Entry 后像各自记录摘要，需由集成者针对准确组合完成公开 SDK 严格编译；独立审查状态单独报告。

主补丁可直接应用于纯 530。`feature-only.diff` 是交付说明指定的已有生命周期组合上的顺序增量，与本功能主补丁二选一。性能的 `OhosDeviceFacts.ets` 和 `OhosThermalState.ets` 为共享辅助模块，Diagnostics 后继应复用相同字节。实际命令、公开来源原文、当前重跑日志及历史缺陷前像见交付包，不以作者检查点代替独立 PASS。
