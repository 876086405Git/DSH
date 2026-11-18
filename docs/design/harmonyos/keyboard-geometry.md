# 本应用键盘几何诊断（1309）

状态：后端及数据协议实现，目标API26 SDK和手机未验证；UI由本机接线。基底8faafe6。沿用dsh/diagnostics的collectSystemIme/cancelSystemIme，无新权限或依赖。

## 来源与边界

`OhosKeyboardLog`原本已经订阅主窗口的will/did、height和avoidArea回调并写几何hilog。本次不读取任何hilog、logcat、IME系统日志或输入框内容；仅把这些已订阅的本应用窗口回调保存为有界内存快照。只接受固定数值/布尔几何字段，未知文本和对象字段不会进入内存导出或既有hilog输出。

- 内存最多64条，保留最近120秒范围内最新到达的记录；64条上限可能截短实际覆盖时段，不承诺完整两分钟历史。
- 前台才接纳回调；后台立即清空，后台collect返回cancelled；恢复前台从空记录开始。窗口销毁/替换清空，按每次attach的新generation隔离旧窗口及同一Window对象重挂后的迟到回调。即使off失败，已失效回调也不能污染新窗口。
- timestamp是Date.now取得的**回调收到时间**，不是系统动作发生时间；没有测量帧级延迟。墙钟回拨时清除落在未来的记录。同毫秒条目保留收到顺序。
- 六个回调注册全部以明确的BusinessError.code=801失败时为unsupported；零注册成功且至少一项为窗口异常1300002、其他错误码或无错误码时为unavailable。只要部分注册成功，就保留对应可用回调；不从错误message猜能力。每次重挂清除上次错误分类，off失败不改变本次注册分类。未绑定Ability/主窗口也为unavailable；前台可观察但无记录为noEvents。空记录/失败不能证明键盘行为正常。
- collect是立即读取环形记录的手动导出，不是启动一个长时间录制。cancel没有待执行的原生录制可中断，仍按同名方法返回null；Dart原有generation负责离页/清除后丢弃迟到结果。

本次改动没有轮询、计时器、文件、系统日志请求或输入法权限。普通诊断/自动故障报告仍不含此手动证据，只有原有明确includeSystemIme的手动导出/发布会带入。

## 线格式

包络字段仍为ok/code/capturedAt/source/events。OH来源为`ohosWindowGeometry`；每条origin固定`ohosWindow`、fromUser=null、reason=unknown。没有把它伪装成Android的imeTracker或requestShow/Hide，也不捏造用户触发归因。

| event | geometry固定字段 |
|---|---|
| willShow / willHide / didShow / didHide | begin、end：各[left,top,width,height]；可选animated、curve、durationMs、curveParams |
| height | height：非负有限数 |
| avoidArea | left、top、right、bottom：各[left,top,width,height]，仅TYPE_KEYBOARD |

坐标/尺寸单位px；坐标可为负，尺寸必须非负。可选动画时长范围采用公开SDK的0–3000ms；参数数组至多4个有限数，仅记录不解释曲线。两端都只重建固定字段；Dart嵌套数组与Map不可变，不保留原生响应对象。Android来源仍为privilegedIme，原有字段、排序、JSON形状和默认构造行为不变，受原回归覆盖。

`diagnosticsChannelProvider`仅在operatingSystemProvider=='ohos'时选择`DiagnosticsChannel.ohos()`；其他系统保留既有构造。这个来源也用于MissingPlugin/PlatformException，防止OH失败被写成privilegedIme。直接调用OH collect的非provider消费者应使用`.ohos()`，recordVoiceStage/info等既有直调不受影响。

## 本机需要改的界面

保护路径未改。请在以下文件做局部接线，不要翻转全局androidSystemFeaturesProvider：

1. `app/lib/ui/settings/diagnostics_page.dart`：SystemImeDiagnosticsSection的出现条件加入本功能的OH分支；保留自动故障、Direct等各自的条件。OH标题用“本应用键盘几何”，按钮说明为导出最近主窗口几何；不是系统输入法日志或系统权限采集。
2. 同文件的SystemImeDiagnosticsSection：保留用户点击才collect、isCurrent判定、前后台和dispose取消、clear、64条计数与时间显示。OH的unavailable提示应说明主窗口暂不可用；**不要显示原Android的PhoneControlScreen/权限跳转**。OH不需要ADB/Shizuku、读日志或手机操控授权。
3. `app/lib/l10n/parts/diagnostics_zh.arb` 与 `diagnostics_en.arb` 的systemIme相关键：为OH分支增加准确的中英文说明；不要把Android既有原生同意框说明一并替换。模型调用或自动发布不能偷偷替用户点这个按钮。
4. 诊断ZIP仍用历史文件名system-ime.json，查看source即可识别来源；Markdown已按来源输出“本应用键盘几何”，无需界面再拼原始数据。

未收到输入内容不代表能看到系统IME全部状态。公开will/did仅描述本应用主窗口相关的固定态键盘拉起/隐藏；浮动/分离键盘、其他窗口、应用后台与设备不支持时都不能据缺记录作正常性判断。

## 原始来源

以下为华为官方API文档，2026-11-15读取；没有复制其他移植项目代码。

- Window on/off、keyboardWillShow/Hide（API20）、keyboardDidShow/Hide（API18）与当前拉起/隐藏固定态键盘的应用窗口限定；will/did注册错误表区分801能力不支持和1300002窗口状态异常：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-window-window/
- KeyboardInfo（beginRect/endRect API18；animated/config API20）、Rect、AvoidArea、WindowAnimationConfig：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-window-i/
- WindowAnimationCurveParam数值数组、弹簧/贝塞尔四参数形状：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-window-t/

仓库基底事实：原OhosKeyboardLog已有这六种订阅；DiagnosticsPlugin只有info/engineLog；SystemImeEvidence原来只接受privilegedIme；diagnostics_page的对应卡被androidSystemFeaturesProvider隐藏。新增通道缺失、来源拒绝和OH失败来源误标均先运行实际红例再修复。

独审在首版dcfb79发现全部注册失败时把窗口状态异常误报为unsupported。R1先在原产品上实跑五个注册错误用例，4红1绿，再修正为按BusinessError.code判定；新门含这些回归并保留原红。错误分类修复没有增加窗口重试、轮询或额外订阅。

## 宿主验证与本机验收

宿主门`keyboard-geometry`运行真实ETS与实际EntryAbility，Window/Flutter/墙钟为显式边界；plain/jitless及strict TypeScript使用NONOFFICIAL宿主声明，不代替SDK。既有keyboard-log夹具补齐SDK完整矩形并将“复用相同回调”改为“旧回调失效”的实际行为断言。既有diagnostics门继续执行真实Linux FD持久日志与实际Dart消费者，不把旧缺方法替身的unsupported计为OH功能结果。

真实Flutter门消费实际ETS产生的codec-input.json，并验证源标记、有限几何、不可变边界、Markdown/ZIP、手动触发和取消；同跑Android原有IME及自动诊断回归。单独运行三份Dart改动的真实flutter analyze。

本机应以API26 HMS SDK编译，并在主窗口键盘显示/隐藏、横竖屏、前后台、窗口销毁重建、无输入法/浮动键盘情况下核对UI与实际回调。宿主没有手机键盘曲线、延迟或帧同步测量。新增记录用于排查本应用布局，不用于推导系统输入法内部因果。
