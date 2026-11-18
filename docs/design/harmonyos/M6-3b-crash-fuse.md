# M6-3b：renameat2 首次试用的持久崩溃熔断

本项落实追加12的保守恢复规则：**每个主引擎进程第一次真正进入 `renameat2(RENAME_NOREPLACE)` 前，先持久写入 `trying`；同系统版本重启仍见 `trying`，转为 `disabled-after-crash` 并停止后续原生尝试。** 普通成功路径在本进程只记录一次；版本改变后允许重新试用。

这不是提前在 App 内发起的探测 syscall。只有实际发布需要进入原生提交时才尝试；原硬链接成功的发布不创建试用标记。`trying` 只说明没有看到正常的持久收尾，不能证明死因为 SIGSYS。[实现：`runtime/ohos/publication/{atomic-fuse,atomic,index,ledger}.mjs`；测试：`runtime/tests/ohos/publication-atomic-fuse.test.mjs`]

## 固定输入与范围

核心以前置39统一入口及34持久归属实现为基础；本核心增量不改 Node 版本声明、统一 preload、原生注册路线、provider diff、pins 或 Android 路径。原生第五个成员 `getSystemBuildIdentity()` 来自配套补丁 `4112154939c29e15a355a45424200623c9c1398bd7b4b6582d67c682b25f81d9`。系统版本的官方固定来源、目标构建要求与 O10 待测项另见配套 [系统 build 来源说明](M6-3b-system-build.md)。

Linux 实验继续固定 Node 24.22.1，SHA256 `e32e2d16081cf644f88392934288086e7662529d0d43277c34f7aad2207cfafb`。本轮实际重建的测试库与配套原生作者产物逐字节一致：`.node` 为 `443a64a9630927881e5a77dec0163c20b9a8750629e45573d5930250febfbfe2`，linked 测试库为 `09dbe1af70e5376f65b5d3ba696c69d96b85ea7721ac672640ccb9c4f357e883`。这些是显式 Linux 夹具，不是 HAP 产物，也不证明 OHOS ABI、商用机策略或目标文件系统已通过。

## 系统版本身份

生产从 linked binding 同步读取对象，要求恰好四个自有字符串字段：`osFullName`、`displayVersion`、`incrementalVersion`、`securityPatchTag`。JS 按此固定顺序序列化 JSON，计算 SHA256，持久键形如 `ohos-build-v1:<64位十六进制>`。固定顺序避免属性枚举顺序或简单字符串拼接歧义；各字段变化都会得到新的版本键。

每个字段必须是 1–1024 个 UTF-8 字节、非全空白、无 NUL、Unicode 字符串形式有效。启动时同步读取两次并要求字节内容一致。这只检查同一次启动内的一致性；跨重启的稳定性依赖配套官方平台 getter，不能由“两次相同”独立证明。不会用 `os.release()`、Node 版本、环境变量、随机值或时间替代系统 build。

**本包采用明确启动失败的合同。** getter 缺失会触发 binding 合同错误；存在但返回缺失字段、空串、NULL 的异常结果、过长字段或不一致读数，会使 publication preload 报 `ERR_OHOS_PUBLICATION_SYSTEM_BUILD`。这些检查发生在打开账本之前，因此旧熔断状态不被读取、清除或重新试用，也没有 rename 调用。四个官方 getter 可返回缺失值的边界由配套来源说明记录；本包不能宣称所有设备都能完成启动。没有添加 `identity-unavailable` 回退状态或猜测版本的后门。

## 状态与每进程语义

磁盘记录是独立 schema 1，不改资源归属账本 schema 2：

```json
{"schema":1,"systemVersion":"ohos-build-v1:<hash>","state":"trying","ownerId":"<本次进程UUID>"}
```

文件位于既有私有 `DSH_HOME/ohos-ownership/` 的固定 `atomic-state.json`，写入使用固定 `atomic-state.pending`。它们与资源账本共用已有 `.lock` 及同一活跃 owner 生命周期。

| 启动读到的状态 | 同版本行为 | 本次可观测状态 |
| --- | --- | --- |
| 没有记录 | 等实际需要原生提交才写 trying | `untried` |
| `untried` | 下次合格提交重新试用 | `untried` |
| `trying` | 先持久改成 disabled；以后跳过原生提交 | `disabled-after-crash` |
| `available` | 保留上次成功事实；**本进程首次真实原生提交前仍重新写 trying** | 首次提交前 `available`，试用期间 `trying` |
| `unsupported` | 不再调用原生提交，走原独占复制回退 | `unsupported` |
| `disabled-after-crash` | 不再调用原生提交，走原独占复制回退 | `disabled-after-crash` |
| 记录属于另一个系统版本 | 内存视为 untried，等实际提交时持久新版本 trying | `untried` |
| 损坏或非法记录 | 明确启动失败，保留证据，不静默重置 | 无已安装服务 |

同版本 `available` 不等于以后所有进程永久免写。按追加12“本进程第一次”的口径，每个新进程都重臂一次；该进程正常成功后不再写成功标记。跨进程持久跳过的是 `unsupported` 和 `disabled-after-crash`，只有可靠系统版本变化才重新试用。没有真正进入 rename 路径的启动不写 `trying`。

| 本次尝试结果 | 状态与对外结果 |
| --- | --- |
| 试用标记的任何持久步骤失败 | 不调用原生提交，实例 poison，错误向上传播 |
| 提交前取消或临时路径身份检查失败 | 不当作 native 返回；试用时清到 untried，再抛原错误 |
| 真实原生成功 | 首次试用持久 available；以后本进程正常成功不再写 |
| 真正 native 调用返回 `code=EINVAL` 且 `syscall=renameat2` | 持久 unsupported 后回退并告警；已 available 后另一目标文件系统的 EINVAL 也执行此转换 |
| 其他 native 错误，如 EEXIST / EXDEV / EACCES / EPERM / ENOSYS | 不回退、不冒称 available；首次试用清到 untried，原错误对象继续向上传播 |
| 原错误后的 untried 收尾也失败 | 聚合原错误与状态错误，保留 cause，不吞任一失败 |
| native 已成功而 available 写失败 | 报 `ERR_OHOS_PUBLICATION_COMMITTED_STATE`，标明 `committed: true`；保留完整 final，**不复制回退、不删除 final** |

“成功以后不再写”限定正常成功路径；后续实际 EINVAL 仍必须持久禁用。来自文件读写、目录 sync、临时路径检查或 ledger 的 EINVAL 不进入 unsupported 分支。本实现将 `beforeCommit` 与实际 native 调用分开辨认阶段，并在两者之间保持同一 JS turn、无 await。

## 与归属账本共享锁和收尾顺序

`openOwnershipLedger` 仍只获取一个真实非阻塞 flock。新增 `ledger.publicationAtomicState.transaction(operation)` 把整个熔断操作放入现有串行队列；事务里的 `io.read()` / `io.commit()` 是直接的内部状态 IO，不递归等待同一个队列。因此多个目标同时发布时，首次试用是 single-flight，不会有人绕过正在持久写入的 `trying`。

一次状态提交为：独占创建固定 pending 文件 → 写完整 JSON → 文件 sync → close → rename 到固定 committed 文件 → 账本目录 sync。所有这些步骤成功后才允许实际原生提交。失败使 ledger 的后续操作拒绝，持久化结果不确定时等待重启处理；不因写失败偷偷执行 rename。

每个已接受的事务及其中已接受的状态 IO 都必须完成，才放行后一个 ledger 操作或 `close()`。关闭开始后拒绝新事务；已接受的事务按队列完成，锁直到这些操作收尾后才释放。没有第二个同路径 flock，也没有“状态任务在独立队列里、主锁先关掉”的窗口。事务内的 IO 接口在事务结束后失效，意外漏 await 的已接受 IO 仍被该队列槽等待。

启动先读并验证已提交的状态。只有它有效或不存在，才清理本协议私有目录中的**那个固定 pending 槽**；损坏 committed 状态会保留 pending 供检查。状态文件拒绝 symlink、非普通文件与大于 32 KiB 的异常记录。这里不扫描发布临时文件名前缀；payload 临时文件仍由既有 schema 2 的 token、inode、xattr 归属规则恢复。

核心在完整临时复制及文件 sync 之后进入 fuse；fuse 持久试用，再同步核对当前临时目录项并调用 native。原 FileHandle 保持打开，既有身份清理与 `ledger.release` 收尾继续执行。状态写失败也不能吞掉资源注销失败。熔断禁用后仍保留原核心的临时准备及旧 source-based 独占复制流程，没有顺带吸收 M3-1c 未批准的性能候选。

## O6 可观测接口

主线程服务 `globalThis[Symbol.for('dsh.go.ohos.publication')]` 继续使用协议 1，新增：

- `atomic`：只读动态 getter，值是上述五个状态之一；O6 可将它映射成 `publication.atomic`。
- `systemVersion`：本次启动的固定版本键。
- `systemBuildIdentity`：四字段冻结对象，供宿主和真机记录核对实际 build。

读取这些字段不发起 probe、状态写或 syscall。Worker 仍跳过主引擎服务安装，继承原生 binding 不等于取得主线程 publication 服务。**本核心增量只提供服务字段**；结构化能力投影与认证 HTTP 入口由配套独立增量提供，其可用性以各自冻结哈希与实际测试为准。

`disabled-after-crash` 说明 rename 原子提交分支被禁用；原来的硬链接优先路径仍可成功。回退首次实际发生时输出一次非原子风险告警，明确最终路径可能留下半文件。不把这个回退叫作原子发布，也不把残留最终路径当作归属临时文件删除。

## 已实际验证的范围

最终准入由独立审查绑定冻结哈希。以下是作者及并行实现夹具的实际观察，不是目标设备裁决：

| 矩阵 | 当前结果与范围 |
| --- | --- |
| 新状态/同锁持久化/故障/close 屏障测试 | JIT 28/28，严格 O0 28/28，零 skip/TODO；六个持久步骤分别注入失败，另有真实 native 成功后记录失败不破坏 final |
| 叠加原 publication / ledger / lifecycle 回归 | 新28 + 原48，两模式各76/76，零 skip/TODO |
| 新原生接缝重新构建 | `.node` 与 linked 库分别逐字节同配套443a64… / 09dbe1… |
| 统一宿主合同与原生/JS 单版本源 | 34/34；本次未传可选旧 runner 参数，39归档的额外旧反例仍独立保留，不能把34写成35 |
| 同一最终强杀/provider 驱动对旧39 | 普通与严格各0/12；真实SIGKILL命中，缺少 trying/disabled，重启仍进入 native |
| 同一驱动对新候选 | 普通与严格各12/12；8个真实强杀场景，覆盖 native 前与 native 成功后、持久成功状态前窗口；真实附件/会话消费者恢复后读到完整结果 |

错误返回测试中的 EINVAL 通过明确的测试 wrapper 注入，Linux 原生成功路径使用实际 renameat2；不能把注入 EINVAL 解释为某种目标文件系统已经测得不支持。SIGKILL 是外部父进程发出的真实信号，孩子在明确阶段握手后阻塞；它模拟没有正常收尾，**不是目标 seccomp SIGSYS 的直接实验**。

强杀/provider 夹具使用真实 DSH bin 作入口以满足预加载解析，但测试 actor 在业务主程序开始前运行 provider 并退出；属于 pre-main provider 集成，不算完整 App 回合。其第一次普通模式曾因仅设置 sim marker、没有模拟平台而使四个公开 provider 案走旧 Linux 分支；原失败保留，测试前置修正后使用同一断言重跑。没有为这个夹具问题修改生产 gate。

## 误触发与保证的限度

`trying` 可以由 SIGSYS、SIGKILL、断电、试用标记落盘后还没执行 native 就死亡、native 已成功但 available 尚未持久等情况留下。最后一种情况下完整 final 会保留，但重启仍保守禁用；这是刻意接受的误触发。若捕获到明确返回的非 EINVAL 错误并正常清到 untried，则不会在下次启动误当成死亡。

“最多一次未完成试用后禁用”依赖同一个私有数据目录、稳定系统版本键、同一真实锁和成功的持久标记。删除应用数据、系统版本变更会重新试用；设备断电耐久性仍需目标验证。本进程已有一次成功后不再重臂每次调用，因此若策略在进程存活期间变化、或后来某次 syscall 被其他原因杀死，本标记不是所有死亡原因的通用计数器。若目标在写标记所需的文件操作或原有 ledger 操作上先失败，本项也不保证 App 能启动。

不在主 App 或 Worker 里提前盲测 SIGSYS，不推断厂商额外过滤层不存在，也不从 Linux overlay 成功推断 el2 的 sharefs/hmdfs/f2fs 支持。真机 O10 应同时记录机型、四字段系统 build、实际挂载链、available/unsupported/disabled 状态、误触发与回退后残留风险；相关来源与待测表由配套文档提供。

## 复跑

先合精确39、配套原生与本核心增量，再合配套的强杀/provider测试。普通和严格模式均使用新的自有 linked Linux 夹具；二进制只在独立 build 目录生成。

```sh
bash runtime/tests/ohos/build-publication-native.sh "$NODE_ROOT" "$NATIVE_BUILD"

LD_PRELOAD="$NATIVE_BUILD/libpublication-test-linked.so" \
  "$NODE_ROOT/bin/node" --test --test-isolation=none \
  runtime/tests/ohos/publication-atomic-fuse.test.mjs \
  runtime/tests/ohos/publication-atomic.test.mjs \
  runtime/tests/ohos/publication-ledger.test.mjs \
  runtime/tests/ohos/publication-ledger-lifecycle.test.mjs

LD_PRELOAD="$NATIVE_BUILD/libpublication-test-linked.so" \
  DSH_GO_OHOS_SIM_PLATFORM=openharmony \
  "$NODE_ROOT/bin/node" --jitless --import "$SIM_PRELOAD" \
  --test --test-isolation=none \
  runtime/tests/ohos/publication-atomic-fuse.test.mjs \
  runtime/tests/ohos/publication-atomic.test.mjs \
  runtime/tests/ohos/publication-ledger.test.mjs \
  runtime/tests/ohos/publication-ledger-lifecycle.test.mjs

python3 runtime/tests/ohos/host-startup.py \
  --node-root "$NODE_ROOT" --dsh-prefix "$DSH_PREFIX" --out "$HOST_RESULTS"
```

`HOST_RESULTS` 包含宿主测试自产生的原生构建和小型测试数据，应使用独立空目录。强杀驱动和原生系统版本矩阵的精确参数见配套测试说明。外部协调器负责启动和强杀，严格 O0 在被测 Node 与真实 Worker 内生效，不能把协调器可 spawn 解释成目标应用可 spawn。
