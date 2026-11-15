# M6-4：唯一预加载与专用宿主启动契约

当前 `dsh_node_start` 已由 [P1A 嵌入式退出合同](embedded-exit.md) 改用公开嵌入 API，保留本文的参数与预加载顺序。下文有关直接调用 `node::Start` 的运行记录属于 M6-4 历史证据；不能据此声称当前 App 宿主、Ark 符号隔离或真机已验证。

**未在 OpenHarmony 真机核实。** 本后继接在34持久账本及网络 M3-5 之后，合并 M5-3 的首个预加载约定。Linux 真实宿主入口、显式仿真、设备 ABI 三种证据分开；不引入旧 O7c 的 `--expose-internals`，不改 M6-5 待评估的 linked 注册 API。

## 产品唯一入口

宿主只配置 **`runtime/ohos/preload.mjs`**。该模块使用两次按顺序等待的动态 import：先完成 `net/dsh-preload.mjs`，再加载并完成 `publication/preload.mjs`。使用动态等待是为了让第二步连模块求值都在网络成功之后发生；网络失败则 publication 不加载，publication 恢复失败则 DSH 主入口不执行。

网络步骤仍以 `process.argv[1]` 为真正的 DSH bin，从它解析锁定的 DSH 0.2.1-rc.4 / Undici 8.11.2，并保持既有晚加载拒绝和 safe-base 规则。wrapper 不改写 argv，不另起 Node。原 `bootstrap.mjs` 没有要求 argv 中直接出现内部 preload 文件名的比较；原保护的是它必须早于 Undici API 首次导入，这个条件在 wrapper 的第一步继续生效。

publication 步骤等待主引擎账本开锁与恢复后才发布服务。Worker 继承统一 import 时，内部网络步骤走 Worker 分支，只安装该 isolate 的 fetch；publication 明确跳过 Worker，不争抢主引擎账本。不把 Symbol 当作跨 Worker 共享值：测试标记仍由显式测试预加载在各 isolate 重建。

## 宿主必须提供的输入

使用编入 `libnode.so` 的自有 runner 的 **`dsh_node_start(argc, argv)`**；这是 libnode 唯一的启动入口，`node::Start` 不导出。Ark 侧仍负责应用生命周期内只启动一次，并保持宿主库驻留。C/C++ argv 数组必须像普通 main 参数一样有效、以空指针结束，在 Node 运行期间保持所需生命周期。

在调用前，宿主创建其获准的私有应用数据目录，把 `DSH_HOME` 显式设成该既有绝对目录，保持34的 ledger / marker / flock 前提。现有 `workspaceRoots`、会话根和文件系统权限约束继续由原授权层提供；本项没有扩大或替代它们。

只接受下面两种**专用布局**。方括号后的内容是 DSH 参数，可以是 `web --host 127.0.0.1 --port … --no-open` 等：

```text
argv[0], --jitless, --import, /安装前缀/runtime/ohos/preload.mjs,
/实际DSH前缀/node_modules/@deepseek-ai/dsh/lib/bin.js, [DSH参数…]
```

或：

```text
argv[0], --jitless, --import=/安装前缀/runtime/ohos/preload.mjs,
/实际DSH前缀/node_modules/@deepseek-ai/dsh/lib/bin.js, [DSH参数…]
```

这里是参数数组，不是待 shell 解释的命令字符串。预加载值和主入口必须为绝对文件系统路径；本版不接受相对路径或 file URL，也不做通用 Node CLI 配置层。安装应保留 `runtime/ohos/preload.mjs` 及其相邻 net、publication、node-version.json 的结构。

native 只检查预加载值的绝对路径和 `/runtime/ohos/preload.mjs` 后缀。**这仅验证约定布局，不证明路径授权、规范化后的归属、文件身份或源码完整性。** 宿主必须从已核实的自有安装包构造路径；不能把该后缀检查用于接纳任意外部路径。实际 DSH 身份仍由网络 bootstrap 在启用平台分支后核对。

主入口之前不能增加第二个 `--import`、`-r` / `--require`、eval、loader 或其它 Node 选项；这些均在专用布局外，返回 `64` 并输出稳定代码 `ERR_OHOS_HOST_ARGV`。主入口之后同名字符串是 DSH 的普通参数，保留传递，不错误当作 Node 选项拦截。

## 为什么拒绝非空 NODE_OPTIONS

`NODE_OPTIONS` 必须不存在或为空字符串。任何非空值，包括空白和 `--no-warnings`，都会在 Node 初始化及 binding 注册前返回 `64`，诊断代码为 `ERR_OHOS_HOST_NODE_OPTIONS`。不打印该变量、路径或 DSH 参数原值。

这是本后继新增的宿主契约。Node 会先处理环境中的可重复 import，再处理 argv 中的 import；CJS require 又先于 ESM import 执行。因此只检查 argv 的“第一个 import”不能保证网络在所有应用代码之前。宿主不尝试自己实现 Node 的完整环境选项语法，也不静默清空该变量：静默清空会改变调用方配置并掩盖启动顺序错误。调用方收到明确错误后，应修正该专用宿主的启动输入。

实际 Node 24.22.1 对照观察到：环境 require → argv require → 环境 import → argv import → main。测试包含带空格路径的引号形式。旧34 runner 在相同环境 require 下实际先执行了 sentinel，再进入 wrapper；新 runner 在任何 sentinel / main 执行前拒绝。此负对照是对新增启动约定的真实需求证据，不把旧版本描述成已经具备该拒绝能力。

## Node 版本只有一个可执行来源

`runtime/ohos/node-version.json` 只存一个规范的版本字符串，当前为24.22.1。

- `publication/index.mjs` 直接 JSON import 这个字符串，用于运行时检查和错误说明。
- `host/generate-node-version.py` 从同一文件生成 **构建目录内**的 `dsh_node_version.h`；C++比较和错误说明都消费生成的宏，不再另写三个数。
- OHOS CMake 与 Linux `build-publication-native.sh` 共用这个生成器。CMake把 pin 和生成器登记为重新配置依赖。生成头文件不提交，不手改。
- 生成器拒绝对象等错误 schema、非规范 major.minor.patch 和超 uint32 分量。运行时对 JSON 文件不存在/损坏不会假定一个默认版本。

这里集中的是 publication JS/native 的可执行版本守卫。历史证据、测试对照和 Node 源归档身份仍可写其实际24.22.1版本，不能把历史证据随 pin 自动改写成未测版本。也不表示单改 pin 就完成 O7 编译链、Undici兼容性或设备验证。

## Linux 合同验证

运行命令（外层协调器需要创建子进程，不放入 O0）：

```sh
python3 runtime/tests/ohos/host-startup.py \
  --node-root /绝对路径/node-v24.22.1-linux-x64 \
  --dsh-prefix /绝对路径/已锁定DSH前缀 \
  --out /绝对路径/新输出目录
```

可额外传 `--baseline-runner /绝对路径/34基线测试so` 重放旧 runner 风险对照；本轮提供的报告实际运行了该对照。新合同矩阵34项，带对照共35项，全部通过；不是35个设备能力通过。所有子进程完整 argv、源码/二进制哈希和 stdout/stderr 都落在报告中。

### A. 实际经过 dsh_node_start 的 Linux 路径

测试专用 `host-startup-linux.cc` 在 glibc 上将官方 Node 可执行文件的 main 交给本仓库真实 `dsh_node_start`，后者调用真实导出的 `node::Start`。编入的是本次产品 runner 与 binding 源，没有替 runner 注册 binding 的测试 constructor；`main` 实际取得四个 linked 成员。Node 官方 Unix main 自身也直接调用 `node::Start`（固定源码 `src/node_main.cc:96–98`）。

这个 LD_PRELOAD shim **只用于 Linux 合同测试**，不进入 HAP，不是 OHOS 启动方案或安全能力替代。该组没有修改 platform / 放置 sim marker，因此网络和 publication 的 OHOS平台分支按设计 no-op；它证明宿主路径、参数拒绝和真实 linked 登记，不能当作 OHOS 网络或账本验证。

4个有效输入覆盖分离/等号 import、空 NODE_OPTIONS、主入口后同名普通参数；14个非法输入覆盖提前/重复 import、CJS require、相对或错误入口以及环境选项。每个拒绝都检查 return64、稳定代码、sentinel 未执行和 main 未执行。

### B. 显式仪器化的预加载组合

另一组用普通 Node CLI，**显式**把测试 observer、sim marker/O0放在 wrapper 前，binding 由原已审 Linux 测试 constructor库注册。这个顺序只服务于 Linux 仿真，不是产品宿主的一个 import 布局，也没有通过 native 参数验证冒充产品启动。

JIT 和严格 O0 各6项，使用真实锁定 DSH bin 作 `process.argv[1]` 解析依赖；wrapper后观察器在 DSH主模块执行前完成验证并退出，因此没有把它说成完整 App 回合：

- main 与真实文件型 ESM Worker 的本地 HTTP 请求均返回完整正文；原 Request/Response/Headers/FormData 身份保持。
- 主服务实际完成文件发布；JIT走link，严格 O0因link拒绝走rename-noreplace；最终内容正确。
- Worker取得自己的网络层、不把worker文件误作DSH bin、不安装主publication服务；严格worker同时验证无WebAssembly及spawn/link/dlopen拒绝。
- 提前导入 Undici 或主入口不匹配时，网络步骤拒绝，publication不存在且没有建立账本目录。
- 缺linked binding或DSH_HOME时，观察到网络已先完成，publication失败，DSH主模块未执行。
- 未加载sim但遗留旧环境变量的Android门控对照保持fetch及服务状态不变；这是模拟平台分支验证，不是Android设备运行。

### C. 版本与34回归

把同一个测试 JSON pin改成下一个patch版本后，生成的真实native addon拒绝当前Node；JS守卫也读到相同测试pin并拒绝。没有通过改写 `process.versions` 来替代这两条单源证明。错误schema不能生成头文件。

集中pin后重新编出的原publication `.node` 与linked测试库仍分别为 `fb9c889c84f5f533d394a089f404347273403b2ee8399e4dbb4280451fdc09e0`、`569b89fc39d9bac0001fff032b54eea7a66f3c89d22c9f1f40f0d71d07d056aa`，与34逐字节一致。新host runner的代码和测试库有自己的新哈希，不借这个相同值冒称host未改变。

34原 `publication-startup.py` 的18项另行实跑全部通过，保留重复/并发安装、缺成员、非法或带符号链接数据目录、公开ledger目录、损坏账本与worker边界。原ledger、atomic、网络传输、vendor/pins和Android启动文件不在此次补丁修改面。

## 现存限制与后续

- OHOS SDK交叉构建、arm64/musl ABI、HAP签名加载、Ark/Node符号隔离与手机一次启动生命周期仍 `NOT_RUN`。本包不填平这些缺口。
- Native仍使用34的预初始化 `napi_module_register` 接缝；M6-5将单独评估嵌入API迁移。本项没有将其弃用状态或固定版本耦合抹去。
- M6-3所列设备seccomp、实际el2挂载、rename flags、xattr/flock前提仍待真机。统一启动不会使被系统拒绝的syscall自动可用。
- publication初始化失败时网络步骤可能已经安装；启动会失败且主入口不会运行。宿主仍遵守一进程一次Node实例的生命周期，不在同一已失败Node环境中重启并假定无副作用。
- 网络require.cache检查是已有外部Undici加载历史的保护，不是对所有Node内置全局状态的完备探测；必须坚持此专用入口早于应用/插件运行的前提。

## 固定依据

本轮实际运行官方Linux Node24.22.1，二进制SHA256 `e32e2d16081cf644f88392934288086e7662529d0d43277c34f7aad2207cfafb`。以下官方tag源码已下载核SHA，仅元数据随交付，不附第三方实现正文：

| 来源 | SHA256 | 用途 |
| --- | --- | --- |
| [doc/api/cli.md](https://raw.githubusercontent.com/nodejs/node/v24.22.1/doc/api/cli.md) | `30dce1604cc3b8aee59b5c176c974bfd0b7748647a453fade811a086dfd2da5b` | import、NODE_OPTIONS、require优先级与Worker继承 |
| [src/node_main.cc](https://raw.githubusercontent.com/nodejs/node/v24.22.1/src/node_main.cc) | `c946687691d86754f5d53560b54a70d17cfed62bf23158ac457497b8b912d740` | Unix main调用node::Start |
| [lib/internal/modules/run_main.js](https://raw.githubusercontent.com/nodejs/node/v24.22.1/lib/internal/modules/run_main.js) | `9b9cf06a2bb5ace9210ac581fc66bc10f46d37d0b4473b4731d0d4ca5c71da47` | 顺序await用户import再执行主入口 |
| [lib/internal/process/pre_execution.js](https://raw.githubusercontent.com/nodejs/node/v24.22.1/lib/internal/process/pre_execution.js) | `2277b59de0d339bb091fb7e4bdddf251097958d488a34060e87616514a8f7717` | 读取require预加载列表；这里只研究源码，不在产品调用内部API |

初次Linux测试shim因导出符号被隐藏而未接管main、出现缺binding；原失败日志保留。修正测试shim导出后真实路径成立，未改变产品注册协议。最终报告按精确源码/产物哈希冻结，后续文档不覆盖旧证据。
