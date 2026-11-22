# F 有限任务源码测试

本组验证真实 Domain/JSON backend、PID 文件锁、临时文件 IO、HTTP 路由，以及实际 task-turn/ApprovalService/approveEscalation 源码。实际工厂、Cordis 范围、Session 持久化及远端回答由明确的受控 peer 提供；它不是完整引擎、JSONL 崩溃恢复、设备或供应商计费测试。

## 准备与现有 CI

输入须是用仓库锁包准备、按 `runtime/patches/TARGETS.md` 打完当前完整补丁链的 DSH 前缀。F03 依赖 E、F01-r2、F02-r2；两个旧 r1 不可替代。准备器不下载或安装任何依赖，逐一核对八个实际 bundle 源文件及 zod、Temporal、jsbi 三个依赖的版本和文件树摘要。

现有 `.github/workflows/ci.yml` 的 `Export the runtime test paths` 步骤在真实前缀恢复/准备后运行本准备器，并导出 `COMPANION_TASK_HARNESS`。随后原有 `runtime/tests/*.test.mjs` 全量命令保持不变。缺少输入或 pin 不匹配会明确失败，不返回 skip 或成功。

已准备前缀的本地 Linux 命令（从仓库根目录）：

```sh
python3 -I runtime/tests/fixtures/prepare-companion-task-source.py \
  --node-modules /absolute/patched-dsh-prefix/node_modules \
  --target android --out /absolute/new-companion-task-source
export DSH_PREFIX=/absolute/patched-dsh-prefix
export DSH_TEST_PREFIX="$DSH_PREFIX"
export COMPANION_TASK_HARNESS=/absolute/new-companion-task-source

node --test runtime/tests/companion-task-store-source.test.mjs \
  runtime/tests/companion-task-http.test.mjs \
  runtime/tests/companion-task-execution-source.test.mjs
```

`--out` 必须是尚不存在的目录；不覆盖旧测试证据。OHOS 源码对照改用其真实最终前缀和 `--target ohos`，输出另一个新目录。它仍是在 Linux 上跑该份 JS，不代表 OHOS 原生支持或设备结果。完整 CI 仍运行原命令：

```sh
node --test --test-reporter=spec --test-reporter=junit \
  --test-reporter-destination=stdout \
  --test-reporter-destination=/absolute/companion-engine.xml \
  runtime/tests/*.test.mjs app/tool/engine_auth/*.test.mjs
```

全量命令还需要现 CI 已导出的其它 runtime/工具路径；本片没有另造测试运行器或替代这些既有准备步骤。上述全量 CI 尚未在本次作者环境执行。

## 精确测试范围

| 文件 | 项数 | 实际边界 |
| --- | ---: | --- |
| companion-task-store-source.test.mjs | 31 | 原 Domain/JSON/atomic-write 的实际提交、关闭、锁和临时文件；每任务单 aggregate CAS、原命令重放、取消/旧明细、时间预算、发布 marker/attempt、恢复门禁 |
| companion-task-http.test.mjs | 8 | 真实 loopback HTTP→生产 task routes→实际 Domain；认证和文件观察是显式 peer |
| companion-task-execution-source.test.mjs | 9 | 生产 execution owner→实际 F01 turn/批准服务/原 sandbox escalation；factory、Session 保存及原卡交接是受控 peer |

准备器只摘取锁定源码中的明确 region，去除未调用的配置 schema/服务注册包装；不会改写被测事务、文件锁、turn 或批准算法。为执行这些 region 提供的少量 Cordis/schema/type-brand peer 在准备器中明列。`source-evidence.json` 保存实际输入摘要和当次复制的 bridge 源码摘要。

真实测试文件系统为 Linux 临时目录。除实际不支持分支外，测试用内部 statfs seam 注入受支持 magic，以执行当地实际文件 IO；这不证明运行环境的 overlay 支持产品持久接单，也不证明断电、网络盘或跨主机锁。生产仅在实际 Linux ext2/3/4、XFS、Btrfs 路径开放该持久域，其余明确 unavailable。

F03 的挂载引用后继 `notes-to-todos.js` 固定 runner；独立 F03 不能作为完整功能交付。真实 runner、F02 文件身份/发布、手机 v13 快照和原批准卡入口必须组合后验收。批准 ID 与 gateway event ID、原手机房间与真实 Host Session 不可互换。旧未知用量明细即使后续取消成功也保留；成功取消不把历史写入或收费改为未发生。
