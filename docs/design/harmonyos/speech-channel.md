# dsh/speech 朗读通道

## 准入状态

本页记录 OH 方法通道与原生 PCM 后端的接线。**完整朗读仍为
`BLOCKED_SOURCE_BASELINE`，不能据此启用隐藏入口。** 真实 Dart 端仍需把原生
预检移到任何 `synthesize` 之前，并完成有背压、可取消的响应流。

产品基底为 `a836880`。协议只读参考固定公开提交
[`dd130b31061e305cd9c06e103c3e5210fee1922f`](https://github.com/ccch1mneyyy/dsh-Go/commit/dd130b31061e305cd9c06e103c3e5210fee1922f)，
不是切换产品基底。对应文件 SHA 在
`runtime/tests/ohos/speech-channel-contract.json`。本次不修改 Android、UI 或引擎
`speech.js`；原生后端见 [speech-pcm.md](speech-pcm.md)。通道补丁依赖该后端，
不能单独作为完整播放实现发布。

## 真实协议

`dsh/speech` 是双向 MethodChannel。原生用 `invokeMethod('event', map)` 回调，
没有另外的 EventChannel。

| 方法 | 参数 | 返回/完成 |
| --- | --- | --- |
| `open` | `id, rate=24000, call=false, levels=false` | 可播放预检成功且 owner 仍有效时 true，否则 false。 |
| `write` | `id, bytes: Uint8List` | 整块接收后返回应用队列字节数；失效返回 -1。 |
| `waiting` | `id` | 应用队列字节数/-1，不包含 renderer 内部缓冲。 |
| `end` | `id` | 返回 null；尾部完成以后另发 done。 |
| `stop` | 无参数 | 撤销当前 owner，加入物理关闭后返回 null；关闭失败为平台错误并保留句柄。 |
| `duck` | `id, on` | 调整当前流音量，返回 null。 |

PCM 为 raw PCM16LE、mono、24000 Hz。块可以在样本中间分割；后端负责拼接。
EOF 孤立奇数字节在 OH 明确失败。`write` 完成只表示入队，不表示已听到。

播放事件为 `{type:'play', what:'start'|'done'|'stopped'|'error', id}`。
预检本身不发 start；start 由后端首个实际数据提交路径触发。宿主测试并不证明
该时刻已在设备扬声器可听。尚未成功 open 时的预检失败发 error，不能先由
cleanup 发 stopped 导致 Dart 把失败当正常完成。用户在创建期间主动 stop 则为
stopped。每个 owner 至多一次终端事件。

当前主线 Dart 会吞掉 MissingPluginException/PlatformException；活动流错误
因此必须经既有 play/error 回调，不能只让一个平台方法抛错。当前 Dart 不消费
play/error 的额外 reason，通道没有发明新事件结构。

## 所有权和生命周期

EntryAbility 注册 SpeechPlugin，并转交 foreground/background/destroy。
每次 open 取得对象身份 request/owner，保存 engine、ability、channel。
异步创建和关闭完成后重新核这些身份与前台状态；迟到旧流回调不能指向复用 id
的新流。停止先使 owner 失效，再等待后端实际关闭。

全局 physicalOwner 独立于某个引擎注册的寿命。释放失败不能丢弃物理句柄；新的
引擎可用 stop 加入/重试旧资源关闭，关闭成功前不能创建新 renderer。终端事件
不等于资源已释放。旧插件退休时只关闭它拥有的流，不能误停之后的新插件。

`callStart` 返回 unavailable，不申请 MIC；callSpeaker 返回 false，其余尚无
资源的 call 方法返回 null。`open(call=true)`、`open(levels=true)` 和非 24000
Hz 在创建之前返回 false。主线 playLevel 每事件还表示约 40ms 已听进度，不能
先用任意频率/入队电平替代。语音通话模型是单独的设计工作。

## 仍未满足的 Dart 全链条件

固定参考中 `_queue → _prefetch → _start` 会先进入 synthesize；`_write` 收到第一
PCM 后才 open。Direct 路线不经过引擎 bridge。Bridge 路线的 `postJson` 又用
BytesBuilder 收完整响应；其 close 仅设布尔值，不能取消已经进行的传输。
因此只有新原生 open、或仅修改 bridge，都不能保证付费前可播放。

下一明确基底须为 OH 数据路径增加一次共享的原生预检与对象所有权协调，覆盖
pending create 的 stop；真实 HTTP 读流和容量等待均可取消。≤64 KiB 分片本身
不足以保证队列有界。唯一 writer 必须在实际 waiting 降至阈值后才继续写，
处理 -1，并取消未消费响应；旧 owner 的迟到 cleanup 不能发无 id 的全局 stop
误伤新流。全量/预取的 Dart 缓冲也必须受控，不能只测 native queue。

## 宿主门和范围

`speech-channel-linux.py` 在 pinned TypeScript 5.9.3 下运行实际 SpeechPlugin、
EntryAbility 与 PCM 后端方法体；Flutter、AudioRenderer、计时器为明确平台
边界。严格 TypeScript 检查使用测试声明，不是目标 ArkTS/SDK 编译。

`run-gates.py` 登记 `speech-channel-plain` 与 `speech-channel-jitless`。实际原生
后端另有 `pcm-stream-native` 门。两者都不包含完整 compose、HAP、真实 Dart、
设备听感或付费上游。三个 `design model only` 场景只验证提议的预检协调模型，
不能抵扣真实 Dart 集成门。

单独运行（out 须为未存在目录）：

```sh
python3 runtime/tests/ohos/speech-channel-linux.py \
  --node /absolute/path/to/pinned/node \
  --typescript-prefix /absolute/path/to/pinned/process-prefix \
  --mode jitless --out /absolute/new/output
```

新基底真实 Dart 需要额外证明：预检失败零 synthesize、stop 撤销在途请求、慢
消费者下大于 2 MiB 的合法流逐字节保持、所有缓冲有界、终端失败明确、Android
原行为保持。目标 SDK 与设备还必须核实际编码映射、格式、焦点、stop 及 EOF
可听尾部。这些条件完成之前整体继续阻断。
