# ST 1.19 请求对拍台

这是 T10 的录制工具和20组自制输入。2026-11-09 的 reply-019/020 已报告固定 ST 的20组实际原生请求，每组恰好一次，guard全程健康；与真实Dart T4捕获逐组原始字节相同。原始请求与完整比较文件留代跑者本机，本仓库不伪造或转填golden。`recordingStatus` 标识此次来源；Node 自测单独仍不能证明 Dart 与 ST 相同。

## 比较边界

固定 SillyTavern 1.19.0，提交 `7e8663cd9c184a550b37238218bdd32c6efc68e9`。浏览器驱动在真实 ST 页面里调用其原生 `Generate`；提示词、宏、世界书和 DeepSeek 后处理仍由 ST 运行。录制器位于 ST 后端的下游，记录发给假模型接口的原始 UTF-8 请求体，不把浏览器到 ST 的中间请求当成模型请求。

逐字验收比较整个请求体字节，包括字段顺序、数字表示、字符串和空白。JSON 语义差异只辅助定位；即使 JSON 值相同，原始字节不同仍失败。不能把 Dart 生成结果回填成 ST golden。采样返回固定 `RECORDER_OK` 和合成的零用量，这些值只让真实生成流程结束，不是模型/分词器证据。

20 组主用例使用 32768 上下文、256 回复上限，以便先验证不触发裁剪的行为。精确 tokenizer 尚按 reply-002 的约定单列待验证；估算计数不能冒充 ST 精确预算。原始卡、预设、世界书、聊天和设置都在 `test/fixtures/st-differential.json`，不是从真实用户聊天抽取。

## 本机录制

1. 使用固定提交的干净本地 ST 测试实例和独立测试数据目录。记录 `git rev-parse HEAD`、Node 版本和启动方式；关闭额外扩展带来的提示词/正则/记忆注入，关闭自动加载上次聊天。**打开新的页面，并且在本次页面生命周期中从未选择过任何角色、群聊或聊天。** 只做下面的连接设置，等 ST 完成初始化、出现原生欢迎助手与欢迎提示两条消息；不要把这些欢迎行清空。驱动会创建合成角色并改变这个测试实例的设置。
2. 在 `packages/dsh_tavern` 打开一个终端，启动：

   ```sh
   node tool/st_differential/recorder.mjs --out st-recordings-016
   ```

   服务只监听 `127.0.0.1:19091`，不向外部模型转发。每次重录用一个新目录，已有捕获不会被覆盖。控制台应输出 `LISTENING http://127.0.0.1:19091`。
3. 在 ST 的连接页选 Chat Completion / DeepSeek，将反向代理设为 `http://127.0.0.1:19091`，代理口令可留空；用 ST 自带 Connect，并完成其对本地代理的提示。无需真实 Key。状态/模型查询由假接口回答。模型由每个夹具设置为合成测试用的 `deepseek-flash` 标识。
4. 在这个本地 ST 页面的开发者控制台运行：

   ```js
   var dshDiff = await import('http://127.0.0.1:19091/browser-driver.mjs');
   console.log(dshDiff.guardStatus());
   await dshDiff.runFixture('01-default');
   ```

   先观察 `DSH_RECORDED` 和服务器的 `RECORDED 01-default #1`。这一步只试第一组；继续剩下 19 组：

   ```js
   try {
     await dshDiff.runAll({ fromId: '02-cjk-fields' });
   } finally {
     dshDiff.downloadReport();
     console.log('DSH_UI_GUARD_FINAL', dshDiff.guardStatus());
     console.log('DSH_UI_GUARD_DISPOSED', dshDiff.dispose());
   }
   ```

   任一组失败时驱动立即停下，不把缺失录制当成成功。首组失败或单独运行失败后，guard 仍保留：先 `dshDiff.downloadReport()`、记录 `dshDiff.guardStatus()`，确认没有组在运行后显式 `dshDiff.dispose()`。不要通过手改夹具凑齐数量。录制期间不要操作角色、群聊、编辑器或设置；UI 变化只能由驱动发起。`runFixture(id)` 可在同一有效 session 中定位，但重复录制产生新的 attempt 号，验收时须明确选用哪次。dispose 后要重录，必须回到步骤 1 的新页面前提，不能复用已经关闭的模块。
5. **按 ADDENDUM-05，只回一个不超过 20KB 的纯文本 reply。** 写入实际 ST 提交、Node 版本、运行命令与退出码、20 组完成数、每组 status / attempt / newCaptures、guard 状态与被抑制的 preview 次数，失败时给出简短错误。真实录制、下载的 `st-driver-report.json` 及完整日志留在代跑者本机；不要回传 ZIP、原件或格式化副本。保留 `*.request.raw.json` 原字节，不用编辑器另存；`*.request.json` 仅便于人读，不能用来做逐字比较。后续逐字核对以本机命令及其文本结果为证据。录制器不保存任何请求头。

驱动导入卡使用 ST 原生卡导入端点；世界书先放入 ST 导出的缓存，再通过原生世界书配置入口选择。它测试的是实际扫描/组装流程，不证明世界书管理界面的导入流程。设置按 ST 的 `settingsToUpdate` 映射，保留已连接的本地反向代理。每组在界面渲染后重新设置宏变量，并由下面的会话 guard 隔离后台 UI 试算。没有预计算命中条目。

### UI 试算 guard 的范围与恢复

真实 `script.Generate`、PromptManager 的组装逻辑、宏引擎、世界书扫描和生成用 tokenizer 都保持原样。驱动只隔离两条会独立消费宏副作用的 UI 路径：

- 将安装时那个 PromptManager 的 `tryGenerate` 暂时换成计数并立即完成的函数。排队的 UI render 也会读取这个 guard。整个录制 session（包括组间和失败之后）保持安装，直到显式 dispose。
- 保存每个实际 Element 的原 `data-token-counter` 属性并临时移除，包含空字符串；MutationObserver 继续处理录制期间新增/变更的计数元素。输入值、其它属性、原生计数函数和 tokenizer 不改。为取消安装前已捕获 NodeList、仍在 await 的计数，驱动实际等待原生 `Date.now()` 严格大于安装时 cutoff，然后在空计数列表下调用并等待原生 `RA_CountCharTokens`，推进其私有 nonce。时钟 5 秒内不前进则安装失败并回滚。

安装检查当前无角色 / 群聊、`getCurrentChatId()` 为 undefined、没有生成且 PM 已初始化，chat 必须是按原生顺序的 `ASSISTANT_MESSAGE` / `WELCOME_PROMPT` 两行，并具有固定源码的 user/system/swipeable 标志。空 chat 或仅半对欢迎行可能是初始化尚未结束，会被拒绝，防止其稍后追加到夹具聊天。检查不修改欢迎行。**这些状态仍不能证明页面以前没有选过角色**，所以新页面操作前提不能省略。PM 在 global 策略下的 `activeCharacter={id:100001}` 是原生 dummy，驱动不会因此拒绝。

每组报告含 `uiGuardBefore`、`uiGuardBeforeGeneration`、`uiGuardAfter`，记录有效性、PM/方法所属、抑制次数、保存的计数元素数与 nonce 时间边界。PM 或方法被替换时，本组失败，不能把捕获当成有效 golden。`dispose()` 在组运行中拒绝；结束后可重复调用。它断开 observer，并按原 Element 恢复全部属性和安装时的 PM 方法 descriptor；后来被其它代码替换的方法不会被覆盖，恢复冲突会明确抛错。安装中途失败也会内部回滚，不留无人能 dispose 的半个 guard。

这些控制只对上述固定源码与声明的独立页面前提负责。Node 的 DOM/调度适配器回归不能代替真实 ST 浏览器录制，尤其不能据此声称已经取得 20 组 golden。

## 单独展开输入

```sh
node tool/st_differential/materialize.mjs st-fixtures-016
```

这会把每组展开为 `card.json`、`preset.json`、`chat.jsonl`、`settings.json` 和世界书。目录内文件以独占创建方式写入，已有文件会报错。手动录制时必须同样应用 settings、全局/聊天变量和生成类型，只导入卡和预设不足以复现。

## 检查录制器与比较字节

```sh
node --test tool/st_differential/recorder.test.mjs
node --experimental-vm-modules --test tool/st_differential/browser-driver.test.mjs
dart run tool/st_differential/dart_capture.dart dart-recordings-016
node tool/st_differential/compare.mjs st-recordings-016/01-default/001.request.raw.json dart-recordings-016/01-default/001.request.raw.json
node tool/st_differential/compare-all.mjs st-recordings-016 dart-recordings-016 --compact
```

`dart_capture.dart` 走真实 T8/T9 接线和 T4 HTTP 序列化，捕获实际 `request.bodyBytes`；MockClient 只返回合成 HTTP 响应，不联网。它使用全新输出目录，不覆盖已有录制；内部临时引擎目录在结束时清理。reply-019 的旧文件名版本已实际捕获20组并与020逐字全等；当前规范文件名、括号和变量前后断言由 reply-021 再次实际验证：Dart 3.13.5，format/analyze/capture/compare均exit 0，No issues found，20组捕获、20组原字节相同、20组variableStateMatches为true。提示词 token 仍为估算，必须先有正式T9依赖。

本工具的夹具限定无工具提示词组装。捕获器对 inline/library 都在生成前调用公开 setToolPolicy，显式关闭全局 roll/remember；不改变产品默认。保存真实 raw 后检查 tools、tool_choice 属性均不存在，成功报告 toolsAbsent=true；存在任一属性即失败并保留 raw，不删字段或放宽比较。以上旧回执仍只是其当时版本的证据，当前捕获器是否逐字一致须由对应版本的新录制判定。

`compare.mjs` 退出码 0 只表示这一对原始字节相同；任何字节差异退出 1。报告列出首个不同字节位置、两边长度，以及最多 20 个 JSON 路径差异。`compare-all.mjs` 按夹具清单读取每组 `001.request.raw.json`；缺文件、无法读取、非法 JSON 或字节不同均计失败。它要求全部声明项都有实际录制和 Dart 输出，空清单会报错；额外重试文件不会被悄悄选为 golden。若采用了其它 attempt，应先依据 driver report 在本机明确组织对应输入目录，不能擅自将第一个失败编号当成正确样本。

`--compact` 仍比较全部原始字节，只截短诊断值，把这一段文本输出限制在 18KB 内；可和简短命令结果一起放入 ≤20KB reply。完整请求和详细比较结果留本机。如果回件剩余空间不足，返回完整计数、失败 id、首个不同字节位置与少量 JSON 路径，后续再按明确命令查这些本机文件。

## 夹具覆盖

| 编号 | 核对点 |
|---|---|
| 01–03 | Default、CJK/CR/空白、角色覆盖与 original |
| 04–07 | 相对条目顺序、绝对深度、对话示例、历史姓名/旁白/隐藏 |
| 08–10 | 前缀继续、nudge 继续、代写 |
| 11–14 | 世界书关键词逻辑、位置、递归、优先级和组 |
| 15–18 | 新宏块、惰性字段、副作用次序、世界书示例、作者注释与人设 |
| 19–20 | 思考和 system 合并、非流式与停止词 |

群聊、真实服务调用、第三方扩展实现、真实 Key、精确裁剪边界不在这 20 组主录制的证据范围内。它们不能由这一套通过结果推断出来。

## 变量快照的单独核验

捕获器实际读取导入后的本地变量与生成结束后的本地变量。正文相同不证明变量类型或副作用相同。reply-020 原生状态给出15的`x="2"`、16的`x=2`、18的`x="new"`，其余组为空；这些已作为夹具的`expectedVariablesAfter`。导入后必须匹配头部variables，生成后必须匹配该期望，否则本组failed、进程非零，不能靠相同请求体掩盖状态差异。reply-021直接重读旧019原件，纠正了019/020的摘要转录错误：三个变量原来就一致。新增断言仍保留，防止后续用正文相同推断变量相同。此断言只读取状态，不展开或修正宏，也不改请求原字节。

变量断言比较JSON值与类型（字符串、布尔、容器结构分别比较；Dart int/double作为同一JSON数值域）。16的元数据原文Dart为`2.0`、ST为`2`，数值相同但原文不同；没有声称变量元数据逐字相同。请求体比较则始终逐字，`1`对`1.0`仍会失败。该元数据表示差异未改变这20组实际请求，也不改变T9声明的JSON值往返契约；不可据此推广到所有宏或任意精度数字。

## 新普通预设验收

两组中性 assembly 与独立原生 UI 导入 smoke 的命令及判定见 [PRESET-INTEROP.md](PRESET-INTEROP.md)。新夹具单独录制；不沿用上述 20 组的历史通过状态。
