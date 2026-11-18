# 931 App → Node Linux 控制合同 v1

状态：930固定入口与931扩展的 ETS / Dart / Node 同步合同，wire版本保持1，旧版本缺少新增可选观察字段时保留null。依据为 705、829 的单开关/独立实例/事实分离要求，以及 922 中实际 `connection`、917 owner、914 backend 接缝。本文定义 **930 新增、931扩展的协议**，没有声称此前已有 Linux RPC 或 NativeHost 方法。

## 1. 固定入口与可信输入

- HTTP exact route：`/dsh-go/v1/linux`，只允许 `GET`、`POST`，不得带 query。使用已有 NativeHost 提供的 IPv4 loopback baseUrl / launchToken，复用现有 token→cookie 握手和 `connection.requestRejection(req)`；鉴权在解析 body 或作任何操作之前。
- 唯一 host preload 在插件前捕获 `DSH_GO_OHOS_LINUX_DIRECTORY` 和 `DSH_GO_OHOS_NATIVE_LIBRARY_DIR`。前者由 `HostOptions.linuxDirectory = filesDir + '/linux-tools'` 固定发布。缺失/非法路径是不可用，不能读取 config、argv 或后续 env 补值。
- assets 仅从当前模块所在 runtime 的 `runtime/ohos/linux/assets/` 固定目录加载。仅有库或目录存在都不表示已打开 guest。`GET` 不读 manifest、不探测文件、不联网、不导入原生库、不创建 owner。
- Node 的 Linux service 装入实际 OHOS `SubprocessRuntime`。940 起同一个 LinuxControl 也是 `CommandRouter` 的 Linux 后端（agent 的 gh/python3/pip 等与插件进程），见 [ROUTING.zh.md](ROUTING.zh.md)；本控制入口的字段与语义不变，只是 `runPrivateGuest` 与这些命令共用客体唯一的作业通道（忙时同样 409 `ERR_OHOS_LINUX_BUSY`），开关 false 与最终停止也会取消正在跑的路由命令。

## 2. POST 精确字段

各 body 均为 JSON object，`Content-Type: application/json`，UTF-8 body 最多 65,536 bytes，body 到达限时 10 秒；未知字段、重复语义、类型错误、NUL argv/env 等拒绝。JSON 重复字面键受 JSON.parse 的最终值规则，不另建自定义 JSON parser。

每种 body 必须携带 `v: 1`、`instanceId: string`、`attemptId: string | null`。两种身份必须等于当前 `GET` 的值；否则 `409 ERR_OHOS_LINUX_STALE`，不执行任何动作。`instanceId` 是此 service 在本 Node 生命期生成的 UUID；第一次显式启用创建 `attemptId` UUID，本期不允许静默换新 owner。

### 开关

```json
{"v":1,"instanceId":"<GET返回>","attemptId":null,"action":"setEnabled","enabled":true}
```

成功接受返回 `202` 和完整状态对象。第一次 true 后后台加载固定 manifest，按可信持久记录选择首次下载/安装或同一数据盘的直接恢复；`202` 仅表示接受。已开启期间的再次 true 只复用同一个健康 owner/backend。false 立即关闭准入；已有 backend 时进入与最终 `shutdown` 相同的屏障，异步 terminate 并等待本 service 的未结局 private/routed job，再等 guest close 与真实 native join。完成后为 stopped，restartRequired 为 true；再次开启须退出并重新启动整个 App。false 在安装中取消安装并收尾；本期取消/失败的安装 owner 不重建，再次 true 明确报错并要求退出并重新启动整个App；保留数据仍须满足干净恢复条件。请求断连或 HTTP 超时不等于 false。

### 明确的私有 guest 运行

```json
{"v":1,"instanceId":"<GET返回>","attemptId":"<GET返回>","action":"runPrivateGuest","requestId":1,"argv":["python3","-c","print(1)"],"cwd":"/workspace","env":{},"stdin":""}
```

成功接受返回 `202` 和完整状态对象。一时只允许一个未结局 job；忙时 `409`。`requestId` 是正的 safe integer，须精确等于 GET 的 `nextRequestId`。同当前 job.id 的同一规范化请求仅返回原 job；同号异参或比当前号更早的请求返回 `409 ERR_OHOS_LINUX_REQUEST_REUSED`，绝不再次执行。最后一个请求的摘要、最后一个 job 和一个单调计数即可完成去重，无无界任务表。调用方先 GET，固定该 requestId，网络失败后仍用原号查询/重试，不能自行换号重做。

`cwd` 必须显式精确为 `/workspace`，绝不替换宿主 cwd。`argv` 为 1–128 个无 NUL 字符串，首项非空，单项 ≤ 8,192 UTF-8 bytes，合计 ≤ 24,576 bytes。`env` 可省略，最多 64 个键，键须匹配 `[A-Za-z_][A-Za-z0-9_]*` 且 ≤ 128 bytes，值为无 NUL 字符串且单值 ≤ 4,096 bytes，整个 JSON env ≤ 16,384 bytes。`stdin` 可省略，UTF-8 string ≤ 16,384 bytes。

backend 不再隐式继承宿主环境，仅提供客体 PATH/HOME/TMPDIR/LANG 默认值；其他变量须由调用方显式提供。代理变量仍按下述当前模式生成逐作业快照，其中 inherit 保留既有活动代理与父代理别名的来源。显式 env 按既有 subprocess 契约可显式提供凭据，但不影响已捕获的宿主路径，也不自动回显/写日志。这里只开放 batch stdin + stdout/stderr 各 16,384 bytes 尾部 collector，没有 pipe/PTY/宿主目录/grant/spill 配置入口。`graceMs` 固定为 10,000，不由 App 自选。取消本期唯一当前 job 使用 `setEnabled(false)`，同时关闭准入；GET 观察 cancelRequested 和真实 settled/unknown。

### 私有作业代理

```json
{"v":1,"instanceId":"<GET返回>","attemptId":null,"action":"setProxy","proxy":{"mode":"direct"}}
```

`attemptId`仍携当前GET的原值。`proxy.mode`为`inherit | direct | manual`；前两者只允许mode，manual另允许`httpProxy`、`httpsProxy`、`noProxy`字符串，各最多4096 UTF-8字节且至少一个HTTP(S)代理URL非空。HTTPS代理缺省时沿用HTTP代理。成功返回202与状态；配置只在本Node会话内，App重启后调用方需重新注入。

同一规范化配置不递增revision。配置可在作业运行时改变，但只影响后续新requestId；原号同参重试先去重，仍返回原作业。manual/direct不允许作业env再携任何代理别名，否则400 `ERR_OHOS_LINUX_PROXY_ENV_CONFLICT`。inherit保留既有活动策略、父环境及显式env优先级；revision只反映setProxy配置，不是外部策略的完整版本，也不是跨客户端租约。

App的HTTP localhost/127.0.0.1代理映射到TinyEMU宿主端10.0.2.2；其他127/8、IPv6 loopback和HTTPS loopback明确拒绝。合并gitee.com及huaweicloud.com直连项，保留整值`*`的客户端语义。控制HTTP本身不走该代理。完整别名、地址、错误码、传输范围和实际客户端验证边界见同目录`PROXY.zh.md`；不影响App归档下载器或全部插件路由。

### 删除保留数据（重新安装 Linux）

```json
{"v":1,"instanceId":"<GET返回>","attemptId":"<GET返回或null>","action":"discardRetained"}
```

保留实例无法恢复（下文 §4 的各类拒绝）时唯一的出路，由 App 在用户确认「重新安装 Linux」后发送，没有其他字段。与其他 POST 不同，它在删除完成后才回复：成功为 `200` 和完整状态对象，`lastErrorCode` 清为 null，开关保持关闭，不会自动开启。删除不需要 VM，只用文件系统和锁：取同一个根 `.lock` 的真实 `flock`（被占用为 `ERR_OHOS_LINUX_BUSY`），按 `openLinuxInstance` 同样核对根与锁的规范路径、FD 身份和私有权限，把除 `.lock` 外的每一项先在根内改名为 `.discard-<随机>` 并同步根目录，再逐项删除（目录递归删除不跟随链接，其余一律按名字 unlink，不打开也不跟随）并再次同步。根目录和 `.lock` inode 保留，下一次启用就是全新安装。删除中途崩溃留下的 `.discard-*` 只是垃圾：`openLinuxInstance` 持锁后先删掉它们再判断有无保留数据，绝不把它们当实例恢复。

只在本 service 没有进行中的安装/关闭/删除、没有作业或路由命令、不在最终停止、且开关关闭（或安装已以 failed/unavailable 结束）时受理，否则 `409 ERR_OHOS_LINUX_BUSY`；最终停止开始后为 `ERR_OHOS_LINUX_CLOSED`。本进程的 owner 若曾创建 native VM，或其退役未确认、状态为 unknown，则 `409 ERR_OHOS_LINUX_RESTART_REQUIRED`：数据可能仍被占用，须退出整个 App 后再删。未曾创建 VM 且已确认退役的失败尝试在删除成功后被丢弃，`restartRequired` 随之恢复 false，同一进程内再开启即全新安装；这是“失败的安装 owner 不重建”的唯一例外，前提是该尝试从未持有 native 资源。删除本身失败时 `lastErrorCode` 为其错误码，数据可能已部分删除，再次删除会继续。删除进行中 `setEnabled(true)` 为 busy，`setEnabled(false)` 无动作，`shutdown` 等它结束后才收尾。

### 最终停止

```json
{"v":1,"instanceId":"<GET返回>","attemptId":"<GET返回或null>","action":"shutdown"}
```

立即关闭准入并返回 `202` 和完整状态对象，后台取消并等候当前 job，再调用同一 owner 的 dispose。重复调用复用同一 promise，不重启收尾。App 必须 GET 轮询，只有 `shutdownComplete: true` 且 `retirement.resourcesRetired: true` 才能确认可继续 nativeStop；`202` 和请求成功均不表示该屏障已完成。失败后状态中的 UNKNOWN、native 退休证据仍保留。HTTP 超时不取消此过程，绝不可将 socket close / Node exited 当 native joined。

`shutdownComplete` 仅表示没有 native owner，或 native joined=true 且 retirementError=false、相关资源退役已确认；它不把历史 job UNKNOWN 改成成功。已发布的可写 instance 保留，因此 `filesRemoved:false` 可与 `resourcesRetired:true` 同时成立。App 在 nativeStop 前必须取得该确认；若状态仍 unknown，须保留结果并明确呈现，不可写成任务成功。

## 3. GET / 成功 POST 的状态对象

下列为状态的基础形状。控制层不回显宿主路径、原始错误message/cause、配置环境、argv或代理凭据。任务自己的stdout/stderr仍是原始字节，任意程序可能自行输出敏感内容；因此测量CLI在代理或账号env回合主动省略输出原件，而不能把整个GET泛称为无敏感信息：

```json
{
  "v":1,
  "instanceId":"UUID",
  "attemptId":null,
  "persistentInstanceId":null,
  "bootMode":null,
  "nativeMemoryRelease":null,
  "proxy":{"source":"inherit","revision":0,"httpConfigured":false,"httpsConfigured":false},
  "state":"disabled",
  "enabled":false,
  "admission":false,
  "guestOpened":false,
  "ownerRetained":false,
  "workspaceLease":false,
  "restartRequired":false,
  "shutdownComplete":false,
  "nextRequestId":1,
  "ownerState":null,
  "backendState":null,
  "progress":null,
  "lastErrorCode":null,
  "job":null,
  "retirement":null
}
```

- `state` 为 `disabled | installing | enabled | disabling | stopping | stopped | unavailable | failed | unknown`。后端真实 `quarantined` / closed fault 和 job UNKNOWN 优先派生 unknown，不能只读可能陈旧的 owner.state=active。`enabled` 是用户请求的开关值；`admission` 仅在同一实际 opened backend 健康且不在关闭过程中时为 true。
- `guestOpened` 来自当前 backend 的实际状态，普通关闭进入最终屏障后，在 backend 真正关闭前仍可 true；不代表生产每任务授权、宿主 workspace、PTY 或所有插件命令就绪。
- `ownerRetained` 只表示 service 仍持有同一 owner 对象；不是“完整 VM 内存已释放”的反义测量。`ownerState`、`backendState` 是既有状态字符串或 null，状态源必须真实。
- `progress` 为 `null` 或 `{stage:string,done:number|null,total:number|null,step:string|null}`，只有固定/有界阶段与计数，不含文件名/URL。观察回调异常不得改变安装成败。
- `job` 为最近一个 job，接受新 job 才替换已结局记录；UNKNOWN 不允许被新 job 覆盖。最多一个 active job，不维护无界历史。

```json
{
  "id":1,"state":"queued","started":false,"cancelRequested":false,"proxyRevision":0,
  "outcome":null,"errorCode":null,"diagnostic":null,
  "stdout":{"encoding":"base64","data":"","totalBytes":0,"retainedBytes":0,"truncated":false},
  "stderr":{"encoding":"base64","data":"","totalBytes":0,"retainedBytes":0,"truncated":false}
}
```

`job.state = queued | running | settled | unknown`；started 仅在 backend handle.started fulfilled 后 true。`outcome` 是 914 的真实 `{exitCode,signal,cancelled}`，必要时带 `notStarted:true`、`requestedSignal:'SIGTERM'`，没有预测性补零。UNKNOWN 保持 outcome=null。流数据是复制出的已收到 raw bytes 的 base64 尾部，totalBytes 与 retainedBytes 分开；上限固定，GET 不消费数据，也不把 UI 接收作为 guest sink ACK。

`proxy`只投影上述四个安全字段，不携URL、凭据或NO_PROXY原串；示例中的两个false以没有当前活动/父代理为前提。direct必须两个false，manual至少一个true。`revision`与job接收时固定的`proxyRevision`均为非负safe integer；当前proxy可以已变化，不能据它推断历史job未用过代理。旧版本未提供这些可选字段时保持未知。

`retirement` 为 null 或 `{resourcesRetired:boolean,filesRemoved:boolean,dataRetained:boolean,ownerQuarantined:boolean,native:null|{joined:boolean,retirementError:boolean|null,apiResult:number|null},releaseErrorCode:string|null}`。真实未 join 可为 `{joined:false,retirementError:null,apiResult:null}`，不得因 `!null` 或默认 `0` 而升级为已退休；有 native 时仅 `joined === true && retirementError === false` 可确认退休。只输出已观测字段，native 缺失时为 null，不补造 joined。将同 owner 资源退休与 job 结局分离。

## 4. 错误与并发

错误体为 `{"v":1,"error":{"code":"ERR_...","message":"HTTP标准短语"},"status":<当前完整状态>}`；鉴权拒绝不附 status。400/413/415 为请求问题；409 为 stale/busy/disabled/failed/unknown 等拒绝；shutdown 已受理但未确认只在 GET 状态中报告，不能把 202 当完成；503 为缺 connection 或可信 host path。仅在首次显式启用后才可能发现 assets 缺失，此时后台状态 `unavailable`。

setEnabled(true) 在 installing 时为幂等保持；setEnabled(false) 在 disabling 时同样保持，不重发 cancel；在 disabling 完成前 true 拒绝 busy。shutdown 一旦开始不可重新开启。不存在自动换号重试、后台重建或每任务grant已完成的声明。931在新的App进程中仅按当前可见且完整合格的clean持久记录恢复同代数据盘；该记录的生成路径要求本epoch的guest syncfs和native成功退役。旧v1、dirty/booting、资产变更或身份错误明确拒绝并保留，不自动重装覆盖；用户确认的 `discardRetained`（App 的「重新安装 Linux」）是删除它们的唯一途径。正常shutdown后退出整个App再开与突然杀进程/掉电恢复是不同范围。

## 5. 需要联测的实际边界

1. 真实现有 BrowserAuth + HTTP route，鉴权前无操作，GET 无 owner/native/下载调用；runtime / attempt stale 不运行。
2. 通过真实 SubprocessRuntime 注册 route；唯一 preload 在插件前捕获可信路径，插件修改 env 后不能重定向目录/库；worker 不注册第二 owner。
3. 实际 914 socket protocol：opened→执行→双 EOF/ACK→完成；active 后真实 socket 断流→GET unknown，后续 run 拒绝，shutdown 后不改写 job UNKNOWN。
4. off→terminate 请求→真实 waitForExit→guest close→join→stopped；同一 owner/session 创建与 join 计数各 1，再次 on 明确拒绝并要求重启 App。
5. 安装 progress observer throw 不破坏安装；安装 cancel 的真实边界与已发布 dataRetained / native joined / filesRemoved 区分。
6. 真实 RuntimeController stop/reset 必须等上述 shutdownComplete，HTTP 失败或 UNKNOWN 未确认不能先 nativeStop/reset。此项由 root / 独审实现验证。


## 6. 931持久身份、干净关闭与内存

`persistentInstanceId`为已安装数据的UUID，`bootMode`为`install`或`resume`；安装选择尚未成立时两者均null。它们不等于本Node服务的`instanceId`或当前尝试`attemptId`。每次VM启动都有新随机epoch，不能复用旧生命周期的closed帧。恢复固定直接引导target，绝不重走bootstrap安装配置。

`retirement.guestClose`只有当前fulfilled backend.dispose带来的`{epoch,rootfsSync:true,syncMethod:'syncfs',syncScope:'rootfs'}`才成立；closed必须在实际rootfs syncfs成功之后发出。`retirement.cleanCheckpoint`只有该guest事实、native joined且无错误、持久clean记录提交都成功时才true。目录fsync失败等情况可能资源已退役而cleanCheckpoint仍false；`shutdownComplete`不是磁盘干净恢复证明，更不是任意掉电保证。

`cleanCheckpoint:false`表示本轮未确认持久提交，不承诺磁盘记录已回滚。若clean记录已rename可见、随后目录fsync失败，下一新owner仍可能读到完整且合格的clean记录并恢复；它重新验证当前记录，不读取上一进程的内存布尔。该可见性不构成掉电耐久性证明。手机CLI的两阶段验收保守要求前轮cleanCheckpoint严格true，才接受那份SUMMARY作为恢复对照。

`nativeMemoryRelease`为`null | 'process-exit'`。owner真正持有native session后为process-exit，包括Socket封装失败但仍有linuxJoin债务。已打开的普通off也走最终join；join或UNKNOWN收尾都不清除此持有事实。null只是缺少该持有事实，不等于零内存、已释放或任意字节数。VM allocation/owner当前保留到整个App进程退出，Node线程stop不是整个App进程退出。Dart提供固定中文notice供界面展示；不从全App PSS推定VM专属内存。

1203 增加可选的 `retirement.native.ramRetirement` 观测。它可为 null（join 未确认），或包含 `eligible`、`attempted`、`trackedBytes`、`eligibleBytes`、`advisedBytes`、`errorCode` 六项。只在正常受控退出和真实 join 后，对主 RAM 内部完整页发出丢弃建议；虚拟地址和 VM 对象继续隔离。`advisedBytes` 记录系统调用成功接受的范围，不能当作 PSS 或设备实际回收量。失败保留非零 errno 与 0 成功建议字节，磁盘关闭结果与 `cleanCheckpoint` 独立。控制层复制这个观测，既不吞掉内存错误，也不让调用者修改 status 快照污染内部状态。

已安装后的普通 `setEnabled(false)` 会在关闭准入后进入现有 `shutdown()` 的不可逆屏障，经 drain job、guest close、owner.dispose 到达真实 join；符合原生正常退出条件时才对主 RAM 内部完整页发出丢弃建议。它不会完整析构 VM/owner，也不允许同一 App 进程重新开启；须重启 App 才能以干净持久记录恢复。安装中的取消仍走原有取消处置，未开启过的 off 不创建 VM。应分别记录请求接受、真实 join、RAM 建议结果、包含 VMA 的 RSS/PSS 与整个 App force-stop；不能用202、shutdownComplete或advisedBytes代替内存量化。

旧 native 未返回该字段时，GET 保持旧形状。持久化 `instance.json` 的 native 记录仍精确只有 joined/retirementError/apiResult 三项，RAM 观测不进入 clean 判断或下一次恢复依据。现有 ETS 解码器不拒绝 native 的额外可选字段；现有 Dart 只取已知三项，因此允许它存在但不展示此观测。本改动不修改 Dart/ETS/UI，也不改变 `nativeMemoryRelease` 枚举。

## 7. 931非零作业的固定诊断

`job.diagnostic`为null或`{category,evidence,message}`。仅fulfilled done后的settled、exitCode 1–255、非取消、非信号退出、非notStarted可有诊断；原outcome及errorCode保持。分类只引用完整且有效UTF-8的stderr，最多16KiB；尾部截断、混合多类或无法识别时为unknown，不能用文本修复UNKNOWN生命周期。

| category | evidence | 含义 |
|---|---|---|
| dns | stderr | 命令输出报告域名/代理名称解析失败 |
| connection | stderr | 命令输出报告无法建立连接或连接超时 |
| tls-interrupted | stderr | 有TLS上下文的unexpected EOF；不能据此确定断开方 |
| tls-certificate | stderr | 命令输出报告证书校验失败；不建议关闭验证 |
| unknown | none | 完整错误证据不足，或输出截断/混合/无法识别 |

message是对应固定中文，不拼接stderr、URL或凭据。成功命令出现相同错误字样仍无失败诊断；取消SIGKILL与请求SIGTERM保持原来的不同事实。
