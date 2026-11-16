# 鸿蒙语音通道：实际调用契约与验证边界

当前候选以 `fd2890cf9ae5ee2bb4faead2fbbf3689a4a29b92` 为基底。HMS 识别部分状态为 **UNCOMPILED_HMS**；公开音频部分也尚未通过目标设备验证。Linux 执行的是产品 ETS 的实际方法体，平台音频、HMS、权限窗口和 Flutter 传输由显式夹具提供，不能据此声称手机麦克风或系统识别已工作。

## 实际 Dart 消费端

权威消费端是 `app/lib/ui/chat/voice/voice_bridge.dart`、`voice_controller.dart`，对应 Android 参考为 `voice/VoicePlugin.kt` 和 `voice/WavRecorder.kt`。没有新增 Dart 调用、依赖或聊天 UI。

| 通道方法 | 返回值与行为 |
| --- | --- |
| `dsh/voice.capabilities` | Map：`recognizer`、`recorder`、`systemUnreliable`、`environmentId`。识别工厂创建成功才报告 recognizer；音频按公开 `SystemCapability.Multimedia.Audio.Capturer` 查询。 |
| `permission` | 不弹窗，返回 `granted` 或 `denied`，兼容现有 Android 方法。 |
| `requestPermission` | 用户操作时申请 MICROPHONE；返回 `granted`、`denied` 或 `blocked`。只有拒绝且公开 `dialogShownResults[0]` 明确为 false，才返回 blocked；缺失该字段不作永久拒绝推断。 |
| `openSettings` | 使用公开 `requestPermissionOnSetting`；错误传回 Dart，不假装已打开。已授权时不再弹窗。 |
| `startRecognizer` | 必须提供正整数 `sessionId`；缺省语言选择 zh-CN，显式其他语言返回 `details.code=12`。 |
| `startRecorder` | 必须提供整数 `maxSeconds` 和正整数 `sessionId`；与 Android 一样将时长限制在 1–600 秒。 |
| `stop` | 系统识别调用 finish，返回 null，最终文字走事件。录音等待实际 stop/release 后返回 Uint8Array WAV；空录音返回 null。 |
| `cancel` | 先使旧会话不能再发事件，等实际资源释放后返回 null。释放失败返回错误并保留占用，后续取消可重试。 |

`dsh/voice/events` 的每个 Map 都包含 Dart 原来发送的数字 `sessionId`。类型是 `level(value)`、`partial(text)`、`final(text)`、`error(code)`、`limit`、`end`。不使用新发明的原生会话号替换 Dart 编号。

额外的 capability 字段为 `languages:['zh-CN']`、`recognizerRegion:'CN'`、`recognizerOffline:true`。**现有 Dart VoiceCapabilities 不消费这三个字段**，不能声称界面已展示语言/地区限制。`environmentId` 保持 null：没有公开核实的 HMS 服务版本，不把设备型号或常量冒充环境标识。服务不可用标志只在本进程内保留。

## 生命周期与资源约束

一个模块级租约覆盖识别和录音两条路径；从权限复查、异步创建、异步 start，到 stop/release 全部包含在租约内。引擎或 Ability 解除连接先使旧会话失效，迟到结果不能写入新引擎。逻辑取消不等于实际麦克风已释放；创建 Promise 尚未完成、释放失败等情形都继续阻止另一会话启动。

权限窗口另有一个模块级占用标记。原 Flutter 引擎解除连接时，正在显示的系统窗口可能仍未关闭，新的引擎不能再打开第二个窗口；旧 Promise 完成后才清除标记。代码不靠延时猜测窗口或麦克风已关闭。

`VoicePlugin.onForeground(UIAbility)` / `onBackground(UIAbility)` 要由 EntryAbility 的真实同名生命周期转发。前台集合按 UIAbility 对象身份保存；旧 Ability 的迟到后台事件不能取消新 Ability。后台事件立即撤销当前会话并释放资源，后台再次请求开始时明确拒绝。Dart 已有 paused/hidden 取消逻辑仍然保留。候选核心不请求后台长时任务权限。

HMS 引擎在任务正常完成后复用，避免每段结果都重建；显式取消、服务错误或宿主退休时 shutdown。`setListener` 必须先于其他实例方法。如果监听器注册失败且 shutdown 也失败，记住该实例并拒绝再创建第二个实例。没有把吞掉异常当成已释放。

## 公共 AudioCapturer 与 WAV

`OhosVoiceRecorder.ets` 只依赖公开 `@ohos.multimedia.audio`。配置为 16000 Hz、单声道、PCM16LE、RAW，音源 `SOURCE_TYPE_VOICE_MESSAGE`。开始前和 start 完成后检查 `getStreamInfoSync()`；不把设备返回的 48 kHz 等格式标成 16 kHz，也未加入未经实测的重采样器。

`readData` 返回后系统可以复用输入缓冲区，所以回调返回前将所需字节复制进本会话有界缓冲。回调内不调用 AudioCapturer API，不读写文件，不向 Flutter 发消息。音量计最多抽样 1024 个采样点；消息和到限停止在后续微任务中执行。录音长度限制覆盖字节数，不依赖墙钟回调准时到达。

最多保存 `600 * 16000 * 2 = 19,200,000` 字节 PCM。构造最终 WAV 时会额外分配最多 19,200,044 字节；两者共 38,400,044 字节，不包含系统缓冲、Flutter 编解码及 GC 延迟。没有声称零拷贝或该值是整个 App 的峰值内存。

WAV 使用 44 字节 RIFF/WAVE PCM 头，16 位小端，单声道，采样率 16000，byteRate 32000，blockAlign 2。测试把产品返回的文件交给 Python 标准库 `wave`，独立解码格式和样本数值。录音满额时先实际停止/释放，随后发送 `limit`；已收 PCM 保留到 Dart 随后的 stop。取消会丢弃数据。

丢帧计数非零、无法读取丢帧计数、奇数字节 PCM、焦点中断、stop 失败等情形，不把有疑问的内容作为完整 WAV 返回，而是报告 Dart 已有录音错误 100。release 失败则继续占用租约。开始失败后也尝试清理部分创建的流。

公开文档说明录音开始的前约 100 ms 通常被静音。本实现没有在用户开始前偷偷预热麦克风，因此开头丢字仍需真机评估。16 kHz 单声道属于官方可配置格式，文档未保证每个设备都支持；该门由实际格式检查和真机测量共同闭合。

## HMS 识别范围

唯一 HMS import 在 `HmsVoiceRecognizer.ets`，使用用户提供的 `hms-contracts.md` C1 合约：`@kit.CoreSpeechKit`、`speechRecognizer.createEngine`、`setListener`、`startListening`、`finish`、`cancel`、`shutdown`。没有改用不同的 SpeechKit，也没有猜测 `LanguageQuery` 的参数。

固定 `language:'zh-CN'`、`online:1`、`locate:'CN'`、`recognizerMode:'short'`。麦克风模式显式设置 `recognitionMode:0`，长度显式设置 60000 ms，启用 partial。原生会话 ID 使用字母、数字、下划线，长度小于 64。这里拿不到音频字节；需要向 DSH speech provider 提交 WAV 时仍走独立录音路径。

capabilities 只调用工厂和监听器注册，不调用 startListening，不调用 AudioCapturer.start，不申请权限。工厂创建成功仅证明该次实例创建成功，不能证明地区服务可用、设备能识别、许可和隐私要求已经满足。代码捕获工厂失败；**没有验证系统根本不提供 HMS 模块时的模块加载行为**。

短语音结果保留最新 `result` 字符串；非 isLast 作为 partial，isLast 发一次 final，onComplete 再补尚未发送的 final 和 end。没有凭字段名擅自拼接分段。**短语音下 result 是累计文本还是分段文本、isFinal/isLast 与 onComplete 的真实顺序仍须 HMS 文档或设备确定**；若实测为分段结果，应按真实协议修订，不能把当前夹具当成证明。

HMS 的异步 onError 与同步启动异常都映射为 Dart 已有类别：1002200012 → 9（权限），1002200002/1002200006 → 8（忙），其余 → 5（可恢复识别错误）。不将十位 HMS 数字原样塞入 Android ERROR_* 空间；也不把模糊的公共 AudioCapturer 6800301 一律说成权限拒绝。未记录识别文本、音频或系统错误中的私密文字。

## 离线模型下载的实际边界

`dsh/voice` 没有下载模型方法。`DeviceVoiceModelPlatform.download()` 直接启动 Dart `VoiceDownloadTask` isolate。唯一相关原生调用是 `dsh/runtime.voiceModelLine`，现有 OH RuntimePlugin 明确返回 `ohos_unsupported`，它只是通知文案，不是下载引擎。

下载前 `VoiceModelFiles.assets()` 会读取 guestRoot 下的 `/opt/dsh/node_modules/@deepseek-ai/dsh-experimental-speech-to-text-sensevoice/runtime/assets.json`；缺失或不可解析时返回 null，`VoiceModelController` 在 refresh/download 两条路径都置为 `unsupported` 并提前返回。P2 v6 的受管 guestRoot 只建立 HOME、DSH_HOME、AGENTS 和 workspace；实际代码在单独 dsh-runtime 目录，并不凭空制造这个 `/opt/dsh` 模型锁。最终组合包仍需核对该路径确实不被额外材料填入。

本项未移植 sherpa-onnx，没有把系统中文识别当成 SenseVoice，也没有新增一个 Dart 不调用的 `downloadModel` 方法来宣称关掉下载。已有远程 DSH 的 speech provider 可以消费录音 WAV，这是原来的 Dart 行为。

## 测试命令与未完成门

```sh
python3 runtime/tests/ohos/voice-linux.py \
  --node /path/to/node-v24.22.1/bin/node \
  --typescript-prefix /path/to/pinned-process-prefix \
  --out /path/to/voice-evidence
```

该命令记录产品/测试 SHA256、Node SHA、TypeScript 版本、完整 TAP 输出、命令与环境，以及独立 WAV 解码结果。Linux 夹具覆盖权限、创建/开始/停止/释放的异步交错、跨引擎/Ability 事件、音频格式、字节上限、丢帧、HMS 两种错误入口和故障清理。首次针对时序新增的 31 项运行有 4 个产品失败，前像完整保留；修复后再跑同样输入。

必须另交真实 `check-arkts.sh --hms-stubs` 输出；stub 明确来自用户合约而非官方 HMS 头文件。通过严格 ArkTS 也不能把 HMS 编译状态改成已编译。最终签收仍需要真实 HMS 声明、合法设备前台权限行为、录音格式/焦点/首段质量、识别语言/地区/结果时序、字节通过 Flutter 到真实 Dart speech provider，以及实际 HAP 安装验证。
# v2：权限 UI 的异步前台门

独立评审对 v1 的真实 ETS 方法体复现：`checkAccessToken` 尚未返回时，同一个 Ability 进入后台；旧代码只检查 engine/Ability 身份，随后仍调用 `requestPermissionsFromUser` 或 `requestPermissionOnSetting`。这是平台 API 调用越过前台门的证据，权限 API 使用显式替身，不能据此断言手机实际弹窗。

v2 在该 await 后、进入两种权限 UI API 前，重新核对同一个 Flutter binding、AbilityPluginBinding、实际 UIAbility、当前插件 owner 及其前台状态；后续权限结果也重新核对。未引入一个宽泛的生命周期世代号：同一 Ability 回到前台后，仍允许当前请求继续。正常前台正例、后台反例、回前台正例、换 engine/Ability 的迟到结果均保留。原 v1 源码、补丁和 BLOCKED 报告不被覆盖。


# 合入 main-dd130b31：语音输入的新方式与语音输出

main 的语音输入多了 **DeepSeek** 和 **其他云端服务** 两种识别方式，自动模式在登录 DeepSeek 账号或填了 API Key 时先用 DeepSeek。两种方式都只用本通道已有的 `startRecorder`（带 `maxSeconds`）和 `stop` 取 WAV，再由 Dart 发给服务，所以鸿蒙版照常可用；账号付费的请求经本机引擎桥的 `/dsh-go/v1/speech`（`runtime/bridge/dsh-go-bridge/lib/speech.js`，随 HAP 运行时打包，未在设备上验证其出站 `fetch`）。鸿蒙本机的「自动」不再说成只用系统识别，文案见 `harmonyVoiceAutoHint`。

以下 main 功能鸿蒙版还没有原生侧，按 `androidSystemFeaturesProvider` 隐藏入口：

| 功能 | 需要的原生侧 | 鸿蒙版现状 |
| --- | --- | --- |
| 朗读（回复下方、长按菜单、酒馆菜单）、设置 › 语音 › 朗读的声音 | `dsh/speech` 的 `open`/`write`/`waiting`/`end`/`stop`/`duck` 与 `play`/`playLevel` 事件：24 kHz PCM16 流式播放 | 入口隐藏。不隐藏的话，DeepSeek 声音会先付费合成，再因 `open` 失败报「朗读失败」 |
| 语音通话（加号）、设置 › 语音 › 通话 | 同上，加 `callStart`/`callStop`/`callMute`/`callBargeIn`/`callPlaying`/`callSpeaker` 与 `speechStart`/`utterance`/`micLevel`/`callError` 事件；Android 用 ONNX Runtime 跑 Silero VAD 与 smart-turn 判停 | 入口隐藏。不隐藏时 `callStart` 得不到处理，通话以「麦克风不可用」结束 |
| 实时字幕（设置 › 语音） | `dsh/voice` 的 `streamingPcm` 与 PCM 事件；sherpa-onnx 只有 Android/桌面库，在 `ohos` 上抛 `UnsupportedError` | 下载卡隐藏；听写的 `liveWords` 取不到模型即照旧 |

实现顺序建议：先做 `dsh/speech` 的流式播放（AudioRenderer），朗读即可用；通话还需要判停模型在鸿蒙上的推理方案。
