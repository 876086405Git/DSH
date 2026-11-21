# 空工具名历史的请求投影

## 触发条件与限定结论

先前提供方产生了名称恰为 `""` 的工具调用；这一调用及同 ID 的工具错误结果已进入正式历史。
随后继续使用会拒绝空函数名的目标，且该历史仍在请求上下文中。原来的
pi-ai OpenAI-completions 与 DeepSeek 自有 Messages 出口会继续发送空名字；
新的错误 attempt 不会改掉这条旧 assistant/message，因此普通后续请求仍含同一拒绝原因。

这里把严格目标拒绝空名字作为给定条件，不声称所有提供方都会这样拒绝，也不声称
更换目标或主动改变上下文后仍绝对不可恢复。本片只去除这两个出口的空名阻断。

## 请求投影

`empty-tool-name-replay.diff` 只在两个发送出口处理名字恰为 `""` 的历史调用：

- pi-ai 已构造请求 context 后，仅当目标 `model.api === "openai-completions"`，把新建
  assistant/toolCall 的空 `name` 与配对 toolResult 的空 `toolName` 改为 `"unknown"`。
  这复用既有结果名称 fallback，不改变其它 pi-ai 协议的 native replay。
- DeepSeek Messages 的 assistant→tool_use 投影仅把空 `name` 改为同一 `"unknown"`。
  tool_result 继续通过原 `tool_use_id` 关联调用。

不 trim 或重写任何非空名称；不改调用参数、调用/结果 ID、错误结果正文与错误标志。
持久历史及 replayState 保持原样，仍可回看原始空名字。占位名称只描述已经发生的
未知工具调用，不注册工具、不执行新调用，也不新增拒绝、重试或状态。

原接收/执行路径（含 owner 108 的 toolcall_end ID 补齐）不在本片范围内。
本片不删除单侧调用或结果，不把两者转为文本，不声称对目标的其它约束作了修复。

## 覆片依赖与登记

固定仓库基底仍为 `69679cc92c9d7c59b826c622dd1d422c38913200`，应用时先包含
owner 108 最终 `piai-tool-call-id.diff`，再包含 5660/request109 的
`piai-bedrock-usage-evidence.diff`，本片登记在 Bedrock 之后、OHOS 专属片之前。

核对原文：pi-ai after108 为 `bf5c03ca763a7ee3ea7e6b193f07fd7e658d1ad4b43b24e69db12b51650e9b80`；
after108+5660 为 `2c75fbaa9a704c782494931e399839d40366194af3e27873a1859b1b1f154190`；
DeepSeek 为 `2ef54c3220c6ff9ac3f7593efa7c3b3813f2d79bca43fefbc8dde7f9ddcfa457`。
内层两个 hunk 均采用非空唯一旧块，逐一检验后替换，不使用纯插入。

同时登记 Android/OHOS 同一相对位置；仅改 `targetSets`，hash 由本机随完整链重录。
OHOS 同改 pi-ai index.js 的专属片为 `ohos-attachment-diagnostic.diff`、
`ohos-piai-empty-models.diff`、`ohos-piai-text-preabort.diff`；没有同改 DeepSeek index.js 的 OHOS 专属片。

## 验证边界

同名 `runtime/tests/empty-tool-name-replay.test.mjs` 参数化两个公开 adapter，构造带合法
pi-ai v2 replayState 的已有 assistant/tool 历史，经实际发送序列化与流解析调用模拟严格接收方。
接收方拒绝空名字、对替代后的请求返回协议合法的合成回复。断言两个 ID 保留并配对、
错误结果保留、非空名字不变、输入历史未变，且普通请求可返回后续文本。

测试用的是发布包公开入口与实际 SDK，没有重测 108 的接收/执行。它不访问付费服务，
不证明实际提供方的所有校验，也不是整段 Agent/JSONL 回放集成。

准备 DSH 0.2.2-rc.1 Android 全覆片前缀时，`rtbuild.py patch-dsh` 必须带 `--target android`。
随后运行：

```bash
DSH_TEST_PREFIX=/path/to/prefix node --test runtime/tests/empty-tool-name-replay.test.mjs
```

缺少前缀时明确 skip，不能将语法检查或 skip 记作公开 adapter 回归通过。
