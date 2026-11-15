# HMS 分享发起与接收

**状态：UNCOMPILED_HMS，未在真机核实。** 本实现依据共享目录 `hms-contracts.md` 的 A/B 合约；没有取得正式 HMS SDK 声明。Linux 的真实文件测试证明协议、状态和复制逻辑，不能证明实际系统面板、URI 授权或目标应用行为。严格 ArkTS 检查必须在本次组合上使用 `check-arkts.sh --hms-stubs`，其非官方声明也不能代替 HMS SDK 编译。

## 基底、依赖与文件归属

- 基底：`530f183906be2a218b1b09000400e01c9a572dba`；共享 ZIP SHA256 `ddbc4f5662bb1f1fc853612809a58bc1dc1e58c5207c73d251e50e23a88bd802`。
- 使用基底已有 P2 的 `RuntimePaths.ets`。工作区从 ApplicationContext 的 `filesDir` 派生为 `runtime/rootfs/root/workspace`，不读取 Dart 传来的根目录。纯基底主入口包含37的懒加载前置，已应用37时使用互斥的 feature-only 入口；各精确 SHA 与后像见交付清单。
- 原生 `openUserFile(root, relative)` 来自基底宿主，逐层 `openat`、拒绝符号链接、仅返回普通文件 FD。分享只消费它，不修改 NAPI、CMake、Node 或 Android。
- `HmsSharePlugin.ets` 和 `HmsShareInbox.ets` 是两个 HMS 适配文件；`HmsSharePolicy.ets`、`HmsShareStorage.ets` 只使用公开 OH/Flutter 接口。
- EntryAbility 新增 `onCreate`、`onNewWant` 转发及插件注册，保留父类调用与已有插件。与 WebFiles 包组合时必须保留 WebFiles 的 import/注册，两者没有互相取代关系。
- module 只增加独立的 `ohos.want.action.sendData` skill。保留530基底已有权限与 `compressNativeLibs:true`，不新增存储权限、FILE_ACCESS_PERSIST 或 `shareFiles` 配置。

## 发起通道

`dev.fluttercommunity.plus/share` 的 `share` 与锁定 `share_plus_platform_interface 7.2.0` 的 `MethodChannelShare` 对接：读取 `text`、`uri`、`subject`、`title`、`paths`、`mimeTypes` 与 `originX/Y/Width/Height`，返回原始字符串。原 Dart 消费端、`ShareParams` 和文件生成方式不改。

| 输入/结果 | 本实现 |
| --- | --- |
| 纯文字 | 一个 `general.plain-text` record，内容放 `content` |
| `uri` | 只接受完整 HTTP(S) 链接，作为 `general.hyperlink.content`；不把远程链接塞入文件 `uri` |
| 一个文件 | 安全 FD 读取，复制进 `filesDir/dsh-share-out/slot-*`，调用 `fileUri.getUriFromPath`，SINGLE |
| 多个文件 | 每个一个文件 record，BATCH；不把独立纯文本 record 混入 BATCH |
| 文字加文件 | 文字放第一个文件 record 的 `description`；目标是否展示须真机确认 |
| MIME/后缀 | 先查公开 UTD 的 MIME 映射，再查后缀；未知 `flex.*` 回退 `general.file` 是产品选择，匹配能力待实测 |
| 锚点 | 有有效矩形时，用公开 Display 的 `densityPixels` 换算像素，传 `windowOffset`/`size`；Flutter 坐标与窗口关系待真机核实 |
| 已观察到 `shareCompleted` | 返回其非空 `targetAbilityInfo.name`；它表示平台提供的完成事件，不承诺目标应用最终发送成功 |
| `dismiss` 先到、引擎/Ability 失效、无法辨认的结果 | 返回 `dev.fluttercommunity.plus/share/unavailable` |
| `show()` 成功 resolve | 不结束回包，也不释放面板占用；此 Promise 没有用户结果 |
| 构造/监听/show 失败 | 返回明确平台错误；不以成功或 cancelled 掩盖 |

不依赖事件先后，不设置延时来猜测取消，所有路径最多尝试回包一次。实际 Dart 中空串代表 dismissed，哨兵代表 unavailable，其他串代表 success；这里没有足够证据时不会返回空串。

### 逻辑回包与物理面板的两个生命周期

模块级唯一 `ShareLease` 覆盖准备文件和显示面板两阶段。准备中取消立刻结算旧回调，但要等实际 IO、临时文件清理收束后释放。显示中即使已收到 completed、Flutter 引擎已更换或 Ability 已解绑，也保留 lease，直到实际 dismiss 或 show 明确失败。新实例不能绕过旧面板另开一个。旧插件的迟到 detach 不能退掉新引擎；旧事件不会覆盖新请求。

已退休回包通道如果抛错，不得阻止面板释放；回包尝试不会重试到新 Flutter 通道。没有公开的物理关闭 API 时，若平台永远不送 dismiss、show 也不失败，lease 将继续占用，后续请求明确报 busy。此行为避免把未知状态当作面板已关闭；实际设备是否丢失 dismiss 是待验项。

### 发出文件预算与保存

输入源只允许本机工作区、ApplicationContext 的 cacheDir/tempDir，以及当前分享租期所属 UIAbilityContext 的 cacheDir/tempDir。两个Context有不同作用域，不能要求目录相同；锁定的 path_provider 在 attach Ability 后从其 context 返回临时缓存路径。发出暂存仍位于 ApplicationContext.filesDir，不随源目录改变。禁止把 DSH_HOME、agents 目录或任意应用私有路径直接作为源。路径比较只负责选择可信根，最终路径和链接约束由原生 opener 执行；末端和父目录符号链接拒绝。

旧530候选只允许 ApplicationContext 缓存，独审用实际 PathProvider 方法、真实文件和原生 opener 复现：相同目录控制打开面板，不同HAP缓存的真实导出文件却返回 outside_workspace。修订只把已绑定租期的 Ability context 传给 outgoing/openLocal，增加其两个可信根；原 active 回调仍在异步原生加载后检查租期，新实例不能借旧 Ability 继续打开文件。未扩大到 Ability.filesDir 或任意 HAP 目录，也没有读取 Dart 提供的根。

每次最多 500 个文件；**本机暂存合计最多 300 MiB**，与现有远端 artifact 的单文件上限对齐，但它是本实现新增的每批总预算，不是 HMS 文件大小限制。元数据本地限 180 KiB，为平台 200 KB（含 Want）的预算留余量，平台最终错误仍须正常处理；预留并不构成对任意 Want 开销的证明。

每个操作只用 256 KiB 读块，处理短读、短写、零进展、大小变化与中途失效；输入 FD 和输出 FD 均在 finally 关闭。复制前后大小相等不证明任意同大小并发写的一致快照，本机工作区同一文件被其他任务改写时仍应重试。

发出暂存不会在 completed/dismiss 时立即删除，因为授权持续时间和目标何时读完没有公开保证。后续新分享开始时保留最近 4 个已结束批次及当前活动批次；当前批最多使正常保留数为 5。该缓存保留策略不承诺任意久之后的目标读取，必须测目标应用交接时间。清理失败不影响本次分享，可能留下旧缓存，不能宣称磁盘绝对上限。创建/清理目录检查符号链接，但不是面对同 UID 恶意进程同时替换应用私有目录的无竞态文件系统服务。

## 接收通道与 Ability 生命周期

`dsh/share` 实现 `ready -> true`，然后按顺序推送 `share`：

```text
{
  text: string | null,
  subject: string | null,
  files: [{path, name, mime: string | null, size}],
  skipped: [{name: string | null, reason: too_large | unreadable | too_many}]
}
```

这是实际 `IncomingShare.parse` / `NativeInbox` 消费的形状。所有 Map 通过 Flutter StandardMessageCodec 编码；文件路径是应用自己的副本，不把外部 URI交给 Dart 长期持有。

EntryAbility 在 `onCreate` 和 `onNewWant` 立即转发实际 Want、LaunchParam；仅 `launchReasonMessage === 'ReasonMessage_SystemShare'` 才调用 `getSharedData`。普通启动不读分享数据。无论解析成功或失败都不调用 `terminateSelf`。已有 FlutterAbility 冷 attach 只给插件 launchWant，缺少首次 LaunchParam，所以不靠插件读 launchWant 推断来源，也不在 onForeground 重复读取。

独立 skill 的 `maxFileSupported` 明确为：general.text 为 1，general.image/general.object/general.file 为 9。同时注册 general.file 是合约建议；非预置类型的系统匹配能力待真机实测。

### URI 获取、复制与限额

每个合法接收 Want 立即调用 `getSharedData`。返回记录后，批内前 9 个文件 URI 一起请求只读、NONBLOCK FD，不让后面的授权等待前一个文件复制完。随后逐个有界复制到 `cacheDir/dsh-share-in/slot-*`。权限是否有效由系统 `fs.open` 实际结果决定，没有自己伪造授权或依赖 undocumented Want 字段。

外部 URI 只接受 `file://<非空外部 authority>/...`：拒绝空 authority、自身 bundle 及其子 authority、HTTP、控制字符、无效百分号转义和解码后 `.`/`..`。这是一层输入限制，实际 provider/URI 授权仍由系统实现，本地夹具不能证明跨应用隔离。

普通文件才复制，FIFO 用 NONBLOCK 打开后立即按类型拒绝；每文件 30 MiB、每批 60 MiB、最多 9 文件、文本最多 200000 UTF-16 单元，数值来自 Kotlin SharePlugin。超量按 Dart 已有错误名跳过。中文/特殊字符名限制在 240 UTF-8 字节，保留短后缀；没有 title 时使用公开 FileUri.name，因此 `.dshgo` 路由后缀不会退化成 `shared`。图片当前按原字节复制，不执行 Kotlin 的压缩/旋转/HEIC 转码；后续图像处理不能计入本包验收。

最多 4 个读取批次同时进行，冷启动队列最多 8 个已接受 arrival。超出部分合并成一个 too_many 提示，不把外部记录无限积存。已接受的 arrival 维持顺序，即使后一个文件先复制结束也不会越过队头。队列属于 Ark 模块，不属于一次 Flutter attachment：引擎重挂继续保留，ready 先应答再发送。普通 detach 不撤销外部已到达的合法分享。

尚未交付 Dart 的暂存批受保护，不会被最近 4 个历史缓存的回收策略误删。交付使用现有 MethodChannel 的一次发送方式；无 Dart 持久确认日志，不能声称进程崩溃或通道发送后重启场景的持久 exactly-once。外部 `open/getSharedData` 若迟迟不返回，保留其有界容量直到平台收束，不使用超时来假装取消已完成。

## 真实 Linux 验证与平台边界

执行 `runtime/tests/ohos/hms-share-channel.test.mjs`。测试对真实产品 ETS 做 TypeScript 擦除，文件操作落到真实 Linux FS，`openUserFile` 调用基底 C++ helper 编成的真实 Node addon；只替换 Flutter、HMS、Display、UTD/FileUri 的平台边界。HMS 模拟事件不是华为平台实现。

当前36项实际通过：原33项包括两个事件顺序、重复/迟到事件、show resolve 不结束、四种失败点、跨插件实例 lease、迟到 detach、准备 IO 取消、已退休回包通道、真实短读短写、私有路径/父末符号链接拒绝、稀疏超量文件、真实 60 MiB总量、真实 FIFO 无写方、源文件真实变长、冷队列乱序完成、8批文件回收保护、分配失败关闭全部 FD、中文 .dshgo 文件名与预算边界；后加的真实懒加载迟到取消1项保持原断言。两个不同Context用例在旧方法体上为35/36，修后36/36，验证两种缓存/临时目录和工作区可分享，同时兄弟目录、私有files、穿越和符号链接仍拒绝。原独立PathProvider探针另按原字节重跑通过。以上都是Linux边界验证，未把替身面板称为实际HMS面板。

保留前像：首个测试夹具的旧面板等待条件挂起后单独修正；随后 27 项中 4 失败，3 项是产品逻辑缺口（新插件接管、无 title 名称、ready 顺序），1 项是夹具只等 FD 关闭却未等目录清理结束。三个产品修复与夹具修复分开说明。新增退休回包通道反例先实际失败，再修正通过。旧失败日志与源码摘要不覆盖。

## 仍须本机/设备核实

1. `check-arkts --hms-stubs` 在本次完整组合中零错误及所有相关模块确实进入 abc；再用正式 HMS SDK 对无 stub 产品编译。
2. ShareKit 可用设备的 canIUse、真实面板 show、completed/dismiss 两种顺序及无事件场景。
3. completed 的目标名称及其与实际目标发送成功的关系；不升级本实现语义。
4. SINGLE/BATCH、多文件真实传递、description 的文本保留、未知 UTD / general.file 的匹配。
5. 真实文件 URI 授权、cache/temp 来源复制、发出文件交接读取时刻、跨批保留策略。
6. 冷启动/已有 singleton onNewWant 的真实 LaunchParam，系统选择器是否把应用列出；普通启动绝不结束主 Ability。
7. 外部 docs/media/应用文件 authority 的授权读取、拒绝自身 URI、文件被撤权/删除时的真实错误；Dart 读应用副本。
8. Display 比例、Flutter sharePositionOrigin 与系统窗口锚点在手机/平板/折叠屏上的对应。

## 来源

- 用户共享 `hms-contracts.md`，SHA256 `7818839b0c232288505ad12ad1c8fb20982b926d0a5e02532dae3f6c5f877b55`，A/B 逐条列出处；这里采用其能力接口，事件取消语义遵守追加5及用户后续要求。
- 官方引用入口：[systemShare](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/share-system-share)、[接收应用](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/share-interface-description)、[应用文件分享](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/share-app-file)。本轮网页抓取只得到导航/超时，没有把它冒称为已取得完整官方 SDK 声明。
- 锁定 `share_plus_platform_interface 7.2.0` 官方 pub 包，tar SHA256 `365ef7379fc22507256adda3385152942ffce08935452bc972c2e52a0bebae41`；`lib/method_channel/method_channel_share.dart` SHA256 `1dc5959408b2e31d1aece604f680f76892a77a0fd12b7b228b72e0319b4c332b`。
- 同仓 `app/lib/links/{share_intake,native_inbox}.dart`、Android `share/SharePlugin.kt`/`ShareNames.kt`、`app/lib/state/artifact_files.dart`。
- 固定公开 OH API 声明归档 `interface_sdk-js` commit `8a86234f0d542e5062e24e948652f5a484d90904`；FileUri、fs、Display、UTD 是公开接口，HMS 不在该归档中。
- 已有 Flutter 源树 commit `e5f752df3e25ec897da3c98a74bcced7c21b0bd3` 的 FlutterAbility，源 SHA256 `90bca5103daec3e1dfda923dd57f9880e9f4b691acf4c4f81eae733829aa2997`。正式检查还须使用 check-arkts 固定 release embedding，以该编译结果确认生命周期覆盖签名。
- [OpenHarmony 应用沙箱目录](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/file-management/app-sandbox-directory.md)，2026-11-02读取：ApplicationContext 对应应用范围，UIAbilityContext 等对应HAP范围；目录必须取自Context属性，不手拼平台沙箱根。固定 `path_provider 2.1.6-ohos.2` 的 `PathProviderPlugin.ets` SHA256 为 `2f83e9198c035b9b3c9a1947fd759296e7445dc82d75d22065a2b99f8a74023d`，独立反例实际运行该方法体。
