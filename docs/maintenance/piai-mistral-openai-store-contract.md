# Mistral 原生端点的可选 store 字段

## 触发条件与证据

用户选择自定义 OpenAI Chat Completions，Base URL 为
`https://api.mistral.ai/v1`（可带末尾 `/`），未显式设置 `supportsStore`。
DSH 0.2.2-rc.1 的 pi-ai 1.5.0 当前自动检测会生成 `store:false`。
[#1690](https://github.com/ccch1mneyyy/dsh-Go/issues/1690) 报告该请求以
422 拒绝，错误位置为 `body.store`、输入值为 `false`。

[Mistral 模型页](https://docs.mistral.ai/models/deepseek-v4-flash-1017)
确认其托管的模型 ID 为 `deepseek-v4-1-flash-1017`。
[官方迁移示例](https://docs.mistral.ai/resources/migration-guides)
使用 OpenAI 客户端和 `/v1` Base URL，因此不把该配置直接判为用户填错。
[当前聊天文档](https://docs.mistral.ai/inference/conversations/chat-completion)
另列 `/openai/v1/chat/completions` 预览接口；本修复没有该接口拒绝 `store`
的证据，不扩大自动识别范围。

## 行为边界

新增 `piai-mistral-openai-store.diff`，接在已有 Google store 覆片之后。
仅对解析为 HTTPS、主机恰为 `api.mistral.ai`、默认端口、路径恰为
`/v1` 或 `/v1/` 的请求，把自动检测的 `supportsStore` 设为 `false`。
URL 标准化仍接受主机大小写和显式 `:443`。

显式 `model.compat.supportsStore` 继续覆盖自动结果。其它兼容字段、消息角色、
token 参数、流式用量、reasoning 参数保持原样；不剥离通用 extra_body，
不更换用户选择的协议或 Base URL，不重试另一端点。修复使该端点的默认请求
不再发送 `store`，不声称其它参数已获服务端接受或整段会话已跑通。

公共覆片同时登记在 `series`、`targetSets.android` 和 `targetSets.ohos`
的相同位置。OHOS 专属 `ohos-provider-body-timeout.diff` 也修改同一
`openai-completions.js`；本片不改其逻辑，公共末态变化后需随链重录 pins。

## 验证

`runtime/tests/piai-mistral-openai-store.test.mjs` 使用真实发布包的公开
`stream()` 与 OpenAI SDK，经已有 `fetch` 接口捕获完整请求体；返回固定
400，既不访问付费服务，也不模拟服务端认可。覆盖报告 URL、等价 URL、
显式覆盖、原有 OpenAI/Google 行为、Mistral 预览端点与自定义代理不变。
完整请求体断言用于确认本片仅改变 `store`，URL 断言确认没有换协议路径。

准备好 DSH 0.2.2-rc.1 Android 全覆片前缀后运行：

```bash
DSH_TEST_PREFIX=/path/to/prefix node --test runtime/tests/piai-mistral-openai-store.test.mjs
```

没有前缀时测试会明确 skip，不能据此记为请求捕获已通过。真实 Mistral
服务端行为须由有效账号下的实际请求验证，单元测试不替代该结论。
