# O6 能力清单协议 v1：先行约定

状态：本文前七节保留协议先行约定；第八节记录第二波在基底 `c818155` 上的引擎与纯 Dart 实现及证据边界。本协议不改 `app/lib/runtime/runtime_state.dart`，也不涉及本机正在改的界面。日期：2026-11-02。

## 1. 三层状态

| 层 | 回答的问题 | 信息来源 |
|---|---|---|
| 原生宿主存在性 | 这个 App 构建是否包含可调用的本机运行时宿主？ | 本机提交 e85e2c9 的 `LocalRuntimeState.available`，MissingPluginException 时为 false |
| 引擎连接状态 | 宿主是否启动、HTTP 鉴权是否通过、WebSocket `$events` 是否 ready？ | 现有 dsh_client 连接协议；一次 Node 实例启动不能等价于已连接 |
| 引擎能力 | 这次已连接的引擎实际上能提供哪些执行能力？ | 本文的可选只读接口 |

能力请求失败、404、未知协议版本均不能把 `available` 改成 false。远程主机同样可能提供能力清单，判断必须绑定当前连接，不能用 App 所在系统推断引擎平台。

## 2. 传输

新增可选接口：**`GET /dsh-go/v1/runtime-capabilities`**，返回 JSON，`Content-Type: application/json; charset=utf-8`，`Cache-Control: no-store`。它位于现有 dsh-go bridge 的命名空间，复用现有 HTTP 连接和启动 token 换取的 Cookie，不创设第二套凭据。接口实现放在 OHOS 的 Cordis 插件中，只有鸿蒙运行时或显式仿真才注册；Android 的 bridge 和启动配置不改。

成功返回 HTTP 200。POST 等非只读方法返回 405。必须经过已有 webServer 鉴权及 Origin/Host 路由防护；不能因使用 127.0.0.1 或因为该接口只读就豁免。若现有 guard 尚未就绪，遵循其失败状态，不先提供一个匿名能力端点。

调用时机：连接认证成功且 `$events` ready 后；重连至新引擎后；前台恢复并完成连接重新检查后。v1 不增加推送通道，App 可以在刷新相关页面时重取。能力记录只属于当前连接和 bootId，不跨主机复用缓存。

选用新可选端点的原因：已有 bridge `inventory` 描述客户端模块、slot 占用和 routeGuard，本机执行能力的生命周期与它不同。新端点使旧 App 无需感知，也避免把未识别字段强加到既有响应。现有实现位置：`runtime/bridge/dsh-go-bridge/lib/index.js` 的 `inventory()`、prefix handler；Dart 连接的已鉴权 GET 位于 `packages/dsh_client/lib/src/connection.dart`。

## 3. 字段

除 `v` 外，客户端必须容忍字段缺失。服务端 v1 正常输出下表全部适用字段；无法核实的值明确用 `unknown` 或 null。`supported` 只代表当前引擎已经装配、配置允许并可供调用；文件在包里、配置声明了名字、源码里存在实现，都不足以得出 supported。

通用支持枚举 **Support = `supported | unsupported | unknown`**。未知枚举值、类型不符、缺失均归为 unknown，不能使用 JavaScript/Dart 的 truthy 转换。

| JSON 字段 | v1 类型/取值 | 含义与数据来源 |
|---|---|---|
| `v` | 整数 1 | 线协议主版本；新增可选字段不升主版本 |
| `bootId` | 非空字符串 | 本次 Node 实例生成的随机标识；不含凭据，每次进程重启变化 |
| `platform` | 字符串 | 引擎的实际 process.platform，仿真会明确覆写为 openharmony |
| `arch` | 字符串 | 引擎 process.arch；桌面 x64 仿真不能写成 arm64 |
| `nodeVersion` | 字符串 | 实际 process.versions.node |
| `simulated` | 布尔值 | 是否启用明确的 OHOS 仿真开关；缺失时客户端按未知处理 |
| `shell.kind` | `virtual | system | none | unknown` | 当前注册的 ctx.shell 执行形态；未装虚拟后端时不能报告 virtual |
| `shell.commands` | 字符串数组或 null | 当前后端可路由的命令名；null 表示清单未知，空数组表示确定没有可用命令 |
| `shell.pty` | Support | 是否能创建实际可用的交互终端；虚拟 shell 不暗示 pty |
| `processSpawn` | Support | 是否能创建任意 OS 子进程；worker 线程不等于子进程 |
| `nodeScripts` | `worker | worker-rebased | process | none | unknown` | `node <脚本>` 的实际后端；worker-rebased 的专属 Worker 会重定位公开 cwd/fs 路径，仍不是 OS 进程 |
| `python` | Support | 当前可调用的 Python 运行时；just-bash 可选 wasm Python 未加载时为 unsupported |
| `wasm` | Support | 此实例是否有可用 WebAssembly；jitless 的本次实测为 unsupported |
| `plugins.bundled` | Support | 随包插件是否可由当前 profile 正常发现和加载 |
| `plugins.marketInstall` | Support | 当前策略和安装实现是否允许在线安装；OHOS 第一阶段为 unsupported |
| `nativeModules` | 对象数组或 null | 仅列本运行时允许的原生模块，见下表；null 表示未获得清单 |
| `storage.sessionLock` | `kernel | main-thread | none | unknown` | O3 实际锁范围；临时 JS 锁必须为 main-thread，不能写 kernel |
| `background.policy` | `may-freeze | unrestricted | unknown` | 对当前宿主获准能力的保守描述；未验证授权时不能报 unrestricted |
| `background.computePermission` | `granted | denied | unknown` | 宿主实际查询结果；尚未接原生查询时为 unknown |
| `background.resume` | `reconcile | none | unknown` | 是否已装配 O8 的恢复对账实现；只有设计文档时不能报 reconcile |

`nativeModules` 每一行：

| 字段 | 类型 | 含义 |
|---|---|---|
| `name` | 字符串 | 包或内建模块名，不暴露文件绝对路径 |
| `version` | 字符串或 null | 已知构建版本；未知不猜测 |
| `state` | `loaded | packaged | unavailable | unknown` | loaded 为实际加载成功；packaged 只是已签名随包但未验证加载；unavailable 为明确禁用或加载失败 |

模块名必须唯一。客户端对无法识别或自相矛盾的行保守视为 unknown，不根据“列在数组中”就启用入口。此清单不是 dlopen 权限授予接口；运行时仍由自己的签名分发、允许列表和服务边界实施约束。

`shell.commands` 由 O4 的**同一个实际路由表**生成并用于 bash 工具说明，避免文案承诺不存在的命令。列表只说明命令名，不承诺 GNU Bash/Git 的全部参数、交互语义或外部插件执行能力；O4 说明书列出支持的参数与显式拒绝情况。未实现命令仍按契约返回 127，并提示“这个命令在鸿蒙本机不可用，可以连接电脑执行”。

## 4. 示例（目标形态，不是当前测试结果）

下面假设 O4 已安装并验证四个列出的入口，O3 仍使用临时锁，O8 尚未装配。实际引擎不得复制这份示例作为固定能力响应。

```json
{
  "v": 1,
  "bootId": "runtime-instance-example",
  "platform": "openharmony",
  "arch": "arm64",
  "nodeVersion": "24.22.1",
  "simulated": false,
  "shell": {
    "kind": "virtual",
    "commands": ["bash", "sh", "rg", "node"],
    "pty": "unsupported"
  },
  "processSpawn": "unsupported",
  "nodeScripts": "worker-rebased",
  "python": "unsupported",
  "wasm": "unsupported",
  "plugins": {"bundled": "supported", "marketInstall": "unsupported"},
  "nativeModules": [{"name": "node:sqlite", "version": null, "state": "loaded"}],
  "storage": {"sessionLock": "main-thread"},
  "background": {
    "policy": "may-freeze",
    "computePermission": "unknown",
    "resume": "none"
  }
}
```

## 5. 双向兼容与错误

| 情形 | 约定 |
|---|---|
| 旧 App → 新引擎 | 旧 App 不请求新端点，既有 RPC、ready、inventory 字节与行为不改；执行后端仍明确报告不支持的操作 |
| 新 App → 旧引擎/无此插件 | 404、405 或 501 表示能力协议未知；保留原有体验与按需错误处理，不把所有能力猜成 false，也不判定无原生宿主 |
| 新 App → v1 + 新可选字段 | 忽略未知字段；已知字段照常解析 |
| 新 App → 未知主版本 | 整份能力视为未知，保留连接；不能套用 v1 枚举猜测能力 |
| 已知字段缺失/类型不符 | 该项 unknown；解析不崩溃，其他有效字段保留 |
| 401/403 | 认证或访问拒绝；交给现有连接错误处理，不伪装成旧引擎 |
| 5xx、超时、网络中断、非 JSON | 本次读取失败；与“协议不存在”分开记录，不永久缓存为不支持 |
| bootId 变化 | 丢弃前一实例能力快照和相关暂存状态，按新实例重新查询 |

对于新增且有副作用的 UI 功能，需要已知 supported 才启用；对于原本存在的远程/Android 功能，unknown 延续既有调用及错误展示。明确 unsupported 时隐藏或降级，给出连接电脑执行的替代入口。以上是给本机界面作者的规则，不在本波修改界面。

能力清单是展示与规划信息，不是授权凭证。客户端不能通过回传清单绕过审批、工作区边界、安装策略或执行限制。读取接口不触发原生加载、联网安装、shell 探测等有副作用操作；它汇总已装配服务和已有验证结果。

## 6. 实现验收（下一包）

1. OHOS 仅在服务实际存在时报告对应能力；默认 Node、Android 和未启用仿真的 Linux 不注册此路由或改变原 bridge 输出。
2. 真实 HTTP 测试：已鉴权响应、未鉴权拒绝、错误 Origin 拒绝、错误方法、no-store；不能仅对生成 JSON 的函数做镜像测试。
3. Dart 模型测试：v1 示例、旧引擎、未知主版本、未知枚举、缺失/错误类型、空清单与未知清单的区别；401/403 与404分开。Dart 环境不可用时明确 NOT_RUN。
4. O4 命令表与模型看到的 bash 说明使用同源数据；O3 临时锁不误报内核锁；O7 未编译加载的 .node 不报 loaded。
5. 前台恢复后重新验证连接与能力；O8 状态恢复不是通过能力查询自动触发工具重试。

## 7. 已有证据与未核实前提

证据：本次官方 Node24.22.1 Linux x64 O0 仿真中无 WebAssembly；严格 child_process/dlopen/link 限制及真实 App HTTP/WS 回合已执行。O3b 只读复核绑定 e5502a4c…f26e，确认临时锁限主线程；O5 网络规范缺口仍独立列出，不通过此协议隐去。

本机 e85e2c9 的 available 语义以 ADDENDUM 为依据，本环境未取该分支，不修改它。手机的后台冻结、受限计算授权、平台名和签名模块加载仍需设备验证。协议可表达 unknown，前提被证伪时只调整相应字段与后端，不改变宿主存在性的定义。

## 8. 第二波实现（c818155）

`runtime/ohos/capabilities/index.mjs` 延续已有的只读端点和连接鉴权，`snapshot.mjs` 每次请求读取已安装服务。插件未在普通 Linux/Android 下注册；旧环境变量不能开启。`bootId` 在本模块第一次实际 OHOS/显式仿真装配时生成，在本 Node 实例内保持不变，不依赖 publication 是否已装配，也不包含启动 token。

| 字段 | 当前实现的依据与边界 |
| --- | --- |
| shell | 先检查实际 `ctx.shell`，再读实际 `ctx.subprocess.capabilities`；命令数组与执行器、bash 工具说明使用同一个 commands.mjs。没有 shell 时是 none/空数组；存在 shell 但没有后端声明时是 unknown/null。 |
| processSpawn / nodeScripts / python | 后端声明来自当前已安装的虚拟进程服务。O4 Worker 后继在存在可继承的产品预加载器时为 unsupported/worker-rebased/unsupported；缺预加载器时 nodeScripts 为 none、命令表移除 node。仅有普通工作线程不代表 Node 脚本入口可用。 |
| wasm | 当前实例没有 WebAssembly 时是 unsupported；仅存在对象不证明能编译，保留 unknown。读取不运行任何 wasm 探测。 |
| plugins.bundled | 当前 profile 已组合 bundle，且 loader 存在至少一个未禁用、fiber active 的官方包条目，才报告 supported；证明本 profile 的发现/加载机制已经运行，不保证每个插件功能均兼容。证据不足为 unknown。 |
| plugins.marketInstall | 当前 OHOS 第一阶段策略为 unsupported。O1/O2 的显式安装拒绝另交；能力读取自身不安装包、不修改市场策略。 |
| nativeModules | null。主机尚未提供已签名原生清单及逐模块加载观测，不能把包名、编译成功或 Linux 加载器结果写成设备 loaded。 |
| storage.sessionLock | 新的仅 OHOS DSH diff 在真实 JSONL 实例的 openharmony 锁分支上暴露 main-thread 标记；未安装/缺标记时 unknown。不把 publication 的内核账本锁误作会话锁。 |
| background | may-freeze / unknown / none。无设备后台授权观测，O8 恢复对账未装配；不自动触发工具重试。 |
| publication | 延续 `publication/capabilities.mjs` 的实时 getter；每次 GET 独立快照，包含 atomic 与 systemVersion。未知服务仍是 unknown/null，不运行探测、恢复或写入。 |

`packages/dsh_client/lib/src/runtime_capabilities.dart` 提供只读模型及 `DshClient.readRuntimeCapabilities()`。它不缓存、不轮询，不改变宿主 available 或当前连接状态；调用方在 `$events` ready、重连及前台连接重新验证后显式调用，并把快照绑定当前连接及 bootId。新的 UI 由主线消费此数据。

解析只接受整数 v=1，忽略新可选字段；字段类型/枚举未知不使用 truthy 转换。commands/nativeModules 的 null 与空数组严格区分；原生模块重复名字保守合并成 unknown，无法确定名字的行令清单整体未知。publication 的五种状态和 unknown 独立于 Support 枚举，disabled-after-crash 不推测上次死亡原因。

HTTP 读取复用该连接已注入的 HttpClient、代理/TLS 策略、Host 和 Cookie。`DshConnection.get` 仅增加可选的跳转/正文预算参数，旧调用默认行为不变；新接口禁跳转，正文限 128 KiB，默认期限10秒。404/405/501、有效但未知主版本返回 null；401/403、其他失败状态、非 JSON、无有效版本信封和正文超限均保留类型化异常。relay carrier 无任意 HTTP 路由，返回明确 transport-unavailable，不能混成旧引擎404。

实际 Linux 验证：真实锁定 DSH/Cordis/connection 的四场景 HTTP 集成通过（含真实 SIGKILL 后熔断恢复）；真实 Cordis 平台门控4项、服务快照3项通过；装入此插件后严格 OHOS 仿真五工具完整回合通过。固定官方 Dart 3.11.0 上新增模型/真实HTTP测试及现有相关HTTP回归实际执行，结果与精确补丁哈希由交付报告记录；没有以 JavaScript 替身冒充 Dart。

Android 的选中 DSH diff、pins 和 companion 字节输入与基底一致，构建脚本及版本输入规则未改。真机后台、原生模块装载、SDK/HAP 与手机网络仍未验证；本协议的 unknown 保留这些限制，不用桌面证据消除它们。

## 9. `worker-rebased` 的兼容含义

此值是 v1 的新增枚举项。旧客户端将它读成 unknown，不能当作 none；新客户端的 `RuntimeNodeScripts.workerRebased` 只接受线值 `worker-rebased`，不接受 Dart 拼写 `workerRebased`。原有 worker、process、none 的解析不变。

该后端只执行本地 `.js` / `.cjs` / `.mjs` 文件。专属 Worker 中的 `process.cwd/chdir` 及固定清单里的公开 `fs` / `fs/promises` 路径参数使用调用的工作区；主线程与普通 Worker 不变。原生 addon、`process.binding` 仍看到进程 cwd，交互 stdin、PTY 和 `child_process` 不可用，不能由这个值推导出 OS 子进程或完整安全沙箱。实际语义、测试及已知差异见 [O4-Node-Worker.md](../../../runtime/ohos/process/O4-Node-Worker.md)。

主线 Flutter 界面负责消费新增枚举。本包只交协议与纯 Dart 模型：`app/lib/ui/engine/engine_capabilities.dart` 的穷尽 switch 必须在合入模型时同步增加 workerRebased 分支。精确衔接片段见 O4 文档；模型测试通过不表示尚未更新的整个 App 可编译。
