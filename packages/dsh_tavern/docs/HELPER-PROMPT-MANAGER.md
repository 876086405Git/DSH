# Helper separate_chat_history 与当前请求拓扑

## 固定来源与作用域

固定 SPreset [53bd585d](https://github.com/starowo/starowo.github.io/blob/53bd585da14248ba10baaede7fc7ed0cebe1eeeb/regex_bind/inject.js)、ST [7e8663cd](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/openai.js)、Helper [29331c36](https://github.com/N0VI028/JS-Slash-Runner/tree/29331c36fb9b2e880d4d488ff919317e1bc95684)。本增量按 owner 实际每 chat 一个画布的路由分区；上游单页 JS global 的跨 chat 切换共享不自动迁移到 App 的多个画布。
ADD14 #6–10 明确修正固定上游也存在的旧集合重读、MI/图片丢失、条件后处理及 continuation 缺 ID 边界。本实现不把这些修正宣称为固定源等价；原始源码探针与历史失败记录保留。原生 TavernScriptRawRequest 保留其原 ABI。

## 保存与消费

| 时点/路径 | 共享状态行为 |
| --- | --- |
| native send/continue、quiet、Helper normal/in_use | 同一次真实准入 finally 保存本代局部快照；身份仍有效才发布到该 chat 的共享 Map |
| Helper raw / 命名 normal 转 raw | 使用本次 raw 的实际 segments 与 chatHistory 成员；不读取上一轮共享消息，不依赖页面已初始化 |
| MessageInjections / 图片 materialize | 消费当前转换后的消息；快照只补充 collection/direct 归属，不恢复旧内容 |
| native system squash | 保留原成员到逻辑 ID/collection 的索引，再记录 flatten；旧系统文本已合并后，MI 展开的原成员仍可定位 |
| END / STOP / 预设切换 | 保留共享快照供状态观察；后续请求不得以它替换自身输入。Entry 清理沿独立规则 |
| host 替换 / resetSPresetPage(chatId) | 前者清全部集合，后者只清目标 chat 并递增其 page epoch |
| authoring preview | 隔离，无共享 setter |

快照保存已准入消息、来源、逻辑 ID 与 collection/direct 拓扑，深复制并冻结。消费时以当前 segments 的顺序和数量为准，不按位置 zip，不从旧内容重建，不重放宏、世界书、预算或历史读取。物理 node ID 留作 provenance，不拿它补 ST 逻辑 ID。
同一个原 segment ID 可对应 MI 的 assistant 和多个 tool result；每条当前消息均保留。当前字段完整复制，包含 DeepSeek reasoning_content、图片 parts、工具参数与真实 tool_call_id，不再次经过旧 Message 字段白名单。
集合项 chatHistory 整组压缩，包括 header/groupNudge；其他 collection 直接展开。system squash 后改走 direct Message，只有逻辑 ID 以 chatHistory 起头的连续项目才压缩。continueNudge 与 controlPrompts 保持独立根集合，不能随历史一起压缩。
原快照自身的 collection/direct serializer 仍保留固定源 signature/reasoning 的真值与非 null 差异；它不用于删减已经生成的当前 wire 字段。
continueNudge 保留被位移 assistant 的集合归属，缺少逻辑 ID 也可作为独立尾部发送；不以物理 node ID 补造逻辑 ID。普通空文本继续过滤，role=tool 的空结果保留；当前 MI 的非空 reasoning/reasoning_content/signature 也是实际载荷，不按空正文过滤。

## 条件与 raw 隔离

conditional_tag 只检查并删除本次输入的 content（含嵌套内容）。未命中直接返回本次输入；命中后，用已去标签的当前消息执行分组和 postscript，因此脚本看不到旧标签或上一轮内容。
Helper raw 的完整 chatHistory 集合由本次 raw 装配提供，包含属于该集合的 header/depth 成员；不能只用 provenance 的 history 标签猜成员。首次 raw、空旧快照、换预设、取消后的新请求、reset 或换 host 后的纯 raw 都不因旧 PromptManager 缺失失败。
raw 合并相邻 system 时保留首条真实 piece ID 与原来源属性，因此 history 成员不会因合并生成新 ID 而漏分；不把相邻但未合并的字面消息吞入历史。

固定源的 continuation 缺 ID 与数组图片 marker 重读仍作为历史观察留档；本轮按 ADD14 分别修成独立 continuation 尾部和当前图片 parts。显式需要页面 JS 的 Final/Entry/Output/ChatSquash 脚本及工具仍受宿主、取消和页面身份检查，不因 raw 隔离而假成功。

## partial / dryRun 的资格边界

ST prepare 在 try 内出错会 catch 后继续 finally setter、getChat/READY；本引擎保留既有失败返回方式，finally 捕获实际已加入 root 的部分 accumulator，不回退上一成功请求，也不补入仅 reserve 的 header/control。失败后的另一条 raw 不读取这份部分内容。
覆盖的是本引擎准入模型的实际 accumulator。它不把全部 ST 异常吞吐、token 实现、V3 装饰器和失败副作用时序宣称为逐步相同。
ST setter 保存同一对象，live system squash 在 await 计数前已 flatten/修改首条内容；计数拒绝时可能留下中间对象。当前快照独立、无额外计数，未模拟这个异步失败残留状态。源控制探针已记录，不能用成功快照验收该异常路径。
ST UI tryGenerate/render 的 dryRun 也可更新 manager；无 activeCharacter 的 dryRun 在创建 ChatCompletion 前退出。App 没有对应的全局 PromptManager UI，本增量不把 detached authoring preview 偷换成 setter，未模拟这类 UI 更新来源。

## 页面 reset 协议

可选 TavernSPresetPageLifecycle 见 SPRESET-HOST.md。可信 App 在 pageLost/document 替换时同步调用 resetSPresetPage(chatId)，再开始新文档工作。关闭 script context 不能作为 reload 信号；hostVersion 也不覆盖同 host 的 reload。
本代局部快照先保存；若 page epoch、hostVersion 或取消状态已过期，跳过共享发布。快照观察本身不抛错、不终止纯 Dart 准备；真正异步 JS 的晚结果仍拒绝采用，已提交效果不撤销，不增加 timeout。PR1771 的 App 已接入 reset 信号，仍没有本轮 Flutter/WebView 真机结果；引擎的显式 reset 测试不构成 WebView reload 验收。

## 验证入口

- test/w11_helper_history_test.dart：公开 Helper/native API、真实 SQLite、生产 HTTP 编解码；仅 HTTP 对端/宿主脚本执行用可控边界。
- test/w11_batch2_r2_prompt_test.dart：真实 MI 一对多、DeepSeek 当前字段、空 tool、图片、已合并来源、条件 postscript 与 continuation 尾部。
- test/w11_prompt_manager_snapshot_test.dart：真实 assembler partial/counter 宏调用轨迹、immutable source 与 mutable wire、源拓扑向量。
- 交付外层保留固定源 setter-source-probe、continuation-source-probe、image-marker-source-probe 和原六组 separate-history-topology-probe；仅相应 I/O/token/宏或 squash 文本变换为明确替身，不当完整源引擎或 App 实跑。
- 旧固定源探针继续说明上游观察；ADD14 修正后的线格式期望由新回归单独证明，不改写原来源实验。
