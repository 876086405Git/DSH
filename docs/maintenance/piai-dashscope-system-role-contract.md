# 百炼与千问 Chat 端点的系统消息角色

## 触发条件与证据

自定义渠道使用 OpenAI Chat Completions 协议和百炼或千问官方的
`/compatible-mode/v1` 地址，模型声明支持思考，且没有显式设置
`compat.supportsDeveloperRole`。DSH 0.2.2-rc.1 的适配器会把模型的
`reasoningEfforts` 映射转换为 `reasoning: true`；pi-ai 1.5.0 原有自动检测
没有识别这组端点，因而将系统指令写成 `developer`。

[#1369](https://github.com/ccch1mneyyy/dsh-Go/issues/1369) 与
[#1139](https://github.com/ccch1mneyyy/dsh-Go/issues/1139) 报告服务端拒绝该角色，
并给出使用 `system` 成功的对照。该对照是报告人陈述。
[百炼 Chat 官方文档](https://help.aliyun.com/zh/model-studio/qwen-api-via-openai-chat-completions/)
将系统消息角色规定为 `system`，并列明旧 DashScope 域名与新的 workspace
专属域名。
[千问 Chat 官方文档](https://platform.qianwenai.com/docs/api-reference/chat/openai-chat)
也规定该角色为 `system`，并给出 `maas.qianwenaiapi.com`；
[千问模型页](https://www.qianwenai.com/models/qwen4-max) 明列 #1139 使用的
`cn-beijing.maas.qianwenaiapi.com`。
[阿里云官方公告](https://help.aliyun.com/zh/marketplace/notice-of-update-to-the-cloud-marketplace-service-provider-onboarding-agreement-fiscal-year-2027)
确认千问网站为关联平台；这里未把相似域名或第三方文章当成官方身份依据。
源码足以复现错误的默认角色选择；真实服务验收仍需实际请求证据。

角色选择取决于模型的思考能力。模型仍声明该能力时，仅在当前会话关闭
思考档位不会改变原来的角色选择。

## 修复范围

新增 `piai-dashscope-system-role.diff`，对以下 HTTPS、默认端口、路径为
`/compatible-mode/v1` 或带尾斜线的端点，将自动检测的
`supportsDeveloperRole` 设为 `false`：

- `dashscope.aliyuncs.com`；
- `dashscope-intl.aliyuncs.com`；
- `cn-hongkong.dashscope.aliyuncs.com`，见[官方接入说明](https://docs.modelstudio.console.alibabacloud.com/en/model-studio/compatibility-of-openai-with-dashscope)的香港旧域迁移项；
- `maas.qianwenaiapi.com` 与 `cn-beijing.maas.qianwenaiapi.com`；
- `{WorkspaceId}.{region}.maas.aliyuncs.com`，workspace 与 region 各占一个域名标签。

沿用已有 URL 解析，接受域名大小写及显式 `:443` 的等价写法。
显式 `model.compat.supportsDeveloperRole` 继续覆盖自动结果。
其余兼容字段、请求参数、消息正文及用户选择的地址保持原样；自建代理仍按
既有默认值及显式配置处理。Responses 是另一协议，不使用这段 Chat 构造器。

公共覆片登记在 `series`、`targetSets.android`、`targetSets.ohos` 的同一
相对位置，接在 `empty-tool-name-replay.diff` 后。OHOS 专属
`ohos-provider-body-timeout.diff` 也修改同一个 `openai-completions.js`，
录制 pins 时需一起更新其输入、输出身份。

## 验证

`runtime/tests/piai-dashscope-system-role.test.mjs` 使用真实发布包的公开
`stream()` 与 OpenAI SDK，通过现有 `fetch` 接口捕获完整请求体；固定返回
400，使用合成密钥、关闭重试。覆盖旧 DashScope 域名、#1139 的千问域名、
新 workspace 域名 → `system`，以及显式 `supportsDeveloperRole: true` 覆盖、官方 OpenAI
不变 → `developer`。完整请求体断言用于检查此修复只改变目标端点的指令角色。

在 DSH 0.2.2-rc.1 的 Android 全覆片前缀上运行：

```bash
DSH_TEST_PREFIX=/path/to/prefix node --test runtime/tests/piai-dashscope-system-role.test.mjs
```

没有真实前缀时测试明确 skip；语法检查或函数级探针不能替代 SDK 请求捕获，
请求捕获也不能替代百炼服务端验收。

本轮局部检查完成了唯一非空 hunk、SHA256、JS 语法及原函数/表达式前后探针；
真实前缀的 SDK 捕获提交本机完整 Linux CI，实际执行结果以回执为准。
