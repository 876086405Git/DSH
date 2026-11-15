# M6-3b：原子发布熔断的消费者与能力观察合同

本文补充 `capabilities-v1.md` 的 O6 先行约定。M6-3b 的生产实现提供发布服务状态及结构化读取函数；**本读取接缝小包不包含 O6 认证 HTTP 端点、Dart 模型和 App 界面，相关接线需分别验收**。本文不改变宿主存在性、连接成功、引擎能力三层的区分，也不修改 Android bridge。

## 状态来自实际服务

主引擎通过 `globalThis[Symbol.for('dsh.go.ohos.publication')]` 提供只读服务。`protocolVersion` 仍为 1；新增只读 `atomic`、`systemVersion`、`systemBuildIdentity`。状态属于这个引擎实例及其真实系统构建标识。只读查询不尝试 `renameat2`、不创建测试文件、不修改熔断记录、不清理资源，也不能恢复或重新执行工具。

生产模块 `runtime/ohos/publication/capabilities.mjs` 导出无参数 `readPublicationCapabilities()`，每次从实际已安装的 v1 服务返回新的冻结快照 `{publication:{atomic,systemVersion}}`。模块不导入 fs/native，不执行探测，不暴露可变 service 对象；路由仍须单独复用原认证 guard。新增可选字段：

| 字段 | v1 类型 | 消费者规则 |
| --- | --- | --- |
| `publication.atomic` | `untried`、`trying`、`available`、`unsupported`、`disabled-after-crash`、`unknown` | 直接读取实际已安装服务；缺失、未安装、错误类型或未来未知枚举为 `unknown`，不能用 truthy 推断 |
| `publication.systemVersion` | 字符串或 null | 已验证系统构建信息的稳定代际键；未取得则 null，不替换为 bootId、内核版本、时间戳或随机值 |

旧客户端忽略新增字段。新客户端面对旧引擎、旧 publication 服务或未知枚举保留连接，并显示能力未知；不能把它解释为“App 没有原生宿主”。认证与缓存遵循已有 O6 约定：复用同连接凭据、no-store、按当前 bootId 重新读取。本文不添加未认证旁路，不暴露私有账本路径、资源路径、凭据或文件内容。

### 五个实际状态

| 值 | 可以作出的结论 | 不能作出的结论 |
| --- | --- | --- |
| `untried` | 该系统代际尚无有效试用结果，或一次非支持类错误已正常返回并清理试用标记 | 不能推断支持或不支持 |
| `trying` | 首次受保护试用的持久标记已经完成，正常结果尚未持久记录 | 不能据此断言原生调用已发生，更不能认定已经收到 SIGSYS |
| `available` | 此代际已有真实成功结果；当前进程成功后的后续调用无需重复写状态 | 不能推断所有挂载、所有路径、所有厂商策略和断电耐久性均已验证 |
| `unsupported` | 原生 `renameat2` 返回了精确的 EINVAL，已持久禁用同代际原子路径 | 不意味着宿主、附件或会话整体不可用；也不能把其它 errno 改写为不支持 |
| `disabled-after-crash` | 启动时发现同代际 `trying` 残留，已保守禁用原子路径 | 不能判断死亡原因是 SIGSYS、SIGKILL、断电还是结果记录失败 |

新进程读到同代际 `available` 可以报告已有结果，但本进程第一次真正原子提交前仍重新写 `trying`。启动后没有发布、只查询能力、只成功完成硬链接时，都不得凭空进行试用。`unsupported` 和 `disabled-after-crash` 跨进程保留，系统代际改变才允许重新试用。

`unsupported` 与 `disabled-after-crash` 使用现有独占复制回退。它仍保留“崩溃或复制失败时最终路径可能留下半文件”的风险；熔断解决重复触发危险系统调用，不把回退升级成原子提交。既存目标不能覆盖；真实 native 已成功、`available` 尚未落盘时发生死亡，重启也不得删除完整最终文件。

“最多崩一次”的证据范围限于受保护首次试用及稳定系统代际、私有数据目录、持有同一账本锁、正确持久写入这些前提。成功后的后续调用不逐次写 `trying`，因此不把这项协议扩大为任意后续调用或任何系统故障的全局次数保证。

## 系统版本身份

产品只使用 `binding.getSystemBuildIdentity()` 的同步返回。配套原生实现从固定 OH 官方 C API 获取以下四项：`osFullName`、`displayVersion`、`incrementalVersion`、`securityPatchTag`。每项必须是有效、非全空白、无 NUL、1–1024 个 UTF-8 字节的字符串；缺失或失效使启动失败，不能擦除原记录来重新尝试。

JS 以固定字段顺序构造系统代际键 `ohos-build-v1:<SHA256>`，并验证同一次启动读取的一致性。两次读取相同只证明启动内一致；跨重启稳定性及真实升级变化仍取决于平台 API，不能由本地测试推出。本合同不提供生产环境变量、内核版本或随机 fallback。

Linux 夹具原生 getter 有自己的固定测试身份。集成测试另在明确的测试前置中包装这一成员提供 A/B 对象，以检验代际变化；报告同时记录未包装 getter 的值和 A/B 输入，不混同于真机版本采集。

## 真实消费者与进程死亡验收

`publication-fuse-integration.py` 使用真实锁定 DSH bin 作为 `argv[1]`，依次加载 O0、测试专用 native 观察器、产品统一 preload、测试 actor。统一网络入口按产品原校验完成，随后 publication 持锁、恢复账本并装配熔断。actor 在 CLI main 前测试真实 provider 后退出。因此这是启动/发布服务集成证据，**不是已认证的完整 App HTTP/WS 回合**。

两条 helper 来自真实 attachment/session provider，原字节只在测试私有目录追加导出行；共享前缀不修改。另两条直接用原 Cordis 服务的 `attachments.saveFile/readFileStream` 与 `sessionPersistence.create/flush/open/list`，不伪造扫描器或数据库。每条分别命中：

1. 进入生产同步提交闭包之后、真正 native 调用之前；
2. 真实 native 已成功返回、但尚未向生产 guard 返回从而尚未持久 `available`。

测试包装只读取实际磁盘状态和暂存字节，输出屏障后用同步 `Atomics.wait` 停住。父进程发送真实 SIGKILL 并等待退出，然后启动另一个 Node。父不创建熔断状态、不提供 receipt、不调用恢复、不在断言前删除临时文件。生产持久写顺序由精确源码与另组故障测试核验；单凭可读 JSON 不声称已经实测掉电持久性。

重启断言包括同版 `disabled-after-crash`、native 入口计数为零、实际 helper 回退/既存目标 EEXIST、最终字节正确、源仍在、账本自动回收有身份暂存。公开附件和会话入口要真的读回或列出结果。正常成功、同进程不重复写状态、新进程重新 arm、EINVAL 持久禁用、unsupported/disabled 后系统代际改变重新试用分别验证。

每次观察还连续读取生产结构化快照 21 次，并另读一次 `service.atomic` 作原始状态对照，核 native 调用数与持久状态文件字节/身份/时间戳不变。报告中的 `publicationCapability` 来自实际生产 `readPublicationCapabilities()` 返回值，测试不再自行构造此片段。旧四文件 2f71ae9b 版本中的 oracle 结果独立保留，不追溯改称生产读取已验。新增隔离合同测试覆盖缺服务/旧服务、未知协议/枚举、错误类型、动态状态及不可变快照；它们不冒充 HTTP serializer 或 Dart parser 的端到端验收。

## O10 真机记录补充

每次真机结果至少记录机型、应用构建、四项系统身份与代际键、实际测试目录、从真实挂载信息确认的文件系统（sharefs、hmdfs、f2fs 或其它）、首次前后状态与返回错误。记录 `available`、`unsupported` 的具体机型/版本分布，不由 Linux overlay 成功推出鸿蒙全支持。

另记录：重启是否正确保留禁用、升级后是否重新试用、人工 SIGKILL 与未解释死亡是否区分、是否发生保守误触发、完整 final 是否保留、回退是否触及既有半文件风险。官方公开 syscall 规则、商用机额外过滤、SDK/ABI 和应用签名权限分别列证据；本地 SIGKILL 不能替代真机 SIGSYS 或权限验证。
