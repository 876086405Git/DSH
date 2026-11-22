# Helper separate_chat_history 与共享 PromptManager

## 固定来源与作用域

固定 SPreset [53bd585d](https://github.com/starowo/starowo.github.io/blob/53bd585da14248ba10baaede7fc7ed0cebe1eeeb/regex_bind/inject.js)、ST [7e8663cd](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/openai.js)、Helper [29331c36](https://github.com/N0VI028/JS-Slash-Runner/tree/29331c36fb9b2e880d4d488ff919317e1bc95684)。本增量按 owner 实际每 chat 一个画布的路由分区；上游单页 JS global 的跨 chat 切换共享不自动迁移到 App 的多个画布。
原生 TavernScriptRawRequest 保留原 ABI，未接新 collection reader；本增量接 Helper raw/命名 raw 与普通装配的 SP separate 路径。它不包含 owner 的其他 raw 预算或工具数据修复。

## 保存与消费

| 时点/路径 | 共享状态行为 |
| --- | --- |
| native send/continue、quiet、Helper normal/in_use | 同一次真实准入 accumulator 的 finally 发布；不等 HTTP 或生成成功 |
| Helper raw / 命名 normal 转 raw | 不发布，消费本 chat 当前集合 |
| MessageInjections | 改 getChat 产物；不回写共享集合 |
| native system squash | 快照独立 flatten，合并相邻无 name 的 system，保留首条逻辑 ID；newMainChat/newChat/groupNudge 保护 |
| END / STOP / 预设切换 | 保留 PromptManager 集合；Entry Map 的清理另按其原规则 |
| host 替换 / resetSPresetPage(chatId) | 前者清全部集合，后者只清目标 chat 并递增其 page epoch |
| authoring preview | 隔离，无共享 setter |

快照只保存已准入消息、来源、ST 逻辑 ID、collection/direct 拓扑；深复制并冻结，消费时另建可变 wire。不会重读整棵历史、重放宏/WI/预算，也不保存 preset、最终 request 或模型回复作为替代。物理 node ID 留作 provenance，不拿它补 ST 逻辑 ID。
集合项 chatHistory 整组压缩，包括 header/groupNudge；其他 collection 直接展开。system squash 后改走 direct Message，只有逻辑 ID 以 chatHistory 起头的连续项目才压缩。continueNudge 与 controlPrompts 保持独立根集合，不能随历史一起压缩。
源 collection serializer 对 signature/reasoning 用真值，SP direct serializer 用 != null；空字符串的差异保留。tool_call_id 来自工具 Message 的逻辑 ID。

## 条件、空集合与已知源怪例

separate 先在本次传入 prompt 检查并删除 conditional_tag。未命中不会读取共享状态；命中后从共享集合重建，执行 squash 后再删一次旧集合中的 tag。新 raw 输入不能代替这个门禁，旧 tag 也不能触发本次无 tag 的调用。
未初始化不是空集合：实际进入 separate 且无本 chat 集合时返回可见 hookFailure；已经发布的空 root/空消息集合合法产生 []。上游抛错前会清输入数组，本桥失败时不发送请求，不声称复制调用者可见的数组原地清空。

1. ST 普通 continuation 位移出的消息没有被普通 history 循环赋逻辑 ID。不开 system squash 时它留在 continueNudge collection，可正常序列化；flatten 后独立的非空 assistant 消息在 SP `.identifier.startsWith` 处抛 TypeError。本桥保留缺 ID 并可见失败，不用 nodeId 伪造成功。原对象本有合法 ID、空内容或 system 合并等控制分支另按实际拓扑处理。
2. Helper normal 数组图片的 once(CHAT_COMPLETION_PROMPT_READY) 监听器只改返回 chat，manager Message 仍是 `__IMG_ARRAY_MARKER_` 文本。因此 separate 会重新读到 marker，不保留先前 wire 图片。本桥只把内部 marker 译回固定源字面值，不把已 materialize 图片缓存成源 manager；普通不启用 separate 的图片路径仍发送图片。

## partial / dryRun 的资格边界

ST prepare 在 try 内出错会 catch 后继续 finally setter、getChat/READY；本引擎保留既有失败返回方式，但 finally 发布当前已加入 root 的部分 accumulator，不回退上一成功请求。已准备或仅 reserve 的 header、groupNudge、continue/control 不在发布集合中；history 开始时可留下空 collection，已准入历史按真实顺序保留。
覆盖的是本引擎准入模型的实际 accumulator。它不把全部 ST 异常吞吐、token 实现、V3 装饰器和失败副作用时序宣称为逐步相同。
ST setter 保存同一对象，live system squash 在 await 计数前已 flatten/修改首条内容；计数拒绝时可能留下中间对象。当前快照独立、无额外计数，未模拟这个异步失败残留状态。源控制探针已记录，不能用成功快照验收该异常路径。
ST UI tryGenerate/render 的 dryRun 也可更新 manager；无 activeCharacter 的 dryRun 在创建 ChatCompletion 前退出。App 没有对应的全局 PromptManager UI，本增量不把 detached authoring preview 偷换成 setter，未模拟这类 UI 更新来源。

## 页面 reset 协议

可选 TavernSPresetPageLifecycle 见 SPRESET-HOST.md。可信 App 在 pageLost/document 替换时同步调用 resetSPresetPage(chatId)，再开始新文档工作。关闭 script context 不能作为 reload 信号；hostVersion 也不覆盖同 host 的 reload。
每 chat epoch 被 SPresetGeneration 捕获；reset 后旧求值、集合发布和请求采用会被 check 拒绝。不会停止 JS、撤销已提交效果或增加 timeout；真实载体/回执沿原规则。当前 owner App 尚未接该能力，测试中的显式 reset 不构成 WebView reload 验收。

## 验证入口

- test/w11_helper_history_test.dart：公开 Helper/native API、真实 SQLite、生产 HTTP 编解码；仅 HTTP 对端/宿主脚本执行用可控边界。
- test/w11_prompt_manager_snapshot_test.dart：真实 assembler partial/counter 宏调用轨迹、immutable source 与 mutable wire、源拓扑向量。
- 交付外层保留固定源 setter-source-probe、continuation-source-probe、image-marker-source-probe 和原六组 separate-history-topology-probe；仅相应 I/O/token/宏或 squash 文本变换为明确替身，不当完整源引擎或 App 实跑。
