# OHOS 工具边界、逻辑暂停与恢复

本实现对应 `docs/design/harmonyos/lifecycle.md` 的 O8 先行设计，基于源码 `3fc4081`、固定 DSH `0.2.1-rc.4` 和 Node `24.22.1`。它给同一主 Node 引擎增加持久工具边界和已鉴权的控制接口。Linux 的真实文件、原生 flock、Worker、HTTP、SIGKILL 和 SIGSTOP/SIGCONT 是本包的验证范围；OHOS SDK 编译、手机前后台回调、设备文件系统掉电行为仍未验证。

## 接入与范围

在 OHOS 的 Cordis profile 中，在 OH subprocess 和原有会话服务可用后注册本目录 `index.mjs`，例如：

```json
{
  "name": "/absolute/runtime/ohos/lifecycle/index.mjs"
}
```

使用项目 profile 的原有插入操作加入该条目；不要替换其他插件，也不要把测试 observer 加入产品配置。宿主前后台事件应调用本模块的鉴权接口。这个包不修改 ArkTS 生命周期回调、UI、Android、宿主 CMake 或 Node 构建。

产品入口只接受真实 `process.platform === 'openharmony'`，或 O0 测试 preload 安装的 `Symbol.for('dsh.go.ohos.sim')`。环境字符串 `DSH_GO_OHOS_SIM=1` 不能开启它。未安装服务时，补丁保持原调度和超时路径；服务安装后不可无声卸载并退回无日志分派。关闭后的全局 owner 仍在，后续调度明确失败。

O6 的 `background.resume` 每次查询已安装 `ohosLifecycle` 服务：协议为 1 且状态未关闭、未因持久化故障阻断时报告 `reconcile`；缺失、异常、关闭或阻断时为 `none`。它只表示引擎工具边界的对账能力，不表示宿主回调已经接好、系统允许后台持续计算或设备已经验证。`computePermission` 仍是 `unknown`，`policy` 仍是 `may-freeze`。

必须按 `pins.json` 的 `targetSets.ohos` 重放 `zzzzzzzzzzzzz-ohos-lifecycle.diff`。该固定补丁只接入五个已核对模块：AgentLoop、deadline、HTTP 代理连接 owner、fs-search spill 消费者、spill-policy。Android patch 集不含它。没有新增运行依赖，也不修改 Date、setTimeout、fs、fetch 等全局内建。

边界覆盖原 AgentLoop 顶层工具调度和该调用内、共享异步调用范围的嵌套执行。直接从其他插件独立调用 `ctx.tools.execute`、绕过调度器的副作用、任意插件自行管理的外部资源，没有被本协议自动纳入。记录调用已进入分派并不等于提供通用 exactly-once：远端写入与本地记录之间仍有无法用普通文件事务消除的窗口。

## 持久身份与顺序

一个调用的主键是 `(sessionId, callSeq)`。记录同时固定 `callId`、工具名、`turn`、`step`、原 `bootId`、真实会话 `tool/call` 的 SHA-256。不同会话可重复使用 callId；它不是全局键。

| 边界 | 已完成的实际工作 | 此时可以得出的结论 |
|---|---|---|
| `prepared` | 原 `ctx.sessions.flush` 成功，重新读出的调用前缀与调度身份一致 | 本协议尚未允许工具正文分派 |
| `dispatch` | 分派记录完成追加及 fsync，最后一次闸门检查紧贴原 dispatch | 此后丢结果时可能已有副作用 |
| `returned` | 原 dispatch 返回的原始结果已保存 | 后处理和有序 finalize 可能尚未完成，不能把它冒充最终结果 |
| `outcome` | 原有序 finalize/finish 已完成，最终结果与一次生成的完整会话消息投影已保存 | 可按原 callSeq 恢复同一次结果，仍要核对外部资源和附加上下文 |
| `committed` | 原调度器按模型顺序 append，flush 后重读到唯一匹配结果 | 会话已有确切的权威结果 |
| `reconciled` | 对账结论、是否阻断及依据已追加刷盘 | 保存恢复判断，不抹去原未知事实 |

快工具 B 可以先写 `returned`，但仍等 A 的原有提交次序。B 在等待期间仍属于未结算调用，不会因 dispatch Promise 已结束而被误判为冷启动未知。`createToolResultMessage` 会生成消息身份；实现只调用一次并保存原投影，避免恢复时生成另一个 id。

日志位于默认 `DSH_HOME/ohos-lifecycle`，也可用唯一配置项 `directory` 指定绝对规范路径。该目录必须在所有已登记的工具工作根之外；目录 0700、文件 0600，不接受别名、符号链接或宽松权限。固定锁 inode 使用实际 linked binding `lockExclusive`。结果先以内容摘要命名写入私有 `results/`，完成文件及目录 fsync 后，日志才引用它。

日志有版本、连续 seq 和 SHA-256 链；单条最多 1 MiB，结果 JSON 最多 16 MiB，日志最多 64 MiB。JSON 采用无损快照约束，拒绝 getter、循环、undefined、稀疏数组、非有限数等无法按原值恢复的数据。达到上限或发生写盘失败后阻止新分派，不自行删日志、截断坏尾或压缩。自动压缩和维护工具不在本包范围；文件系统损坏需要显式修复，不能用 acknowledgeUnknown 清掉全局持久化故障。

## 冷启动对账

对账发生在原 `AgentFactory.resumeWith` 的会话写事务内、原 `interruptedTurnClosers` 追加前。它只替换原本属于该调用的恢复槽，维持原事件顺序。追加后 flush 并重读，再记录恢复已提交。

| 看到的真实证据 | 处理 |
|---|---|
| 唯一匹配、已持久的 `tool/result` | 接受原事实，不重新执行；若记录过 committed，则核对原 seq 和消息摘要 |
| 完整最终 outcome，无会话结果，且无尚未验证的资源/上下文依赖 | 将原消息投影放入原恢复槽；刷盘后才 committed |
| 只有 prepared，完整日志证明没有 dispatch | 原恢复槽记 `TOOL_NOT_STARTED`；允许正常重新规划，不自动重放旧调用 |
| 已 dispatch，结果丢失；或只有 returned 尚未有序 finalize | `result-unknown`，原未知占位保留，禁止该会话新步骤 |
| 日志前从未登记的旧悬空调用 | 追加 `untracked`，原 boot 为 `unrecorded`，不虚构 prepared 证明 |
| 原 ToolCallRecovery 已写未知占位 | 保持该占位，不追加第二个 tool/result；鉴权结果接口可另查保存的 final/raw 数据 |
| 结果文件丢失、错误摘要、损坏尾、调用身份冲突 | 保持未知或全局阻断；不当空成功，也不推测副作用没有发生 |

已知外部资源依赖采用保守处理。实际 fs-search 和 spill-policy 消费者在成功产生 spill 引用时通知本次调用范围，不解析模型文本、不按工具名猜测。最终 envelope 保存该事实；图像附件、bash spill/job 引用、`additionalContexts` 也不能仅凭 JSON 恢复其生命周期。本包不重建这些资源：当会话还没有权威结果时保留原未知槽，完整 final JSON 仍可查阅。即使 spill 文件看似还在，也不会把一个未经验证的旧路径当成可恢复资源。第二次冷启动继续保留未知，不会把第一次插入的不完整成功消息误当 committed。

任意第三方插件在文本中放入自己的外部定位符，无法由通用 JSON 判断有效期；这类插件需要自己的资源恢复契约。当前接点覆盖固定引擎上述实际消费者，不宣称所有字符串引用已被证明可恢复。

未知结论按会话隔离；完整但未知的 A 不会阻止独立 B 接收一个明确的新请求。若是日志/存储整体损坏，所有会话都被阻断。`acknowledgeUnknown` 表示明确放弃继续追认旧未知操作，持久记录 `explicit-abandon-unknown-without-replay`，不会重写旧会话结果，也不会自己再发送 prompt 或工具调用。仍有待结算调用或取消尚未 join 时，该操作拒绝并返回 `ERR_OHOS_LIFECYCLE_STILL_RUNNING`；逐条持久化确认期间若开始取消，返回前再次核对，不能清除尚未完成的取消意图。已经刷盘的确认记录保留，它们没有重放任何工具。

## 暂停、恢复、取消与时钟

`pause` 立即关闭新步骤/新工具闸门，串行持久化暂停记录，再暂停本模块拥有的活动预算，最后返回确认版本。已开始的工具保留原 Worker、Promise 和 AbortSignal；暂停不声称它已终止，也不会重复创建它。没有完成确认的宿主通知不构成一个可扣除的冻结区间。

`resume` 先让已排队的 I/O 完成回调得到处理，再重验自有传输，持久化恢复记录，释放最新控制版本的闸门。重入 pause/resume 按版本串行结算；状态查询本身不执行这些操作。已结束的异步调用按原句柄结算。

`cancel(sessionId)` 先登记取消意图，调用原 agent.cancel，等待原 agent.whenIdle、会话 flush 和所有已开始调用的有序提交/失败清理。不能仅凭请求被接受就标为 terminated；如果调用忽略取消，接口继续等待，不假装已完成。取消的 join 期间有独立的分派闸门，确认旧未知和迟到的 prepared checkpoint 都不能释放它。已取消信号不会复活，后续显式新请求必须有新 signal。全引擎 close 同样等待已拥有任务结束后关闭日志。

| 时间 | 实现 |
|---|---|
| `TOOL_TIMEOUT`、`BASH_TIMEOUT` | 同一 `ActiveBudgetClock`；只扣除本引擎已经确认的逻辑暂停，使用剩余预算，不重置 |
| fs-search 的工具期限 | 通过真实 tool-call-timeout-policy 接入上面的 TOOL_TIMEOUT |
| 未预告 SIGSTOP | 没有推测出的暂停区间，事件循环恢复时仍计入已经流逝的预算；恢复会同步检查已到期但回调尚未执行的 deadline |
| HTTP、LLM 空闲检测、其他未接入的期限 | 保持原墙钟/原调度规则；不宣称所有库的计时器均已暂停 |
| token、签名、证书 | 保持服务端/系统真实墙钟验证，过期仍失败，不因暂停延寿 |

上游 AbortSignal 的原 reason 保持不变。暂停前已经到期的 deadline 不会因后续 pause 恢复；本模块关闭后拒绝新的 deadline。实现不利用 Date.now/performance.now 的差值猜测内核冻结时长。

## 连接恢复

恢复是新连接边界，不是健康证明，也不是请求重试策略。若 OH 启动层仍拥有默认 dispatcher，替换只用于之后的请求；旧 owner 的 close 异步排空已接受的操作，绝不 destroy 一个在途写请求。自定义全局 dispatcher 和显式单请求 dispatcher 都保留。

完整 DSH 启动会安装自己的代理策略 wrapper。固定 `dsh-http-proxy` 接点在同一个 wrapper 内更新其自有连接池，保持 proxy/no_proxy 选择、wrapper 身份和原关闭责任；旧连接完成后再退役。不能把该 wrapper 误当可替换的直连 dispatcher。恢复 HTTP 请求自身可能仍属于旧连接，故不会等待其响应完成后才能发送恢复响应。状态中的 generation 只表示完成了连接 owner 更新，不表示认证、远端可用性或用户网络已恢复。

## 已鉴权接口

接口使用现有 `connection.requestRejection`，沿用 Host、Origin 和认证判断；无连接鉴权服务时拒绝服务。正常响应为 JSON、`no-store`。不会在控制错误中回显原始异常原因、凭据或结果内容。

| 请求 | 参数和结果 |
|---|---|
| `GET /dsh-go/v1/lifecycle` | 全引擎视图；可选唯一 `sessionId` 查询参数过滤会话 |
| `POST /dsh-go/v1/lifecycle` | JSON `{"operation":"pause"}` 或 `{"operation":"resume"}`；控制整个引擎 |
| 同上 | JSON `{"operation":"cancel","sessionId":"…"}` |
| 同上 | JSON `{"operation":"acknowledgeUnknown","sessionId":"…"}`；显式保留历史并放弃追认旧未知 |
| `GET /dsh-go/v1/lifecycle/result?sessionId=…&callSeq=…` | `identity`、`final`、原始/最终 `result`；final 时另含确切 `sessionData` 和已知 `resources` |

状态字段包括 `v:1`、`bootId`、六态 `state`、`closed`、`paused`、`confirmedPause`、`blocked`、`corruption`、`controlVersion`、`activeBudgetCount`、`calls`、`transport`。每条 call 有原身份、边界 phase、是否仍待结算 active、是否仍在原 dispatch 中 dispatchActive、保存结果标志以及恢复依据。六态为 `running`、`paused`、`cancelling`、`terminated`、`completed`、`result-unknown`；未知事实优先于暂停显示。

控制体限 8192 字节、真实墙钟 10 秒，不接受多余字段。未认证/不可信 Origin 按现有桥返回 401/403；错误参数 400，缺结果 404，错误方法 405，过大体 413，错误类型 415，不能执行的控制 409。读取 final JSON 不自动确认 unknown；需要显式的用户决定或未来的专属对账器。

## 复核入口

本包测试源码在 `runtime/tests/ohos/lifecycle-*`。`lifecycle-engine-fixture.mjs` 加载固定真实 DSH 和 JSONL；为了直接观察私有调度入口，测试只在原模块的完整临时副本末尾加 export，不替换调度算法。冷恢复最终走公开 AgentFactory。进程控制器是引擎之外的 Python 父进程，握手后才发送真实 SIGKILL/SIGSTOP/SIGCONT，引擎内部继续保持 O0 禁止子进程和 WebAssembly 的约束。

交付目录的 `commands.sh`、命令 JSON 和原始日志给出精确 prefix、native `.so` allowlist、linked fixture、旧模块前像和新基底补丁。只有实际运行成功的项登记为 PASS_SCOPED；未经过 SDK/设备的部分不由桌面结果替代。完整回合仍使用原 `runtime/ohos/sim/round.mjs`，测试 observer 仅记录实际五工具与控制接口证据。
