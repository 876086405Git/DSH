# 鸿蒙本机运行时通道约定（P2）

当前增量基底：`2c2e799`。v7 包含 P2 v6、专用输出目录和首次使用原生能力时再加载宿主；详见 [懒加载与实例归属](native-host-lazy.md)。初版约定在 `c818155` 的 ArkTS 实现之前写定；v6 依据追加2/3/4同步目录、重开 App 与托管技能，具体协议见 [P2 v6](runtime-channel-v6.md)。下文 v4/v5 段落保留各版的历史验证范围。

**验证边界：v7 使用公开 OpenHarmony SDK 完成精确组合的严格 ArkTS 编译，0 错误；未在真机核实。** Linux 可以验证协议状态机、日志序号、清单校验与文件更新算法，不能替代 `hvigor`、两种 NAPI 共存及设备生命周期验证。

## 通道与所有权

- MethodChannel：`dsh/runtime`；EventChannel：`dsh/runtime/events`，沿用 Dart 的字段与事件名。
- 模块级控制器持有运行时状态，Flutter 插件重挂只更换接收者；不重新初始化 Node。
- P1 原生模块 `libdsh_host.so` 暴露 `start(options)`、`stop()`、`getState()`、`drainEvents()`。原生队列有界，ArkTS 在启动、运行、停止期间每 100 ms 取一批；不从 Node 线程回调另一个 JavaScript VM。
- 一个 App 进程只允许一次 Node 启动。`stop()` 请求 P1 的 embedder 停止，退出状态要等原生实际完成；不通过杀掉 App、伪造退出状态或卸载 `libnode` 实现 stop/restart。停止不能保证正在执行的工具已经回滚。
- `LocalRuntimeState.available` 仍只表示通道存在。它不表示所有工具、后台运行、原生加载或发布原子性已验证；这些属于能力清单。

## 方法全集

来源：`app/lib/runtime/runtime_bridge.dart` 和 `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/RuntimePlugin.kt`，包含 Kotlin 额外接收的两个方法。已知但未支持的方法返回 `PlatformException(code: "ohos_unsupported", message: 中文原因及替代路径)`；未知方法才使用 `notImplemented()`。

| 方法 | 鸿蒙行为与返回 |
| --- | --- |
| `guestRoot` | 同步返回 Controller 保存的应用 Context 的 `filesDir + '/runtime/rootfs'`，不等清单、安装或 Node，不做文件 IO。 |
| `getStatus` | 返回下述完整状态 map；缺运行时 payload 时仍有原生通道，报告 `notInstalled` 或具体错误，不能伪装正在运行。 |
| `install` | 落地随 HAP 的 JS/JSON/资源文件；同版本、完整文件集合不重写。并行安装返回 `install_busy`；Node 已启动后拒绝修改运行时，要求关闭并重新打开 App。成功返回 null，进度由事件流发送。`dropKept` 仅允许 false/省略，鸿蒙没有 Android 的 reset 保留恢复事务。 |
| `start` | 只接受字符串 env map、`phoneStorage`、`mode`、`visualReplies`。安装未完成、版本不符、载荷不完整均拒绝。只以固定入口启动一次，成功受理返回 null，ready 后才报告 running。运行中重复 start 仍返回 null，状态由 getStatus/事件取得，不第二次启动；退出后返回 `ohos_restart_required`。 |
| `stop` | idle/尚未启动时返回 null；异步准备阶段撤销尚未进入 native 的 start；活动 Node 调用 P1 stop 并返回 null，随后观察 stopping → 实际 exited。手动停止后映射 installed，但 consumed 资格不重置，再 start 要重开 App。原生停止的桌面验证由 P1A 独立报告负责；OH 设备仍待验。 |
| `getLogs` | 字符串数组，默认 500 行，限 0–2000；返回已脱敏日志。 |
| `getLogSnapshot` | `{entries: [{seq, line, stream}], throughSeq}`，默认 300 行，限 0–2000；throughSeq 是同一同步快照的最大已接收序号。 |
| `reset` | 本阶段明确不支持：Android 的 rootfs/keep 语义在鸿蒙无等价实现，不能删除用户数据后只返回成功。 |
| `clearFailure` | 清除 ArkTS 记录的操作错误说明与失败日志；不清除原生真实退出状态，不恢复 Node 再启动资格。成功返回 null。 |
| `failureLog` | 最近一次错误/退出时的已脱敏日志字符串数组。 |
| `lastKnownGood` | 返回 `{available:false, at:null, disable:[], enable:[], changed:[], patchChanged:false, empty:true}`，明确没有已保存恢复点。 |
| `restoreLastKnownGood` | 不支持；尚无鸿蒙安全模式/配置恢复事务。 |
| `safePreflight` | 不支持；不返回空数组冒充已完成安全检查。 |
| `moveAside` | 不支持；不会按 Android `/root` 路径重命名鸿蒙文件。 |
| `setAutoSafe` | 不支持；状态 `autoSafe:false`，不承诺自动重启到救援 profile。 |
| `setDirectEngine` | 不支持；鸿蒙始终为进程内 libnode，没有 Android Direct/PRoot 开关。 |
| `installManagedSkill` | 与 Kotlin 同形的有限请求，固定写 `<guestRoot>/root/.dsh/skills/<四个App技能名>/`；实际 ready、token、grant 与 Flutter owner 同时有效才可写。逐文件原子替换，SKILL.md 最后，不承诺整体回滚；返回 result/current/reason。 |
| `cancelManagedSkill` | 当前 owner 的精确 requestId 取消，返回 null；旧 owner 不能取消新 owner；已提交文件可保留，物理 IO 退出前不释放写槽。 |
| `reopenApp` | 当前 UIAbility 的公开 restartApp，先走已有 stop；目标由系统 abilityInfo 固定，不接受任意 Want。系统失败码与消息回传 Dart；无窗口明确失败，不用 process.exit。 |
| `publishDiagnostics` | 与 Android 返回形状相同：运行时已安装时原子写入 `$DSH_HOME/dsh-app/diagnostics.md` 并返回 `{path,bytes}`；无可写运行时或参数超 256 KiB 返回 null。并发调用按进程内队列串行提交，每次成功提交的文件都是完整的一次输入；后一次允许覆盖前一次。只写调用方提供的已脱敏文本，不采集额外数据。 |
| `storageStatus` | 返回 `{granted:false, permission:false, legacy:false, guestPath:""}`。鸿蒙没有 `/sdcard` 全盘挂载；通过 `dsh/files` 系统选择器导入/导出。 |
| `requestStorage` | 不支持；不申请 `READ_MEDIA`、`WRITE_MEDIA` 或全文件权限。 |
| `openAllFilesAccess` | 不支持；不存在 Android 的“所有文件访问权”页。 |
| `batteryExempt` | 不支持；不能用 false 暗示已检查 Android 电池白名单。Dart 当前仅捕获 MissingPluginException，调用方会收到明确 PlatformException；界面如何呈现由本机负责。 |
| `requestBatteryExempt` | 不支持；不打开猜测的系统设置 URI。 |
| `backgroundSettings` | 不支持 Android 厂商设置协议。 |
| `openBackgroundSettings` | 不支持 Android 厂商设置协议。 |
| `openVendorSettings` | 不支持 Android 厂商设置协议。 |
| `networkMetered` | 使用 OpenHarmony `connection.getDefaultNet()` 与 `getNetCapabilities()`；无默认网络/查询失败返回 null，存在 `NET_CAPABILITY_NOT_METERED` 返回 false，否则 true。 |
| `voiceModelLine` | 不支持 Android 前台服务通知语义；回复/进度通知由独立 `dsh/notify` 通道承接。 |

### start 参数

`env` 不得包含 `NODE_OPTIONS`、`NODE_PATH`、`LD_PRELOAD`、`LD_LIBRARY_PATH`、`DSH_HOME`、`DSH_AGENTS_HOME`、编译缓存目录或宿主内部字段；宿主固定的配置不能由 Dart 覆盖。值不写入日志。`phoneStorage:true` 明确拒绝并提示系统文件选择器，不能静默当作已挂载。`mode:"safe"` 明确拒绝；省略/null/normal 使用正常 profile。`visualReplies` 控制鸿蒙自有托管 AGENTS 里的 dsh-ui 说明，移除托管标记的用户文件保持不变。

## 状态字段

| 字段 | 鸿蒙值 |
| --- | --- |
| `abi` | `arm64-v8a`，与现有 Dart 识别兼容；不将该字符串当作实测 ABI 证据。 |
| `bundledVersion`, `installedVersion`, `dshVersion`, `nodeVersion` | 来自 HAP manifest/成功提交的安装记录；未知为 null。安装中断时不得报告旧记录为可启动。 |
| `phase` | 只用 Dart 现有枚举：notInstalled/installing/installed/starting/running/stopping/error。native 的 exited 不直接透传：手动 stop 完成后是 installed，意外退出是 error。 |
| `baseUrl`, `token` | 只取原生 ready/state。退出后清空；token 只在状态通道传递，不进入日志、磁盘或说明。 |
| `managedSkillGeneration` | 实际 ready 且当前 Flutter owner 有效时的正安全整数 grant；此前、stop、退出或 detach 后为 null。重挂引擎授新 grant；Ability 变化不退休 owner。 |
| `error` | 稳定错误码和不含凭据的说明，成功时 null。 |
| `mode`, `safeState`, `safeReason`, `strikes`, `autoSafe` | normal/off/null/0/false。 |
| `failure`, `mainFailure`, `healthyAt` | 无已核分类时 null；不把任何非零退出猜成 Android 的某一种 fatal 分类。 |
| `networkBlocked`, `networkBlockedAt` | false/null；此字段原为 Android 厂商封网观测，本阶段不宣称已提供鸿蒙观测。 |
| `directEngineEnabled`, `directEngineAvailable`, `directEngineActive` | false/false/false，避免把“进程内”偷换成 Android Direct。 |
| `directEngineFallbackReason` | null。 |
| `currentExecutionMode`, `launchSelectedMode` | 启动前 null，真实原生受理后 `ohos-embedded`。 |
| `launchSpawned` | 原生 Node 启动已受理时 true；字段沿用 Dart，但文档明确没有子进程。 |
| `launchFailureReason` | 原生拒绝/退出错误码或 null。 |
| `tidyingFiles` | false；不执行 PRoot 硬链接整理。 |

## 事件与日志

- `status`：`{type:"status",status:上述 map}`；订阅时立即给一个状态，状态变更再推送。
- `progress`：`{type:"progress",step:"extract"|"verify"|"configure",done,total}`。extract 表示本次需落地的文件字节数；复用已核文件不会虚增写入量。
- `logs`：`{type:"logs",entries:[{seq,line,stream}]}`，stream 为 stdout/stderr/system。序号在本 App 进程中单调递增，订阅/取消订阅/clearFailure 不归零。
- `notice`：明确用户可操作的文字；不把凭据混入通知。
- 先订阅再取快照时，Dart 已按 `seq > throughSeq` 去重；ArkTS 侧快照与序号必须在同一个同步函数中取得。
- 日志环只保留 2000 行，单行限制由原生和 ArkTS 共同执行。吞吐超限必须有丢弃提示，不能无限攒入内存。

## 文件落地与更新

运行时代码在 HAP `resources/rawfile/dsh-runtime/files/`，清单为 `dsh-runtime/manifest.json`。原生 ELF（libnode、宿主、flock、loader）只能按本机工具链的 ABI 结果进 HAP `libs/arm64-v8a/`；本安装器不会把 `.so`、`.node` 或 ELF 文件复制到可写数据目录来绕过系统加载政策。原生模块映射未完成前，不把 JS 已落地等同于引擎可启动。

清单固定版本1，包含 runtimeVersion/dshVersion/nodeVersion 与按相对路径排序的 `{path,size,sha256}` 列表。路径不得绝对、含 `..`、空段、反斜杠或 NUL；拒绝重复/前缀冲突、原生载荷及指向外部的链接。固定布局为 `node_modules/@deepseek-ai/dsh/lib/bin.js`、`runtime/ohos/preload.mjs` 及其依赖目录；宿主唯一 preload 不能由清单另行注入。

实现采用**固定代码目录、安装归属记录、逐文件原子替换**：开始前原子持久写入 installing.json，其中保存当前与历次未完成安装的 ownedPaths/stagingHashes；先按深路径优先清理本版已退役的登记文件和空祖先目录，遇到当前版本需要的目录则保留，未知内容不递归删除。逐个核已有文件的 size/SHA256，相同则复用，不重复读取 HAP 内容；变更文件从 RawFd 的 `{fd,offset,length}` 分块读出，写同文件系统的 staging 临时文件，核摘要后 rename；最后清理登记的临时文件、提交安装记录并清掉 installing 标记。任何中断都保留“待续装”状态，start 必须拒绝；换 HAP 版本后也继承未完成事务的归属记录，再按新版本清单续装。这样升级只写变化部分，不承诺旧版本即时回滚，也不在已经启动过 Node 的 App 进程内换代码。

`guestRoot = context.filesDir + '/runtime/rootfs'`；`HOME`、`DSH_HOME`、`DSH_AGENTS_HOME` 分别为其下的 `root`、`root/.dsh`、`root/.agents`，唯一 workspaceRoot 为 `root/workspace`。交付文件放 `root/workspace/DSH-Go`；缓存仍放 `context.cacheDir`。`rootfs` 只是目录名，没有 Linux guest。运行时代码仍在 `context.filesDir + '/dsh-runtime/tree'`，不在 workspaceRoots 中。任何安装/首次启动的目录创建失败均明确失败，不回退到 `/` 或 `process.cwd()`。

## 公开 API 依据与设备待验

- OpenHarmony `interface_sdk-js` 的 `@ohos.file.fs.d.ts`：open/read/write/fsync/rename/lstat，ReadOptions.offset 是文件偏移。
- `@ohos.resourceManager.d.ts`：getRawFd 返回 HAP 描述符及资源 offset/length，须以 closeRawFd 关闭，不能直接把整个 HAP fd 当作单个 rawfile 复制。
- `@ohos.file.hash.d.ts`：hash(path, "sha256")。
- `@ohos.net.connection.d.ts`：默认网络、能力列表与 NOT_METERED。
- 来源：https://github.com/openharmony/interface_sdk-js/tree/master/api 。仅核公开签名，不复制其他移植项目实现。实际构建须以本机 API 26 SDK 为准。
- Flutter 通道核对的是项目固定 `oh-flutter/flutter_flutter` 修订 `e5f752df3e25ec897da3c98a74bcced7c21b0bd3`：`MethodCall.argument(key)` 无泛型；`FlutterPluginBinding.getApplicationContext()` 返回应用 Context；StandardMessageCodec 支持 Map 及普通对象。本实现发送 Map；注销时仅给公开允许null的MethodChannel和BinaryMessenger传null，不向非空的EventChannel.setStreamHandler参数传null。

设备须验证：rawfile 压缩情况下的 RawFd 行为、安装中断恢复、ELF 实际加载路径、真实启动与退出不带走 App、后台恢复后事件队列、重新挂接 Flutter、日志/凭据脱敏，以及选择器导入文件后的工作区边界。


## 终态轮询的读序（P2 v4）

Controller先getState，再记录已知凭据用于脱敏，再drainEvents，处理该批日志后才按先前快照收束。P1B在同一锁内发布终态与exit事件，而且此前已等待stdout/stderr读取线程排空；因此读到终态后取队列会包含所有尾部事件。若先前读到的还是非终态，即使随后Node退出，也保留下一轮轮询，不能用比刚取批次更新的终态提前停止。

v3的反例为drain返回旧批次之后原生线程完成尾日志和exit；随后getState看到终态并停timer，failureLog缓存缺尾。手工第二次collect虽补recentLogs，却不能纠正已按相同终态缓存的failureLog。独立评审用实际P1B HostCore/NAPI/原生线程复现，本修订另用确定性的边界夹具做先失败后通过回归。没有增加定时器频率、任意sleep或“再排一次”的次数猜测。

## 原生库目录与真实依赖文件名（P2 v5）

本版是以 c818155 为基底的完整替换补丁，取代编号11的 v4（及更早P2），不能在旧完整补丁上再叠加。v4 的终态读序和回归全部保留。

### 可信安装目录接线

新增 `HostOptions.nativeLibraryDir`，只来自当前应用 Context：`bundleCodeDir` 是安装代码根，`applicationInfo.nativeLibraryPath` 按文档是相对此根的安装库路径，但 HarmonyOS 7.0.0.111 真机给的是此根下的绝对路径（`/data/storage/el1/bundle/libs/arm64`），所以以「根 + /」开头时先去掉这个前缀，再按相对路径检查。`resolveNativeLibraryDir` 要求根是非根绝对路径且无 NUL；相对路径可去一个末尾斜杠，随后不允许空分量、`.`、`..`、NUL 或前导斜杠。错误返回 `ohos_native_library_path`，不回退硬编码的 `/data/...`，不消耗唯一 Node 启动机会。

显式设置 `module.json5` 的 `extractNativeLibs:true`、`libIsolation:false`，让固定两库使用同一已解压的安装目录；具体 HAP 布局仍须主线核验。P1B v2 必须接收这个必填字段，canonicalize 并检查目录、固定 `libdsh_require_builtin.so` 和 `libdsh_flock.so` 为普通非链接文件，再写受保护的 `DSH_GO_OHOS_NATIVE_LIBRARY_DIR`。本 ArkTS 部分不自行 dlopen、不把 ELF 拷进可写 rawfile 运行时、不代替 C++ 的真实文件校验。已有 env 校验拒绝全部 `DSH_GO_OHOS_*`，包括此字段，不能由 Dart env 覆盖。

公开依据固定为 interface_sdk-js `8a86234f0d542e5062e24e948652f5a484d90904` 的 [ApplicationInfo](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/bundleManager/ApplicationInfo.d.ts) 与 [Context](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/application/Context.d.ts)。[MainThread](https://raw.githubusercontent.com/openharmony/ability_ability_runtime/OpenHarmony-v6.1-Release/frameworks/native/appkit/app/main_thread.cpp) 实际拼 `LOCAL_CODE_PATH + nativeLibraryPath`，文件 SHA256 `fa2073829e92d5a66bd8d32b85d9235e37591abaa062120e3432c0786fed6d24`；[固定 ContextImpl](https://raw.githubusercontent.com/openharmony/ability_ability_runtime/8222796f651bb5c19a91dbf927795ceb149c0e97/frameworks/native/appkit/ability_runtime/context/context_impl.cpp) 的普通自有 Context.GetBundleCodeDir 返回同一根，SHA256 `eb4ec82bc1ec88ca260c380677fb99caa5cab5412f1e497231fe8802a410c537`。这支持拼接关系，不能代替目标设备值测量。

### `.node.js` 是普通 JavaScript

O2 真实锁定组成中包含 `node_modules/@deepseek-ai/dsh-api-gateway/lib/client.node.js`。旧的扩展名规则错误地把名称中间的 `.node.` 当作原生文件，阻止完整载荷安装。本版只拒绝终端 `.node`、`.so`、`.so.<数字版本链>`（忽略大小写），允许普通 `.node.js`；**ELF magic 拒绝保持原样**，即使 ELF 伪装成该 JS 名也不能提交到运行时代码目录。没有通过删除真实依赖或改名 JS 绕过问题。

已保存两个先失败反例：v4 未传 nativeLibraryDir；旧路径规则拒绝真实依赖的文件名。最终 Linux 完整 **23/23** 通过，包括原20项、Context 路径分量及失败后可再启动、真实名称的普通 JS 落地/版本化 so/伪装 ELF、实际 SIGSTOP/SIGKILL 安装恢复与 v4 终态尾日志。系统 Context、资源管理器和 native 启动仍是明确替身；文件字节操作与杀进程真实执行。API26 ArkTS/hvigor、P1B v2 目标 ABI、HAP 和设备仍为待验门。
