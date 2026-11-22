# Helper 图片阶段与失败契约

本增量以共享 PromptManager 的 9070 冻结结果为父，限定 Helper DTO；原生 background ABI、Entry/工具 registry、Final/output 和宏提交协议保持其原有归属。
固定 Helper `29331c36fb9b2e880d4d488ff919317e1bc95684`（4.12.2），ST `7e8663cd9c184a550b37238218bdd32c6efc68e9`（1.19）；完整源链接/许可在 `HELPER-GENERATION-SOURCES.json`。

## 时点

| 路径 | 时点 | wire 结果 |
| --- | --- | --- |
| normal 单图 | 输入/角色字段、WI 后，PromptManager 前 | 固定源旧 image 字段不被 ST 1.19 消费，不额外附图 |
| normal 非空数组 | 输入宏/regex 后只附 literal marker；WI、集合 admission、MI 后的 READY 中找 marker | 最后一个 role=user 且 content=string 的匹配消息转 text+成功图片 parts |
| normal 缺 marker | READY 未匹配 | 不调用 resolver，附可见 warning issue 后继续实际模型请求 |
| raw 单图 input 槽 | system/示例集合 add 与外层纯文本 user reserve 后 | 解析后附到 user，不套历史图片门禁 |
| raw 单图仅 history 槽 | 同上，new_chat_prompt 准备/预留后、历史门禁前 | 门禁真才附图 |
| raw 非空数组 | 输入处理后、WI/集合预算前 | 成功图片原序、失败项跳过；显式 input 保留 parts，仅 history 时再按下面的 String 转换处理 |
| raw 覆盖历史 image | 早期系统预算之后，既有历史媒体门禁为真 | 每条历史进入 canAfford 前解析，首条不够后不额外解析后续历史图 |

普通数组使用固定字面 `__IMG_ARRAY_MARKER_`，因此 WI 可读取该串；READY 只删除命中内容里的第一个 marker。
assistant 或 parts 内 marker 不匹配；多个匹配 user 只改最后一条。整个模型请求中的其它消息保持原形。
共享 PromptManager 捕获仍发生在 READY 之前，持有 literal marker；晚改 wire 不回写 snapshot。后续 raw ChatSquash separate 仍可能读回 marker，和固定上游相同。
早期 raw system/示例 add 超预算时单图零解析；raw 数组已经解析。reserveBudget 只扣余额，不能误称所有后续预算失败都先于图片。

## 宿主必须区分的失败

`TavernHelperImageHost` 原 `Future<String> resolveHelperImage(source, cancellation)` 签名不变。
新增可选异常 `TavernHelperImageConversionFailure` 与 `TavernHelperImageConversionStage.download/base64` 可从主库直接引用。
宿主在实际网络下载、读取 blob 或 base64 编码的失败分支，构造该类型；不得仅因为任意桥 RPC 出错就归类为图片转换失败。

```dart
throw TavernHelperImageConversionFailure(
  stage: TavernHelperImageConversionStage.download, // 或 base64
  message: actualDownloadError.toString(),
);
```

如果工作由页面完成，App 应将**明确属于下载/base64 阶段**的既有错误回执映射到上述 Dart 类型。类型名是本桥契约，不是声称上游 JS 原生抛这个类。
未实现该映射的宿主仍走既有异常失败路径；返回错误对象或错误文字冒充 data URI 也不会被当成“undefined”。
引擎只对这个明确类型记录 `helperImageConversionFailed`（details.conversionStage/message）并跳过该项；采用前复核现有 cancellation、hostVersion、context 和 SPreset page epoch。
缺接口、无可用页面、取消、页面/宿主更替、DTO 结构不合法、返回值不是有效 image data URI，以及未分类的宿主异常，均仍失败可见。
顶层单图先经过 Helper 转换函数，下载/编码失败相当于源 undefined，保留原字符串。覆盖历史单图则先进入 ST `Message.addImage`：先将文本转为 parts，随后下载/编码失败仍保留 text parts，且沿用转换前的文本准入费用。历史媒体门禁不成立或无历史图片时不转换。
数组按 Promise.all 启动、原序收集成功项。全部失败仍保留 `[{'type':'text','text':input}]`，不是伪造空模型成功。
warning issue 随 `TavernScriptGenerationResult.hookIssues` 可见；实际正文请求仍须成功，才产生成功结果。

## raw 显式 user_input 数组准入

固定 Helper `handleCustomPath` 先为纯文本 user 消息预留费用，再把非空 image 数组产生的 parts 交给 `Message.createAsync`；ST 该方法只对非空 string 调用 tokenHandler，parts 保留初始 `tokens=0`。
本次窄修仅在 Helper raw 的显式 `user_input` 槽中，按该 Message 实例的零费用做集合准入；纯文本预留、系统/示例/历史费用与预算不足异常均保留。所有数组图片转换失败仍有 text parts，因此同样适用；空数组仍走 string 费用。
该局部费用不改变公开 token counter、最终 wire parts 或原生 raw 预算接口，也不代表供应商对图片零计费。history-only 顶层数组没有套用这条修复。
`w11_helper_raw_array_admission_test` 对照真实固定源八组阈值/失败向量；同一测试在父版本 5 通过、3 失败，修复后 8 通过，保留实际 HTTP 请求与失败时零请求断言。
`helper-raw-array-admission-oracle.cjs` 接受包含固定 `research/helper` 与 `research/st` 源文件的证据目录；它校验四个文件 SHA，抽取 14 个真实函数/类并记录 reserve/add/free 序列。纯文本 callback 使用现有默认计数器实测值，任何 parts 进入 callback 都失败，不推定图像 token。

## raw 仅 history 承接顶层数组

固定 `processChatHistoryAndInject` 在没有显式 user_input、但存在未过滤 chat_history 时，把已处理图片 parts 作为一条历史输入；depth 注入之后、逐条 Message/canAfford 之前调用真实 `substituteParams`。
固定 ST 的该函数先对非字符串执行 `String(content)`，再分派现代或旧宏。因此一张成功图片变成字面 `[object Object],[object Object]`；全失败数组仍有 text part，变成 `[object Object]`。即使原 user_input 缺省或为空串也如此。
桥只在原非空 image 数组的这个分支，复用 `ScriptCoercion.string` 和当前真实宏环境，再按转换后的文本做原有费用准入；不回写共享 PromptManager，也不改 Entry 或其它历史行。
上游本次 console warning 以 `helperHistoryImageArrayCoerced` issue 可见。仅该分支不再要求内部图片槽最终必须保留：源本来就把图片结构丢掉，不能随后又以图片丢失拒绝请求。
显式 input、被过滤/缺失的 history、单图、空数组均不套用转换；既有 DTO 对 image:null/空字符串、user_input:null 和 history.prompts:null 的拒绝也未放宽。
`w11_helper_history_array_coercion_test` 的同一 29 项测试在父版本 19 通过/10 失败，修复后全过；现代/旧引擎另实际核变量写入、input random→resolver→depth random 的副作用顺序。
`helper-history-array-coercion-oracle.cjs` 校验 6 份固定源，执行 20 个实际函数/类；默认 26 向量逐字节匹配 fixture，`--media-off-control` 另核两种宏模式在历史 H、媒体门禁关闭时仍丢 parts。
该 oracle 的 `substituteParams` 本体含真实 String 转换和引擎分派；两种宏后端是明确记录参数的边界，不能当作完整 upstream MacroEngine 差分。既有 image_paths 中一条 identity-substituteParams 旧探针的发图期望据此更正，旧失败日志保留。

## 证据与复现

`w11_helper_image_phase_test.dart` 使用真实公共 DTO、引擎、SQLite、宏/WI 和生产 HTTP 编解码；仅 resolver/网络对端为受控宿主。
覆盖阶段随机宏计次、WI marker 激活、缺/错误 role marker、最后匹配、raw 预算优先、两类单图失败、混合数组逆序完成仍保序、全失败 text parts、协议/能力/DTO 错误及取消/host/page 拒晚结果。
固定源转换 oracle：

```sh
node tool/st_differential/helper-image-conversion-oracle.cjs /path/to/pinned/src/function/generate/utils.ts
```

输出须与 `test/fixtures/w11_helper_image_conversion_source.json` 逐字节一致；工具校验固定 utils SHA，仅抽取真实 convert/array 函数，不运行整个扩展。
10 个转换向量含两阶段 undefined、并行数组保序/全失败、缺 marker/assistant/parts；真实阶段控制流另有 25 函数/类、10 向量的只读审计冻结记录。
`w11_helper_history_image_failure_test` 另对照完整固定 ST Message 类与 Helper 转换函数的四组下载/base64 分支，覆盖历史/top-level 的不同失败形状、文本费用边界与媒体门禁。对应 `helper-history-image-failure-oracle.cjs` 接受 pinned openai.js 与 utils.ts 两个路径，输出须与 `w11_helper_history_image_failure_source.json` 逐字节相同。
既有 `w11_helper_image_test`、`w11_helper_history_test` 和 `w11_helper_transport_test` 保留成功路径、共享 marker 与生命周期回归。

## 仍有明确边界

App File 必须先编码为 data URI；数据 URI 的 MIME/非空字节校验仍是此桥的明确协议边界，未放宽为上游任意字符串。
ST 单图 `Message.addImage` 的 createThumbnail、尺寸读取和图像 token 回退没有复现；缺真实媒体/图像能力时不发明尺寸、压缩结果或精确费用。
源数组直接创建 parts 或在 READY 修改内容，不走单图 addImage；本次仅对显式 raw input 的 Message 准入费用作上述对齐，normal READY、历史及其它路径不因此宣称 token 完全等价。
原始历史宏与图片的更细逐条交错、完整页面 listener 竞争和外部供应商均未在此签全等价；失败时原有背景写意图仍不会自动落盘。
App 必须接入真实 resolver 及明确失败映射；本补丁没有修改 App 页面，也没有真机/浏览器签署。

ADDENDUM-14 #11 更正上述 ST 整文件摘要：证据根中的 `research/st` 路径现须放固定提交的原始字节，不能复用旧追加尾 LF 的研究副本。取源表和六个 oracle 的重放资格见 [ST-SOURCE-PIN.md](../tool/st_differential/ST-SOURCE-PIN.md)；历史日志与行为向量不改。
