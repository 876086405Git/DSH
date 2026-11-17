# DeepSeek Messages 的无名错误帧

`deepseek-unnamed-stream-error.diff` 改 `@deepseek-ai/dsh-llm-deepseek` 的 Messages 适配器（`lib/index.js`），排在 `deepseek-refusal.diff` 之后。

DeepSeek 的 Anthropic 兼容接口在成功的 HTTP 响应里，可能发一个没有 SSE event 名、JSON 里也没有顶层 `type`、只带 `error.message` 字符串的 data 帧（例如等生成开始超时）。原 `parseSse` 先做 type 校验，报 `MALFORMED_RESPONSE`，服务给的错误文字就丢了。补丁后：

- 在原 type 校验前，把这种形状交给现有的 `providerError`：默认分类为 `SERVER`，已有的 AUTH、QUOTA、RATE_LIMIT 等更具体的规则仍优先，错误文字保留；
- 仍然抛错，不产生成功块；
- 有 event 名或带 `type` 的事件、缺 `error.message` 的无名帧等其它畸形输入，走原来的路径。

只修分类，不承诺所有部署都会自动重试。

验证：在打过补丁的前缀上 `DSH_PREFIX=<prefix> node --test runtime/tests/deepseek-unnamed-error.test.mjs`（新形状、现有带 type 的错误、有 event 名但缺 type、无名但缺 message），以及 `python3 -I runtime/tests/test_patch_dsh.py`。
