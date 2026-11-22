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
| toolRegistry | 一次同步所有活跃绑定，执行定义求值、UUID/临时缓存、注销/裁剪/保留注册，返回 tools 与 diagnostics。 |
| toolDefinition | 用 Function('console', source)() 求工具对象，保留 action/formatMessage 闭包，仅返回 JSON 描述。 |
| toolAction | 调用已保留的 action(args)，顺序 await；不重新求值定义。 |
| toolFormatMessage | 调用已保留的 formatMessage(args)。 |

响应 JSON：`{requestId,value,isUndefined,arguments,scriptLogs,scriptLogsDropped,scriptLogValuesTruncated}`；App 另可添加真实 `committed` 事实，并用 `TavernSPresetEvaluationResult.fromJson` 还原。两项计数缺省为 0，兼容旧页面返回。带结构化宿主 issues 时可直接构造 DTO 的 issues 参数（JSON convenience factory 当前不解析 issues）。
toolRegistry 的 arguments[0] 为 `{bindings:[{identifier,code,uuid?}],activeIdentifiers:[...]}`。value 为 `{tools:[{identifier,code,sessionId,definition}],diagnostics:[{identifier,message}]}`；definition 含 name/description/parameters/hasAction/hasFormatMessage，以及可选 displayName/stealth。页面保留回调于 `generationId + ':' + returnedSessionId`；主引擎随后按该 sessionId 调用，不能重新执行定义来找 action。
`isUndefined` 与 JSON null 分开：FinalRequestProcessing 的 undefined 采用修改后的 arguments[0].request；ChatSquash 数组 undefined 采用修改后的 arguments[0]。
关闭合并时，原源 runPostScript 也接受 `['A']` 这样的 primitive 消息数组；本包后续 PromptSegment 需要消息 object，会在该类型边界报错，不把它伪装成源脚本回退。固定源54向量中53项对齐，这1项边界有单独测试与说明。
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
