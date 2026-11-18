# OH 朗读 PCM 后端（1213）

本候选增加 `OhosPcmStream`，由 1214 的 `dsh/speech` MethodChannel 适配器调用。
接口来自固定参考 `dd130b31061e305cd9c06e103c3e5210fee1922f` 的 Android
`speech/PcmStream.kt`、`speech/SpeechPlugin.kt` 和 Dart `app/lib/speech/speech_audio.dart`。
产品补丁仍以 a836880 为基底；没有把新 main 的 Android 或 Dart 文件移植进来。

**整体朗读为 `BLOCKED_SOURCE_BASELINE`。** 固定参考中的 Dart 先 prefetch/synthesize，
首个 PCM 到达后才调用 `open`。仅增加此后端不能保证付费前可播放；必须在之后获准的新基底，
把真实合成调用接到成功预检之后。后端宿主通过不等于这条 Dart 链已接通。

## 能力和协议边界

| 项目 | 本候选行为 |
| --- | --- |
| 音频 | 24,000 Hz、单声道、PCM16 小端、RAW；其他 rate 在分配播放器前返回 false |
| 朗读 | `call=false, levels=false`；通话和按实际播放进度计时的电平回调均未实现，相关 open 返回 false |
| open | 实际 create、格式核验、事件注册、独立焦点模式、start、再次格式和 running 状态核验之后才返回 true |
| write | 完整接受一个 chunk，复制其字节后返回应用队列长度；旧流、结束后、故障后返回 -1 |
| waiting | 尚未交给 AudioRenderer 的应用队列字节数；不是已播放帧数，也不包含平台内部队列 |
| 队列上限 | 固定 2 MiB；无法完整接收时不接收该 chunk，终止并发出现有 play:error |
| end | 输入结束；偶数短尾补零填满最后一个平台 callback；奇数尾字节报 error；空流可 done |
| stop | 立即关闭数据准入，按状态请求 pause、flush，再 stop；等待在途操作和真实 release；失败保留物理占用 |
| duck | 按顺序设置 0.25 / 1.0 的流音量；系统强制 duck/unduck 由系统处理，不覆盖手动音量 |

单次 2 MiB 在该格式约为 43.7 秒。BridgeDeepSeekSpeech 可能一次交来整段 PCM，
所以不能宣称 Android 可接收的所有 chunk 都兼容。后续 Dart 接线应把输入分为不超过
64 KiB 的块并遵守既有 144,000 字节背压；那不是本补丁已执行的 Dart 修改。

`open=true` 证明的是该次预检已创建并启动指定格式的 AudioRenderer。它不证明之后不会
被系统抢焦点，不保证用户音量、外部设备或声学听感，也不保证之后每个 write/drain 都成功。
后来失去焦点、队列超限或平台失败必须通过原有终止事件让 Dart 停止剩余合成；不能仅抛出
会被 Dart `_invoke` 转成 null 的 PlatformException。

## 回调、EOF 和完成顺序

使用 API 12 起能返回 VALID/INVALID 的 `writeData`，不调用 API 11 已废弃的 `write()`。
平台消费 VALID 对应的整个缓冲区，因此输入暂时不足时返回 INVALID 且不移动队列。
每个输入 chunk 可以被多次 callback 部分消费，PCM 样本可跨奇数长度的传输 chunk。
只有 end 后的最后一块可以不足 callback 长度；其余字节显式清零，随后返回 VALID。

`writeData` 只处理有界内存和状态，不调用 AudioRenderer API、不发 MethodChannel 事件、不做 I/O，
也不保留平台传入的 ArrayBuffer。首次 payload 才安排 start 事件；预检空启动不报 start。
首个 start 已交付后，普通 VALID callback 不创建额外的控制 timer。没有应用级 PCM 轮询定时器。

最后 VALID 回调返回后，原生仍需把缓冲区入队。候选等下一次空 callback 再安排独立事件循环任务，
在回调外取消写入订阅并调用 drain；drain 成功且仍是当前流后，stop/release 完成才发 done。
这使 done 等待平台报告的缓冲耗尽，而非只等待应用队列为空；它尚未证明扬声器已播完尾音。
drain 失败报 error。正式启用前仍需通过后述目标设备完播验收。

官方 OpenHarmony 参考实现有两个相关顺序：

1. `napi_audio_renderer_write_data_callback.cpp` 的 `OnWriteData` 用 mutex 串行化回调，
   等 JS 回调返回再 `Enqueue`；
2. `renderer_in_client.cpp` 的 `WriteCallbackFunc` 先处理前次 `cbBufferQueue_`，再请求下次数据。

参考源码快照及 SHA 保存在交付物 `speech-native/api-source/sources.json`。
它们是 2026-11-14 读取的官方公开实现参考，**不是已经验证为用户设备 API 26 实现的二进制**。
宿主夹具刻意延迟最后一块提交，只有下一次 callback 才放行，验证候选没有过早调用 drain。
最终目标 SDK 与真机仍需验证服务行为、短句尾音、无数据回调、焦点和停止延迟。

## 生命周期和错误

每个对象只承担一次流生命周期；关闭后再次 open 返回 false。并发 open 受模块级物理 lease 保护，
跨 Flutter engine 的旧流 release 失败时，任何新流都不能悄悄获得第二个播放器。
失败资源保留在旧对象中，后续 stop 或新对象的退休重试可以重试 release；成功 release 只执行一次。
同一流最多发出一个 terminal，即使 release 重试、平台迟到回调或 listener 抛异常。

后台、换流、卸载由上层先撤销 current，再调用 stop。current 用来限制 start/write 准入；
terminal 不因 current=false 而在后端消失，上层根据仍关联的 engine 和 stream 对象过滤转发。
audioInterrupt 的 PAUSE/STOP/MUTE 终止朗读，RESUME 不自动重启；平台先发 PAUSED/STOPPED
状态再发中断也按 stopped 收尾，不重复 stop 已停止的 renderer。

stop 先禁止新数据，在已有 drain 尚未完成时也先请求 pause；确认暂停后 flush 丢弃旧尾部，再 stop，
最后等 drain/volume 操作结算和 release。官方客户端的 stop 在正常输出路径会先内部 drain，
所以用户打断不能只调用 stop。自然 done 不走 abort flush，避免丢掉仍应播放的尾音。
平台可以在内部串行化 drain/pause；宿主只证明请求和等待顺序，不宣称设备立即静音或某个固定停止时延。
原生调用若不结算，候选不会虚报已释放或让第二个播放器抢占 lease。stop 失败但 release 成功也报 error；
release 失败更不能清空 lease。没有用单纯 timeout、generation 或强制丢掉对象冒充原生释放。

## 宿主验证与未运行范围

正式门 `pcm-stream-native` 已登记在 `tooling/ohos/run-gates.py`，命令为：

```sh
python3 -I -B runtime/tests/ohos/pcm-stream-native.py \
  --node /absolute/path/to/node \
  --typescript-prefix /absolute/path/to/pinned-typescript-5.9.3-prefix \
  --out /absolute/path/to/fresh-output
```

执行真实 ETS 方法体，AudioRenderer、焦点事件和控制 timer 是显式边界夹具；plain 与 jitless 均执行。
另把三个 ETS 文件逐字节复制为 `.ts`，用 TypeScript 5.9.3 strict 对公开方法最小类型夹具检查。
这个检查**不是 ArkTS 编译，不是官方 SDK 类型检查**。报告记录每个输入 SHA、完整命令、原始日志、
模式计数和本次运行前后源码一致性。

未运行：用户实际 HarmonyOS SDK ArkTS 编译/HAP、真实 AudioRenderer 服务、手机声学播放、
Bluetooth/有线耳机切换、来电/其他 app 焦点抢占、真实 Dart 付费前预检、付费合成端到端。
本候选不改 Android、Dart UI、受保护 Node/direct runtime，也不启用语音通话。

官方低功耗指南明确 AUDIOBOOK 可使用较大的系统缓冲，且应用写完不等于实际播完。
本候选的下一次 callback 只是原生提交/处理路径屏障；内部 Write 错误不能仅由此屏障排除。
done 仍依赖平台 drain 的完成契约。公开 server 路径把 `stream_->Drain` 的
`OPERATION_DRAINED` 转成 `DRAIN_STREAM` 通知；其中 PA 回调先发该通知再保存 success，
HPAE 路径继续委托给下游 manager。已读链条不足以证明 sink/offload 的完整成功消费，
也不能据此断言用户目标设备必然截断。公开源码与目标设备实现尚未核同，完播/丢帧/无线延迟
不能由本宿主夹具定论；设备验收必须同时观察最后音频样本与终止事件，必要时结合
API19+的 getAudioTimestampInfo。getBufferSizeSync 是合理最小缓冲大小，不保证所有后续
callback 一样大；候选将 callback 硬限为 64 KiB，超过时明确 error，不假装支持该输出配置。

官方 API 主源：

- [AudioRenderer API](https://developer.huawei.com/consumer/en/doc/harmonyos-references/arkts-apis-audio-audiorenderer/)
- [AudioRenderer 数据回调规则](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/using-audiorenderer-for-playback/)
- [AudioRendererWriteDataCallback](https://developer.huawei.com/consumer/en/doc/harmonyos-references/arkts-apis-audio-t/)
- [AudioRendererOptions/Info](https://developer.huawei.com/consumer/en/doc/harmonyos-references/arkts-apis-audio-i/)
- [音频用途和焦点](https://developer.huawei.com/consumer/en/doc/best-practices/bpta-audio-focus-management/)
- [低功耗播放与实际播放进度](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/power-saving-for-playback/)
