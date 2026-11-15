# M6-5：固定 Node 24.22.1 的 AddLinkedBinding 迁移评估

状态：**评估与 Linux 实验已完成，独立复核待进行；本包不迁移生产入口。**

## 1. 结论与建议

`node::AddLinkedBinding` 在固定 Node 24.22.1 上确实可用。真实 Linux 实验验证了主环境注册、Worker 继承、已有 Worker 查询父环境后来注册的**新名称**，以及 Worker 局部注册的向下可见性。现代注册路径也实际执行了已审 publication 的四个原生回调。最终矩阵为 **20/20 符合预期**，其中六项是故意构造的负向结局；它不是 20 项目标设备能力通过。[E1]

39 的现有 C++ 调用点位于 `node::Start` 之前，没有可直接传给现代 API 的 `Environment*`。在该位置只把旧函数名改成新函数名不成立。但这**不能推出所有保留 `node::Start` 的路线都不成立**：本轮动态 bootstrap 实验保留了原 runner 的参数检查、真实 `dsh_node_start` → `node::Start` 调用和单个 CLI `--import`，在实验 wrapper 内依次加载网络、自己的动态原生 bootstrap、publication。分开的 `--import path` 与 `--import=path` 两种写法均实际成功。[S1][S4][E1]

动态路线增加了一个在 Node 环境内加载的自有 `.node` 模块，并改变了注册时点和构建、签名、加载关系。本轮仅证明其 Linux 可行性；OHOS arm64/musl 构建、Ark 与 Node 同进程符号归属、HAP 签名与加载、代码库存活期、完整 App 和设备生命周期尚未验证。因此建议暂时保留 39 的生产路线，把动态 bootstrap 作为有实证的后续候选；不为了更换 API 立即重写完整 embedding 生命周期。

## 2. 固定输入与交付范围

本包只新增 `runtime/tests/ohos/linked-binding-evaluation/` 下的自有实验源码、来源元数据，以及本说明。源码补丁可从 c0949d6 应用；**运行实验另需提供精确的 39 树**。补丁可应用的基底和实验运行输入是两个不同条件。

运行输入是 39 的 after34 补丁 `d534915f519bbf993cc9386ef270791f32ffa189b13885af6e6638553484870f` 对应树。驱动逐字节检查下列输入，实验前后另核对该轻量树的 37 个 runtime 文件，结果全部不变。[E1]

| 输入 | SHA256 |
| --- | --- |
| 官方 Linux Node 24.22.1 可执行文件 | `e32e2d16081cf644f88392934288086e7662529d0d43277c34f7aad2207cfafb` |
| 39 `host/node_runner.cpp` | `993b923df7999c23f3cb1d5efa9e300a37d85ad88f1b9f14e8a5ddb8caff27ae` |
| 39 `host/publication_binding.cc` | `902ce0e57fc90ee8c8f801ab64cdd646ffdbfc87f185d5b2df760ddd2907091a` |
| 39 `node-version.json` | `abbea973e37761623fc80fe12da17d79df3db932b66169da3fa1e45f552192c4` |
| 39 统一 `preload.mjs` | `791a559daa988dbf2f54ae8f08a7212db63ed1fdb773f8524dd4513153ca3274` |

`input-pins.json` 还固定六个实际编译头文件，包含 `node.h`、`node_api.h`、`node_api_types.h`、`node_version.h`、`v8.h`、`v8config.h`。其中前两个与本轮重新获取的官方 v24.22.1 原文逐字节一致。编译器实测为 Ubuntu g++ 13.3.0，实验使用 C++20、Node-API 8；这是 Linux 编译证据，不是目标 ABI 证据。[E1][S1][S2]

交付不含 Node 第三方实现全文、依赖 tarball、生成头、`.so`、`.node` 或已安装依赖。原生实验产物保存在独立 build 目录，证据记录其命令、哈希与长度，复查方可从给定精确输入重新编译。

## 3. 公开接口与旧注册路线的实际语义

### 3.1 现代接口要求真实 Environment

固定 `node.h:1457–1473` 声明四个 `AddLinkedBinding` 重载，每个都接收 `Environment*`。接口说明目标环境及其创建的 Worker 可以访问该 binding，注册回调至少要在环境存活期间可调用。`src/api/environment.cc:1118–1167` 显示它将模块记录放入该环境的链表；传空环境会触发检查。最简 Node-API 重载接受名称、初始化函数和 API 版本，本实验使用此公开重载。[S1][S4]

固定 Linux 可执行文件实际导出了四个重载及 `GetCurrentEnvironment`，记录见 `evidence/node-public-exports.json`。实验 bootstrap 从正在运行的 Node JavaScript 回调进入原生代码，通过公开 V8 当前 context 与 `node::GetCurrentEnvironment` 获得环境，再注册固定名称。它没有把 Ark 的 `napi_env` 强制转换为 Node 环境，也没有访问 Node 内部 `Environment` 定义。[E2]

这是公开的 Node/V8 C++ embedding 接口加 Node-API 初始化回调；不能因为回调采用 Node-API，就把整个 bootstrap 描述成只依赖稳定 Node-API ABI 的模块。官方 embedding 文档明确允许 embedding API 随 major 版本发生破坏性变化，本任务仍固定 24.22.1。[S3]

### 3.2 旧 flags 问题需要准确归因

`node_api.cc:808–827` 的转换会保留传入的 `nm_flags`，再交给 `node_module_register`。因此“手工描述符里的 flags 一律被丢弃”并不是这里的正确解释。`node_binding.cc:276–290` 的实际分支是：Node 尚未初始化时加入进程级 linked 列表，并设置 linked 标志；已经初始化后则进入线程局部 pending 路径。后一个分支不会因为调用方传入 `kLinked` 就改成环境级或进程级 linked 注册。[S5][S6]

本轮以真实动态 addon 在初始化后调用旧 `napi_module_register`，明确传入 `kLinked`，主环境和 Worker 都仍查不到新 binding；JIT 与严格 O0 两种模式一致。现代路径在同类时点可以注册。这支持迁移到现代接口的语义理由，但不抹去当前生产在初始化前注册的既有前提。[E1]

固定 `node_api.h:36,81–90` 标记旧描述符注册为 deprecated；宏 `NAPI_MODULE_X` 的附加参数展开行为与直接传描述符也需要区分。本实验自己的动态 bootstrap 采用符号式 `NAPI_MODULE` 入口。[S2]

实验 `.node` 同时含现代正对照和旧 API 负对照，所以动态符号表中仍可见 `napi_module_register`。**不能用该产物宣称整个二进制已移除 deprecated 符号。** `registerModern` 的实际执行路径没有调用旧注册函数；每个相关测试先确认目标名称不存在，再执行现代注册。[E1]

### 3.3 Worker 继承的边界

`node_binding.cc:678–688` 查询当前环境、Worker 的父环境，最后才查询进程级 linked 列表。本轮观察与该实现一致：主环境注册能被后代 Worker 发现，Worker 局部注册能被其子 Worker 发现，但主环境不能反向发现。后者在外层 Worker **仍活着时**就进行了断言，并非只在它退出后检查。[S5][E1]

“晚注册”实验的名称此前不存在，已有 Worker 先得到 missing，收到明确消息后重新查询父环境刚注册的新名称并成功。**没有测试，也不据此推论：重新注册同名 binding 可以覆盖某个环境已经缓存的 `_linkedBinding` 返回值。** 各环境初始化得到的序号不同，证明测试并非把同一个 JavaScript exports 对象跨环境复用。[E1]

名称使用静态字面量，回调来自实验加载且保留的库。生产迁移必须保证这些名称和回调代码至少覆盖相关环境及后代 Worker 的存活期；本轮没有验证主动卸载库、移动端销毁与再启动、Ark 生命周期交错或环境退出竞态。

## 4. 与 39 唯一预加载入口的关系

39 的 `node_runner.cpp:30–57` 先验证专用宿主参数，再执行 `RegisterPublicationBinding()`，最后调用 `node::Start`。它拒绝非空 `NODE_OPTIONS`，要求 `--jitless`、一个指向统一入口的首个 `--import` 和绝对主入口。路径后缀检查只证明布局符合约定，不授权路径、不证明文件身份，也不替代既有 workspace roots、私有 `DSH_HOME` 和宿主信任前提。[E1 的固定输入]

固定 `node.h` 的 `Start(int,char**)` 不向调用方暴露当前 `Environment*` 或 preload 回调。现有 pre-Start 调用点没有这个参数，因而不能直接替换。负向实验在独立 Linux 子进程中传入空环境，进程以 SIGABRT 退出，stderr 对应 `CHECK_NOT_NULL(env)`。该子进程禁用了 core dump；这是错误参数的隔离反例，**不能作为 App 内或 Worker 内的安全能力探测方式**。[S1][S4][E1]

两条不同的后续路线如下。

| 路线 | 环境从何而来 | 与 39 的关系 | 本轮证据 |
| --- | --- | --- | --- |
| 在原 pre-Start 位置直接替换调用 | 该位置没有可用环境参数 | 缺少现代 API 必需前提 | 固定声明、实现检查、空环境隔离反例 |
| 宿主改为公开 embedding 生命周期 | 宿主创建并持有 Environment，在 LoadEnvironment 前或其公开 preload 回调内注册 | 会改变目前由 node::Start 管理环境的方式 | 仅源码分析；NOT_IMPLEMENTED |
| 统一入口内部加载自有动态 bootstrap | 已启动 Node 的当前 JavaScript context | 可保留外层 node::Start 与一个 CLI import；改变注册时点并增加模块加载 | Linux JIT/严格 O0 与单 import 实验已测；目标端 NOT_RUN |

完整 embedding 路线可以使用公开的 `LoadEnvironment` preload 回调。固定 `node.h:829–851` 保证该回调在用户模块加载器执行用户代码之前运行，Worker 也遵守它，并要求回调线程安全。固定默认主环境路径 `node_main_instance.cc:106` 使用空的启动回调；不能从现有外层 `Start` 调用凭空取得该 hook。[S1][S7]

若选择完整 embedding，必须承担初始化、平台与 isolate、environment、原 CLI/环境选项处理、事件循环、退出处理、Worker、线程与库寿命以及 teardown 的完整回归。官方示例为这种架构提供公开接口，但本包没有编写或验证一个产品级替代。也没有以内部 `require` 或私有 Node API 代替缺失的环境接点。[S3][S4]

动态候选的实验改动则是显式而局部的：保留原 runner 源文件，用**测试专用链接替身**把旧静态注册设为 no-op；单 import 的测试 wrapper 在网络初始化之后、publication 之前加载现代 bootstrap。其 first sim 步骤和最后 observer 都是测量 instrumentation，不是产品入口方案。这个 wrapper 放在满足布局后缀的测试目录，**不是 39 原 wrapper 的源码身份**。[E1]

## 5. 真实矩阵及负向对照

最终结果在 `evidence/run-final/report.json`，全部 stdout、stderr 与编译命令逐项保留。所有测试是实际执行，零 skip/TODO；表中“符合预期”包括预期失败。[E1]

| 组别 | 项数 | 真实观察 |
| --- | ---: | --- |
| JIT 主环境、新名继承、父环境晚注册新名、Worker 局部注册、旧 API 晚注册反例、原 publication 回调 | 6 | 6/6；旧 API 一项按预期 missing |
| 严格 O0 同一六项 | 6 | 6/6；实际 `--jitless` 与精确 sim preload，动态 addon 仅测试绝对白名单 |
| pre-Start 空环境负向 | 1 | 子进程 SIGABRT，符合预期；无 core 文件 |
| 精确 39 runner 与原注册，普通 Linux 下新增现代 binding | 1 | 真实进入 dsh_node_start 后成功；网络/publication 的平台 no-op 不算 OHOS 网络实证 |
| 精确 39 runner 额外 CLI import 负向 | 1 | 退出 64，ERR_OHOS_HOST_ARGV，bootstrap sentinel 不存在 |
| 多 import 仪器路径的 bootstrap 前/后顺序 | 2 | 前置成功，后置退出 1 且 ERR_OHOS_PUBLICATION_BINDING_MISSING；后置 bootstrap 未执行 |
| 测试 no-op 旧注册后，单 import 动态候选 split/equals | 2 | 两种均真实进入 dsh_node_start、node::Start，publication 成功且 Worker 继承四接口 |
| 同一单 import 路径省略现代 bootstrap | 1 | 退出 1，publication binding 缺失，bootstrap 未执行 |
| 合计 | 20 | 20/20 符合预期，其中六项为负向结局 |

publication 正对照没有只检查属性名：它实际调用 `lockExclusive`、`getOwnershipMarker`、`setOwnershipMarker`、`renameNoReplace`，读取最终 payload 核对结果。仪器 wrapper 还运行真实 publication JavaScript 服务与持久账本，发布方法为 `rename-noreplace`，收尾时 `pendingCount` 为 0。Worker 实际获得四个原生接口，且没有主线程的 publication JavaScript 服务。[E1]

单 import 与多 import 的 observer 均在真实 DSH bin 开始前退出。因此本轮**没有执行完整 DSH App 回合、五工具审批剧本或真实 HTTP/WS 会话**。网络 initializer 存在的断言只证明初始化顺序，不能替代网络收发测试。实验持续时间、测试产物大小也不能解释成生产性能收益。

初次 run-01 使用了 C++17，被固定头文件拒绝，随后修正为 C++20；当时没有运行任何 runtime case。该编译夹具错误、原驱动快照和 stderr 继续保留，不归因为产品缺陷。run-02 的 17 项与 run-03 的 20 项历史观测也保留；正式结论只绑定 run-final 与冻结源码。[E3]

## 6. 决定迁移前还需要的证据

1. **目标导出与 ABI：** 用固定 OHOS arm64/musl 的 Node 24.22.1 头文件和实际 `libnode` 编译，核实所需公开 Node/V8 C++ 符号能链接、加载、执行。Linux 可执行文件的导出表不能代替这一结果。
2. **自有模块的签名与路径：** 动态候选引入的 `.node` 必须属于自有、随包、签名且受信任的代码，核实 HAP 安装布局、加载规则及更新过程。不能把本轮 Linux `.node` 复制或重命名就当作目标产物。
3. **Ark/Node 环境与符号归属：** 同进程里两套运行时可能提供相似 Node-API 名称。需要确认 bootstrap 的 Node-API、Node/V8 C++ 调用解析到正确的 Node 实例；从 Node context 取环境，不向 Node 回调传 Ark 环境或值。本轮 Linux 单一 Node 环境不证明这种混合归属。
4. **生命周期：** 宿主保持库存活，注册回调、名称、环境与后代 Worker 不发生悬空关系；实际测启动失败、Worker 终止、App 销毁以及系统生命周期。固定版本对正常父子 Worker 的证明不能替代卸载和重启测试。
5. **统一入口与实际 App：** 迁移仍应只保留产品的一个 CLI import；网络先执行，现代注册在 publication 之前，错误在业务代码之前明确失败。以真实 App、HTTP/WS、五工具/审批和目标设备回合重验，保留 `DSH_HOME` 与授权根前提。

这些是选择动态路线后需要闭合的具体证据，不是对当前生产39的新增“已失败”判定。本轮没有速度、RSS、HAP 大小或目标能力的比较数据；暂不据现代 API 的名称就宣称更快、更小或目标更安全。

## 7. 复现

先准备完整的精确 39 runtime 树、官方 Node 24.22.1 Linux x64 分发，以及包含本轮固定 DSH/Undici 依赖的前缀。测试只读取这些输入，所有生成物写入两个新的目录。需要 Python 3、g++ 13.3.0 或另行记录的兼容编译器、`nm`；Linux 文件系统必须支持本轮实际 publication 的 flock、xattr 和 renameat2 操作。

```sh
python3 runtime/tests/ohos/linked-binding-evaluation/run.py \
  --node-root /absolute/path/node-v24.22.1-linux-x64 \
  --host-source /absolute/path/exact-39/runtime/ohos/host \
  --dsh-prefix /absolute/path/fixed-dsh-prefix \
  --output /absolute/path/new-text-evidence \
  --build-output /absolute/path/new-native-build
```

两个输出目录必须尚不存在。驱动核对 Node、头文件和 39 的四个关键前像，再实际编译、执行、核对运行前后文件哈希。其协调器在普通宿主 Python 中启动子进程；严格 O0 限制在被测 Node 进程及真实 Worker 中生效，不能把协调器能 spawn 误说成目标可以 spawn。

raw report 记录全部 argv、受控测试环境项、返回值、断言和产物哈希。单 import 实验所用 LD_PRELOAD 只是 Linux 测试桥，用于让可执行 Node 的 main 进入已有 `dsh_node_start`；它不是 OHOS 产品部署方式。构建输出不随补丁交付，也不承诺不同编译器或目标 ABI 的产物逐字节相同。

## 8. 来源与证据索引

所有官方源均固定到 **v24.22.1**，本轮 HTTP 200 获取，完整 URL、字节数、时间和 SHA256 在 `runtime/tests/ohos/linked-binding-evaluation/sources.json`。本包只交元数据，不打包这些第三方实现全文。

| 编号 | 官方来源 | SHA256 |
| --- | --- | --- |
| S1 | [src/node.h](https://raw.githubusercontent.com/nodejs/node/v24.22.1/src/node.h) | `c35691764bac5a82c4139348ca57f5676163afe563a40ad78457cef8bfb57012` |
| S2 | [src/node_api.h](https://raw.githubusercontent.com/nodejs/node/v24.22.1/src/node_api.h) | `2d4560831e525b47b060ec8a0864ab73993df9e20215ce9f0fe7b24cd31af32a` |
| S3 | [doc/api/embedding.md](https://raw.githubusercontent.com/nodejs/node/v24.22.1/doc/api/embedding.md) | `ff249f5c0b5557b75a7140a096df42372454448a5ea5e010c7b28bdaef4ad1cb` |
| S4 | [src/api/environment.cc](https://raw.githubusercontent.com/nodejs/node/v24.22.1/src/api/environment.cc) | `58206afd59c1e161bc892bf9aa67714fa1e997395d96ceeb23eccd334b08b470` |
| S5 | [src/node_binding.cc](https://raw.githubusercontent.com/nodejs/node/v24.22.1/src/node_binding.cc) | `b1d9a6e2b13a63b58c741d48b108e1e658ebd0a82593280b452f776b1e89dc75` |
| S6 | [src/node_api.cc](https://raw.githubusercontent.com/nodejs/node/v24.22.1/src/node_api.cc) | `4c76a71e04fc4b5201fc83fffc68e724db9bd660951d098ba50f04909b00b4da` |
| S7 | [src/node_main_instance.cc](https://raw.githubusercontent.com/nodejs/node/v24.22.1/src/node_main_instance.cc) | `bcca3565964f27ebd14028e6f58857dc37938d9f3ea942ad4cebb9fd44325145` |

证据随评估包提供，路径相对于包根：

- **E1：** `evidence/run-final/report.json`、同目录逐项 stdout/stderr、build-records 与 addon-dynamic-symbols。现代与旧 API 对照、六个负向预期、真实宿主桥和精确运行输入均在其中。
- **E2：** `evidence/node-public-exports.json`，固定 Linux Node 的公开符号实测；目标导出明确 NOT_RUN。
- **E3：** `evidence/run-01/` 的原编译错误和旧驱动；后续 run-02/run-03 历史文本记录以及 build-relocations 只用于追溯，不替换最终矩阵。
- **来源记录：** `evidence/final-source-record.json` 与源码内 `sources.json`；官方头文件同一性可独立重取核验。
- **冻结清单：** 包根 manifest 给出自有源码、文档与证据的哈希；独立复核状态另由审查报告提供，本说明不预先给自己 PASS_SCOPED。
