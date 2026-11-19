# dsh_tavern：预设执行与协议边界

本包以 SillyTavern 1.19.0 固定提交 `7e8663cd9c184a550b37238218bdd32c6efc68e9` 为兼容基准。预设的 `raw` / `encode()` 保留原始 JSON 值和未知字段；执行时按具体读取位置转换，不对整个预设做统一强转。

## T19a：宽容读取预设

| 读取位置 | 行为 | 固定 ST 依据 |
| --- | --- | --- |
| 上下文、最大回复的预算计算 | JavaScript Number 语义，然后进入现有整数 token 预算；无效或非有限值用字段默认值 | openai.js setTokenBudget 用 context - response |
| temperature、top_p、presence_penalty、frequency_penalty 请求值 | Number 转换；非有限结果按 JSON.stringify 语义发 null，不改成默认采样值 | openai.js 2803–2810 |
| max_tokens 请求值 | 保留原类型与值；缺失时用默认。数字字符串可参与预算计算，请求仍是字符串 | 前端 2811、后端 1130 直接转发 |
| enabled、continue_prefill、squash_system_messages、stream_openai、show_thoughts | 按 JavaScript 真值读取；非空字符串 false 也是真 | PromptManager 的 entry.enabled &&、openai 直接条件 / Boolean |
| names_behavior、injection_position、injection_depth、system_prompt、forbid_overrides | 保留严格比较；字符串 1 不自动变成数值 1 | openai 的 enum / depth 比较和 forbid_overrides !== true |
| 提示词正文 | 先按真值判空，再 String 转换；false/0/null 为空，true 变文字，数组用逗号连接，对象为 [object Object] | script.js substituteParams 2981–2987 |
| DeepSeek reasoning_effort | auto 不发，min/low → low，max → max，其余包括非字符串值 → high；仅思考开启时发 | openai.js getReasoningEffort 2570–2582 |

预算不能使用 NaN 或 Infinity，有限值回退是本包的明确容错政策，不代表 ST 也回退到 4095/300。请求采样有独立的 Number → JSON null 路径，不能拿预算回退替代。现有预算是整数，有限小数仍沿用整数化；不宣称复刻任意非法预设的浮点预算或 DOM 控件行为。

角色在内部不再触发 String 强转错误：按 ST Message 的规则，假值在生成消息时回退 system；其余原值保留。未知角色仍可能被模型端拒绝，不等于已被验证合法；完整导入校验属于 T20。

continue_postfix 对齐主脚本运行态字符串拼接，cyclePrompt 和 continue_mag 使用同一值。包内既有接口允许任意字符串；ST 的 setContinuePostfixControls 有四选项控件修正，预设切换又会写回原值。本包不模拟整套 DOM 装载流程。开启 continue_prefill 时，发出的前缀仍是原消息；后缀用于本地累计，不为了后缀改写此前已确认的预填充语义。

历史仍从新到旧展开宏、计算用量和选择预算内片段；片段引用先追加，最后一次按时间顺序形成 chatHistory，避免每条历史头插导致的重复搬移。newChat 在前，emptyUser 补位仍在历史后，groupNudge 与 continuation 保持原位置；不重新展开宏或提前过滤可选段。该收集环节使用额外 O(K) 引用列表，保留同一 PromptSegment 对象，不声称内存减少或整个组装/回合端到端线性。依据是代码中的操作次数及[固定 Dart 3.13.5 growable list 实现](https://github.com/dart-lang/sdk/blob/3.13.5/sdk/lib/_internal/vm/lib/growable_array.dart)，不是 Dart/设备测速；旧、新产品的顺序与副作用回归都应通过，不设耗时阈值。

## T19b：100001 组的选择

ST 使用 global 策略、dummyId 100001，比较 String(character_id)。缺少该组时 sanitize 追加默认 12 项，随后选用它；不回退第一组，也不使用定义自己的 enabled 代替顺序。

第一份匹配的组已经存在，但 order 为 []、null 或缺失时，ST 虽追加默认组，后续 find 仍先命中原来的空组；重复的后组也不覆盖它。本包保留这一结果。空顺序不等于禁止所有独立系统、世界书或控制注入。

ST 对非数组 order 或非对象条目可能抛 TypeError。本包将无法执行的容器视为空顺序、过滤非对象条目，这是明确的畸形输入容错；原 JSON 仍无损保留。规范视图同时供 assembler 和 engine 世界书 section 判断读取。

## T19h：DeepSeek 的 seed

**原生 DeepSeek 请求继续不发 seed；本项只修正说明，不改变这个发送行为。** 固定 ST 前端 seedSupportedSources 不含 DeepSeek；只有来源在列表且 settings.seed >= 0 时才附加 seed。后端虽转发 request.body.seed，正常前端未提供时它是 undefined，JSON.stringify 会省略。

因此，后端支持转发不代表正常 DeepSeek 回合会发送。设计稿 roleplay-compat.md 的 DeepSeek 段中发送 seed 的说法按这里的固定源码证据修正；设计文件不在本次允许修改的 package 范围内，本补丁不编辑它。

通用非 DeepSeek 路径保留已有 seed 功能：按 JavaScript 数值比较判断，再转发原值。字符串 Infinity 比较时为正无穷，发送的仍是原字符串；这不保证提供方接受它。

## 固定来源与验证

- [PromptManager.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/PromptManager.js)，blob 20219dc45ffa232ef61ebbfac0836241f168a55a。
- [openai.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/openai.js)，blob bab82eec57e0927b809b0571534e96f1b13360e1。
- [chat-completions.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/src/endpoints/backends/chat-completions.js)，blob 0d98c77f7b64502c5b0f504eaa1f67df0f26041e。
- [script.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/script.js)，blob 777a2d5983a6283ef9b26726e75192da1e3f3cea。

已执行固定源码方法和请求对象片段的原生 V8 探针；它不是 Dart 测试，也不是完整 ST 浏览器或真实提供方对拍。新增 test/t19_preset_protocol_test.dart 覆盖对应 Dart 行为；实际 formatter / analyzer / 测试结果以 owner 代跑回件为准。

# T20：预设库、选择与增强预填充

## 管理接口

Tavern 提供 listPresets/watchPresets/preset、importPreset、updatePreset、updatePresetPrompt、setPresetOrder、setPresetPromptEnabled、exportPreset、presetSelection、setDefaultPreset、bindPreset、deletePreset。导入传原始 JSON String 与可选文件名；它只保存，不自动选为默认，也不修改配置的模型地址或密钥。返回详情与逐项诊断（severity/code/path/identifier/message）。异常 TavernPresetImportError 带完整错误列表。

sourceText 是不可编辑的导入原文，保留 BOM、空白和换行；raw 是当前完整 ST JSON；envelope 保存可选分享包。已知字段的正规化会指出具体路径，未知字段保留。后续编辑不重写原文。摘要列表只读元数据；详情才取原文和全部 JSON。更新对象递归合并、数组/标量替换，调用时复制输入，队列内取最新记录再合并。

新导入校验唯一非空字符串 identifier、system/user/assistant role、0/1 注入位置和非负整数深度。缺角色、model别名、大小写和可归一化的整数形式会记录诊断；非法值拒绝，不自动改标识符。旧 main_prompt 等无prompts格式仍可导入。首个100001组及空组保持T19语义。单提示词编辑的identifier稳定；顺序助手保留现有entry未知字段和开关，其他组不动。

## 格式与无损范围

识别的增强格式为 [dsh-preset-enhance](https://github.com/bychv/dsh-preset-enhance/blob/a7717ddc76f3985cf6a71ac6ee463911886b15a5/PRESET_FORMAT.md) v1（MIT）。只按确切format识别；该格式的未知主版本拒绝，不悄悄当ST。其他原生ST未知format/version/preset字段仍保留。外层metadata、preset包装、prefill、tools和extensions均保留；保存不代表执行工具、DSML、动态模板或附件。

ST原生导出在extensions.dshgo.presetEnvelope存去掉preset.data的外壳，从当前raw重建data，避免多次往返递归增长。当前独立envelope是外壳权威；其旧prefill开关不在重导入时覆盖已经编辑的dshgo配置。presetEnvelope是导出保留载体，updatePreset及从已有外壳派生的旧map桥接拒绝改变它；结构相同的完整raw回写允许。旧setPreset完整替换且无独立外壳时仍能原样导出旧未知值。

导出不重新套新导入正规化，旧宽容helper接受的role/正文等值不会在出口静默改变。修改库名称会同步现有分享包metadata.name；原生ST名称由调用方导出文件名承载。连接字段也保留，但实际endpoint/model/key只由configure控制。

## 选择、聊天覆盖与旧入口

优先级为有效chat binding、显式chat inline、有效library default、global inline、ST默认。缺失旧ID保留且由presetSelection列出missingPresetIds；新bind/default先验证存在。bindPreset(chat,null)清该chat的已知inline并恢复继承；setSettings({'preset':null},chatId:chat)仍保留旧语义，执行该聊天自己的ST默认。

每聊天采样可写setSettings({'presetOverrides': {...}},chatId:chat)，六个可执行键为temperature、top_p、presence_penalty、frequency_penalty、openai_max_tokens、openai_max_context。覆盖在完整选择后应用，不修改库raw；其他键保留在settings而不进入预设。

旧setPreset是整份替换；旧setSettings里的preset对象只在本scope递归合并。chat不能拿继承的global预设作合并基底。有明确库选择时从它派生新记录并选用，保留原记录、完整外壳和库名称；原inline也同步保留。因此删除库记录与清绑定后，已有inline仍是合法回退，不承诺删掉这个独立配置。完全通过新import/bind/default选用、无inline的记录删除后回默认继承。

原生库和chat混合编辑均用SQL事务。旧global混合入口先写settings.json再改SQL选择，不能跨资源原子；期间新回合busy，已有回合保留快照。SQL第二步失败时新文件内容已提交、旧default仍在，新记录回滚，错误上抛，重开读同一事实。文件第一步失败则不碰SQL，但沿用旧API已更新内存的失败行为；不宣称内存和磁盘一起回滚。编辑库记录、换default只影响后续回合；按聊天选择及删除会取消并等待受影响回合。删除也追踪当前回合先前捕获的ID，覆盖default已经换走的情形。

### 设置文件的启动读取

`openDirectory` 直接读取 `settings.json`；只有明确的 `PathNotFoundException`、错误码为2（Windows另允许3），且随后跟随链接的实体查询仍为 `notFound`，才使用首次启动的空设置和全局变量。启动不提前创建该设置文件。访问失败、其他读取错误，以及缺失样错误后仍可识别的文件或socket均失败；不把已经提交的配置误当空文档，让之后一次正常保存覆盖它。目标实际为目录时也失败，收紧了旧版 `exists=false` 会误当空设置的行为。

JSON解码和版本校验保持在读取异常分支之外；有效文档的未知字段、null、数组与字符串中的BOM按原语义保留。读取失败仍沿用工厂的根目录所有权释放路径，恢复访问后可公开重开。这里不改变上面的旧写失败内存行为，也不增加文件与SQL的跨资源事务。

## 预填充通道与边界

增强设置为extensions.dshgo.prefill的enabled和target。只有enabled为true才解释额外assistant_prefill，或采用明确的末尾预设assistant片段；enabled仅控制增强路径，ST原生正文前缀继续按既有规则。所有来源缺target默认content，以题面为准；增强参考实现自身的隐式reasoning默认不搬入。明确reasoning且当前回合开思考时，新前缀进入最后assistant的reasoning_content，content为空，prefix=true；关闭思考则原文留在content。

正文模式保留原文字节；思维模式只对选中的新片段处理参考实现的leading think/thinking包装，不扫描历史。新思维片段与历史assistant/CCV3正文前缀保持独立边界，不把合并后的历史整条搬进思维。API形状依DeepSeek官方 [Chat Completion](https://api-docs.deepseek.com/api/create-chat-completion/) 与 [前缀续写](https://api-docs.deepseek.com/guides/chat_prefix_completion/)，具体服务端兼容性未以真实付费模型调用测试。

continue回合跳过新增增强预填充并记录exclusion，保留原continuePrefill和postfix语义，不执行被跳过模板的宏。generic连接不假定支持reasoning_content；保留content并给unsupported诊断。非预设尾片段、尾system和空模板不强行移动为前缀。宏只展开一次，预算预留原始新片段，思维输入也计入trace和估算，不按空content记零；这是token估算，不能冒充提供方收费数。

按ADDENDUM-04，增强预填充模式、continue_prefill续写和声明CCV3前缀时，从预算开始就移除新tools/tool_choice。增强模式即使最终空或尾system未形成prefix也不挂工具，明确记录排除；避免为实际不发送的工具预留预算而误报超限。历史tool_call/result配对保留，不执行DSML工具转换。完成输出仍只由模型增量形成，不把请求前缀冒充模型输出落盘。

公开 `PromptAssembler` 的 `role: tool` 历史消息即使 `content` 为空也作为结构消息保留，沿原路径计数与预算裁剪；不因正文为空而删除工具结果。这里不校验 id 或调用/结果配对，不新增成对预算算法；其它角色的空消息仍沿原 `tool_calls` 例外与筛选规则。这是装配器输入合同，不改变主 `Engine` 的四种历史角色或 T17 不回放工具消息的边界。

T20的结构化导入诊断供后续T22体检接入；T22统一持久体检接口尚不属于本层。真实v2逐级迁移、失败回滚、原文/未知字段、选择和前缀均有专项测试；冻结交付说明另列实际运行结果，不能把源码探针或静态阅读当作Dart通过。

外层分享包与内部 `presetEnvelope` 同时存在时，去除外层 `preset.data` 后的外壳必须结构相同（JSON 对象键顺序不影响判断）；不同则以 `conflicting-envelope-carrier` 报出内部载体路径，避免导出覆盖另一份未知数据。内部载体自身含 `preset.data` 也拒绝；它是去掉数据后的分享包元信息，不能递归嵌套预设。


# T21：显示正则与资料库

`displayText(chatId, nodeId:, text:, role:, speaker:, depth:, reasoning:)`返回临时文本、逐规则warnings、replacements和superseded。传nodeId读存储原文，同时传text则使用最新完整流式原文；每次从原文计算，不能叠用上次显示结果。相同chat/node/reasoning最多一个执行中和一个最新待执行版本，App忽略superseded结果。无node时正文/思维各有一个live通道。

只做正则，不渲染Markdown/HTML。变量、历史、hash与随机源均为独立显示副本，不改变真实回合、正文、reasoning、检视或导出。按固定ST messageFormatting，隐藏消息仍做显示正则，但不计自动depth；真正is_system且名字为SillyTavern System才跳过。raw无自动depth，raw system缺speaker时用系统名；自定义旁白请传speaker给trim宏。

正则数值字段的合法无符号 `0x`／`0b`／`0o` 字符串先按任意精度整数解析，再转为 double，避免正数超出有符号 int 范围后变成 NaN、绕过 minDepth。原语法门仍拒绝带符号的进制文本、裸前缀和非法数字；缺失／null 深度仍为 null，空串仍为 0，十进制等其它分流不变。此类合法进制文本即使原来在 int 范围内，也统一以 double 进入执行视图；数组字符串化后若得到同类文本，也共享该转换。原始 JSON、来源文本与导出不改写；writeBack 继续忽略 depth。这里不承诺其它数值转换全部与 JS 相同，也不增加任意长度输入的成本保证。

显示和WI正则使用两个独立常驻Isolate。默认每次200条实际规则，原始输入/模式512KiB UTF-8，最终及链间文本2MiB，累计替换20000次，单派发请求1.5秒；内部捕获描述预算2MiB，最多64个等待命令。超时返回跳过并请求immediate kill，旧onExit确认后才重生，epoch/id拒绝旧结果。实际退出和Timer受VM调度影响，期限不是整个API的硬完成时间。宏、纯文字匹配、替换构造仍在owner；prompt/writeBack保持旧同步路径。

失败只丢本条文本，保留前序成功文本和已发生的临时宏效果。捕获模板逐步限制增长；宏前上限为输出预算与原模板大小的较大值，允许长模板经宏收缩，宏后严格检查最终输出。WI的skipped为不可判定，按候选跳过，不可当false再经NOT/exclude反向命中。取消在受控await前后检查。原生未识别literal仍回退纯文字；已识别但编译失败跳过，是T21保护政策。

新卡、预设、世界书及正则导入会试编译静态输入，动态宏只标deferred并延到运行检查；原始JSON不因诊断被改写。script历史flags fallback、native和V3方言分开。卡/预设/世界书的regexDiagnostics仅为导入回执；全局库诊断随记录保存，统一持久体检属于T22。

全局库接口：listRegexScripts、importRegexScripts、updateRegexScript、setRegexEnabled、deleteRegex、exportRegex。单对象/数组均接收，内部ID独立于ST id；原文、未知字段、原开关及诊断保存。执行view跳过不兼容规则。顺序：旧inline global→管理库→preset→card；managedRegexScripts是设置合并后的只读投影，read→set不能重复或覆盖库。在途回合保留已捕获规则。

`await tavern.updateRegexScript(script.id, {'findRegex': r'/(A!)/g', 'replaceString': r'$1', 'trimStrings': ['!'], 'minDepth': null, 'maxDepth': null})` 原位编辑 ST raw，返回当前诊断和新报告。内部 ID、顺序、首次 sourceText/importedAt 不变；raw.id 可编辑。调用时捕获 patch 的 JSON 深拷贝，队列内读取最新 raw：对象递归合并，数组/标量替换，null 明确存储，省略及未知字段保留。省略 disabled 即保留原开关。成功 await 后才开始需要新规则的业务；旧消息和已捕获环境不追溯改写。分享当前编辑结果使用 exportRegex，sourceText 仍为首次导入原文。

更新复用导入检查及原文件发布点；静态不兼容 raw 可保存/导出，执行投影停用而不改 raw.disabled；动态模式只标 deferred，不在编辑时展开宏。空 patch 也刷新报告，setRegexEnabled 则保持旧报告及 stale 语义。缺失内部 ID 沿用 TavernImportError，检查或文件发布失败传播异常；正式文件发布前失败保留旧提交，后续队列仍可用。没有新增 schema、跨进程锁或断电事务承诺。

世界书接口：listLorebooks、importLorebook、lorebook、putLorebook、exportLorebook、deleteLorebook、bindLorebooks。可绑定global、characterId、chatId、personaId。删除保留绑定，下轮记missing并跳过；已捕获书的回合继续。

删除世界书时，路径查找的访问错误会返回失败，不提前清理书的内容、来源名或报告缓存。普通文件仍直接删除；查找无法确认缺失时只读探测该路径，不读取正文，明确缺失才按不存在处理。探测句柄关闭或随后删除失败也会返回；正常缺失及重复删除仍成功并完成原有缓存清理，已识别非文件路径保持原跳过行为。

filename去路径及.json后另存stWorldName，不能用raw.name显示标题代替来源；仅当raw缺name才以filename补显示名。raw与来源在同一个本地envelope原子发布，旧raw文件仍可读，公开读/导出只含原生raw。summary.stWorldName供导出命名，put保留来源。当前分支world_info对应的精确stLorebookIds映射优先，并统一同ID各scope的原生timer hash/key；无来源证据才回退本地ID。read/put/delete同队列，同时捕获raw与来源；不承诺跨多个资源事务。

世界书扫描文本、普通主关键词和次关键词在匹配前按固定 ST 的 JavaScript 空白集合裁剪首尾；U+0085 NEL 保留，NBSP 与 U+FEFF 仍按 JS 空白裁剪。普通关键词的静态正则体检使用同一裁剪规则，避免把 NEL 包围的字面串误诊为原生正则。关键词原值继续保存在卡片和匹配 trace 中；V3 正则原始模式与既有分流、全词边界规则保持。评分仍按原始键调用 matches，不新增 trim 或 expand，评分算法未另改；共享扫描文本的裁边，以及本累计层另接入的有限 lowercase，可能改变评分与普通匹配结果，不能由保留原始键推断结果恒定。

新测试登记207例：worker19、protected display115、WI34、façade/library33、来源身份6；已有113例WI及105例同步regex保留。登记数不是通过数，实际format/analyze/test和平台退出结果以owner回执为准。来源固定ST 1.19.0提交7e8663cd的public/script.js、regex、utils和world-info；未读JS-Slash-Runner。


# T22：持久化导入体检

四个新导入入口（importCard / importPreset / importLorebook / importRegexScripts）会保存结构化能力报告。App可在角色页或对应资料详情页常驻展示；本层只提供数据和接口，DeferredTavern / PreviewTavern转发由主线补。

| 接口 | 合同 |
|---|---|
| readImportReport(kind, assetId) | 读已保存报告；旧资料没有报告、或资源已不存在时为null。不会试编译、展开宏或执行脚本。 |
| recheckImport(kind, assetId) | 对当前资料显式重检并保存；缺失资源报错。复用T21受控编译，不执行用户宏或脚本。 |

kind为character / preset / lorebook / regex。报告包含version、checkedAt、counts、verdict、findings、renderLevel、fingerprint和stale。三个总评为usable（能用）、partial（部分能用）、preserveOnly（只保留不执行），描述已识别的能力，不保证动态内容在所有场景均会生效。用户关闭的条目、空合法书或未触发的关键词不是兼容错误。

每个finding单独带path、code、message、kind；可带identifier、原文行号及从零计的UTF-16 offset，conditional/fallback保留条件与后备路线。unsupported表示已知未实现，invalid表示该已知结构或模式无效，deferred表示需运行时上下文，unknown表示不解释的保留数据；条件性结果不冒充无条件失效。数量是声明及检查的数量，不能当作本次执行次数。原生书的存储条目、V3去重后的执行条目分别计数。

报告是checkedAt时的快照。fingerprint对已检查的JSON、独立预设外壳和嵌入资源路径作规范化哈希；对象键序不影响，数组顺序有意义。此值用于检测编辑，不是签名，也不判断未读取的资源内容。一般编辑保留旧报告；读取时根据当前检查输入的指纹是否与报告一致设置 stale。恢复为相同指纹时 stale 可回到 false，但 checkedAt、findings 等仍来自原快照；显式重检或 updateRegexScript 刷新该快照。后者包含当前规则检查，setRegexEnabled 仍不自动刷新。重检保留原文、当前raw、库名、选择和内容更新时间；不会趁机正规化宽容旧预设。引擎版本升级可能增加能力，旧报告仍是原检查时刻的记录，可显式刷新。

渲染级别仅是建议：0原生、1单消息WebView、2整页画布。2需要明确脚本、助手依赖或跨消息样式证据；说明里提到插件名称、普通HTML、CSS字符串或代码示例不足以判定。后端不启用任何WebView或脚本执行。静态未发现HTML不能证明运行时宏或正则结果不会生成HTML。

保存边界：卡的report文件在同一个staging目录里随整卡rename发布；预设nullable import_report_json在schema3的同笔INSERT保存；正则report跟随其资料记录；世界书report和原生来源名跟raw同一个本地外壳发布。报告读取与编辑/删除共用所属资源队列。读取角色报告只读card.json和资源清单，不加载原始卡、头像或所有资源字节。重检失败保留旧报告，删除随资料删除。

角色导入保存本次解码返回卡所持的 originalBytes，不在后续检查或发布的 await 之后重新采用调用者输入缓冲区的另一版本。公开 beforeSave 回调确认已解析 A 后，仅复用外层输入为 B，不应使返回原件为 A、重载原件却为 B。这是已完成解码的来源一致性，不是所有异步入口在调用瞬间复制输入的承诺，也不把可变 TavernCard 或回调主动修改卡的行为称为不可变。正常 JSON/PNG/CHARX 导出从当前工作卡重建，不宣称本问题会使工作卡或导出变成 B。

角色报告读取仍沿用旧_tidy清理残留，因此不承诺绝对零文件写。正则重检同时刷新T21的diagnostics，可能改变后续回合的兼容执行资格；原始数据及disabled不变。数组正则初报使用原$[i]，按单个ID重检使用当前单条的$；不是所有报告路径都对应保留的sourceText。

schema0/1/2通过原有逐级事务迁移到3，既有预设报告为null，不伪造“零问题”。旧裸世界书、T21带来源名的外壳、无报告的regex记录继续读取；无文件名的世界书可用新外壳保存report而不虚构stWorldName。导出不把内部报告混进卡、预设、正则或世界书原生JSON。

非法顶层输入继续按原入口拒绝，不生成不存在资源的“只保留”记录。低层CharacterLibrary/ChatStore及旧setPreset/setSettings宽容桥接可以产生无报告旧式记录；显式recheckImport为这些记录补报。新导入的regex数组逐记录保存报告，保留原数组位置。

中央检查把每处脚本、助手脚本或变量配置、无效正则、未实现的世界书特性、banned宏分别定位。未知供应商字段保持不解释；正常空返回宏、禁用条目和条件性装饰器不冒充引擎缺失。预设附件逐项定位，分享包的工具转换、正文提取、自定义工具后前缀分别提示。正则只使用T21已有受控试编译回执，不再执行第二次编译，动态输入仍为deferred。

HTML/CSS只是有限的静态正面检测：资源路径参与计数和fingerprint，资源字节不扫描；不展开实体、CSS转义、srcdoc、宏或正则动态输出，不下载远程内容。Markdown代码、HTML注释、JSON数据script和普通插件名称不作为脚本证据。0不构成动态输出无脚本的保证，2也不表示后端会执行脚本或改变用户开关。

新增110项登记用例：中央分类60、世界书27、存储及迁移8、四类入口集成15。包括旧库补报、编辑后stale、真正v2升级、SQL及文件发布失败、重开/导出隔离、静态检测正反例。110是运行前登记数；实际结果以正式交付回执为准。本层同时修正032指出的4项T21样式info（两处花括号、worker惰性空值赋值、fixture空值元素），不改变其判断或断言。

本层静态分类与持久化测试尚须owner运行。固定ST原文、Python SQLite辅助验证、词法检查和独立源码复核均不替代Dart formatter/analyzer/test结果。

# T23：流式持久化、历史与缓存

流式增量仍立即发事件，正文落盘改为约500ms的dirty检查点，不再每16个增量写入。schema4新增影子正文/reasoning；周期写入不改usage、检视、变量、original或FTS。终态以一个FULL事务保存最终正文、usage、状态与检视，并更新FTS；NORMAL仅用于正文检查点，其他聊天普通写入仍用FULL。重开推广未完成检查点，清除不再对应这份正文的旧usage/检视，不伪造完成状态。

历史改为共用递归CTE，任意叶的完整history不受path默认60条限制；父指针决定顺序，完整路径检查环、断链和跨chat引用。每回合复用一个MacroContext及活历史投影，每次expand仍重新求值，不缓存变量、随机、original或字段结果。固定正则共享，legacy动态编译和普通WI整词编译各有最多1000项LRU；T21用户正则worker保持。

聊天列表查询只返回摘要实际使用的六列，保留原全局/角色过滤、更新时间与id排序、标题的文本保护，以及当前未软删末节点的完整正文和深度计数；stream_text为null时才退回text，空串仍保留。metadata、variables、settings等九个未使用的聊天列不再进入结果集合，完整chat读取不变。旧列表本来不解析这些JSON，并非把严格JSON校验改成跳过。按固定sqlite3 3.9.1的逐列读取方式，这减少无用结果列的Dart物化；仍有完整末条正文和既有plain-text处理，不承诺磁盘页、耗时或峰值内存的减少比例，也不宣称外部损坏TEXT或资源失败的所有异常行为完全等价。

角色列表只读小摘要索引。`watchCharacters()`中的description、creatorNotes、greetings和regexDiagnostics为空，进详情用`character(id)`，字段编辑用`characterFields(id)`。缺索引旧库只从两个JSON恢复；完整记录按id最多缓存最近8项，失败/缺失可重试，编辑只刷新对应项。头像路径沿用既有portrait.png，没有新增图片缩放。

导入和非空编辑在发布角色源文件前使旧摘要失效。路径查找不能确定缺失时，只读打开该索引路径确认，不读取内容或枚举整个索引目录；明确缺失才继续，访问错误在源发布前返回。探测成功先关闭句柄，再删除旧摘要；关闭或删除失败不会被当作缺失。已识别的非文件或符号链接索引仍跳过，源提交后的派生摘要写失败仍允许从当前源恢复。

删除角色时，目标目录的 notFound 分类也须用保留错误的身份查询确认缺失；仅明确缺失错误码并且后置不跟随链接的分类仍为空时，才按幂等缺失结束文件阶段。其它查询错误或成功发现对象均在所属聊天的SQL删除前返回错误，避免卡目录仍在却误报删除成功、丢掉聊天。真正目录仍以原rename为提交点，已知非目录仍拒绝；没有给之后的文件清理和SQL失败新增跨介质事务承诺。

详细的事务、故障恢复、列表合同、模拟清单和仍在调用方isolate的成本见[性能说明](docs/performance.md)。本轮没有搬迁整个引擎或实测手机帧率；500ms全文快照仍有累计文本量可随回复长度二次增长的边界，不能宣称总体已经O(n)。新增100项是运行前登记，实际验证以精确补丁回执为准；033的35条样式info作为本层等价改写处理。

# T24：离页接回、撤销删除、搜索、用量与整库备份

## App 接口及行为变化

| 接口 | 合同与新增理由 |
| --- | --- |
| `resumeTurn(chatId)` | 首次监听时接回当时的活动回合；先给 `TavernTurnSnapshot` 全文，再收后续增量和终态。 |
| `deleteFrom(chatId, nodeId)` | 改为返回 `Future<String>` 撤销 token，先软删整棵子树；原来只 await 的调用方可忽略返回值，接口实现者须转发 String。 |
| `undoDeleteFrom(chatId, token)` | 同一开库会话内恢复该批次，返回 bool；有后续树变更时保留当前路径。 |
| `searchChat(chatId, query, limit: 50)` | 指定对话所有未删除分支的字面子串搜索，返回消息及实际用量，按节点创建顺序从新到旧。 |
| `TavernMessage.reportedUsage` | nullable 的提供方实际用量；批量 path/search 无须逐条重建检视。 |
| `backup(destinationPath)` | 无活动回合时捕获数据库及文件快照，生成 ZIP，返回 `TavernBackupInfo`。 |
| `restoreTavernDirectory(archivePath, directory)` | 顶层恢复函数；目标须关闭，先验证及迁移 staging，成功后重新 open。 |

这些 api.dart 变化承载 App 需要的状态和操作结果。本包没有修改 App 转发或页面。TavernBackupInfo 的 createdAt/sqliteUserVersion/fileCount/totalBytes 描述源快照；字节数是普通 payload 文件的未压缩总量，不含 manifest，恢复迁移后不改称目标目录统计。

## 回合与观察者

send/regenerate/continueReply/impersonate 仍在首次监听时接纳回合。取消订阅只移除该观察者，零观察者时生成、正文写回、检视和用量仍继续；stop、树修改或 close 才明确取消。调用方要停止模型请求须调用 stop，不能再依赖 subscription.cancel。

resume 的查找、登记和完整快照在一个同步段完成。创建 Stream 后延迟监听，以实际监听时的回合为准。准备阶段 snapshot.message 为 null，之后收到 Started；已有消息时快照来自内存，包含未到500ms检查点的全文、续写前缀、允许的思维和本次报告。后续不重放旧 Started 或旧增量。没有活动回合则空流关闭，改从 path/inspectTurn 读持久结果。

观察者互不取消，终态关闭不等待暂停订阅的 close Future。暂停订阅仍可能由 Dart 积压事件，不能将“没有全局重放日志”解释为总内存恒定。接回限于当前引擎生命期，不承诺进程重启后恢复原 HTTP 连接。参见 Dart [StreamController](https://api.dart.dev/dart-async/StreamController/StreamController.html) 和 [close](https://api.dart.dev/dart-async/StreamController/close.html) 合同。

主回合准备中的角色详情与完整世界书加载也由引擎拥有。stop 或 close 可以先使回合给出取消终态；已开始的真实本地读取仍须排空，close 等待它们结束后才关闭数据库并释放目录所有权。回合取消结束后接纳的备份捕获也先等待这些读取。世界书在每本读取前后检查取消，当前一本排空后不再读取下一本；角色详情则完成其已开始的整份读取，包括卡正文之后的原件文件。读取成功或失败都会结束这项所有权，暂停观察者与模型订阅的取消 Future 不在这项本地 IO 等待中。

列表订阅的快照也属于引擎管理的异步工作。取消订阅停止通知，已经开始的角色索引读取或恢复仍会完成；close 等这些实际读取结束后才关闭数据库、释放目录所有权。开始关闭后不再启动新的列表读取，也不等待暂停的界面订阅消费事件。备份捕获期间的新列表读取等待捕获结束；这个等待不加入备份正在排空的操作集合，因此不会形成互相等待。捕获成功或失败都会释放等待者。

## 删除、变量与后续工作

schema5 增加删除批次、节点标记和树 revision。软删保留节点身份、正文、父边、seq、内部记忆选择、state、extra/original，不借用 ST hidden。正常节点、路径、兄弟编号、导出和搜索排除标记节点。低层 ChatStore.deleteFrom 仍立即删除，供空失败回合回滚；用户 façade 使用 softDeleteFrom。

删除与选路、当前变量/运行态恢复、latest 检视清理在同一外层事务内；撤销也一起恢复可见性和当前变量。节点自身的检视及实际用量保留，撤销不把旧调用重新记成 latest。无后续树变更时恢复原选择；新回复、正文编辑或分支 ABA 都推进 revision，此后撤销只恢复分支，保留当前路径及变量。普通 updateChat 的变量/metadata 收尾不推进 revision。

重叠删除保留各自 token；另一个已删祖先未恢复时返回 false 且不消费子 token。未知、已使用或已清理 token 返回 false，不能跨聊天使用。删除活动子树先经既有 mutation 屏障完成取消/部分正文收尾，再标记子树。

采用题目允许的“下次打开真删”，没有 timer，close 本身不清理。下次 ChatStore 初始化在 FULL 事务中清待删行及批次，再推广其他 pending 正文。恢复的 staging 试开也属于新会话，因此恢复后不能再撤销上个会话的删除；备份不重开原库，原库 token 仍有效。物理删除用原 FTS trigger 清旧词，软删/撤销不反复写索引。

## 字面搜索与 reportedUsage

新搜索查 text/speaker，包括非当前分支和 ST hidden，不查思维链。绑定参数的 instr(lower(列), lower(query)) 按完整 TEXT 做字面子串匹配，包括正文、说话人或 query 中的 NUL；%、_、!、引号、反斜线与 FTS 操作符样式均不作语法处理，中文短词可命中。采用 SQLite 原有 ASCII 大小写规则，不承诺全 Unicode 折叠。先验证 chat；空白 query 或 limit=0 返回空，负 limit 抛 ArgumentError。旧低层 search 保留 MATCH 高级语法。该查询仍需检查聊天内的候选行，不宣称全文索引加速或新的耗时保证。

SQL 排除已有 shadow 的 pending；façade 另排除活动回复，覆盖首检查点前的 continue 旧正文/旧报告和空 reply 的 speaker 命中。每 chat 至多一个活动回复，正 limit 多取一条、过滤后截取，补足正常结果。搜索不取消生成或改变路径。

字面搜索在普通 FROM 子查询中按原筛选、seq 和 limit 选节点，外层保留原完整节点字段及两个兄弟计数，并再次明确 seq 倒序。兄弟计数仍查完整 nodes 表中的同 chat/parent 未删除兄弟，不把兄弟范围缩成搜索命中或限量结果；未匹配、hidden 和 pending 兄弟继续参与编号。该结构针对有限 limit 减少未返回节点的兄弟计数工作；扫描、字符串匹配、排序和完整 payload 处理仍在，返回全部大量兄弟时仍可能有平方级计数。已执行的比较仅是宿主 SQLite 的 SQL/VM 证据，不是 Dart 或设备测速，不承诺端到端 O(N) 或耗时阈值。[SQLite 相关优化机制](https://www.sqlite.org/optoverview.html#subquery_co_routines)

reportedUsage 为 promptTokens/cacheHitTokens/completionTokens 与可选 model。缺失是 null，真实零保留对象，不从估算或旧 usage 填充。小列只从 version/chatId/nodeId 匹配的 owned inspection 派生，迁移也检查类型。path 不重建 prompt/trace，但 SQL 仍选择节点其他列，不宣称完全不读 extra 字节。

续写只用本次报告，不借之前计数，也不是累计费用。普通手动编辑保留原生成报告；无正文/思维而回滚的失败续写保留原消息及其报告，失败调用另记无 node 的检视。崩溃重开推广 pending 时清过时报告，不虚构最终 token 或价格。

## 删除人设的聊天读取

人设删除的受影响聊天筛选与存储清理只投影 `id/persona_id`，顺序仍为 `updated_at DESC, id`。显式绑定、默认回退及回合开始时捕获的人设选择继续使用原判定，文件提交前的数据库 owner 检查、提交后的重新读取、逐项绑定更新及失败回滚保持。该路径不再为筛选逐个解码聊天的 metadata/variables/settings，也不读取列表末条正文；仍查询全部聊天并按原规则排序，保留原人设解析及受影响绑定的更新。这里只说明源码工作量减少，没有 Dart/设备测速或新的耗时与内存上界；不改变 `listChats` 与完整 `chat` 的各自合同。

## 备份和恢复的边界

backup 在首个 await 前拒绝活动回合和另一备份，阻止新操作/回合；等待此前已接纳操作以及已经启动的列表快照读取完成，后来的列表读取延迟到捕获结束。SQLite 使用 [online backup API](https://www.sqlite.org/backup.html)，不拼接活 main/WAL/shm 文件。固定 sqlite3 3.9.1 用 `backup(target, nPage: 1024).drain<void>()`，native stream 真正结束后才关目标，不用 timeout 提前放弃句柄。[固定版本源码](https://github.com/simolus3/sqlite3.dart/blob/sqlite3-3.9.1/sqlite3/lib/src/ffi/implementation.dart)

全部文件 staging 完成后释放写屏障，哈希和压缩在辅助 isolate 读取不可变副本；close 等到整个备份及清理完成。ZIP 必须写在活库/快照外，完整关闭后 rename 发布，之前的编码失败不覆盖旧 ZIP。

快照保留所有聊天分支/预设/状态，角色原件及资源、世界书、正则、设置、人设和其它普通文件。只排除明确的存储临时位置、SQLite sidecar、可重建的根 character-index；资源中的 .writing 不按全局后缀过滤。内部链接/特殊文件明确报错，不跟随根外或静默漏备。目录别名统一规范身份，路径可表示性和冲突按宿主平台检查。

Persona 绝对头像只有位于库内且文件已打包才记录 id/sourcePath/path 映射。恢复先核原字节 hash，再只搬迁匹配的已知 avatarPath 到最终根；未知 JSON 中同样字符串、外部/相对/缺失引用均不改，不下载外部资源。原文、未知字段和 opaque 文件不通过重新 import 改写。

恢复先验 manifest 版本、路径/重复、实际解压长度及 SHA-256，再验实际 SQLite user_version、integrity_check、foreign_key_check。旧 schema 仅迁移 staging；现有 settings/persona/regex、角色 metadata/体检、预设详情/体检、世界书 loader 验本应用版本，不重新编译规则或解释资源，不声称验证所有业务损坏。全部 handle 关闭后才移动目标。

父目录 journal 记录 prepared/committed/rolledBack。open 先恢复 journal 再创建根：未提交状态回滚，已提交状态保留新根并重试清理；矛盾或损坏状态留证拒绝误建空库。提交后的清理失败保留日志，不谎报核心恢复失败。同 isolate 拒绝相同或祖先/后代的活库与恢复根；跨 isolate/进程仍要求单 owner，没有 OS 锁。未实现父目录 fsync，不把进程中断恢复扩称为任意断电保证。

日志类型查询返回 notFound 也可能代表访问或查找错误，不能单独授权创建空根。该分支用保留原错误的路径身份查询确认缺失，不读取未知对象内容；仅明确的缺失错误码且后置不跟随链接的类型查询仍为 notFound 时继续。查询成功或其它错误均在创建根前拒绝，原件与恢复工作目录保持可重试；已识别的链接、目录和其它非普通文件仍拒绝。回归构造公开备份及恢复可产生的合法 prepared 中断状态，没有宣称实测进程强杀、断电或跨进程锁。

备份需要额外 staging/ZIP 空间，未量测手机耗时或峰值内存。归档模块测试以合成字节模拟数据库回调，只测打包协议；store 测试用真实 SQLite backup；façade 测试以受控模型事件覆盖接回、变量/撤销、用量、搜索、整库往返、维护屏障、关闭、版本及工厂恢复。实际 Dart 结果以精确补丁回执为准。


# T16：世界书编辑、分支树、手动消息与卡外观

## App 接口及入口选择

本层按 TASK 的 a–e 与 ADDENDUM-03 的 f 一起实现，接在 T24 之后。新增接口都通过现有异步操作登记，因此 close 等待已接纳工作，T24 捕获备份时新操作按 busy 合同拒绝。App 的 DeferredTavern / PreviewTavern 转发及 UI 由主线补，本补丁不修改 App。

| 入口 | 返回与用途 | API 变化原因 |
| --- | --- | --- |
| `addCharacterBookEntry(id, entry)` | 更新后的完整角色 | 卡内书追加条目；不存在时创建 V3 书 |
| `updateCharacterBookEntry(id, index, fields)` | 更新后的完整角色 | 按原始 entries 数组下标修改，不按排序位置或 uid |
| `deleteCharacterBookEntry(id, index)` | 更新后的完整角色 | 删除该条目，保留其余原件 |
| `previewCharacterBook(id, text, chatId:, seed:)` | `Map<String,Object?>` 世界书阶段 trace | 编辑器“测一下”，复用现有命中、跳过和正则诊断 |
| `tree(chatId)` | `List<TavernTreeNode>` | 整棵可见保存树，提供 parent、role、speaker、preview、at、当前路径、兄弟序号、hidden、branchName |
| `nameBranch(chatId, nodeId, name)` | 完成后通知现有 pathChanges | 给某分支起名，null / trim 后为空时清除 |
| `deleteMessage(chatId, nodeId)` | 完成；没有撤销 token | 只永久删除一条，孩子接到原父节点 |
| `sendOnly(chatId, text)` | 已保存的 `TavernMessage` | 只追加用户消息，不生成回复；空字符串也追加 |
| `narrate(chatId, text, speaker:)` | 已保存的 narrator 消息 | 直接旁白文本入口，不生成回复 |
| `readVariables(chatId)` | 当前末节点已保存局部变量的深复制 Map | 给状态面板只读显示；空的选中路径返回 `{}` |
| `TavernCharacter.theme / assets` | 原始主题 JSON，以及 `TavernCharacterAsset` 列表 | 完整详情提供外观；两个参数可省略，旧 DTO 构造继续有效 |

`watchCharacters()` 保持 T23 的轻量摘要：theme 为 null、assets 为空；请调用 `character(id)` 取得完整外观。导入和编辑返回的是完整角色。资源 DTO 的 type/name/uri/ext/localPath 均为可空 String，原声明中的其他形状仍保留在 `characterFields` 与导出原件中。

## a. 卡内世界书写入和预览

条目编辑支持卡内书的普通 V3 字段及 extensions 中的 ST 位置、深度、顺序、概率、次关键词逻辑、常驻与分组设置。已知字段校验类型和有限整数/数字，未知合法 JSON 仍保留；对象扩展递归合并，数组和标量整体替换。调用时先深复制输入，排队后取最新原件再合并。index 始终是原 entries 数组下标，显式重复 ID 可分别编辑；旧 native 对象型 entries 仍可读和预览，但此写入 API 明确拒绝它，不静默转换为 V3 数组。

id 不能由调用者修改。实际编辑前把旧缺失/null id 固化为原数组下标，再为新增项分配未占用的非负整数。显式异常/重复 ID 保留；null→下标会改变该条目的运行身份，可能使它旧的 timer 身份失效，不能声称所有历史计时键恒定。空更新验证角色和下标，但不固化 ID、不改 modification_date、不重写源卡或索引；删到零条仍保留空书和书级未知字段。

保存复用 T23 的提交顺序：先准备新卡与摘要，再使旧摘要失效，原子发布 card.json，最后尽力发布派生摘要。无法先移除仍可读的旧索引就不发布新卡；卡已提交而索引重建失败不把成功保存谎报为失败，下次列表修复索引。原件、PNG、resources、library metadata 和已有体检报告字节不因此重编码。成功后只替换对应角色的详情 LRU，并刷新摘要列表，不恢复全量读卡或逐 chat 统计。

T22 报告保持原件和检查时间；真实卡指纹改变后读取为 stale，显式 `recheckImport` 才更新。世界书编辑不自动执行关键词试编译或重做体检。theme / localPath 的只读投影不参与指纹，不会仅因目录搬家使报告过期。

预览在首次文件等待之前捕获当前对话、变量、历史、人设、有效预设和设置；用独立 seed 的随机源和局部/全局状态副本。先固定预设，再建立单次宏环境；用户写回正则和宏、角色准备、提示词历史与扫描注入按现有阶段执行；世界书求值 await 引擎的常驻关键词 worker。只传当前卡内书，不混入另外绑定的全局、人设、对话书。

返回 scope=`character-book`、stage=`world-info`、seed、chatId、contextNodeId 以及现有 trace。正常 sticky/cooldown/decorator 规则在副本上执行后丢弃，不用改变语义的 dryRun 替代。没有完整组装最终 prompt，因此 contextAtCapacity 保持未知，不保证某条最终一定送达模型。不创建 turn、不调用模型、不取消现有回合、不保存变量、计时器、检视或使用量；关键词诊断沿用 T21。写回和 prompt 正则仍采用现有同步实现，不能把关键词 worker 的保护外推为整次预览都在 isolate 内。

普通不分大小写的世界书关键词匹配补足 İ → i + U+0307，以及按原输入上下文计算的 Final_Sigma。后者使用当前运行时的 Cased／Case_Ignorable 属性，重叠时先跳过 Case_Ignorable；除下述五段外，其余字符沿用运行时的小写映射。转换不做 locale 定制、case folding 或规范化，不改变原卡与 trace 中的关键词；区分大小写、实际 regex 执行及失败分流保持原行为；现有退回普通匹配的 literalFallback，以及评分中的普通匹配，也采用上述转换。

在上述有限范围上，再按 Unicode 17 的固定映射补足 Cherokee U+13A0–13EF→U+AB70–ABBF、U+13F0–13F5→U+13F8–13FD，Georgian Mtavruli U+1C90–1CBA→U+10D0–10FA、U+1CBD–1CBF→U+10FD–10FF，以及 Adlam U+1E900–1E921→U+1E922–1E943，共五段166个大写字符。空洞、既有小写及 Adlam 标点不随之平移；不扩大到所有 Georgian 字符。早退识别也覆盖这些范围，Adlam 从原输入完整合法代理对识别。

这仍是一项有限兼容范围，不承诺全部 Unicode 字符或任意 JS 宿主结果一致，也不固定为完整 Unicode 17；区间外继续使用 native 基础映射。Final_Sigma 仍取当前运行时的 Cased／Case_Ignorable，属性与基础映射的 Unicode 版本不假定相同。Dart 3.11.0 的这五段旧 native 行为已作官方源码确认，不代表该 SDK 的本层实际运行结果。扫描保留未配对 UTF-16 code unit，不通过新增输入禁令或 UTF-8 往返修剪字符串；这不代表存储层未配对代理项问题已解决。

## b/c. 树、分支名与两种删除

整树按插入顺序返回全部可见保存节点，不受 path 默认 60 条限制；包括非当前分支和 ST hidden，排除 T24 软删节点。preview 是原文前 64 个 Unicode code points，不拆合法代理对，不运行宏、正则或 Markdown。活动回复只读已经保存的正文/checkpoint；要接回实时全文请用 T24 的 resumeTurn。

整树和 JSONL 导出共用的 allNodes 读取，以单个聊天的未软删节点为范围，在 SQLite 内按原始 parent_id 分组，用窗口计算兄弟序号和完整组大小，再按唯一 seq 读取完整节点。NULL 根、hidden、正文与流式字段的解码、extra/original 和最终插入顺序保持原合同；其他单节点及局部查询仍沿用原兄弟投影。

这项改动针对同父兄弟很多时的重复计数。宿主 SQLite 3.53.1 辅助探针中，1024 个根兄弟的 VM 步从 9,526,331 降至 121,940，而 1024 节点单链从 99,386 增至 141,377（约增加 42.25%）。这不是 Dart 或设备延迟测量，也不表示完整导出或所有树形都更快。新增两项小规模公共语义回归在旧新查询下都应通过；实际运行及宽树/长链性能取舍仍须本机验证。

单行 swipes 展开后，各节点的 original 仍保留原 swipes 数组，完整节点读取继续逐份解码。因此这部分载体可随兄弟数二次增长；本次只减少重复兄弟计数，不承诺完整 tree/JSONL 导出端到端线性，也不改变原件字段、存储格式或无损往返合同。

分支名存于 `extra.dshgo.branchName`，仅合并这个字段。命名先取消并等待该聊天的活动回合，再读取最新 extra，因此不覆盖取消收尾写入的检视、使用量或状态。同名/清理本已缺失的字段不写；实际改名推进树版本，旧撤销 token 仍可恢复分支可见性，但不覆盖之后的选择。

| 操作 | 被移除的内容 | 选择和状态 | 撤销 |
| --- | --- | --- | --- |
| `deleteMessage` | 一条可见节点，所有物理直接孩子重挂；包括待撤销孩子 | 幸存节点 ID、正文、报告及未知数据不变；当前末节点若正是目标则退到父/空路径；否则保留末节点 | 没有 token，永久删除 |
| `deleteFrom` | T24 的整棵物理子树软删标记 | 当前路径退回保留部分并恢复其局部状态 | 返回 token；下次打开前可撤销，后续树版本影响选择恢复 |

单条删除前分别保存两种状态：物理父链重建值写成每个直接孩子的完整 checkpoint；孩子的 portable tavernState 另存于原 extra，不能拿它替换物理基底，否则会污染更深后代的 delta。旧快照缺少 hash 标记时，在改边前按该孩子自己的来源 header 补齐；显式 null 与 0 均保留。更深后代的 delta/full 不变，全部物理后代深度减一。后续 append 同时按实际 delta 距离建检查点，保持最多 19 个 delta，而不只看已经改变的深度取模。

结构修改、当前局部变量/运行 metadata 恢复、失去有效锚点的 latest inspection 清理放在一个 SQL 事务内；成功提交后才清内存变量/检视缓存。取消回合的既有收尾可先产生效果，删除本身不重放宏、不改全局变量。旧子树 token 若记录了已永久删除的父/选择，单删会推进 tree_revision，使 undo 只恢复实际新父边上的可见性，不复活历史父节点。待删节点不能作为单删目标；普通读写也不能绕过软删可见性。

## d/e. 手动消息与保存变量

`sendOnly` 对原始 text 先执行 USER_INPUT 写回正则，再展开一次宏；不先 trim，结果为空仍入树，speaker 取当前人设名。`narrate` 先按 JavaScript 的 25 个空白/换行码元集合 trim，再展开宏，不执行 placement 3；NEL U+0085 保留。speaker 显式参数（包括空串）优先，其次为有效 metadata 中非空 String 的 narrator_name，最后为 System。节点可见、role=narrator、extra.type=narrator。

变量清理也采用该 JavaScript 集合：legacy 的 set/add/inc/dec/get 局部与全局变量宏清理名称，保留 NEL，使 `KEY` 与 `NEL+KEY` 保持两个键；设值参数仍按 legacy 原规则原样保存。现代简写先求出参数值再清理边缘空白，该共享值用于赋值、追加、比较与 fallback，因此 NEL 保留、NBSP/BOM 被裁去；惰性分支、首次求值缓存及求值顺序保持原规则。

卡字段的三个既有清理 helper（legacy eager、modern lazy、主回合字段快照）也按 JavaScript 集合裁边：保留 NEL，裁去 NBSP/BOM，再展开宏并按原规则处理 CR。它们共同覆盖原来会清理的系统与尾部提示、描述、性格、场景、示例、创作者注释、深度提示、问候及相应 persona/覆盖值，不只 description；原字段后续专用处理、类型/空值规则、访问顺序和缓存保持。character_version 继续原样读取，personaDescription 提示 marker 继续使用 raw persona。原卡 JSON 不因这些执行时清理而改写。

这里的卡字段执行时清理与 createChat 的原始问候入口采用不同政策：后者取消 AI_OUTPUT 正则前的 trim，允许 NBSP/BOM 等边缘原文进入正则；不把卡字段 helper 的裁边合同移给 createChat。

两入口先取消并等待当前回合，随后沿此时选中末节点追加；不另外执行 prepareCharacterFields、首条历史重写、WI、完整 prompt 或模型调用，保留前次请求检视。旧宏模式自身的 eager 卡字段读取仍然执行，这是已有宏语义，不能误写为“绝无卡字段副作用”。旁白入口只对齐直接 handler 的正文阶段，不模拟 slash parser 的前置参数展开、bias、at、compact 或 avatar 参数。

局部变量在副本里计算，与新消息和运行 metadata 一起提交；timer/decorator/greeting、JSONL 来源、chat identity 与 hash 跟随选中状态。已改变的全局变量先持久保存，再进入 SQL 事务。准备失败时仍保存已经发生的全局准备效果；若保存也失败，错误载体保留原准备错误、保存错误及各自 stack。准备成功但保存失败不会追加消息；之后 SQL 失败会回滚消息和局部状态，而已经保存的全局准备效果保留。这是新手动入口的明确顺序，未更改旧 createChat 的既有顺序。

`readVariables` 只读末节点保存的 effective state，优先 portable override，否则物理快照；其 variables 缺失时为空，不从 chat 级或 live cache 补值，不包含 globalVariables。读取不保存、不取消、不运行宏、不消耗随机数，返回嵌套 Map/List 的独立副本。即使还有未选中的根节点，空的选中路径也返回 `{}`。

## f. 外观与本地资源

theme 是 `extensions.dshgo.theme` 的 JSON 深复制，对象、数组和标量都原样提供，缺失或 null 仍为 null，不解释颜色/字体、不增加默认值、不暴露其他 extensions。assets 保留对象成员的声明顺序，type/name/uri/ext 是字符串才投影；其余原值仍在完整卡 JSON 中。

已物化的 `embeded://`、`embedded://`、`__asset:` 与 CHARX 安全相对引用给出当前角色目录中的 resources 路径；`ccdefault:` 在保有原 PNG 时指向 source.png，不拿 portrait.png 代替原始动画/容器。远程 URL 保持原 uri，localPath=null；不下载，不把 arbitrary file URI 当本地资源，不做 URI 百分号解码。路径只在记录运行时保存，不写入卡、metadata、摘要索引或报告；整库移动、T24 恢复到新根后，重读详情按新根生成路径。

localPath 表示当前已载入记录的物化位置，不能保证面对外部删除文件后仍永远存在；不为每次 DTO 投影额外扫盘。摘要构造直接读取小字段并复用 regex/script 计数，不先展开主题和资源再丢弃，因此列表和索引恢复继续保持 T23 的轻量职责。

## 来源与测试边界

ST 对照固定为 `7e8663cd9c184a550b37238218bdd32c6efc68e9`（AGPL-3.0）：[script.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/script.js) 的普通删除及 sendMessageAsUser、[slash-commands.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/slash-commands.js) 的 sendNarratorMessage。这里对齐正文阶段和“仅删该条、保留之后消息”；树边、checkpoint 与撤销 token 是本项目存储适配，不声称 ST 原生也具有相同树模型。

本层以临时真实 SQLite/文件/ZIP、真实正则与宏做回归；模型事件、时钟和随机源使用受控 fixture，不发生真实计费。SQL 触发器和 settings.json.writing 目录用于真实失败路径；外观回归的 loopback 服务只统计是否发生不应有的下载。没有把源码阅读、Python SQLite 探针或 V8 空白谓词对照算成 Dart 通过。准确注册数、冻结 SHA、独立复核与 owner 运行结果记录在本层交付 README/REVIEW；旧 027/028 只适用于旧 T16a/b 层叠。

# T17：节点状态、声明式规则与工具审计

本层实现 ADDENDUM-02 的状态层。App 可读原始 schema、已保存的值、隐藏/钉住路径、本次变化和效果，能手动改一个值，也能查看模型与规则的执行记录。新增状态处理不依赖画布脚本，不从正文猜状态，不实现 §2.4 的自动整理者、自动推断 schema 或每三回合对账；这些仍是后续工作。状态不是 ST 全局变量，卡内第三方脚本也不会因为本层自动获得执行能力。

## App 接口与保存位置

| 入口 | 返回及用途 | 增加接口的理由 |
| --- | --- | --- |
| `readState(chatId)` | `TavernStateSnapshot`：当前末节点 ID、DSH/legacy 模式、值是否存在、原始 schema 和值、初值预览、hiddenPaths、pinPaths、最近一次成功变更与效果、诊断 | 一次读取状态面板所需信息；缺失值和显式 null 分开，读取不落库 |
| `setStateValue(chatId, path, value, expectedNodeId:)` | `TavernStateEditResult`：applied、changed、最新面板、操作收据及诊断 | UI 只能通过 user 权限和同一校验器修改；可选节点守卫防止编辑器在切分支后写错位置 |
| `readAgentRuns(chatId, nodeId:, limit: 50)` | 最新在前的 `TavernAgentRun` 列表，含 kind、时间、锚点、用量及结果 | 让检视页读取持久化工具、规则与手改审计，按节点过滤或查看整个对话 |

DTO 的 JSON 在构造和读取两侧复制，调用者修改返回容器不会修改保存状态。schema 保留 `description`、`title`、`x-dsh-show` 等原字段，由 App 决定画法；本层增加布尔 `x-dsh-pin`，也接受 state 级 `pin` JSON Pointer 数组。`hiddenPaths` 表示主模型不可直接看见的路径，App 仍拿到原值，可以按产品需要显示或折叠。

DSH 值保存在节点 effective state 的 `messageVariables.dshgo`。MVU 的 `stat_data` 及其他 messageVariables 邻项原样保留，ST 局部变量仍是独立的 `variables`。切回答、切分支、单删重挂、JSONL 的各个 swipe 都沿用 T16 的有效节点快照规则。状态运行账本另存 `dshgoStateRuntime`；它不占用用户字段的 `dshgo` 对象，也不混入全局变量。

没有显式 schema 的卡使用 legacy 面板，显示末节点已保存的 ST 局部变量；空选中路径为空。手改不展开宏、不访问 globalVariables，根指针只允许对象；已有非对象局部变量可用根对象显式修复。显式存在但无效的 schema 仍是 DSH 模式，带诊断，不能悄悄退回 ST 变量编辑。

## schema、初始化与只读边界

版本键是 `extensions.dshgo.v`，缺省为 1。定义位于 `extensions.dshgo.state`，包含 `schema`、可选 `init`、`rules`、`summary`、`depth`、`role`、`pin`。本层本地 schema 子集支持七种 JSON 类型及 type 联合、properties、同质 items、required、布尔 additionalProperties、有限数值上下界与数值 exclusive 上下界、enum、default、title/description、数组长度及 Unicode code point 字符串长度。`x-dsh-step`、`x-dsh-by`、`x-dsh-hidden`、`x-dsh-show`、`x-dsh-pin`、`x-dsh-derive` 按本节执行；这不声称实现完整 JSON Schema 标准。

不支持的已知约束使对应子树不可写，父对象替换或数组移位不能绕过；其他独立子树仍可操作。未知厂商注释保留原件并给 unknown 诊断。导入体检只编译定义，映射每项问题和数量，不运行初值、表达式、规则或模型；旧卡没有 schema 时不增加状态报告项。导入本身不初始化节点状态。

初值优先采用显式 `state.init`，否则采用根 default，缺省对象根可从 `{}` 开始；在已经存在或明确建立的容器里补属性 default。只有子字段有 default，不会凭空创建可选的父对象或数组。初始化时计算派生值、校验完整结果，随后固定本次 step 基线；失败则保留缺失并给诊断。显式 null、标量、数组或已有不合法保存值都不会被默认值偷偷覆盖。读接口可返回独立的 `initialValues` 预览，但不会写入节点、消费一次性规则或生成执行记录。

新建聊天、send/sendOnly/narrate/regenerate/continue 的节点保存会在增强开启且值缺失时初始化；手动追加消息不跑剧情规则。原来已存在的坏值先保留，只有显式操作形成完整合法候选才提交，不自动截断未触碰的旧坏字段。`stateEnabled: false` 可通过已有全局/对话 `setSettings` 关闭自动初始化、主模型状态提示、工具、回合后规则和 pending 消费；显式用户手改仍按权限校验并执行适用规则。只有 JSON 布尔 false 表示关闭。面板 `automaticEnabled` 是有效设置与定义的启用状态；若保存账本损坏，issues 会另指出本次不可执行。

## 五种操作与本次变化

每个操作是 JSON 对象，`op`、`path`、`why` 必填；`why` 必须是字符串。`set/add/push/move` 需要 `value`，`remove` 不接受 value。可以加 `from`，表示预期的目标旧值；它和实际值不同只记 conflict，不单凭冲突丢弃原本合法的操作。显式 `from: null` 与没有 from 不同，缺失旧路径也有独立 exists 标记。

| op | value 的含义 | 主要边界 |
| --- | --- | --- |
| set | 新值 | 不自动造中间父容器；空指针替换根 |
| add | 有限数字增量 | 目标必须是数字；整个 invocation 共用 step 基线 |
| push | 新的一个数组元素 | 校验 items、长度及完整候选 |
| remove | 不带 value | 删除对象键或现有数组元素；不能删除根 |
| move | **源 JSON Pointer 字符串** | path 是目的；先核旧目标/权限再删除源，删除后重新解释目的数组索引；同一路径需先存在 |

Pointer 只解码一次 `~0` 和 `~1`，不做 URL 解码；对象中的 `01` 是普通键，数组要求规范非负索引。`-` 只用于 move 的数组末尾目的。数组内 `0→2` 表示删除旧 0 后在新索引 2 插入，例如 `[A,B,C]→[B,C,A]`。源是目的祖先、权限不足、目的无效或派生/完整校验失败时，整个操作回滚。

`x-dsh-by` 在祖先与子节点之间取交集，默认 model/rules/user；空数组拒绝全部。hidden 对 model 形成额外拒绝，派生字段只由计算器写入。范围和 `x-dsh-step` 对显式新数值截断并记录 clamps；整数使用合法整数边界，number 的 exclusive 边界没有虚构的 epsilon。移动和数组移位保留既有负载，不通过改数字来“修好”结构操作。step 按固定路径的调用起点计算，跨多个工具调用和后续规则不重置；先删再建、父替换、移动都不能重置额度。下一次 continue 或用户编辑是新 invocation，才重新取基线。

每次成功 invocation 的 own audit 写到当前节点 `extra.dshgo` 的 `stateInvocation/stateChanges/stateEffects/stateIssues`。changes 是基线到最终值的合并差分，包含 path、oldExists/old、newExists/new、actor、why；数值 1 与 1.0 相等，不伪造 `+0`。被后续操作覆盖的中间值保留在收据，不伪装成最后的增量。新节点不继承父节点的“本回合变化”；无效手改、取消或失败不擦掉原节点上一次成功 audit。user 的默认原因是“你改的”。

例如 `affection` 初值 0、step=5 时，模型提交以下操作会得到 5，并留下截断依据；下一条同次调用再加 5 也不能绕过同一上限：

```json
{"ops":[{"op":"add","path":"/affection","value":20,"why":"信任提高","from":0}]}
```

## 模型可见投影与 strict 工具

主模型只收到公开状态。隐藏对象成员省略，隐藏数组元素用 null 占位以维持索引；没有 schema 的未知属性不出现在公开投影。公开字段的 description 写进默认摘要和工具 value/path 说明，title 也进入工具说明；隐藏祖先下的说明不发送。卡可用 `summary` 的 `{{state}}` 或 `{{state:/pointer}}` 插入公开 JSON/字段，单次替换，不再递归解释替换结果；缺失或隐藏路径为空并给诊断。默认深度 1、system，role 可选 system/user/assistant，depth 为 0..10000 的整数，随后沿用 ST/DeepSeek 后处理。

状态摘要和规则 pending 文本使用 `PromptFragment.expandMacros=false`，包括经过相对、绝对、深度和合并路径后也不运行 ST 宏。因此保存值中的 `{{incvar::...}}` 不会产生变量副作用。隐藏投影不是完整自然语言信息流控制：卡作者公开声明的 derive 或模板本身可以主动写出秘密；本层不理解并重写作者的任意自然语言。

`update_state` 从可执行公开 schema 生成封闭的 anyOf 操作分支。每个对象字段全部 required、additionalProperties=false；有/无 from 用不同分支，数值 add 的 value 表示增量，不错误地套用目标值范围，from 也不错误地套新值约束。不可替换的父容器不宣传整体操作；本地执行器同时核能力集合，不只相信提供商 strict。路径分支按可能的父类型遍历，不会为显式 string 的 properties 宣传不可达操作。

[DeepSeek 工具文档](https://api-docs.deepseek.com/guides/tool_calls/) 当日说明 strict 需要 beta 和 function.strict=true，并列出受支持类型。本实现沿用已有 `/beta/chat/completions` 路由。其公开类型列表未保证 null，因此只把可表示的非 null 分支送给主模型，另给 strict_nullable 诊断；本地显式编辑仍可保留/设置 schema 允许的 null。strict 对象的全部字段必填也是模型能力子集限制，不改变原始本地 schema 的 optional 语义。普通 OpenAI 兼容服务使用同一参数形状但不添加 DeepSeek strict 标志，没有声称验证了所有服务商。

仅当实际最终请求仍含 update_state 且 tool_choice 允许它、非 thinking、非 prefix/impersonate、增强开启、定义/账本可执行时，模型操作才有执行资格。工具结构完整不能自行获得资格。T17 不发第二次工具结果请求，不回放 tool 消息，下一回合通过状态摘要体现效果。工具-only 正常终态允许保存空正文回复。

## 派生值、规则、效果与下一回合提示

派生及条件使用固定 `json-logic-js 2.0.5` 的有限子集：var、if、and/or、!、!!、相等/不等/关系比较、+、-、*、/、%、min/max。采用 JsonLogic 的空数组假值和惰性分支；保留 JS 数值/字符串转换、对象引用相等的相应语义，非有限结果或 undefined 拒绝。var 路径必须为静态字符串或有限数字；动态取值、数组循环、自定义函数不支持。派生依赖按静态 DAG 排序，循环/未知依赖有诊断，每个操作后的派生失败会回滚那个操作；最终自动计算或完整校验失败不发布候选。

规则格式为 `{id?, when, once?, do:[...]}`，按声明顺序检查一遍，前条成功的状态操作和派生值可被后条看到，不反复求固定点。动作格式如下：

| type | 字段 | 接受后的含义 |
| --- | --- | --- |
| state | ops | 同一校验器，以 rules 权限执行 |
| prompt | text | 放入 pending 队列，供后续主请求一次性发送 |
| notice | text | 保存通知效果，供 App 显示 |
| event | name、data | 保存命名剧情事件，供后续消费者读取 |
| unlock | kind=ending/achievement、id、可选 title | 保存结局/成就效果，供 App 消费 |

state 动作的 value 仍是字面 JSON，不把任意对象暗中当表达式。每条 once 只要至少一个操作被接受（含合法 no-op）或一个效果被接受，就记为消耗；全部拒绝不消耗。显式 id 的身份为 `id:<id>`，修改定义但保留 id 不重置 once；重复显式 id 的规则拒绝。无 id 规则按规范化自身内容及同内容序号识别，不使用整份定义 hash 导致无关编辑重跑。条件 false、已消耗、条件错误和执行结果都有有界 rule 收据。

`dshgoStateRuntime` 的 version=1，firedRules/pendingPrompts 缺失按空处理，未知字段保留；显式 null、错误字段类型、未来版本或重复 pending ID 使整个 session 只读。不会把坏账本清空后重新执行 once。effect 使用独立的 effectId/invocationId，保留 unlock 原来的业务 id；接受并保存效果不等于 App/T18 已显示、消费或执行外部动作。

pending 只消费本次最终请求实际包含、并且 stop/tool_calls 成功提交的旧集合。预算排除、增强关闭、impersonate、length/content_filter/null、取消、网络或 SQL 失败都保留它们；本次规则新产生的 prompt 留给下一次。导入的原始 ledger id 与组装器 source id 显式映射，新来源使用专用命名空间，避免把 `2_floating_prompt` 等合法原 ID 误当原生 ST 扩展。

## 事务、审计与运行限制

主回合的工具片段不算正文输出；按 index 累积 arguments，metadata 冲突、重复 id、半截 JSON 和错误参数保留诊断，坏的独立调用不妨碍另一合法调用。正常终态按 index 顺序执行多个调用，共用一份纯 session，最后只跑一遍规则。thinking/prefill 模式仍可在正常结束后跑声明式规则，但没有自动推断正文的整理者。

候选状态与 turn 当前状态分开保存。正文、inspection、候选状态、own audit、agent_runs 在同一 SQL 事务提交，提交后才更新缓存；失败后保存 partial 正文的路径不能拿到已经回滚的候选、once 或新 effects。无正文的失败回滚临时节点，诊断 run 使用 null 锚；continue 失败仍可锚原节点。用户编辑先复制输入、取消并等待活动回合，随后取最新叶，节点守卫失败只记拒绝。与旧 ST 宏准备的全局文件写入顺序保持原合同，不把两个存储系统虚构成分布式原子事务。

审计 kind 是 state.tool/state.tool_batch/state.rules/state.user，含 invocation、输入/参数、收据、拒绝/冲突/截断、耗时、提交结果以及本次已有 reported usage。耗时为墙钟测量而非确定性 fixture，未获取 usage 时为空。读取按时间和插入顺序降序；软删物理节点仍可作锚，永久删后 FK 置空，删 chat 级联。节点状态和 own audit 随 JSONL 往返，数据库 agent_runs 历史不塞进 ST JSONL；整库备份恢复保留它们。

| 有界对象 | 上限与行为 |
| --- | --- |
| schema | 2048 个节点、深度 64 |
| 单个 JsonLogic 表达式 | 4096 个 AST 节点、深度 64 |
| 同次状态执行 | 256 个 state ops、256 条规则、256 个规则动作 |
| 规则效果 | 256 KiB UTF-8 |
| strict 参数 | 2048 个操作分支、256 KiB；超限整工具不暴露 |
| 单次响应工具 | 64 个不同 index、arguments 合计 1 MiB UTF-8；资源超限整批拒绝 |
| 累积器诊断 | 去重并限制 32 条，保留资源拒绝及遗漏标记 |

arguments 的 UTF-8 上限按每个明确 index 的累积字符串分别计算后合计。同一调用的 Unicode 代理对即使分在两个参数片段中，也与未分片时计入相同字节；空字符串参数或未携带 arguments 的 metadata 片段不改变连接关系，不同 index 之间不配对。HTTP 显式 arguments:null 仍保留字段类型诊断，不能执行。未分配或非法 index 的参数仍独立消耗响应预算，64 项上限仍统计不同调用 index，真正超限后整批保持不可执行。这里计量的是外层 JSON 解码后的 arguments 字符串，不是 SSE 包大小，也不先解析内层参数来忽略其中的空白或转义。

这些是具体组件的限制，不是全状态文档、所有响应 metadata 或进程总内存的恒定界。状态编译、校验、派生和规则目前在引擎所在 isolate 同步执行；没有声称整个引擎已搬到后台、手机性能已测量或真实提供商账户已验收。

语义依据为 [JsonLogic 官方操作](https://jsonlogic.com/operations.html) 与 [MIT 源码固定提交](https://github.com/jwadhams/json-logic-js/blob/c5c73601c90b11e98f6846609bac4dec203d1c18/logic.js)，原许可在 `lib/src/state/JSONLOGIC-LICENSE.txt`。测试包含固定原 JS 的 24 个 oracle 案及另外的数值、truthiness、DAG 和权限反例；V8/Python 探针仅证明各自探针，不代替 Dart。工具传输测试使用真实 loopback HTTP/SSE；门面测试使用真实 SQLite、文件、宏、提示组装、导入/导出和备份，只替换模型事件/时钟/随机。实际 format/analyze/定向/全包/20 案 ST 运行结果以精确补丁交付 README/REVIEW 与 owner 回件为准，源码登记数不是通过数。


# T16-select-node：直达任意树节点（接在 T17 之后）

新增 `Future<void> selectNode(String chatId, String nodeId, {bool restoreDescendants = false})`。App 的 `DeferredTavern` / `PreviewTavern` 等实现只需增加同签名转发，并原样传递命名参数；本补丁只修改包，不修改 App。树页可直接传 `tree` 返回的任意节点 ID，不必逐层换 sibling。

默认精确停在目标节点：沿祖先设置选中边，并持久清除目标的第一条 `selected_child_id`。后代节点及更深的记忆边仍保留。`restoreDescendants: true` 只沿目标目前记忆的路径选择最深后代，不能恢复先前已经清掉的第一条边；显式选中一个保留后代可以重新建立其祖先选择。低层 `ChatStore.selectNode` 的默认值仍为 true，旧 `selectSibling`、regenerate 和 continue 的记忆/精确停点约定不变。

调用先取消并等待该聊天的活动回合，再把选边、当前根/末节点及局部变量/运行 metadata 恢复放入同一 SQL 事务。成功后才清 live variables 缓存；恢复使用所选末节点的 portable tavernState，缺少时才重建物理快照。T17 状态、once、pending 和审计跟随该保存节点读取，不因选择而重新初始化或运行规则。原回合取消收尾仍可能保存 partial、回滚空节点及保留失败审计，这些先于选择发生。 即使随后发现目标无效，也不撤销已经完成的原回合收尾；“选择失败回滚”只覆盖本次选择事务。

目标必须存在、属于此聊天且未软删；ST hidden 节点仍可选。只检查本次经过的祖先和记忆后代链，拒绝环、外聊天、非直接孩子或已软删引用，不改写不相关分支。失败的选择事务完整回滚，包括显式停点清边和 tree_revision；空选中路径即使保留其他根也可重新选择。新增定向测试含真实 SQLite 晚期触发器失败、取消收尾、空路径 JSONL 往返和重开验证；登记与静态审阅不等于 Dart 运行通过。


# T18a：后台导演、下一拍与预取

## 完成范围与 App 接入

本层实现 ADDENDUM-02 所列导演的第一层闭环：一次后台 `direct` 调用，保存五字段输出及失败审计，独立刷新 App，并在下一主回合使用已捕获、来源仍有效的 `beat` 和 `prefetch`。本层只改包，不改 App。T18 总体仍有后续工作，具体列在本节末尾，不能把保存提案等同于已执行剧情事件。

| API | 返回与用途 | 新接口的原因 |
| --- | --- | --- |
| `readDirector(chatId)` | `TavernDirectorSnapshot`，分开提供 `latestSuccess` 与 `latestAttempt`，以及 `stale`、`issues`、`automaticEnabled`、`pendingJobs`、`running` | 主回合检视与后台 helper 具有不同生命周期；失败不能覆盖上次成功结果 |
| `watchDirector(chatId)` | 初始快照及后续变化；成功、失败、队列状态、设置与来源变化可刷新 | 主事件流已在回复结束时关闭，无法承载稍后完成的导演 |
| `runDirector(chatId)` | 显式运行一次，返回该次 `TavernDirectorRun` | 自动关闭时仍允许用户点“让导演想一想”；不会暗中打开自动收费开关 |
| `readDirectorEvents(chatId, limit: 50, beforeEventId:)` | 以发布顺序倒序读取跨多次成功结果的提案 | 新结果替换最近建议时，旧的待处理事件仍能通过稳定游标读取 |

`TavernDirectorRun` 包含源种类/原节点 ID/指纹、起止时间、自动或手动、是否成功、已有 reported usage、失败类别、诊断和输出。`notesSpoiler` 固定为 true，App 可默认折叠笔记。`output`、`issues` 及五字段的列表 getter 每次返回独立 JSON 副本。`latestSuccess == null` 可能表示从未成功，也可能是最近成功行不可用；后者会有明确诊断，不悄悄回退到更旧结果。

`stale` 指最近成功结果当前不具备注入资格，不删除笔记。App 可展示旧笔记并标明来源已变，不应把 stale 建议当成已经针对当前分支重算。`pendingJobs` 包括正在准备、调用、等待的任务，以及已取消但实际文件读取还在排空的任务；`running` 仅表示队列内正在执行的 job，两者可能暂时不同。取消 watch 只取消观察，不取消导演或主生成。

事件 DTO 正常时 `available=true`、`status='pending'`、`source='director'`，含稳定 `id`、`runId`、原始源信息、`name/data/createdAt`。`name` 和 `data` 都是模型提案文本，没有执行权限。读取坏 JSON、未来版本或形状不合法的事件时返回 `available=false`、`status='unavailable'` 与固定原因；保留 `id/chatId`，其余 payload 为 null。该 ID 仍可作下一页游标，正常邻居不会因此被隐藏，原始行也不会被自动修复。负 limit 抛 ArgumentError，零返回空；游标必须属于此聊天的导演事件。

## 自动开关与逐回合计数

沿用 `readSettings/setSettings` 的 JSON 设置。App 可用下列调用设置本聊天，省略 `chatId` 则设置全局默认：

```dart
await tavern.setSettings({
  'director': {'enabled': true, 'every': 2},
}, chatId: chatId);
```

开关应命名为“自动导演”：只有布尔 true 打开自动调用，缺省关闭；卡不能自行打开收费开关。全局与聊天覆盖按现有设置合并规则处理。关闭自动仍保留上次成功结果供下一回合使用，也保留显式手动入口。`every` 接受 1..1000 的整数；用户未提供时可读卡内 `extensions.dshgo.director.every`，两处均缺失则为 1。显式 null、字符串、零或其他非法值采用 1 并记录诊断，不用宽松数值转换猜测用户的收费频率。

仅成功提交且 `finish_reason` 明确为 `stop` 或 `tool_calls` 的 send、regenerate、continue 计入自动轮次。同一节点的两次 continue 是两个 invocation，不能用节点数量代替。impersonate、只发不回、旁白、失败、取消、length、content_filter 和缺失终态均不计入。计数以 `director.tick` 持久化，重开继续；只在当前自动设置开启时递增，手动不改计数。坏/未来计数行使自动触发暂不可用并给诊断，不清零后重新收费。

主回复提交并发出 Done 后，同一同步段登记任务所有权，实际准备和模型调用放到后续任务；主回合不等导演。自动 admission 重新读取当前有效开关：主回合开始后全局关闭，也不能继续用旧开关发新 helper；但聊天显式开启的覆盖仍有效。

每聊天一个独立串行队列，正常情况下保留每个应运行的回合。上限为 32 个已接纳且尚未释放全部所有权的任务；第 33 个保存 `director_queue_full` 失败而不调用模型。同源、同设置、人设、配置与角色卡修订的重复手动按钮合并到同一个已接纳手动任务；不同源排队。主生成、树修改或角色删除期间手动调用返回 busy，不取消或等待主回合，也不捕获 continue 的流式半成品。

## helper 的输入、传输与输出

helper 输入为必要角色文字与 `extensions.dshgo.story/state/director`、当前人设、来源路径最新 12 个可见正文节点、至多 20 条已有合格摘要、源节点已保存的状态（含隐藏值/定义及旧卡局部变量）、上一份已发布笔记，以及实际已绑定世界书/记忆的标题目录。摘要的起止节点都必须位于该来源的有序祖先路径；本层不生成摘要，也不保证人工摘要在正文修改后语义上仍准确。

来源、设置、人设和配置在接纳时捕获；角色/世界书文件读取后使用副本。队列到头时读取上一份成功 notes，因此前一个 job 刚发布的笔记可以进入下一 job。helper 不复制历史 reasoning/tool_calls，不运行 ST 宏、规则或 derive，不把全局变量当成隐藏状态。目录最多 512 项，摘要截断有诊断；整个编码后的 helper 输入超过 1 MiB 即明确失败，不默默删掉隐藏真相以凑预算。历史指纹的计算与本地 JSON 组装仍在引擎所在 isolate，未声称手机耗时或进程总内存恒定。

DeepSeek helper 固定 `deepseek-flash`、关闭 thinking，沿现有配置的 key callback 和 base URL，使用既有 beta 路由。普通兼容 provider 沿当前 model，关闭内部 thinking 模式，并省略 DeepSeek 的 thinking/strict 字段。实际请求只有独立 system/user 输入、`stream:false`、`max_tokens:4096`、一个 direct 定义和具名 `tool_choice`；不继承主预设的 prefix、stop、采样参数或其他工具。

[DeepSeek 工具文档](https://api-docs.deepseek.com/guides/tool_calls/) 说明 beta、`function.strict=true`、必填和封闭对象的要求；[Chat Completions 文档](https://api-docs.deepseek.com/api/create-chat-completion/) 描述具名工具选择与 thinking 的约束。本层使用已核实的类型/enum/anyOf 组合，不把本地长度限制作为未确认的 strict 关键字发送。普通兼容服务没有真实 strict 兼容承诺。本层没有真实账号调用证据。

一次逻辑调用必须得到恰好一个完整、合法的 direct 函数调用，并有一个正常终态；额外工具、半截 JSON、冲突的调用身份、超限 batch、重复/缺失终态均失败。正文或 reasoning 即使出现也不会作为剧情正文写入。没有第二轮工具结果请求或 JSON fallback。底层既有连接错误/5xx 有界重试仍可能产生多次 POST；这不是绝对一次计费保证，详见 T19 的重试边界。

五个字段全部必填，所有对象都封闭：

| 字段 | 结构与本地限制 |
| --- | --- |
| `notes` | 字符串，至多 64 KiB UTF-8；覆盖最近成功笔记视图，历史审计保留 |
| `beat` | 字符串，至多 16 KiB；作为下一拍要点，不生成正文或对白 |
| `prefetch` | 最多 64 项；`{kind:'worldInfo',bookId,uid}` 或 `{kind:'memory',id}`，标识必须为非空字符串，每项标识最多 1 KiB |
| `suggestions` | 恰好 3 项 `{text,risk}`；text 非空、最多 4 KiB，risk 最多 1 KiB、可空 |
| `events` | 最多 32 项 `{name,data}`；name 非空、最多 1 KiB，data 字符串最多 16 KiB、可空 |

全部编码后输出至多 256 KiB。notes/beat 可空；字段不隐式 trim 或转数值；重复引用保留原序号供 resolver 说明去重。格式异常只使用固定错误文字，不拼出私有输入或提供商回显。已有 usage 仍保存在失败审计；无报告时不推算 token 或费用。

提示词要求不替用户行动，并对 beat 进行一个明确有限的检查：分句后，删掉以人设精确名字开头并接空白、冒号或列明动作词的句子，记录移除位置，保留其他原文。它不是自然语言语义证明，不保证识别所有代用户行动的改写；也不通过执行模型文字来完成检查。

## 来源资格与下一回合

成功结果具有显式 `node` 或 `empty` 源。节点源在数据库 FK 因永久删除而变为 null 后，审计仍保留原 `sourceNodeId`，不能误变成空聊天来源。指纹覆盖从根到源的节点身份、全部祖先正文/role/speaker/hidden/system 的摘要、源保存状态、必要卡字段与人设；不比较之后新追加的后代，不包含 previous notes、可回拨时钟或全局树 revision。

主回合在开始时捕获当时最近成功行，之后完成的 helper 不会改写这一轮的输入。准备时核该源仍是所用上下文的祖先且指纹相同。正常追加后代允许继续使用；无关分支、源删除、原地改正文/隐藏状态、相关卡或人设改变会使结果 stale。空源可给仍为空的选中路径首次 send 使用；regenerate 的空前缀一律不能冒充该保存空来源，即使当前选择为空且仍保留其他根。

例：A 导演未完成时 B 主回合开始，B 固定使用更早的成功结果；A 在 B 期间或之后完成并保存，C 开始时才可能捕获 A。普通分支切换不强行取消 A，A 可留下审计，但当前分支不合格时不会注入。

beat 以 depth=1、system、`expandMacros:false` 的独立来源片段进入原组装器，可被正常预算裁掉。宏样式文本保持字面，不修改变量。主请求不拼 notes、完整 helper request、隐藏 schema/default 或整个 direct 输出；这是明确的字段隔离，不保证模型的自然语言 beat 不主动透露已经看过的秘密。

`TavernTurnInspection.director` 给出实际捕获的 runId、资格诊断、beat 是否提供/最终观察到，以及每项预取的目录授权、解析结果、WI 决策和最终来源观察。检查遍历深度注入及 author-note 的嵌套来源。outlet 只是条目可供宏取用，若最终消息来源未观察到它，不把“已激活”宣称为“模型已经读到”。没有导演结果时该字段不新增到旧检视 JSON。

## prefetch 与已有记忆

引用需同时满足两项条件：它出现在这个 helper 实际发送的标题目录中；它在下一主回合实际加载的执行视图中仍唯一可解析。模型猜出的书 ID 不会触发额外文件加载，也不能替换条目 content。不同书的同 uid 仍是不同身份；native 书中多个对象键重复 uid 的外部引用拒绝歧义，V3 重号沿原来的最后一项胜出。

外部激活只跳过关键词“命中”要求，继续经过禁用、trigger/角色、定时/递归、装饰器、组竞争、概率、预算及最终组装剔除。V3 主 regex 必须全部合法，空关键词按原 sticky 允许路径处理；不改原 constant、keys 或原件。旧空 external 输入保持旧执行与序列化形状。WI 的结果提供至多 64 条真实最终决策及溢出数；不是逐轮全量日志。`withoutEntries` 保留曾准入事实，只更新是否保留，不重新执行副作用。

本层只读现有 `memories` 表，没有新增完整记忆 CRUD 或自动记忆生成器。`entry_json` 按原生 ST entry 解释；仅在原生字段缺失时，`keywords` 补 key、`pinned` 补 constant。`expiresAt` 缺失/null 表示不过期，整数 Unix 毫秒在等于或早于捕获时刻时到期；其他形状明确诊断并排除。坏 JSON、包含非有限数字的原件保留不改；解析成功与否用独立标志，不占用原件未知字段。

有合格导演结果时，把该聊天全部有效、未过期记忆组成一次性的伪世界书，再与已绑定书按标准 WI 竞争；只有被授权的预取引用进入 external。伪书 id/stWorldName/world 为 `dshgo:memory:<chatId>`，uid 强制为原 row.id；原条目不能改写其身份。内部记忆用实际 book 对象身份识别，不把普通已绑定的 memory 来源书误认为内部表行，命名碰撞有诊断。临时书不进文件缓存，下一回合重新读取。

记忆沿标准 WI 展开宏；导演只读标题时不展开宏。因此它不是 literal 记忆系统，literal 合同适用于生成的 notes/beat/suggestions。现有 memories 行属于聊天而没有节点锚，本层不宣称记忆随分支隔离。没有合格导演结果时不额外加载这些记忆，不改变默认关闭的旧回合。

## 保存、关闭和维护

导演真源为既有 `agent_runs`，kind 分 `director.success/failure/tick/event`；本层不迁移 schema。最近结果按插入 rowid 排序，不受时钟回拨或交错 state 审计影响。成功输出与全部 event 行在同一 SQL 事务提交，事件 ID 由 runId 和序号派生；SQL 中途失败时整个成功发布回滚，旧成功/旧事件仍在。无法保存失败本身时，只给当前引擎一个明确 `director_result_not_persisted` 的临时失败状态，不伪装为已持久化。

这与设计稿“notes 放对话变量”的存储位置不同：独立审计行避免后台任务拿旧 metadata 覆盖较新的主回合状态，也避免 ST 变量宏把笔记带入主请求。完整数据库备份保存导演历史；ST JSONL 没有承载 agent_runs，不把私有笔记偷偷塞进导出正文或变量。这里的私有是请求与 UI 展示边界，本层未增加磁盘加密。

关闭自动会取消受影响的自动队列，显式手动继续；全局关闭尊重聊天显式开启。若全局设置文件/后续 SQL 失败，而内存开关已经关闭，仍执行相应取消后抛出原始存储错误。删除聊天或角色会取消相关 job 并排空其本地准备，再删除实体；晚模型回调不能复活被删数据。

close 先停止 admission，取消队列，等待已接纳任务及实际文件 IO 排空，然后才释放 SQLite、watch 与目录所有权。网络插件若不合作、让 subscription.cancel 永远不结束，本层不等待该 Future，接收器用取消信号结束并忽略晚事件；真实本地文件读取则仍归引擎所有，不能把取消 race 已结束当作文件操作已结束。备份见到任务或这些未排空的读取就返回 busy，不等网络、不取消导演、不创建 staging。备份捕获关闭 admission、压缩期重新允许正常操作的原 T24 合同不变。

## 模拟清单、验证与后续边界

纯协议测试使用构造 JSON；WI 用真实规则引擎和 regex worker；store 用真实 SQLite；门面用真实文件、节点树、状态、宏、组装器和 SQL，主要替换模型事件、clock/random。HTTP 测试同时包括真实 loopback 服务和 `http.MockClient`，经过真实 TavernModelClient 的请求构造、响应解析与工具累积；没有真实提供商账户调用。文件所有权用门控真实 File 读取，门控改变时序而不替换文件内容；SQL 发布失败用真实触发器。

覆盖包括默认关闭、A/B/C 时序、计数与重开、继续同节点、手动去重、32/33 上限、多个待启动任务 close、暂停 watcher、拒绝取消的订阅、删除/备份、终态 clock 错误、设置失败后的自动取消、源分支与修改、坏存储行、整个主 body 的隐藏字段哨兵、字面宏、目录授权、身份歧义、WI 各 gate、记忆过期与最终来源。源码登记、作者自查和非作者静态审阅都不等于 Dart 运行通过；精确补丁的 format/analyze/定向/全包/ST20 结果以交付 README/REVIEW 和 owner 回件为准。

T18 后续仍待做：剧本 outline/acts/tension 的章节、秘密/结局规则及即兴剧本（可拆 T18b）；非剧本秘密自动写隐藏状态；事件到固定规则动作的授权、幂等消费；剧中手机与导演点名消费者；离开时长触发；可选预生成开头；摘要/记忆创建管理。这些不是已经被 pending event 完成的功能。后续接入不能把模型 `events.data` 直接当规则 actor、任意状态路径或可执行代码，必须另有卡作者声明的固定动作合同。

# T18b：剧本章节与结局核心

本节补充前述待办中的章节与结局部分：根据卡的声明和正常主回合终态，在当前分支保存章节进度、结局解锁及审计。固定卡事件桥、动态秘密写入与揭示许可、即兴剧本等仍未编码；本切片不代表 T18 整体完成。代码叠加在 T18a 042 候选上，父层与本层的运行结论仍须分别以 owner 回件为准；编写本节时，本层 Dart format/analyze/test 均未运行。

## 卡声明与资源边界

声明位于 `data.extensions.dshgo.story`，外层 `dshgo.v` 缺失按 1，当前支持版本 1。例如以下是 `data.extensions.dshgo` 的内容；条件中的变量需要卡另行声明的 T17 DSH schema/值：

```json
{
  "v": 1,
  "story": {
    "outline": "仅供导演参考的私有提纲",
    "acts": [
      {"id": "arrival", "when": {"var": "ready"}, "minTurns": 2, "maxTurns": 5},
      {"id": "resolve", "when": {"var": "resolved"}}
    ],
    "tension": [-1, 1.5],
    "endings": [
      {"id": "peace", "title": "和平结局", "when": {"var": "resolved"}}
    ]
  }
}
```

`outline` 可选且须为字符串。`acts` 可省略或为空；每章须有唯一、非空的字符串 `id`，可有字符串 `title/goal`。`when` 默认 false，使用 T17 的有限 JsonLogic 子集；`minTurns` 默认 0，须为非负整数；可选的 `maxTurns` 须为不小于 minTurns 的整数，显式 null 无效。`tension` 若存在，须与 acts 等长且每项为有限数，不强制 0..1 或其他固定范围。

`endings` 可省略或为空；每项必须声明唯一、非空的 `id`、非空字符串 `title` 和 `when`。结局依声明顺序检查，每次可以解锁多个，在所继承的分支账本中各解锁一次。未知注释保留并诊断，不执行；它们仍参与定义指纹。

整份 story 的编码 JSON 上限为 **1 MiB UTF-8**，acts 和 endings **各最多 256 项**；超限定义不执行，不静默截成另一份剧本。条件沿用 T17 的表达式限制。编码长度与声明数不是进程总内存上限；解析、条件和结算仍在引擎所在 isolate 同步进行，没有手机性能测量结论。

## 开关、计数与结算顺序

用户设置中的 `director.enabled == true` 才授权自动故事结算，默认关闭，卡不能自行开启。每次终态在异步准备／文件写入结束后重读当前有效开关：全局关闭可撤销本次尚未提交的故事行为，chat 显式 true 仍覆盖 global false。`director.every` 只控制原有后台 helper 的频率，不控制章节计数；手动调用导演也不增加章节回合。

只有 send、regenerate、continue 的正常 `stop/tool_calls` 终态参与；无正文但合法的 tool-only 成功同样可以参与。sendOnly、narrate、impersonate、length、content_filter、null 终态、取消及异常不计数。继续同一 nodeId 是新的 invocation；不能按 nodeId 吞掉第二次计数。

未完成的当前章先把 `actTurns` 加 1，再判 min/max：未到 min 不推进；到 min 后，when 为真或已到 max 即推进，一次最多一章。进入下一章后计数归 0；最后一章通过后标记 completed，保留最后一章身份。已完成时不再加章内计数，但正常结算仍可检查尚未解锁的结局。条件求值错误会拒绝整份本次 story 候选，不能只保留其中已算出的计数／结局。

先完成 T17 本回合的工具操作、派生与规则，再把其最终有效 DSH 值交给故事条件；故事不再开启第二份状态 session，也不重复跑 T17 rules。没有 state.schema 时条件 data 为 null，不拿 ST local/global variables 冒充；不可校验的已存 DSH 或 runtime 保留并诊断，不当空文档继续执行。故事条件自身失败不撤销另一份合法的 T17 更新。

## 读取当前分支

```dart
final Map<String, Object?>? story = (await tavern.readDirector(chatId)).story;
// 原有 watchDirector(chatId) 也会随主回合提交、切支等变化给出新视图。
```

本层只给 `TavernDirectorSnapshot` 增加可选、深复制的 `story` Map，没有新增 Tavern 抽象方法；App 的现有门面转发不必增加一组 story 方法。没有 story（或 story 为 null）的卡返回 null。read/watch/export/preview 不评估故事条件、不写账本、不推进或发模型请求。

| story 字段 | 含义 |
| --- | --- |
| `defined/executable/valid` | 是否有定义、定义是否可执行、当前定义与保存账本是否可读；不等于最新结算已提交。 |
| `initialized` | 是否存在保存的 runtime；坏的显式 null/未来账本也算存在，须同时看 valid/issues。 |
| `fingerprint` | 当前完整规范化 story 与外层版本的定义指纹。 |
| `nodeId/automaticEnabled` | 当前选中节点，以及当前有效用户授权。 |
| `currentActId/currentActIndex/actTurns/completed` | 当前章身份、从 0 开始的索引、章内回合及章节完结状态。 |
| `currentAct` | 当前章的 id/title/goal/minTurns/maxTurns，以及声明时的 tension；没有可用章时为 null。 |
| `unlockedEndings` | 当前分支已解锁的结局 ID 列表。 |
| `changes/effects/issues` | 节点自己的故事变更／效果，以及定义、账本和节点已保存诊断；不是全聊天累计历史。 |

尚无 runtime 且定义合法时，视图提供首章、0 回合、空结局列表的**只读预览**，initialized=false；没有章节时预览 completed=true。即使某个 when 恒真，读取也不会解锁。调用者修改取得的嵌套 Map/List，不会修改 DTO 或保存状态。

## 分支保存、版本与审计

运行时是有效节点快照中的 `dshgoStoryRuntime`，沿既有 `extra.dshgo.tavernState` portable 载体保存、继承和导出；不借全 chat 的 director.tick 代替分支进度。regenerate 从目标父状态开始，continue 从目标自身开始，切支／重开读取该节点自己的账本。JSONL 保留节点载体，数据库 agent_runs 历史仍由整库备份保存，不混进 ST 正文。

账本记录 version=1、definitionFingerprint、当前章、计数、completed、unlockedEndings 和 lastInvocationId。坏形状、未来版本、重复／未知结局或定义指纹不相容时，保留原值并拒绝结算，不清空 ledger 重新解锁。指纹包括未知注释；编辑剧本后没有自动迁移／重置旧进度。

故事候选与正文、T17 状态、inspection、节点 own audit、`story.rules` 审计在同一终态 SQL 事务提交；提交成功后才发布内存结果。SQL 失败后的 partial 保存不能夹带先前回滚的计数或结局。一次被拒绝的故事结算也不覆盖节点原 `storyInvocation`、`storyChanges`、`storyEffects`：新拒绝从该次 `story.rules` 或 `inspection.director.story` 读取，不能把 readDirector.story 的旧成功效果误认为刚刚执行。数据库正常提交与条件拒绝是两个不同状态。

## 与后台导演的关系

helper 在既有输入中额外取得捕获源的 `storyProgress`，outline、章节条件和完整故事仍只给导演／用户剧透阅读，不自动拼进主提示。章节本地结算本身不调用模型、不发送工具结果第二轮，也不等待后台 helper；T17 的 update_state 工具资格和 T18a 的 direct 协议保持原合同。

沿 T18a 的祖先／源指纹检查通过后，剧本卡还比较当前上下文的阶段：定义指纹、有效性、当前章、completed 和已解锁结局。阶段不包含 actTurns；同章内增加计数不会**仅因阶段**使旧结果过期，仍须满足原源资格。换章、完结、解锁结局、定义或账本失效会阻止旧结果的 beat/prefetch 进入主回合。T18a 的旧成功行若没有捕获阶段信息，仍可读，但不能事后补造剧本上下文；无 story 卡沿用原行为。

本切片尚未消费 `director.event`，没有把事件名／data 映射成固定动作，没有自动写新秘密、创建记忆或执行手机／离开事件。已有事件仍是提案。源码注册、作者静态检查与文档均不代替 Dart 运行验收；本节不列未验证的通过数量或提速数字。

# T18：固定卡事件桥（literal v1）

本节接续 T18b 核心，把前文仍待处理的固定卡事件桥单独实现。导演仍返回 notes、beat、prefetch、suggestions、events 五个字段；其中 events 继续是原始提案。卡作者预先声明哪些名称可对应哪些固定动作，主回合在用户授权下检查条件、按当前分支去重，并随正文一起提交结果。本节描述的源代码与回归尚未获得 Dart 运行验收，不代表 T18 其余功能完成。

## 卡声明：名称匹配与固定字面动作

声明在 `data.extensions.dshgo.director.eventRules`，外层 `dshgo.v` 和 registry 的 `v` 均为 1。以下是 `data.extensions.dshgo` 的一个完整片段，配合原 T17 state 定义使用：

```json
{
  "v": 1,
  "state": {
    "schema": {
      "type": "object",
      "properties": {
        "clueKnown": {
          "type": "boolean",
          "default": false,
          "x-dsh-by": ["rules", "user"]
        }
      }
    }
  },
  "director": {
    "eventRules": {
      "v": 1,
      "rules": [
        {
          "id": "clue-discovery-v1",
          "name": "discover_clue",
          "when": {"!": [{"var": "clueKnown"}]},
          "once": true,
          "expect": [
            {"path": "/clueKnown", "exists": true, "value": false}
          ],
          "do": [
            {
              "type": "state",
              "ops": [
                {"op": "set", "path": "/clueKnown", "value": true, "why": "卡中固定的线索发现事件"}
              ]
            },
            {"type": "prompt", "text": "线索已被发现。下次回复可自然承接这个已保存的事实。"},
            {"type": "unlock", "kind": "achievement", "id": "first-clue", "title": "发现线索"}
          ]
        }
      ]
    }
  }
}
```

导演可以在原五字段中的 events 提出 `{"name":"discover_clue","data":"本回合的提案说明"}`。data 必须仍是字符串，只按原文审计；即使内容像 JSON、宏、路径或代码，也不会变成参数、条件或操作。上例真正写入的路径和值来自卡的固定 do，而不是模型的说明文字。prompt 文本同样保持字面值。

每条处理器必须有非空字符串 id/name、必填 when 和 do 数组；once 缺省 false。条件使用 T17 的有限 JsonLogic 子集。同 name 可对应多条，按卡中的顺序处理；重复 id 的所有处理器都禁用，其他合法处理器仍可执行。未知有限 JSON 注解保留并诊断。

expect 可省略；存在时是静态 JSON Pointer 前置条件数组。exists:true 必须显式带 value，null 是合法值；exists:false 不得有 value。它在该处理器第一个动作前比较当前真实存在性和值，失败整条待处理。T17 操作中的 from 仍只记录冲突，不是拒绝旧状态的 CAS，也不能代替 expect。

do 沿用 state、prompt、notice、event、unlock 闭集。state 以原 rules actor 执行，继续受 schema、祖先/子项权限、hidden 与派生字段规则约束；不增加一个模型可自报的 actor。输出 event 是新的效果意图，不在本地递归匹配处理器，也不因此再发 helper 请求。unlock 保存意图及卡的 id，并不等于已经有外部消费者完成成就 UI、手机、记忆或相册操作；它也不直接改写故事 runtime。

## 目录能力与用户开关分开

新 helper 在真实准备阶段捕获 `eventCapability`：版本、literal 模式、registry 指纹、state 定义指纹或 null、合法 handler id 集合及当时自动开关值。它来自当前卡与宿主设置，不能由模型输出补写。发布阶段只保存已经捕获的能力。旧成功行没有该能力时仍可阅读，不能在打开新功能后给它追认权限；不合格能力只阻止事件执行，不必撤销原本合格的 beat/prefetch。

显式手动在 director 关闭时调用 helper，仍可记录它实际见过的固定目录和 `automaticEnabledAtCapture=false`；这不是自动执行授权。新处理器必须在主回合准备阶段捕获该合格批次，且在正常终态同步读取到有效 `director.enabled == true` 才执行。聊天显式设置覆盖全局，卡不能自行打开增强或增加模型费用。

准备时固定定义、批次和允许集合。处理中关闭会撤销尚未执行的新处理器；从关闭改为开启，只能授权这次已经捕获的合格批次，不额外搜索后台刚完成的结果。含任意 state 动作还要求原回合已获 T17 session 授权，且终态 `stateEnabled != false`；否则整条处理器待处理，不能先发 notice/prompt 再丢掉 state 部分。

没有 state schema 的卡可以使用纯效果处理器，条件 data 为 null，不伪造空 DSH 文档。有有效 schema/保存值但状态自动写关闭时，纯效果条件只读真实 DSH，不初始化、不 derive、不跑 ordinary rules；坏 DSH 不能降格为 null 继续执行。事件桥本地结算没有模型请求，也没有工具结果第二轮，原导演调用计费和用户开关合同保持。

## 只处理已捕获的最新批次

主回合只取准备时捕获、通过 T18a source/path/card/persona 及 T18b story phase 条件的最新成功结果对应事件。会核对 capability，并读取实际持久化的 director.event 行，逐项匹配 run、原输出序号、来源、name/data 与事件身份；缺失或坏记录不从输出文本补造。

本切片不补捞更早批次的 pending，也不把主请求开始后才发布的 helper 事件加进本次。终态不因本回合自己的 continue/checkpoint 更新源节点而重新否定已准入批次；公开切支、编辑、删除仍通过既有取消与排空流程使正在进行的回合停止。处理器的 when/expect 则在结算时读真实当前候选，不能把源指纹通过理解成状态条件永远为真。

## 一次状态会话与资源预算

正常主回合的顺序是：模型状态操作 → derive/ordinary rules 一次 → 命名事件处理器 → 最终验证和差异 → story → 同一终态 SQL。命名处理器沿用原 StateSession，后处理器能读到前处理器已接受的状态及即时派生值。事件不重开 session，不重置 x-dsh-step 的原始基线，也不在事件之后重跑 ordinary rules。

| 边界 | 本切片约束 |
| --- | --- |
| 事件 registry | 整份编码 JSON 最多 1 MiB UTF-8，rules 最多 256；超界整定义不执行，原值保留。 |
| 原始提案 | 沿用 direct 的最多 32 项、名称最多 1024 UTF-8 字节、data 最多 16 KiB，以及原五字段总输出 256 KiB；纯层另核该事件数组本身不越界。 |
| state ops | 模型、普通规则、命名事件共用原每 invocation 256 次尝试额度。 |
| actions | 普通规则与命名事件共用每 invocation 256 次；独立纯效果入口受同上限。 |
| 效果字节 | 共用 256 KiB UTF-8 JSON；计入纯层实际 envelope 的动作字段、source、eventId/runId/handlerId/actionIndex。宿主之后附加的固定长度 effectId/invocationId 不计入此上限。 |
| handler 判定 | 每 invocation 最多 256 次；未匹配、已消费或未授权判定也占此数，超限后缀保留为待处理。 |

预算 metadata 不能重置以上计数。这些是一次编译或结算的边界，不是完整聊天历史或进程总内存上限；不会为保持常量空间而裁掉旧消费账本、重新允许重放。没有手机性能数字或提速验收结论。

一条 handler 至少有一个被接受的操作（含合法 no-op）或效果才消费。前缀已接受、后缀失败时，消费该 pair，once=true 也随之记账，防止重放已接受的增量；全部拒绝、空 do、when/expect 假值不消费。普通状态最终 derive 或验证失败，新事件候选全部拒绝；另一方向，坏事件账本仅阻事件桥，不撤销合法 T17 更新。

只有正常主回合 stop/tool_calls 终态才能提交新消费；length、过滤/null 终态、取消、网络或 SQL 失败、impersonate、手动追加、read/watch/export 都不提交新处理器的消费或效果。原 finish 和无事件序列化保留；同一 session 封存后只允许同批重入，不能追加另一批绕过原预算。

## 分支账本、历史 once 与独立提示队列

运行时是 portable 节点快照顶层的 `dshgoDirectorEventRuntime`，含 version=1、consumed 的 `{eventId,handlerId}` 结构化对、firedHandlers 及 pendingPrompts。未知键与历史条目保留。坏形状、未来版本或重复身份只读并诊断，不自动清空。去重按事件/处理器二元组，once 按稳定 handler id；修改 handler 内容或 registry 指纹不会清除历史 once，表达新语义应使用新 id。

后代继承已消费 pair 后不会重做；从未消费父节点走兄弟分支可以独立执行。continue 从目标自身继承，再生成从父路径开始。JSONL 保留 portable 账本，但没有原 agent_runs 提案就不能凭 ledger 或旧输出补造执行；整库备份保存数据库历史与账本。原 director.event 永远保持原始 pending proposal，不能用全局 executed 让另一个分支丢掉自己的机会。

每个效果有宿主统一的 effectId/invocationId，原 unlock 的 action.id 仍是卡的结局/成就身份，两者不混用。事件 prompt 进入独立 `pendingPrompts:[{id:effectId,text,...来源}]`，不再次加入 T17 的旧提示队列；组合 StateResult 已包含事件效果一次，不能重复 append。

prepare 有效 director 开关为 true 时才 offer 这些提示；注入使用 `expandMacros=false`。宿主只记录最后实际请求里出现的 prompt id，正常终态才消费。因为预算而排除、取消或 length 结束的提示保留。提示已经真正送出后再关闭 director，正常终态仍确认这次已经发生的送出，同时不执行新的 handler。历史已发送 prompt 的确认独立于新 handler 候选；新普通状态候选被拒绝也不能把已发送事实伪装成未发送。原 T18a 在 off 时仍可使用合格旧 beat/prefetch 的行为不变。

## 同一事务与只读分支视图

正文、T17 最终状态、事件 ledger/queue、story、节点 own audit 和 `director.event_apply` 批次审计在原终态 SQL 事务内提交。每条原提案及其 handler 判断在批次 receipts 中单列；实际回复节点作审计锚，原 source 身份另存。SQL 失败后的 partial 使用原 turn.currentState，不夹带候选消费、once、效果或队列；continue 失败保留旧成功 own audit，本次失败单独可查。

```dart
final Map<String, Object?>? eventRules =
    (await tavern.readDirector(chatId)).eventRules;
// 原 watchDirector(chatId) 返回相同 DTO 的当前分支视图。
```

只给 TavernDirectorSnapshot 新增可选深复制 eventRules Map，没有新增 Tavern 抽象方法或要求 App 增加一组事件转发。没有定义也没有保存账本时返回 null；有旧账本时仍能展示与诊断。read/watch 不运行条件，不消费，不调用模型。

| eventRules 字段 | 含义 |
| --- | --- |
| defined/executable/valid/initialized/fingerprint | 当前 registry 与保存账本的只读状态；initialized 只表示已有账本，不等于它有效或刚提交成功。 |
| nodeId/automaticEnabled | 当前选中节点与当前有效用户开关。 |
| consumed/firedHandlers/pendingPrompts | 当前分支继承的消费对、once 身份及未确认提示。 |
| receipts/effects/pendingConsumed | 当前节点自己的事件审计与已确认提示身份，不是全聊天累计执行列表。 |
| issues | 当前定义/账本诊断与节点已保存诊断。 |

`readDirectorEvents` 继续返回原始提案：合法行 status=pending，坏/未来行 unavailable。要判断某条提案在当前分支是否执行，看 eventRules 的消费对及 receipts，不能只看原提案 status。一次新拒绝不覆盖节点旧成功审计；该次拒绝从 `director.event_apply` 或 `inspection.director.eventRules` 读取，不把旧 effects 误读成又执行了一次。

本切片没有给 events.data 增加动态参数协议，没有自动创造/绑定新秘密或“先落地再揭示”许可，也没有实现手机、记忆 CRUD、相册和其他外部消费者。固定 state 标志可以让后续同一终态的 story 条件成立，固定 unlock 仍只是持久意图。验收须覆盖纯会话预算与身份、真实来源/开关/请求时序、分支/portable、提示入选、取消与 SQL 回滚；本层运行结论和最终登记总数以精确冻结材料与 owner 回件为准。

# T12 A：导演读取与订阅成本修复

本节对应查 bug 轮转中的长对话性能、并发与测试错误路径。只调整内部存储读取及现有 `watchDirector` 的订阅生命周期；没有新增 Tavern 抽象方法、改变 direct 五字段协议或引入新的模型调用。以下是源码合同，Dart format/analyze/test 的验收以本层精确冻结补丁和 owner 回件为准。

## 审计查询与 schema6

数据库由 schema5 逐级升级到 schema6，只增加 `agent_runs(chat_id, kind)` 索引。沿用原迁移事务；失败整条升级回滚，不改写既有节点、审计 JSON、未知列、扩展表或 FTS 内容。新版本数据库不能由只认识 schema5 的旧程序直接打开。backup 外层格式不变，其数据库版本字段仍准确记录实际 schema；旧备份在独立恢复 staging 中升级，不修改输入 ZIP。

内部 `agentRunsByKind` 按 publication 的 SQLite rowid 倒序读取，保持原先的同 chat、同所选 kind 的 exclusive cursor 规则。它不改用 `at` 排序，时间回拨也不会重排发布顺序。单 kind 通过等值索引查询；多个 kind 各取前 N 个原始行，再合并排序、截成全局前 N，最后只解码选中的行。自身 kind 内排在 N 之后的行，已有至少 N 个全局前驱，所以不可能进入全局前 N。

坏 JSON 或不支持的已选记录仍占它的发布位置，并保留原 unavailable 语义；不能跳过坏行去捞一个更早的成功。未进入全局 N 项的候选不会因解码产生额外可见错误。负数、零 limit、空 kind 集合与失效 cursor 的既有参数检查顺序保留。普通 `agentRuns` 的旧时间排序合同没有改动。

此方案最多取 K×N 个原始候选，K 为所选 kind 数；不能称任意 K/N 下恒定内存。索引查找及倒序范围扫描的宿主 SQL 探针与全局查询对照是正确性/计划证据，不是 Dart binding 实跑或目标手机速度测量。

## 来源成员判断只读身份

`ChatStore.ancestorIds(chatId, leafId)` 是内部存储接口，返回指定叶子的完整根到叶 id 链，不使用消息路径的默认 60 条窗口。它复用原祖先 CTE 和父链/visited 校验，只投影 id、parent_id；允许 inactive 分支和 hidden 节点，仍拒绝环、断父、foreign-chat 或 softdeleted 祖先。null 叶仍先验证 chat 存在。

导演资格检查只用这份窄结果判断真实 source 是否属于当前路径。真正 source 仍由原 `_directorSource` 完整重读，并使用相同 wire 的全文/状态指纹；当前叶的 state、story phase 和事件视图仍各自验证。修改 source 的流式影子正文，即使 tree_revision 没变，也会让下一次读取发现失效；恢复原字节后可重新取得资格。

这里有一项明确的坏数据行为变化：无关后代的 extra/original JSON 损坏，不再仅因成员判断需要建立完整 DTO 而撤销仍合法的 source。窄接口不解析也不修复该文档。完整 `historyTo`、`StoredNode` 读取、导出及主回合历史组装仍执行原文档解析；它们不会因此忽略坏 JSON。source 本身坏文档与损坏的身份链仍阻止导演输出取得资格。

## 同 chat 共享 watch，观察者独立暂停

每次公开 `watchDirector(chatId)` 仍返回单订阅 stream；真正监听后，加入该 chat 的共享 hub。hub 只有一份 changes 订阅、dirty 标记和刷新循环，使用 microtask 合并当前批次通知，没有 timer 或 debounce。每次真正刷新仍读取当前存储和角色记录，不把上一份快照当作可信缓存。

每个观察者独立 pause/cancel：一个暂停不阻止其他观察者；全部暂停时只记 dirty，不启动新读取。已经接纳的读取继续排空，但不给暂停或取消的观察者加入新事件。resume 与新 listen 都要求 fresh read，即使这期间没有收到通知，也不直接重播旧快照。暂停之前已经进入 Dart stream 队列的事件不能撤回；恢复后可能先看到这些既有事件，测试与调用方不能把它们误认为暂停期间新增的快照。

最后一个观察者取消会同步退役这一代 hub。新监听可立即创建后继；旧读取或异步取消晚完成，只能清理自己的 hub，不能从 map 删除后继。正常一代 hub 内只有一个实际刷新读取；旧 hub 尚在排空时可与后继的首读重叠，不能把它夸大为跨世代永远只有一次原生操作。

所有实际读取在开始时登记到引擎操作排空集合。UI 取消不代表底层文件读取已经完成，因此引擎 close 仍等待真实 IO；它不等待暂停 UI 消费 controller 的 done。backup capture gate 在登记读取之前等待，避免 backup 排空一个反过来等待它自己的操作。没有 gate 时，从检查到登记之间没有 await，保持现有准入顺序。未知 chat 的错误仍通过 stream 报告，后续刷新可重试；read/watch 不初始化或结算 state/story/events，也不调用模型。

`TavernDirectorSnapshot` 已有的嵌套 getter 副本规则继续生效，共享一次完成的快照不把可变 story/eventRules 对象暴露给其他观察者。角色详情缓存本来就能去重冷文件 IO，因此测试中的单次文件读取只能证明相应 IO 生命周期，不能单独证明 SQL 或 hash 的执行次数。

## 验证边界与剩余成本

新增回归使用真实 SQLite/临时文件/engine、受控模型、实际角色文件 IO 门；迁移 fixture 来自父层真实 V1→V5 SQL，不把 V6 库降 user_version 冒充旧库。覆盖发布顺序、分页、坏记录、迁移回滚、备份 staging、祖先损坏边界、来源身份，以及共享订阅的暂停/恢复/取消/关闭/备份交错。测试的精确登记数与运行结果写在本层交付材料，不从源码存在推导已经通过。

本层减少同 chat 多观察者的重复读取、无关当前后代文档物化和按 kind 查询的扫描成本。每次需要刷新的 source 前缀仍完整读取/编码/hash；主回合历史组装仍读完整文档。没有提交日志、依赖游标、资格结果缓存、持久 hash 或增量 hash；不能称长对话读取已经成为常数时间，也没有手机延迟、帧率、内存或加速倍数结论。

# T12：空选中路径的失败回滚

当前路径为空而消息树仍保留旧根，是公开 API 可以产生的合法状态：对根 A regenerate 得到根 B，再单条删除 B，当前两个选择指针为空，A 仍可供用户重新选择。从这个状态 send 时，若本回合无输出并进入原有空回滚分支，硬删临时根会触发普通删除的邻兄弟 fallback；旧实现只恢复非空的旧叶子，因此可能误选回 A，并使运行时变量与按当前路径读取的变量不一致。

空回滚现在先恢复原有 remembered child choices，再根据回合开始时的选择恢复非空叶子或显式清空本 chat 的两个选择指针。内部 `clearSelection` 不遍历或解码消息，不修改节点、记忆后代、物理状态或其他 chat；已经空选时不推进版本、时间或通知。它与临时节点清理、变量恢复和失败审计处于同一现有事务中，后续 SQL 失败时一起回滚。

没有新增 Tavern 公共接口或 schema，也没有改变普通 `deleteFrom` 的 fallback。成功回合及已有输出而保留 partial 的回合继续保留新路径。原来空选时，对 inactive 节点 continue 或 regenerate 的无输出失败也恢复空选；既有正文和记忆后代保留，随后显式选择旧根仍可恢复原分支。continue 的既定失败结果可以返回原 target 作为 partial，这不表示本次新输出已经提交。

新增回归由公开操作构造前置，使用真实 engine、SQLite、文件和受控模型，覆盖网络失败、stop、provider 调用前的准备失败、重开、变量一致性、成功与 partial 对照。SQLite 只读快照核对幸存节点和状态原始行；另有存储测试核对空选 no-op、真实 SQL 故障下的外层事务回滚及通知。运行结果和旧实现负对照以本层 owner 回件为准，测试文件存在不代表已经实跑。

# T12：文本字段开头的 U+FEFF

JSONL 字符串中的 U+FEFF 是内容。当前固定的 sqlite3 3.9.1 在读取 TEXT 列时调用 Dart 的 UTF-8 解码器，后者会丢弃输入开头的 BOM。因此正文、说话人或 reasoning 即使按正确字节写进数据库，读回时也可能少一个字符；随后导出或 continuation 会使用这个变短的值。文件最开头的编码标记仍由 JSONL 文档编解码器按原合同处理。

读取保护沿用 T20 已有的 `source_text` 方式：SQL 投影先在需要保真的列前加一个 U+0001，Dart 解码后仅移除这个保护字符。节点的正文、说话人、reasoning 和流式影子，聊天标题与列表末条正文，以及预设名称均使用这一方式。完整节点读取共用投影，每个正文列只取一份；只读祖先身份的查询仍保持窄投影。用户原有 U+0001、一个或多个首 U+FEFF、内部 U+FEFF、空串、null、中文、emoji 和 CRLF 各自保留。

更新时也使用已去除保护字符的真实值，包括聊天未传新标题的回写、流式正文提升及 reasoning 的回退。单纯修改消息 metadata 不会顺带提升流式正文。数据库保存的仍是原始文本，保护字符只存在于 SELECT 结果，不进入持久数据；schema、全文索引和 JSON 原件沿原合同工作。此前已经丢掉首字符并回写的内容，无法从缺失信息自动恢复。

回归使用真实 SQLite 和公开 import/path/export/continue 路径，核对字段内容、分支与重开，并通过 BLOB 读取核持久 UTF-8 字节。既有文档级 BOM 与预设 sourceText 用例继续作为边界回归。新的消息负对照和完整运行结果以本层 owner 回件为准；030/031 对旧 sourceText 的实测只佐证底层原因及已有保护策略，不能代替本层测试。

# T18：固定槽动态秘密（v1）

本节接续前面的动态秘密待办，实现有限的“先保存事实，再按当前条件提供给主模型”闭环。它只用于已经具有有效 DSH schema 和保存值的非剧本卡。代码与新增回归尚须精确冻结后的 Dart format/analyze/test 验收；本节不把源码、静态审阅或 SQL 夹具探针当作运行通过。

## 开关、费用与调度

```dart
await tavern.setSettings({
  'director': {'enabled': true, 'secretsEnabled': true, 'every': 2},
}, chatId: chatId);
```

`director.secretsEnabled` 是额外的布尔开关，缺省关闭；字符串 true 或卡内同名字段不授权收费。还要求有效 `director.enabled == true` 且 `stateEnabled != false`。一次到期的自动 tick 先接纳原 ordinary `direct`，有可用固定槽时再接纳至多一次 `propose_secrets` 请求。两类任务使用同一聊天 FIFO 和 32 个拥有中任务上限；最后一个名额给 ordinary。秘密任务可能延迟后续普通任务，新增调用的用量按 provider 返回记录。手动 `runDirector` 仍只有原 ordinary 模式，不暗中多跑一次秘密 helper。

关闭秘密会取消已接纳的秘密任务。准备和发送前仍核当前授权；受保护旧卡或人设已经改变时不发送其旧快照。普通手动导演在秘密关闭后仍可运行，但使用遮蔽后的载体，不能继承已经撤权的事实或笔记。卡字段、设置和保存源的完整身份检查不等同于对自然语言剧情一致性的证明。

## 声明与固定权限

以下是 `data.extensions.dshgo` 的最小完整例子：

```json
{
  "v": 1,
  "state": {
    "schema": {
      "type": "object",
      "additionalProperties": false,
      "required": ["entity", "secret", "reveal"],
      "properties": {
        "entity": {"type": "string"},
        "secret": {
          "type": ["string", "null"],
          "x-dsh-hidden": true,
          "x-dsh-by": ["rules", "user"]
        },
        "reveal": {"type": "boolean"}
      }
    },
    "init": {"entity": "npc-17", "secret": null, "reveal": false}
  },
  "director": {
    "secretSlots": {
      "v": 1,
      "slots": [{
        "id": "past",
        "path": "/secret",
        "entityPath": "/entity",
        "unbound": {"exists": true, "value": null},
        "bindWhen": true,
        "release": {
          "id": "tell-past",
          "audience": "currentCharacter",
          "when": {"var": "reveal"},
          "template": "角色此刻可以引用的事实：{{fact}}"
        }
      }]
    }
  }
}
```

槽名与路径必须唯一。目标是非根、固定 object property 链的 hidden string 叶，可额外允许 null；目标及祖先须 rules 可写、非 derived、非不支持子树，所有实际父容器已经存在。首版不接数组、动态路径或创建缺失父容器。`entityPath` 当前须指向非空 string 身份，且不能和目标重叠。可选字段可用严格的 `{"exists":false}` 表示尚未出现；`{"exists":true,"value":null}` 则必须匹配 schema 允许的显式 null，不能把非法 null 当成空槽。已经绑定过的 slot/entity 键跨声明修改仍保持已绑定。

声明最多 1 MiB UTF-8 JSON、256 槽，条件沿现有 JsonLogic 的 4096 节点等限制。未知字段保留并诊断，没有额外执行语义；一个槽非法会使整份声明不可执行，能恢复的合法 Pointer 仍用于保护。模型只能调用固定工具，返回精确的 `notes/facts`，每项 fact 仅有授权槽 `slotId` 和 string `value`。一次最多 8 项、每值最多 16 KiB、整个输出最多 256 KiB；不能提交路径、实体、条件、规则或 state ops。空 facts 是有效的“没有建议”，不会绑定。

秘密 helper 可读它的完整固定上下文；其 notes、正文及 reasoning 都不变成 ordinary notes 或聊天正文。helper publish 只写 `director.secret_proposal`／`director.secret_failure`，不会后台修改节点状态。

## 接纳、事务与单会话结算

主回合开始监听时冻结最近一份持久提案；其后任何文件／世界书等待期间晚到的提案，都不能加入该回合。绑定要求提案来源正是本次上下文和当前选中的物理叶，来源、卡、人设、完整能力和当前 entity 未变，且该锚没有任何物理孩子，包括软删孩子。inactive continue、regenerate 等不合条件时保留普通生成行为；不把 regenerate 的目标当作其父上下文。

主回合只开一份原状态 A 的 StateSession。秘密 prepare 对整批先核真正的 absent/null CAS，再通过原校验器尝试写入；所有值必须精确等于提案，完整候选有效且实际 A→B 差分恰好只有获准叶。实际 derive 旁支或 clamp 改变结果会拒绝整批。拒绝恢复候选、writer 和 structural 记录，但不退还操作预算、收据序号或尝试记录。普通规则和固定事件不在 prepare 中执行。

接受的 B 与 portable 账本及独立 `director.secret_bind` 审计，写在同一个 FULL SQL 事务里，早于用户新节点、宏、世界书和 provider 准备。使用原始 raw extra，不重写旧 `node_states` checkpoint/delta；`_stateAt` 的既有 portable 优先级生效。COMMIT 前构造持久 B、continue 恢复目标 B、可变生成 G 三份隔离对象；COMMIT 成功后立即同步采纳引用，先于通知及耐久级别恢复，不在该钩子里读库、解析或 await。内部 transaction 钩子只允许外层同步采纳；可辨识的异步 hook 在 operation 之前拒绝。

接受 prepare 后若后续准备或 SQL 失败，本次生成结束，不另开一份会话绕过预算。COMMIT 前失败保留 A；COMMIT 后准备失败、空 continue 回退、部分正文、length 或普通终态 SQL 失败都保留已提交 B。绑定审计独立记录 A→B，正常终态继续同一会话执行 model → ordinary rules → 固定 handlers → seal → story，并记录真正的 B→C 差分及该阶段 writer。普通规则可以再合法改写秘密叶，此时报告 old=B/new=C，原绑定 valueHash 不被偷偷改成 C。结算开始后抛错，失败路径只写失败审计，不再次 apply/finish。

## 输入保护、笔记继承与释放证据

保护路径是当前声明与 portable 账本的并集，与秘密开关是否开启无关。普通 helper 的实际输入省去整个 stateDefinition 与 director.secretSlots，并在 state.value 副本删除受保护叶，所以 raw init/default 不会另带一份事实。不可可靠解析的账本关闭相应自动载体；保留的数组 Pointer 若无法按固定 object 语义遮蔽，也不回退为发送原值。完整来源认证仍使用未删减的源身份，不能用遮蔽后的值替代来源指纹。

主模型状态摘要先遮蔽，再走原 T17 投影。旧 ledger 路径不再能证明属于当前 hidden 区域时，保守关闭自动 update_state 工具；包括可选父对象缺失而当前投影无法证明 hidden 的情形。用户 `readState` 仍能读取剧透原件，hiddenPaths 加入可恢复的 ledger 路径；手动 `setStateValue` 继续受用户权限控制。手动改值或 entity 会使原 release 证明失配，不自动重绑或重新签发。

释放每次核当前定义、entity、角色、值指纹、portable binding，以及同 chat 仍存在且逐项吻合的 committed bind 审计，再求当前固定 when。文本只按字面替换 `{{fact}}`，其他宏标记原样保留，整段 `expandMacros=false`，仍参加正常预算。真正调用 provider 前再次核当前开关、人设／卡修订、请求节点保存值和持久证明；已入体的授权撤销会使请求在发送前失败。

普通导演记录实际获得的保护策略及公开事实身份／值指纹。前后任一份输入涉及秘密保护时，previousNotes 除来源／祖先／卡／人设资格外，还要求与本次实际知识集合精确相同；源和当前分支的释放集合取交集。两侧都没有秘密策略时，保持旧普通笔记的继承语义。相同知识门参与 read.stale、主回合 beat/prefetch 以及固定事件执行资格。旧 source 不变而后代撤销 release 条件，仍应使旧知识失效；不能只比较 slot 集合或 policy 名字。准备期间撤权后已经组装的导演载体也不能越过 provider 前检查。

`TavernTurnInspection.state.secrets` 区分 offered、included、attempted：第一项保留本次提供的字面片段和身份；第二项只含最终请求来源实际保留的片段；第三项表示客户端尝试调用 provider，既不证明服务端收到，也不自动标记角色 knownBy。预算排除只有 offered；进程在终态持久化前崩溃可能没有完整尝试日志。绑定提案、失败与独立 bind 回执通过已有 `readAgentRuns` 读取，不增加 Tavern 公共方法或数据库 schema。

账本保存在节点 `dshgoSecretRuntime`，原始未知字段保留。JSONL 可携带该账本和私密值，但没有 agent_runs 的同 chat 证明时只能继续保护，不能自动 release；完整备份同时保存数据库证明，恢复后仍逐项核验。read/watch/export 不初始化、绑定或推进所谓知情进度。

## 本切片的边界

固定卡的 ordinary rules、derive、模板和事件动作仍是作者明确允许的其他通路；本功能不审查任意自然语言，不撤回历史正文或角色已经读到的内容，也不证明 helper 创造的事实在语义上绝无矛盾。尚未实现无 schema 自动建状态、任意 JSON 动态事实、群像独立视角、背景即时绑定、即兴剧本、手机／相册和记忆管理。首版只提供上面固定槽、持久绑定和当前释放许可的有限合同。

永久回归分别覆盖纯 CAS／预算／B→C、真实 COMMIT 故障、共享队列／取消／旧卡及人设、真实绑定与空回退、主请求字面片段与预算、当前知识撤权、JSONL／整库恢复。各文件完整审阅、精确补丁身份、测试总数、旧产品对照和 owner 运行结果以本层交付材料为准。

# T12：SSE 尾帧与正常 HTTP EOF

SSE 事件必须由空行结束才会交给模型响应解析器。HTTP 正文正常结束时，尚未结束的尾帧会丢弃；即使其中已经出现完整 JSON 的 `finish_reason` 或 `[DONE]`，也不能作为完成证据。LF、CRLF、CR 的行结束语义相同，UTF-8 与 HTTP 分块边界不影响事件边界。这与 [WHATWG SSE 解析规则](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation) 及本项目固定 ST 1.19.0 的事件解析器一致。

此前完整事件中的正文仍然保留。如果从未收到完整 finish 事件或完整 DONE 事件就遇到 EOF，回合以 `network / stream_ended_before_finish` 失败，已收到的正文作为 partial 保存；接纳 HTTP 2xx 后不会因此重发模型请求。完整 finish 事件之后缺少 DONE，仍按已有合同完成并保留结束原因；完整 DONE 事件没有提供结束原因时，仍允许完成并返回 null。

对应回归使用正常结束且 Content-Length 精确匹配 UTF-8 字节数的本地 HTTP 响应，覆盖未完成尾帧、只多一个 LF 的完成对照，以及真实门面的 partial／检视持久化。Node 上运行固定 ST 原件的探针只证明上游 JavaScript 解析行为；本层 Dart 编译、测试及旧产品负对照的实际结果，以精确交付材料和 owner 回件为准。

# T12：人设库打开与缺失判定

打开人设库先实际读取 `personas/index.json`。访问或读取失败会使开库失败，不用空人设替代已有资料；只有明确的路径缺失错误且后续查询仍未发现实体，才初始化内存中的空库。成功读取保留原有 BOM、JSON 版本及字段验证；目录等不能作为人设文件读取的路径继续报错。初次缺失不提前创建人设目录或文件，后续成功保存才写入。故障解除后可重试打开，继续读取原已提交的人设与默认选择。

# T12：SSE 的 UTF-8 替换解码

SSE 按 [WHATWG UTF-8 解码规则](https://encoding.spec.whatwg.org/#utf-8-decode)将非法或未结束的字节序列替换为 U+FFFD，再处理行、字段和注释，与固定 ST 1.19.0 的默认 TextDecoderStream 行为一致。因此 keepalive 注释中的坏字节不会中止其后完整的合法事件；data 字符串中的坏序列则保留为替换字符。解码器跨 HTTP 分块保留状态，不拆坏正常多字节字符。替换后的 data 仍须通过 JSON 验证，坏 JSON 仍以 `server / invalid_response_format` 失败且不重发已接纳请求；事件仍须空行结束，EOF 继续丢弃未完成尾帧。

# T12：正则库打开与缺失判定

打开正则资料库先实际读取 `regex-library.json`。访问或读取失败会使开库失败，不把已有资料当作空集合；只有明确的路径缺失错误且后续查询仍未发现实体，才按首次缺失处理。故障解除后可重试打开，原先导入的记录、原文、未知字段、诊断和报告继续保留，后续导入仍追加到已有集合。首次缺失不创建正则文件，成功导入才保存。

该路径若是目录或其他不能作为正则文件读取的既有实体，现在会使开库失败；旧实现曾因存在性查询返回 false 而把目录误当空库，这是本次明确收紧的错误边界。读取成功后的 JSON、版本和记录验证沿用原行为，非法内容仍返回错误。

新增回归使用公开导入、真实 SQLite、文件、正则 worker 和重开；只在目标路径注入查找或读取故障，并以恢复后的资料保留作为主要断言。Dart 编译、测试及旧产品负对照是否通过，以本层 owner 回件为准，宿主文件系统探针不替代这些结果。

# T12：random/pick 候选项的空白

现代宏的单参数候选列表，在按 `::` 或逗号拆分后使用 JavaScript 的空白集合清理；legacy 只清理逗号分支，含 `::` 的旧分支继续原样保留边缘空格。U+0085 NEL 保留，NBSP 和 BOM 等 JS 空白仍被裁掉；转义逗号、空候选、现代真正多参数的直接选择以及原随机/种子算法不改。不把这项修复扩成所有宏参数或卡字段的统一 trim。固定依据为 ST 1.19.0 的 `core-macros.js` 单参数列表助手和 `macros.js` random/pick 回调。

两模式各新增一个公开 sendOnly 回归，检查单候选 NEL、NBSP/BOM、内部 NEL、legacy 双冒号分支及 pick，再重开核已保存正文；不触发模型请求。固定 ST 原函数的 Node 观察不是完整现代 parser、ST UI 或 Dart 执行，本层实际运行仍待精确补丁回件。

# T12：roll 的有限整数算术

在原有骰子语法和 `int.tryParse` 可解析范围内，`roll` 的每骰 `1 + floor(random * sides)`、骰子和及最后一次 modifier 加法均按 binary64 运算，输出复用现有 JavaScript 数字字符串规则。先从零累计骰子，最后才加 modifier：`1d1+9007199254740992` 输出 `9007199254740992`，`2d1+9007199254740992` 输出 `9007199254740994`。现代和 legacy 共用此 helper；原语法、随机有效性检查和每骰一次抽取保持原有合同。

语义依据为固定 ST 1.19.0（`7e8663cd9c184a550b37238218bdd32c6efc68e9`）的 roll 注册和锁定的 droll 0.2.1，已读 [droll v0.2.1 原件](https://github.com/thebinarypenguin/droll/blob/v0.2.1/droll.js)；tag 源码读取不等同于 npm tarball 字节验证。本层不扩大公式可解析范围，也不新增巨量骰子、任意长度或 Infinity 政策。

新增两个回归登记：有限纯宏数值／调用次数控制，以及真实现代 `sendOnly` 的完整正文、公开路径和重开持久化。公开核心在普通 `1d1+3→4`、模式、存储和无模型调用前置之后比较完整返回文本；断言失败时也登记真实关闭和目录清理。编译、测试、旧产品首差异和清理是否实际通过，仍待精确候选的 owner 回件。

# T12：datetimeformat 的字面格式与展开顺序

时间格式先展开现有 en／zh-cn 长格式别名，再解释完整格式串的基础 token，与固定 ST 使用的 [Moment 2.30.1 formatter](https://github.com/moment/moment/blob/2.30.1/src/lib/format/format.js) 顺序一致。反斜线保护整个基础 token：`\MM` 输出字面 `MM`，`\YYYY` 输出 `YYYY`；受保护的长别名先保留，再交基础词法，因此 `\LLLL` 输出 `LLLL`，而 `\LTS` 的末尾 `S` 仍输出毫秒首位。相邻格式也在展开后共同分词，例如 2024-02-29 的英文 `LY` 输出 `02/29/02024`。

方括号按原件的贪婪字面规则去掉外壳，内部反斜线保留；其它字面 token 中的反斜线按原件移除。反斜线分支使用原 Moment 的完整 token 边界，因而 `\gggggg` 可正确保留六个字面字母；该转义分支本身不增加未实现 token 的数值输出能力。普通输出按明确支持的 token 集处理，新增的有限 era 族见下文。现有固定长格式表不再含其它长别名，所以一次展开即可；没有增加可变 locale 或平台时区依赖。

现代和 legacy 时间宏共用该 formatter。回归从真实 `sendOnly` 保存正文、重开读取及固定时钟的公开宏展开观察结果；原 Moment 的 Node 观察只说明上游行为，实际 Dart 编译、旧产品负对照及全包结果仍以 owner 回件为准。

era 输出依据固定 [Moment 2.30.1 era.js](https://github.com/moment/moment/blob/2.30.1/src/lib/units/era.js) 和 en 时代定义；zh-cn 没有自定义 eras，沿用英文时代名称。十个 token 的有限输出合同如下：

| token | 输出 |
|---|---|
| `N`、`NN`、`NNN` | `AD` 或 `BC` |
| `NNNN` | `Anno Domini` 或 `Before Christ` |
| `NNNNN` | en narrow 名称，仍为 `AD` 或 `BC` |
| `y`、`yy`、`yyy`、`yyyy` | eraYear，最少1／2／3／4位，不截短；2024的`yy`仍为2024 |
| `yo` | 按单位`y`取序数；en如`1st`，zh-cn仅数字 |

时代与年月日统一使用同一显式 Context 的固定 offset 日界：`local = now.toUtc().add(timeZoneOffset)`，令`c=local.year`；`c>=1`为AD且eraYear=c，`c<=0`为BC且eraYear=1-c。因此year 1／0／−1分别为AD 1／BC 1／BC 2；大写`YYYY`仍是原日历年。此政策不模拟Moment将隐藏宿主本地era锚点与另一个实例offset混用时在year 0／1附近出现的空era间隙，不声称任意历史本地时区完全等价；没有新增平台时区读取、API或时区库。

MacroContext未显式提供now／offset时的既有默认取值，以及Engine传入捕获时钟和其offset的行为均保持。现有locale范围、072词法和长格式展开顺序不变；方括号和反斜线仍保护完整era token。DateTime既有范围、offset add及格式器构造当年元旦的边界也不扩张，不承诺极限历史年份都可格式化。两个公开sendOnly回归使用既有真实文件／SQLite支架和固定时钟；另一个纯MacroContext控制只验证固定输入的字符串输出。三项均不访问真实模型，本层实际Dart结果仍待获准验证。

# T12：创建聊天时的原始问候

createChat 将选中的 first_mes 或 alternate_greetings 原文直接交给 AI_OUTPUT 正则，不先裁去边缘空白；普通无宏、无正则的 `' G '` 保存为原样。这对齐固定 ST 的 [getFirstMessage 创建入口](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/script.js)，不改变本累计层卡字段宏／提示词字段各自的 JavaScript 清理规则。

本包仍按原合同执行 AI_OUTPUT 正则→整段宏展开→去 CR，并保留局部状态、SQL 事务和已发生全局效果的失败处理。公开 greeting 索引仍是 0 对应 first_mes、其后按原 alternate 顺序计数；空字符串占位，选择空项仍保存空正文根，greetingIndex 保留实际索引，不模拟 ST 界面在空 first_mes 时重排默认项的行为。

新增两个公开门面回归使用真实文件／SQLite、字段编辑、JSONL 导出与一次重开，不调用模型；第二项只检验本包既有处理次序，不声称执行过 ST 整体创建与宏展开流程。实际 Dart 结果及唯一核心的旧产品差异仍待本机验证。

# P2 G1–G3：共用聊天树的群聊

本层实现已交付 `P2-API.md` 的群聊 A 部分。每批使用同一聊天树，演员按有限计划逐个完成；下一人读取前一人已经提交的正文、普通变量和主持状态。没有循环调用公共 `send`，也没有并行演员请求。这里描述候选源码行为；本地未运行 Dart、formatter 或测试，实际验证结果以本层代跑回件为准。

## 建群、成员与旧入口

```dart
final groupId = await tavern.createGroupChat(
  [aliceId, bobId],
  hostCharacterId: hostId,
  activation: TavernGroupActivation.listOrder,
  maxSpeakersPerTurn: 3,
  addGreetings: false,
);
await tavern.updateGroupMember(groupId, bobId,
    talkativeness: 0.5, modelRole: TavernGroupModelRole.helper);
final events = tavern.sendGroup(groupId, '一起讨论下一步。');
// 明确让某一成员说一次；允许覆盖该成员的 mute。
final oneSpeaker = tavern.sendGroup(groupId, '', speakerCharacterId: bobId);
```

两个返回的 stream 都在监听时接纳，示例中的调用本身不会启动模型；同一聊天只能监听接纳一个主操作，另一个会得到 busy。`groupChat` / `watchGroupChat` 返回不可变的成员快照；`addGroupMember`、`updateGroupMember`、`removeGroupMember`、`reorderGroupMembers` 和 `updateGroupChat` 返回更新后的完整配置。调用时复制成员列表，排队后不会重读调用方的可变 List。

主持必须是真实库卡，缺省为首成员，可以不在发言名单；有显式主持可建空名单，名单移空仍是群聊。主持定义来源首版不可隐式重绑。`deleteCharacter` 若仍被任何群用作主持，返回 `TavernGroupException(hostInUse)` 和 `relatedChatIds`，在库队列实际删除前再次检查；移除主持的发言席位不改变这个引用。删除非主持卡先取消排空受影响批次，再移出名单，保留群历史和旧发言 ID。文件删除与 SQL 不承诺跨资源原子；文件已失而 SQL 未完成时读取可显示 `available=false`，不会因此删除群。

成员 ID 必须存在且不重复。talkativeness 的显式输入必须是有限 0..1；缺省从卡读取并规范化，非法或缺失用 0.5，随后作为群偏好独立保存。update 的 null 表示不改；重排必须是完整排列；上限为正整数。CRUD 校验经 Future 返回 `TavernGroupException` 的领域 code，真实 I/O 错误保留存储失败。无群或单聊的 `groupChat` 为 null。

| 入口 | 群行为 |
| --- | --- |
| `sendGroup` / `resumeGroupTurn` | 新群事件流；明确点名只排一人，重连只给当前快照和后续事件 |
| `send` | 空闲群为 invalidParameters / `group_requires_sendGroup`；已有同聊天主操作时先返回 busy |
| `resumeTurn` | 活跃群批次为 `group_requires_resumeGroupTurn`；群内单次重做仍用原入口观察 |
| `regenerate` / `continueReply` | 从目标 `speakerCharacterId` 选当前在册演员及模型角色，只生成一人；未知身份、移出名单或缺失卡明确失败，静音不阻止显式重做 |
| `impersonate` | 空闲群为 invalidParameters / `group_impersonate_unsupported` |
| `sendOnly` / `narrate` | 取消并排空整个批次，再用主持环境写一条，无模型调用 |
| `stop` / 树结构编辑 / 成员配置编辑 | stop 取消整批；结构编辑先取消排空，之后才修改，不等待暂停的 observer |

## 调度、流与费用

- natural 采用固定 ST 的 ASCII 单词点名、shuffle、talkativeness 阈值、fallback、去重，然后应用本项目 cap。无输入时只看实际最后一行；该行 is_system 为真则正文为空，不倒查更早消息。`allowSelfResponses=false` 的 banned 影响原前两段，但原 fallback 仍可能选回自己。中文明确点名使用 ID。
- listOrder 是按当前名单从头列出启用成员再 cap，不保存公平轮转游标。randomPool 每次只选一人；新用户输入清空“本轮已说过”池，否则从最近用户行之后的真实 speaker ID 计算池。
- manual 未明确点名就不生成；有输入仍保存用户行并结束 noSpeakers。这与固定 ST MANUAL 的无输入随机回退是明示差异。director 只读本轮捕获的合格已保存提案，不临时调用导演补人。
- mute 只禁止自动选人；零 talkativeness 仍可能因原阈值或 fallback 被选中。读取 DTO、重连和 UI 展示均不重抽随机。

正常顺序为外层 `TavernGroupStarted` → ready → speaking（`TavernGroupMemberEvent` 包住 Started/delta）→ SQL 提交后的 settling → 内层 Done → 下一演员 → 唯一 `TavernGroupFinished`。内层 Failed 直接进入外层 failed/cancelled 终态；settling 只标明演员 SQL 已提交，不代表整批成功。`remainingCharacterIds` 只包含尚未开始者，`speakerCharacterId` 是当前演员；`generationId` 在该演员活跃时存在，结束后清空。每份 progress 的列表是独立不可变副本。每个 child 仍只有一个原 TavernEvent 终态，不能把 child Done 当成整群完成。

取消订阅只离页。`resumeGroupTurn` 原子注册并发送 `TavernGroupSnapshot`（含尚未 checkpoint 的完整当前正文），不重放 delta、RNG、Key 或 HTTP；无活跃批次就关流。stop、close 或进程终止后不自动补剩余演员。外层占用覆盖准备、演员间隙和 settling；人设、预设删除也识别整批捕获的资源。

用户行最多提交一次；提交后 `progress.userNodeId` 即凭据，第一演员零输出失败也不删除它。A 成功、B 失败时 A 保留；B 有输出按原规则保存 partial，零输出新回复撤回，C 不启动。失败终态的 remaining 保留未启动名单，仅用于解释。终态存储失败明确为 server，不保证 partial 是完整最新文本，不应据此自动再插用户行。

每名演员是独立请求和用量。main 使用本批捕获的模型配置；helper 在 DeepSeek 用 `deepseek-flash` / thinking=false，其余 provider 用原 model / thinking=false，沿同一个 endpoint 和 Key callback。helper 演员仍走普通角色预设及流式通道，不携带导演 direct 工具。取消后不额外启动下一人的 Key/HTTP。

## 演员、主持和所有成员的书

演员决定人物字段、`char`、角色正则、当前 WI 过滤和发言身份；真实主持独占共享 DSH schema/规则、故事、秘密和导演定义。不会把演员的另一套 schema 反复初始化进共享状态。创建时主持初值保存一次；无 greeting/空名单也用 `group_chats.initial_state` 保存同一根基线，空路径 readState、首演员、重开和完整备份都读取它。群开场按名单选择、展开并写入真实演员 ID；添加成员不自动补开场。

提示词采用固定 ST SWAP：当前演员字段加完整共享可见历史，传入现有 assembler 的 groupNames、群开场/nudge/姓名处理及原预算。`group` 为全部可用成员名、`groupNotMuted` 为未静音可用成员名，主持不在名单就不偷偷加入。输入宏/写回正则只执行一次，有计划用首演员环境，无计划用主持。角色 prompt/写回正则仍仅用当前演员；显示/编辑有 ID 的旧正文用真实发言卡，缺失或无身份的历史可继续显示，显示结果以 `group_speaker_unavailable` 标记未套角色规则，不按同名猜卡。

每名演员都加载在册成员（含静音者）的嵌入书，以及每个成员显式 characterLorebooks 的并集；共享 global/chat/persona/memory 绑定保留。外部书维持 bookId，并由现有 `_sortedEntries` 按原 global→chat→persona→character→memory 优先级去重；嵌入书保持 `<characterId>:card`。当前演员仍决定 characterFilter/tags。主持不在名单时不因主持身份额外注入主持内嵌书。全员书是 ADDENDUM-10 的产品要求，已读固定 ST getCharacterLore 本身仅证明当前 chId 的读取，不冒称原 ST 所有模式已有全员书。

共用历史不新增跨角色思考传输。只有当前演员、同模型及 provider 来源的已知群消息可沿原 reasoning 设置参加；来源未知或其他演员的 reasoning 不新增到正文。每位演员正常提交各结算一次 T17，因此最多三人可能消耗三份 x-dsh-step 额度；章节回合计数及普通自动导演只在完整批次最后结算一次。失败/取消/无人发言不额外推进故事或安排新自动导演，已有演员的状态修改保留。既有秘密增强若显式开启，仍可能按原合同另安排一份秘密 helper。

导演点名只接受已保存 `name='group.speaker'`、字符串 data 内 `{ "characterId": "真实ID" }` 的提案。验证原成功来源、祖先/fingerprint、稳定 eventId 和原记录字段；群导演作业即使没有卡 eventRules 也持久保存 outputIndex，但不因此新增 eventCapability。不按名字猜、不扩展其他事件执行权限。无效、静音、重复或不可用候选保存 `group.selection` 审计，`readDirector().issues` 与演员 inspection 保留诊断。实际消耗的 eventId 写到回复节点的分支局部 extra；零输出撤回不消费，partial 留存则消费，其他未消费分支可按原来源规则再次选择。原 pending proposal 不被全局删除或改写。

## 持久化和 App 接合

SQLite 注册迁移升至 7：group_chats、group_members、nodes.speaker_character_id；主持仍是 chats.character_id。旧单聊不变群，旧节点未知 ID 保持 null，新开场和生成填写已知 ID。聊天列表/角色统计同时识别主持和成员且每 chat 去重；消息/path/tree/search/流/终态及复制均透传 ID。JSONL 使用 `extra.dshgo.chatJsonl.speakerCharacterId` 保留每个 swipe 身份；本地 UUID 不能冒充 ST original_avatar。完整备份包含群表、初始状态和消息 ID；不宣称目前只有 JSONL 的接口能够完整互导 ST groups 定义，不能按同名自动映射跨库成员。

App 的 `DeferredTavern` 要转发所有新群方法，Preview 由 owner 按完整群事件序列模拟。本层没有读取或修改 App。`TavernChatSummary` 增加 kind 与不可变 memberCharacterIds；为复制列表，构造器不再 const，既有 `const TavernChatSummary(...)` 调用应移除 const。其 characterId 在群里表示主持，消息演员应读 nullable speakerCharacterId。新 DTO 字段均有单聊默认值；不把主持头像当成每条消息的发言人。

群聊切片本身不运行 JS 或 MVU。下面的 B1 累计层已把 settling/generationId 接到真实的缓存和回复 handler 屏障；群尾只提交当前节点的新 story 状态与审计，不再把旧 child 正文、reasoning 或 inspection 缓冲写回。JS 执行器和固定 MVU 构建仍由 App/owner 接入验证，不能从 native hook 完成推断 MVU 已兼容。

固定参考为 ST `7e8663cd9c184a550b37238218bdd32c6efc68e9` 的 [group-chats.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/group-chats.js)、[utils.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/utils.js)、[openai.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/openai.js) 及 [world-info.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/world-info.js)。这次只读源码，没有新增 ST probe；`p2_group_store_engine_test.dart`、`p2_group_turn_engine_test.dart` 和旧 schema 回归的实际运行由正式代跑给证据，不把静态源码审阅当作通过。

# P2 B1：脚本数据桥与持久回复屏障

`Tavern.scripts` 提供原生的 `TavernScriptBridge`。本节记录 B1 引入的 context/snapshot、消息与 swipe family、五个变量 scope、实际提交版本、可等待的主生命周期和 App host 接口。B1 当时的 `capabilities.adapterVersion` 是 `p2-b1`，随后 B2 使用 `p2-b2`；本包当前候选继续接入末节的 B3，能力版本为 `p2-b3`。本包不内置 JavaScript 引擎、不解析 MVU；B3 的有限 STscript 与真实 App host 协议见末节。没有 host 时持久数据操作仍可使用，`hostAttached=false` 不伪造宿主成功 Ack。

这些调用/事件边界遵循已交付 P2 API 和项目勘误，尤其派生通知、swipe 改长及主生命周期重入是项目协议，不声称它们都已由固定 helper 原件或实际 MVU 构建证明。当前作者只做源码实施与静态自读；本层 Dart 编译、analyze、测试、App 和 MVU 的实际结论以对应正式回件为准。

## Context、消息身份与快照

```dart
final bridge = tavern.scripts;
final context = await bridge.openContext(TavernScriptContextSpec(
  instanceId: 'card-frame-1', chatId: chatId, characterId: characterId,
));
final page = await bridge.getChatMessages(
  context.id, const TavernMessageRange(first: 0, last: -1),
  includeSwipes: true,
);
final saved = await bridge.getVariables(context.id,
  const TavernVariableTarget(scope: TavernVariableScope.chat));
await bridge.replaceVariables(context.id,
  const TavernVariableTarget(scope: TavernVariableScope.chat),
  {...saved.value, 'visited': true}, expectedVersion: saved.version,
);
```

context 是当前 engine epoch 下的运行身份；`instanceId` 不是持久 script 键。群 context 未明确 characterId 时不猜主持或首成员。消息真实身份是 `(chatId,nodeId)`；楼层号来自完整选中 ancestor path，包含 hidden/system，先编号后筛选，不受 native `path` 默认分页限制。范围两端为闭区间，负数从路径末尾计算。数字写入在调用时固定节点，之后的异步等待不重新解释同一数字；历史 swipe 的明确 ref 可直接指定非当前页。

`snapshot` 是独立当前读取，不派发事件、不 Ack lifecycle、不改变已发布 delta 的比较基线，也不等待当前 cache Ack。各 scope 可经过不同文件队列，返回前会同步复验这次读到的每个目标 commit token 和路径修订；坏形状的观察也带当时 token，发生交错则重读，避免旧值配上较新 lastSeq。App 在安装 snapshot 前缓冲 cache delivery，随后按水位去重；仍待 Ack 的 lifecycle 不因 `seq <= lastSeq` 被丢弃。

仅打开的 context 构造脚本路径/消息缓存；每个 token checkpoint 不把整个历史发到 iframe。cache delta 含实际变更的消息、删除 ref、楼层索引变化、变量快照与资源引用，namespace/name 为空。每 context 的 seq 在实际派发时递增；稳定 eventId、generationId 与 message ref 的职责不同。

## 原始消息与 family 修改

`setChatMessages`、`createChatMessages`、`deleteChatMessages`、`rotateChatMessages`、`selectSwipe` 都在完整预检后提交一笔 SQL；失败不留半批。raw setter 不运行宏或正则，默认不发送模型请求。extra 是用户投影，内部 `extra.dshgo` 保留且不可直接覆盖。显式 hidden 写同步已有历史 system 标记；raw `role=system` 是 comment/system，hidden=false 仍不进入模型；原 narrator 若只回写相同投影，不被改成 comment。

读消息同时给 `hasData/rawData/dataIssue`：缺少 messageVariables 的 data 投影为 `{}`；历史 null/数组/其他非对象原样保留，data 为 null 并报告形状。`getVariables` 对后者报 shapeMismatch；明确整对象替换可以按统一状态通道修复，不能默默把坏形状当成空值。

swipes 留存索引保留原 nodeId，至少一页。裁掉入场目标或选中页必须显式给保留的 swipeId；被删页的孩子转挂到保留选中页，后代 ID/有效状态保留，祖先前缀可改变。新页缺省 data 克隆入场目标的完整有效状态；既有页未给 data 不改。重复给 message/data/extra 与对应 selected swipe 值时必须一致，否则整批拒绝。新增页不复制伪造模型 inspection/usage。

整楼删除移除该层所有可见 swipe 页，保留并重接后方分支；rotate 交换两段完整 family，不等于选页。物理 checkpoint 与 portable override 分开保存，重接前保全受影响状态；seq/FTS 身份不重新编号。返回 mutation 的 refs、indexChanges、stateEdits 和 actual upserts 来自本次真实提交。

## 五 scope、JSON 与版本

| scope | 持久目标 |
| --- | --- |
| global | settings.json 的 globalVariables，与 native 设置/宏保存共用实际文件队列 |
| character | 卡 extensions.tavern_helper.variables，保留其他卡字段、媒体和原件 |
| chat | chats.variables，并同步当前节点或群空路径 initial_state 的变量载体 |
| message | 指定稳定页的有效 state.messageVariables，独立于 chat locals |
| script | owner(kind,assetId)+scriptId 的 data；卡/预设保留原脚本树，全局为 settings.json 的 scriptData |

卡/预设脚本定位支持公开 folder.scripts 结构，兼容已有 children 容器；同名或相同 scriptId 不跨 owner 合并。脚本数据与 iframe instance 无关。未知 JSON 字段保留；全局库管理和当前对话运行清单见下文“第七波：脚本库接入”。

输入在调用时严格深拷贝，只接受 null、String、bool、有限 num、字符串键 Map 和 List；循环、自定义对象/函数、非字符串键、NaN/Infinity 报 invalidJson，不调用任意 `toJson`。replace 完整替换对象；对象成员 null 是值，只有 remove 才删除。mutate 使用已拆路径 token；insertIfAbsent 按存在性判断，null/false/0/空串均已存在；数组删除收缩数组，不制造稀疏洞。

version 按具体持久目标独立计数，包含 engine epoch。settings/card 的成功 rename、外层 SQL COMMIT 与内存采用后，同步观察已登记目标；真实 A→B→A 两次提交也使旧 token 失效。回滚、失败 rename 和无实际值变化不提前推进版本；无关目标不会制造冲突。CAS 在最终实际队列内读取最新值并检查。`updateVariablesWith` 只在写队列外调用 updater 一次，返回后 CAS；冲突不重试函数。updater 可以 await engine.close，任意用户 Future 不会被当成必须排空的存储作业，关闭后迟到结果不提交。

全局原生宏立即改变 live RAM，但保存只记录已计算的根 set/remove 意图；同值 set、删除当前不存在的键也保留顺序。实际文件队列从最新已提交基底合入本次 cutoff 内尚未提交的意图；若 JSON 有变化，成功 rename 后才确认，无 JSON 变化可确认日志而不追加 IO。不会重跑宏或 RNG，也不会用入队前的旧整对象覆盖其他写者。失败保留原生 RAM 效果与未提交意图，磁盘/bridge version 不前移；close 只排空已接纳 IO，不自动重试失败保存。普通 settings/scriptData 保存不领取这些原生意图。

`setGlobalVariables`、bridge replace 和 updater 返回的整对象是明确全替换：真正接纳写入、进入文件队列之前捕获 native cutoff；成功时准确保存替换对象，覆盖 cutoff 之前的原生值，包括先前保存失败而留在 RAM 的值，并保留调用之后的 native 意图。updater 的 cutoff 在函数返回后的提交接纳时捕获。bridge path mutate 则先在队列检查已提交 CAS/形状，合入 cutoff 内 pending native 意图，再执行路径计划一次；未提到的 native 键保持。重叠操作期间，native getter 的 live 值可以短暂包含 bridge snapshot 尚未提交的后续意图；bridge 返回其实际持久提交对象，不把 pending 当作已提交版本。原生宏非有限 Number 继续留在 RAM，持久及 bridge JSON 投影为 null，未修改这些键的 path mutate 不把 RAM 强制改成 null；bridge 新输入仍严格拒绝非有限数。这些是本项目的并发提交合同，未宣称为固定 helper 实现对拍结论。

文件与 SQL 不承诺跨资源原子。card.json 已 rename 但派生 summary 失败时，重新读取权威卡并以 committed=true 报告；成功提交后 host/cache 失败也不能说数据没保存。调用方应根据 committed 和实际读取决定恢复，不盲目重放写入。

## 同一个 message data / DSH 通道

变量 message scope、set/data、swipesData 和 create/data 共用状态准备与提交。普通 sibling（例如 stat_data）整对象替换不另解析 MVU；dshgo 没变就不执行 rules、不中断原 runtime/秘密/事件/故事账本。已有 schema 且 dshgo 改变时走 user/source=script 的真实 StateSession，新 invocation 进行校验、clamp/derive/rules 后返回 actual、收据、问题和审计。省略已存在的 dshgo 按 remove_root 校验，拒绝时整笔/整批都不提交；不会先保存普通 sibling。无 schema 的 dshgo 仍是普通 JSON。

写历史页时先保全直接 physical children 的旧 checkpoint（含 retained deleted children），再写目标 state 和 portable/audit；不能用新父状态污染未修改子页。所有 DSH 文件准备在 chat gate 外，最终同步检查主持定义修订；SQL 内不等待角色文件队列。

## Host、完成边界与群接合

host 的 cache 通道必须可重入：RECEIVED handler 可以 await 变量或正文短写，而该写会先要求 App 应用真实 cache。普通 bridge 写 Future 只等待真实提交、actual 和 cache 确认；其产生的 EDITED/UPDATED/SWIPED/DELETED 与画布 refresh 独立调度，不纳入该写 Future 或 RECEIVED 的隐式传递闭包。raw create 只有 cache/refresh；纯 data 写只有 cache；正文变更 EDITED、其他显示字段 UPDATED、实际选页 SWIPED、真实移除 DELETED。

主回合按 STARTED → AFTER_COMMANDS → 冻结本次请求 → 模型/regex/state/SQL → cache → awaited RECEIVED 及其直接写 flush → actual Done → ENDED。AFTER_COMMANDS 是可改本次准备的屏障。SENT 保留真实用户提交的 ref/楼层/修订，但在完整 body 深拷贝及 config 捕获后才异步派发，不等其 handler；准备失败/取消也只报告一次已发生的提交。群的用户 SENT 在首位演员的同一捕获边界发出，无演员则在批末报告。SENT 异步写不修改已冻结请求，也不保证赶上后续演员准备。

主生命周期不排在派生通知队尾。App 可串行派生 listener，但单聊 ENDED handler 若启动并 await 下一代，必须允许新 generationId 的 STARTED/RECEIVED 重入；不能把全部生命周期锁在旧 ENDED 后。同 chat 在 RECEIVED 等待中仍 busy；群 actor ENDED 时 outer 仍占用，不能另起同群主生成。没有声称这些项目调度选择等于固定 ST listener 的全域行为。

STOPPED/ENDED 的 args[0] 使用实际 Done/Failed 的 status、generationType、cancelled、committed、finishReason、modelFailure、replyRef、partialRef 与完整 hookIssues；dispatch 另有 generationId/nodeRef。committed 专指成功模型结算，失败保存的 partial 由 partialRef 明示；停止发生在已提交模型的 hook 等待期时，completed 与 cancelled=true 可以同时成立，不伪造 modelFailure。impersonate 临时消息不冒充持久 ref。模型已提交后的 resume 读取当前保存的回复，保留 handler 正文编辑。

准备与模型提交后的数据短写不等自己的 turn.done/outer.done；模型写阶段未 drain 或结构/选路变动则先取消并排空。stop、detach、closeContext、engine.close 解除相应宿主等待，迟到 Ack 不转给新 host。已提交模型与短写不会因 hookFailure 回滚；Done/Failed 的 hookIssues 分开报告。群下一演员在 RECEIVED 明确屏障后读最新已提交数据；批尾只写新 story state/audit/cache，不覆盖 hook 已改正文，不重复 T17 结算。

cache、lifecycle 和 refresh 的取消/失败通过 watchEvents 可观察；watchEvents 不承担 Ack，也不重新运行 JS。close 先取消回调 race，再排空实际 IO；不等待任意无响应 JS Promise或暂停的观察者。B1 没有新增 schema：继续使用 7 与现有备份/JSONL 的真实数据载体。

App 的 DeferredTavern 需新增 scripts 转发或稳定代理；同步 getter 不能返回 Future，也不能返回一个假成功 bridge。Preview 由 owner 按实际能力模拟并设置 simulated=true，未实现的方法不放 capabilities。`TavernTurnDone` / `TavernTurnFailed` 新增不可变 hookIssues，构造器不再 const，既有 const 调用须移除；群消息仍透传 speakerCharacterId。这次没有读取/修改 App，没有执行固定 MVU 构建。

# P2 B2：后台生成、注入与显式正则

本层在同一个 `TavernScriptBridge` 增加九个入口：`generate`、`generateRaw`、`stopGenerationById`、`getTavernRegexes`、`formatAsTavernRegexedString`、`injectPrompts`、`uninjectPrompts`、`releaseInjectionLease`、`listInjections`。B2 引入时的 `capabilities.adapterVersion` 为 `p2-b2`，保留 B1 的十五方法和五 scope；`generationOptions` 只列已接入的十二个请求字段。当前 B3 保留这些公开入口和请求字段。本段陈述源码合同；编译、analyze、运行及 fixed helper/App/MVU 的实际结论仍以对应正式回件为准。

## 请求、热 handle 与观察

```dart
final generation = await tavern.scripts.generateRaw(context.id, TavernScriptRawRequest(
  generationId: 'background-example',
  orderedPrompts: const [
    TavernScriptPromptPart.literal(role: TavernScriptPromptRole.system, content: 'Keep the reply brief.'),
    TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'Hello'),
  ],
  stream: true,
));
final observation = generation.events.listen((event) {
  // Render event.text. isSnapshot restores this observer without re-running JS.
});
final result = await generation.result;
await observation.cancel();
```

完整 `generate` 要求 chat context；`generateRaw` 按请求的实际来源检查依赖。literal 保持给定文字，即使含宏原字也不求值；placeholder 为固定九项。raw 不隐式补卡、history、input 或普通 preset 控制段。null-preset raw 不发默认采样值；显式 preset 只提供参数/预算，不把其 prompts、regex 或脚本挂到 raw。`max_tokens` override 只改 wire；null-preset 的宏 4095/300、WI 3795 是项目参考，不是 provider 窗口保证。显式 preset 的 raw 最终 messages 超预算时报 contextTooLong，不暗裁显式文字。普通 generate 沿既有 assembler 的预算/保留路线。

请求对象在构造及调用入口脱离捕获。`TavernScriptGenerateRequest.fromJson`、`TavernScriptRawRequest.fromJson`、`TavernScriptInjection.fromJson` 和 `TavernScriptRegexQuery.fromJson` 是实际白名单适配边界：未知选项报 unsupportedOption，不能把 tools/images/json_schema/custom_api 等藏进 JSON。非 nullable 字段的显式 null 不等于省略。prompt part 的 JSON 形状为 `{"kind":"literal","role":"user","content":"..."}` 或 `{"kind":"placeholder","placeholder":"chatHistory"}`。采样 override 仅 temperature、top_p、presence_penalty、frequency_penalty、正整数 max_tokens、非负整数 seed；DeepSeek 路线不支持 seed override。

handle 只有 `id/events/result`，建立后即热执行；无人订阅也推进准备，进入模型阶段时只订阅一次生产 `TavernModelClient`。每个活跃观察订阅先获得独立的 snapshot（isSnapshot=true、lastSeq 水位），随后接新事件；终态晚订阅只获得完整 finished/failed 恢复事件，然后关闭。恢复不重新派 host STARTED/TOKEN/ENDED，也不重读 key。logical terminal 后可以重用 public ID；旧 handle、旧取消及迟到 callback 仍属于原 record。result 失败即有内部错误观察，调用者稍后 await 仍取得原结构化异常。

`stream` 最终控制请求 stream；`includeReasoning` 只控制公开 reasoning 投影，不开关 config.thinking。结果是生产 ModelClient 解码的正文/推理，不自动执行 output/writeBack 宏或追加聊天节点；格式化使用显式 formatter。模型意外返回工具片段或 tool_calls 终态时为 unsupportedCapability，保留已收到的失败累计视图，不执行工具或开启下一轮。一次逻辑 ModelClient 执行仍可按原 transport 规则进行有限 retry，同编码重发不重跑准备。

## 准备接受、真实提交与取消

后台准备在脱离的 runtime local/global 上执行，记录已经计算的根 SET/REMOVE，包括同值 SET 和删除 absent 键；不会以 JSON diff 猜宏效果。body/config 冻结后同步检查实际写目标、选路与参与注入版本，再原子领取 once；随后先 global 文件、后 chat SQL，最后才由原 ModelClient 调用一次 apiKey。冲突不重跑宏、filter、WI 或 RNG。

global 沿唯一 settings 队列结算 native pending 前缀；在 writer 位置再次 CAS，成功 rename 或明确无文件采用后才更新 runtime，并保留之后到达的 pending 后缀。内部 runtime/pending/adoption 身份独立于 B1 committed JSON version：包括 Inf→null 且 public JSON 不变的采用、pending 前缀确认，都能使旧后台捕获失效。原生非有限数仍在 RAM 保留，JSON 边界投影为 null。

local/WI/hash 只窄合并到捕获的当前叶子、空单聊或空群 initial_state，不覆盖 messageVariables、DSH/story/director、原消息正文或 inspection；空 chat 不制造隐藏节点。实际 COMMIT 观察 selection 与各字段身份，A→B→A 不能冒充未变，无关 message data 不充当 local 版本。提交使用独立非取消短 chat 门；存在同目标未结算 native snapshot 时 busy，保留那条主回合继续运行。准备 handler 建立 baseline 前，以及已提交模型的安全 RECEIVED 阶段，不以父 turn.done 作为后台完成条件。

文件与 SQL 不承诺合成事务。失败/取消异常的 `issues` 至少含 `generationPreparation`，其 `details` 记录 preparationAccepted、persistedTargets、claimedInjectionVersions、skippedTargets、实际 failedTarget/phase、budgetSource 和 preparationIssue；没有虚构的 exception.details。只有确实采用或领取的效果才计入 committed。取消在 IO 之前阻止启动；已开始的文件/事务排空并记录结果，之后尚未开始的载体列为 skipped，不能把成功 global 写回滚成“全失败”。filter 自己通过普通 bridge 完成的写不会随后台 clone 放弃而回滚；这份准备收据不保证任意宿主私下行为从未发生。

准备存储工作先登记 ownership，STARTED 同步重入 backup/close 也不能越过它；纯 HTTP 阶段另有实际 drain，备份不等其模型结果。逻辑取消/终态与真实订阅 cancel/onDone、ModelClient finally/client.close 分开处理，engine.close 等待自有清理；任意 key/filter/host Promise 用可取消 race 解除逻辑等待，迟到结果不能开启新 IO。暂停某一观察者不阻塞其他观察者或关闭。

## 三来源注入与 native 主回合

persistent 来源是 chat metadata.script_injects，继续 JSONL/reopen；transient 是按 chat/rawId/version/owner 保存的运行 registry；request injects 只属于该请求。三者原始身份、排序键和内部 assembler ID 分开，同名跨来源不去重。注入批内重复 rawId 整批拒绝；跨调用替换产生新 version，旧 lease 只能清理仍匹配原 owner/version 的项。closeContext 清理自己的 transient 版本并取消自己的后台请求。

持久候选同步保存 raw 与实际 metadata 载体：native 的非当前 regenerate/continue 使用目标 node，后台调用使用捕获时的 current leaf。载体按既有 codec 的 sources[key]、首个有效 files/header、root 顺序解析一次；后续 COMMIT 观察与 claim 固定该实际载体和 rawId，不再改读当前页。目标真实 A→B→A 仍推进内部版本，单纯切页或另一 source 的修改不冒充该注入变化；若准备还实际写 history/WI/local，其原选路检查仍独立生效。raw literal 的 generation anchor 可为 null，但持久来源身份不因此丢失。内部 token 不是 helper lease/owner；原 SQL→claim 次序和一次 filter 保持。

filter 只调用一次，并供 scan/prompt 共用同一结果和已准备文字；不持文件/SQL 锁等 host。callback 必须属于原 live context/instance，requestId 和 host 身份核对失败不是 false。持久载体中的序列化 closure 不恢复为可调用对象；实际需要执行它时仍报 unsupportedCapability，并在 list 中保留 raw/诊断。这与 B3 执行过程中有真实身份的私有 Closure 是不同来源。

全部实际参与的 transient/persistent 注册都在接受点核精确版本；任一个变化则整批 revisionConflict。once 仅在完整准备后同步全领取；filter=false 不领取。scanOnly、展开为空、后续预算裁掉等已参与来源仍可领取；claim 后缺 key、HTTP 错误或取消不退还。claimed 记录以诊断状态保留，之后不再候选，不写入备份或 JSONL。raw inChat 在完整显式序列上定位，再做 provider 转换；非空 beforeMain/afterMain 缺 main 时明确失败。

native 单聊与每个群演员共用这张 registry。AFTER_COMMANDS 及直接写 flush 后，在原 preparing 的 scriptWritesAllowed 区捕获/过滤，再 drain direct writes，之后才建立原 native 回滚 baseline。body 冻结后、原 key 调用前，与后台共享同一个 claim。filter/claim 问题只一次进入真实 TurnFailed.hookIssues/ENDED 观察，原 user/reply SQL、变量保存、失败回滚和输出 regex 路线保留；不会调用后台生成来模拟主回合。

## Host 通知与显式正则

后台的 iframe STARTED、stream=true 时的正文 INCREMENTALLY/FULLY、ENDED 均独立发布，不等 Ack 才读 key、推进模型或完成 result。GENERATION_REQUESTED 仍由 App 在 Dart 调用前执行。事件 context.seq 与 handle event.seq 是不同序列。终态只冻结已知 hookIssues；迟到 Ack/失败仍通过 watchEvents 归属原 event/record，不修改旧 result。silent 只供 App 决定全局停止按钮的目标，显式 stopGenerationById 仍可停止它；Tavern.stop(chatId) 保持主回合/群范围。

正则查询按 inline global、managed global、所选 context/显式 preset、明确 character 的真实来源投影，保留 raw、ST id、实际 managed engineId 和来源身份；同名规则不合并。formatter 的 source 是 RegexPlacement 整数，destination 仅 prompt/display；depth=null 完全不筛。两个 phase 都用脱离的 local/global/hash 和私有稳定 seed RNG，clock 仅捕获一次，不消耗主引擎随机序列、不写库。display 保留 worker 保护；prompt 在原同步执行循环取得 warnings/replacement count，不先预跑或伪装成 display。上述 raw、once、WI 时钟和 formatter 隔离是项目政策，未冒称 fixed helper 4.12 actual 对拍结论。

# P2 B3：有限 STscript、宿主交互与原始资源

本层在同一 bridge 增加七个入口，能力版本为 `p2-b3`。下述是候选源码合同；编译、静态诊断、Windows guard、真实 App 与提供方集成的结论分别以实际回件为准。能力集合不包含“运行已通过”之类的状态。

| 方法 | 输入与实际边界 |
| --- | --- |
| `triggerSlash` | context、完整 source String、可选 executionId/pipe 和 `Map<String,String>` arguments；返回只有 id/events/result 的热执行 handle。 |
| `stopScript` | 按活动 executionId 停止该真实 record 及它拥有的后台 child；返回是否找到尚未终结的执行。 |
| `substituteMacros` | 普通 String 宏求值与真实 local/global/hash 提交，完成对应 cache 确认后返回 `Future<String>`；没有 Slash frame。 |
| `replaceCharacterData` | characterId、完整 raw data object 与可选 expectedVersion；目标级 CAS、真实文件采用及原格式/外壳保全。 |
| `getContextBooks` | 返回实际 global/persona/chat/character/group 绑定；不因只读查询自动建书或迁移绑定。 |
| `readBook` | standalone/embedded tagged ref；返回脱离的 raw book 与同次读取的 version，缺失资源或坏形状明确失败。 |
| `replaceBook` | tagged ref、完整 raw book object 与可选 expectedVersion；走实际资源队列、CAS 和文件采用。 |

## 命令与语言

批准拼写共41个、38个语义族：

```text
setvar getvar addvar incvar setglobalvar getglobalvar flushvar
if while times run pass return break abort
gen genraw trigger
send sendas sys nar comment
inject listinjects flushinject flushinjects
echo input buttons popup setinput
hide unhide messages cut del
getchatbook findentry createentry setentryfield
```

只有 return→pass、nar→sys、flushinjects→flushinject 三组别名。`/:` 是 run 的结构糖，不增加 capability 拼写。命令只支持本层已批准的有限参数与格式；未知普通命令或封闭 named 选项在实际执行该命令、求它的参数效果之前失败。完整源码先完成语法解析，因此后段语法错不会让前段先写入；未选 lazy 分支中的普通未知命令保持休眠，结构性 parser flag 则在完整解析时明确拒绝。

默认参数、重复 named、立即 child 和 unnamed 各按实际顺序求值；公共 arguments 是调用数据，不声明同名 lexical 变量，也不作为新的 Slash 源重解析。真实 Closure 身份只在执行器内传递，公开投影为 `[Closure]` 或 `[Closure]()`；普通字符串、变量存储与 JSON 往返不会恢复可执行身份。modern indexed lexical lookup 与固定 legacy 的无 index 行为保留各自合同；legacy scoped匹配区分大小写。

`pass`/`return` 继续后续命令；`break` 只作用于所属局部 break owner；lazy 循环与 `/run` 各建立局部归属，无归属的根 `break` 写入 pipe 后继续，quoted 控制 body 不继承外层 break 归属；`abort` 成功终结为 aborted，而显式 stop 是 cancelled。parser 每4096 UTF-16消费步骤合作式让出，命令和循环也真正让出 event loop；不以微任务循环假装可取消，不额外设置长度或嵌套小上限。

## 热执行、效果与取消

record 在首次异步解析前登记，订阅者只是观察者；取消订阅不取消执行。事件有单调 seq 与恢复 snapshot，终态晚订阅只取得该 record 的冻结终态。公开 ID 可在逻辑终态后重用，旧 handle、旧 host 回件和旧 child 清理仍归原 record。纯语言执行不因 host 替换停止，真正依赖旧 host 的等待则按归属取消。

三个效果单位分别保持：一次规定文本片段先采用，再进入下一段；私有 generation 的完整输入只在一次 prepare→accept 中采用；网络返回后以 fresh capture 完成 quiet C1→reasoning→C2 或 raw 单次清理，再一次采用。global 文件先于 chat SQL，已经成功的文件采用不能被后来 SQL 失败或取消回滚成“没有效果”。effects 的单项 committed 与累计 committed 分开，HTTP开始、非空文字、accepted 或发出事件本身不代表持久提交；错误保留已知事实和适用的 partialGeneration。

`/gen` 使用真实聊天、卡、预设、注入和 WI；`/genraw` 使用 prefill→user→system 的输入求值顺序及规定的实际 wire 顺序，不隐式消费 registry/WI。raw callback恰空时在 child/key/lease 前返回，外层已经完成的参数效果保留；空白 String 仍进入生成。quiet偏置依据第一次已展开结果做JS空白判定，保留NEL、裁去FEFF；输出的两次cleanup各从原decoded正文开始。公开 B2 generate/generateRaw 的结果与请求字段仍沿原合同，Slash私有选项不混入它们。

## App host 与手工消息

App需通过既有 `TavernScriptHost` 接线：dispatch及其ACK使用 `eventId`，interact/invoke使用 `requestId`，invoke的ref另含 `contextId/instanceId/callbackId`；resolveSlash的Reference只有 `contextId/label` 与可选 `setName/sourceSpan`，没有公开 `requestId`。native另核对捕获的真实context instance、host和execution归属。第四波 ADDENDUM-04 中 owner 报告：App invoke 已接（本机提交2774677d，未推送），filter 留在所属页面，调用返回在 filter 及其写入完成后确认；注入、列出、撤销已在真引擎核过，filter 实际调用仅在单元测试和 Edge 桩核过，尚未经过真实生成准备。interact 原生 input/buttons/popup、echo提示条、setInput composer 界面已完成（139c7813），仍待 B3 合入后接到 host；resolveSlash 因无脚本库仍拒绝。这些是 owner 报告，不是本包实测。五UI使用固定typed fields；input/buttons的取消是正常空结果，echo/setinput必须确认实际处理文本。HTML/Markdown显示及sanitize由真实App完成，后端不虚报已绘制。`resolveSlash` 接入后的合同是返回一次固定source与asset/version；执行器不在执行中重查来源。

可选 `TavernScriptGenerationLockHost` 单独提供 acquire/release。hostCapabilities仅当当前host实现该接口时有generationLock，既不代表已获得lease，也不代表App实现已经验证。lease所有权在实际调用前建立；正常release是命令完成屏障，失败/取消收尾使用独立取消令牌且不无限等待任意host Promise。snapshot保留读取时的能力副本，host替换后的新getter/新snapshot反映新host。

send/sendas/sys/comment走真实B1消息存储：文本效果先采用，再保存消息；消息SQL失败仍保留更早文本效果。返回值捕获真实保存时的节点/编号/正文，不被后来的派生listener改写。手工send/sendas的SENT/RECEIVED是保存后的非屏障派生通知，模型回合的RECEIVED仍是原可等待生命周期；raw CRUD不附送这些通知。九种return模式为none、pipe、object、chat-html、chat-text、popup-html、popup-text、toast-html、toast-text；显示使用已捕获source，不再宏展开。

## 持久注入、世界书与原始数据

`inject`/`flushinject`只改实际选中物理header/source的persistent `script_injects`，不删除同名transient或once注册。`listinjects`对已接受return模式统一先读取并格式化真实条目，坏条目在输出前失败；none/object没有惰性跳过格式检查的例外。序列化filter保留为数据，不执行为Closure。

完整character data与embedded book有独立目标版本，无关变量写入不冒充整个raw data或embedded字段变更；实际A→B→A仍推进对应目标身份。保留原sourceFormat、外壳、资源与未知字段，读raw与version不拼接来自两次读取的数据。standalone原书的entries object与array格式按资源API保留；ST字段命令只支持standalone entries object，array格式明确unsupported。

`getchatbook`先解析真实canonical绑定，再按已定唯一native绑定回退；只读不迁移。建书先真实文件采用，再写chat SQL，第二步失败报告chatBookPartial并保留真实orphan。createentry取raw属性键第一空洞并使用完整固定模板；setentryfield按raw key定位，按当前值类型转换并保留unknown，不能把actual uid当raw key。Names要求真实身份，非空Tags需要真实catalog；缺能力明确失败。findentry使用固定Fuse 7.1.0有限消费者，按JS整数属性顺序与UTF-16分块，不附加disabled/uid真值/order筛选。其默认完整小写复用本包固定Unicode 16数据，包含条件Final_Sigma和一对多映射，保留重音及原正规化形式；整个Unicode空间与任意浏览器运行时的逐点等价尚未取得实际证据。

App的Deferred/Preview转发、真实宿主UI与MVU运行由主线接入；本包没有借方法存在声明这些外部工作已完成。预览只能标注并实现其真实模拟能力，未实现入口应明确失败。固定来源为ST 1.19.0、Handlebars 4.7.9及Fuse 7.1.0，对应来源与许可证见各文件头；本层有限实际与其未覆盖范围见交付报告。

## R5 当前状态：136 失败后的有限修订

本小节记录 2026-11-12 UTC 的 R5 冻结前作者状态，接续上述合同与历史说明。136 的真实结果为：原八条命令中 1–7 均 exit 0，analyze 为 0 error / 0 warning / 0 info；第 8 条 guard exit 1，owner 报告 276 pass / 5 fail，无超时。root 于 2026-11-12T23:19:53.210980Z 全文接受独立 RUNTIME，结论仍是 **PARTIAL / BLOCKED_GUARD_FAILURE**。analyze 通过不能提升为 B3 通过，R5 本身尚未运行。

R5 的修改范围保持有限：

| 修订 | 合同与证据边界 |
| --- | --- |
| 内部缓存 capture 失效 | `_buildView` 在解析每个内部 target 之前复核所捕获 pathRevision，仅确认失效才整体重建各 scope。稳定目标的 notFound、真实读取错误和关闭/取消链仍保留。136 回件定位了 cache notFound，但没有打印具体异步交错或该失败子阶段的实际 DELETE receipt；提交后旧 capture 失效是源码可达路径分析，不能写成该次实际采用已证。 |
| numeric 条件测试 oracle | 固定 `Scope.getVariable` 对非索引 numeric String 进行 Number 转换；`n=007` 与 `7` 应相等。保留原脚本，并用 `n=8` 对照确认 lexical 值仍遮蔽 persistent `n='007'`。没有修改语言数值产品逻辑。 |
| 两个 legacy 测试 oracle | 固定 ST 在构造 legacy 宏列表时即取得 chat hash；本项目 L1 保存成功片段的真实 hash intent。测试核首调用的真实 SQL metadata/hash adoption，并保持同 fixture 后续调用无新采用；原大小写与 typed Closure 语义仍按原 source/pipe 期待核对。 |
| quiet whitespace 测试 oracle | fresh empty chat 的第一次 quiet preparation 会真实保存 WI timer/decorator 状态。测试保留原 NEL、FEFF、ASCII 三个 wire/pipe 向量，核首轮两个具体 SQL adoption 及真实 metadata，后两轮仍要求无新采用；没有改 whitespace、WI 或 effects 产品算法，也没有暖机或删除向量。 |

完整归因、固定来源、实际作者范围与未运行事项见交付工作目录的 `review-b3-r5/author/AUTHOR-B3-R5-EFFECTS-GENERATION.md` 及 root 的条件/legacy 作者记录；136 原始 reply、完整 RUNTIME/checks/root 接受记录整件保留。结合回件与冻结测试断言顺序可以作静态控制流推断，但 wire/pipe、receipt、各 case 的实际逐项日志没有因此补齐；FEFF/ASCII 后续 case 不能据首轮失败宣称已运行。R5 新期待和缓存修正仍待独立 CODE 及真实后继运行，未继承实际 PASS。

后续 137 已选执行父链为：**干净 `4af464df` → owner 原始未格式化 `checkpoint-135-P2-B3-r3.patch` 一次 → 真正同时包含 R4 与 R5 的 R5-on-R3 delta 一次**。不能再另叠 R4 delta；不以 raw136 为父，也不在此链叠加 full-on-B2。R5 full-on-B2 累计补丁仍用于完整当前层审查与接入，和上述执行 delta 的用途分开。raw135 原件由 owner 持有，本地 R3 代表只支持静态接点核对；raw136 也只收到 owner 留存的名称、规模与校验元数据，未取得其原始字节。本节编写时 137 尚未正式创建，补丁身份、正式请求 ID 与时钟以真实最终发布记录为准。

完整 HB 仍 OPEN，mixed String/object entries 的 Fuse 合同域仍未定，完整 Unicode/浮点域与任意浏览器运行时的等价未由这些修正证明。App 状态继续按上文 ADDENDUM-04 的 owner 报告：invoke 已接但 filter 尚无真实生成准备验证；interact 原生界面已完成但未接 host；resolveSlash 仍拒绝。真实 App/MVU/device 及其它原未覆盖范围保持。下一阶段已有 owner 决策不撤销，但阶段一实施仍须后继 B3 实际通过、正式交付和 owner 合并主线三项全部完成；本次没有启动该阶段。

# 第七波：脚本库接入

`Tavern` 现在管理全局脚本库，并读取这个对话实际应运行的全局、当前预设、角色卡脚本。引擎仍不执行 JavaScript；App 负责脚本库页面、隐藏 iframe、按钮和既有 host 协议。

| API | 行为 |
| --- | --- |
| `listGlobalScripts()` / `watchGlobalScripts()` | 有序树，包含禁用项与文件夹；`TavernScriptLibraryEntry.raw` 是脱离的当前 JSON。 |
| `importGlobalScripts(text)` | 接收裸 script、裸 folder 或完整树数组；保存原 enabled，不主动运行，返回实际采用的树。 |
| `setGlobalScriptEnabled(id, enabled)` | 改指定脚本或文件夹；关文件夹屏蔽子树，保留各子项开关。 |
| `setGlobalScriptOrder(ids, folderId: ...)` | 提交一个父目录的完整同级排列；省略 folderId 表示根，不能借遗漏 id 删除。 |
| `deleteGlobalScript(id)` | 删除该项/子树及其叶脚本的全局变量和按钮行；其他主人的数据不变。 |
| `exportGlobalScripts(id: ...)` | 指定 id 导出一个对象，省略则导出完整树数组；从实时载体拼回 data/button，保留 export_with 原值。 |
| `chatScripts(chatId, characterId: ...)` / `watchChatScripts(...)` | 返回 `TavernChatScripts`：实际 characterId、按全局→当前预设→卡排序的 scripts，以及无法建立唯一主人的旧数据 issues。 |

全局库与既有 `scriptData`、`scriptButtons` 同在 settings.json 的文件队列内提交，成功采用后才通知。导入 data 与 button.buttons 分别进入这两个既有载体；代码/文件夹/按钮开关等元数据放 scriptLibrary，避免脚本运行后导出陈旧变量。已有非空且未占用的 id 保留，缺失或与库/已有全局数据键冲突的 id 取得稳定新 id，不覆盖旧主人。关闭引擎再打开后保持顺序、开关及数据。全库数组是本引擎的往返格式。

预设与卡读取 `extensions.tavern_helper.scripts`；它不存在或为 null 时才读旧 `extensions.TavernHelper_scripts`，现代空数组明确压住旧字段。树内文件夹使用 scripts，已有 children/递归旧结构也保留。脚本须 enabled=true 且代码非空；缺 id 或同一主人树内重复 id 的活动脚本在 issues 中报告并跳过，不创造临时 script-N。不同 scope 的同 id 是不同主人。

“当前预设”包含现有 RAM 工作副本和旧 inline 配置。保存版仍使用原 `TavernScriptOwner(kind:preset,assetId,scriptId)`；临时/内联版另带 `presetCarrier`：kind 为 working 或 inline，chatId 为空表示全局，workingId 仅标识本次引擎中的 RAM 槽位。继承全局工作副本的多个聊天共享这个全局主人，只有实际存在的 chat slot 才有聊天主人。同一槽位中改温度、正则、代码、data 或按钮不换 workingId；切换/重载清除槽位后，旧主人不再重定向到新槽位。RAM 写入不保存到原预设，inline 写入仍落原 settings/chat 载体。carrier 是本引擎接线信息，不进入助手原始 JSON，也不承诺 RAM 身份跨重启恢复。

App 接线示例：

```dart
final selected = await tavern.chatScripts(chatId);
for (final script in selected.scripts) {
  final context = await tavern.scripts.openContext(TavernScriptContextSpec(
    instanceId: frameInstanceId,
    chatId: chatId,
    characterId: selected.characterId,
    script: script.owner,
  ));
  // App 安装 snapshot，随后在该 frame 中执行 script.content。
}
```

主线需要在 `app/lib/tavern/deferred_tavern.dart::DeferredTavern` 和 `tavern_preview.dart::PreviewTavern` 补齐这 9 个 Tavern 方法；用 chatScripts/watchChatScripts 替换仅看角色卡的 provider。`tavern_script_wire.dart::_owner/_ownerJson` 必须保留 presetCarrier，现有 `_DeferredScripts.openContext` 已原样转发 typed spec。`tavern_canvas_calls.dart::_openScript` 的 character owner 硬编码、`asScript/id`、`_scriptContexts` 和 liveButtons，以及 `tavern_canvas.dart` 内的 varKey、listenerOwner、按钮缓存均须按完整 owner 路由，例如以 `jsonEncode(script.owner.toJson())` 作缓存键；原 scriptId 仍是助手脚本自身 id。

按 owner/content 的实际差异开关帧，移除帧时关闭对应 context；普通变量或按钮更新不应重执行代码。按钮只显示 buttonsEnabled 且 visible 的非空命名项，后续列表从既有 context snapshot/cache delta 接收，点击按完整 owner 路由。以上 App 接点只作接入说明，本层没有修改 App。

现有 `tavern_canvas_view.dart::_open` 的 `Object.hashAll(cardScripts)` 会令目录变化触发整页 loadHtmlString；此处需换成对应帧的差异更新。`callerScript()` 目前以 sourceURL 数组下标找脚本，增删/排序不能改变存活帧的 owner。`adoptResources` 尚未采用 scriptButtons，`_openScript` 尚未注册该 owner context 到 `TavernScriptPages`；主线需将该 owner 的 snapshot/delta 接入按钮缓存，并保持单次 cache/lifecycle Ack，不能仅替换 provider。

群聊未传 characterId 时只返回全局和当前预设；App 明确选择卡后传入同一个 characterId，并原样传给 openContext。watch 在库管理、实际卡提交、预设/选择/工作载体修改时合并刷新，不订阅普通消息列表或流式 checkpoint；外部直接改卡文件后可主动调用 chatScripts，仍走已有 stat 刷新。导入保存成功后，App 根据用户的 enabled 选择及返回清单启动脚本，不设置额外默认禁用策略。

格式依据是助手[脚本库](https://n0vi028.github.io/JS-Slash-Runner-Doc/guide/基本用法/脚本库.html)和[获取脚本](https://n0vi028.github.io/JS-Slash-Runner-Doc/guide/功能详情/酒馆助手脚本/获取脚本.html)公开文档，以及 [NE-Memory README](https://github.com/Melody-0321/NE-Memory/blob/main/README.md) 的裸 script 导入说明、[SillyTavern-Auto-Summary](https://github.com/Yi-Lings/SillyTavern-Auto-Summary) 的实际单脚本导入包。后两者证明 info/data/button/export_with 可缺省。裸 folder 依据公开 ScriptFolder 结构接收，尚未用真实 folder 导出对拍；不推测未知 wrapper，也不声称上游支持嵌套 folder。未阅读助手实现或 type 仓库，未执行样本脚本。
