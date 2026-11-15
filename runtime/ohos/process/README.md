# O4a：鸿蒙批量虚拟进程后端

**本项是 O4 的可复核子集，不代表 O4 全部完成。未在真机核实。** 历史 O4a 固定基底 `afb5cdd`、DSH `0.2.1-rc.4`、Node `24.22.1`。**历史 v3 完整替代 v1/v2，不叠加应用。** 第二波 `c818155` 后续增加了 [外层语句分段输出](O4-statement-output.md)：`bash` / `sh` 完成一个外层语句即交付该语句的输出，单个命令、管道和复合语句内部仍有缓冲。`2c2e799` 后继按追加2提供 [Node 专属 Worker](O4-Node-Worker.md)，可用时 O6 报 worker-rebased。stdin 仍为批量，交互字节通道不可用；基底已包含 O4b 的受限 Git Worker、父线程临时文件归属和真实工作区快照，具体范围见 [GIT.md](GIT.md)。本次实际组合同时保留 Git 异步清理门与 Node 输出排空门。

M4-1 v2 在此基线上恢复 DSH JSON grep 的正向 `include` 和 Unicode 常用字符类/词边界，具体构建链、差分与边界见 [M4-1.md](M4-1.md)。本组合版本已包含 [M4-2](M4-2.md) 的搜索与执行双队列，以及后继 [M4-3](M4-3.md)、[M4-4a](M4-4a.md)、[M4-4b](M4-4b.md)、[M6-1](M6-1.md)、[M6-2](M6-2.md)，各自范围与仍存在的差异见对应说明。

## 接入与行为

Cordis 的 `subprocess` 提供者改为本目录的 `index.mjs`，`sandbox` 提供者改为 `sandbox.mjs`；**保留原 `@deepseek-ai/dsh-bash-sandbox`、`dsh-sandbox-policy`、`dsh-user-approval` 和 `tool-bash`**。后两者继续负责逐会话策略与单次审批。不要直接把 shell 换成没有 `sandboxMode` 的 `LocalBashExecutor`。DSH overlay 的 `name` 是匹配断言，不能用同 id 加新 name 来换实现：应禁用旧条目，再插入 `ohos-subprocess` / `ohos-sandbox` 新 id；服务注入名仍为 `subprocess` / `sandbox`。该差异已在主代理的真实 App 启动中定位并验证。

示例 subprocess 配置：

```json
{
  "workspaceRoots": ["/应用已授权的工作区"],
  "temporaryRoot": "/应用私有临时目录"
}
```

目录必须已存在，配置只来自宿主。没有传 `temporaryRoot` 时，服务用 `mkdtemp` 建立独立目录。所有根先经 `realpath` 规范化；拒绝把 `/` 授为根。不要把共享 `/tmp`、整个用户目录或其他应用目录配置为临时根。虚拟环境中的 `TMPDIR` 强制指向本服务的私有临时目录。服务的只读 `temporaryRoot` getter 供随后工作区快照适配器取宿主授权目录；不能用任意 env 扩大授权根。

`sandbox.confine()` 发放随机、单次的 argv 票据。策略留在宿主 Map 中，不放进可伪造的环境变量；prepare 与 spawn 解封后的实际 argv 共用无 NUL / 非空命令校验；票据不能把非法脚本藏在外壳后绕过原子进程限制。spawn 在进入队列前消费票据，重复使用、任意猜测和取消后的票据均被拒绝。`read-only` 拒绝所有受限 FS 写方法；`workspace-write` 将可见的工作区收窄到该调用的会话根。原工具层获准的 `danger-full-access` 也只能访问宿主启动时授权的根。

shell 任务在独立 `worker_threads` 中运行已固定的 just-bash 解释器；直接 node 任务使用其自身脚本 Worker。同一服务使用两个 FIFO 队列：直接 `rg` 独占一个搜索槽，其余命令共享一个执行槽，最多两个顶层任务。bash 的 node 命令和脚本创建的后代 Worker 可增加线程数，不能继续把两槽写成整个进程最多两个线程。写任务仍串行；长 bash 不再阻塞直接搜索。bash 内部调用 rg 仍在执行槽，因为同一脚本可能同时写文件。搜索可能观察到同时执行任务或外部编辑器正在修改的文件，不宣称快照一致性。

宿主主线程与普通 Worker 的 cwd/fs 不由 Node 脚本适配器改写；只有专属脚本 Worker 按追加2重定位 `process.cwd/chdir` 与固定公开 fs 路径表，并明确拒绝 child_process。`python:false`、`javascript:false` 禁用 just-bash 自带可选运行时；node 是单独的受控入口。`defenseInDepth:false` 防止 just-bash 改写宿主内建入口。公开 JS 路径检查不能控制原生 addon、process.binding 或未重定位的后代 Worker，不宣称能安全承载不可信任意 JS。

追加13增加独立的产品 `child_process` 边界：唯一产品 preload 在 network、publication 和插件加载前，且仅在 `process.platform === "openharmony"` 时，替换 `spawn`、`spawnSync`、`exec`、`execSync`、`execFile`、`execFileSync`、`fork` 与 `ChildProcess.prototype.spawn`，同步 ESM 导出，并抛出固定 `ERR_OHOS_NO_SPAWN`。普通 Worker 继承该边界；协议1的专属 Node 脚本 Worker 随后仍使用既有 `ERR_OHOS_CHILD_PROCESS_UNAVAILABLE`，保留原契约。`worker_threads` 和上述虚拟命令继续使用线程。该公开 JS 入口边界不是 OS 沙箱，也不保证拦截在唯一产品 preload 之前已捕获的旧同步函数引用。

OHOS 专用 MCP 补丁对 `transport: stdio` 在建立连接和注册重连副作用前明确拒绝；错误包含服务器名称、`ERR_OHOS_NO_SPAWN` 和改用 `streamable-http` 的建议。普通可选 MCP 服务器显示失败，HTTP MCP 继续原连接和取消路径；原有必需插件失败策略保留。Android 的补丁选择和已安装运行时字节不变。

`ReadWriteFs` 的路径和符号链接检查能拒绝已存在的越界链接；检查与后续宿主文件操作之间不是原子的，不能对抗另一个宿主调用同时替换路径的竞态。因此返回的 `sandbox.enforcement` 是 `partial`。这不是完整 OS 沙箱，真机验证也不能把这一结构边界消掉。

## 与原 DSH 契约的对应

| 项目 | 当前实现与边界 |
| --- | --- |
| spawn / handle | 同步返回 handle；启动前已取消、非法 graceMs 与空命令在分配 worker 前同步拒绝；`done`、`terminate`、`waitForExit`、stdout/stderr 收集保留原形状。未知可执行命令返回 127 和题面要求的中文信息。 |
| 环境 | 复用 `dsh-subprocess.scrubbedParentEnv()`；显式 env 在其后覆盖，`undefined` 删除变量。不把父进程其余 `DSH_*` 身份和凭据透传给 worker。 |
| 参数 | argv 原样传给解释器；`bash/sh -c` 的脚本只在该语法位置解析，普通位置参数不做第二次插值。仅接受固定虚拟别名，任意 `/另一个目录/bash` 不会按 basename 偷换成 bash。 |
| 取消 / 超时 | 原 bash 执行器决定 timeout / aborted 分类，后端终止 worker 并等待其实际退出；排队任务也可取消。已发生的文件写入不会回滚。 |
| 尾部 / spill | 直接复用纯 JS 的 `dsh-subprocess-local/output` 导出；独立偏移读取、尾部截断、spill 上限及超限后不提供不完整 spill 文件沿用原行为。 |
| 输出时机 | OHOS 私有构建在外层 shell 语句完成后交付 stdout/stderr；取消保留已经交付的前缀。单个命令、管道、循环、函数、嵌套 shell 等复合语句内部继续缓冲，取消时其中尚未交付的输出可能丢失。raw pipe 及原 OutputCollector 的字节、尾部与 spill 语义保留，具体测试见 [外层语句分段输出](O4-statement-output.md)。 |
| stdin / control | 仅 ignore 和一次性 `{data}` 输入；交互 pipe / control 明确抛 `ERR_OHOS_STREAM_UNAVAILABLE`。没有 PTY。 |
| 内存和文件规模 | just-bash 受限 FS 单文件读取及复制上限 64 MiB、解释器输出上限 64 MiB。Node 的公开 fs 并未套用该文件大小上限；批量 stdin 与 bash 内 Node 命令输出各限 64 MiB。各顶层脚本 Worker 的 JS old-generation 上限 256 MiB，不限制 Buffer/native 分配或整个进程 RSS。 |

## rg 范围与真实差分

`dsh-tool-fs-search` 的命令模板、超时、输出上限、错误分类与 NDJSON 消费保持原路。仅 OHOS/显式进程内仿真标记下把 resolver 指向虚拟 rg；JSON 只交付 DSH 实际消费的 `match` 记录，不提供 ripgrep 的统计、summary 或上下文格式。

M4-1 已恢复该 JSON 路径的正向 include：`*`、`?`、`**`、花括号选择与字符类，并实现有序正负 override、目录剪枝、隐藏条目及本地 ignore 优先级。glob 按固定 rg 的 UTF-8 字节语义工作：`?` 是一个字节，`???` 可匹配一个三字节汉字；类内反斜杠是字面成员，不能解释成文本正则的 shorthand。模式与路径仅在匹配时经可逆的 byte→Latin1 标量映射，实际 FS 路径不改变。显式文件始终越过这些过滤，显式目录作为遍历根；没有文件被隐式根搜索到时返回 2，已有文件但无匹配返回 1。祖先规则只通过受限 `ctx.fs` 读取；授权根以外的 ignore 不可见，不能因此放宽文件系统边界。

JSON 正则通过仅供 OHOS rg 使用的 re2js 1.3.3 私有源码构建，支持 Unicode 16 的 `\w/\d/\s/\b` 及反类、类内组合、分组/选择与量词。词边界在匹配引擎的零宽上下文中判断，不能用匹配后过滤冒充任意模式语义。UTF-8 字节偏移、CRLF、无换行末行、空模式、BOM、固定字符串和大小写样本均有原生差分。仅跳过文件最前的一枚 UTF-8 BOM；后续 BOM 按原字节保留。

默认大小写、明确路径、负向 glob、常规 Unicode 属性、单个开头 `(?i)` / `(?-i)` 保留；`--files --no-ignore --hidden --sort=modified` 沿既有有限模板，相同 mtime 用路径稳定排序。非 JSON 的新增常用字符类/词边界和正向 include、`--files` 的 `**`/花括号正向 glob、局部/组合正则标志、未知参数和含换行符的显式路径仍报 exit 2。默认显式二进制搜索要求 `--text`；JSON 无效 UTF-8 拒绝，尚不实现 UTF-16/其他编码。`.git` 文件式 gitdir 在 JSON 目录遍历中明确报错；外部全局 gitignore 与 `core.excludesFile` 不读取，全部 gitignore 极端语义没有等价保证；原始非法 UTF-8 文件名未计入兼容范围。

固定原生参照是 DSH 随包 ripgrep 15.0.0（rev `3a612f88b8`），二进制 SHA256 `193906679498de4d939345b937fa24e0e69a03c244bd70c859f5e41232713f21`。M4-1 v2 的 93 项差分在 JIT / 严格 O0 各 93/93；原 33 项为 32 相同和 1 项明确拒绝的默认显式二进制。完整标量检查含 1,112,063 个有效非 LF 标量及 LF 单独验证；单点穷举不代替多码点、嵌套零宽位置矩阵，二者分开保存。前版 include/词边界拒绝、错误 stdin 夹具以及 BOM 新失败记录均保留。M4-1 v1 `5fdebda8…` 被独审判 BLOCKED：字节 glob 的四项真实 DSH 用例失败；v2 修复该问题，保留原报告，详见 M4-1 证据。

JSON 搜索路径的单次读取和 4 MiB 单行预算见 [M4-3](M4-3.md)，非 JSON 路径仍保留原预检；本项不以 64 MiB FS 文件上限充当总内存上限，也不宣称完整 ripgrep 兼容。

## 安装与复跑

M4-4b 后继使用固定 just-bash 3.6.0 的 OHOS 私有 ESM 构建，以恢复越界读取的 EACCES 诊断及合并输出的字节标记；构建方式、先失败证据与仍存在的上游边界见 [M4-4b.md](M4-4b.md)。Worker 启动前须运行下面的 `build-just-bash.py`，生成物不随源码补丁提交。

manifest 中直接声明的运行时依赖保持题面已批准的 `just-bash 3.6.0`（Apache-2.0）与 `isomorphic-git 1.44.9`（MIT）。本项还直接依赖原锁闭包中的 `re2js 1.3.3`（MIT）来生成仅供 rg 使用的私有构建，修改其非生成源码；不改原 npm 包、原 Unicode 表或其他消费者，也没有安装新的 ignore/glob 依赖。它不再只是调用未修改 re2js 的公开 matcher：构建耦合包括固定 sourcemap 与其中 24 个源码的身份。追加6已要求把 re2js 记录为 manifest 直接依赖，由主线 M4-6 独立落实；本包不抢改该锁文件。生成脚本复用已批准的 esbuild 0.27.3；`build/` 产物不提交，完整 MIT 归属保留在产物头部。

O4b 的 `git-diff.mjs` 直接导入同一原锁闭包中的 `diff 8.0.4`（BSD-3-Clause），该包原由 just-bash 传递引入。这里没有增加、升级或重新声明依赖，`package.json` 和 `package-lock.json` 保持基底字节；O2 的最终组成必须保留 `node_modules/diff` 的 ESM API、包声明和 LICENSE。依赖闭包、实际入口及许可仍须按最终分发文件复核。

从 `afb5cdd` 根目录应用独立补丁后，使用官方 Node 24.22.1：

```bash
git apply O4a-virtual-process-v3.patch
export PATH="/Node-24.22.1/bin:$PATH"
npm ci --prefix runtime/ohos/process --ignore-scripts --omit=optional
node runtime/ohos/process/link-dsh.mjs /已装DSH的独立prefix
# 应用 M3-3 标记迁移与本 M4-1 差分后：
node runtime/ohos/process/build-rg-regex.mjs /已有esbuild0.27.3的prefix
python3 runtime/ohos/process/build-just-bash.py
```

DSH 厂商包补丁为 `runtime/patches/ohos-virtual-process.diff`，`pins.json` 只登记 `0.2.1-rc.4` 两个文件的 before/after SHA256。完整 OHOS 前缀用 `runtime/lib/rtbuild.py patch-dsh --prefix ... --dsh-version 0.2.1-rc.4 --target ohos`。阶段验证只要本 diff 时，把它拷到临时补丁目录，旁边放一份 schema 2 的 pins：`targetSets` 为 `{"android": [], "ohos": ["ohos-virtual-process.diff"]}`，`patches` 只含本项条目；再传 `--patches <临时目录> --target ohos`。不要对指向共享 npm-ci 包的符号链接树运行全部厂商补丁。

```bash
NODE=/Node-24.22.1/bin/node \
OHOS_TEST_PROCESS_PREFIX=/仅应用O4厂商补丁的独立prefix \
OHOS_TEST_BASE_PREFIX=/未修改DSH的prefix \
OHOS_SIM_PRELOAD=/已复核O0/runtime/ohos/sim/preload.mjs \
OHOS_ESBUILD_PREFIX=/已有esbuild0.27.3的prefix \
bash runtime/ohos/process/test.sh
```

`process.test.mjs` 24 项、`process-integration.test.mjs` 17 项、`process-policy.test.mjs` 8 项：普通 Node 与 O0 严格仿真各 49/49，0 skip、0 TODO。Android 条件对照 3/3：两个 OHOS 服务不能误挂载、rg 原 resolver 与 Promise 契约不变、实际注册的工具 description/schema 逐字相同。审批测试走真实 ToolRuntime、Session、SandboxPolicy、ApprovalService；用户答复是测试事件通道中的显式 allowed-once/rejected，未以绕过审批的 stub 替代执行路径。

O0 环境同时启用 `--jitless`、删除 WebAssembly、禁用所有 `child_process` 入口、限制 dlopen、link 模拟 EACCES。测试证明的是这个 Linux 宿主仿真范围，尚不证明 OpenHarmony 真机性能、SDK/宿主 worker 支持、文件系统竞态或后台冻结行为。

## v1/v2 失败与 v3 修复证据

v1 的独立审查 `cb25400e…` 为 BLOCKED：缺失路径和合法零宽正则都可落为 exit 1，真实 DSH 将其误读成 `noMatches:true`。原独立夹具的断言未改，冻结 v1 为 2 PASS / 2 FAIL，v2 候选为 4 PASS；另外两项只读写入口和延迟管道收尾原本就通过，不能说成四个实现缺陷。

主代理另外实际复现：直接 spawn 拒绝 NUL 命令，prepare 后却可执行。v2 已增加真实 tool-bash / sandbox.confine / 直接 spawn 三路径回归，非法命令在分配 worker 和票据前被拒绝。v2 独立复核还发现一个既有缺陷：显式给出 `.gitignore` 忽略的文件时，借用 just-bash `--files` 会过滤该文件，真实 DSH 相对与绝对路径均误报零结果。v3 只把显式文件从目录遍历中分开：已指定文件按受限 FS 读取，目录仍沿原规则；没有全局关闭 ignore。新增真实 DSH 的 ignored/hidden/负向 glob 回归，审查方默认遍历的负对照也必须保留。

冻结前并行负载曾令一个普通 shell 成功测试超过夹具原 2 秒预算。仅将普通成功用例共用的 fixture 默认预算改为 15 秒，显式 timeout 回归仍是 120 毫秒，生产代码的预算与分类未变；旧失败日志保留。正式结论以绑定补丁 SHA256 的独立复核报告为准；该 v3 历史结果不覆盖当时未实现的 include；M4-1 的 include 结果单列。当时未实现的 Git 由本次 O4b 单列验证；历史通过不能作为新功能的证据。

## 可核对的源材料

- 固定 npm-ci 包 `@deepseek-ai/dsh-subprocess`、`dsh-subprocess-local/lib/runner-launch-B2zsQ1Dz.js`：stdio、生命周期与收集契约；仅导入其公开的纯 JS output 子路径。
- 同版本 `dsh-tool-fs-search/lib/index.js`：`buildGrepCommand`、`buildGlobCommand`、`runRipgrep`、`parseGrepMatches`；真实集成测试直接调用这些函数。
- 同版本 `dsh-tool-bash`、`dsh-bash-sandbox`、`dsh-user-approval`：工具审批先于执行，策略来自会话，批准只对单次调用有效。
- [just-bash 官方项目](https://github.com/vercel-labs/just-bash) 与锁定 npm 包的 ReadWriteFs/MountableFs/CommandContext 声明及 rg bundle。
- [Node 24.22.1 worker_threads 文档](https://nodejs.org/download/release/v24.22.1/docs/api/worker_threads.html)。
- [isomorphic-git 官方文档](https://isomorphic-git.org/docs/en/quickstart)：本次 Git 子集使用固定 1.44.9 包；独立 index/object 环境及真实 DSH 工作区快照的验证见 GIT.md，不能把支持的子命令理解为完整原生 Git 兼容。

- [RE2JS 官方项目](https://github.com/le0pard/re2js) 及锁定包 1.3.3 的 matcher(number[]) / find / start / end 公开 API；字节坐标以原生差分为证据；M4-1 的私有源码改动与生成流程另见该文。
- [ripgrep 官方指南](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md)；本文具体行为数据由随 DSH 分发的 15.0.0 实测，而非以最新版文档代替已锁版本。

## M3-3 进程内标记迁移

本附属差分只在已审 O4a v3（补丁 SHA256 `2f134c973c565b0b771acdff483537e85a844ee6d7faf5ad5cdea12d418c2581`）上迁移门控。生产服务、rg resolver 与 bash 说明只判断 `openharmony` 平台或显式预加载设置的 `Symbol.for('dsh.go.ohos.sim') === true`，不再读取旧 `DSH_GO_OHOS_SIM` 环境开关。

测试先应用 M3-3 主包，以取得 `sim/marker.mjs` 与新版完整预加载器。`test.sh` 的 Android 组故意携带旧环境变量，JIT 组只加载 marker，严格组加载完整 O0。Worker 不靠环境变量建立标记，而由默认继承的 `--import` 再次运行预加载；仅显式仿真下转发平台覆写配置。没有改动 argv 校验、权限票据、命令注册、rg 搜索语义或取消实现。

O4a 原有范围与限制不变；本迁移不把尚未完成的 node 脚本、实时输出或 O4b 硬取消宣布可用。
