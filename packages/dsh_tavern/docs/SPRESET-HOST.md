# SPreset App host 接线契约

本文件描述 W11 包内能力与 owner 尚需完成的页面接线。固定行为来源为 [SPreset inject.js](https://github.com/starowo/starowo.github.io/blob/53bd585da14248ba10baaede7fc7ed0cebe1eeeb/regex_bind/inject.js)。实现为独立 Dart/JS 协议代码，不加载该 runtime。

## 1. 接入点与同页要求

从 `package:dsh_tavern/dsh_tavern.dart` 导入公开类型。已有 App `TavernScriptHost` 可以额外 implements：

```dart
abstract interface class TavernSPresetScriptHost {
  Future<TavernSPresetEvaluationResult> evaluateSPreset(
    TavernSPresetEvaluationRequest request,
    TavernScriptCancellation cancellation,
  );
  Future<void> releaseSPresetSession(String sessionId);
}

abstract interface class TavernSPresetRequestObserver {
  Future<void> observeSPresetRequest(
    TavernSPresetRequestSnapshot request,
    TavernScriptCancellation cancellation,
  );
}
```

继续用 `engine.scripts.attachHost(host)` 附加同一个对象；原接口没有增加抽象方法。没有额外能力时，原有脚本 ABI 仍可用，但依赖 SPreset JS 的功能会产生可见 issue。

将 `assets/spreset_page_runtime.js` 作为 owner 页面资产安装一次。页面必须是当前用户脚本实际运行的持久 realm，有同一 localStorage 命名空间及已授权的 TavernHelper/SillyTavern facades。不要在每次调用中新建空白页或换成不共享存储的孤立 iframe。
本包没有修改 Flutter 页面；owner 负责把资产纳入 App 资源、加载顺序、当前 chat/page 路由及 bridge RPC。

## 2. JSON 求值协议

`request.toJson()` 给出 detached JSON，字段为：

| 字段 | 含义 |
| --- | --- |
| requestId | 一次求值的唯一关联 ID；响应必须原样返回。 |
| chatId / generationId | 当前生成所属上下文。 |
| sessionScope | 每次生成实例的内部唯一前缀；generationId 可复用，不能用它代替此值。旧直接调用可省略。 |
| sessionId | 本次生成内保留函数/状态的键；释放时按该键清理。 |
| stage / identifier | 可见诊断阶段与可选 prompt 绑定 ID。 |
| kind | 下表求值方式。 |
| source | 用户函数表达式或 ToolBindings 的函数体；不是 URL。 |
| cacheKey | 单个 toolDefinition 兼容通道的身份提示；主引擎用 toolRegistry 内的原始 UUID 和 callback sessionId。 |
| reset | true 时重编译该普通函数 session 并清空状态。 |
| captureLogs | 仅 App 全局 opt-in 打开且本次启用日志时为 true；缺省 false。 |
| arguments | 函数实参的 JSON 数组；返回中携带修改后的数组。 |

页面 RPC 调用 `globalThis.DshSPresetPageRuntime.evaluate(request, signal)` 并等待其返回对象。通过 JSON/RPC 传 request 对象；不要把未经编码的 source 拼进另一层 JavaScript 字符串。

| kind | 页面行为 |
| --- | --- |
| validateFunctionExpression | 编译表达式，确认是函数，不调用；用于先验证输出拦截器。 |
| functionExpression | 编译表达式并 await 调用结果；EntryCondition/Output/Final/工具文本 formatter。 |
| syncFunctionExpression | direct eval 并同步调用；ChatSquash 支持语句完成值，原源不 await Promise。 |
| toolRegistry | 缺省sync保持原同步；公开native还使用read/refresh，见下表。返回tools、diagnostics及明确模式ack。 |
| toolDefinition | 用 Function('console', source)() 求工具对象，保留 action/formatMessage 闭包，仅返回 JSON 描述。 |
| toolAction | 调用已保留的 action(args)，顺序 await；不重新求值定义。 |
| toolFormatMessage | 调用已保留的 formatMessage(args)。 |

响应 JSON：`{requestId,value,isUndefined,arguments,scriptLogs,scriptLogsDropped,scriptLogValuesTruncated}`；App 另可添加真实 `committed` 事实，并用 `TavernSPresetEvaluationResult.fromJson` 还原。两项计数缺省为 0，兼容旧页面返回。带结构化宿主 issues 时可直接构造 DTO 的 issues 参数（JSON convenience factory 当前不解析 issues）。
toolRegistry 的 arguments[0] 为 `{bindings:[{identifier,code,uuid?}],activeIdentifiers:[...]}`。value 为 `{tools:[{identifier,code,sessionId,definition}],diagnostics:[{identifier,message}]}`；definition 含 name/description/parameters/hasAction/hasFormatMessage，以及可选 displayName/stealth。页面保留回调于 `(sessionScope ?? generationId) + ':' + returnedSessionId`；主引擎总是传sessionScope，并用同一前缀调用与释放，不能重新执行定义来找 action。缺省generationId只兼容旧的直接页面协议调用。

公开native的toolRegistry增加可选arguments[0].registryMode；缺省请求形状仍是sync。
更新asset的同步响应另含registryModes:['sync','read','refresh']及registryMode:'sync'。
附加JavaScript host只有明确声明能力后才接收新模式，每次新响应必须同名ack；缺能力/缺ack会可见失败，不能以空tools或退回sync冒充支持。已有Tavern/Host抽象接口没有新成员。
升级页面asset并重新加载该画布后可重新发起生成；能力按本次生成的实际响应读取，不保留永久失败标记。
没有附加JavaScript host的数据型预设沿既有路径，不因该协议额外要求页面；原本需JS的模块仍沿原可见失败规则。完全没有启用SPreset的普通预设保留原来的晚host/page捕获，START内host更换仍按原issue-only规则处理；不是把所有普通生成都纳入新增SP phase。
ADD13/14：整个配置没有任何 valid 且 enabled 的 ToolBindings 时，native 与 Helper 均不发 registry RPC；即使 host 实现了接口而页面 runtime 关闭，纯数据 SPreset 也可生成。配置有可用绑定、只是被 order/Entry 暂时筛空时，仍保留原 empty sync/read/refresh 清理与晚读。前一种零 RPC 会跳过固定源本会执行的旧注册清理，是 owner 指定的 native 可用性取舍，不能称三种空集合行为都与原源相同。
已配置绑定仍尝试 START sync。本次 function_calling=false 且失败响应未广告 refresh 能力时，sync 失败只诊断、不强制不存在的 refresh；实际广告了 refresh 则仍刷新。真正需要 registry 的 read/refresh 失败继续可见阻断；启用的其他 JS 模块仍独立校验，不能统一吞掉 runtime 缺失。

| registryMode | 定义/注册行为 | 本次返回与绑定 |
| --- | --- | --- |
| sync（缺省） | 同步bindings、缓存与注册/注销，按activeIdentifiers选择 | 保留旧tools/diagnostics，绑定本sessionScope |
| read | 不执行定义、不改缓存或注册；仅以当前activeIdentifiers查询实际共享注册 | 返回并绑定当前generation所选receiver；ack=read |
| refresh | 同步bindings与未来注册，执行源码SETTINGS_READY后的刷新 | 返回diagnostics和空tools；不重绑已选session、不改当前body；ack=refresh |

同页嵌套请求可在outer wire前改变当前注册；read必须查询页面实际集合，不能用outer早期返回的私有副本。
refresh可改变未来请求，但本次已选工具和其action receiver保持；generation release仍只释放自己的sessionScope。
同一页面的 toolRegistry 调用按到达顺序串行处理 sync/read/refresh，失败后队列仍可继续；其它 Output、Final、action 求值不进入此队列。一次 await 期间另一请求不能改写本次 activeIdentifiers 的选择。
`test/spreset_entry_phase_test.cjs`直接加载实际asset验证这三种行为；旧sync缓存/receiver/session测试保持。

`isUndefined` 与 JSON null 分开：FinalRequestProcessing 的 undefined 采用修改后的 arguments[0].request；ChatSquash 数组 undefined 采用修改后的 arguments[0]。
关闭合并时，原源 runPostScript 也接受 `['A']` 这样的 primitive 消息数组。generic provider 且通用后处理走原switch default/no-op时，普通与背景raw把该数组直接保留在body.messages，FinalRequestProcessing可修复后发送；未修复也交实际HTTP并保留provider错误。none、空与未知模式均属no-op；merge/claude/merge_tools/semi/semi_tools/strict/strict_tools/single及DeepSeek仍需typed转换，保留当前pre-final类型边界，不把它伪装成脚本回退。
这条通路的PromptAssembly.before/after、token与window记录的是脚本前的typed admission；body记录数组后脚本结果，最终观察器记录真正发送body。owner检查wire时应看body/最终观察，不能把typed段声称为脚本后逐项消息。没有给primitive伪造role/content、token数或来源，也没有重排Final与provider阶段。原53/54矩阵保持历史范围，新增真实HTTP用例证明这第54类输入在上述有限路径可被final修复；不宣称全部模式54/54。
函数/循环引用/page 对象不能跨 JSON 返回；OutputPreprocessing 的 `state` 保留在该页面 session，adapter 不把它序列化。原源允许的其他任意对象结果不保证可跨桥复刻。

## 3. 函数输入形状

| 阶段 | 实参 |
| --- | --- |
| EntryCondition | `{model,provider,source,type,entry,chat}`；必须返回 boolean，失败/非 bool 则当前条目不参与。 |
| ChatSquash | 合并后字符串，或关闭合并时的消息数组；数组返回 undefined 支持原地修改。 |
| OutputPreprocessing | `{buffer,chunk,hold,output,raw,final,stream,state,channel}`；string 或带 output/emit/text/content、hold/state 的对象。 |
| ToolCallFormatter | `{calls:[{id,name,arguments,signature}],defaultText,provider,stream,final:true,channel}`。 |
| FinalRequestProcessing | `{request,provider,model,source,stream,preview:false}`；返回 object 或修改 request 后 undefined。 |
| ToolBindings action / formatMessage | 模型参数 object。 |

provider 为 `{adapter,source,model}`，source 根据实际模型配置与 host 判断，不采用预设内保留的连接字段。
FinalRequestProcessing 的 request 是直连 provider HTTP body；ST 后端代理 envelope 上的专有选项不会凭空存在。stream 和 chat_completion_source 不能被此阶段改变。

## 4. 最终请求观察

`observeSPresetRequest` 位于请求 normalize、SPreset stop、FinalRequestProcessing 之后、实际模型发送之前。snapshot.body 每次访问给副本，适合 owner 的“最终请求检查”页面；修改它不修改发送。
当前普通模型请求与背景 generation 均进入这个观察点，工具后续请求也逐次观察。它不是仅在 preview 调用的测试接口。
不要从这里另发模型请求；观察结束后引擎沿既有 transport 发送。观察 host 发生变化/取消时沿既有取消流程终止。

## 5. 取消、真实副作用与关闭

一次请求只有一个真实 host Future。收到取消信号不能把已进入 action 自动认定为“未执行”，也不能重跑该 action。

- `committed:true`：有证据证明产生了提交效果。
- `committed:false`：有证据证明没有提交效果。
- `committed:null`：事实未知；任意 JS 正常 return 本身不证明 false。

adapter 不替任意脚本伪造 committed。owner 应关联原有 Helper/native bridge 的实际提交回执；无法确认时保留 null。
逻辑取消可立即结束 turn 展示；若原 host Future 随后确实返回已知 true/false，可回填同 executionId 的 unresolved receipt，保留此前封存的 wire_result_json 字节，不再生成下一次模型请求。
ADDENDUM-02 的实际 App 在取消时立即让 host Future 以错误/结果未知结算，不等待 JS 函数返回；该路径不保证另有晚事实回传。close/backup 等待的是 host Future 结算，并不证明任意 JS 已终止。页面销毁也必须结算 RPC；没有新增超时。
runtime 的 signal 仅在入口检查；任意 JS 中途继续运行及其外部副作用不能靠 AbortSignal 强停。本次沿用 App 已有立即结算方式，不添加另一套取消竞速或伪造 committed。
已有 hostVersion/cancellation/turn ownership 防止取消或页面换代后再采用结果。formatMessage await 返回后、action 进入前还会再次验证 ownership。
公开generationId可在终态后立即复用；每个内部生成实例的sessionScope和requestId均独立。旧RPC晚结算、旧release晚完成也只清旧键，不能命中新运行。scope使用独立随机isolate前缀与共享计数，不消耗业务ID生成器；同一页面由多个engine使用时也保持实例分离。owner必须原样传递sessionId/requestId，不按公开generationId重建或截断键。此处只隔离session引用，ToolBindings的UUID缓存与注册receiver仍按上游规则共享。

## 6. 页面缓存生命周期

普通函数状态保留到 `releaseSession(sessionId)`；ToolBindings 按原 UUID+code 共享闭包，另有 runtime:identifier:code 的1秒求值缓存（最多512项）。缺 UUID 不进入持久定义缓存；同步后裁剪未使用 UUID。
一次 toolRegistry 处理整个活跃集合，使重复 UUID 跨 identifier 共享、同名首项优先、注销顺序与原源相同。原源还会保留同名且 UUID 未变的已注册对象，即使此时定义代码求值已变化；adapter 保留该行为。
每个注册拥有独立 ToolDefinition receiver；普通 function 的 action 与 formatMessage 共用这个 this，原始定义对象的附加属性不会被复制到它。receiver提供原公开invoke/formatMessage/shouldRegister/toFunctionOpenAI及displayName/stealth；缺自定义formatter仍返回默认“Invoking tool”文本。此项已与固定ST类及SPreset wrapper实跑对照。
owner 在切换预设或更换页面时，应在结算活动 host RPC 后调用 `DshSPresetPageRuntime.resetPreset()`。普通 generation 结束只 releaseSession；绑定变化由下一次 toolRegistry 同步处理，不额外把全部缓存清空。resetPreset 清定义/注册/session，而上游1秒求值缓存继续按TTL过期。
同一工具上的 action 由引擎顺序执行；owner 不应把一个 action 的重试当成 transport 重试。

## 7. 原生/外部 runtime 选择

默认 `spresetRuntimeMode: 'native'`（缺省同义）。只有完整识别的官方 bootstrap 在脚本运行列表被跳过；原文仍保留，`nativeRuntimeSkipped` issue 可展示。
owner 可通过既有 settings API 写 `spresetRuntimeMode: 'external'`。该模式保留第三方 loader，并让 SPresetConfig.present=false，关闭本包原生 SPreset 功能，避免两套 hook 同时执行。
不能因为脚本长、名字含 SPreset 或文本提到 inject.js 就跳过；固定身份测试覆盖了这些阴性样例。
外部模式仍受 owner 原有脚本执行入口控制；本包不自动下载或执行 loader。

## 8. 日志与导出

页面诊断按既有 8192 UTF-16 code unit 边界省略超长字符串；超长属性名在读取该值、构造快照、序列化之前跳过整个字段，不截短键名以免碰撞。前 50 个属性中被跳过的字段不再补读后面的字段。
`scriptLogValuesTruncated` 累计页面与 Dart 两端实际发生的裁剪：每个被省略的参数/属性/数组槽计 1，长标量计 1，节点/深度预算省略的整个子树计 1，整条事件改为 preview 再计 1。不递归统计未访问的子树，不把 Accessor/Circular/undefined 等类型表示算成预算裁剪；同一槽不会既因超长键又读取其值再计数。
页面 `scriptLogsDropped` 只数被容量挤出的 console 记录，Dart 报告仍分别给 `scriptConsoleLogsDropped`（页面记录）与 `scriptLogsDropped`（Dart 求值记录）。计数按实际收集动作累计，即使相应记录后来被容量挤出也不撤销；captureLogs=false 不做快照、两项页面计数均为 0。新增字段由现有 fromJson 路径读取，不增加 App/Host 抽象接口。

`spresetLogUploadEnabled` 只读 App 全局 setting，缺省 false；聊天级同名配置忽略，聊天级写入拒绝。预设的 LogUpload.enabled 不得单独开启。owner 开启后才收集模型请求/transport/本求值通道日志。
TavernEngine 额外 implements 可选 `TavernSPresetLogApi`；`exportSPresetLogs(chatId)` 返回当前预设报告，`uploadSPresetLogs(chatId, address: ...)` 显式上传。它们没有加入原 Tavern 抽象接口；现有 Preview/Deferred wrapper 不因日志功能新增必实现成员。owner 要暴露日志时先检查实际 delegate 是否支持此能力，再显式实现/转发；不能假设所有 Tavern 都是 TavernEngine。没有自动上传。
报告形状 `{schemaVersion:1,exportedAt,client,tavernHelper,browserConsole,records}`。导出/上传均接收可选 `tavernHelper` 和 `browserConsole` Map；App 从当前持久页面采集后传入，引擎在调用入口复制并脱敏。未传时报告标记 `available:false`，不能表示实际浏览器控制台已采集。
Helper快照应区分 `configuredEnabled` 和实际iframe的 `runtimePresent`，浏览器控制台按原源500事件/512KiB字符、优先保留warn/error；这些页面采集、显示与授权入口由owner接线，不由Dart虚构。外部runtime模式关闭原生采集。
日志会脱敏，限制20条、字段和总量；每代求值日志在采集时最多500条/512KiB UTF-16字符，独立报告丢弃求值数、截断值数、页面丢弃console数。页面每次最多500条/512KiB，captureLogs=false不收集但仍转发原console。诊断对象限制深度6、节点500、集合前50项；超过8192字符的诊断字符串整条省略，不保存可能含认证片段的前缀；单条最多64KiB。
已解析API key只传给日志脱敏器，不重复调用key提供函数；已合并的HTTP文本先替换原值，因此跨chunk仍能遮蔽。完整JSON/SSE再按字段脱敏，截断/无法解析的body只存省略原因。authToken、JSON字符串、行内Bearer/Basic以及两种App快照均覆盖。上传地址和presetName在首次await前一起捕获。
已授权创建的 pending 记录在响应结束时仍会结算，不因等待日志加载或 API key 期间关闭全局开关而悬挂。若结算时全局开关关闭，记录标记 `logging_disabled`、省略响应并释放 transport 缓冲；已取得的 key 仍用于已授权记录的脱敏。此决定读取结算时的开关，不另设“本次曾关闭过”的粘滞状态。
HTTP文本按流式UTF-8解码后1MiB UTF-16字符截断，中文不按字节提前截断。日志观察不改变原生流的同步事件顺序。文件为 engine directory 内 `spreset-generation-logs.json`。缺省关闭不是限制脚本功能。
按 ADDENDUM-02 的明确要求，显式上传只接受 HTTPS 且无 URL credentials（固定 SP 源允许 HTTP，本处是 owner 指定收紧）；60秒上传超时沿原源，不是求值超时。可选 `bearerToken` 只用于此次请求的Authorization头，不加入报告；owner负责原源Discord登录UI和session，Dart不冒充登录完成。

## 9. 数据/验证变化

schema18 把工具请求上限从硬编码4改为 turn 捕获的 request_budget；迁移保持原数据和 FK。`budgetMax` API 变为 `int?`；null=显式无界、JSON null，调用方计算时应处理 null。
native roll 仍有原边界；SPreset 按 ST depth<L，默认5跟进/6请求。混合 turn 的总 budget 为两者需求上界，不表示每种工具各自都可执行该次数。
`show_thoughts` 显式原字段优先；缺字段时 generic 保留 reasoning，DeepSeek沿用config.thinking。generic显式false仅控制可见推理，不停止模型思考。
MacroNest替换形成新的括号边界时会再次扫描；沿用固定原源函数内部的1,000,000扫描步计数。首次constructor探测的额外宏展开仍只发生一次，preset切换或关开不重置engine运行期缓存。

验证入口：

```sh
dart test test/spreset_protocol_test.dart test/spreset_engine_test.dart test/spreset_migration_test.dart
node test/spreset_page_runtime_test.cjs
# 可选：只提取固定原源 runPostScript 进行同步 Promise 差分，不执行整个 runtime。
node test/spreset_page_runtime_test.cjs /path/to/fixed/regex_bind/inject.js
node test/spreset_tool_registry_test.cjs /path/to/fixed/regex_bind/inject.js
node test/spreset_tool_receiver_test.cjs /path/to/fixed/regex_bind/inject.js /path/to/fixed/tool-calling.js
```

已运行证据为 Dart 引擎+SQLite、HTTP mock 与 Node VM；不是实际 Flutter/WebView、真实外部模型 API 或完整用户预设已验证的声明。

## 10. EntryConditions 当前决策与 Helper 路径

固定上游的决策变量初始为 null，在原生 `GENERATION_STARTED` 条件求值开始时清空，全部条件结束后才发布 Map；全局 `GENERATION_ENDED` / `GENERATION_STOPPED` 清回 null。这不是跨已完成生成保留的结果缓存。来源为 [Entry hook 与决策读取](https://github.com/starowo/starowo.github.io/blob/53bd585da14248ba10baaede7fc7ed0cebe1eeeb/regex_bind/inject.js#L309-L381) 与 [ToolBindings 活跃条目](https://github.com/starowo/starowo.github.io/blob/53bd585da14248ba10baaede7fc7ed0cebe1eeeb/regex_bind/inject.js#L6566-L6581)。

| 内部 preparePreset 路径 | 条件求值 | 提示 order | ToolBindings |
| --- | --- | --- | --- |
| native（已启用SPreset的实际公开_Turn） | 普通START handler前重新求值并发布，晚prepare不重复求值 | 晚prepare读取当时的Map | early sync、budget read、wire read、随后refresh |
| native（既有私有prepare入口） | 保持prepare内求值，不假称有公开START | 应用准备时当前Map | 保持原sync |
| helperPreset | 不重新求值 | 读取仍在活动的原生决策；无 Map 时沿原 order | 同样读取当前 Map |
| helperRaw | 不重新求值 | 保留 raw 提示 order | 仍读取当前 Map |

Helper 适配器按转换后的实际请求类型选择路径：named `generate()` 转成 raw 后也用 helperRaw。Helper 私有 `js_generation_ended` 不清共享 Map；实际向该聊天画布发出全局 STOP 时调用 `_clearSPresetEntryDecisions(chatId)`。取消或更换 host 后的原生晚结果不可采用；普通全局 STOP 仅清该画布当前 Map，不额外使同画布另一条仍活着的原生条件求值失效，该求值随后仍可发布。
owner App 的同一 TavernScriptPages host 分派多个画布，SP evaluate 明确按 chatId 路由。因此活动 Map 按非空 chatId 分开；同 chat 的多个 script contexts 共享，不同 chat 的开始/END/STOP 不互相清理。host 替换清全部；无 chat 的调用不借用其他聊天的状态。公开 generationId 和单个 script contextId 都不是这份共享状态的键，Helper 关闭自己的求值 session 不清另一条原生生成的决策。
上游 ST 单个网页的全局变量可跨该页 chat 切换共享；不能据此推定 App 的不同画布是同一个 JS realm。当前按 owner 明示路由实现 per-chat 作用域，没有为未知宿主自动启用跨chat共享。
页面文档重建可能保留同一个 host/context，不能任意关闭一个 script context 就清整页 Map。可选 TavernSPresetPageLifecycle.resetSPresetPage(chatId) 见下节；PR1771 的 App 已调用此信号，本轮仍没有 Flutter/WebView reload 真机验收。
启用SPreset的实际公开_Turn现已前移Entry：在普通tavern GENERATION_STARTED/AFTER_COMMANDS处理器之前，创建同一SPresetGeneration、逐条await条件及early tool sync。provider在本次求值中捕获一次，chat在每次调用前重新读取/复制；前一条件通过实际bridge修改chat，下一条件可见。随后prepare只读取当时当前Map；START里的Helper STOP可以清它，不能把早先私有Map重新发布。
这针对实际已有公开lifecycle的send/continue/regenerate/impersonate及使用同_Turn的路径。ST generateQuietPrompt本身会走全局Generate START，但当前dsh slashquiet/B2是iframe私有生命周期；本块不改其公开ABI或伪造全局事件，仍是明确的范围边界。原显式native raw也保持原private prepare合同；Helper private START绝不触发fresh Entry。
固定ST事件实现证明later注册的makeFirst可以排在SP监听器之前；当前引擎仅保证相对其普通START处理器的次序，不声称复现任意外部listener重排。
`spreset_entry_state_test.dart`保留原共享/清理核心门禁；`w11_entry_phase_test.dart`通过真实native入口、公开Helper DTO、SQLite及生产HTTP编码器覆盖START重入、逐条件编辑、STOP/嵌套请求、wire晚读和取消/host/page epoch。后者不依赖VM reflection。页面求值host是边界替身，asset另有Node真代码门禁；尚无App/WebView端到端资格。

| 固定源顺序 | 当前实现位置 | 可改变的事实 |
| --- | --- | --- |
| SP makeFirst GENERATION_STARTED：条件→sync | _ScriptCoordinator.beforeTurn → _beginNativeSPreset | 更新当前per-chat Map及共享页面注册 |
| 普通START/AFTER_COMMANDS | 原_lifecycle循环 | 可编辑chat、清Map、进行嵌套生成 |
| prompt prepare与预算工具查询 | preparePreset读取当前Map；registryMode=read | 只选当前注册，不能重新sync恢复被early排除的定义 |
| 准入后GENERATE_AFTER_DATA/ChatSquash | spreset.assembly | 保持原准入与脚本合同，不重放宏/预算 |
| sendOpenAIRequest选择本次wire工具 | selectNativeWireTools，位于ChatSquash后 | 再读当时Map/共享注册，绑定当次receiver |
| CHAT_COMPLETION_SETTINGS_READY第二次sync | request中registryMode=refresh，Final前 | 只更新未来注册，不回写当次body或绑定 |
| fetch Final/最终观察/发送 | 原request尾部 | 按原Final权能与累计最终offered-tool授权继续 |

第二次refresh不能提前到本次wire选择前。false/default-true/STOP的首wire仍没有被early排除的工具；refresh后后续请求才恢复。若嵌套READY已先刷新，则outer的wire read看到新注册。这些特殊顺序由固定ST EventEmitter/ToolManager与SP原函数12个观察向量支持，研究报告与包内真实控制分别留档。
当前工具执行来源来自本次实际选中工具；后置刷新不新增本次执行权限。最终body的工具授权仍由累计owner工具计划处理，此块没有另造权限来源。


## 11. 可选页面 reset 与 PromptManager 集合

TavernEngine 另实现 TavernSPresetPageLifecycle；既有 Tavern/TavernScriptHost 抽象接口不增加成员。App 包装器须显式检查并转发能力，不能假设所有 Tavern 实例支持。调用是同步 void，不新增 timeout。

```dart
final lifecycle = delegate;
if (lifecycle is TavernSPresetPageLifecycle) {
  lifecycle.resetSPresetPage(chatId);
}
```

由可信 App 在该画布 pageLost 或更换 document、开始新文档调用之前调用；不直接暴露成页面可调用的任意 reset RPC。一个 chat 的多个 script contexts 共用该画布，不应在关闭任意脚本或最后一个 context 时猜测 realm 是否重建。固定 owner canvas_calls.pageLost 明确保留 context，document 过滤只处理消息归属，不能代替这个 engine 通知。
reset 清该 chat 的活动 Entry 与共享 PromptManager 集合，每 chat 单调 epoch 拒绝采用旧异步 JS 结果；不清另一 chat、不执行 JS、不撤销已发生副作用，也不声称令实际宿主 Future 结束。真实载体仍沿既有排空和回执规则。
准入 finally 先保存本代局部 PromptManager，再检查 host/page/取消身份是否允许发布共享 Map；过期观察只跳过共享发布，不抛错终止纯 Dart 准备。真正需要 JS/registry 的阶段继续检查身份；纯数据路径不因无关旧页面失效而失败。
separate 用本代拓扑分组当前 MI/图片后的消息；raw/named 使用本次 raw 自己的集合，不读取旧共享内容。完整合同与 owner 要求的上游缺陷修正见 HELPER-PROMPT-MANAGER.md。孤立 authoring preview 仍不是 ST UI dryRun。
本轮只改 engine/bridge/protocol，没有修改 owner App；PR1771 的接线代码已只读核查，仍没有 Flutter/WebView 真机结果。

## 12. 原生流式 formatter 的模型目录事实（可选）

可选 `TavernSPresetToolCapabilityHost.lookupSPresetToolModel(request,cancellation)` 返回 `FutureOr<TavernSPresetToolModelLookup>`；没有向 Tavern 或既有 ScriptHost 添加必实现成员。request 包含 generationId/chatId/source/model，toJson 保留这四项；应按 chatId 的实际画布目录查第一个严格相同的模型 ID。请求通过返回值/Future 关联，不能仅用可复用的 generationId 关联 RPC。

- `notSupplied(reason: ...)`：App 未提供原始目录元数据，或只保存了模型 ID；这不是匹配行缺能力字段的证据。
- `noMatch()`：实际目录为空、非数组或没有匹配模型。
- `matched(row)`：原目录第一条匹配的 JSON 行，含原字段；DTO 在构造和读取时均复制，宿主后续编辑不回写已返回事实。

缺接口及 notSupplied 明确使用“native 未导入目录、ST 初始 []”的 provider 默认分支，不猜模型名、不伪造 raw row，也不逐帧刷诊断。noMatch 走同源默认名单；matched 对 OpenRouter 直接读 supported_parameters，字段缺失/空数组是假，不能回退名单。其余七个专门 provider 按固定源字段规则；这些纯规则不代表新增了 provider 原生传输支持。字符串 includes 与直接字段的 JS 真值语义保留；畸形不可调用 includes 或 null Workers property 是可见失败，不是无匹配。

查询仅服务原生 OutputPreprocessing.consumeToolCalls 的流式 formatter metadata，经现有 parsed-frame callback 每帧读取；即时缓存结果不引入 await，异步结果受既有 cancellation、hostVersion 和关闭检查约束。App 应复用本地实际目录，Future 在取消/页面销毁后仍须结算；迟到结果不会采用，错误不会静默变成 noMatch。common function_calling/后处理/模型前缀已禁止时不查询。没有增加字节解析器或模型请求。

source/model 绑定本次生成捕获的真实连接，预设残留连接字段、Final 改写的 wire model 均不改它；不同 chat 的目录事实不能因共享 dispatcher host 串用。目录逐帧变化已对照原源，但 native 保留既有捕获的 source/model/预设，未声称 UI 中途换源/换开关的全部 live-global 时序等价。OpenRouter 签名在支持门槛之前收集，先前不支持工具的帧仍可给后来启用的工具提供签名。

非流式 SP response 消费不查询此接口。未提供 parsed-frame 回调的旧 custom ModelClient 仅在流式 EOF 查一次，这是旧入口的明确边界，不是逐帧源复刻。被门槛排除或格式化失败时仍沿现有原生 fragment 回放和工具授权；ST 的 unsupported 流原本不解析工具，两者授权体系的差异没有在此被重写。
一次批次混有允许/不允许 formatter 的实际 primary 工具片段时，formatter 只能看到允许部分；即使该部分成功，仍保留原生整批供原授权与回放，不能把没交给 formatter 的调用一并丢弃。阻断标记按生产 decoder 的 primary 选择规则判断，不能把 decoder 未接受的畸形 choice 算成原生片段；签名仍按既有顺序收集。

`tool/st_differential/spreset-tool-capability-oracle.cjs` 从固定 ST 真函数生成 103 个目录向量；`test/spreset_tool_capability_test.dart`、`test/spreset_tool_capability_engine_test.dart` 覆盖公共 DTO、真实生产 HTTP 编解码和宿主边界。旧 formatter 形状向量把 support 固定为 true，只证明其声明的形状/签名范围，不能单独作为完整 provider 能力证据；新接口尚需 owner 在实际 App 接线验证。
