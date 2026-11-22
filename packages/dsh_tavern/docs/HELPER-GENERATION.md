# Helper 生成桥协议与 App 接线边界（W11）

状态：引擎候选已实现；执行资格以冻结包验证记录和独立复核为准。本文不代表 Flutter、WebView、外部模型或用户完整脚本已经验收。
固定来源：[Helper 4.12.2 / 29331c36](https://github.com/N0VI028/JS-Slash-Runner/tree/29331c36fb9b2e880d4d488ff919317e1bc95684)、[ST 1.19.0 / 7e8663cd](https://github.com/SillyTavern/SillyTavern/tree/7e8663cd9c184a550b37238218bdd32c6efc68e9)、[SPreset / 53bd585d](https://github.com/starowo/starowo.github.io/blob/53bd585da14248ba10baaede7fc7ed0cebe1eeeb/regex_bind/inject.js)。
来源清单记录 URL、Git blob、SHA256、抓取时间和许可。Helper 根许可为 PolyForm Noncommercial 1.0.0；候选独立实现可观察协议，不复制其 TS 函数正文到产品。测试只加入小型合成输入及预期结果。

## 1. 请求入口与捕获

App 等待 `GENERATION_REQUESTED` 实际监听器完成，用最终 config 建立 `TavernHelperGenerateRequest.fromJson` 或 `TavernHelperRawRequest.fromJson`，分别调用现有 `bridge.generate(contextId, request)` / `bridge.generateRaw(contextId, request)`。
Helper 子类型标记必须经过捕获保留，不能先转换为普通 DTO。普通 `TavernScriptGenerateRequest` / `TavernScriptRawRequest` 沿既有契约，尤其 native raw 的字面量、无隐式预设和无隐式预算。
JSON 在入口深度捕获；之后修改原 config 不改变已受理请求。ID 取监听器最后修改后的值，不能提前用旧 ID 登记页面 Promise。

| JSON 字段 | 实际消费 |
| --- | --- |
| `generation_id` | 非空值原样使用；省略/空值生成 ID。活跃重复 ID 拒绝；旧 Helper 已取消但载体尚未排空时可复用，收尾按 record 身份核对。 |
| `user_input` | 默认空串；一次基础宏→prompt USER regex，跳过 writeBack；空结果用当前 `send_if_empty.trim()`。 |
| `should_stream` | 默认 false；控制本请求 wire 和 Helper 进度，不借预设默认值。 |
| `should_silence` | 默认 false；控制共享 Helper 状态与主按钮占用，仍可被全局 Helper stop 停止。 |
| `should_return_reasoning` | 默认 false；只改返回形状，不关模型推理或思考事件。 |
| `max_chat_history` | all/有限数值；真实历史先按完整历史深度跑 regex，再按 JS slice 整数端点取尾。覆盖历史不受此上限裁剪。 |
| `preset_name` | normal 按真实名称取，重复名报歧义；转 raw 的 order/inject/六采样，不切全局预设、regex 或 SP 配置。固定 raw 未读取该选项，保留并诊断。 |
| `ordered_prompts` | 仅 raw，缺省为源码九项顺序；role/content 对象为字面量。chat_history/user_input/dialogue_examples 三控制槽不区分大小写，其余内建项精确匹配；未知字符串按源忽略。 |
| `overrides` | snake_case 八项；chat_history 有 with_depth_entries/author_note/prompts。覆盖 prompts 不跑存储历史 regex；空覆盖过滤历史及相关 depth/note。 |
| `injects` | normal 消费 role/content、in_chat/none、depth、should_scan、filter；函数先注册当前 context callback ref。raw 未读取 position/filter/should_scan，不擅自执行。 |
| `image` | URL/data URI 字符串或数组；File 先由 App 编码。发送取决于下表固定源路径：normal 单图/历史图不发送；raw literal 的 image 源未消费，桥给诊断。 |
| `custom_api` | proxy_preset/apiurl/key/model/source、六采样三态、custom_include_body/custom_exclude_body/custom_include_headers。 |
| `tools/tool_choice/json_schema` | 支持协议族的函数工具、auto/required/none/any/指定函数、name/value/description?/strict?；返回调用信息，不执行 action。 |

`automatic_trigger` 及源逐字段投影未读取的额外 JSON 被捕获、保留、忽略；不因其存在报错，不发明自动触发行为。top-level、overrides/chat_history、custom_api 不套 native 严格允许列表。
类型、数据 URI、能力缺失、名称歧义会结构化失败；不能变为空字符串成功。

## 2. raw、命名转换、预算与图片

raw 用当前预设采样和预算。缺 input 槽时按源合入有效 history 或追加尾部；literal 不展开宏。命名 normal 转换后按实际 raw 请求分类。
命名条目按启用 order 取出、depth/order 排序；准备宏按源顺序执行，六采样覆盖 custom_api 同字段并按源范围截断，当前 regex/SP 上下文保持。
预算先预留纯文本用户消息与 new_chat_prompt。历史每条 canAfford 看同一余额，最后集合整体收费；首条不够即停止，不能跳过取更新消息或改成渐进裁剪。图片最终按实际消息计价，不在外层重复预留图成本。图像 token 受当前计数器能力限制，不是外部供应商精确计费证明。
App File 必须先变规范 data URI，不能直接 JSON.stringify。URL 需真实可选 `TavernHelperImageHost.resolveHelperImage`；返回后校验 image MIME/非空字节。实际下载/base64 失败由宿主明确抛 `TavernHelperImageConversionFailure`，形成可见 issue 并按源跳过；取消、页面/宿主更替、能力/协议错误仍失败，未接此失败类型也保留旧失败行为。
数组保留位次；raw 无 input 槽且无有效 history 槽时，源不会附单图。本实现保留该差异，不补发源未发送的图。
固定 Helper normal 单图写 userMessageTemp.image，ST 1.19 populateChatHistory 只读 media；本候选不迁移该旧字段，也不额外发送。

| 图片路径 | 当前源对齐的消费条件 |
| --- | --- |
| normal 顶层单图 | WI 后、PromptManager 前解析 URL/data URI，随后不附图。 |
| normal 覆盖历史 image | 不解析、不发送。 |
| raw 显式 user_input 单图 | system/示例集合 admission、纯文本用户预留后解析并附图，不套历史媒体门禁。 |
| raw 缺 input 槽的顶层单图 | 有未过滤 history 才解析；解析先于门禁，门禁真才附图。 |
| raw 覆盖历史 image | 有未过滤 history 且门禁真才解析并附图。 |
| 顶层数组 | raw 非空数组在 WI/集合预算前解析，有 input/history 才保留；normal 先放 literal marker 参与 WI/预算/共享 manager，实际 READY 逆扫最后 user/string marker 命中才解析并改 wire。数组不套单图历史门禁。 |

历史媒体门禁读取 custom_api 覆盖前主连接与捕获主预设 media_inlining；不能用本次请求模型代替。chat-completion 主环境下，custom 直接允许，OpenAI/DeepSeek 按固定 ST 模型模式判断（保留 OpenAI 原 some 排除式）。
OpenRouter 必须由可选 `TavernHelperImageCapabilityHost.supportsHelperModelImages(request, cancellation)` 返回真实 model_list 能力。request 含 generationId/contextId/chatId/主 source/model；owner 按页面取目录对应项的 architecture.input_modalities。未加载或无此项的真实目录结果为 false；没有能力接口时，被消费的历史图分支明确 unsupportedCapability。关闭 media_inlining 或仅 raw input/数组路径不要求目录能力。
normal 数组缺 marker 给 `helperImageMarkerMissing` 后继续正文、零解析；命中后只改该条消息，所有图片失败时仍保留 text-part 数组。并行数组转换保留成功项原序。阶段/错误映射与 App 契约见 [HELPER-IMAGE-PHASES.md](HELPER-IMAGE-PHASES.md)。ST 图片压缩、尺寸、精确 token 与完整页面事件并发没有在此复现，背景宏写意图仍按原成功准备后提交；不据本次阶段修复宣称完整图像等价。

## 3. 每请求 custom_api 与 provider

URL/key/model/header 每请求冻结，不改全局连接或落盘密钥。apiurl 去空白/尾斜线后构造 /chat/completions；显式 DeepSeek 代理路径不套 native beta。
`TavernHelperProxyHost.resolveHelperProxy` 按 trim 后真实名称取代理；无能力明确失败，真实查无名称给诊断后沿显式配置/当前连接，不制造记录。

| 项目 | 行为 |
| --- | --- |
| number/same_as_preset/unset | 数字覆盖、保留已组装值、删除；源用于删除的默认数字也删除。 |
| custom_include_body | 仅 custom；浅层 Object.assign；之后非空实际 stop/tools（含自动供给）及其 tool_choice 优先覆盖 include，同字段实际为空才保留 include。 |
| custom_exclude_body | 最后按顶层字面 key 删除，点号不是路径；Final 之后可显式再改。 |
| custom_include_headers | 仅 custom；显式 Authorization 优先本次 bearer，不污染下一请求。 |
| source 缺省 | 显式 apiurl 存在时 openai，否则当前连接。 |
| 支持 source | openai/custom/deepseek/openrouter 的实际兼容 wire；当前 OpenRouter 可直接复用。 |
| 未实现的 source | 无真实协议适配器时 unsupportedCapability；存 source 名称不代表 Claude/Google/Azure 传输支持。 |
| 无 URL 切源 | 当前配置不能提供对应连接时可见失败，不猜供应商地址。 |

SP provider 对象取 custom 覆盖前页面主配置；normal MessageInjections 也如此。真实 source/model 仍管传输、推理和规范化；Final 顶层 source/model 取实际请求，provider 对象保留页面上下文，不重定向请求。

## 4. 返回、工具、响应帧能力

成功结果保留 native id/origin/usage/finishReason。App 用 `result.toHelperValue()` 取字符串或详情：

```json
{"content":"正文","reasoning":"实际非空思考","reasoning_signature":"可选签名","tool_calls":[{"id":"call-1","type":"function","function":{"name":"tool","arguments":"{}"},"thought_signature":"可选签名"}]}
```

should_return_reasoning=true 或实际非空 tool_calls 才返回详情；空元数据不补字段。自动 ToolManager/SP 供给不改变 effective explicit tools 判定：无显式工具时不因此提取工具、强制详情或执行 action。
显式非空 tools 替换自动供给，空数组沿自动供给。DeepSeek 工具/schema 按 wire 转换。Helper 工具递归合并、字符串拼接、null 覆盖，独立于核心 replay 证明。
OpenRouter 流式思考签名取最后，非流式取首个；工具签名沿源优先级，不用 Helper 元数据替代核心 collector 原证据。

生产 `ModelRequestContext` 的可选能力：

| 能力 | 时点与保证 |
| --- | --- |
| projectResponseText(streaming, detachedFrame) | 同步、在任何 text/reasoning delta 前选择 Helper provider 提取；返回 (text, reasoning)。不能改 collector/usage/tools 原 map；native/quiet 省略后沿旧逻辑。 |
| onResponseFrame(attempt, streaming, detachedFrame) | 同一生产解码器实际完整帧全部 delta 后、下一帧前；非流式完整 parsed response、Finished 前。同步返回 null，只有真实 Future 才 await。 |

没有第二套 SSE parser，不另缓冲整个原 HTTP body。注释、DONE、未完成 EOF 记录不作为帧；onResponseStarted/onResponseBytes 原日志观察不改。
owned 投影/帧回调错误保留原对象/stack，不变成网络/JSON 错误，不重试已接受响应。观察型回调仍隔离。
OpenRouter/custom/DeepSeek/openai 的字段优先级和空串分别处理；非流式 choice.text/top text 回退可消费。数组/对象正文超出现有字符串 DTO 时明确 unsupportedCapability，不 flatten 假等价。
自定义 ModelClient.generate 若未提供这些能力，仅有其实际 delta/snapshot：不能恢复丢失的原签名/工具结构，也没有中间完整帧，Helper 进度只能最终发送。能力声明不能代替运行接线。
生产传输仍要求可解码协议记录；不声称复现源对全部畸形 JSON、无结束标记和任意异构响应的宽容策略。

## 5. 流式清理、事件与副作用

流式 result.text/toHelperValue 是 raw accumulation；ENDED 的 message 为独立清理结果。BEFORE_END 不 await、不回读 payload 修改。
streaming_fps 缺省 30；过早帧直接跳过进度，不睡眠。无效/非有限/≤0 interval 按 1 ms；上次时钟在清理完成后记录，最终补剩余 addition。

1. 清理未报告 addition，非最终片按源平衡未闭合 Markdown。
2. 发送全文、增量、全文思考、增量思考四事件，包括空字段。
3. 最终进度之后再清理完整 raw，保存 endedText。
4. BEFORE_END、ENDED；返回仍 raw。

固定 Helper 五位置参数 cleanUpMessage 使 includeUserPromptBias/trimNames/trimWrongNames 为 undefined，这里不启用其默认 true。每次非空清理重读停止宏，不缓存副作用；空串早退。
每次读当前变量/观察版本，冻结本次 settings/card/preset。写入沿 effect scope/receipt；取消前未进入的不执行，真实 rename/提交已发生则保留 committed。取消和 engine.close 等实际载体排空，outputPending 在 finally 结算。
异步清理只给 Helper；native/quiet 无新增输出 await。

## 6. SPreset 实际钩子

详细来源见同批 HELPER-SPRESET-HOOK-MATRIX-W11.md。

| 模块 | normal/in_use | raw 与命名 normal 转换 |
| --- | --- | --- |
| MessageInjections/结构占位/MacroNest | 进入对应 promptManager 钩子 | 不进入；基础宏仍执行 |
| Entry fresh evaluate | 不发生 | 不发生 |
| 活动 Entry Map→prompt order | 读仍活动原生 Map，null 沿默认 | 不改 raw order |
| 活动 Entry Map→自动工具 | 读取 | 同样读取当前页面预设活跃集合 |
| ChatSquash/Forced/Final | 共同事件/fetch路径 | 同样进入，mixed array 无转换路径可交 Final |
| Output 正文 processor | 私有 Helper 不进入 ST 全局钩子 | 同左 |
| Output consumeToolCalls | 只有非流式 fetch 可消费 | 同左，流式透传 |

非流消费先验证脚本，按 choice 通道格式化原始调用签名；成功追加并删 calls，任一 formatter 失败完整回退；不运行正文 processor。native response 保持既有行为。
Entry 是按 chat 画布分区的当前活动状态，不是上轮缓存；Helper 私有 ended 不清，成功 global STOP 清，原生结束/host replacement 清，取消旧求值不复活。命名按转换后 raw 分类。
宿主原样透传可选 sessionScope；公开 generationId 不是宿主会话所有权键。同 ID 旧 release 不得删新 state，沿现 evaluate/release/取消协议，不另造 nonce。
normal/native/quiet 在真实准入 finally 保留本代 PromptManager 拓扑，身份有效才发布共享状态。按 ADD14，separate 把拓扑应用于本次当前 segments，保留 MI 一对多及图片；postscript 看到的是已经去掉本次条件标签的内容。Helper raw 与命名 raw 使用自身集合，不重读旧共享内容；首次 raw 不因缺少旧快照失败。continueNudge 即使 flatten 后缺逻辑 ID 也保留独立尾部，空 tool 结果保留。固定上游同类缺陷与本轮有意修正见 HELPER-PROMPT-MANAGER.md。
可选 TavernSPresetPageLifecycle.resetSPresetPage(chatId) 由可信 App 同步调用，清本 chat 的 Entry/集合并递增 epoch；旧 JS 求值不采用晚结果，过期快照观察仅跳过共享发布。PR1771 已接此信号，本轮仍无同 host reload 的 Flutter/WebView 真机验收。
native SP Entry/early sync 已在普通 START 处理器之前；仍不声称复现任意外部 makeFirst 监听器重排。ST UI dryRun setter、全部失败副作用顺序及 system squash 计数拒绝后的中间对象状态不在完整对齐范围。

## 7. 停止、同步 JS 返回与按钮

可选 TavernHelperGenerationControl 属共享 coordinator，只管 Helper，跨其页面/context/chat，含静默，排除 native/quiet；缺能力明确 unsupported。

| 页面行为 | 桥方法/状态 |
| --- | --- |
| stopGenerationById(id) | stopHelperGenerationById(id)，只 Helper、未找到 false；true 表示实际受理，载体可能仍排空。 |
| stopAllGeneration() | stopAllHelperGenerations()，全部 Helper，空集合 true。 |
| 主 #mes_stop | 停当前普通生成，再 stopNonSilentHelperGenerations；静默 Helper 继续。 |
| 发送/停止按钮 | helperGenerationState.blocksMainGeneration 与 watchHelperGenerations 快照/更新。 |

上游 JS stop 返回同步 boolean，Dart 为 Future，App 不能把 Promise 当 boolean。可用共享镜像做同步受理/占用，但桥 ack 失败必须可见；跨页镜像与终态可竞态，不能永远成功。
页面 generating map 只跟踪 Promise，不是全局停止权限来源。重复活跃 ID 先拒绝再登记；finally 按对象身份清理。已取消旧请求未终态时新同 ID 可受理，旧收尾不得释放新按钮或 registry。

## 8. App owner 与验证边界

App 负责请求事件等待、callback 注册、File 编码、真实 proxy/image/catalog host、generationId/sessionScope 透传、停止镜像、按钮、事件映射和错误呈现。内部 lifecycle 的私有 START/BEFORE_END/ENDED 以 iframe namespace 映射 js_generation_*；私有 ENDED 不是 ST global END。STOP 是例外：namespace=tavern、GENERATION_STOPPED 映射全局 generation_stopped，参数为真实 ID，不存在 js_generation_stopped。
ADDENDUM-01 的 SP host 已接属于 owner 报告；ADDENDUM-02 #20 说明 App 取消立即以 error/unknown 结算，不等待页面函数返回，不能据此证明 JS 后续副作用已停止。本候选不改 App，也不据此签 Helper File/按钮/页面已完成。
日志区分源函数探针、Dart、真实 engine/SQLite/文件、生产 HTTP 编解码及合成 peer。Flutter/widget/真机、外部供应商、完整社区生态需各自证据。
