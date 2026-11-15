# iOS 伙伴配音

这是现有 `dsh/companion_voice` 的 iOS 实现，最低 iOS 15。Dart 的默认关闭、
用户选择声音源、请求外部语音服务、临时音频文件管理和同一句系统朗读回退沿用原合同。
本增量不增加界面、小组件、录音、网络请求或原生声音缓存。

**验证状态：本次 Linux 环境没有 Swift 编译器、Apple SDK、模拟器或 iPhone。
Swift/XCTest 的 Apple 编译和执行均为 UNRUN；没有声音、权限对话框、PiP 共存、
设备能耗或后台时长的实测结论。** 下列保证分为代码中的状态合同和仍须 Apple 验收的行为。

## 接入

`IOSCompanionVoice` 是 `@MainActor` 对象。由 AppDelegate 在已有主 actor 上创建并保留：

```swift
companionVoice?.dispose()
companionVoice = IOSCompanionVoice(messenger: registrar.messenger(), pipAudioConfigured: {
  IOSPetOverlay.shared.statusSnapshot["audioSessionConfigured"] as? Bool == true
})
```

AppDelegate 的持有属性、Runner / RunnerTests 的 Xcode 注册和现有 iOS compile job
测试条目由同一交付的集成改动负责。再次初始化 Flutter engine 时先 `dispose()` 旧对象，
再绑定新 messenger。该方法返回前结清旧工作，移除通道 handler 和 timer；
迟到的旧读取或 delegate 结果不能发事件或启动新声音。系统音频通知由共享协调器集中处理。
`pipAudioConfigured` 初始化标签仅为现有 AppDelegate 保留源码兼容，闭包结果不再授予
借用权。PiP 与配音分别取得协调器中的成员 token，不能用一份状态快照代替成员身份。

不需要新增麦克风用途声明或请求麦克风权限。`ready` 路径只查询系统当前可用的 voice，
不创建朗读请求，不调用音频会话 setter、`prepareToPlay` 或 `play`。
这是源码调用范围；首次安装的权限界面仍须实际观察。

## 通道合同

所有方法和回调使用 MethodChannel `dsh/companion_voice`。

| 方法 | 参数 | 结果及行为 |
|---|---|---|
| `ready` | `{language: "zh-CN"}`，缺省同左 | `bool`。成功选择供后续句子使用的系统 voice；不支持的语言返回 false，保留先前成功选择。表示当时可解析，不表示以后一定能发声或所有音质永远离线可用。 |
| `speak` | `{id, text, flush?, pitch?, rate?}` | `bool`。必须先成功 ready。默认排入 TTS 队列；`flush=true` 仅结清 TTS 的正在朗读和排队句子。参数拒绝时不清旧队列。 |
| `play` | `{id, path}` | 异步 `bool`。后台读取、构造解码器和检查时长；实际受控 `AVAudioPlayer.play()` 返回 true 才接受。替换先前 clip，保留 TTS 域。 |
| `stop` | 无 | `null`。结清两个输出域和待加载请求，不自动继续旧内容。 |

保留 Android 的两个独立输出域，所以直接同时调用 `speak` 和 `play` 时可能重叠播放。
正常 Dart 外部声音泵一次只等待一句。不要把本通道解释成自动混排的统一播放列表。

ID 必须是 1–128 个 ASCII 字母、数字、下划线或连字符，保留大小写、不重写 ID。
现调用方使用 `vN` 和 `preview-N`。已被在播、排队或加载工作占用的 ID 不能再次接受；
终态或 `stop` 后可复用。新 utterance / player 对象与各输出域的 UUID generation
共同判定回调归属，同名旧对象不能结束新工作。

回调方法 `event` 的参数为 `{type, id}`，range 另有 `start` / `end`，错误或中断可有
不包含文本、文件路径或系统异常详情的稳定 `code`：

| type | 含义 |
|---|---|
| `start` | TTS 的 didStart（或首个有效 range）；clip 的 play 返回 true。不是扬声器可听性的证明。 |
| `range` | 原始 `speechString` 的 UTF-16 location 与 exclusive end，逐字传递给 Dart。 |
| `done` | 当前对象的完成回调，clip 还要求 successfully=true。 |
| `stopped` | stop / flush / 替换 / dispose / 可观察中断或会话撤销。 |
| `error` | 已接受的工作遇到解码失败或无进展超时等问题。 |

每个**已接受**请求只结清一次终态。未开始朗读的排队项也由本控制器结清，不依赖系统
为它们逐一发 didCancel；Apple 明确该回调不覆盖未朗读项。[1]

被拒的新 `play` 不发 start 或终态，也不会在稍后的读取、解码或播放器回调中发出它们。
这是 Dart 用**同 ID** 回退 `speak` 所需的边界；早到的播放器结果先缓存在 provisional
请求里，只有 play 成功才进入已接受状态。先前已接受的其他工作仍拥有自己的终态。

### 文本、速率和范围

- 一句最多 4096 UTF-16 code units / 16384 UTF-8 bytes；TTS 域合计最多 32 条、
  32768 UTF-16 code units（包括当前句）。超限整句返回 false，不截断后朗读。
- pitch 范围 0.5–2.0，默认 1；Dart 传 1.12。
- rate 参数范围 0.1–4，默认 1；映射为 `DefaultSpeechRate * rate`，再限制到 Apple
  的 min/max 常量。它是参数映射，不声称跨平台等速或精确线性倍速。[2]
- 每句创建独立 utterance，并在入队前固定 voice、rate、pitch。后来 ready 不改变旧句。
- `A😀é中` 有 6 个 UTF-16 code units、4 个 Swift grapheme clusters。NSRange `(1,2)`
  直接给 Dart `start=1,end=3`；不按 `String.count`、Unicode scalar 或 runes 换算。[3]
- TTS 使用 **5 分钟无有效进展** watchdog，不是 5 分钟总时长。首次 start 或有效 range
  的 UTF-16 终点前进会刷新；重复 start、重复/逆行 range、越界 range 都不刷新。
  超时结清当前及其 TTS 队列为 error，clip 域可继续。

## 本地音频边界

原生只接受系统缓存目录的 canonical anchor 下这一叶子名称：
`companion-voice-<exact-id>.<kind>`。`kind` 为 Dart 现有的小写
`wav / mp3 / m4a / flac / ogg / bin`。通过目录 descriptor 和 `openat` 读取；
拒绝最终叶子符号链接、目录、空文件、超限文件和不符合名称/目录的路径。
原生不从 URL 下载，不复制到新缓存，不持久化，不删除或覆盖 Dart 原文件。

一次输入最多 **16 MiB**，实际播放器时长必须有限、正数且 **≤55 秒**。文件按块读取，
取消在块间检查；前后 fstat 与大小检查拒绝观察到的文件改变。扩展名只用于匹配 Dart
合同，解码器按实际 bytes 初始化：`ogg`、`bin` 或任意容器/编码组合都**不保证支持**，
不能解码则返回 false。Apple 要求输入是 Core Audio 支持的格式。[4]

读取/构造播放器的逻辑等待上限为 5 秒。取消、超时和 dispose 立即使该请求不可接受，
并在可运行的主 actor 上返回 false；这不表示能中断已进入的系统读取或解码调用。
生产 loader 使用跨实例共享的单一物理槽，直到后台工作真实返回才放开；
替换 Flutter engine 也不能趁旧 decoder 未返回而启动第二个物理工作。忙时返回 false。
文件 bytes 有界不等于已测得系统解码器峰值内存或硬实时延迟。

后台阶段不调用 `prepareToPlay()`。Apple 明确它会激活共享音频会话，而 `play()`
会按需隐式调用它；因此 play 必须在请求身份和会话许可有效后执行。[5]
读取、容器解析和播放器构造离开主线程；会话 setter 与实际播放启动留在主 actor。
这些系统启动调用的最坏耗时未在设备测量，不能宣称整个启动绝不阻塞。
已接受 clip 超过其声明 duration + 3 秒仍无有效完成时结清 error；该界限最多 58 秒，
在 Dart 外部音频泵的 1 分钟等待前留余量。

## 音频会话交接（ADDENDUM-09 §2.2）

本轮以 `3302d3a791d39ccac1327b8915b6f517217a92df` 为基底独立重交 16，
不依赖退回的 24。`IOSAudioSessionCoordinator` 收拢 Runner 中显式的 category / active
setter；PiP、配音、Voice、NativeMedia 和静音启动片都通过成员 token 协作。
`IOSCompanionAudioLease` 供配音的两个输出域共同持有，只有 TTS 与 clip 都空才释放它。
尚在读取的 clip 不预先占用音频成员，但记录音频环境代际。

| 角色 | 取得配置与优先级 | 加入 / 撤销规则 |
|---|---|---|
| PiP、companion | playback / default / mixWithOthers | 可加入同一输出组；后加入不再 configure / activate；任何一方正常离开只删自己的成员。 |
| silentVideo | 独自使用 ambient / default；不显式 activate | 加入已激活的输出组不降级配置；录音或独占媒体占用时可拒绝播放启动片。 |
| nativeMedia | playback / spokenAudio / duckOthers + mixWithOthers | 可抢占共享输出组，先撤销旧成员并停输出；已有录音时拒绝。 |
| recording | record / measurement，无 duckOthers | 可抢占协调器管理的共享组或媒体组；外来 playback / default、spokenAudio、moviePlayback 也允许新录音尝试。已有外来 record / playAndRecord 仍拒绝。 |

相同 category / mode / options 不是成员身份，也不是 OS 当前 active 的证明。首次取得
非静音成员仍须成功 activate；当前 token、可观察配置与组激活记录共同构成本地准入。
PiP 已开始之后，配音不再为自己显式激活；`AVAudioPlayer.play()` 仍可能隐式准备/激活，
不能把零新增显式 setter 写成框架零激活。[5][6] 外来配置若无法区分于本组完全相同的
tuple，公开 API 也不能证明是否发生了同 tuple 接管。

抢占时，协调器先使旧 token 失效，再同步通知客户端停止输出，随后才安装新配置。
所有 token 都离开时才尝试 deactivate / restore，恢复的是这条合作链最初的 baseline，
不把中途 PiP 或录音 tuple 当成新的原始配置。恢复前和 deactivate 后均核对仍属本组。
deactivate 抛错时保留 residual，不把可能仍 active 的会话改回 soloAmbient；后续只有
原 tuple 仍在才沿用 residual 的真实 baseline。过渡期释放最后一个成员由过渡结束的
统一清理处理；同一次准入若已接纳新成员，不错误地释放它。

### 拔耳机、重置与恢复

`oldDeviceUnavailable` 只撤销 companion、nativeMedia、recording。PiP 与 silentVideo
成员、配置及激活仍可用时继续保留；这一路由变化本身不令 PiP fail，也不由 overlay
触发手机任务暂停。配音正在说的句子、排队项和已接受 clip 各结清一个
`stopped / route-lost`。待加载但尚未接受的 clip 返回 false，无终态。
过渡中的同步 route-loss 也必须保留仍可用的安静成员，不经全组失败路径将其撤销。
若系统同时改变了配置，则仍按可观察的真正所有权丢失处理；本合同不保证系统持续运行。

来电 interruption、媒体服务 reset 或配置被其他 owner 改变仍可撤销整个组。旧工作
不会因 interruption ended、重新前台或后续可用性通知自动重播。解码中的工作记录
`environmentGeneration`；短暂录音即使已经结束、配置已经恢复，旧 decoder 回调也不能
重新开始。一个从未占用音频成员的 pending decoder 也受 reset / route-loss 代际保护。

reset 后，自动配音、静音启动片、状态/能力查询、普通 foreground 回调和 NativeMedia
pause/resume 都不清 `requiresUserAction`。有效、前台且 protected data 可用的 Voice
`startRecognizer` / `startRecorder`，以及已经通过当前 owner、path、hint 等既有校验的
NativeMedia 新 `play` 入口，才按本轮维护者要求调用 `retry(userInitiated: true)`。
PiP 的原生启用/恢复确认也可调用。无效参数、能力查询和恢复旧播放器不能替代新准入。

**这里是入口 / 角色级恢复策略，不是每次都证明新发生了物理用户点击。**
现有 Dart 系统听写失败后的自动 fallback 会调用 `startRecorder`，可能另取一个
sessionId；该 ABI 没有可信的发起来源字段。因此不能将每个 startRecorder 都描述为
新的用户手势。Apple 要求媒体服务 reset 后由用户动作发起重新录播，[9] 本包按现有
合同恢复合法新入口，严格到物理手势的端到端证明仍需维护者调整发起来源或交互协议。
本包未改 Dart。新请求也仍需经过权限、所有权、前台条件和音频取得，不能复活旧 token。

### 析构与 PiP 可用性

NativeMedia 用显式 `storedCaption` 保存已创建的字幕。deinit 只捕获既有 player、
caption 和 lease，转到主线程停止、释放、隐藏；不访问会创建字幕的 getter，不在
NSObject 析构中建立新 weak self。普通 hide/dispose 也不为了清理创建字幕。

Voice / Microphone 的非主线程析构使用一次性 cleanup 转移既有资源。lease 的
resource-only stop 闭包还由协调器独立保留：主线程 cleanup 尚未执行时若发生抢占，
仍先停止旧输出，再安装后继配置；迟到的旧 release 只能删旧成员，不影响新 token。
`@unchecked Sendable` 只覆盖这个运行时主线程约束和加锁的一次性转移，不宣称整个
Flutter / AVFoundation 层已经获得 Swift 6 编译器验证。

PiP availability 代际根据 PiP blocker 或实际 PiP 成员丢失变化。普通一句配音的
加入、完成、释放不触发 recover；一轮短暂录音的 busy→ready 即使通知合并也有新代际。

AVSpeechSynthesizer 保持 `usesApplicationAudioSession=true`。[7] 活动期间每 250 ms
检查租约，补充 mode/options-only 替换没有 categoryChange 通知的情况。App 挂起时
timer 没有实时保证；再次可运行时先按跨睡眠单调时钟检查期限和身份。

### Dart 可见变化清单

本包没有新增方法名、状态键、phase 或错误码枚举值；下表列出既有值的新触发条件。

| 通道 | 变化及现有消费者行为 |
|---|---|
| `dsh/companion_voice` | route loss、reset、录音/媒体抢占结清已接受项，仍使用既有 `stopped` 与 `route-lost / media-reset / audio-replaced`；未接受 play 只返回 false，同 ID TTS fallback 仍可尝试新准入。 |
| `dsh/native-media` | play 在音频取得失败或读取期间环境失效时返回既有 `audio`；pause/resume 租约无效也返回 `audio`。正在持有 player 的成员撤销时发送既有 `audio.stopped`、reason=`interrupted`，先停止输出再释放。Dart 的 play 异常分支归为 `audio.error` / media；pause/resume 异常可撤销 owner，终态可隐藏字幕。 |
| `dsh/voice` / `voice/events` | 路由丢失、reset、音频撤销触发当前 session 的 error 后 end：系统识别仍用 3，recorder 仍用 100。开始时取得失败仍返回既有 `FlutterError("audio")` 与对应数值。旧 sessionId 的迟到事件被丢弃；Dart 可走既有自动 fallback。 |
| `dsh/pet_overlay` | 仅 oldDeviceUnavailable 不再生成 `overlay_audio_interrupted`；真正 interruption 仍映射该码，reset 为 `overlay_media_reset`，抢占/可观察替换为 `overlay_audio_replaced`，外来 spokenAudio/moviePlayback 阻塞新 PiP 为 `overlay_audio_busy`。 |
| `dsh/launch_clip` | 音频协调器拒绝时启动片可直接 `done`，可能没有一帧 `showing`；Dart 既有海报路径须验收。没有新增结果键或事件。 |

## 回归与 Apple 验收

当前源码有 `IOSCompanionVoiceTests` **45** 个 test 方法与
`IOSAudioSessionCoordinatorTests` **43** 个 test 方法，共 **88 authored / 0 executed**。
这是对当前新候选逐个方法名计数，不是旧环境测试结果的转移。测试调用生产 engine、
coordinator、lease 和 file loader；录制适配器不发声，也不访问真实麦克风。

配音夹具覆盖独立输出域、FIFO/flush/stop、准确 ID、同 ID 旧对象、UTF-16 范围、
false play 的 inline/late 回调、读取取消/超时、dispose、双域最后释放、PiP 两种
加入次序和独立离开、route loss 保留安静成员、同步录音抢占先停输出、无成员的
pending decoder 代际、短暂录音与 reset 后的迟到回调，以及恢复策略的模型入口。
实际文件读取测试只生成自己的合成缓存文件；播放器构造只用合成无效 bytes 或
50 ms 静音 PCM，不调用真实 play。跨实例 loader 用受控队列检查物理槽的释放时机。

协调器夹具覆盖两种释放顺序、过渡重入、partial setter failure、deactivate failure
residual、外来会话、route-loss 同步回调、PiP availability 代际、后台资源转移；
NativeMedia 的未用/已用字幕析构与无效 play 采用实际 Flutter method codec / channel
和假的 messenger、caption。合法 Voice/Media 新入口的正向恢复夹具调用协调器，
**没有**执行真实 Voice 权限 UI 或真实 NativeMedia 音频解码/播放全链路。
off-main 夹具用 async 工作加两秒有界 semaphore 确认真正不在主线程；不执行旧版 fatal
重现，也不运行设备崩溃、高 fd 或用户音频 probe。

Apple CI 在原 12 个 `-only-testing` selector（其中含 Companion）基础上新增
`-only-testing:RunnerTests/IOSAudioSessionCoordinatorTests`，共 13 个。
所有 XCTest 均为**已编写、尚未执行**；静态源码、shell 语法和真实 Git apply 检查
不计为 XCTest PASS。当前修复仍等待 Apple SDK 编译和独立审查。

首次 Apple 验收还须记录：
首次 Apple 验收还须记录：

1. 新装默认静音；ready 中文/英文不发声、不出现麦克风提示；不存在的语言明确 false。
2. 用户开启后，实际可听的中英文 FIFO、flush、stop；emoji/组合字符 range 与 Dart 嘴型对齐。
3. Dart 真实本地 WAV/MP3/M4A 与实际不支持的样本；失败后同 ID TTS 回退只有自身终态。
   不把一次成功扩大成全部后缀/编码支持。
4. 配音 / PiP 两种先后与离开次序；PiP 离开不结束仍在播的配音，配音结束不触发 PiP recover。
   录音 / NativeMedia 抢占先停旧输出；旧释放不覆盖后继 owner；拔耳机保留实际 PiP 和手机任务。
5. 来电、后台/锁屏、媒体 reset 后无旧工作自动重播；不用 PiP 也可从合法 Voice / Media 新入口恢复。
   分别测用户开始和 Dart 自动 recorder fallback，记录真实手势来源，不能仅从 sessionId 推断。
6. 连续读取期间 stop、同 ID 复用和 messenger 更换；测实际加载/启动延迟与内存。
   记录失败和未知，不把停止请求等同于 OS 立即物理静音。
7. 录音去掉 duckOthers 后，其他 App 音乐可能被打断而非压低；record 类别不允许该选项。[8]
   PiP 改 default mode 的实际兼容性、静音启动片被拒绝时的海报/首帧行为，均为真机 UNRUN。
8. 未 activate 的 NativeMedia 被 messenger/插件替换、已显示字幕后的销毁、非主线程 Voice
   teardown 与重入抢占；验证无崩溃、无孤立声音、无旧回调影响后继。新代码夹具不替代设备观察。

## 公开 API 依据

以下只用于设计与声明核对，不是本次执行证据：

1. [Apple didCancel](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizerdelegate/speechsynthesizer(_:didcancel:))。
2. [Apple rate](https://developer.apple.com/documentation/avfaudio/avspeechutterance/rate)、
   [pitchMultiplier](https://developer.apple.com/documentation/avfaudio/avspeechutterance/pitchmultiplier)。
3. [Apple range delegate](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizerdelegate/speechsynthesizer(_:willspeakrangeofspeechstring:utterance:))、
   [NSString UTF-16](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Strings/Articles/stringsClusters.html)、
   [Dart String](https://api.dart.dev/dart-core/String-class.html)。
4. [Apple AVAudioPlayer(data:)](https://developer.apple.com/documentation/avfaudio/avaudioplayer/init(data:))。
5. [Apple prepareToPlay](https://developer.apple.com/documentation/avfaudio/avaudioplayer/preparetoplay())、
   [play](https://developer.apple.com/documentation/avfaudio/avaudioplayer/play())。
6. [Apple AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession)、
   [setActive](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactive(_:options:))。
7. [Apple usesApplicationAudioSession](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/usesapplicationaudiosession)、
   [speechVoices](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice/speechvoices())。

8. [Apple duckOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/duckothers)、
   [mixWithOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers)。
9. [Apple mediaServicesWereResetNotification](https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification)。
