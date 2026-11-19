# 普通预设：两组对拍与独立原生入口 smoke

本轮只用自制登记台文字，新夹具初始为 `unrecorded`，旧 20 组历史证据不变。两组 assembly 核实际组装；独立 smoke 核原生 UI 导入、选择后是否进入请求，分开执行、分开报告。

| 清单（相对包目录） | case | 本轮范围 |
| --- | --- | --- |
| `test/fixtures/st-ordinary-presets.json` | `21-ordinary-on`、`22-ordinary-off` | 顺序、depth=1、互斥尾部、开关与本地/全局变量后态 |
| `test/fixtures/st-preset-native-smoke.json` | `23-native-import` | 原生 UI 导入/选择；唯一文本标记和 temperature |

## 前提与固定版本

以下工具命令均在 `packages/dsh_tavern` 执行，输出目录必须尚未使用。保留命令、退出码和完整日志；使用已有 Dart 依赖及独立本地 ST 测试资料，不连接真实模型，无需真实 Key。先记录：

```sh
git -C /path/to/SillyTavern rev-parse HEAD
node --version
dart --version
```

ST 必须是 1.19.0 / `7e8663cd9c184a550b37238218bdd32c6efc68e9`；不符则停止并报 `UNVERIFIED`。`/health` 的 expectedStCommit 只是录制器声明，不能替代实际 checkout 检查。另记 ST 启动方式。
关闭额外扩展注入和自动加载上次聊天。assembly 的新页面须从未选过角色/群聊/聊天，等原生两条欢迎行完整出现，勿清空；guard 前提见 [README](README.md)。

## 1. 展开输入与 Dart 库入口捕获

```sh
node tool/st_differential/materialize.mjs tmp/ordinary-inputs test/fixtures/st-ordinary-presets.json
node tool/st_differential/materialize.mjs tmp/native-inputs test/fixtures/st-preset-native-smoke.json
dart run tool/st_differential/dart_capture.dart tmp/dart-ordinary test/fixtures/st-ordinary-presets.json
```

两组新夹具显式 `presetEntry="library"`：捕获器 importPreset，导入 chat 后 bindPreset；meta.presetImport 记录 id/issues/regexDiagnostics/selectionSource/effectivePresetId，须核 selectionSource=chat 与实际绑定 ID 相符。
`expectedPresetIssues`、`expectedRegexDiagnostics` 均为 `[]`，按声明严核；两个变量域都核前后 JSON 值与类型。未知入口或遗漏新夹具状态声明须失败；旧 20 组仍走 inline。这里不对 native smoke 运行 Dart 或 raw 比较。
这些夹具的对拍前提为无工具：Dart 捕获器在生成前通过公开 setToolPolicy 将全局 roll.allow 和 remember.allow 设为 false，inline/library 入口相同，产品默认不变。实际 raw 保存后须核 tools、tool_choice 属性都不存在，成功 meta 的 toolsAbsent=true；不删除请求字段。

## 2. 固定 ST 的两组 assembly

在一个终端启动录制器，保持运行：

```sh
node tool/st_differential/recorder.mjs --out tmp/st-ordinary --fixtures test/fixtures/st-ordinary-presets.json
```

应显示 `LISTENING http://127.0.0.1:19091`。ST 连接页选 Chat Completion / DeepSeek，反向代理设为该地址，口令留空，用原生 Connect 完成本地代理确认；假模型为 `deepseek-flash`。
在符合上述新页面前提的 ST 控制台执行一次：

```js
var ordinaryDiff = await import('http://127.0.0.1:19091/browser-driver.mjs');
try {
  await ordinaryDiff.runAll();
} finally {
  ordinaryDiff.downloadReport();
  console.log('DSH_UI_GUARD_FINAL', ordinaryDiff.guardStatus());
  console.log('DSH_UI_GUARD_DISPOSED', ordinaryDiff.dispose());
}
```

运行中勿操作角色、聊天或设置。driver 直接施加完整运行态再调用真实 Generate，不证明 ST 原生预设导入。逐组须 await 原生 Generate 返回、status=recorded、attempt=1、newCaptures=1，guard 全程有效；报告 presetApplication=declared-settings，保留两个变量域 before/after 与 globalVariableStateMatches。
21 的 deskMode/deskFlag 从字符串 initial 变 active；22 保持 initial；完整 map 与 untouchedLocal/untouchedGlobal 哨兵也须符合夹具。以下检查实际 ST raw 的标记次数/有无、MAIN→[GUIDANCE]→历史 assistant→DEPTH→历史 user→选尾顺序，以及 MAIN/system、历史问候/assistant、历史提问/user 三个 role 锚点，再逐字比较：

```sh
node tool/st_differential/check-ordinary-signals.mjs tmp/st-ordinary
node tool/st_differential/compare-all.mjs tmp/st-ordinary tmp/dart-ordinary test/fixtures/st-ordinary-presets.json --compact
```

每组 PASS 须同时有 Dart 恰一个 TavernTurnDone、无 TavernTurnFailed 且退出 0、toolsAbsent=true、诊断与 selection 正确、ST 原生 Generate 返回、唯一请求、健康 guard、两端本地/全局状态通过、referenceSignals=passed、rawEqual=true。compare-all 只判断 raw，退出 0 不能覆盖其它失败；Dart 确认唯一请求及正确 endpoint 后先保存 raw，工具前提或后态失败仍报 failed/退出非零，留下的 raw 仅供诊断，不能作为有效 golden。

## 3. 独立原生 UI smoke

结束前一个 recorder；另用独立 ST 测试资料和新页面，**不导入 browser-driver，不调用 runFixture/runAll/applySettings**。
启动仅含 smoke 的录制器：

```sh
node tool/st_differential/recorder.mjs --out tmp/st-native --fixtures test/fixtures/st-preset-native-smoke.json
```

从 `tmp/native-inputs/23-native-import/` 通过原生 UI 导入合成 card.json、chat.jsonl 和 preset.json，再实际选中预设。可先把 preset.json 原字节复制为 `DSH_PRESET_23_NATIVE_IMPORT.json` 再导入，避免普通文件名；记录选择器实际显示名，不把 fixture.name 当成原生名称字段。
先完成导入，再按第 2 节配置 loopback 并 Connect；发送前复核实际所选预设。不要手改 prompt、temperature 或请求来补齐条件。
在 ST 页控制台只操作本项目录制器：

```js
var nativeBefore = await fetch('http://127.0.0.1:19091/health').then(r => r.json());
console.log('NATIVE_BEFORE', nativeBefore);
var nativeSelection = await fetch('http://127.0.0.1:19091/active-case', {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ id: '23-native-import' }),
});
console.log('NATIVE_SELECTION', nativeSelection.status, await nativeSelection.json());
```

确认 HTTP 200、activeId 正确、尚无捕获，再用原生发送界面发送一次中性文字 `Please tell me the next step.`，等 `RECORDER_OK`。
然后读取 `await fetch('http://127.0.0.1:19091/health').then(r => r.json())`，核本 case counts 与 attempts 均为 1。
在包目录运行以下 PowerShell 只读检查，核同一次 raw 请求的 messages 标记恰好一次、temperature 为 number 0.37；失败退出 1：

```powershell
@'
import fs from "node:fs";
const body = JSON.parse(fs.readFileSync("tmp/st-native/23-native-import/001.request.raw.json", "utf8"));
const markerCount = (Array.isArray(body.messages) ? body.messages : []).reduce((n, m) => n + (typeof m?.content === "string" ? m.content.split("DSH_NATIVE_PRESET_SMOKE_23").length - 1 : 0), 0);
const temperatureType = typeof body.temperature, entrySmoke = markerCount === 1 && temperatureType === "number" && body.temperature === 0.37;
console.log(JSON.stringify({ entrySmoke, markerCount, temperature: body.temperature, temperatureType })); process.exitCode = entrySmoke ? 0 : 1;
'@ | node --input-type=module
```

本地检查只判两个观察值，另须保留实际选择器名、导入/选择步骤与截图或日志。入口 smoke 的 referenceSignals、rawEqual、localState、globalState、guard 均报 `not-applicable`，不能称整请求逐字相同。

## 4. 状态与回件

| 结论 | 报告规则 |
| --- | --- |
| `PASS` | assembly 满足上述全部联合门槛；smoke 只表示原生入口和两个观察条件通过，单独记 entrySmoke |
| `FAIL` | 已执行却出现生成、数量、guard、诊断、选择、状态、referenceSignals 或字节失败；列失败 case、阶段与首个错误，不能降格成未运行 |
| `UNVERIFIED` | 未执行或被版本/依赖/原生入口条件阻断；写具体原因和缺少的证据，不计通过 |

每 case 列 recorded、attempt/newCaptures、referenceSignals、rawEqual、localState、globalState；未执行检查用 not-run，smoke 不适用检查用 not-applicable。
失败即保留现场和所有 attempt；不得改 golden、覆盖旧输出或反复重试挑赢家。若另获修正后重跑指令，用新目录，并报告旧失败与修正原因。
仅回一份 ≤20KB 纯文本：实际 SHA/版本/命令/退出码、两组联合判定、smoke 两观察值及实际选择器名、简短失败定位。原始请求、完整日志、driver/Dart 报告和截图均留 owner 本机，不回传 ZIP 或请求正文；raw 不经编辑器另存，pretty JSON 不能代替逐字输入。
Node 自测、合成 RECORDER_OK 和零用量不证明 Dart/ST 兼容、模型效果或精确 token；本轮不验 regex/display、EJS、压缩或社区发行版整包。

## 设计来源

[Prompt Manager](https://docs.sillytavern.app/usage/prompts/prompt-manager/) 与 [Macros](https://docs.sillytavern.app/usage/core-concepts/macros/) 用于顺序、深度和变量维度；[Sudachi 1.22 公开说明](https://github.com/LimeBlogs/Sudachi-Next/releases/tag/1.22) 仅提供互斥选择维度，不复制正文。[Regex 文档](https://docs.sillytavern.app/extensions/regex/) 与 [ST 发布页](https://github.com/SillyTavern/SillyTavern/releases) 供后续独立探针参考；当前网页不能替代固定提交实际行为证据。
