# iOS 原生通道核对

Flutter 的 `MethodChannel` 能编译通过，即使 iOS 没有注册同名通道。2026-11-16 清点 `app/lib` 中直接声明的 46 条 `dsh/*` 通道：iOS 注册或显式提供空事件流的有 35 条。语音通话和普通消息朗读共用的 `dsh/speech` 已补齐；`test-channel-contract.py` 检查语音方法和 iOS 分发器一致，也要求新增的共享通道有 iOS 注册或在下表明确归类，避免再把缺少通道误报为麦克风故障。

其余 11 条没有同名 iOS 通道，按源码调用路径处理：

| 通道 | 当前 iOS 路径 | 后续工作 |
| --- | --- | --- |
| `dsh/attachment-files` | OHOS 专用附件接口 | 无需移植；iOS 走自己的文件入口 |
| `dsh/authorized-workspaces` | OHOS 手机文件夹授权（系统目录选择与持久授权）；Dart 侧尚未接入界面 | 无需移植；iOS 的工作目录授权走自己的路径 |
| `dsh/dynamic_color` | 缺失时退回预设配色 | 壁纸取色未实现 |
| `dsh/media_video` | 缺原生解码/纹理；页面明确说明不可在 App 内播放，并保留相册保存与外部打开 | **仍需实现 iOS 视频预览** |
| `dsh/paste` | 仅 OHOS（`PasteReader.ohos`）：系统粘贴按钮；其他平台用 Flutter 剪贴板 | 无需移植 |
| `dsh/phone/preview` | Android 后台预览流 | iOS 后台预览能力未对齐 |
| `dsh/picture_shortcut` | 缺失时返回“不支持” | iOS 快捷方式用另一入口 |
| `dsh/secrets` | iOS 使用 Keychain 的 FlutterSecureStorage | 无需移植 OHOS 密钥接口 |
| `dsh/streaming_asr` | 仅 OHOS（`operatingSystemProvider == 'ohos'`）：系统流式识别做实时字幕；iOS 走 `dsh/voice` 与模型 | 无需移植 |
| `dsh/update` | Android 应用内安装器 | iOS 更新入口需单独设计，不能复用 APK 安装 |
| `dsh/web-files` | 仅 Android WebView 显式连接此选择器 | 核对 iOS WebKit 文件上传实际行为 |

同名通道的**方法**也需核对：`dsh/media` 的 `saveVideoFile` 已补成 iOS 相册写入（编译和静态契约已验证，实际相册写入尚未做）；`dsh/voice` 的 `streamingPcm` 仍缺少 iOS 原生实时 PCM 帧（调用方捕获失败后回退到原来的识别方式）；`dsh/pet_overlay` 的 `configureCompanion` 和 `reloadPack` 在 iOS 宠物画中画中尚无对应处理，因此 iOS 设置不再提供网页伙伴悬浮渲染选择，控制器也不会启动该路线。App 内伙伴页面不受此限制。`dsh/notify/actions` 在 iOS 注册为空事件流，不属于缺失通道。

这个清单只证明通道注册与静态调用关系，不证明真实设备上的麦克风、播放、后台或 WebKit 行为。新增共享 UI 功能若调用原生通道，应核对 iOS 注册、每个方法的返回类型和真机路径。
