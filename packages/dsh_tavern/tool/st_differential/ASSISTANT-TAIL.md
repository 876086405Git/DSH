# 普通 assistant 尾部：22/24 同场对拍

这是尚未实录的独立候选。新清单 `test/fixtures/st-assistant-tail-presets.json` 按顺序包含 `22-ordinary-off`、`24-ordinary-assistant-tail`，两者均为 `unrecorded`。22 的输入逐字段、类型和数组顺序与186冻结的22相同；24只改四个身份字段和已启用 `desk-tail-b` 的 role，正文、开关、顺序及变量状态不变。

本批必须用全新 ST/Dart 录制目录，同场重新录两组；186旧22的请求、报告或成功标签都不能代替本批22。若186回件暴露公共 harness/入口阻断，先修复并重基底，再使用经复核的候选版本执行本指南。

| case | 本批实际末 message 必须满足的门槛 |
| --- | --- |
| `22-ordinary-off` | role=user，content 以 `DESK-TAIL-B: End with one short question.` 结束，**没有 prefix 属性** |
| `24-ordinary-assistant-tail` | role=assistant，content 精确为上述完整尾句，prefix 为布尔 true，**没有 reasoning_content 属性** |

两份均为原生 JSON、normal 生成、空 assistant_prefill/assistant_impersonation、continue_prefill=false、show_thoughts=false、extensions={}。不启用 dsh 增强 prefill；prefix=true 本身不能区分普通路径与 content 增强路径，须连同声明输入和实际库选择核验。

## 1. 前提与本批目录

命令在 `packages/dsh_tavern` 下执行。以下是 PowerShell 示例；三个输出目录必须未使用，任一步失败立即停止后续步骤并保留现场。需要重跑时使用新的目录，不能覆盖或删掉失败证据。

```powershell
git -C /path/to/SillyTavern rev-parse HEAD
node --version
dart --version
```

实际 ST checkout 必须为 1.19.0 / `7e8663cd9c184a550b37238218bdd32c6efc68e9`；不符则停下报告 UNVERIFIED。录制器 health 中的 expectedStCommit 只是声明，不能代替实际 SHA。保留候选版本、ST 启动方式及命令/退出码。
使用独立本地 ST 测试资料，关闭额外扩展注入和自动加载上次聊天；新页面从未选过角色、群聊或聊天，等两条原生欢迎消息完整出现，勿清空。沿用 [README](README.md) 的 UI guard 前提。仅连接 loopback 假模型，不需要真实 Key。

## 2. 物化与 Dart 库入口捕获

```powershell
& {
  node tool/st_differential/materialize.mjs tmp/assistant-tail-inputs test/fixtures/st-assistant-tail-presets.json
  if ($LASTEXITCODE -ne 0) { throw 'materialize failed; stop here.' }
  dart run tool/st_differential/dart_capture.dart tmp/dart-assistant-tail test/fixtures/st-assistant-tail-presets.json
  if ($LASTEXITCODE -ne 0) { throw 'Dart capture failed; stop here.' }
}
```

两组都须 status=captured。捕获器须完成唯一实际 POST `/beta/chat/completions`、恰一个 TavernTurnDone 且没有 TavernTurnFailed；退出非零后不得继续比较。
捕获器在生成前通过公开 setToolPolicy 关闭全局 roll/remember；两组 meta.toolsAbsent 必须为 true，来自实际 raw 的 tools/tool_choice 属性均缺席检查。产品默认与原始请求不改写；普通 assistant prefix 在本批无工具前提下核验。
逐组读取 `001.meta.json` 的 presetImport：issues/regexDiagnostics 都为 []，selectionSource=chat，effectivePresetId 与该组导入的 id 相同。捕获器走 importPreset→bindPreset，不是 inline setPreset。
两组 local 初态与后态完整 map 均为 `{"deskMode":"initial","untouchedLocal":"local-sentinel"}`；global 均为 `{"deskFlag":"initial","untouchedGlobal":"global-sentinel"}`。不得忽略额外 key 或把字符串当数值比较。

## 3. 同一批固定 ST 录制两组

结束此前占用19091端口的本项目 recorder，在单独终端保持这个新 recorder 运行：

```powershell
node tool/st_differential/recorder.mjs --out tmp/st-assistant-tail --fixtures test/fixtures/st-assistant-tail-presets.json
```

须显示 `LISTENING http://127.0.0.1:19091`。ST 原生连接页选 Chat Completion / DeepSeek，反向代理为该地址、口令空，通过原生 Connect 完成本地确认；假模型为 deepseek-flash。
在满足新页面前提的 ST 控制台执行一次，运行中勿操作角色、聊天或设置：

```js
var assistantTailDiff = await import('http://127.0.0.1:19091/browser-driver.mjs');
try {
  await assistantTailDiff.runAll();
} finally {
  assistantTailDiff.downloadReport();
  console.log('DSH_UI_GUARD_FINAL', assistantTailDiff.guardStatus());
  console.log('DSH_UI_GUARD_DISPOSED', assistantTailDiff.dispose());
}
```

每组须 await 原生 Generate 返回，status=recorded、attempt=1、newCaptures=1，guard 全程有效，两个变量域的 before/after 和匹配断言符合第2节。保留下载报告；任何失败立即停止，不继续 signal/compare。
driver 对本批两组逐一重置声明状态，施加完整 preset 后调用真实 Generate；报告 presetApplication=declared-settings。这是 assembly 证据，不是 ST UI 原生预设导入/选择证据。

## 4. 先核真实 ST 信号，再逐字比较

只有前两端生成与状态门槛通过，才执行以下命令；signal 非零时 PowerShell 立即停止，不能把后续 rawEqual 当作覆盖失败的理由。

```powershell
& {
  node tool/st_differential/check-assistant-tail-signals.mjs tmp/st-assistant-tail
  if ($LASTEXITCODE -ne 0) { throw 'ST reference signals failed; stop before compare.' }
  node tool/st_differential/compare-all.mjs tmp/st-assistant-tail tmp/dart-assistant-tail test/fixtures/st-assistant-tail-presets.json --compact
  if ($LASTEXITCODE -ne 0) { throw 'Raw-byte comparison failed; stop here.' }
}
```

新 checker 只读本批真实 raw：MAIN、历史完整问候、DEPTH、最后 user 完整句和 TAIL-B 各一次；GUIDANCE/TAIL-A 不出现，来源顺序为 `MAIN < greeting < DEPTH < question < TAIL-B`，并核 MAIN/system、greeting/assistant、question/user 三个角色锚点；非字符串 content 失败。最后再核表中的两种末 message 合同，不规定整体消息条数。
成功时应得到下面两行；它们是**待满足的门槛示例，不是已经跑过的结果**：

```json
{"id":"22-ordinary-off","referenceSignals":"passed","lastRole":"user","prefixPresent":false}
{"id":"24-ordinary-assistant-tail","referenceSignals":"passed","lastRole":"assistant","prefixPresent":true}
```

完整 PASS 是逐组全部满足：Dart生成/唯一请求/toolsAbsent/诊断/库选择/状态、ST Generate返回/唯一请求/guard/状态、referenceSignals=passed、rawEqual=true。compare-all 只判断实际 raw；一个门槛通过不替代其它门槛。
失败后留下的 raw 仅作诊断，不能充当有效 golden；不要修改请求、补写 ST golden、从 Dart 复制参考请求或只用 pretty JSON 做比较。

## 5. 回件与证据边界

保留两组全部原始请求、所有 attempt、完整命令日志及 ST/Dart 报告；回一份≤20KB纯文本，列实际版本/命令/退出码、每组 recorded、attempt/newCaptures、库选择/diagnostics、localState/globalState、referenceSignals、lastRole/prefixPresent、rawEqual 与联合判定。
已执行失败写 FAIL，并列首个失败阶段；未运行或被前提阻断写 UNVERIFIED，说明原因。下游未执行项写 not-run；不得把失败归为通过或静默挑选重试结果。没有新重跑指令时保留现场。
本指南只描述本批新清单；若总请求合并了公共代码或产品修复，另按总请求执行旧20捕获、定向回归及全包测试，不由本指南替代。
Node合成自检、loopback RECORDER_OK及请求prefix形态，不证明真实beta服务接续、模型输出质量、最终存储拼接、增强reasoning、预设regex或社区整包兼容。

设计语义来源：[Prompt Manager](https://docs.sillytavern.app/usage/prompts/prompt-manager/) 与 [DeepSeek Chat Prefix Completion](https://api-docs.deepseek.com/guides/chat_prefix_completion/)；当前文档不能替代上述固定ST的本批实录。
