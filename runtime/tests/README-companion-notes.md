# 固定笔记待办执行器：源码验证与边界

依赖完整 E 后态 → F01-r2 → F02-r2 → F03。此层另需 F 手机入口，
不能将本层当成独立可用的手机功能。F01/F02 r1 均为保留的 BLOCKED 历史，不叠加。

## 已实现的有限动作

只执行 `host.notes_to_todo` 固定步骤：选原目录的本层 `.md`/`.txt`，
按接单时已存的原日期半开区间匹配最后修改时间，读回整份固定清单，
用原选中模型生成一份有逐字来源的候选页，再通过原 FS/批准边界新建并读回原目标。
模型没有工具、目录选择、写文件或覆盖文件的权力。模型内容不当成执行回执。

最多20份、每份64KiB、合计256KiB，不截断文件；完整请求使用现有启发式估算，
输入估值上限32000，输出额度3000，另核同次准备返回的真实上下文窗口。
3000是现有辅助通道上限，小于09f的4000上限。估值不是实际tokenizer上界或供应商usage。
DeepSeek在真实最终序列化体、异步凭据返回后、fetch调用前复核；generic只保证既有adapter输入边界。

实际执行累计最多5分钟，批准等待不计；模型和网络等待计入。丢失时长的段保留held，
重开不归零；明确截止更早时服从原截止。未知上下文窗口不臆造默认值。
任务专用turn及所有实际操作排空后，服务才关闭execution owner与持久域。

每个step先持久认领。选取和读取可在确实安全的waiting结果后沿原范围重试；
模型只有可核实的未派证据才能重试。已有candidate不重生成。
stage intent已存但publicationAttempted仍false，且原对象只读检查确认absent，
才可保留旧held、以剩余预算新认领并首次发布同一stage。marker为true时永不再link。
真实link后只能读回原stage和输出的同一inode/摘要来补原artifact；同内容不同inode不算原发布。
这不保证跨多份来源的原子快照，也不证明断电后的磁盘持久性。

`afterExit:continue`可执行。`afterExit:pause`目前保持明确
`waiting/foreground_control_unavailable`，不选择文件、不叫模型、不发布；
现有owner连接或心跳不能证明原任务房间在前台。这是未闭合的功能缺口，
不是已实现前台执行与离页暂停。须新的显式改约才能转为continue。

## 复跑

在已经应用上述全部补丁的已锁定runtime prefix中运行，无下载、安装或完整engine启动：

```sh
python runtime/tests/fixtures/prepare-companion-task-source.py \
  --node-modules "$DSH_PREFIX/node_modules" --target android \
  --out "$PWD/.companion-task-source-test"
COMPANION_TASK_HARNESS="$PWD/.companion-task-source-test" \
  node --test runtime/tests/companion-notes-content.test.mjs \
  runtime/tests/companion-notes-runner.test.mjs \
  runtime/tests/companion-notes-model-source.test.mjs
```

OHOS源变体使用`--target ohos`及它的实际prefix，仍在Linux源码环境执行。
输出目录须不存在。实际CI沿F03的既有Export步骤准备，再运行原有Node全glob。
缺harness或任一源码SHA不符会失败；不变成通过或静默skip。
`DSH_FS_NOTES_SOURCE`可显式指向同一完整已核FS源变体，否则使用`DSH_PREFIX`。

## 模拟清单与证据范围

- 14项SOURCE_UNIT：范围/大小/整份输入、严格结构及逐字引文、空待办页、Markdown转义和估值。
- 25项SOURCE_INTEGRATION：真实Domain/JSON、PID锁、F02 Node文件IO、实际重开及三个SIGKILL断点。
  Agent、所选模型响应和服务框架为明确受控边界。
- 2项SOURCE_HTTP_IO：同一runner和真实存储/文件路径，叠真实锁定的LlmRuntime、DeepSeek最终序列化、
  SSE解析及真实loopback HTTP。模型回答是测试端点提供的固定提案。
- 两目标执行同一组41项，不能相加成82个不同场景，也不与早期15/17/22/38/40版重复累加。
- 当前执行环境为Linux overlay。仅statfs capability类型注入支持值，其余Node IO真实；
  生产在overlay不宣称可发布。ext4/XFS/Btrfs设备与OS断电测试待owner，不能据这些测试认证。
- 完整Cordis/AgentLoop/JSONL重启、真实WS原批准卡、Dart/Flutter/Android与真实付费模型均NOT_RUN。
  严格parser只证明结构和逐字证据；真实模型是否把否定、引用、已完成事项正确排除仍待语义评测。
- 首轮便携源准备遗漏LlmRuntime实际读取的原package.json，曾出现2个MODULE_NOT_FOUND；
  现为该原文件单独核SHA并携带。旧失败日志保留，不将其写成产品测试失败或跳过。

## 回退

本片为F04完整替代r3，直接叠F03，不叠F04 r1/r2。r1的已派模型在取消/截止后可能继承
控制错误的waiting/failed状态；r2只查abort位和waiting，漏掉墙钟前跳、定时器尚未触发的直接截止guard。
r3同时按明确截止/预算中断原因核原步骤已持久的派发/用量事实，无完整结果时保unknown。
明确取消且原请求已观察complete、原iterator已排空时，旧step可记cancelled，旧usage始终保留。
任务头的后续停止与原模型结果是两件事；不会因旧请求unknown自动再派模型。

按手机层先停新接单，再逆序回退。已有Host任务aggregate、原usage和artifact是真实历史，
不因回退删除；保留原数据目录与stage证据。取消不会删除已有文件。
只有持久artifact已确认后才尽力清理私有stage；清理失败不抹掉真实artifact。
