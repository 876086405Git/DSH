# 原生预设绑定正则：两预设、同一聊天、四次发送

这是后续独立候选，尚无本批 ST/Dart 实跑结论，不属于 R2/187。执行前须使用 root 确认已整合到 R2 之后、通过复核的候选版本；本指南不构成新增代跑请求。
清单为 `test/fixtures/st-native-preset-regex.json`，仅 `rx-a`、`rx-b` 两项，均为 `unrecorded`。两份使用同一 DeskClerk card/chat；**只导入 A 的 card/chat 一次**，两份 preset 分别导入，四阶段始终使用同一聊天和同一个 A 资源。

| A 中规则 | 查找 → 替换 | promptOnly | markdownOnly | 初始 disabled |
| --- | --- | --- | --- | --- |
| DSHRX Prompt（P） | `/DSHRXPRAW/g` → `DSHRXPOUT` | true | false | false |
| DSHRX Display（D） | `/RECORDER_OK/g` → `DSHRXDOUT` | false | true | false |

两条 placement=[2]，无宏、trim 或 depth；B 的 regex 数组为空。main 标记分别是 `DSHRXPRESETA`、`DSHRXPRESETB`。固定 recorder 回复仍为 `RECORDER_OK`。

## 1. 前提、物化与 Dart 行为回归

以下命令在 `packages/dsh_tavern` 执行，示例使用 PowerShell。先记录实际候选提交、ST 启动方式及版本：

```powershell
git -C /path/to/SillyTavern rev-parse HEAD
node --version
dart --version
```

ST 必须为 1.19.0 / `7e8663cd9c184a550b37238218bdd32c6efc68e9`；不符停止并报告 UNVERIFIED。health 的 expectedStCommit 不能代替实际 checkout 核查。
使用独立、全新的本地 ST 测试资料和页面，确认无其它 global/scoped regex、WI、额外扩展或工具介入；只连接 loopback，不需要真实模型或 Key。每次选择/保存后须重新核对连接。

```powershell
& {
  foreach ($dshRxTarget in @('tmp/native-regex-inputs', 'tmp/st-native-regex', 'tmp/native-regex-exports')) {
    if (Test-Path $dshRxTarget) { throw "Output already exists: $dshRxTarget" }
  }
  node tool/st_differential/materialize.mjs tmp/native-regex-inputs test/fixtures/st-native-preset-regex.json
  if ($LASTEXITCODE -ne 0) { throw 'materialize failed; stop.' }
  dart test test/t21_library_display_test.dart
  if ($LASTEXITCODE -ne 0) { throw 'Dart behavior regression failed; stop.' }
  New-Item -ItemType Directory tmp/native-regex-exports -ErrorAction Stop | Out-Null
  Copy-Item tmp/native-regex-inputs/rx-a/preset.json tmp/native-regex-inputs/rx-a/DSHRXPRESETA.json -ErrorAction Stop
  Copy-Item tmp/native-regex-inputs/rx-b/preset.json tmp/native-regex-inputs/rx-b/DSHRXPRESETB.json -ErrorAction Stop
}
```

新增 Dart 回归在同一 engine/chat/Aid/Bid 中完成四阶段，检查库选择、P 更新/恢复、display/path/export、每次一个 Done/无 Failed及一次 generate 调用。它观察模型 generate 入参，**不等于原始 HTTP 实录**。
该测试显式禁用本项目 roll/remember，并核 tools/tool_choice 缺席；native checker 也核这两属性缺席。不要用旧 dart_capture 的两个独立实例代替本次切换链；本指南不追加旧20或全包测试。

## 2. 原生入口和初始显示

结束先前占用19091的本项目 recorder，在单独终端保持以下进程运行：

```powershell
node tool/st_differential/recorder.mjs --out tmp/st-native-regex --fixtures test/fixtures/st-native-preset-regex.json
```

须看到 `LISTENING http://127.0.0.1:19091`。不加载 browser-driver，不调用 runAll/runFixture/applySettings，不直赋 ST extensions 或调用私有导入/保存 API。
通过 ST 原生入口导入 A 的 `card.json` 并选择 DeskClerk，导入上述两个具名 preset 文件，实际选择 A。记录选择器实见名称、两条规则的归属/flags、来源启用情况；fixture.name 或文件名不能代替实际选择证据。
许可弹窗有无、实际文字、选择以及原生保存方式都现场记录；不假定某个控件或自动授权存在。不能确认所需原生状态时停止；已经导入却观察到错误状态，按实际失败报告。
随后通过原生入口导入 A 的 `chat.jsonl` 并打开导入的聊天。B 目录中的重复 card/chat 不导入；不能重导聊天、重建聊天或重导 A 来完成后续阶段。
186 owner 预检实际使用过 ST 原生 file-input 路径：`#character_import_file`、`#chat_import_file`、`#openai_preset_import_file` 放入原始文件并触发其已有处理事件；OS 文件选择器没有覆盖。若本次采用该路径，应记录实际入口，不能把预检写成本批成功。

初始唯一 assistant 原文为 `DSHRXANCHOR | DSHRXPRAW | RECORDER_OK`。A 激活后，通过该聊天的正常导入/打开显示，必须观察到：

```text
DSHRXANCHOR | DSHRXPRAW | DSHRXDOUT
```

这同时提供 P 不进显示、D 进入显示的对照。不要手改正文/DOM补条件；后续以**每次新回复**为显示判据，不假设切换会自动重绘旧消息。
原生连接页确认 Chat Completion / DeepSeek、反向代理 `http://127.0.0.1:19091`、口令空，并用原生 Connect 完成本地代理确认。**每次选择或保存预设后、发送前都重新确认/必要时恢复连接并 Connect**；同时复核实际预设仍正确。连接未确认则停止，不向其它端点尝试。

## 3. 固定四阶段，逐阶段停止检查

下表 `(A,B)` 对 health 的 counts、attempts 分别适用，缺失项按 0。每次普通 Send 精确发送 `Please continue.`；不能使用 Continue、Swipe 或 Regenerate。

| 阶段 | 原生预设状态/操作 | capture | health pre→post `(A,B)` | 请求锚 P 值 | 当次新回复 UI | 导出消息数 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | A：P/D 都启用 | rx-a/001 | (0,0)→(1,0) | DSHRXPOUT | DSHRXDOUT | 3 |
| 2 | 同一 A：只禁 P，D 仍启用 | rx-a/002 | (1,0)→(2,0) | DSHRXPRAW | DSHRXDOUT | 5 |
| 3 | 先恢复 P、确认 A 已保存，再选空 B | rx-b/001 | (2,0)→(2,1) | DSHRXPRAW | RECORDER_OK | 7 |
| 4 | 切回同一个 A，两条均启用 | rx-a/003 | (2,1)→(3,1) | DSHRXPOUT | DSHRXDOUT | 9 |

阶段2用原生 UI/导出预设核 P.disabled=true、D.disabled=false；离开 A 前恢复两者 false，并确认实际保存后的同一 A。记录具体控件/保存动作，不能用整来源关闭冒充单条禁用。
返回 A 若需要再次许可/启用，记录实际干预；只能报告在这些操作条件下恢复，不能称“选择即自动恢复”或授权自动持久。
每阶段先完成表中选择/保存、连接与规则核查，再在 ST 控制台仅操作本项目 recorder。下例阶段1/2/4使用 rx-a，阶段3改成 rx-b：

```js
var regexSelection = await fetch('http://127.0.0.1:19091/active-case', {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ id: 'rx-a' }),
});
console.log('REGEX_SELECTION', regexSelection.status, await regexSelection.json());
console.log('REGEX_PRE', await fetch('http://127.0.0.1:19091/health').then(r => r.json()));
```

须确认 HTTP 200、activeId 正确及表中 pre。然后原生发送一次，等待生成与显示完成，定位**本次新增的末助手回复**核 UI，不能拿旧回复画面替代。随后读取：

```js
console.log('REGEX_POST', await fetch('http://127.0.0.1:19091/health').then(r => r.json()));
```

两个计数均须只让本阶段 id 增1，另一 id不变；保存/切换/Connect/active-case 不得带来额外模型 POST。阶段2后恢复 A、切 B 的过程中仍应保持 (2,0)。出现额外捕获就停，不删除 attempt 后重试。
**每阶段完成后立即原生导出完整 chat**，保留原下载，再原字节复制到固定 stage-k.jsonl。不能从 messages 自行拼装、筛选 system 行或经编辑器重存。若当前浏览器无法取得完整原生导出，停止并报告具体阻断。
下面一块每阶段执行一次：把 `$dshRxStage` 改为当前 1/2/3/4，把 LiteralPath 换成本阶段刚导出的原文件；没有成功前不得开始下一次发送。

```powershell
& {
  $dshRxStage = 1
  $dshRxDestination = "tmp/native-regex-exports/stage-$dshRxStage.jsonl"
  if (Test-Path $dshRxDestination) { throw 'Stage export already exists; preserve evidence and stop.' }
  Copy-Item -LiteralPath '填入本次原生导出文件路径' -Destination $dshRxDestination -ErrorAction Stop
  node tool/st_differential/check-preset-regex-signals.mjs tmp/st-native-regex tmp/native-regex-exports $dshRxStage
  if ($LASTEXITCODE -ne 0) { throw 'Regex file signals failed; stop before the next stage.' }
}
```

checker 的第三参数省略时为4；前缀1/2正常尚无 rx-b 目录。它要求 capture/export 文件集合恰为当前前缀，未来阶段文件提前出现也失败。前缀全部通过才输出 N 行，checkedThrough=N；1/2/3通过不能称四阶段通过。

## 4. 文件信号与联合报告

checker 只读 `.request.raw.json`，严格 UTF-8。第k阶段核正确 main/唯一 assistant 完整锚/互斥 P 值、全请求 RECORDER_OK 恰k次、DSHRXDOUT 为0，并要求 tools/tool_choice 属性缺席；非字符串 content 失败。全局标记按 JSON 字符串解转义后计数，包括非 messages 字段。
导出只除 header 与 JSON 空白物理行，严格要求 1+2k 条消息：原 assistant 锚，再依次 k 对 user `Please continue.` / assistant `RECORDER_OK`；mes 逐字符一致，is_user 为对应布尔值，is_system 只能缺省或 false。不筛额外对象；其它 metadata 可变。
每行输出的 wireSignals/exportSignals=passed **只表示文件信号**。实际选择/许可/保存、初锚 UI、当次新末回复 UI、普通生成完成和 health，必须由 owner 独立记录；checker 无法自证它们。
完整 PASS 必须同时满足本批对应 Dart 回归、四阶段原生观察与计数、最终 checkedThrough=4 的文件信号。已执行不符为 FAIL，列首个失败阶段；未执行或缺原生事实为 UNVERIFIED，其余阶段记 not-run。rawEqual、compare-all 和 browser-driver guard 不适用。
回件只需一份≤20KB纯文本：候选/ST/Node/Dart版本、命令退出码、Dart回归结果，以及每阶段实际选择器名、P/D状态/许可保存动作、health pre/post、UI所见、capture/导出路径、文件信号和联合判定。原始请求、每次原生导出、截图及完整日志留 owner 本机。
失败保留现场，不覆盖旧目录、不改 golden、不补写 ST 请求，不通过重复发送挑赢家。四次 rx-a/rx-b 是固定不同状态，不能当重试。
本批不证明一般 regex 兼容、单文本 g 多次命中、D 单独禁用、宏状态隔离、旧 DOM 自动刷新、冷重启持久化或过程中零临时写入。导出断言针对各观察点的 mes；Node 合成自检不是 ST 实录，也不证明真实模型质量。
