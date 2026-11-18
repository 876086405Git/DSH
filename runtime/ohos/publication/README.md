# M3-1 / M3-1b / M6-3b：不覆盖发布、持久归属与崩溃熔断

## 已实现的范围

OpenHarmony 的附件和会话 provider 继续使用 30 号包的协议 1 接缝：先尝试硬链接，受限时在最终路径的同一父目录复制到独占临时文件，写完并同步，再执行 `renameat2(..., RENAME_NOREPLACE)`。源文件由辅助函数只读打开；已有最终文件不覆盖。

M3-1b 增加了生产持久账本。临时路径在 `open('wx')` **之前**持久登记；已打开文件的身份和随机文件标记在**首个 payload 写入之前**持久确认；本调用安全收尾后注销。新主进程在安装 publication 服务前打开同一账本并恢复旧进程记录。测试父进程不再预建临时文件，不提供 receipt，也不代替产品删除它们。

M6-3b 在实际 renameat2 提交前持久记录首次试用，重启若仍见未完成试用则禁用该系统版本的原生提交分支。每进程第一次真实调用都重新记录；同进程成功后的正常调用不再写，已不支持或已禁用状态跨进程保留，可靠系统版本改变后重新试用。完整状态机、误触发、同锁收尾与复跑见 [M6-3b 崩溃熔断](../../../docs/design/harmonyos/M6-3b-crash-fuse.md)。

本轮仍保留两个明确边界：

- 创建成功但身份确认尚未完成时，磁盘只有 `reserved` 记录。若路径已存在，重启会保留文件及记录，报告 `reserved-without-inode`。路径缺失则可以清账。不能仅凭名字、空文件或旧 inode 号推定归属。
- 原生提交真实返回 `EINVAL`，或熔断状态已为 `unsupported` / `disabled-after-crash` 时，继续使用旧独占复制并告警；此时最终路径可能残留半文件。不删除历史或回退产生的最终文件，也不把这个分支列为原子发布。

因此，本轮补上了**有持久身份的半写临时文件在 App 进程死亡后的自动回收**。它不宣称任意中断窗口零遗留，也不宣称断电恢复或 OpenHarmony 真机已经验证。

## 宿主配置与启动

Node 的唯一可执行版本声明是 `runtime/ohos/node-version.json`（当前 **24.22.1**）；JS 直接导入，原生构建从它生成临时头文件。自有宿主在 Node 启动前注册 `dsh_ohos_publication` linked NAPI 模块，必须提供以下同步函数：

| 成员 | 合同 |
|---|---|
| `renameNoReplace(temp, final)` | 固定 `RENAME_NOREPLACE`；成功 `undefined`，失败抛系统错误 |
| `lockExclusive(fd)` | 对已打开 fd 取非阻塞排他锁；不替调用方开关或删除文件 |
| `setOwnershipMarker(fd, token)` | 在实际文件上独占设置随机归属标记；已有标记不能覆盖 |
| `getOwnershipMarker(fd)` | 返回标记字符串；缺少标记为 `undefined`，其他系统错误抛出 |
| `getSystemBuildIdentity()` | 同步返回 `osFullName`、`displayVersion`、`incrementalVersion`、`securityPatchTag` 四个字符串字段；仅取实际平台 getter，无环境变量替代 |

标记使用 `user.dsh_go_ownership`。成功改名后的最终 inode 保留该扩展属性，payload 字节不变。本轮不另开移除标记的中断窗口。五个函数的原生实现、固定构建脚本和独立边界测试属于配套原生分项；Linux `.node` / `LD_PRELOAD` 库仅是显式测试夹具，不是 OpenHarmony 产品二进制。

系统 build 四字段须各为 1–1024 个 UTF-8 字节、非空白且无 NUL，启动两次读取必须一致。固定字段顺序的 JSON 经 SHA256 得到持久版本键。任一字段不可用、过长或不稳定都明确阻止 publication preload；此时不读写旧熔断状态、不重新试用。该启动前提尚待实际设备验证，不能用 kernel release、Node 版本或随机值补足。

宿主必须先创建它授权的应用数据目录，并将 **`DSH_HOME` 显式设为既有的绝对目录路径**。预加载会用 `realpath` 得到实际目录；不存在、相对路径、普通文件及文件系统根目录均拒绝。不从 `cwd` 或系统临时目录推导应用数据权限。账本放在该目录下的 `ohos-ownership/`；账本 factory 创建或核查这个 `0700` 私有目录，拒绝符号链接和非私有权限。

产品宿主必须通过 `dsh_node_start`，只传一个 `--import /绝对路径/runtime/ohos/preload.mjs`；该统一入口先等待网络启动，再等待本服务的 `installPublication()` 完成。启动布局、`NODE_OPTIONS` 拒绝与 Linux 合同测试见 [统一启动契约](../../../docs/design/harmonyos/startup.md)。直接导入 `publication/preload.mjs` 仅保留给本文件的 publication 专项测试，不再作为产品宿主命令。安装仅在真实 `process.platform === 'openharmony'` 或明确的进程内 `Symbol.for('dsh.go.ohos.sim') === true` 下执行；旧环境变量本身不会开启分支。Worker 继承 `--import` 时跳过主引擎服务，不竞争主引擎账本锁。

安装过程先核版本、重复安装和五个原生成员，取得可靠系统 build 后才打开账本排他锁，执行归属恢复和熔断恢复，最后定义 `Symbol.for('dsh.go.ohos.publication')`。初始化失败时关闭已取得的 ledger。重复及并发安装都明确失败；缺少原生能力不静默降级。服务仍为 `protocolVersion: 1`，保留 `publish`、只读 `pendingCount`、`ownerId` 与深冻结的 `recoverySummary`，并提供只读动态 `atomic`、`systemVersion` 和冻结的 `systemBuildIdentity`。O6 可将 `atomic` 映射为 `publication.atomic`；本核心增量不含 RPC 路由，结构化读取与认证入口由配套独立增量提供。未解决记录只输出数量告警，保留详细结果供宿主检查。

## 账本与身份

`openOwnershipLedger` 由配套 `ledger.mjs` 实现。本核心只依赖 `reserve`、`identify`、`release`，不反向导入账本；账本可以复用精确临时文件清理函数。生产调用顺序如下：

1. 对同一个最终绝对路径排队，尝试原硬链接。`EEXIST` 等不在回退集合的错误原样传播。
2. 选择与源和最终路径不同、位于最终路径同一父目录的随机候选名。路径选择器只有选名权限，不能自行创建文件。
3. `await ledger.reserve(temp, final)`，将路径、最终路径、本次启动 UUID 和 pid 等写入账本。提交完成后才能 `open(temp, 'wx', 0600)`。
4. `fstat` 取得实际文件身份，确认空普通文件。`await ledger.identify(token, {dev, ino})` 会重新以 `O_NOFOLLOW` 打开同一路径，核对身份，设置独占随机标记并同步，再持久提交 identified 状态。
5. 每次最多复制 65,536 字节，等待写入；末尾同步文件，随后再次检查取消。同步等待期间被取消不会继续提交。
6. 进入与 ledger 共队列的熔断事务，必要时先持久试用状态；随后在同一 JS turn 中核对临时目录项身份并调用原生不覆盖改名，二者之间没有 await。首次成功记录 available；实际原生 EINVAL 记录 unsupported。既有 unsupported / disabled 状态跳过 native 并进入旧复制回退。
7. 保持输出 FileHandle 打开，核验并清理本次临时路径；随后关闭输出和输入句柄；路径已安全删除或已缺失时才 `await ledger.release(token)`。注销完成或失败已向调用方报告之前，不放行同目标的后一个任务。

账本以固定锁文件上的真实 `flock` 排除另一个活跃 writer。锁文件不被删除或改名，锁句柄保持到 ledger 关闭或进程退出。启动 UUID 不承担判断另一个进程是否死亡的职责。账本更新为串行原子替换，并同步账本文件及账本目录；持久化结果不确定时拒绝后续写入，要求重启处理。

仅 `dev/ino` 不足以证明跨重启归属：独立审查实际复现过旧临时文件删除后，新文件复用相同 inode 的情形。因此新的账本 schema 2 同时要求随机扩展属性标记与 token 一致。恢复时先打开文件、检查 inode 和标记，并在句柄仍持有该 inode 时同步核对目录项并清理。标记不符、标记读取失败、身份改变、未识别记录均保留；旧 schema 不会被当成新协议静默接纳。

私有目录的权限前提仍然必要。JS 中的检查和 `unlink` 不是内核原子 compare-and-unlink，不能抵抗任意外部原生 writer 在检查与删除之间操作同一路径。随机标记防止已测得的普通 inode 重用，不是针对能读取账本并仿造相同标记的攻击者的认证机制。

## 失败语义

| 情形 | 处理 |
|---|---|
| 持久 reserve 失败 | 不创建临时文件；原错误向上传播 |
| `wx` 返回 `EEXIST` | 保留既有目录项，只撤销本次预约，换一个候选名 |
| 创建后 fstat 失败 | 未获得可信身份，保留文件及 reserved 记录，明确报错 |
| identity/marker 持久化失败 | 不写 payload；本调用仍持有的精确文件可安全清理；注销失败也必须报告 |
| 当前临时路径被替换 | 不提交、不删除替换者，保留可供检查的记录 |
| 成功提交后 close / release 失败 | 向调用方报告失败，完整最终文件和源均保留 |
| 重启发现 identified 路径已缺失 | 清除旧记录，不碰最终路径 |
| 重启发现 identified 身份和标记都吻合 | 自动删除该临时文件并注销旧记录 |
| 重启发现 reserved 路径存在 | 保留并报告未解决 |
| 新临时文件所在文件系统不支持归属标记 | 在首个 payload 写入前明确失败；不降级为不带身份的恢复 |
| 试用状态写入失败 | 不调用 renameat2，明确报错并拒绝后续持久操作 |
| native 成功而 available 记录失败 | 完整 final 保留，明确报告提交后状态失败，不再次复制或删除 final |
| 重启发现同系统 build 的 trying | 持久 disabled-after-crash；禁用 native 分支并提供只读能力状态 |

首次产生 unsupported 的 `EINVAL` 只限固定原生 renameat2 调用：硬链接、读写、文件同步、路径身份检查及 marker 操作的 `EINVAL` 都不会误入这个分支；`EEXIST`、`EACCES`、`EXDEV`、`ENOSYS` 也不被当成不支持而吞掉。持久 unsupported 或 disabled-after-crash 随后的回退不需要再次调用 native。旧回退仍重新读取原 source。M3-1c 的性能与一致性评估是独立分项，本包没有偷换成未校验的 temp 路径读取。

## M3-1b 原冻结版实际验证（历史）

下表是 M3-1b 原冻结版的历史实测；它不包含后续 M6-3b 熔断，不能反写为旧版已有该功能。新增矩阵见上面的 M6-3b 文档。最终准入均由独立复核报告绑定精确补丁哈希。

| 验证 | 结果 |
|---|---|
| 原 30 生产 preload，同新重启 driver | 0 PASS / 2 FAIL；两个 provider 的 65,536 字节旧 temp 在重启后仍存在 |
| 新生产 preload，两 provider × 六中断阶段 | 12/12；真实 SIGKILL，父进程不提供 receipt、不调用 cleanup |
| 原发布错误、取消、身份 18 项 + 新账本顺序/失败 10 项 | JITless 28/28；严格 O0 28/28；零 skip |
| 真实附件/会话外层与锁回归 | 严格 O0 24/24，零 skip |
| Linux / Android 非 OH 分支对照 | 6/6；原硬链接、native flock 和 EACCES 行为保持 |
| 真实 Node 启动矩阵 | 18/18；含显式 appdata、坏账本、缺 marker 成员、并发安装、Worker 继承 |

| 强杀点（每个 provider 都实际执行） | 重启恢复与重试 |
|---|---|
| reserve 已持久，尚未 open | 路径缺失，清账；重新发布成功 |
| open 已完成，尚未 identify | 空文件及 reserved 记录保留，报告未解决；新一次发布成功 |
| identify 已持久，首写尚未开始 | 自动清理已标记空 temp；重新发布成功 |
| 第一块实际写完 | 自动清理 65,536 字节 temp；重新发布完整 196,625 字节 |
| 最后一次实际文件同步完成 | 自动清理完整 temp；重新发布成功 |
| 真实原子提交及 close 完成，尚未 release | 最终文件完整，temp 缺失；清账后重试 `EEXIST`，不覆盖 |

驱动仅对两个真实 provider 的副本追加 `publishOhosExclusive` 导出，不改辅助函数。每个孩子都显式导入产品 publication preload。父进程只在已选定的真实操作返回处发送 SIGKILL，并读取状态进行断言；自动恢复发生在第二个孩子运行测试入口之前。断言完成后才移除测试自身的目录。旧证据中“父进程预登记 receipt”的范围仍保留在 30 号原归档，不能反写成该旧版已经具有生产账本。

本包不修改 vendor diff、pins 或两个 provider 的原字节，继续使用 30 的 OH-only 协议 1 接缝。没有为本次纯 OH 源码接线重复宣称新的 Android 整包构建或真机测量；原 30 / M4-7 的 Android DSH 整树逐字节证据仍按原哈希独立保存。

## O4b 的可复用接缝与边界

账本的 reserve、随机 marker、identify、release、排他 writer 和旧 owner 恢复可供其他临时资源复用，数据中不要求资源名具有某个前缀。但 Git 的实际 Worker 硬取消尚未接入：父线程仍须在创建每个资源前登记，保持 job→token 关系，处理已接受 IO、Worker 退出和 cleanup 的先后关系，并等待清理及注销结束后才放行下一写任务。`recover()` 跳过当前 owner，不能直接用它替代活跃主进程对刚取消 job 的即时收尾。Git 原先 4 过 1 败的硬取消反例没有被本包消除。

## 复跑

先合 30 的原子发布接缝，再合配套 M3-1b 原生与 ledger 分项及本接线增量。用固定 Node 构建配套 Linux linked 库，配置以下绝对路径。`APP_DATA` 必须是专门为此次验证创建、尚未存在的目录；测试结束后只删除这个已知目录。

```sh
mkdir -m 700 -- "$APP_DATA"

LD_PRELOAD="$LINKED_LIBRARY" "$NODE" --jitless --test \
  runtime/tests/ohos/publication-atomic.test.mjs \
  runtime/tests/ohos/publication-ledger-lifecycle.test.mjs

LD_PRELOAD="$LINKED_LIBRARY" DSH_GO_OHOS_SIM_PLATFORM=openharmony \
  "$NODE" --jitless --import "$SIM_PRELOAD" --test \
  runtime/tests/ohos/publication-atomic.test.mjs \
  runtime/tests/ohos/publication-ledger-lifecycle.test.mjs

LD_PRELOAD="$LINKED_LIBRARY" DSH_HOME="$APP_DATA" DSH_TEST_PREFIX="$PREFIX" \
  DSH_GO_OHOS_SIM_PLATFORM=openharmony \
  "$NODE" --jitless --import "$SIM_PRELOAD" \
  --import ./runtime/ohos/publication/preload.mjs \
  --test --test-isolation=none \
  runtime/tests/ohos/publication-locks.test.mjs \
  runtime/tests/ohos/publication-integration.test.mjs

python3 -B runtime/tests/ohos/publication-startup.py \
  --node "$NODE" --simulation "$SIM_PRELOAD" \
  --linked-lib "$LINKED_LIBRARY" --out /绝对路径/startup.json

"$NODE" runtime/tests/ohos/publication-kill.mjs \
  --node "$NODE" --simulation "$SIM_PRELOAD" \
  --publication /绝对路径/runtime/ohos/publication \
  --linked-lib "$LINKED_LIBRARY" --prefix "$PREFIX" \
  --out /绝对路径/recovery.json
```

先失败重放使用同一个新 driver，将 `--publication` 指向 30 冻结版 publication 目录，并加 `--phases mid-copy`。预期退出 1，JSON 中为 0 PASS / 2 FAIL，失败来自实际 temp 残留。不要为了使基线全绿而删除这个断言。

## 仍待验证

OpenHarmony SDK 编译与 ABI、Node/Ark NAPI 符号归属、宿主 linked 注册、实际应用目录的 xattr / flock / RENAME_NOREPLACE 支持、正常宿主 teardown 与真机后台杀进程仍需目标证据。本轮只有 Linux 显式夹具，未将这些项目记为已测通过。

文件 `fsync` 不单独证明目录项的断电耐久性。账本目录同步不能代替临时文件所在目录和最终提交目录的持久性论证；原 provider 的目录同步保留，但本轮没有断电、重挂载或存储故障测量。具体文件系统 flag 支持也不能从 Linux overlay 成功外推：已归档的官方 OpenHarmony 6.1 sharefs 源码对非零 rename flags 返回 EINVAL，真机目录实际挂载何种文件系统仍未知。相关原始来源与哈希保留在 30 的来源记录中。

## ADD12：会话删除标记需要原子发布

会话删除的 `deleted.json` 是持久提交点，不能使用可能留下部分最终文件的独占复制回退。协议 1 服务新增显式 `publishAtomic(source, target, options)`；它使用同一队列、账本和不覆盖提交，但在 `unsupported` / `disabled-after-crash` 分支进入复制或告警之前，抛出 `ERR_OHOS_PUBLICATION_ATOMIC_REQUIRED`。普通 `publish` 的既有回退语义保持。显式方法避免旧服务静默忽略新选项。

OH 删除 seam 将缺少该方法或原子能力不支持映射为既有 `unavailable`（路由 HTTP 503）。第一次发布标记后仍依次同步标记目录、lifecycle 目录、会话根和根的父目录，成功后才删除已筛选的日志。有效标记重试在 OH 再次完成四级目录同步；即使此时不能创建新标记，仍允许完成旧标记的清理。非 OH 的共享 core、bridge 和 Android recipe 输入保持新基底原字节。OH composer 在普通 prepare receipt 核验之后，从已固定前像生成专用的 core 和 bridge 变体；prepared prefix 不被修改，两个变体的前像、变换和后像 SHA 分开记入组成记录。实际 payload 的导入、manifest 与归档检查消费生成后像。

删除 GET 能力只读 `supported`：OH 仅接受新 core 明确返回 true，缺 getter 的旧版本不再被误报可用。缺方法、已知 `unsupported` / `disabled-after-crash` 为 false；`untried` / `trying` / `available` 表示没有已知拒绝，不是新的设备探测或永久保证。GET 不调用 syscall、不写磁盘。POST 仍由 seam 区分新提交与有效标记重试，不用 GET 的结果提前阻止重试。

有限回归使用真实私有文件和固定 Linux publication linked 夹具。以下入口不启动 App 或 SDK；`NODE`、`LINKED_LIBRARY`、`SIM_PRELOAD`、`OH_DELETION_CORE`、私有 `APP_DATA`、`TRACE` 均须使用明确绝对路径。`OH_DELETION_CORE` 指本次 composer 输出的 `generated/ohos-deletion/core.mjs`；路由单元组使用 `DSH_SESSION_DELETION_ROUTE` 指向同目录的 `session-deletion.js`，不得以未修改的共享源冒充 OH 后像。目录同步用例的 hook 只替换 core 自身的 fs/promises 依赖，记录真实 open/fsync/rm；为单独比较旧重试顺序，其 legacy-link 接缝委托真实原子服务，不启用硬链接，也不称旧完整构建或设备重放。

```sh
LD_PRELOAD="$LINKED_LIBRARY" DSH_GO_OHOS_SIM_PLATFORM=openharmony \
  DSH_SESSION_DELETION_CORE="$OH_DELETION_CORE" \
  "$NODE" --jitless --import "$SIM_PRELOAD" --test --test-isolation=none \
  runtime/tests/ohos/session-deletion-publication.test.mjs

LD_PRELOAD="$LINKED_LIBRARY" DSH_GO_OHOS_SIM_PLATFORM=openharmony \
  DSH_HOME="$APP_DATA" DSH_DELETION_SYNC_SOURCE="$OH_DELETION_CORE" \
  DSH_DELETION_SYNC_TRACE="$TRACE" \
  "$NODE" --jitless --import "$SIM_PRELOAD" \
  --import ./runtime/ohos/publication/preload.mjs --test --test-isolation=none \
  runtime/tests/ohos/session-deletion-sync/directory-sync.test.mjs
```

这证明的是明确故障返回与重试顺序；没有新增断电恢复、任意并发 writer、文件系统能力或真机结论。
