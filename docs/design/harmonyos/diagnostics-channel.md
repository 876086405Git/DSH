# 鸿蒙设备诊断与持久引擎日志

本次完整交付的基底为 `530f183906be2a218b1b09000400e01c9a572dba`。`dsh/diagnostics` 的实际 Dart 调用方是 `app/lib/diagnostics/diagnostics_channel.dart`，诊断 ZIP 收集器优先调用 `engineLog`，空结果才回退内存日志。本实现保留这个协议；诊断增量没有修改 Dart 或 Android。

**作者状态：候选；精确补丁待独立审查，设备 NOT_RUN。** 三个诊断模块与已有完整组合保持相同字节，本次补齐最终单归档调用方和最小 EntryAbility 接线。作者执行实际 ETS 方法体、Linux 文件描述符和原版 Dart 消费端；公开声明语义检查不是 ArkTS。精确最小组合的 `check-arkts.sh` 结果与输入身份随交付保存，不能借其他组合的编译结果或作者结果宣布整个包 PASS。

本次最小组合实际公开 SDK 检查位于 `logs/arkts/diagnostics-release530-01`：24 个输入、hvigor exit 0、错误/工具错误/未编译均 0，自家警告 157、依赖警告 359；HMS 占位开关为 0。唯一工程为 `check-Iw3eygnr`，源码前后摘要、诊断来源路径和 HAP 内/提取后的 ABC 一致。它是普通严格 ArkTS 检查，没有完整 Flutter AOT/native `--full` 装配、签名或设备运行的结论。

## 接线与依赖

主补丁可直接应用于纯 530，已经合入单归档完整包 42 的必要前置；它是重新比较基底与最终源树得到的完整 diff，不是把重叠补丁直接拼接。已有精确 42 主补丁 `5a9d6775d71da197e92827113c7b20cc720495f76b4c24e51297ddbf9dc5fb0b` 时，只应用交付中的 `diagnostics-only.diff`。两条路线后像相同，不能叠用本功能主补丁和增量。

本包包含 `plugins/OhosDeviceFacts.ets`，SHA256 为 `fa4bb43b0ce81876ffafe5d43e3a0a50cb5036aec3adcce91c305636aef8dfe0`。它与 performance 候选共享相同字节，诊断只依赖这个 helper，不依赖 `OhosThermalState` 或 PerformancePlugin。已有 performance 的组合不能重复应用新增文件 hunk，也不能覆盖已有 Entry；应核实相同 SHA 后复用该文件，并按两个插件各自最小注册改动合成 Entry、对最终组合重新编译。交付记录给出准确注册前后像和组合约束，未声称一个 feature-only 补丁可以自动适配任意 Entry。

EntryAbility 在 42 的生命周期接线后像上仅增加 import 和 `new DiagnosticsPlugin()` 注册，由现有 Flutter `AbilityAware` 绑定提供字号配置。原 RuntimeController 的前台、后台和销毁回调完整保留。插件构造、attach、`PersistedRuntimeLog.get(filesDir)` 及 `facts()` 均只操作内存，不读取运行时清单、不探测磁盘、不导入 `NativeHost` 或 `.so`。只有明确的诊断查询才读取公开设备 API、单归档内清单或日志。

最终 RuntimeController 已接线：`collect()` 把 **`RuntimeLogs.append()` 已经返回的条目** 交给下列 API，再发送既有内存日志事件；没有把 native 原始事件行直接落盘。首次观察到退出或错误终态时异步请求 `flush()`；失败只记诊断持久化状态及明确提示，不把 Node 终态或整个 UI 变成同步磁盘等待。

```typescript
const disk = PersistedRuntimeLog.get(context.filesDir);
disk.append(batch); // batch: RuntimeLogEntry[]，已经过 RuntimeLogs.append
// 仅在日志生产者已停止时，明确等待持久化：
await disk.flush();
```

`getStatus`、`guestRoot`、只用远程主机的路径不调用 `flush()`，也不做同步磁盘探测。日志 helper 与诊断插件共享同一 ApplicationContext 的 `filesDir`；若误传不同根，明确失败，不悄悄切换日志文件。rootfs、DSH_HOME、workspace 与 path_provider 不参与这个路径决定。

## 两个方法

| 方法 | 输出与来源 | 缺失时 |
|---|---|---|
| `info` | `app/device/manifest/voice` 四个 map | 单项公开 API 不可用时省略对应事实 |
| `engineLog({maxBytes})` | 读取实际文件中的完整 UTF-8 行；默认 512 KiB，限制在 1 KiB 至 4 MiB | 文件不存在返回 `[]`；权限、类型、读取失败返回 `failed` |

每个插件实例最多一个异步查询，重入返回 `busy`。完成时先释放 busy 再回复，避免紧接着的下一次调用误判仍忙。旧 Engine detach 后的异步回复只报告 `detached`；它不能清掉新 Engine 的 busy 状态。底层 Flutter 传输抛错不会触发第二次回复。

`app` 只含公开 self BundleInfo 的版本名/版本号及日志状态。`device` 使用公开 manufacturer、brand、model、OS 版本、OH API 版本、ABI 列表、内存、应用目录可用存储及屏幕尺寸/密度/字号比例。内存来源的 KB 按 1024 换算，存储按字节除以 1024²；只接受安全的非负或正整数。没有序列号、UDID、广告标识等唯一标识。OH API 26 写作 `apiVersion`，绝不放进 Android 的 `sdkInt` 或 `android` 字段；不虚构当前 HAP ABI、CPU、Android low-RAM 等事实。

`manifest` 经 `OhosRuntimeStorage.readBundledManifest()` 从唯一资源 `dsh-runtime/runtime.zip` 读取 Stored 首成员，再由真实 `RuntimeCore.validateManifest` 验证；没有继续读取旧裸 `dsh-runtime/manifest.json`。仅输出 runtimeVersion、dshVersion、nodeVersion、文件数和声明的非压缩字节总数。归档清单限额为 16 MiB，诊断另要求版本字符串最多 128 字符；这里没有实测磁盘占用的含义，也不输出校验和、文件路径、环境变量或启动参数。诊断只读清单，不安装运行树，也不解压每个 payload 成员。`voice` 返回空 map，不为了诊断加载 HMS 识别器或读取音频/转写。

现有 Dart `NativeDiagnostics` 会保留这些通用 map 字段，实际消费者测试已验证。现有 Markdown 环境行的 `_android` 仍只渲染 Android 字段，因此 OH OS/API 事实会保留在诊断 JSON，而不会自动显示在该 Markdown 位置；本补丁未改变 UI 或假填 Android 字段。

## 持久日志边界

固定文件为 `<filesDir>/dsh-runtime/engine.log`，轮转为同目录的 `engine.log.1`。这是应用私有 files 目录，不是可被清理的 cache。正常由本 helper 维护时，每个文件最多 1 MiB、两文件最多 2 MiB。遇到已经存在的超限 current 文件会拒绝继续写，读取仍有字节上限；不会把异常旧文件自动清空。

待写队列最多 256 KiB；正在写入的单批最多约 256 KiB 加一行省略标记。过载丢弃最旧的待写条目，后续写入明确的省略数量。只有一个串行文件操作队列，不按每条日志建立无限 Promise 链。写入处理真实短写，逐批 `fsync`，成功后关闭描述符。`flush()` 成功表示在该次等待中已排空的批次完成了 fsync/close；持续生产日志会延长等待，所以调用者应先让生产者静止。

写入或 fsync 失败后按本批开始位置截断回滚，失败批以省略标记计数。若截断或关闭也失败，helper 保留该 FD 的唯一所有权，下次操作先重试清理；不会假装已经释放。fsync 已成功但 close 失败的批次不重新写、不计作丢失。这个共享所有权让全新 DiagnosticsPlugin 实例也能触发恢复，不依赖已注销旧插件的私有通道。

进程可能在短写中结束：下次写之前只丢弃旧文件没有换行结束的后缀，避免和新日志拼接。读尾部按实际 UTF-8 **字节** 限额，丢弃被切断的首行和没有换行结束的末行，先旧文件后新文件。读取排在当前文件操作之后，不无限等待活跃生产者的整个待写队列；它返回文件中已存在的完整行，不用内存快照冒充持久内容。

文件槽以 NOFOLLOW、NONBLOCK 打开并实际 fstat 为普通文件；目录本身拒绝符号链接。读写失败都会尝试关闭持有 FD。这里使用可信 Context 私有目录，未声称抵御其他同 UID 原生代码在检查后替换任意父目录的攻击；用户 workspace 没有写这个目录的授权。

这里没有目录 fsync、事务日志或掉电恢复协议。应用崩溃前仍在队列/短写中的尾部可能丢失；轮转也不能保证掉电后两个名字的原子持久顺序。`facts()` 的 pending 字节、省略计数、最近持久化错误和 `flushRequiredAfterProducerStops` 明确说明这条边界。不能将它描述成崩溃前的完整引擎日志记录。

## 脱敏与实际证据

真实 `RuntimeLogs.append` 先替换 URL token/key、Authorization、常见 key/token 键及 `rememberSecret()` 已记录的值，再截断长行。持久 helper 只接收其输出，保留 Dart 导出端已有的第二层打码。测试实际调用这个原实现，检查写出的文件字节不含测试 token，并在另一个真实 Node 进程读取相同文件；新进程内存日志为空、PID 不同、磁盘行仍在。此证据限于已有打码规则，不宣称正则能识别任何未知凭据。

作者实际运行记录包含：

- 26 个实际 ETS/Linux FS 用例：原 24 个无 IO 构造、真实清单校验、脱敏、过载省略、串行并发、轮转、中文 UTF-8、短读/短写、半行恢复、写入/fsync/截断/关闭故障、跨插件恢复、符号链接/FIFO/目录、绑定取消及紧接着查询；另两项直接执行最终 RuntimeController，验证只落脱敏条目、退出尾部与持久化失败状态。
- Python 分别启动的 write/read 两个真实 Node 进程，验证进程结束后仍读取磁盘日志，不依赖同一模块内存。
- 原版 `diagnostics_channel.dart` 六个消费者断言；只为 Flutter MethodChannel/Provider 提供显式 API 替身，没有 Flutter Engine。
- 固定公开 OH 声明、TypeScript 5.9.3 检查当前诊断依赖图；加入单归档后为七个实际模块。全局 `canIUse` 与 Flutter 桥接口在该辅助检查中显式声明，不能把这项结果当作 ArkTS 或设备执行。

第一轮实际方法测试为 22/24：一个暴露 busy 释放时序，已修复；另一个是此执行器禁止 Node 子进程创建，`mkfifo` 辅助器不可运行。最终由 Python 在同一测试文件系统真实建立 FIFO；Node 的 node:test 在进程内执行，所有原断言保留。原失败日志也保留。

## 公开 API 来源与待验证项

固定 `openharmony/interface_sdk-js` 提交 `8a86234f0d542e5062e24e948652f5a484d90904` 中的 [file.fs](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@ohos.file.fs.d.ts)、[file.statvfs](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@ohos.file.statvfs.d.ts)、[bundleManager](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@ohos.bundle.bundleManager.d.ts)、[display](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@ohos.display.d.ts)、[Configuration](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@ohos.app.ability.Configuration.d.ts) 是接口依据；完整九文件 SHA256 清单随交付证据保存。设备/内存 helper 的来源另见 performance 包。

精确 Entry/Controller 组合的真实严格 ArkTS 及补丁独立审查结果见交付证据；设备上仍须验证实际 filesDir、OH FS flags/错误码、权限缺失行为、退出/重开、后台写入以及 fsync 带来的耗时和功耗。Linux FD、普通编译 HAP 和公开类型结果不能替代这些设备事实。诊断增量没有新权限、第三方依赖或顶层原生宿主导入。
