# 网页端没有可见答复的回合提示

`web-empty-reply-notice.diff` 修改 `@deepseek-ai/dsh-client-ui-chat` 0.2.2-rc.1 的 `lib/client.js`。补丁登记在 Android 和 OHOS 的公共补丁链；iOS 使用同一共享运行时组合。

## 范围

关联 #1462 的“只剩已完成”反馈。正常 stop 可以携带 reasoning 或空白 text 块；已有 EMPTY_RESPONSE 只检查完全没有内容块。这类回合可能以 completed 结束，但没有给用户的答复。

本补丁仅修网页端把这种情况静默显示为成功完成的问题，不保证修复报告中所有正文缺失，也不推断模型已经生成过正文。不改变模型请求、引擎结束原因、消息持久化或重试政策；不把思考转换为答案，不自动重发请求或重放可能已经执行的工具。Flutter 原生界面不在此补丁范围。

## 显示契约

复用既有 turn-process 投影，只有以下条件同时成立才提示：

- 回合结束原因为 completed；
- answerAnchorSeq 为 null；
- messageCount 为 0。

不能只看最后一个步骤或 turn-tail 的 closing：前面的步骤可能已有答复；图片等非文本回复也可能没有 closing。既有 hasAssistantReplyContent 不把 reasoning、tool-call 和空白文本当答复，但认可媒体。没有最终答案锚点时，messageCount 统计整轮可见助手消息，因此不会误报早先已有正文或媒体的回合。

回合摘要及读屏播报改为“未收到答复”，不再拼成功完成的耗时。回合尾部在折叠区外显示：

> 本轮已结束，但没有可显示的答复。请先查看过程或工具结果，再决定是否发消息继续。

英文同步；其它语言使用既有英文回退。保留插件的 turnTail 内容，不放进悬停操作区。关闭过程折叠、展开过程或查看历史空回合时，提示仍在。已有答复、运行中、错误、中止、中断和输出达上限的现有呈现不变。

TurnTailNodeView 通过既有 useTurnData("turn-process") 订阅当前回合的 keyed store；hook 位于所有条件返回前，不新增持久状态、扫描整个会话或改动折叠政策。迟到的有效答复更新投影后，提示随派生值消失。

## 验证

在准备好的补丁前缀运行：

```sh
DSH_PREFIX=<prefix> node --test runtime/tests/web-empty-reply-notice.test.mjs
```

用例执行发布包中的真实投影与渲染区域，覆盖仅思考、空白文本、无助手回复、工具后无答复、早先已有正文/媒体、正常最终答复、非 completed、历史回合、折叠开关、插件尾部保留、读屏文案及运行到结束再收到迟到答复的变化。React vnode 夹具不等同真实 WebView；真机仍须验证布局、折叠和实际报障回合。

原始未补丁包应在无答复提示断言上失败；不能用测试自写的判据代替真实发布包实现。完整补丁集合检查仍由现有 runtime CI 执行。
