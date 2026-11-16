# 1304：鸿蒙系统实时字幕（数据与协议层）

范围：数据、协议与原生系统识别；具体测试和独审结论绑定交付包中的完整补丁 SHA。公开 Core Speech API 形成调用合同，尚未用真实 HMS SDK 编译，尚未在手机核实。

## 为什么选这个后端

1300 的语音选型已对照官方 sherpa-onnx HarmonyOS HAR 与 Core Speech Kit。当前实现采用系统离线普通话识别，不新增产品依赖、模型下载、NDK 库或 Android 改动。它消耗 1303 已有采集器的 PCM tap；不申请新的权限，不再开一个麦克风。通话切轮仍由 1303 的 SpeechGate/TurnPause 能量回退负责；系统 ASR 的句末停顿不能代替 callPause、Silero 或 smart-turn。

Android 现有字幕走 Dart isolate/sherpa FFI，没有一个可直接复用的 Android 原生 ASR 方法通道。因此保留 StreamingAsr/LiveWords 的事件形状和 Android 后端，仅对 OH 增加 dsh/streaming_asr。dsh/speech、dsh/voice 的原有方法仍由对应插件负责，字幕插件没有通话控制权限。

## 数据合同

| 入口 | 参数／结果 | 约束 |
| --- | --- | --- |
| start | `{run: 正安全整数}`，成功无返回值 | 前台 Ability；等待系统 onStart；旧资源成功 shutdown 后才分配新引擎 |
| feed | `{run, bytes: Uint8Array(640)}` | 16 kHz、单声道、PCM16LE；立即复制；最多排队 50 帧；过载明确 error，不偷偷丢新音频 |
| stop | `{run, finalize: boolean}` | false 立即令旧结果失效并丢待写队列；true 写完已接收队列、等完成回调、再 shutdown |
| event | `{run, type: 'partial'/'final', text}` | text 是当前句的假设或结果；不是整个通话的累积文本 |
| event | `{run, type: 'error', reason}` | 运行期失败通过错误流到 Dart，不伪装成识别文本 |

run 由 OH Dart 后端递增生成，用来隔离迟到的方法回复与事件。原生物理句柄独立于 Flutter 逻辑会话保留；shutdown 失败不会释放共享 ASR 准入，也不会分配第二个引擎。显式 stop 与下一次 start 都能重试退休资源；新请求在退休旧资源时失败，也保留该重试链。

HmsVoiceRecognizer 的普通系统听写与 HmsStreamingAsr 共用一个引擎准入令牌。空闲预热的普通听写可先 shutdown；活动中的普通听写不会被字幕抢走。相反方向同样返回 busy。此为 App 进程内约束，不保证其他应用没有占用系统服务。

## 时间、队列与长会话边界

Core Speech 的 writeAudio 文档规定 640 字节／20 ms 或 1280 字节／40 ms。本实现采用 640 字节、一项可取消的 20 ms 定时任务，只在已收到 onStart 且有待写帧时调度；不会在暂停后突发追赶。50 帧对应最多 32,000 字节的这一级 PCM 队列，不包含系统服务、Flutter 通道、采集器及模型内部的内存，不能换算为 App PSS。

同一份官方文档的 writeAudio 段写最长 60,000 ms，StartParams 的 long 模式又写最长 8 小时。这一矛盾尚待实际 SDK／设备定论。当前按已写采样数在 55 秒主动 finish，等旧会话 onComplete 后才重启；这 55 秒是产品选定的保守段长，不是实测延迟、官方推荐值或体验保证。

轮转期间的音频仍进入有限队列。旧 onComplete、新 startListening 到迟到 onStart 之间，finalize 必须保留尾帧；重复 finalize 共享同一个完成 Promise。取消始终优先，迟到的旧 sessionId 不再出字。

**不能据此承诺无限时长连续不丢字。** 输出节拍与实时输入名义速率相同，轮转耗时和调度抖动会积累队列延迟；达到上限时本实现明确结束字幕并报告 queue，而不是扩大到无界内存或悄悄跳帧。是否可用同一个 long 会话连续输入超过 60 秒、轮转实际耗时和可持续时长都需要手机测量。字幕失败不应取消仍然健康的通话 WAV 采集与云端回合。

## 静音、恢复与 UI 接线

1303 在共享 tap 上发 `pcmReset`，包含 source、pcmSession 和 muted/resumed/stopped。StreamingPcmCapture 只接受当前 source/session 的重置信号。OH 系统模型下，LiveWords 静音时取消识别并清掉当前字，恢复时建立新 run；来源停止则释放字幕订阅与 ASR。旧 run 的回调不能重新显示已静音的内容。

### 系统就绪 provider

`app/lib/state/streaming_asr_state.dart` 新增 `ohosStreamingAsrReadyProvider`，类型为 `AsyncValue<SystemAsrReadiness>`，无需创建下载模型 store，也不读取四个模型文件。

| 状态 | 准确含义 | 本机界面处理 |
| --- | --- | --- |
| AsyncLoading | 本次系统服务探测尚未结束 | 显示检查中，不能写已就绪 |
| ready | 已有真正活动的字幕识别，或本次外送PCM引擎收到onStart且成功释放 | 可选择系统字幕；真正start仍可能因资源变化失败 |
| busy | 本App识别启动、物理关闭或另一就绪探测尚未结束 | 让出，不抢占；待操作完成或用户重试后invalidate |
| unavailable | 当前系统不是ohos | 保持原平台文件模型路径，不做OH调用 |
| AsyncError | native start、错误事件或物理关闭失败，保留异常 | 显示原因与重试，不伪装成模型未下载或已成功 |

探测使用独立的 `OhosStreamingAsr.forReadiness()`，走同一个真实 `start/stop` 合同，以 recognitionMode=1 外送PCM模式等待onStart，不调用语音采集或feeding。普通活动字幕不被替换；pending start与in-flight stop也不被探测抢占。临时probe有独立身份，第二个probe不能把它当成已就绪的真实字幕。provider销毁只取消自身run，不清除新owner的事件handler；最终shutdown失败不返回ready。错误事件在start前订阅，方法失败和事件失败均可见。

这是**一次状态快照**，不是持续健康监测、已下载离线资源的永久承诺或手机识别效果测量。自动重试已关闭：原生失败立即成为AsyncError，不在后台反复开关识别服务；本机应在明确重试、回到前台需要重新判断时 `ref.invalidate(ohosStreamingAsrReadyProvider)`。不可在每次build无条件invalidate。首次失败还留有物理资源时，下一次明确探测/字幕start会经原生现有退休屏障重试，失败仍显式返回。

### 逐文件本机接线位置

本补丁不改受保护页面，也不改 `androidSystemFeaturesProvider`。下表是基底8fa的真实调用位置；本机同时保留 f021a246 的朗读放开改动。

| 本机文件／位置 | 当前条件 | OH 应接的条件与动作 |
| --- | --- | --- |
| `app/lib/ui/speech/voice_call_page.dart`，`_start()` | 提前取streamingAsrModelStoreProvider，再等models.installed()；null即无字幕 | OS=ohos分支不要取得模型store；检查系统ready，ready时用`const StreamingAsrModel.system()`创建LiveWords；busy/error显示字幕状态，通话本身继续；await后仍检查mounted与call.ended |
| `app/lib/ui/chat/chat_screen.dart`，`VoiceInputController(liveWords: ...)` | models.installed()决定是否构造dictation LiveWords | 仅OH改用系统ready+system模型；失败返回null并提示，不影响既有云端听写结果；保留mounted和会话归属检查。普通系统听写正占引擎时busy是正常互斥，不能偷走它 |
| 同一`chat_screen.dart`，`call: ref.read(androidSystemFeaturesProvider)` | OH通话入口隐藏 | 本机验收采集/播放后，只对OH通话能力放开该处；不要把全局androidSystemFeaturesProvider置true而误开其他Android专属能力 |
| `app/lib/ui/settings/voice_settings_page.dart`，speech总开关及`StreamingAsrModelCard.build` | speech由Android标记控制；字幕区watch下载model和controller，显示约198MB下载/删除 | OH字幕区watch系统ready，显示系统普通话、检查/失败/重试；不要调用模型download/delete，不伪造doneBytes或installed；Android分支保持现有页面 |
| `app/lib/ui/settings/search/settings_search_page.dart` 与 `app/lib/ui/settings/index/spots.dart` 的语音项目可见性 | 按androidFeatures/androidOnly过滤 | 本机只对已验收的朗读/通话/系统字幕条目扩展OH条件，其他条目沿用现状 |

`StreamingAsrModel.system()` 是后端选择标记，四个空文件字段不会被系统后端作为文件读取，也不表示安装了sherpa。给OH后端传文件模型会明确拒绝。OH分支无需取得 `StreamingAsrModelStore`，也不要复用针对旧sherpa模型的 `models.trial` 作为系统识别已经验证的凭据；未来若本机为系统字幕增加独立NativeTrial，应使用不同试验键。

创建 `LiveWords` 时接 `onFailure`，把错误显示为字幕不可用；`failure` 保留本次错误供查询。reason不是识别文本，字幕失败不取消正常的WAV通话。每个系统LiveWords仅允许一次start；重试创建新对象。显式stop可重试失败的物理关闭，并发stop合并；两个共享provider的LiveWords由独立ASR/PCM归属隔离，旧start/resume/feed/stop迟到不能操作新对象的run或tap。Android文件模型仍走原isolate/sherpa，原有错误传播不改。

入口、提示和前端视觉由本机完成；尚未接线与真机验收时，不能宣称用户已看到字幕。系统中文离线资源的地区、版本与首次启动表现仍以手机为准。

## 证据与未证实项

宿主测试执行真实 ETS 源体、实际 EntryAbility 注册与真实 Dart 数据代码；HMS 服务、麦克风、Flutter 原生端和时钟为明确的边界替身。虚拟时钟断言只证明调度状态机，不是设备时延测量。严格 TypeScript 使用非官方声明与受限宿主类型表，不等于 ArkTS/HMS SDK 编译。

本机应先核对 SDK 头中的 CreateEngineParams/StartParams/RecognitionListener；再测离线资源不足、非 CN 区域、系统识别被占用、首次 start 的延迟、短句/长句/isFinal/isLast/onComplete 顺序、前后台、取消创建、静音恢复、长通话轮转和队列过载。中文效果、首字时间、AEC 有效性、CPU/PSS、功耗均无本波手机测量结果。

公开主来源（2026-11-15 核对）：

- [speechRecognizer API](https://developer.huawei.com/consumer/en/doc/harmonyos-references/hms-ai-speechrecognizer/)
- [系统语音识别指南](https://developer.huawei.com/consumer/en/doc/doccenter-capabilities/speechrecognizer-guide/)
- 本仓库 Android 数据基线：app/lib/voice/streaming_asr.dart、streaming_pcm.dart、live_words.dart；1300/SPEECH-SELECTION.zh.md 与独立 ASR-PCM-CONTRACT-REVIEW。
