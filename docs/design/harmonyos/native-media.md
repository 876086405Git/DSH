# 鸿蒙插件媒体通道：音频阶段

本次收束基于 `530f183906be2a218b1b09000400e01c9a572dba`。三个音频产品模块保持已测 v2 原字节；主补丁包含统一懒加载包 37 的完整原始补丁和最小 EntryAbility 注册、前后台接线。已安装 37 或已有生命周期组合时，使用交付说明指定的增量，不能重复叠加主补丁。当前作者状态为 `CANDIDATE / WAITING_EXACT_ENTRY_ARKTS / NOT_RUN_DEVICE`。没有新增权限或 Android 修改。

## 实际调用方与范围

`app/lib/plugins/native/native_platform.dart` 使用 `dsh/native-media` 与 `dsh/native-media/events`。`native_capabilities.dart` 先订阅事件，再带 `{owner, generation, lease}` 激活所有者；音频由 Dart 下载到 `getTemporaryDirectory()/native-media/<owner>/clip`，然后传入 `privatePath` 与 `contentType`。停止调用成功或终态事件会允许 Dart 删除缓存、结束该角色。因此，原生通道只有在播放器释放、文件描述符关闭后才能报告停止或结束。

当前仅在公开 `SystemCapability.Multimedia.Media.AVPlayer` 可用时广告 `audio`。`voice` 与 `overlay` 暂不广告，相应方法明确返回 `unsupported`：它们还缺少可见的原生停止指示、原生字幕窗口及与 `dsh/voice` 共用的麦克风实际释放仲裁。现有 Dart 会据 `features` 过滤能力。本阶段不把语音转录当作语音活动检测，不假定两个通道各自的麦克风锁可以互斥。

| 方法 | 行为 |
|---|---|
| `capabilities` | 返回 `{features:['audio']}` 或空列表；不创建播放器，不调用安全 opener，不加载 Node |
| `activate` | 校验前台 UIAbility、已订阅事件流及所有者三元组；旧播放器实际关闭后再次核对 binding、Ability、sink 和前台状态 |
| `play` | 仅当前所有者固定缓存片段；用安全 fd、有限长度设置 AVPlayer，不向播放器交路径或 URL |
| `pause` / `resume` | 已初始化片段按 AVPlayer 状态暂停/恢复；初始化期间的暂停意图保留到 prepare 完成后 |
| `stop` | 立即取消迟到状态转换，等待在途创建/prepare/API 操作，释放播放器后关闭 fd；失败保留资源供重试 |
| `disposeOwner` | 对指定当前所有者执行相同物理关闭；已经没有该所有者时幂等返回 |
| `requestVoiceGrant` / `startVoice` / `stopVoice` | 本阶段 `unsupported` |
| `showOverlay` / `updateOverlay` / `hideOverlay` | 本阶段 `unsupported` |

后台、Ability 解绑、引擎解绑、事件流替换/取消均先使所有者失效。异步结果必须仍属于原 binding、Ability、事件 sink 及音频世代，才可以继续操作或发事件。播放器使用模块级物理租约；引擎或插件对象替换不会提前腾出尚未真正释放的资源。

## 缓存根的证据与文件边界

固定依赖为 `app/ohos/pubspec_overrides.ohos.yaml` 指定的 `path_provider` tag `2.1.6-ohos.2`。已只读取得该 tag，指向 commit `3905829ce2fe2cd51e8439512b3db7993521c371`；其 `PathProviderPlugin.ets` SHA256 为 `2f83e9198c035b9b3c9a1947fd759296e7445dc82d75d22065a2b99f8a74023d`。源码中 `onAttachedToAbility` 把 context 换为 `binding.getAbility().context`，`getTemporaryDirectory` 返回这个 context 的 `cacheDir`。因此本通道在激活时保存同一 UIAbility 的 context，不用 ApplicationContext 的目录作替代，也不扩大允许根去兼容一个未经核实的目录。

固定路径严格为 `<UIAbility.context.cacheDir>/native-media/<owner>/clip`。所有者为 16–64 位小写十六进制（当前 Dart 生成 48 位），世代为非负 32 位整数，lease 为最多 256 字符且无控制字符。只接受调用方列出的五种音频 MIME。路径检查通过后，注入的 opener 调用已有 `openUserFile(root, relative)`；该 C++ helper 逐层 `openat` 与 `O_NOFOLLOW`，末端要求普通文件，拒绝父目录/文件符号链接及 FIFO 等特殊文件。

在实际 fd 上 `stat`，要求 1 字节至 16 MiB。传给 AVPlayer 的 `fdSrc` 为 `{fd, offset:0, length:已检查大小}`，限制可读取的范围。后续替换同名路径不会改变已打开 fd 的 inode；文件在交付后继续增长也不会扩大 `length`。这并不宣称同 UID 可以任意原地改写数据时仍能保证音频内容不可变；现有 Dart 协议只在播放前写完片段，之后等待终态才删除。

公开 SDK 来源：`openharmony/interface_sdk-js` commit `8a86234f0d542e5062e24e948652f5a484d90904` 的 `api/@ohos.multimedia.media.d.ts`、`@ohos.multimedia.audio.d.ts`、`@ohos.file.fs.d.ts`。AVPlayer 的 `fdSrc`、`audioRendererInfo`、`audioInterruptMode` 与状态约束均按这些声明核对；在 `initialized` 设置 `STREAM_USAGE_VOICE_MESSAGE` 后 `prepare`，在准备完成后设置 `INDEPENDENT_MODE`。音频中断的 pause/stop/mute 提示触发实际关闭，不擅自自动恢复。

## 集成入口与懒加载

EntryAbility 注册时传入异步 opener，导入只发生在播放确实需要 fd 时：

```ts
new NativeMediaPlugin(async (root: string, relative: string): Promise<number> => {
  const host = await loadNativeHost();
  return host.openUserFile(root, relative);
})
```

EntryAbility 的对应生命周期调用 `NativeMediaPlugin.onForeground(this)` / `onBackground(this)`。本补丁三个模块没有顶层 `libdsh_host.so` 导入。`loadNativeHost` 的实际导出形状以集成包为准；不要另加一个绕过统一懒加载门的缓存或动态库入口。

## 已执行的验证与边界

`runtime/tests/ohos/native-media-linux.py` 使用 Clang 18 和固定官方 Node 24.22.1 头文件重编译基底的 `user-file-access-addon.cc`，实际调用产品 `file_access.h`。测试读取真实文件、fd、替换路径、关闭及回收；AVPlayer、Flutter 事件边界为显式状态替身，不解码音频，也不产生声音。

作者的 27 项验证覆盖正常播放/暂停/恢复/终态、路径与 MIME 拒绝、真实安全 fd 与大小限制、路径替换后的 fd 身份、opener/create/prepare 在途停止、释放失败重试、晚到回调、跨引擎租约、后台/解绑/事件取消、替换播放与 stop 交错，以及固定 path_provider 的实际方法体和不同 ApplicationContext/UIAbility 缓存目录的联合消费。

保留了一个真实先失败的异步窗口：旧实现等待旧播放器释放后，没有再次检查 EventSink 身份；此时 Dart 已取消事件流，新所有者仍可激活。原 22 项中该项失败；修复后捕获并重检同一个 sink，23 项通过。旧失败日志与源码后像在交付的 `evidence/before-sink-cancel/`，不覆盖原证据。

独立复核随后发现跨实例恢复缺口：旧引擎解绑时 release 或 fs.close 拒绝，旧通道注销后，新插件连续 play 都 busy，原 fd 保持打开；原测试只覆盖能再次调用旧 owner 的重试。v2 保留公共物理租约为恢复入口：新播放器只对已停止/退休的旧租约等待原关闭尝试结束，然后再次真正关闭。失败仍返回 busy 并保留租约，成功后才竞争新租约；正在播放的旧 owner 不可被抢占。两个新实例同时恢复时至多一个取得租约，等待期间取消则不会打开新 fd 或创建播放器。

原独立六场景探针未修改，旧冻结包四场景通过、全新插件的两场景失败；v2 六场景均通过。新增四项回归后共 27 项通过。此结论来自真实 Linux fd 与注入的公开 API 失败，不声称已在设备上制造过 release 失败。旧补丁 SHA256 `b13af4ec191eacb8ea46e310dff8f4b9aa0c6c16d442f85ae7ccf056edf5e13d` 及其原报告保持不变。

公开 OH 声明与固定 Flutter 最小公开签名的 TypeScript 语义检查为三模块零诊断，不能替代 `check-arkts.sh`。最终集成仍必须以同一产品字节运行严格 ArkTS、核 Entry 生命周期挂钩和懒加载边界。设备清单包括实际 codec 支持、`fdSrc` 有限范围、音频焦点/中断、后台停止、真实 release 延迟、缓存清理及页面/引擎重挂。现在均为 `NOT_RUN_DEVICE`。

## 可复现命令

在打完补丁的仓库根目录，使用实际工具目录参数：

```sh
python3 runtime/tests/ohos/native-media-linux.py \
  --node /path/to/node-v24.22.1/bin/node \
  --node-headers /path/to/node-v24.22.1/include/node \
  --typescript-prefix /path/to/installed/typescript-5.9.3-prefix \
  --path-provider-source /path/to/fixed/PathProviderPlugin.ets \
  --out /path/to/evidence/native-media
```

PathProvider 测试输入在交付包中按原字节保存，并带上该项目的 BSD 许可；它仅用于验证实际调用方路径，不复制进产品。完整命令、工具/源码 SHA256、先失败后通过日志和公开声明检查脚本在交付包中。


## 530 基底的收束边界

本包产品方法体与 `logs/arkts/integrated530-archive-life-hms-01` 的实际 44 源编译输入逐字相同；该组合的真实严格 ArkTS 结果为零错误。它包含其他通道的非官方 HMS 占位声明，不是本包独立 Entry 后像的编译记录，更不证明 HMS SDK 或设备功能。新主补丁和顺序增量的 Entry 后像各自记录摘要，需由集成者针对准确组合完成公开 SDK 严格编译；独立审查状态单独报告。

主补丁可直接应用于纯 530。`feature-only.diff` 是交付说明指定的已有生命周期组合上的顺序增量，与本功能主补丁二选一。性能的 `OhosDeviceFacts.ets` 和 `OhosThermalState.ets` 为共享辅助模块，Diagnostics 后继应复用相同字节。实际命令、公开来源原文、当前重跑日志及历史缺陷前像见交付包，不以作者检查点代替独立 PASS。
