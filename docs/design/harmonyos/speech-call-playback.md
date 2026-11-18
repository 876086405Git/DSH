# 1302：通话 PCM 输出与播放电平

基底为8faafe6，旧speech-pcm.md记载1213历史范围；本文件说明本轮增量。此项只补播放后端和dsh/speech的open选项/事件，通话麦克风、callStart等控制在另件1303接入，不能把1302当作完整通话已可用。未在真机核实。

## 当前合同

|方法/事件|本轮行为及Android对照|
|---|---|
|open(id,rate,call,levels)|沿用24kHz/mono/PCM16LE，接受布尔call和levels；非24k或错误类型仍在创建renderer前false。call使用STREAM_USAGE_VOICE_COMMUNICATION，普通朗读保持AUDIOBOOK|
|open成功|真实创建、通信默认输出设置、格式核验、start完成及running确认后true，失败false+play:error；仍是已有Dart付费前准入点，不保证未来焦点或实际听感|
|write/waiting/end|原队列/背压/EOF协议不改，waiting是应用未提交字节数，不是已听字节数。自然done仍等平台drain和release|
|stop/duck|原停止/物理释放屏障与0.25/1.0音量不改；stop立即取消本轮新增的level任务|
|event type=playLevel|原Android形状{id,value}，每完整40ms有效PCM至多一次；value是有符号PCM RMS经(-50,-10)dBFS区间归一到0..1|
|播放位置|通过API19 getAudioTimestampInfoSync().framePos确认960个样本的末端已播放；不把writeData提交量或经过的墙钟时间当成已听进度|
|路由|call renderer在start前setDefaultOutputDevice，默认SPEAKER；内部setSpeaker可设置EARPIECE。API12只设置本流内置设备偏好，耳机优先、无听筒的设备仍可用扬声器，成功仅代表SDK接受参数|
|失效事件|收到outputDeviceChangeWithInfo且已有PCM提交时，终止当前levels播放为error，避免route重置后错误累加heard；观察到framePos回退也error。不存在计算未核实的frame偏移或静默继续|

参数和事件对照基底Android speech/PcmStream.kt、speech/SpeechPlugin.kt与Dart speech_audio.dart。基底_OhosDeepSeekOut每收到一个PlayLevel增加1920字节，VoiceCall打断时在stop之前读取heard；因此只在stop时补最后位置不能修复截断文本。尾部不足40ms和EOF补零不发额外tick，正常done由既有Dart将heard补至written。

## 异步与资源边界

writeData只做原有有界内存操作与每样本累加，任何timestamp、MethodChannel或AudioRenderer API都在其回调外执行。只在levels=true且有尚待确认的40ms片段时维持一个40ms定时器；普通朗读和没有待确认片段时不查硬件进度。level队列以已有2MiB等量PCM为上界。后台、换owner、stop、error与release都取消任务；旧stream的事件同时受真实对象身份和current守卫，不靠字符串id复用区分。

路由事件比相邻framePos比较多覆盖一个可达情况：重置发生在两次查询之间，新epoch又超过旧位置时，数值不再回退，但PCM映射仍已丢失。已知的设备切换直接退场，不将硬件新epoch当旧PCM的进展。首次尚未送PCM的路由选择可以继续。尚未获得播放第一帧时，SDK6800103允许等待；其他错误显式终止。原生release失败仍保留原物理lease，不能新建第二个播放器。

切换听筒/耳机会使正在播放的句子报错中止，这是本轮明确的体验限制；后续完整通话控制保留下一句的设备偏好。要无缝跨route继续，需要真机确认旧/新epoch实际已播的PCM边界，当前公开API证据不足以虚构这个偏移。callStart以及无renderer时的路由偏好回执由1303另行说明，1302未宣称已切全App输出。

## 频率与测量

当前官方中文AudioRenderer说明建议降低timestamp查询频率（通常间隔大于200ms）。现有Dart使用40ms tick决定打断文本，改成200ms会增加截断估计滞后。本件选择只在活跃且有待确认音频时40ms查询，并明确这是体验/功耗待真机权衡，未测CPU/PSS、电池或真实停止时延。即使硬件位置已更新，也不等于经过无线链路后耳边声学采样已到达；不能把宿主fixture写成声学证明。

## 验证

运行的针对性测试包含原先call/levels拒绝的真实基线红、进度不能用提交/墙钟冒充、边界960/1920、符号PCM、callback拼接、EOF补零、stop晚回调、route重置数值回退及无回退两种情况、真实SDK路由失败边界和普通朗读零新增查询。真实ETS方法体在显式AudioRenderer/Flutter边界中运行，strict TypeScript检查的是宿主声明，不能替代ArkTS/SDK。

门登记扩展已有pcm-stream-native为原回归与pcm-stream-call.test.mjs一起跑plain/jitless；speech-channel两模式新增真实SpeechPlugin+真实PCM组合事件测试。完整门依TASK留本机。本件未改Dart、Android、UI、Node/direct、生成文件或资产。

命令（在应用本件后的仓库根目录；TypeScript为已有测试锁5.9.3；Node 24.22.系列）：

```sh
python runtime/tests/ohos/pcm-stream-native.py --node /absolute/node --typescript-prefix /absolute/typescript-prefix --out /fresh/native
python runtime/tests/ohos/speech-channel-linux.py --node /absolute/node --typescript-prefix /absolute/typescript-prefix --mode plain --out /fresh/channel-plain
python runtime/tests/ohos/speech-channel-linux.py --node /absolute/node --typescript-prefix /absolute/typescript-prefix --mode jitless --out /fresh/channel-jitless
```

真实SDK与HBN-AL00验收应覆盖外放/听筒/耳机、边播边插拔、来电焦点、短尾与打断点、后台立即退休，分别对照硬件进度事件和实际发声；记录首帧/停止时延及CPU。这里没有那些测量数据或虚构通过记录。

官方来源（2026-11-15核阅）：

- AudioRenderer API（通信usage、setDefaultOutputDevice、route事件、时间戳与reset）：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-audio-audiorenderer/
- AudioTimestampInfo字段：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-audio-i/
- 路由与外接设备优先级：https://developer.huawei.com/consumer/en/doc/harmonyos-guides/audio-output-device-switcher/
