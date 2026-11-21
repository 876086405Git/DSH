# pi-ai 工具调用缺 ID 时补本地 ID

## 触发条件

自定义 OpenAI 兼容服务返回工具调用，但到流结束都没给 `id`（缺字段或空字符串），
`finish_reason` 是 `tool_calls` 或 `stop` 都一样。pi-ai 的 `ensureToolCallBlock()`
把缺失的 ID 存成空字符串；原链照常提交 `assistant/message`、执行工具，
`tool/call` 和 `tool/result` 都带空 ID。JSONL V4 编码要求 `tool/result` 有非空且对得上的
`toolCallId`，于是拒绝这一批，失败批次放回写队列队首，此后这个会话每一轮都报
`format v4 tool/result ... requires toolCallId matching its tool source`
（[#1661](https://github.com/ccch1mneyyy/dsh-Go/issues/1661)）。

## 修法

`piai-tool-call-id.diff` 只改共用 pi-ai 适配器 `toStreamChunks()` 的 `toolcall_end` 出口：
`event.toolCall.id` 为空时用 `call_<毫秒时间>_<contentIndex>` 作为块 ID。做法照抄 pi-ai
自己在 `google-generative-ai.js` 里给 Gemini 补 ID 的方式。服务后来补发的 ID 在
`toolcall_end` 之前就已写进 `event.toolCall.id`，不受影响。

工具因此照常执行，`tool/call`、`tool/result` 与回放给服务的 `tool_calls[].id` /
`tool_call_id` 是同一个本地 ID（回放取的是 Harness 块上的 ID）。名字也为空的调用
（#1661 报告里的情形）走现成的 unknown-tool 错误结果，模型能接着说。

本片不修已经写坏的旧日志。

公共覆片接在 `piai-usage-evidence.diff` 后，`series`、`targetSets.android`、`targetSets.ohos`
都已登记；同文件的 OHOS 专片（`ohos-attachment-diagnostic.diff`、`ohos-piai-empty-models.diff`、
`ohos-piai-text-preabort.diff`）的 pins 随之重录。

## 回归

```bash
DSH_PREFIX=<打好覆片的前缀> node --test runtime/tests/piai-tool-call-id.test.mjs
```

真实 pi-ai SDK、`PiAiAdapter`、`AgentLoop`、Session 与 JSONL，对端是本地 SSE。
两种情形：`stop` 结束、显式空 ID 的正常工具；`tool_calls` 结束、既无 ID 也无名字。
断言工具结果回到服务时 ID 一致且非空，回合正常结束，flush 后重读的日志与内存一致。
