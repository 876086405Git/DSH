# O4b：受限 Git Worker 与父线程资源生命周期

本补丁以续作快照 `c818155` 为基底，使用已锁定的 isomorphic-git 1.44.9。它增加直接 `git` 与 shell 内 `git`，两条路径共用同一个 custom command 和受限文件系统。没有调用系统 Git、启动新进程、全局替换 Node builtin 或读取环境变量来开启仿真。测试里的 native Git 仅用于生成对照；严格通道读取该对照，不调用 native Git。

Linux Node 24.22.1 的 JIT/`--jitless`、真实文件、真实 Worker、原 DSH 0.2.1-rc.4 与真实 ownership native fixture 是本次已测范围。OpenHarmony ABI、HAP、设备时序与存储行为未在本补丁中编译或核实。

## 可用命令与边界

| 命令 | 已实现接口 |
|---|---|
| `init` | 一个目录；`-b` / `--initial-branch`，`-q` / `--quiet` |
| `status` | short / porcelain v1、`-z`、全部未跟踪文件；默认也是短格式 |
| `add` | 字面文件或目录、`-A` / `--all`、`-u` / `--update`、`-f` / `--force`、`--ignore-errors`；快照使用字面 `:(exclude)` |
| `commit` | `-m` / `--message`、`-a`、`--amend`、`--allow-empty`；不运行编辑器或 hooks |
| `log` | 一个起始 ref、`--oneline`、`-n` / `--max-count` / `-N`；长格式为本子集的确定格式 |
| `diff` / `diff-tree` | index/worktree 或一至两个 tree-ish、`--cached` / `--staged`、`--numstat`、`-z`、`--name-only`、有限重命名检测、字面路径 |
| `branch` | 列表、建立、`-d` 安全删除、`-D`；不支持列表 pattern |
| `checkout` | 切分支、`-b`、`-f`、`--` 后显式文件；显式文件模式会按该请求覆盖对应工作文件 |
| `clone` | HTTP/HTTPS、`--depth`、`--branch`、`--single-branch`；必须是空目标目录 |
| 快照 plumbing | `rev-parse` 的固定路径模板、`write-tree`、`ls-files --stage/-z`、`check-ignore --stdin/-z`、`ls-tree -r/-l/-z`、`cat-file blob <oid>`、仓库本地单键 `config` |

`git -C` 可以在原授权根内改变命令工作目录。未知子命令或参数返回 127，并附“这个命令在鸿蒙本机不可用，可以连接电脑执行”；仓库、路径或 I/O 错误一般返回 128，部分 Git 规定的结果使用 1。不能把命令列表看成完整 Git CLI 兼容承诺。SSH、URL 凭证、credential helper、push/pull/fetch/merge/rebase、任意 pathspec、外部过滤器、交互终端均未实现。

HTTP clone 显式使用 O5 的 `createFetch` / `createHttpDispatcher`，每次命令从实际 `CommandContext.env` 建 dispatcher，因此 shell 前缀环境也进入原代理规则；命令收束时销毁 dispatcher。没有修改全局 fetch。当前每份元数据 payload 上限为 64 MiB，超出明确拒绝；不承诺任意规模仓库。文本 diff 有 1000 ms 计算预算，重命名候选乘积限 10000。相同 blob 的重命名可精确识别，编辑后文本采用共同完整行字节比例；该启发式不是原生 Git 的完整相似度算法。

索引读取支持带 SHA-1 校验的 v2/v3 及 stage 记录。私有快照不把原 unmerged index 写回用户仓库；gitlink 以 160000 处理，不递归子模块工作树。`core.filemode` / `core.symlinks` 与原 packed objects/alternates 有对照样本，但索引 v4、split/sparse index、所有 Git 配置和非 UTF-8 路径不在兼容范围。

嵌套仓库也先受 `-u`、ignore、force 和字面路径选择约束。尚未跟踪的嵌套仓库不能因为存在 `.git` 而绕过这些条件；原来已经被外层仓库跟踪的子文件，也不能因后来出现内层 `.git` 而被改成一个 gitlink。已有 gitlink 的更新仍受原 tracked 语义保护。

工作树 diff 的 `core.autocrlf=true/input` 比较按字节处理 CRLF，不对原数据作 UTF-8 解码再编码。二进制判别、裸 CR、非 UTF-8 高位字节和已有 index CRLF 的行为有 Git 2.51.1 对照；磁盘内容保持原字节。该实现不提供完整 `.gitattributes` 或外部 clean/smudge filter 语义。

## 元数据归属与停止顺序

Worker 不能自行打开主 ownership ledger，也不能关闭它、取得它的进程级 flock 或修改 publication atomic 状态。`installPublication()` 成功后，主线程仅提供冻结的 `reserve` / `identify` / `release` 借用接口。读命令和空闲 job 不借用 ledger。

每个 Worker 有一个由主线程创建的资源服务。roots 来自既有 cwd/会话票据收窄结果，read-only 模式继续拒绝写入；Worker 消息不能带来新授权。每个 request 的 `protocolVersion` 为 1、`requestId` 严格递增，响应确认 ACK 在 Worker Promise settle 之前发出。五种操作如下。

| 操作 | 父线程职责 |
|---|---|
| `createIndex({target,content,mode})` | 持久 reserve；同目录独占创建随机临时文件；记录打开 FD 的身份、持久 marker/identify；完整写入种子，返回 job 局部 id/path |
| `writeIndex(id,content)` | 只改同一打开 inode，按位置处理短写，然后 truncate、chmod、sync；不另造 Worker 临时文件 |
| `writeMetadata({target,content,mode})` | 用同一分配、写入、真实 rename 与清理协议发布单个元数据文件 |
| `commitIndex(id)` | 仅允许完整持久写之后的 ready 状态；重新核验路径与持有 FD 的身份，真实同目录 rename 后释放临时归属 |
| `releaseIndex(id)` | 在持有 FD 的期间核验并删除本次确切临时对象，关闭 FD 后持久 release；不删除 final |

每次重写在第一处可失败 I/O 之前置 dirty；只有全部 write/truncate/chmod/sync 成功才重新 ready。真实 partial write、truncate 失败、sync 失败均不能继续 commit 部分索引。可通过一次完整重写恢复 ready；如果取消或 cleanup/ledger 失败，job 进入停止或失败流程。

`terminate()` 先同步封住资源入口。尚未开始的任务从这一刻不能再创建 Worker；已经开始的任务请求真实 `Worker.terminate()`，观察到实际 `exit` 后才进入收束。runtime 排空此前接受的父 I/O 和响应，精确清理仍活跃的资源并完成持久 release，然后固定失败状态，最后 settle `done` / `waitForExit` 并放行该 writer lane 后继 job。测试既在七个已开始的实际阶段暂停父操作，也覆盖 `spawn()` 同一调用栈立即 terminate、AbortSignal 和 dispose 的尚未开始边界；真实 async_hooks 观察 Worker 创建，未替换 Worker 或调度器。

已发出的 rename 若在取消之后成功，新的 final 保留。取消不提供整个 Git 操作的回滚；checkout/clone/commit 等多文件操作可能留下已提交业务更改。它保证此 job 的临时资源生命周期与完成顺序，不能把不同文件的发布描述成一个事务。

资源替换、cleanup、ledger 持久化或响应投递失败不会被取消吞掉；`done` / `waitForExit` / runtime dispose 会报告失败。dispose 在这些失败下保留临时根和归属证据，不进行递归删除。主 ledger 的既有 poison 与下次启动 marker 恢复机制继续生效。没有路径前缀扫描，也不凭关闭后的 dev/ino 回执猜测文件仍属于自己。

当前服务不实现原生 Git 的 `index.lock` 获取/重命名协议；对该路径的适配器 mutation 明确拒绝。正常写入通过虚拟 runtime 的同一 writer lane 排队，**不承诺与外部同时运行的原生 Git 写者互斥**。受限文件系统原有的“部分隔离”边界也保留；这不是抵御同 UID 恶意并发文件系统替换的完整内核沙箱。

## 原 DSH 工作区快照

新的 `ohos-workspace-changes.diff` 仅在 pins 的 OHOS target 列表中启用。原 provider 的临时目录在 openharmony 或显式仿真 marker 下取 `ctx.subprocess.temporaryRoot`；缺失或非绝对路径直接失败。其他平台继续使用原 `tmpdir()` 分支。

实际 `GitRunner` / `TurnRecorder` 通过受限 subprocess/Worker 执行私有 index、独立 objects 与 alternates。`GIT_INDEX_FILE` / `GIT_OBJECT_DIRECTORY` 等路径本身不扩权；对受限外部根和符号链接越界的测试继续拒绝。

端到端夹具 `runtime/tests/ohos/workspace-round-fixture.mjs` 初始化新的有效仓库，保留原五工具回合，在工具之外写“仅快照可见.txt”，并在基线快照完成之后移入一个被忽略、已有提交的嵌套仓库，再用生产 workspaceChanges 和真实认证 HTTP summary/diff 核对。它同时要求忽略/未变文件和该嵌套仓库都不出现、外层及内层 `.git` 所有文件及字节不变，因此文件工具退化记录不能满足断言。fixture 是测试插件，不进入产品 profile。

## 固定依赖与复现

`git-diff.mjs` 的 `diffLines` / `createTwoFilesPatch` 来自原 process lock 的 `diff 8.0.4`，BSD-3-Clause，原来是 just-bash 的传递依赖；这次成为源码直接引用。其锁 integrity 为 `sha512-DPi0FmjiSU5EvQV0++GFDOJ9ASQUVFh5kD+OzOnYdi7n3Wpm9hWWGfB/O2blfHcMVTL5WkQXSnRiK9makhrcnw==`。本补丁不修改 package manifest/lock，不新增或升级包。O2 需保留 `runtime/ohos/process/node_modules/diff/package.json`、`libesm/` 实际入口及 LICENSE；最终许可闭包按实际分发内容核验。

先按原构建说明 `npm ci`、构建固定私有 just-bash/rg 并将固定 DSH prefix 链接到进程依赖。前缀需应用 `rtbuild ... --target ohos`，其中 workspace provider 输出 SHA256 必须为 `027c3246d8174ad2c519fd989e0ab157eedbe3535a5afa41121dc05e5e5615d3`。测试所需 native/linked fixture 沿已有 O0/M3 生成方式，不是 OHOS 产品库。

```sh
# --output 必须是新的目录；--prefix 必须是自己的固定 DSH 副本。
python3 runtime/tests/ohos/run-owned-tests.py --node /absolute/node \
  --native /absolute/publication.node --linked /absolute/libpublication-test-linked.so \
  --sim-preload runtime/ohos/sim/preload.mjs --marker-preload runtime/ohos/sim/marker.mjs \
  --suite core --mode strict --output /absolute/new-owned-core
# 上项 --suite 另取 rpc、share；JIT 与 strict 分开运行。

python3 runtime/tests/ohos/run-git-tests.py --node /absolute/node \
  --linked /absolute/libpublication-test-linked.so --prefix /absolute/own-prefix \
  --suite worker --mode strict --output /absolute/new-git-worker
# --suite 另取 client、oracle、semantics。oracle/semantics 的 JIT 加
# --record-native 会重录本机 Git 对照；
# strict 只能重放，不能创建原生子进程。源码 SHA 被写入 oracle 并在重放时校验。
```

本轮保留旧18 worker 硬取消遗留临时 index、接管候选同 inode 重写失败仍可 commit，以及 v1 独审发现的三项实际失败：尚未开始的取消任务仍写文件、嵌套目录绕过选择规则、二进制被错误当作 UTF-8 处理。修复后仍保留旧“零临时文件”断言，同时按真实 ledger reservation 核对新临时路径与 token 均消失，不靠改名取得通过。新的 Git 选择/换行语义对照独立保存原生 oracle，完整实际回合也保留忽略仓库错误进入快照的前后证据。精确补丁 SHA、全部命令、stdout/stderr、原失败及最终结果保存在同交付包；只有独立审查绑定该 SHA 后，才记为通过。
