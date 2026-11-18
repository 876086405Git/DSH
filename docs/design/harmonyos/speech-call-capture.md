# HarmonyOS 通话采集、能量判停与 PCM 分流（1303）

## 本件结论与证据边界

本件在 `8faafe6` 源快照上补齐 `dsh/speech` 的通话采集及控制，并把同一个采集器的 PCM 送到既有 `dsh/voice/events`。播放依赖已审 1302 的通话 PCM 后端；字幕识别器由另件 CoreSpeech 适配承接。本件没有新增模型、sherpa、ONNX Runtime 或第二个录音器，也没有开放 Flutter 通话/字幕 UI。

**本件采用 Android 已有 `SpeechGate` / `TurnPause` 的能量 fallback。它没有移植 `NeuralGate` 的 Silero VAD 与 smart-turn，不能宣称两端判停、抗噪声或打断体验等价。** 能量较大但并非人声的输入仍可能开启一句话；安静尾音、背景噪声与回声的实际表现需手机录音证据。`VOICE_COMMUNICATION` 请求系统语音处理，不能证明指定手机或外接设备实际获得了与 Android 一样的 AEC。

主机测试执行实际 ETS 源体，明确替代 AudioCapturer、AudioRenderer 边界、Flutter transport、权限、单调时钟和自身 Window。SDK 类型声明是本库的主机 fixture，不是官方 SDK 头；TypeScript 严格检查与 Node plain/jitless PASS 均不能代替 API 26 ArkTS/HAP 编译或手机测试。

## 源码职责

| 文件（`app/ohos/entry/src/main/ets/plugins/`） | 职责 |
| --- | --- |
| `CallEnergyGate.ets` | Android 能量门与 quick/normal/patient 三档停顿的同常数移植 |
| `OhosCallCapture.ets` | 单 AudioCapturer、640 字节分帧、300 ms 前卷、110 s WAVE 上限、静音隔离、溢出与中断处理 |
| `OhosSpeechCall.ets` | 与听写共享 `VoiceMicLease`、启动结果、控制、前台窗口常亮及恢复 |
| `VoicePcmTap.ets` | 单个显式订阅、source/session/owner 身份与帧边界；自身不占麦克风 |
| `VoicePlugin.ets` | `streamingPcm` 方法及 `pcm` / `pcmReset` 事件 |
| `OhosVoiceRecorder.ets` | 普通听写录音器复用 PCM 分流；启动、overflow 通过后放行 |
| `SpeechPlugin.ets` | 原 13 个 Android 方法的实际调度，call 播放/采集状态，barge-in duck 与生命周期 |

Android 对照文件在 `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/` 下：`speech/SpeechPlugin.kt`、`speech/CallCapture.kt` 及 `nativemedia/SpeechGate.kt` / `TurnPause.kt`。测试从未改动的 Android `SpeechPlugin` 提取 13 个方法名，逐一调用实际 OH handler，防止再次遗漏 `callPause`。

## 方法与事件合同

| 方法 | 行为与结果 |
| --- | --- |
| `callStart(bargeIn,pause)` | 权限已获批、MIC lease 和窗口常亮初始化成功后返回 `ok`；未授权返回 `permission`，采集/麦克风准入失败返回 `microphone`，退休、平台不可用或窗口阶段失败返回 `unavailable`。不在此方法弹权限框。 |
| `callStop` | 立即退休当前采集 owner，等待真实 stop/release 与自身窗口恢复；停止本通话 PCM，不误停独立朗读 stream。失败保留重试句柄，不伪造释放成功。 |
| `callMute(on)` | 清除已排队事件、半帧、前卷、当前话段及 tap 缓存；静音期间不送 PCM、不产生话段，只保持零电平显示。 |
| `callBargeIn(on)` | 关闭时忽略播放期间的语音起点；重新回到非播放状态后恢复正常判停。 |
| `callPause(pause)` | quick / normal / patient 分别使用 700 / 1000 / 1600 ms 连续低能量；未知值回 normal，大小写不敏感。 |
| `callPlaying(on)` | 外部播放标记与本通话 renderer 的已开始状态合并，驱动能量门播放阶段。 |
| `callSpeaker(on)` | 当前存在通话 renderer 时等待 1302 的 SDK 路由偏好调用；失败明确报错并保留旧偏好。尚无 renderer 时只保存下一次通话播放的偏好。每次请求递增独立序号，迟到的旧请求不能覆盖新偏好，并明确失败，避免 Dart 在 await 后回写旧布尔。返回布尔表示接受的偏好，不证明物理出声设备。默认 true，与 Android 一致。 |
| `open/write/waiting/end/stop/duck` | 沿用 1302 PCM 合同；当前通话播放开始/结束同步采集门；播放时识别到语音起点会 duck 当前通话 renderer。 |

`dsh/speech` 通过同一 MethodChannel 的 `event` 回调发送 `speechStart(over)`、`utterance(wav,ms)`、`micLevel(value)` 和 `callError(reason:'capture')`。播放事件及播放电平沿用 1302。静音、退休或采集异常不会把被丢弃的片段伪装成成功 WAVE。

`dsh/voice.streamingPcm` 保持 Android 的 `source='call'|'dictation'` 与 `pcmSession` 合同：未知 source 返回 `pcm-source`，错误 details 为 null；关闭时只匹配当前 session。`pcm` 事件含 `bytes`、`rate:16000`、`source`、`pcmSession`。每帧 PCM16LE 单声道 20 ms，即 640 字节；不额外申请麦克风。

OH 扩展事件 `pcmReset` 含 `source:'call'`、`pcmSession`、`reason`。实际 mute、resume 和已观察到 tap 的采集 stop 分别送 `muted`、`resumed`、`stopped`。识别器消费者必须据此退休未结算的 partial 并重建会话；仅停止送帧不能阻止识别器的迟到结果。事件按 tap 对象身份匹配，旧 owner 的 stop 不能重置新的订阅。

## 采集时序和有界内存

通话格式固定为 16 kHz、单声道、S16LE raw，创建及 start 后均核对 SDK 实际格式；不做静默重采样。`readData` 仅复制和处理内存，不调用 AudioCapturer 接口、不向 Flutter 发送事件。SDK buffer 可以在返回后复用，实际测试会覆盖原 buffer 来检验副本。

SDK 可以在 `start()` Promise 完成前交付 PCM。通话与听写分流都暂存这些早期帧，等待实际启动成功及本轮 `getOverflowCountSync()` 为零再送出。启动失败、中断、overflow、静音、后台或 owner 退休会清空暂存；正常早期帧保留样本字节。tap 暂存上限为 128 个完整帧（81,920 字节）；超过上限视为采集故障，不能无限积压或悄悄漏帧。

通话输入以 640 字节重组，前卷最多 15 帧，即 300 ms。起点纳入前卷与当前帧；一句话最多 110,000 ms、3,520,000 字节 PCM，加 44 字节 WAVE 头。到顶即结算这一句并重置话段状态。完整 PCM、WAVE、通知和延迟 tap 都绑定 owner/静音 epoch；跨 mute/unmute 的半帧不会拼接。奇数字节及超出本件 65,536 字节回调预算的输入明确失败。

能量门使用 RMS dBFS，非播放/播放起点持续量分别为 6/10 帧，播放切换后有 400 ms 稳定时间。起点相对噪声底的 margin 为非播放 15 dB，已证 AEC 的播放分支 24 dB，未证 AEC 的播放分支 30 dB；本件生产代码使用未证 AEC 分支。结束阈值比起点低 6 dB。计时用 `getUptime(STARTUP,false)` 的毫秒值，不受墙钟调整影响；时间单位及暂停阈值均由 Android 对照和主机向量验证。

## 麦克风、窗口及退休

本件复用已有 `VoiceMicLease`。活跃听写或通话已占用时不覆盖；native-media 持有者须先完成真实释放，才能创建通话采集器。release 失败保留旧 token，后续 stop 或下一 owner 可重试；返回的 Promise 本身不被当作已释放证据。

后台、Ability detach、engine detach/replacement、callStop 先使 owner 失效，随后真实释放资源。尚未完成的权限查询、AudioCapturer 创建/start、Window 查询/set 不能复活 owner。窗口初始化等待期间收到 stop，麦克风先立即退休并释放，不等待迟到的 Window Promise。

仅操作调用 Ability 取得的本应用 Window。读取 `isKeepScreenOn` 后，原值 false 才设 true；stop、后台和启动失败恢复原值，原来 true 的窗口不被本件改成 false。失败但可能已生效的 set 也进入恢复；恢复失败保留可重试 owner，阻止下一 call 假成功。已取得的窗口后来报告 `1300002`（未创建/已销毁）时，本件认为该旧窗口已无可持续持有的 screen flag，清理恢复句柄。没有新增全局 wakelock 或后台常亮能力。

## 官方接口证据（2026-11-15 核对）

| 接口 / 事实 | 官方来源与使用边界 |
| --- | --- |
| `on/off('readData')` API 11；回调内不得调用 AudioCapturer 方法；`getOverflowCountSync` API 12 | [AudioCapturer](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-audio-audiocapturer/)。本件检查放在离开 read 回调后的微任务。官方还说明启动后的前约 100 ms 通常会被系统静音以消除硬件上电杂音；300 ms 应用前卷不能恢复系统已静音的数据。 |
| `VOICE_COMMUNICATION` 及语音通话处理 | [Audio 枚举](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-audio-e/) 与 [通话开发指南](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/audio-call-development/)。需结合 capture source 与播放 usage；系统处理效果仍与路由/设备有关。 |
| `systemDateTime.getUptime` API 10 | [系统时间](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-date-time/)，STARTUP 包括深度睡眠，false 返回 ms。 |
| `window.getLastWindow(context)` API 9 | [Window API 14 参考](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V14/js-apis-window-V14/)，获取该应用窗口，不是任意全局窗口。 |
| `setWindowKeepScreenOn(boolean):Promise<void>` API 9 | [Window](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-window-window/)。仅当前前台窗口有效，交互场景结束须恢复；官方不鼓励纯后台音频场景使用。本件限定前台通话界面生命周期。 |
| `AudioRenderer.setDefaultOutputDevice` API 12 | [AudioRenderer](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-audio-audiorenderer/)。1302 每流实现，耳机可优先；本件不新增全应用 AudioSession 路由。 |

MICROPHONE 使用项目已有声明，并在每次 callStart 检查；没有新增授权范围。上述公开合同可用于审查代码设计，API 26 手机实际支持、权限交互、前后台抢占、蓝牙/听筒/外放及能量判停效果仍需编译与设备证据。

## 可重放测试与待定证据

新增 `call-capture-linux.py` 支持 plain / jitless，保存命令、Node/TypeScript SHA、执行前后源文件 SHA、TAP 与计数；`run-gates.py` 登记 `call-capture-plain` / `call-capture-jitless`，显式纳入原 voice 回归。原 `speech-channel-linux.py` 增加真实 call 产品依赖，严格主机类型检查覆盖这些文件；旧播放 fixture 将捕获能力明确设为 unavailable，新通话 fixture 才实际执行 capture/control。产品业务代码均未被 stub 替换。

重点反例包括：start 挂起时的早期 PCM、start 失败与 overflow、read buffer 复用、静音前已排队帧、半帧跨静音、订阅换代、release 失败、后台/迟到 start、迟到 Window lookup/set、常亮恢复失败、旧 controller 误停新 call、callStop 误停朗读、callStart 等待旧播放释放期间被 callStop 取消。110 s 上限使用完整 5,500 帧验证。

证据等级：源代码合同和上述主机时序可定论；系统 SDK 编译、实际 MIC/AudioRenderer、AEC 抑制、设备路由、屏幕功耗与外部 PCM ASR 准确率尚未定论。后者需要当前累计候选在 API 26 设备上进行：录音/播放并行与权限拒绝，外放/耳机切换，静音后迟到字幕检查，前后台/重建释放观测，连续话语与三档停顿录音对照，以及正常结束/取消/故障的屏幕状态恢复。不得用本件主机 PASS 代替这些结果。
