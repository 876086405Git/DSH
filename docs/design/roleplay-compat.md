# 酒馆：兼容 SillyTavern

> 总纲见 [roleplay.md](roleplay.md)。依据：2026-11-08、11-09 读的源码和规范——SillyTavern `release` 分支 1.19.0（2026-09-14 发布）、Character Card V3 规范、MagVarUpdate（`beta` 分支，最近一次更新 2026-10-19）、酒馆助手（JS-Slash-Runner）4.12.0 的公开文档。下文的 ST 文件路径都相对于 ST 仓库根目录。

## 0. 结论

- **目标**：同一张卡、同一个预设、同一段对话，我们发给 DeepSeek 的请求和 ST 发的逐字一致；同一条消息显示出来一样；酒馆助手和 MVU 的卡能玩。
- **怎么做到**：ST 是 AGPL-3.0，和 dsh-Go 一样，组装、宏、正则、显示这几块复用 ST 的实现（版权与来源见 THIRD_PARTY_NOTICES.md）。酒馆助手按公开文档重写同名接口。MVU 是 MIT，引擎照它的源码原生实现变量协议（§5.3）。
- **对拍**：让 ST 连一个只录请求的假接口，录下它发出去的东西，和我们的逐字比较（§10）。
- **不弹授权。** ST 对卡和预设里的正则会问一次「允许吗」，我们默认就开（owner 定的）。
- **只做对话补全（Chat Completion）。** ST 的文本补全和 instruct 模板不做：DeepSeek 和主流接口都是对话补全，中文社区的预设也都是对话补全的。

## 1. 兼容范围

| 东西 | 我们怎么做 | 阶段 |
|---|---|---|
| 角色卡 V1 / V2 / V3（PNG、JSON、CHARX） | 读写，无损（§2） | R1 |
| 世界书（卡里的、独立的、绑在对话上的） | 语义一致（§4）；V3 装饰器在 R2 | R1 |
| 对话补全预设 | 原样读写，组装规则一致（§3） | R1 |
| 宏 | 新旧两套引擎（§5.1） | R1 常用，R2 全量 |
| ST 聊天记录 `.jsonl` | 双向转换（§7） | R1 |
| 正则 | 语义一致（§6.1） | R2 |
| 显示流水线 | 复用 ST 实现（§6.2） | R2 |
| 作者注释、用户人设、经典群聊 | 照 ST | R2–R3 |
| ST 主题（颜色、自定义 CSS） | ui §10 | R2 |
| 酒馆助手：前端块、接口、嵌入脚本 | 照文档重写（§8） | R3 |
| MVU | 引擎原生实现它的变量协议（§5.3） | R3 |
| 斜杠命令、快速回复 | 常用子集（§8.4、§8.5） | R3 |
| 提示词模板（EJS，ST-Prompt-Template 扩展） | 待定（§5.4） | R3 前调研 |
| 不做 | 文本补全和 instruct；ST 的其他扩展（向量库、摘要、生图、TTS 等，我们有自己的对应功能）；改 ST 设置面板和侧栏的脚本 | — |

## 2. 角色卡

### 2.1 格式

- 内部存 V3 卡的 JSON（`spec: chara_card_v3`）。V1、V2 导入时升到 V3；V3 是 V2 的超集。
- 字段：`name`、`nickname`、`description`、`personality`、`scenario`、`first_mes`、`alternate_greetings`、`group_only_greetings`、`mes_example`、`system_prompt`、`post_history_instructions`、`creator_notes`、`creator_notes_multilingual`、`tags`、`creator`、`character_version`、`character_book`、`assets`、`source`、`creation_date`、`modification_date`、`extensions`。
- V3 的几个规矩：
  - `nickname` 有值时，`{{char}}` 换成它。
  - `group_only_greetings` 必须有（可以是空数组）。
  - `creation_date`、`modification_date` 是 Unix **秒**，0 表示不知道；用户不能改，导出时更新 `modification_date`。
  - `source` 只追加，不改。
  - `creator_notes_multilingual` 按界面语言挑，没有就用 `creator_notes`。
- `extensions.dshgo` 放我们自己的东西（agent §10）。不认识的扩展原样保留、原样导出：`regex_scripts`、`depth_prompt`、`world`、`talkativeness`、`tavern_helper`（酒馆助手的脚本和变量）等。导入再导出，别家的数据一个字节不丢。

### 2.2 导入导出

- **PNG**：读 `tEXt` 块，先找 `ccv3`，再找 `chara`，内容是 base64 的 JSON。导出时两块都写：`ccv3` 放 V3，`chara` 放降级的 V2（去掉世界书条目里的装饰器），老软件也能读。PNG 里的 `chara-ext-asset_:<路径>` 资源块能读，导出不写。
- **JSON** 卡、**CHARX**（zip：根目录 `card.json`，资源按规范建议放在 `assets/<类型>/images|audio|l2d|fonts|…/`）、**独立世界书**（ST 格式，或 V3 的 `{spec: "lorebook_v3", data}`）。
- 存在 `<应用支持目录>/tavern/characters/<id>/`：`card.json`、卡面、资源目录，原文件也留一份。读包复用伙伴素材包的代码：解出的文件不出卡的目录，图片在后台 isolate 里解码。

### 2.3 资源

V3 的 `assets` 每项是 `{type, uri, name, ext}`：

| `type` | 我们用来 |
|---|---|
| `icon` | 卡面和头像；多个时叫 `main` 的那个是主图；没有 `assets` 时当作有一个默认 `icon` |
| `background` | 背景，`[场景:名字]` 按 `name` 找（agent §6.1）；叫 `main` 的是默认背景 |
| `emotion` | 表情图，`name` 是情绪名；`neutral` 是默认 |
| `user_icon` | 你的头像候选 |
| `x_` 开头的自定义类型、RisuAI 写的 `x-risu-asset` | 保留；音频按扩展名当作 `[音效:]` / `[音乐:]` 的来源 |

`uri` 认 `https://`、`data:`、`embeded://<路径>`（规范原文就这么拼）和 `ccdefault:`。

### 2.4 伙伴和卡

- 伙伴「她的设定」里的用户块（名字、怎么叫你、人设全文）就是卡的 `name`、`description`。App 固定追加的规则块（表情动作标记、旁白说明）不进卡。
- **请进小屋**：任何一张卡都能成为伙伴。卡的设定替换她的设定，开场白当第一次见面的问候；用卡里的 Live2D（`extensions.dshgo.live2d`），没有就用现在的鲸鱼娘。伙伴一次只有一个。

## 3. 预设和提示词组装

### 3.1 预设文件

存 ST 导出的原样 JSON（`public/scripts/openai.js` 的 `getChatCompletionPreset()` 导出的那份）。我们用到的字段：

| 组 | 字段 |
|---|---|
| 采样 | `temperature`、`top_p`、`top_k`、`frequency_penalty`、`presence_penalty`、`repetition_penalty`、`min_p`、`top_a`、`seed`、`openai_max_context`、`openai_max_tokens`、`stream_openai` |
| 文本模板 | `impersonation_prompt`、`new_chat_prompt`、`new_group_chat_prompt`、`new_example_chat_prompt`、`continue_nudge_prompt`、`group_nudge_prompt`、`send_if_empty`、`wi_format`、`scenario_format`、`personality_format` |
| 行为 | `names_behavior`（-1 无、0 默认、1 用 name 字段、2 写进正文）、`squash_system_messages`、`continue_prefill`、`continue_postfix`、`show_thoughts`、`reasoning_effort`、`function_calling` |
| 结构 | `prompts`、`prompt_order`、`extensions`（预设绑定的正则在 `extensions.regex_scripts`） |
| 连接 | `chat_completion_source`、各家的模型名、`reverse_proxy` 等：**不用**，接口和 Key 用我们自己的设置；原样保留，导出时照 ST 的做法问要不要去掉 |

- `assistant_prefill`、`assistant_impersonation` 在 ST 里只对 Claude 源生效；我们发 DeepSeek 时同样不用。
- 旧预设的 `main_prompt`、`nsfw_prompt`、`jailbreak_prompt` 照 ST 的迁移写进 `prompts` 里对应的条目。

### 3.2 `prompts` 和 `prompt_order`

- **`prompts[]`** 每项：`identifier`、`name`、`role`、`content`、`system_prompt`（内置的不能删）、`marker`（占位，内容由 App 填）、`injection_position`（0 按列表位置，1 按深度插进聊天记录）、`injection_depth`（默认 4）、`injection_order`（默认 100）、`injection_trigger`（空 = 总是；或 normal / continue / impersonate / swipe / regenerate / quiet 里的几个）、`forbid_overrides`。
- **`prompt_order`**：`[{character_id, order: [{identifier, enabled}]}]`。对话补全用的是 `character_id: 100001` 那一组；没有 100001 时 ST 写回默认顺序（只有 100000 的老预设会丢自定义顺序，我们照样）。
- **默认顺序**：main → worldInfoBefore → personaDescription → charDescription → charPersonality → scenario → enhanceDefinitions（关）→ nsfw → worldInfoAfter → dialogueExamples → chatHistory → jailbreak。
- **内置条目**：文本类 `main`、`nsfw`（界面叫「辅助提示词」）、`jailbreak`（界面叫「历史后指令」）、`enhanceDefinitions`；占位类 `chatHistory`、`dialogueExamples`、`worldInfoBefore`、`worldInfoAfter`、`charDescription`、`charPersonality`、`scenario`、`personaDescription`。

### 3.3 组装

按 `openai.js` 的 `prepareOpenAIMessages` → `populateChatCompletion` 行为实现。要点：

1. 按 100001 的顺序取开着、且满足 `injection_trigger` 的条目。`main` 关着也保留（内容为空）。
2. 填占位：世界书文本套 `wi_format`，场景、性格套各自的模板；人设只在人设位置是「在提示词里」时放进来。
3. 卡的 `system_prompt` 替换 `main`、`post_history_instructions` 替换 `jailbreak`，除非那条设了 `forbid_overrides` 或关着；替换文本里的 `{{original}}` 是原来那段。
4. 预算 = `openai_max_context - openai_max_tokens`（再留 3）。固定的先放，放不下就报「必需的提示词超出上下文」；续写、代写这类控制段和工具定义先预留。
5. 按位置的条目按列表顺序排；扩展的段落（作者注释的「前 / 在提示词里」、摘要）插在 `main` 前后。
6. **按深度插入**：同一深度按 `injection_order` 分组，小的在前、大的更靠近末尾；同一组里同角色的用 `\n` 合成一条，顺序 assistant → user → system。ST 自己的按深度条目（世界书 @深度、作者注释）并进 order 100 那组。深度 N = 从最新往前数第 N 条消息之前。
7. **聊天记录**：先留出新对话提示的位置，再从新往旧加，加不下就停。群聊末尾加 `group_nudge_prompt`（代写时不加）。最后一条是 assistant 时，按 `send_if_empty` 补一条 user。
8. **示例对话**：整块整块地放，每块前面放 `new_example_chat_prompt`；默认在聊天记录之后填（剩多少放多少）。
9. **名字**：按 `names_behavior`。`is_system` 的消息不发；旁白消息用 system 角色。
10. **合并 system**（`squash_system_messages`）：相邻、没有 name 的 system 用 `\n` 合并，跳过新对话提示和群聊提示，丢掉空的。
11. **接着写**：`continue_prefill` 关时，把最后一条移到末尾，后面跟一条 `continue_nudge_prompt`；开时把最后一条原样放在末尾。`continue_postfix` 加在原文后面（原文末尾已有空白时不加）。
12. 你发出的消息在发送时就展开宏（ST 的 `sendMessageAsUser`）。

### 3.4 DeepSeek 源的后处理

ST 发 DeepSeek 时（`src/endpoints/backends/chat-completions.js` 的 `sendDeepSeekRequest`）还会改写一遍，我们照做，否则对不上：

- 地址固定是 `https://api.deepseek.com/beta/chat/completions`。
- **总是**按 `semi_tools` 处理（`src/prompt-converters.js` 的 `mergeMessages`）：带 `name` 的非 system 消息把「名字: 」写进正文、删掉 name；相邻同角色的消息用 `\n\n` 合并；**第一条以后的 system 都改成 user**，再合并一次。没有工具时，工具消息改成 user、去掉 `tool_calls`。
- 没有工具、且最后一条是 assistant 时，给它加 `prefix: true`（前缀续写）。所以「接着写」开着 `continue_prefill` 时，模型直接接着原文往下写。
- `thinking: {type: show_thoughts ? "enabled" : "disabled"}`；思考开着才发 `reasoning_effort`（auto 不发；min、low → low；max → max；其他 → high）。`top_p` 为 0 时发一个极小数。只发 model、temperature、max_tokens、stream、presence_penalty、frequency_penalty、stop、seed（和工具），不发 `logit_bias`、`n`。
- 之前回合的思考内容不发回去。
- 带工具的消息补 `reasoning_content: ""`。

这意味着「提示词中间插的 system」到了 DeepSeek 都变成了 user，和相邻的 user 合在一起。增强层插的段落（导演提示、状态、记忆）也按 ST 作者注释的方式插，最后一起过这道后处理，所以和 ST 的预设配合起来行为一致。

### 3.5 缓存

DeepSeek 的缓存按前缀整段命中，命中价是未命中的五十分之一（flash 每百万 0.006 美元对 0.30 美元）。ST 默认的顺序里，世界书「角色前」紧跟在主提示词后面；哪一回合命中的条目变了，它后面的所有东西（角色设定、整段聊天记录）都得按未命中算。一回合 16k 的提示词，命中时约 0.0001 美元，全不命中约 0.0048 美元，差几十倍。

- **默认照 ST 的顺序**（兼容第一）。
- 检视页标出「这一段打碎了缓存」，并算出这一回合因此多花了多少。
- 对话设置里有一个开关「省钱排序」：把非常驻的世界书条目从「角色前 / 角色后」挪到按深度插在末尾（深度 1），常驻的不动。默认关；检视页第一次发现缓存被打碎得很厉害时，提示一次这个开关。
- 增强层自己的段落（状态、导演提示、记忆）都按深度插在聊天记录的末尾附近，不打碎前面的缓存（agent §2.6）。

### 3.6 检视

每一段都标来源（预设的哪一条、哪张卡、哪个世界书条目和命中原因、作者注释、导演提示、记忆）、token 数、缓存命中了多少、大约多少钱；后处理前后两份都能看。界面见 ui §9。

## 4. 世界书

语义照 ST 的 `world-info.js`，用同一批夹具对拍：

- **条目**：主关键词、次关键词和逻辑（任一 / 全部 / 都不 / 不全，即 selectiveLogic 0 AND_ANY、1 NOT_ALL、2 NOT_ANY、3 AND_ALL）、常驻、扫描深度、区分大小写、整词匹配、插入位置（角色前后、示例前后、作者注释前后、按深度并指定角色、出口 outlet）、顺序、触发概率、组（同组只取一条，按权重；组内优先级、组评分）、粘滞 / 冷却 / 延迟、递归（能再触发别的条目；可以禁止被递归、禁止递归别人、只在递归时触发）、关键词写成 `/…/i` 就是正则。
- **定时效果**（粘滞、冷却）的状态存在对话的 `timedWorldInfo` 里，跟着对话走。
- **预算和策略**：ST 的世界书全局设置（扫描深度、预算占上下文的比例和上限、最少激活条数、递归、角色书和全局书的排序策略、是否带名字扫描）放在酒馆设置里，默认值照 ST。
- **来源**：卡自带的 `character_book`；全局世界书；绑在对话上的世界书（`chat_metadata.world_info`）；人设绑定的世界书；增强层的记忆书（agent §5.3）。
- **V3 装饰器**（R2）：条目内容开头的 `@@名字 值`，一行一个，处理后去掉。支持规范里的全部：`@@activate_only_after`、`@@activate_only_every`、`@@keep_activate_after_match`、`@@dont_activate_after_match`、`@@depth`、`@@reverse_depth`、`@@role`、`@@scan_depth`、`@@is_greeting`、`@@position`、`@@ignore_on_max_context`、`@@additional_keys`、`@@exclude_keys`、`@@is_user_icon`、`@@dont_activate`、`@@activate`、`@@disable_ui_prompt`。`@@@` 开头的行是上一行的后备，至少支持 5 级；不认识的忽略。`@@instruct_depth` 这类给文本补全的不做。
- 引擎是纯 Dart，不碰 I/O，同样的输入永远同样的输出。

## 5. 宏和变量

### 5.1 宏

ST 有两套宏引擎。1.17.0 起新装默认用新引擎（「Macros 2.0」，`public/scripts/macros/`），老用户保留原来的设置；旧引擎（`public/scripts/macros.js`）不再更新。两套都实现，设置里能切，默认新引擎。

**新引擎的写法**

- 先把 `<USER>`、`<BOT>`、`<CHAR>` 这类老写法换成宏，再整段解析成语法树，从左到右求值；参数里的宏先求（由内向外），`{{if}}` 只求选中的分支。不认识的宏原样留下（里面的宏已经展开）。
- 块写法 `{{名字::参数}}…{{/名字}}`；条件 `{{if 条件}}…{{else}}…{{/if}}`，`!` 取反，空串、`false`、`off`、`0` 为假。
- 变量简写：`{{.x}}` 本地变量，`{{$x}}` 全局变量，支持 `= += -= ++ -- || ?? ||= ??= == != > >= < <=`。
- 注释 `{{// …}}`；参数可以用 `::` 或空格分隔。

**宏清单**（别名不列）

| 组 | 宏 |
|---|---|
| 名字和卡 | `user`、`char`、`group`、`groupNotMuted`、`notChar`、`charDescription`、`charPersonality`、`charScenario`、`persona`、`mesExamples`、`mesExamplesRaw`、`charDepthPrompt`、`charCreatorNotes`、`charFirstMessage`、`charVersion`、`charPrompt`、`charInstruction`、`model`、`original`、`isMobile` |
| 聊天 | `lastMessage`、`lastMessageId`、`lastUserMessage`、`lastCharMessage`、`firstIncludedMessageId`、`firstDisplayedMessageId`、`lastSwipeId`、`currentSwipeId` |
| 基础 | `space`、`newline`、`noop`、`trim`、`if`/`else`、`input`、`maxPrompt`、`maxContext`、`maxResponse`、`reverse`、`//`、`roll`、`random`、`pick`、`banned`、`outlet` |
| 时间 | `time`（可带时区）、`date`、`weekday`、`isotime`、`isodate`、`datetimeformat`、`idleDuration`、`timeDiff` |
| 状态 | `lastGenerationType`、`hasExtension` |
| 变量 | `setvar`、`addvar`、`incvar`、`decvar`、`getvar`、`hasvar`、`deletevar`、`setvarkey`、`getvarkey` 和对应的 `…globalvar` |

- `{{random}}` 每次求值都重掷；`{{pick}}` 按「对话的哈希 + 位置」固定，换回答也不变。
- `{{addvar}}`：原值是 JSON 数组就追加，两边都是数字就相加，否则拼字符串。
- 1.19.0 起变量宏支持数组和对象的取值。
- 酒馆助手加的宏（`{{get_message_variable::路径}}`、`{{format_message_variable::路径}}` 等）在 §8.2。

### 5.2 变量

| 作用域 | ST / 酒馆助手里在哪 | 我们存在哪 |
|---|---|---|
| 本地（对话） | `chat_metadata.variables` | `chats` 表的对话变量 |
| 全局 | `extension_settings.variables.global` | 酒馆的全局变量文件 |
| 消息（每条消息、每个备选各一份） | 酒馆助手：消息对象的 `variables[swipe_id]` | 节点的状态（总纲 §5.2）：每个备选本来就是一个节点 |
| 角色 | 卡的 `extensions.tavern_helper.variables` | 卡里，原样 |
| 预设 | 预设的扩展字段 | 预设文件里，原样 |

增强层的状态放在消息变量的 `dshgo` 键下（agent §2.1），和 MVU 的 `stat_data` 并排。

### 5.3 MVU

MVU（MagVarUpdate，MIT）是中文卡里最常见的变量框架。它是一段酒馆助手脚本，卡里用 `import 'https://gcore.jsdelivr.net/gh/MagicalAstrogy/MagVarUpdate@master/artifact/bundle.js'` 引入。它做的事：

- **初始值**：世界书里注释带 `[initvar]` 的条目（关着的也算），内容按 YAML → JSON5 → 修复后的 JSON 依次尝试解析，所有这类条目深度合并进 `stat_data`。开场白里的 `<initvar>…</initvar>` 会替换这一份。
- **存在哪**：消息变量里：`stat_data`（当前值，经典写法是 `[值, "说明"]`）、`schema`、`initialized_lorebooks`，以及已废弃的 `display_data`、`delta_data`。
- **模型怎么改**：回复里的 `<UpdateVariable>`（或 `<VariableUpdate>`、`<update>`）块，里面是 `_.set('路径', 旧值, 新值);//原因`、`_.insert`、`_.remove`、`_.add`；也认 `<JSONPatch>` 块。思考类标签里的内容不算。参数按 JSON → JSON5 → YAML → 算式解析，不 `eval`。
- **事件**：`mag_variable_initialized`、`mag_variable_update_started`、`mag_command_parsed`、`mag_variable_update_ended` 等；全局对象 `Mvu` 有 `getMvuData`、`replaceMvuData`、`parseMessage`。
- **状态栏**：前端块用酒馆助手的 `getVariables({type: 'message', message_id})` 或 `Mvu.getMvuData` 读；提示词里用 `{{get_message_variable::stat_data}}` 或 EJS 的 `getvar("stat_data")`。卡通常配两条正则：一条藏掉 `<UpdateVariable>`，一条藏掉占位标签。

**我们的做法**（2026-11-14 改）

- **原先的打算是让 MVU 自己的脚本跑**，取了 master 的构建看过后放弃：它运行时 import 51 个远程模块（各家模型的适配、mathjs 等），还直接读写 ST 的内部对象（`SillyTavern.chat`、`saveChat`、`registerMacro`、`loadWorldInfo` 等 22 种），离线做不到，要模拟的东西太多，还跟着上游变。
- **改成引擎原生实现 MVU 的变量协议**（MIT，照它的源码移植语义，版权与来源记进 THIRD_PARTY_NOTICES.md）：`[initvar]` 初始值、楼层里的 `stat_data`、`<UpdateVariable>` 和 `<JSONPatch>` 的解析、相关的宏和事件。MVU 的「额外模型解析」和它的设置面板不做。
- 卡脚本 import MVU 的地址时，App 换成本地的小模块，挂出全局 `Mvu`（`getMvuData`、`replaceMvuData`、`parseMessage`、事件名），接到引擎上。前端块照常用 `getVariables` 或 `Mvu.getMvuData` 读。
- **App 怎么接（2026-11 阶段四）**：卡里（脚本、正则、开场白）出现 MagVarUpdate，或 `extensions.dshgo.mvu.enabled` 为真，就算用 MVU。聊天页对这类卡调一次 `setMvuEnabled` 打开这段对话的原生 MVU（不管用哪种显示方式），之后每条回复由引擎算变量。整页画布里卡脚本照常跑：MVU 的 import 换成本地 `Mvu`，事件监听改过的候选随 Ack 交回引擎。默认的岛屿不跑卡脚本，但状态栏这类读变量的前端块会拿到本楼层的只读变量（`getVariables`、`Mvu.getMvuData`、`getCurrentMessageId`、`waitGlobalInitialized('Mvu')`），写操作会被拒绝并说明要去整页画布；岛屿里也带上 jQuery 和 lodash。
- **原生状态面板**能直接读 `stat_data`（ui §8 的变量树视图），整理者也能读。
- **zod 版**（`StageDog/tavern_resource` 的 `mvu_zod`）是 PolyForm NonCommercial：卡自己引入时照常从网上加载（能不能跑看它用到的接口），我们不打包；它的 schema 校验先不支持。

### 5.4 提示词模板（EJS）

ST-Prompt-Template 扩展（AGPL-3.0）让提示词、世界书里能写 `<% %>`（EJS），MVU 的教程就用它的 `getvar("stat_data")`。它是 AGPL，可以复用其实现。R3 之前拿一批真实的中文卡统计用得多不多，再定做不做。

## 6. 正则和显示

### 6.1 正则

- **字段**（13 个）：`id`、`scriptName`、`findRegex`、`replaceString`、`trimStrings`、`placement`、`disabled`、`markdownOnly`、`promptOnly`、`runOnEdit`、`substituteRegex`、`minDepth`、`maxDepth`。
- **`placement`**：1 用户输入、2 AI 输出、3 斜杠命令、5 世界书、6 思考。旧的 0 迁移成「两个都勾」，旧的 4 迁移成 3。**`substituteRegex`**：0 不替换、1 原样、2 转义；旧卡里的 `true` 当 1。
- **三处来源，依次执行**：全局 → 预设（`extensions.regex_scripts`）→ 角色（卡里），同一处按数组顺序。
- **什么时候跑**：

| 时机 | 跑哪些 | 结果 |
|---|---|---|
| 显示 | 勾了 `markdownOnly` 的 | 只改显示，每次渲染都跑，不存 |
| 组装提示词 | 勾了 `promptOnly` 的 | 只改发给模型的 |
| 收到回复、你发送、开场白、斜杠命令、思考 | 两个都没勾的 | 直接改写存下来的正文 |
| 编辑消息 | 两个都没勾且 `runOnEdit` 的 | 同上 |

  两个都勾 = 显示和提示词都改，不写回。世界书条目走的是提示词那条路，所以 placement 5 的脚本要勾 `promptOnly` 才生效——ST 就是这样，照着做。
- **深度**：显示时，最新一条非系统消息是 0；提示词里同样从新往旧数，「接着写」时正在续写的那条是 -1。`minDepth` ≥ -1、`maxDepth` ≥ 0 才生效，空表示不限；写回存档那条路不看深度。
- **`findRegex`**：按 `/模式/flags` 切开，flags 只认 ST 认的那几个字母，否则整串当模式；编译不过就静默跳过；没有 `g` 只换第一处。
- **替换**：`{{match}}` 等于 `$0`；`$1`、`$<名字>` 展开，`$&`、`` $` ``、`$$` 不支持、原样输出；每个分组先删掉 `trimStrings`；最后整段再展开宏。
- **在哪跑**：显示用的在画布的 JS 里跑，用的就是浏览器的 `RegExp`，和 ST 完全一样。提示词和写回用的在 Dart 里跑：Dart 的正则沿用 V8 的 irregexp 规则，lookbehind、命名分组、`s` 都有；剩下的差异靠夹具兜底。
- **不弹授权**：ST 对卡和预设的正则各问一次（`regex/index.js` 的 `checkPresetEmbeddedRegexScripts` 等）。我们默认就开；角色页写着「这张卡带 3 条正则、2 个脚本」，旁边一个开关。

### 6.2 显示流水线

和 ST 的 `messageFormatting` 同一个顺序，用同一组库（showdown、DOMPurify），实现与之一致：

1. 显示用正则（按深度）。
2. 修 Markdown（默认开，可关）。
3. 「显示 <标签>」开着时把尖括号全转义（默认关）。
4. 引号包成 `<q>` 着色（跳过 `<style>` 和代码）。
5. showdown 转 HTML，选项同 ST（表格、删除线、下划线、简单换行……）。
6. `<style>` 作用域化：每个选择器前加消息容器，类名加 `custom-` 前缀（元素的 class 同步加），删 `@import`；「禁止外链资源」开着时删掉值里带 `://` 的声明。
7. DOMPurify 清洗，白名单同 ST：去掉 `script`、`iframe`、`object`、`embed`、`link`、`meta` 和 `on*`、`javascript:`；保留 `style`、表单、`details`、SVG、`data-*`。
8. 前端块：`<pre>` 里含 `html>`、`<head>` 或 `<body` 的，交给 §8.1。
9. 我们的组件标签（`<dsh-*>`，agent §6.2）在第 7 步前换成画布的组件，不经 DOMPurify 清掉。

伙伴模式的字幕只显示纯文字；带排版的回复在伙伴的「记录」里用同一块画布渲染。

### 6.3 画布的 DOM 和 CSS

- 画布按 ST 的消息结构搭 DOM（`#chat > .mes[mesid] > .mes_block > .mes_text`，名字在 `.name_text`，头像在 `.avatar`），卡里写给 ST 的 CSS、选择器和 ST 主题的自定义 CSS 大多能直接生效。
- ST 的 CSS 变量（正文、斜体、引号的颜色，模糊强度等）在画布里定义同名的，默认取 App 的颜色。

## 7. 聊天记录

ST 的聊天记录是 `.jsonl`：第一行是头，之后每行一条消息。

- **头**：`{"chat_metadata": {…}, "user_name": "unused", "character_name": "unused"}`。`chat_metadata` 里我们读写的：`integrity`（uuid）、`variables`、`main_chat`（分支的来源）、`chat_id_hash`（`{{pick}}` 的种子）、`timedWorldInfo`、`world_info`（绑定的世界书）、`script_injects`、`quickReply`、作者注释的 `note_prompt` / `note_interval` / `note_depth` / `note_position` / `note_role`、对话级的 `scenario` / `system_prompt` / `mes_example` 覆盖。其余原样保留。
- **消息**：`name`、`is_user`、`is_system`（不发给模型）、`send_date`、`mes`、`swipes`、`swipe_id`、`swipe_info`、`force_avatar`、`extra`（`reasoning`、`display_text`、`type`、`model`、`api`、`token_count`、`tool_invocations`、`branches`、`bookmark_link` 等），以及酒馆助手的 `variables[]`（每个备选一份）。
- **分支和存档点**：ST 里都是另一个文件，复制了 0 到分叉处的消息，`chat_metadata.main_chat` 指向原对话，来源消息的 `extra.branches` / `extra.bookmark_link` 记着它。
- **群聊**：群的定义在 `groups/<id>.json`（成员、`activation_strategy` 0 自然 / 1 轮流 / 2 手动 / 3 随机池、`generation_mode`、`disabled_members` 等），记录在 `group chats/<id>.jsonl`。

**导入**：一个文件变成一段对话；同一角色的一批文件（ST 导出的整个文件夹）里，`main_chat` 指过来的分支按共同的前缀接到树上，变成一段对话的不同分支。`swipes` 变成兄弟节点，`variables[i]` 变成第 i 个兄弟的状态。

**导出**：当前这条路写成主文件；每个节点的兄弟写进 `swipes`（`swipe_id` 指当前那个）；别的分支各写成一个分支文件，`main_chat` 指回主文件，来源消息的 `extra.branches` 记上——和 ST 自己存分支的方式一样。增强层的东西放在 `extra.dshgo`，ST 读到会忽略。`integrity` 每次导出新生成。

## 8. 酒馆助手

依据酒馆助手 4.12.0 的**公开文档和对外行为**。它是 PolyForm NonCommercial 1.0.0，和 AGPL 不兼容：实现时只给 Pro 看文档和我们写的行为说明，不给源码。

### 8.1 前端块

- 消息里 `<pre>` 包着整页 HTML（含 `html>`、`<head>` 或 `<body`）的，把那段藏起来，换成一个懒加载的 iframe（`srcdoc`）。外壳先放基础样式和常用库，再把卡的代码整段放进 `<body>`。
- 高度：iframe 里监听 body 的尺寸，直接改自己的高度；`vh` 换成父窗口高度的变量。
- 只渲染最近若干条（同酒馆助手的「渲染深度」），滚出屏幕的卸掉。
- 常用库打包在 App 里，不从 CDN 拉：jQuery、jQuery UI（含 touch-punch）、Vue、Vue Router、Tailwind、FontAwesome、lodash、EJS、YAML、showdown、toastr、zod。合计约 1–2 MB。

### 8.2 接口

iframe 和画布同源（酒馆助手就是这样，卡会直接用 `window.parent`、`frameElement`）。画布提供一个兼容的 `TavernHelper`，挂到每个 iframe 的全局上：

| 类别 | 函数 | 落到哪 |
|---|---|---|
| 楼层 | `getChatMessages`、`setChatMessages`、`createChatMessages`、`deleteChatMessages`、`rotateChatMessages` | 这段对话当前这条路的消息树 |
| 显示 | `formatAsDisplayedMessage`、`retrieveDisplayedMessage`、`refreshOneMessage` | 画布 |
| 变量 | `getVariables`、`replaceVariables`、`updateVariablesWith`、`insertOrAssignVariables`、`insertVariables`、`deleteVariable` | §5.2 的五种作用域 |
| 事件 | `eventOn`、`eventOnce`、`eventEmit`、`eventEmitAndWait`、`eventOnButton`…… | 我们的生命周期按 ST 的事件名发出 |
| 生成 | `generate`、`generateRaw`、`stopGenerationById` | 经 App 调模型 |
| 斜杠命令 | `triggerSlash` | §8.4 |
| 世界书、角色、人设、预设 | 增删改查 | 和酒馆助手一样，所有的都能读写 |
| 正则、提示词注入 | `getTavernRegexes`、`formatAsTavernRegexedString`、`injectPrompts` | §6.1、§3.3 |
| 其他 | 脚本按钮、音频、`substitudeMacros`（原拼写如此）、`SillyTavern.getContext()` 的常用部分 | — |

提示词里酒馆助手的宏（`{{get_message_variable::路径}}`、`{{format_message_variable::路径}}` 等）和 §5.1 的宏一起支持。

### 8.3 嵌入脚本

- 卡里的 `extensions.tavern_helper.scripts` 是一棵脚本树（脚本和文件夹；旧字段 `TavernHelper_scripts` 自动迁移）。每个开着的脚本放进一个隐藏 iframe，用 module 方式执行；脚本声明的按钮显示在输入区上方。
- 酒馆助手让脚本直接用 ST 页面的 `$` 改 ST 的界面；我们的画布按 ST 的消息结构搭 DOM（§6.3），常见的选择器能用，改 ST 侧栏、设置面板的那类不支持。

### 8.4 斜杠命令

`triggerSlash` 和输入框里 `/` 开头的话都走这里。先做常用的一组：

- 变量：`/setvar` `/getvar` `/addvar` `/incvar` `/setglobalvar` `/getglobalvar` `/flushvar`
- 流程：`/if` `/while` `/times` `/run` `/pass` `/abort` `/return`
- 生成：`/gen` `/genraw` `/trigger`
- 发消息：`/send` `/sendas` `/sys`（`/nar`）`/comment`
- 注入：`/inject` `/listinjects` `/flushinject`
- 交互：`/echo` `/input` `/buttons` `/popup` `/setinput`
- 消息：`/hide` `/unhide` `/messages` `/cut` `/del`
- 世界书：`/getchatbook` `/findentry` `/createentry` `/setentryfield`

这份排序是判断，不是统计；R3 之前拿真实卡统计一遍再调。

### 8.5 快速回复

- 快速回复组的 JSON（`{version: 2, name, qrList, …}`，每条有 `label`、`message`（STscript）、各种「在什么时候自动执行」）原样导入。
- ST 的卡本身不带快速回复，角色和快速回复组的绑定存在用户设置里；我们存在角色的本地设置里（不进卡）。
- 显示在输入区上方的胶囊里（ui §6）。

## 9. 可选的保护

默认和 ST 加酒馆助手一样，卡想做什么都行。画布从 App 里只听 `127.0.0.1` 的小服务器加载（路径带随机令牌，同伙伴舞台），和 App 之间是一个 JS channel，承载 §8.2 那张表里的调用。卡的 `alert`、`confirm`、`prompt` 用 App 的对话框显示，链接用浏览器打开，网页要相机、麦克风、定位时问你。

下面这些是开关，放在酒馆设置里，也能按卡单独设。用户自己选，**默认都关**：

| 开关 | 防的是什么 | 打开后 |
|---|---|---|
| 拦截本机和局域网地址 | 卡里的脚本访问本机的其他服务（引擎、伙伴小屋的回环服务）或局域网里的设备 | 画布的 CSP 只放画布自己的地址和外网，挡掉其他回环端口和局域网地址（含 WebSocket） |
| 禁止外链资源 | 卡从外网拉图片、字体、脚本，或把内容发出去 | 只放 App 自己的地址。ST 的「禁止外链媒体」（ST 里默认开）也归到这一项 |
| 单独的网页存储 | App 里所有 WebView 共用一个渲染进程和 cookie，卡发往网页版主机的请求会带上它的登录 cookie | 画布用单独的 WebView Profile（androidx.webkit 的多 Profile）；系统 WebView 太旧时改成离开对话就清空 |
| 只许读写这张卡 | 脚本改别的角色、别的世界书 | `TavernHelper` 的增删改查只限这张卡和这段对话 |
| 脚本调用模型的上限 | 脚本反复调 `generate` 花钱 | 每分钟、每条消息有上限，检视页标「脚本发起」 |
| 正则超时跳过 | 写得很慢的正则（灾难性回溯）把对话卡死 | Dart 一侧放后台 isolate，超时就跳过这个脚本；画布卡住就重载并停掉它 |

## 10. 对拍

- **录请求**：在电脑上跑 ST 1.19.x，DeepSeek 源的反向代理地址指向一个只录请求的假接口。用 ST 自己的接口导入卡、预设、世界书、聊天记录，触发一次生成，录下请求体——这就是 DeepSeek 会收到的东西。夹具 = 输入（卡、预设、世界书、聊天记录、设置）+ 录到的请求。
- **录显示**：把 ST 的显示流水线放进 jsdom 跑同样的消息，录下 HTML。
- **测试卡**：一批我们自己写的卡、预设、世界书，覆盖每个字段和组合，放进仓库。真实的热门卡只在本机测，不进仓库。
- `dsh_tavern` 的测试逐字比较请求、逐项比较世界书命中和正则结果；显示结果比较清洗后的 DOM。
- ST 升级时重录一遍，看差异决定跟不跟。

## 11. 许可证

| 项目 | 许可证 | 我们怎么用 |
|---|---|---|
| SillyTavern | AGPL-3.0 | 复用实现，版权与来源见 THIRD_PARTY_NOTICES.md |
| Character Card V3 规范 | MIT | 照规范实现 |
| MagVarUpdate（MVU） | MIT | 自带一份构建，保留许可证 |
| ST-Prompt-Template（EJS） | AGPL-3.0 | 要做的话可以复用其实现 |
| RisuAI | GPL-3.0 | 能和 AGPL 合并；目前只参考 |
| 酒馆助手（JS-Slash-Runner） | PolyForm NonCommercial 1.0.0 | 按公开文档重写 |
| `mvu_zod`、tavern_helper_template | PolyForm NonCommercial 1.0.0 | 不打包；卡自己引入时照常跑 |

以上是工程上的判断，不是法律意见。

## 12. 待定

- 酒馆助手的接口面很大：先以 4.12 为准，按真实卡里的调用频率排先后。
- EJS 提示词模板做不做（§5.4）。
- 自带的 MVU 版本怎么跟上游：跟着 App 发版更新，还是单独下载。
- 单独 WebView Profile 要求的最低系统 WebView 版本。
- ST 新宏引擎里还没实现的标记（`!`、`?`、`~`、`>`），等 ST 实现后再跟。
