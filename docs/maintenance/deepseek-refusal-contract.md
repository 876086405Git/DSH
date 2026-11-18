# DeepSeek Messages 的合法拒答

`deepseek-refusal.diff` 改 `@deepseek-ai/dsh-llm-deepseek` 的 Messages 适配器（`lib/index.js`）。

DeepSeek 的 Anthropic 兼容接口在 `message_delta.stop_reason` 里合法地返回 `refusal`。原 `stopReason` 只认 end_turn 等已知值，遇到 `refusal` 抛 `MALFORMED_RESPONSE`，而且抛在吸收最终 usage 之前。补丁后：

- `refusal` 返回已有的 `kind: "error"`，失败由 `LlmError` 构造，code 为 `REFUSAL`；
- 终帧照原顺序先发最终 usage，再发 finish；error 不附成功的 `replayState`；
- 其它未知 reason 仍按格式错误（`MALFORMED_RESPONSE`）抛出。拒答是一种「结束」，不是解析失败。

已流出的文字和块不撤回，也不把拒答当成功。合法拒答不再进入请求的 catch，因此不再调用 `auth.onRequestError`。默认重试码不含 `REFUSAL`。

验证：在打过补丁的前缀上 `DSH_PREFIX=<prefix> node --test runtime/tests/deepseek-refusal.test.mjs`（普通 end_turn、空文本拒答、部分输出后拒答、未知 reason 仍 MALFORMED），以及 `python3 -I runtime/tests/test_patch_dsh.py`。Refs #1427。
