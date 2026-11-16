# 鸿蒙插件静态兼容性扫描

## 判断对象与边界

此工具对实际 npm 原包或固定安装树做静态筛查，检查原生二进制/编译输入、`child_process` 及常见进程执行依赖、Wasm、`bin` 与安装脚本。它不导入插件模块，不执行包内 JavaScript、shell、生命周期脚本或二进制；读取目录时拒绝符号链接，读取 tarball 时沿用既有压缩/展开/条目/路径检查与 SHA-512 核验。

目标条件来自本轮已确定的运行时约束：OpenHarmony arm64、Node 24.22.1、无 JIT、无可用 Wasm 执行通道、无外部进程。普通插件原生模块必须由 HAP 固定白名单另行提供。扫描器是桌面构建工具，不随手机执行。

| 状态 | 含义 | 不能推出的结论 |
| --- | --- | --- |
| `usable` / 可用 | 已扫描范围未发现本扫描器覆盖的阻断；若使用安装树模式，还核对了所声明必需依赖的实际位置和版本 | 已在真机运行、业务功能正确、没有动态加载或间接调用 |
| `partial` / 部分可用 | 存在功能限制、未核依赖或其他证据缺口 | 一定存在可运行子集；某条静态引用一定会被执行 |
| `unavailable` / 不可用 | manifest 明确排除目标 os/cpu，或无 exports/DSH bundle 替代入口且唯一 main 为原生/Wasm 文件 | 已测量到真机崩溃；绕过 manifest 后仍必然不能运行 |

每份结果都包含 `deviceValidated: false`、扫描器版本、范围、目标条件及文件清单内容指纹。文件证据带 SHA-256，源码引用另带行号；每类最多列 12 处定位，但扫描仍覆盖全部输入文件。`ownStatus` 与最终 `status` 分开，避免把依赖里的 CLI 当成当前插件自身代码的执行证据。

五类功能存在不自动使整个包为不可用。例如 isomorphic-git 的 CLI 与 API 不同；`bin` 只能说明命令入口受限。字符串/注释、平台守卫之后的分支、开发或测试脚本会带来保守命中；动态拼接、混淆、间接调用与嵌套归档可能漏检。扫描器不做调用图可达性证明，也不覆盖所有平台 API。源码引用不能取代已完成的实际 DSH 回合；反过来，一次成功回合也不能替代所有插件功能测试。

## 依赖覆盖

单包模式如实列出未遍历的 `dependencies` 和必需 peers；有任何未核必需依赖就不能获得干净判断。可选依赖另列，相关功能仍需单独核实。

安装树模式按实际 `node_modules` 向上查找规则定位包，不重新解析网络版本，不安装缺失依赖。它对完整的 manifest 必需闭包遍历并去重处理循环，使用固定 semver 库检查版本范围；不把普通范围自动当成允许任意 prerelease。缺包、范围无法核验或版本不匹配均记为不完整。可选依赖不纳入必需闭包，报告不会把该范围称为全部运行路径。

`os/cpu` 的字符串、数组、单独 `any`、否定项与混合项语义，已和实际 npm `npm-install-checks` 实现作 32 组对照。隐式 node-gyp 规则核对了实际 `@npmcli/run-script`：存在 `binding.gyp`，且未关闭 `gypfile`、没有 preinstall/install 脚本时才记隐式安装构建。输入源路径与 hash 随交付证据保存。

## 可重放命令

在 `market/` 中按现有锁运行 `npm ci --ignore-scripts`。没有新增依赖，`package-lock.json` 不变，SHA-256 `a2624fefc46dc7521c2e758f5ba8a4f6fa5b1f9ec0fe816a25dc27f6cf6a5754`。以下输出文件或目录必须尚不存在，避免覆盖旧报告：

```sh
# 单个已展开包，不遍历其 node_modules
node scripts/ohos-scan-cli.mjs --package /absolute/package-dir --out /absolute/package-report.json

# npm 原始压缩包；必须给出该版本原始 SHA-512 SRI
node scripts/ohos-scan-cli.mjs --tarball /absolute/package.tgz --integrity 'sha512-...' --out /absolute/tarball-report.json

# 已固定的最终 payload，闭包不向目录外扩展
node scripts/ohos-scan-cli.mjs --installed /absolute/runtime-root --out /absolute/new-bundled-report

# 本交付原包快照；manifest 绑定每个包的 URL、版本、SHA-256 与 npm SRI
node scripts/ohos-scan-cli.mjs --snapshot /absolute/npm-snapshot --out /absolute/new-market-report

# 给既有 sidecar 加数据；先核 name/version/integrity，保留其他字段和平台
node scripts/ohos-scan-cli.mjs --apply-sidecar /absolute/dsh-go.json --data platforms/ohos-2026-11-02.json --out /absolute/new-dsh-go.json

# 直接在同一 Node 进程运行测试；本次 33 项实际执行，不计空子进程为测试
node --test --test-isolation=none
```

`--installed` 的 `all-packages.json` 保留整个已读依赖树；`bundled.json` 与表格按安装路径选取 `@deepseek-ai/dsh-*` 及两个本地 runtime 包。该筛选包含 API/support 包和重复安装版本，**不是当前 profile 中活跃插件的计数**。

## 2026-11-02 固定快照结果

正式市场条目采用 `c818155` 的五个精确版本。其中两份原包直接复用仓库 2026-10-30 夹具；其余从 npm 原站读取精确版本并验证 SRI。没有执行 npm 安装。所有原包、原始精确版本元数据、来源 URL、hash 与读取命令单独封存，可离线重放。

| 包 | 版本 | 静态判断 | 主要证据 | 依赖覆盖 |
| --- | --- | --- | --- | --- |
| @ccch1mneyyy/dsh-media | 0.2.1 | 部分可用 | unresolved-dependencies | not-traversed |
| @liustack/modlens | 3.27.2 | 部分可用 | bin、child-process、unresolved-dependencies | not-traversed |
| @liustack/modsearch | 5.10.11 | 部分可用 | bin、child-process、unresolved-dependencies | not-traversed |
| @xmanrui/dsh-im | 5.8.0 | 部分可用 | bin、child-process、optional-dependencies、unresolved-dependencies、wasm | not-traversed |
| dsh-context | 0.78.2 | 部分可用 | unresolved-dependencies | not-traversed |
| dsh-univer-office | 0.3.9 | 部分可用（未完成扫描） | package-too-large | not-scanned |


媒体包与上下文包本体没有命中上述五类，但所声明的必需依赖未下载/扫描，所以仍为 `partial`。modlens/modsearch 命中 `dist/main.js`、`dsh/spawnHidden.js` 和 shell 技能脚本；这不是对图像/搜索主路径作已不可用的判断。dsh-im 命中进程相关路径及 WebAssembly 引用，并有可选 sharp/agently-cli；报告保留具体路径与行号，不推断每个渠道都失败。

候选 office 原始压缩包 44,566,924 字节、SHA-256 `ea196132b2115f0123f0423b695740f54db4d9ce2a190bd69e2250af0fd41596`，其 npm SRI 已核实。展开触发既有 `package-too-large` 上限，因此未完成包内身份及代码扫描，`runtimeVerdict` 明确为 unknown。它不是正式市场五条之一，不进入本次应用数据补丁；未降低归档上限来给出结论。

随包输入为实际 O2 组成最终树，ZIP SHA-256 `3f295a96f390d83cc4030e4fadde375771e7dfe6dee12a472d65626b353917a5`。代码子集为 c818155 + O2-native + O4 流式 + O2-composition；**没有 O6、O4b、新市场拒绝或后继主线基底**。随后全栈需要重组并再扫，不能沿用本表作新输入的证明。

| 扫描范围 | 条目 | 可用 | 部分可用 | 不可用 |
| --- | ---: | ---: | ---: | ---: |
| 完整实际安装树 | 545 | 198 | 347 | 0 |
| 随包 DSH/local runtime 选择 | 296 | 2 | 294 | 0 |

随包选择的包自身为 286 条无命中、10 条有命中；加入必需依赖后出现上述更多 partial。必需依赖覆盖完整 277 条、不完整 19 条。Cordis 等依赖中的 CLI 或安装辅助代码会保守传播，因此统计不能解读为“只有两个功能能用”。完整 296 行结果表和 JSON 均随交付保存。

## 市场数据字段的来源与兼容性

`core.scan` 从已核验 tarball 的实际文件产生 `report.platforms.ohos`。`build` 将压缩摘要写入 sidecar 的 `plugins[name].platforms.ohos`，同时 `makeIndex` 写入格式 1 的 `metadata.platforms.ohos`，并继续调用官方 `parseMarketIndex`。作者提交的条目 JSON schema 没有放开此字段，不能自填“可用”。

`platforms/ohos-2026-11-02.json` 是实际 snapshot 命令生成的数据补充。应用时逐条核对名称、版本和 npm integrity；不覆盖风险、tier、标题、其他平台或版本。两个真实历史 npm/advisory 夹具已实际经过可信 build、数据应用 CLI 和官方格式 1 解析，非 OH 字段保持不变。该夹具不是当前在线安全查询，本补丁没有发布索引。

现有 Flutter sidecar 读者只读取已知键，源码表明额外元数据会被忽略；本补丁不加入 UI 展示，也未运行 Flutter/SDK/设备验证。兼容性字段不能绕开 O2 的应用内插件包管理拒绝。

## 已执行验证与未完成门

本轮最终源码的 33 项离线测试全部实际执行，包含现有 24 项市场检查与新增 9 项；完整日志保留 stdout/stderr。另有实际 npm 平台条件 32 组对照、单 tarball CLI、单目录 CLI、5 原包 + 1 明确 blocked 候选扫描、545 包闭包扫描及实际 sidecar 数据应用。

所有改动在 market 源码/数据/文档，没有改变 Android 运行时输入。实际 recipe helper 输出仍为 3,789 字节、SHA-256 `67a8c2a119a9d254ba27f6e657f11fca73ee30de499a723f2084f57f213f5f39`。没有重新构建 APK 或 HAP，也没有鸿蒙设备。

要将 static 标签升级为功能兼容结论，需要：补齐被声明但未覆盖的实际依赖字节；对命中路径证明不可达或提供受支持的实现；使用最终完整 HAP 对每个目标插件的必要操作进行测量，特别是渠道登录、网络、文件与资源限制。本工具不会自动做这种升级。
