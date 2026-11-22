# J：owner 本机真实引擎联合验证

这是独立测试增量，**没有改变 J/F 产品、批准策略或冻结补丁**。作者仅做 Node 语法检查；下列三例均 **NOT_RUN**，不能凭代码存在或无 `DSH_PREFIX` 的跳过结果写成通过。

## 范围与受控部分

三例从真实 `dsh-app-boot` 创建 Cordis Host，实际加载 AgentRegistry/AgentLoop、Session/JSONL、Domain/JSON、SandboxedFileSystem、ApprovalService 和 Gateway/Remote 插件，调用生产 `mountCompanionTasks`。不注册 adapter、不安装默认模型服务、不发普通 inbox，不使用假 Factory/Session 或 `flush:true` 替身。

输入是测试临时根内的四份明确文本票据；原件、XLSX、Domain 和 JSONL 都执行真实文件 IO。测试只控制 owner Peer 身份及其批准回答、以及冷恢复例的发布前暂停时序。批准通过实际 `$events` 与 `$events/result`，没有本地直接返回 `allowed-once` 的 answerer。不能据此宣称已验证手机批准卡 UI、实际登录认证、完整部署的所有附加插件，或 PDF 在这条联合链上的运行。

测试把当前仓库 bridge 的 `lib` 原字节复制到自己的临时目录，再将其 `node_modules` 链接到指定 prefix 的完整 `node_modules`（包含 `zod`、`@js-temporal/polyfill` 和 `@deepseek-ai`）；不会修改 prefix 或仓库依赖目录。没有下载/安装。这里只用四份 `.txt` 原件，因此这条 Factory/JSONL 联合测试不需要另外启用 PDF；原 J PDF 的标准准备和验收仍须按 J 交付说明执行，不以本文代替。

## 必需的实际前态

1. 使用 owner `97c94e3a2be81c72659f9ad3b3fd126613771cb1` 精确源码；该头已包含 J 六片，无需重复叠 J。若再应用 F，使用以该头为前态的最终正式 F 片。此测试读取当前 repo 的 pins 和 lock，不沿旧 J/F 被阻断片。
2. `DSH_PREFIX` 指向完整、已按该目标实际打补丁的引擎前缀，结构为 `node_modules/@deepseek-ai/...`。源码摘录 harness 不可冒充完整前缀。准备沿仓库已有 runtime 流程，本测试不安装依赖；版本/已知最终 patch SHA 不符会失败。
3. Node 24，使用本仓库约定的 owner 运行环境。`COMPANION_TASK_TARGET` 是 `android` 或 `ohos`，用于核真实源变体，不能把 Linux source 执行叫设备执行。
4. `COMPANION_J_OWNER_ROOT` 是**现有绝对路径**，作为本测试 `mkdtemp` 的父目录。它必须位于生产已支持的 Linux ext2/3/4、XFS 或 Btrfs；测试在自己的新子目录中放账本、JSONL、原件和产物，不读取该父目录内的其它文件。overlay/tmpfs/非 Linux 均明确 BLOCKED，不注入 statfs、不伪报 ext4。

在设置上述真实环境变量后，从仓库根运行实际入口：

```sh
node runtime/tests/owner/run-companion-receipts-engine.mjs
```

可用的环境变量只有：

| 变量 | 用法 |
|---|---|
| `DSH_PREFIX` | 必填，实际完整已打补丁引擎前缀的绝对路径。 |
| `COMPANION_J_OWNER_ROOT` | 必填，真实支持介质上的临时测试父目录绝对路径。 |
| `COMPANION_TASK_TARGET` | 默认 `android`；OH 公共 JS 前缀选 `ohos`。不代表 Android/OH 设备运行。 |
| `COMPANION_J_OWNER_KEEP=1` | 保留本轮新建的临时 home，便于核原始 JSONL/Domain/XLSX；默认测试结束删除自己的子目录。 |

显式 runner 缺能力时输出 `BLOCKED / NOT_RUN` 并退出 2；prefix SHA 错误或测试失败非零退出。它原样继承父 Node 的 `process.execArgv` 和环境；使用 REQUIRED 模式，不能把三例全跳过的退出 0 当验收通过。

需要 Node 原始 TAP 时也可直接运行：

```sh
node --test --test-reporter=tap runtime/tests/owner/companion-receipts-engine.test.mjs
```

直接模式缺环境时会显式 `SKIP: BLOCKED/NOT_RUN`，这不是 PASS。此目录不在常规 `runtime/tests/*.test.mjs` source glob 内，不改变默认 CI 的依赖要求。应保存完整 TAP、pass/fail/skip 总数及诊断中的 prefix 身份、真实介质类型和临时根。不要只截取 exit 0。

## 三例应验证的事实

| 用例 | 真实断言 |
|---|---|
| 四原件→原批准→XLSX | 真实工厂创建一单，空 agentOptions；原 Session 的 turn/asked 已写进 JSONL 才见批准卡；原 eventId 与 approvalId 不相同且任务绑定一致；未允许前零文件/零 link；实际允许后一个已登记 XLSX，按原 identity/hash/size 重开并核 20 个单元格；零模型入口/零 fetch/无模型步骤。 |
| 冷恢复 | 批准已持久后，唯一受控暂停点拒绝执行实际 stage，等待真实 owner-stop 信号。`store.stop()` 排空 turn 并注销/关闭原 Agent writer；读取真实 JSONL 后 `close()` 释放 Domain 锁。新 boot 创建新的 Host/Registry，自动恢复原 waiting J；必须实际调用 resume、同 agentId/store/execution/原 revision、旧 JSONL 前缀与旧完成 step 不变、没有第二批准、只一次真实最终 link。不是重新 GET 冒充恢复。 |
| 原拒绝 | 通过真实 Gateway 回 `rejected`；原 decided 写 JSONL，保持等待/拒绝事实，无 writeSheet claim、无文件/产物/link，零模型。 |

冷恢复是正常 stop/排空后重启；它**不**替代此前独立 source 测试的 SIGKILL/断电/marker 窗口。跨主机网络盘、真实手机 App UI/认证、full 原屋其它插件和 PDF 联合链仍另验。测试输入不涉及用户实际文件。

## 当前交付证据

作者只运行三个新 `.mjs` 的 `node --check`，未运行本页命令、boot、引擎安装或模型。完整装配（含当前 Typert/remoteAccess 插件初始化）只能由 owner 实跑确认；装配失败必须保留为真实失败，不得换用假服务让测试转绿。预期三例通过不是已得到三例通过。
