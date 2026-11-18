# 鸿蒙聊天视频原生后端（1305）

本项以 `8faafe6` 为基底，补 `dsh/media_video`。实际消费者是 `app/lib/media/video.dart` 和 `app/lib/ui/chat/media/media_video_viewer.dart`；Android 合同来自 `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/media/MediaVideoPlugin.kt`。本项没有修改这些文件、UI、启动视频、Android 或原生文件授权实现。

## 通道合同与明确差异

| 方法 | 参数 | 结果与行为 |
| --- | --- | --- |
| `open` | `path` | 成功返回 `texture/width/height/durationMs` 四个数值；先退休旧播放器；最长 20 秒答复 |
| `poster` | `path` | JPEG 字节或 `null`；最长边 512、质量 80；已有物理任务未结束时返回 `null`；最长 10 秒答复 |
| `play` | `texture` | 前台才启动；成功为 `null`；音量 1、非循环 |
| `pause` | `texture` | 暂停当前播放；重复暂停为 `null` |
| `seek` | `texture/positionMs` | 毫秒截断并夹到 `[0,durationMs]`；结果 `null` 表示提交，实际位置仍由 `state` 查询 |
| `state` | `texture` | `positionMs/durationMs/playing`，读取 SDK 实际状态 |
| `close` | `texture` | 已知资源完成物理退休后为 `null`；未知纹理也返回 `null` |

不增加原生推送事件。未知方法和未知纹理的处理顺序与 Android 一致：不存在已准备的纹理先报 `closed`；存在时才 `notImplemented`。

错误保留既有 `invalid/unsupported/timeout/closed/background/playback` 命名空间。公开 AVPlayer `play()` 错误表没有能唯一证明“焦点被拒绝”的错误码；因此本项不能声称已实现 Android 的 `audio_focus` 专属分类。SDK 播放失败按已知 `playback` 返回；实际焦点中断触发暂停。`5400107` 的官方描述是焦点冲突导致**录制**失败，不能据此把普通播放错误映射为焦点拒绝。

Android 使用 `SEEK_CLOSEST_SYNC`；OH AVPlayer 没有该枚举。本项使用 API 12 的 `SeekMode.SEEK_CLOSEST`（最近帧），这是明确的语义差异。不会伪造精准跳转、同一关键帧或提交后立即到位；测试也保持请求位置与 SDK 实际位置不同。

## 文件权限与资源所有权

仅沿用现有 FilesMedia 的已物化文件根：应用 workspace、application cache/temp、当前 Ability cache/temp。没有开放整个 `filesDir`，没有扩大 LaunchClip 的目录权限，没有新增 `READ_MEDIA/WRITE_MEDIA`。路径先做格式和根检查，再经现有 lazy `loadNativeHost().openUserFile(root, relative)` 安全打开；该原生 helper 对逐段路径、符号链接和常规文件执行实际检查。

播放器先安全验证新 FD，成功后才退休旧视频；不存在或被原生拒绝的文件不会中断当前播放。最多保留一个播放 owner 和一个待验证/切换 FD，取消后的待验证 FD 退出前不再打开第三个 FD。播放器创建、prepare、控制操作与 release 的迟到完成都绑定该资源代际；旧资源成功退休前新播放器不能超车。纹理在 AVPlayer 和 FD 都成功退出后注销。release 或 FD close 失败时保留句柄，后续 `close/open` 可以重试。准备超时只终结 Dart 回包，不能把仍供 SDK 使用的 FD 或纹理提前关闭；若 SDK 永不结算，此后打开会继续在自己的截止时限内报超时，物理占用仍有上界，不能伪称已经释放。

缩略图与播放是独立资源，各最多一个物理 owner。先用 AVMetadataExtractor 获得宽高，并成功 release extractor 后才把同一个 FD 交给 AVImageGenerator。按 `min(1,512/max(w,h))` 计算合法 `PixelMapParams.width/height`，检查返回 PixelMap 实际大小，再调用 `ImagePacker.packToData`。超时或销毁时等待正在执行的操作结算；packer 和 PixelMap 在编码结束之后释放，媒体服务释放成功后才关 FD。退休失败保留原 owner；下一次缩略图请求先尝试回收，失败返回 `null`，不会另开解码器。

前后台和 engine/Ability 生命周期由实际 EntryAbility 接入。失去前台、收到 PAUSE/STOP/DUCK（含 FORCE/SHARE）都调用真正的 `pause()`，即使 SDK 中断后状态仍是 playing。重新前台、RESUME 或 UNDUCK 不自动续播，和现有 Android 行为保持一致。迟到 `play()` 必须再次核对前台与播放意图。

## 官方 API 核实

以下仅是公开声明核对，不是 HarmonyOS SDK 编译或真机结果：

- [AVPlayer](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-media-avplayer/)：`createAVPlayer`、fdSrc、surfaceId、prepare/play/pause/release、`seek(timeMs, mode)`、`stateChange/error/audioInterrupt`；audioRendererInfo 在 initialized 设置，audioInterruptMode 在准备完成后、播放前设置。
- [Media 枚举](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-media-e/)：`SeekMode.SEEK_CLOSEST` 从 API 12 提供；AVImageQueryOptions 有 `AV_IMAGE_QUERY_CLOSEST_SYNC`，不能把它混入 AVPlayer SeekMode。
- [AVMetadataExtractor](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-media-avmetadataextractor/)（API 11）与 [AVImageGenerator](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-media-avimagegenerator/)（API 12）：元数据与首帧提取、Promise release；同一 fd 不同时归多个媒体服务使用。
- [Media 类型](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-media-i/)：`PixelMapParams.width/height` 必须正数且不大于源尺寸，SDK 不保证超界参数会缩放。
- [ImagePacker](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-image-imagepacker/)：API 13 `packToData(PixelMap, PackingOption)` 与 Promise release。旧 `packing` 在 API 13 废弃，本项不用它。
- [Audio 类型](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-audio-i/) 和 [枚举](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-audio-e/)：InterruptEvent 的 eventType/forceType/hintType、INDEPENDENT_MODE、MOVIE usage。
- [音频焦点实践](https://developer.huawei.com/consumer/en/doc/best-practices/bpta-audio-focus-management/)：强制中断后应用仍应主动 pause；[Media 错误码](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/errorcode-media/) 不足以证明 AVPlayer `5400107` 为焦点拒绝。

本项所用公开接口的最高最低级别为 API 13（ImagePacker.packToData），目标 API 26 是否通过实际 SDK 编译仍待本机核验。Flutter 纹理桥已按下节的固定官方发布源码确认；宿主检查不能证明真实纹理合成效果。

## 固定 oh-flutter 纹理桥源码

已实际下载工程 `check-arkts.sh` 指定的 [3.47.9-ohos-1.0.0 release ZIP](https://atomgit.com/oh-flutter/flutter_flutter/releases/download/3.47.9-ohos-1.0.0/ohos-arm64-release-artifacts.zip)，15,485,641 字节，SHA256 `20903e3b9197004b0181e3a2acc9243d04e5b10fa63d19453969dfc97dc87e42`；内部 `flutter_embedding_release.har` 294,449 字节，SHA256 `b46e5e370827ef0b80b0d25b219e902680a4a0620c6a75fa6b3cef95a36ff15a`。两项均与仓库既定 pins 完全一致。固定提交记录为 `e5f752df3e25ec897da3c98a74bcced7c21b0bd3`，不把整个 HAR 与该 Git 树逐字等同；本项直接读取实际构建所用的发布 HAR。

| 实际源码 | SHA256 |
| --- | --- |
| `view/TextureRegistry.ets` | `7beb00448c6b72732c234c662bde8ee893eb1bcdc6875f5333edfbd379e1401a` |
| `embedding/engine/renderer/FlutterRenderer.ets` | `223a3177c3dc07115c4aa87ebe4261bc86291192588da2fe64d43e0f481b8098` |
| `embedding/engine/FlutterNapi.ets` | `c128c96dcd0cd8f640ab6c600c6d740a6b584b3d51b5394fba32f6d0945b2d59` |
| `embedding/engine/plugins/FlutterPlugin.ets` | `682e842ce926e5ceabfeaf62eb380ecded11a4b2b4898705c1d4ab2b3a037614` |
| `embedding/engine/FlutterEngine.ets` | `d75dbfb418415fc379f8dac1e352ee4e37fc7005a127c910f5343e95784150ae` |
| `embedding/engine/FlutterEngineConnectionRegistry.ets` | `aa0df1a500039ee8df627df9fdd78399f6795367e8db7a6ed088e0a5ea7a0ed8` |

表内路径均相对于发布包 `package/src/main/ets/`。`index.ets` 对外导出 TextureRegistry/SurfaceTextureEntry；真实 `FlutterPluginBinding.getTextureRegistry()` 返回该接口。真实 renderer 的 `getTextureId(): number` 分配全局递增 ID；`registerTexture(id): SurfaceTextureEntry` 调 native 注册并保存其数值 surfaceId；`getSurfaceId(): number` 原样返回该数值，媒体插件转字符串后给 AVPlayer；`setTextureBufferSize(id,width,height): void` 与 `unregisterTexture(id): void` 都委托同一个 renderer 的 N-API。旧 `createSurfaceTexture` 已弃用，`SurfaceTextureRegistryEntry.release()` 实际抛出未实现错误，因此本项不用这两条路径。

生命周期也按真实实现核对：binding 只可在同步 detach 返回前引用，本项在 detach 内清除 binding/入口；已捕获的旧 renderer 仅用于退休其自己的纹理，不重新取 binding 或触碰新 engine。engine destroy 在通知插件后释放 native holder；真实 N-API 对已销毁 holder 的 unregister 会直接返回。故正常关闭时测试证明的是调用顺序“AVPlayer release → FD close → 原 renderer unregister”；engine 本身销毁时纹理由 engine 负责回收，不能将 void 返回当作底层图形资源已完成物理释放的证明。

最终夹具直接执行上述完整 FlutterRenderer 源体，且固定两份接口/renderer SHA；只替换 FlutterNapi 系统边界。runner 必须提供已钉 SHA 的 HAR，保留其身份与完整相关文件的输入前后 SHA。发布包与原许可在交付证据 `EMBEDDING/`，不向产品添加依赖。

## 可复现验证及边界

`runtime/tests/ohos/media-video-linux.py` 编译现有 C++ `openUserFile` Linux N-API helper，运行完整产品 ETS/Entry 和固定发布 FlutterRenderer 方法体，保存命令、输入前后 SHA、严格 TypeScript 输出和 TAP。显式替换的边界为 AVPlayer/Extractor/Generator/ImagePacker、音频系统及 FlutterNapi；不把合成的 JPEG 回包当作真实编码证据。

基底原 Entry 确实缺少 `dsh/media_video`，同一测试报 `CHAT_VIDEO_CHANNEL_MISSING`。20 项用例在普通与 JITless 模式验证七方法、目录授权、无效文件不退旧视频、待验证 FD 上界、迟到创建/prepare/play、后台/焦点、释放失败重试、两种缩略图超时和资源上界。严格 TypeScript 使用明示的宿主声明，不能替代 ArkTS SDK。

本机还应执行：实际 SDK 编译；常用编码/旋转/长视频的画面尺寸和首帧；纹理关闭后重开；来电及其它播放源抢焦点；后台和 engine 重建；seek 实际落点；格式错误/损坏视频；视频列表快速滚动的缩略图与 FD/内存上界；设备媒体服务异常的恢复。完整统一门与设备测量由主线记录，不从本项宿主结果推定。
