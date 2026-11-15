# 嵌入层的两项源码修复

`prepare-pasteboard.py` 对固定上游 HAR 应用 `pasteboard-settlement.json` 列出的差分：输入法粘贴 helper 的 Promise 结算（下文大部分）和触感预置效果（见文末「触感预置效果」）。

## 输入法粘贴 helper 的 Promise 结算修复

仓库补丁基底：`56e682bf76368074e14c4d9be02db53cc6616c4b`。状态 **WAITING_ARKTS / NOT_RUN_DEVICE**。本目录提供固定上游 HAR 的三行差分与离线准备器；没有修改原 SDK、`build-hap.sh`、应用权限或 Flutter 平台通道。

### 问题与改动

输入法 `ExtendAction.PASTE` 走 `ListenableEditingState.handleExtendActionEvent → PasteboardUtils.getPasteDataAsync`，独立于 Dart 的 `flutter/platform`。原 helper 在 `new Promise(resolve)` 内的三个失败出口只记日志，没有 resolve/reject：权限结果为拒绝/INVALID/default、权限请求 Promise reject、读取或其后转换 Promise reject。外部操作已结束后，该次 helper 的等待仍没有结算路径。

`pasteboard-settlement.patch` 只在这三个出口、原有日志之前各加一行 `resolve('')`。原来的成功读取、格式转换、日志内容及同步建立请求抛错的语义均保留。空字符串符合原方法“无文本时返回空串”的约定。真实 release HAR 的 `ListenableEditingState` 只在 `if (pasteText)` 为真时调用插入函数，故失败不会把当前选区替换为空字符串；测试执行的也是这个实际消费者与实际 `TextEditingDelta`。

`PlatformPluginCallback.getClipboardData` 的 INVALID_REQ 分支本来已经回 null；这次没有重新绑定或修改它。没有添加 READ_PASTEBOARD，也不能让没有 ACL/用户授权的读取变成成功。原生 PasteButton 面板与平台消息接管不在此补丁范围。

### 固定输入与许可

| 输入 | SHA256 |
|---|---|
| release 外层 ZIP（来源记录） | `20903e3b9197004b0181e3a2acc9243d04e5b10fa63d19453969dfc97dc87e42` |
| 准备器实际输入 `flutter_embedding_release.har` | `b46e5e370827ef0b80b0d25b219e902680a4a0620c6a75fa6b3cef95a36ff15a` |
| 原 helper | `bf5e71746b1168c39993dbfdc80333b8f20f3843430b0f31330a7d8a3316f35c` |
| 修改后 helper | `4f16b6fa39cfc6d668895ce6e01a6faeec250c845feeeac700ba5d3263a84803` |
| 三行差分 | `455d6cba1acd8879f753e3c9aa9fb3992b8bf196cff56ea27812b51e14eafd7e` |

上游标签 `3.47.9-ohos-1.0.0`，Git 提交 `e5f752df3e25ec897da3c98a74bcced7c21b0bd3`，仓库为 [oh-flutter/flutter_flutter](https://atomgit.com/oh-flutter/flutter_flutter.git)。核心 helper 和 PlatformPlugin 与固定 Git 源逐字相同，但整个 HAR 与同标签源码并非全同；因此测试直接读 HAR，消费者的准确 SHA 单独钉在 JSON 中。

本目录 `LICENSE`、`LICENSE_HW`、`LICENSE_KHZG` 原文取自同一提交的 `engine/src/flutter/`，`LICENSE.flutter_har_zip.md` 原样来自 release ZIP。文件 SHA 都在 `pasteboard-settlement.json`。准备器保持 helper 原版权头，复制这些许可材料随产物交付；没有改写许可或把上游代码宣称为本项目原创。

### 准备与接入

```bash
python3 tooling/ohos/prepare-pasteboard.py \
  --input-har /path/to/original/flutter_embedding_release.har \
  --output /new/private/embedding-with-paste-settlement
```

输入 HAR 必须为上述准确字节；准备器同时校验两个修复目标、两个真实消费者、补丁和许可文件，任一不符即退出。输出目录必须不存在，不会原地改原件或已有产物。`git apply` 只对 `/tmp` 内的目标文件私有副本执行，未运行网络操作。

输出目录包含新的 `flutter_embedding_release.har`、与 HAR 每个文件逐字对应的 `package/`、`licenses/`、小差分和 `report.json`。归档所有文件中只有 `package/src/main/ets/util/PasteboardUtils.ets` 和 `package/src/main/ets/plugin/PlatformPlugin.ets` 的内容变化，报告列出全部前后哈希。gzip 时间固定为 0、文件名为空，并记录 Python/zlib 版本；本次同环境重复生成的 HAR 完全一致，SHA 为 `759a836691934a209ee39591fd8b0e25da38a77a330cb52d910d98f8b5f3899a`。

根代理/本机构建方应在自己的新私有构建目录同时使用这个 HAR 与匹配的提取 package，再跑真实 `check-arkts.sh`。这里没有自动覆盖构建下载缓存，也没有改动禁改的生产构建脚本。未完成这一步之前不能宣称应用已经使用补丁。

### 实际验证

```bash
python3 tooling/ohos/tests/clipboard-settlement.py \
  --input-har /path/to/original/flutter_embedding_release.har \
  --node /path/to/node24 \
  --typescript-prefix /path/to/typescript-prefix \
  --output /new/test-output
```

同一份测试针对准确原版和修改版各跑一次：原版 **12/25 通过、13/25 失败**，失败均为“平台 Promise 已返回，helper 未结算”；修改版 **25/25 通过**。测试使用 TypeScript 5.9.3 擦除类型，执行实际 HAR 方法体，权限管理器、系统剪贴板、StyledString、ArrayList 和 FlutterManager 是明确的边界替身；没有申请设备权限或读取用户剪贴板。

断言包括 -1/2/未知/空结果、权限 reject、读取 reject/同步 throw、记录访问/类型查询 throw、传统 HTML 转换 reject；现代读取/HTML 自己已捕获的拒绝保留为控制组。每个病例同时执行实际消费者，失败/空文本时保持原文本、正反向选区、零编辑通知和零 delta；成功文本/HTML/多记录仍按原逻辑替换选区。原 flutter/platform 的 INVALID_REQ 仍只回复一次 null、零读取。

准备器门另实跑：未知 HAR 拒绝且不生成输出、已存在输出拒绝、两次准备 HAR 一致、提取文件与归档一致、只有 helper 内容改变、原输入哈希不变、所有许可原样保留。第一个测试夹具曾把 ExtendAction 误写成连续序号；最终按固定公开 `@ohos.inputMethod.d.ts`（提交 `8a86234f0d542e5062e24e948652f5a484d90904`）校正为 `SELECT_ALL=0/CUT=3/COPY=4/PASTE=5` 后完整重跑，原历史另存，没有将历史范围混作最终证据。

没有新增任意等待超时；若平台自己的请求永远不返回，此补丁不声称能自行结束它。三个事件循环轮转是测试中的有限观测，原版永久缺少结算路径的判断同时来自完整控制流阅读。没有把该次等待悬空夸大成整个输入框或 UI 卡死。

最终门仍为：精确 patched HAR 组合的真实严格 ArkTS、签名设备上批准/拒绝/撤销、Flutter 编辑框与输入法各自的粘贴路径。设备结果、授权可用性、可见 UI 与延迟均未测量。

## 触感预置效果

上游 `PlatformPluginCallback.vibrateHapticFeedback` 对所有触感都用定时马达：`selectionClick` 100 ms、`mediumImpact` 150 ms、`heavyImpact` 300 ms。应用里大多数点按是 `selectionClick`，在 Android 上是短促的 `CLOCK_TICK`，在这里就成了一下长振。`haptic-presets.patch` 把它换成系统预置效果，映射只在这个方法的 `switch` 里一处：

| Flutter | 预置效果 | 强度 | 设备没有该预置时 | 上游 |
|---|---|---|---|---|
| `selectionClick` | `haptic.clock.timer` | 100 | 10 ms | 100 ms |
| `lightImpact` | `haptic.effect.soft` | 100 | 15 ms | 25 ms |
| `mediumImpact` | `haptic.effect.hard` | 60 | 25 ms | 150 ms |
| `heavyImpact` | `haptic.effect.hard` | 100 | 40 ms | 300 ms |
| `vibrate` | `haptic.effect.hard` | 100 | 40 ms | 75 ms |

API 26 的 `@ohos.vibrator.d.ts` 公开的预置只有 `haptic.clock.timer`、`haptic.effect.{soft,hard,sharp}` 和 `haptic.notice.{success,fail,warning}`。文档只说 soft/hard/sharp 的频率高低，没有说强弱：`hard` 自称「较沉重」，`sharp` 用于警示，所以 medium 和 heavy 用同一个 `hard` 靠 `intensity` 分级，不用 `sharp`。设备不支持调强度时按默认强度振动，两者就一样重。**这张表没有上过真机，手感要有设备才能定**；改表要同时改差分、`afterSha256`、`patchSha256`、两个脚本里钉的 SHA、`haptic-presets.mjs` 和 `check-arkts.sh` 的字节码门。

文档建议先查 `isSupportEffect`；同步版本会阻塞主线程，所以用异步版本，每个预置只问一次并缓存，查询失败按不支持处理。权限仍是已声明的 `ohos.permission.VIBRATE`，`usage` 仍是 `touch`，受系统触感开关管控。debug 嵌入不打补丁，仍是上游的长振。

| 输入 | SHA256 |
|---|---|
| 原 `PlatformPlugin.ets` | `6ffecb1d0d5b6b28e1018e9be7d823f7a6ba23d126ca85fc2c442ff97368d1a5` |
| 修改后 `PlatformPlugin.ets` | `938829683d527ce8e0c4f2f76895122c36b0992633596dc0e7b196890e2882a9` |
| 差分 | `0915da9b4618de10276bf7e3828304f7f2bc5e056454e33bd1c3fbc7e6b24dc4` |

验证：`tests/clipboard-settlement.py` 同时跑 `tests/haptic-presets.mjs`，执行 HAR 里实际的方法体，马达是替身：原版 **2/15 通过、13/15 失败**，修改版 **15/15 通过**。`check-arkts.sh` 在 release 下再查打包进 HAP 的字节码：每个触感都走 `vibratePreset`，表里不再自己启动马达，`startVibration` 确实收到 `type: preset`。真机上的手感和各设备实际支持哪些预置均未测量。
