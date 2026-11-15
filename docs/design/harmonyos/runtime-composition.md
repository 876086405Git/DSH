# O1/O2 组成 v2：固定输入、完整静态导入与真实宿主入口

本轮以 `530f183906be2a218b1b09000400e01c9a572dba` 为基底，重新组成并运行当前 OH 运行时。最终目录载荷是 **14,253 个文件、160,393,179 字节**；该确切文件集合已经过真实 `Host::Start` 文件预检、宿主原样 argv/env/profile、实际 DSH 消费者及严格五工具/两审批回合。产品 Node 入口随后还执行了带相对模块、中文参数与相对文件访问的真实 Worker 脚本回合。

本文保留已冻结组成 v2 的目录格式及其历史测量，替换旧组成包的构建定义和验证方法。追加10的单归档增量沿用这些输入与内容门，构建输出和当前实际产物见 [单归档组成](runtime-archive-composition.md)，安装器及公开 zlib 接口见 [单归档安装](runtime-archive.md)。下文的目录 ZIP 数字不代表新的单归档，也不与安装器测量混用。Linux 验证不代表目标 N-API ABI、HAP 安装或设备后台行为已通过。

## 一、实际输入与应用顺序

| 输入 | 精确标识 |
| --- | --- |
| 公开基底 | `530f183906be2a218b1b09000400e01c9a572dba`；快照 ZIP SHA256 `ddbc4f5662bb1f1fc853612809a58bc1dc1e58c5207c73d251e50e23a88bd802` |
| Worker rebased v2 | 补丁 SHA256 `46b1b09b2b96ac774ada4d3b78b6e4accd450642b88287ea6a1bfe1424b44909`，原基底2c，干净应用到本基底 |
| 懒加载 native host 增量 | 补丁 SHA256 `c1f470fed52fa393175a666a53dd64425f47183102c9cfb617430b7c9a198215`，在本基底干净应用；不会用旧完整 P2 包覆盖已合入代码 |
| 本组成 v2 | 在上述实际组合最后应用；产品补丁本身从530基底导出，精确 SHA256 由交付清单给出 |
| DSH | `0.2.1-rc.4`；锁文件 SHA256 `9b61c5b60c82a3b64fb252af5c142d40d0c86aff30a17cdd5e1ca9d73df9a25c` |
| process npm 闭包 | 锁文件 SHA256 `5a815fc00cafc62fca834fe3e2abf6792bd3263c1a386cb2948d6a4063ed8f30` |
| 执行工具 | 官方 Linux Node `24.22.1`、npm `11.9.0`；构建解析器使用既有 esbuild `0.27.3`，不进入运行载荷 |
| 私有 RE2 | 固定产物 SHA256 `80eaea2a9e50a2851e332fa4fccffeb01550584ad3c448a2eadd88b43373d5f1` |
| 当前 OH pins | 27项；真实目标输入 SHA256 `f5d248d8a9a7be739269009846bc775940f962d8ec059f2d5d400e222b80b05c` |

该基底已经包含 O4b、O6、O8 和默认宿主接线，不能重复叠加其旧包。本组成不覆盖 Worker/O4b 的进程调度代码，也不改变 `stopped/finishing`、异步归属清理以及 stdout/stderr 排空屏障。私有 Bash 的变更仅增加被证明不从产品命令集合进入的裁剪项，重写器保留 Worker v2 字节。

### 从固定锁准备输入

`runtime/ohos/package/prepare-inputs.py` 为 DSH 和 process 分别创建全新目录，并运行同一条明确配方：

```sh
npm ci --ignore-scripts --omit=optional --include=dev \
  --install-strategy=hoisted --install-links=true --no-audit --no-fund
```

脚本核对 Node/npm 版本，复制仓库已有 package/lock，实际执行 npm，再按当前 `--target ohos` 应用 pins。DSH 不从已有平台目录克隆，也不使用硬链接克隆。`prepared-inputs.json` 保存每个正常文件的路径、大小和 SHA256；组成前重新逐项核对。相同 package.json 版本而内容被改、额外或缺失文件、硬链接共享文件、未知链接、不同安装参数，以及意外安装的 optional 包都会拒绝。npm 的 `.bin`、已知开发链接和安装缓存不进入载荷。

本轮有两次真实 fresh npm ci。第二次只增加本包三个已声明 OH vendor 修复文件；除这三个文件外，DSH 的所有记录文件和 process 全部文件在两次准备中逐字节一致。当前收据 SHA256 为 `22f820fa973437ec2bdbfe5b2557bf9ce6c99f128c63ac36ee945a45e40082a7`。这解决了“只核锁文件但未固定安装参数”的重现缺口，不声称不同 npm 版本或任意环境变量下结果也相同。

## 二、宿主、清单和组成器的共同必需入口

本基底实际 `host_core.cpp` 的 `File(options.runtime_root, "…")` 要求八个文件：

| 用途 | 安装根下的路径 |
| --- | --- |
| DSH 可执行 JS 入口 | `node_modules/@deepseek-ai/dsh/lib/bin.js` |
| 宿主唯一 preload | `runtime/ohos/preload.mjs` |
| 虚拟进程插件 | `runtime/ohos/process/index.mjs` |
| 沙箱策略插件 | `runtime/ohos/process/sandbox.mjs` |
| 生命周期工具边界插件 | `runtime/ohos/lifecycle/index.mjs` |
| 能力协议插件 | `runtime/ohos/capabilities/index.mjs` |
| App 路由桥 | `runtime/bridge/dsh-go-bridge/lib/index.js` |
| OS 子进程边界 | `runtime/ohos/process/child-process.mjs` |

`RuntimeCore.validateManifest` 现在要求同一集合。组成器从真实 C++ 源中的固定字面量调用提取要求，并与实际 ETS 声明比较；不能识别的调用形式、集合漂移或最终载荷缺项都会拒绝。新增宿主入口时必须继续遵守并更新这一明确约定与测试，不能仅修改某一层的常量。

`composition-required.test.mjs` 执行真实 ETS 校验函数的逻辑体，依次删除八个入口验证拒绝；最初加这道门时，旧基底在七项中五项失败，新定义七项通过。`composition-inputs.test.py` 另用真实文件检查新入口、清单漂移、调用语法漂移及输入收据边界。Node 类型擦除仅用于 Linux 逻辑验证，不能作为 ArkTS 编译通过的依据。

`host-layout.py --assembled-payload` 读取实际 manifest，验证整个文件集合后直接把该树传给由原样 `host_core.cpp` 编译的驱动。驱动真正调用 `Host::Start`，完成所有文件预检和 profile 生成；runner 回调只负责捕获 argv/env。随后测试用这些原样参数启动真正 pinned DSH，并完成消费者检查、配置 dump 和原严格回合。此路径不复制 npm 开发前缀、不重建 process、不用开发目录顶替运行依赖，回合前后整树 SHA/size 集合必须一致。

## 三、所有保留 JavaScript 的静态导入门

`audit-imports.mjs` 使用固定 esbuild 的语法解析/元数据功能，遍历每个保留的 `.js/.mjs/.cjs`，包括不在默认启动图中的文件；不会执行模块。解析不做 bundle，避免把计算路径的资源 glob 当成 JavaScript；输出名称独立，避免同目录 `.js/.mjs` 同名冲突。

ESM import/export 和字符串字面量 dynamic import 用 Node24 的真实逐 importer 解析规则验证。目标必须存在、为正常文件且仍在载荷内；不对 ESM 偷用 require 的补扩展名规则。实际结果：**8,661 个文件、20,003 条导入记录，零静态导入/白名单错误**。

该结果的范围必须保留：

- 141个无法解析的字面量 `require` 被单独记录，主要为保留的上游测试/开发入口及可选 native 优化；本门没有把它们伪称为已完整验证的 CJS 闭包。
- 计算得到的动态 specifier 不能由这个静态门穷举，仍依赖具体使用路径的执行证据。
- 保留的非声明 TypeScript 源和包的 source/type 开发条件不属于 JS 运行图审计，不承诺设备可用它们构建新的插件。
- 解析成功不证明某个模块的所有 API 在鸿蒙可运行。实际热点、拒绝分支、Worker/Git、签名和完整回合分别有执行证据；O9 扫描也继续保留“部分可用”。

### 精确的动态裁剪白名单

`dynamic-omissions.json` 保存 importer、specifier、出现次数、原因及源 SHA256。私有 Bash 的 importer SHA 来自已校验的 PROVENANCE；其余使用精确已审核源字节。源码、次数或原因变化即拒绝，已失效/不再需要的白名单也拒绝。不能用白名单放行静态 import。

| 被裁剪目标 | 可观察的产品边界 |
| --- | --- |
| Bash Python、SQLite、js-exec/QuickJS loader | 固定命令注册关闭；对应命令返回127与明确替代路径，真实 Node 使用专用 Worker 后端 |
| Bash flag-coverage 与仅服务旧 tar 的 chunk | 产品构造不提供 coverage；tar 原本就不在允许命令集合中，其 loader 不进入 |
| Windows `koffi` 分支与 Win32 worker | 实际平台选择器先排除；不宣称任意私有文件直接调用可用 |
| Office `libreoffice-kit` | OH 分支在动态加载前返回明确 unavailable |
| fs-search 的外部 ripgrep | OH 分支先返回虚拟 rg token，完整 grep/glob执行走既有后端 |
| 代理 Kerberos | 新 OH 分支在 import 前返回 `OHOS_PROXY_NEGOTIATE_UNAVAILABLE`，给出其他代理认证方式/电脑替代路径 |

此前曾错误推断 tar 的 xz/zstd 路径可达，实际命令调用表明 tar 入口一直返回127。原失败探针和被撤回的草稿保留；本包没有增加 tar 或假称 xz/zstd 已适配。实际独立 gzip/gunzip 往返仍通过。

### 静态闭包修复及新增裁剪

AWS/Smithy 的固定 Node 条件选择 CJS 分发，OpenTelemetry 选择 build/src；浏览器/bundler用的 extensionless ES副本被精确移除。fontkit、json-schema-to-ts 的重复源码/类型实现、指定上游测试文件、配置脚本、历史草稿也按具体包/路径裁剪。四个 DSH controller 的 client 仍保留公开打包入口，移除未打包的重复 types/client JS。规则和每个实际决策均留在 composition.json/input-files.json，不按模糊名称批量删文件。

OpenAI Bedrock 的 ESM/CJS 入口原本静态引用未安装的 `@smithy/hash-node`。本包仅在 OH pins 中换成已锁闭包内的 `@smithy/core/checksum.Sha256`。真实测试核对异步 digest、HMAC、reset，并通过实际公开 OpenAI provider 签署请求，与独立 node:crypto SigV4 推导逐项一致。没有新增外部依赖或升级任何 package/lock。

## 四、保留行为、许可与原生库

保持原组成边界：移除 Python/SQLite/QuickJS wasm解释器、LibreOffice kit、sharp平台库、SenseVoice native模型库、koffi/PTY/外部rg及平台 npm native包；对应功能明确拒绝或已有虚拟替代。**Node自带 `node:sqlite` 与实际 DSH 查询能力保留**。`.node.js` 是合法JS名称；只有真实 native 后缀和 ELF/wasm/PE/Mach-O 文件头被拒绝。

isomorphic-git API与依赖保留，CLI及minimisted移除。diff 8.0.4/BSD-3-Clause 原是既有锁内传递依赖，当前 Git直接使用它；ESM/CJS API、exports和LICENSE保留。私有 Bash 3.6.0 的194个文件及 Apache-2.0 LICENSE 由固定重写器生成；并不携带原 npm just-bash 包的被禁用解释器。

`libdsh_flock.so` 与 `libdsh_require_builtin.so` 留在 HAP libs，由可信安装目录和固定映射加载。**runner 已合入 libnode.so，不再存在需要并列打包的 libdsh_node_runner.so**；Ark host和主线目标native构建仍是另外的构建输入。本文体积不包括 Flutter、libnode、Ark host及目标原生模块。Linux测试`.so`只用于模拟真实加载边界，不能作为OH产物。

licenses/texts及input-manifest保留来源材料；其中已移除组件的许可材料是输入证据，不应误当最终安装组件。没有对全部第三方许可作法律结论。编译缓存位于应用 `cacheDir/node-compile-cache`，不进入 immutable rawfile，可独立删除重建。

## 五、真实输出与测量口径

| 实际对象 | 文件数 | 普通文件字节 |
| --- | ---: | ---: |
| 本次 fresh DSH npm输入收据 | 26,782 | 256,239,337 |
| 本次 fresh process npm输入收据 | 3,805 | 102,832,732 |
| 最终逻辑运行载荷 | 14,253 | 160,393,179 |
| 当前目录式传输 ZIP（含manifest） | 逐成员SHA/size回读一致 | 46,628,202 |

输入表是实际准备收据，并非“旧App占用”；最终载荷还加入仓库运行模块、bridge、许可与私有构建，因此不能简单把两行之差称为严格受控的单项裁剪收益。旧21在c818子集上的文件数、ZIP与20个计时样本均保留历史，不再拿来代表本轮组合。

最终 payload SHA256：`fa5c3bfd2e7c3eb2918c5fc0dda33de1d663233854c7afe80dd0deee22de3cf5`。

runtimeVersion：`ohos-fa5c3bfd2e7c3eb2918c5fc0`。

当前目录 ZIP SHA256：`8b35f70b2c6cd16f58b54a5bb54cd1dc745d22a435cbe0a6e91c250a256c822d`。

### 新一轮冷热启动

每个变体5组，组内cold→warm、变体首发次序交替，共20次真实严格回合。before是同27pins的未裁剪npm前缀加显式独立的同源process/lifecycle/capabilities目录；after是上述确切组成产物。两者文件布局、模块解析路径不同，所以该对照衡量这两个完整布局，不能把全部差异归因于某一个裁剪规则。

cold指空V8 compile-cache，warm指新进程/home/workspace复用本组前轮缓存。没有清OS页缓存，没有独占CPU；逐轮保存load average、缓存文件数/字节、启动/首回合时延和完整报告。每轮都必须真的完成五工具与两审批，失败不进入成功统计。

单位 ms，每格为中位数（最小–最大）：

| 布局 / cache | URL ready | Host ready | 首完整工具回合 |
| --- | ---: | ---: | ---: |
| before / cold | 4199.8（3892.3–6552.0） | 4654.9（4350.0–7346.2） | 3068.1（2260.0–7684.7） |
| before / warm | 5005.8（3590.3–9486.0） | 5489.9（4220.2–10018.6） | 3290.2（2188.0–7002.5） |
| after / cold | 5271.3（5094.8–6373.5） | 5937.4（5713.0–6894.1） | 2606.2（2398.4–4639.6） |
| after / warm | 5929.9（4248.3–9254.0） | 6591.2（4800.9–9905.8） | 3757.7（2127.6–12140.9） |

20轮全部通过，前后缓存均为1,826文件；before约9.00 MB，after约9.04 MB。after的URL/Host ready中位数在本轮没有降低，warm也没有稳定优于cold；共享机器负载、布局差异与每格仅5个样本不支持“裁剪必然加速”或“缓存必然更快”的结论。要判断设备收益，应在安静目标环境固定同一布局进行更长配对测量，并另核实际缓存命中和真实HAP安装。

## 六、实际验证及保留边界

| 验证 | 本轮结果与范围 |
| --- | --- |
| 完整实际组成与归档回读 | PASS；所有manifest文件SHA/size/集合一致 |
| 必需入口实际ETS逻辑 | 7/7；另输入/漂移门12/12 |
| 静态导入审计器边界 | 11/11，包括非启动图、ESM扩展规则、Node条件、越界、精确白名单和语法错误 |
| 实际payload原进程矩阵 | JIT156/156、strict156/156；只改测试import位置，断言可逆恢复原字节 |
| 实际payload专项 | 10/10；Node Worker、任意stderr字节、真实虚拟Git/归属、SQLite、diff、Bash及不可用分支 |
| 实际payload新vendor边界 | 5/5；真实OpenAI ESM/CJS签名、异步摘要、Kerberos拒绝和gzip/tar边界 |
| 原样Host路径完整回合 | 标准模型与Node脚本模型两组，均五工具、两审批；生成profile及运行树未变 |
| 真实ETS逻辑/FS通道回归 | 32/32；含中断、升级、日志、懒加载、技能及28方法契约；不是Ark编译 |
| O9对真实payload扫描 | 543包、其中296 bundled；197 usable、346 partial。静态标签不代替运行担保 |
| Android | 保护源码不变、目标pins不变、39个真实受检vendor输入经原patcher输出相同；完整输入清单上的逻辑目标树一致；两ABI真实shell recipe输入及后缀一致 |

Android验证为节约磁盘只复制所有pins涉及的vendor文件，用实际patcher执行；未被patcher处理的文件使用完整原始前缀清单。报告明确区分这一逻辑树证明与另建完整npm树/实际APK。两ABI外部归档采用相同小夹具，仅用来验证真实shell配方，不能称Android镜像构建完成。

保留两类失败证据：静态导入门的初始真实失败与被修正的依赖/裁剪；夹具自身的路径排序、误把专用DSH preload用于非DSH测试入口等准备错误。后者没有通过放宽产品断言解决。此前独审确认的两个独立重定向打开同一路径截尾问题仍属于基底既有边界，本包没有扩大其语义承诺。

后续验收包括：追加10单归档及流式安装的真实大树/中断/增量测量、root新增Ability生命周期控制合入后的重新组成与实际Host回合、目标ABI/HAP/设备验证。设备后台保活、受限时间内恢复和任意插件可用性均不能由本次Linux通过直接推出。

## 合 main 时的 OH 删除变体

`compose-runtime.py` 的 `deletion_variants` 钉了 `runtime/session-deletion/core.mjs` 和 `runtime/bridge/dsh-go-bridge/lib/session-deletion.js` 的前像、后像 SHA。main 改了其中任何一个，组成都会以 `OH deletion source changed` 拒绝，不会静默打错。

遇到这个拒绝时：

1. 读 main 的改动，确认 `session-deletion-ohos.diff` 的语义还成立；每个 hunk 的旧块必须在新源里唯一匹配，否则重切这份差分。
2. 更新 `deletion_variants` 里两个文件的前像和后像 SHA。
3. 重跑 `composition-inputs.test.py`、`session-deletion-publication.test.mjs`、`session-deletion-sync/directory-sync.test.mjs` 和 `host-layout.py --assembled-payload`。

组成物里的 `dsh-session-persistence-jsonl/lib/index.js` 如果也变了，`dynamic-omissions.json` 里它的 `importerSha256` 要一起更新。Android 不走这条路径。
