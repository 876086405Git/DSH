# `dsh/native-files`：系统选择及有界读取

本次收束基于 `530f183906be2a218b1b09000400e01c9a572dba`。两份文件通道产品模块保持已测 v2 原字节，补入最小 EntryAbility 注册和前后台接线；不依赖包 37 或 NativeHost。原 fd2890c、2c2e799 检查点及失败前像保持原字节。当前作者状态为 `CANDIDATE / WAITING_EXACT_ENTRY_ARKTS / NOT_RUN_DEVICE`。

## 协议与接线

协议的直接消费者是 `app/lib/plugins/native/native_file_platform.dart`；请求预算来自同目录 `native_effects.dart`，Android 对照实现为 `nativefiles/NativeFilesPlugin.kt` 和 `SelectedFileBudget.kt`。

| 方法 | 输入及行为 |
| --- | --- |
| `capabilities` | `{files: canIUse('SystemCapability.FileManagement.UserFileService')}`；不打开选择器或文件，不加载 Node。 |
| `pick` | 必须前台、有 `userGesture:true`；owner 必须为 32 位 `[A-Za-z0-9_-]`。普通请求 1–4 个文件，单文件最多 8 MiB，总计最多 16 MiB。仅应用自身的 `own:true` 请求可选 1 个、最多 30 MiB。 |
| `read` | 精确匹配当前 owner 与本次随机 handle；返回 1–65536 字节的 `Uint8Array`，EOF 返回 `null`。不接受本地路径作为权限。 |
| `cancel` | 匹配 owner 才取消；立即退休逻辑授权，异步等待真实系统操作结束后关闭资源。 |

本包 EntryAbility 已注册 `new NativeFilesPlugin()`，并从对应 UIAbility 的前后台回调调用 `NativeFilesPlugin.onForeground(this)` / `onBackground(this)`。无需新增权限或配置。只有前台可以发起选择；系统选择器本身可能使 Ability 暂时离开前台，因此单独 `onBackground` 不冒充 picker 已关闭，不取消一个仍在显示的系统面板。引擎/Ability 解绑和固定五分钟寿命均撤销逻辑授权。

`images:true` 用公开 `PhotoViewPicker` 的 `IMAGE_TYPE`；`visual:true` 用 `IMAGE_VIDEO_TYPE`；其他请求用 `DocumentViewPicker` 的 `FILE` 模式。缺少对应 SysCap 明确返回 unavailable，不悄悄换成更宽的选择范围。

## 文件权限与字节边界

选择结果只接受系统的 `file://docs/…` 和 `file://media/…`，拒绝任意绝对路径、本应用或其他应用 authority、网络地址、query/fragment、控制字符、反斜线、无效百分号编码、原始/解码后的点段和编码斜线，重复 URI 也拒绝。检查原始路径段，避免 URI parser 规范化后掩盖 `%2e%2e`。

公开媒体指南明确允许 `fileIo.openSync(uri, READ_ONLY)`，同时说明不要在 PhotoPicker 回调里直接打开文件，应该在界面返回后的另一操作中读取。因此 `pick` 只保存 URI、随机 handle、清理后的名称和扩展名推定的 MIME，`bytes:null`。Dart 明确支持未知长度。名称最多 128 个字符；MIME 是 UI 元数据，不是内容真实性断言。

首次独立 `read` 才使用公开异步 `fs.open(uri, READ_ONLY | NONBLOCK)`，随后通过实际 FD 的 `stat` 验证普通文件及已知大小。FIFO/目录拒绝，不读取任意文件系统路径。已打开 FD 保持到 EOF/取消/到期；不持久化授权，不复制文件到缓存。媒体指南的“另一次 UI 操作”与 Dart 的后续方法调用的具体设备时序仍需真机核实；本机测试不能证明系统 URI 授权。

预算按实际返回字节累计，跨全部 handle 计算。每次最多读 `min(64KiB, 单文件剩余+1, 总剩余+1)`；多出的一个字节仅用于检测虚报大小或增长，超限时整个选择失败并关闭，超限字节不交给 Dart。精确达上限仍会执行一次 1 字节 EOF 探测。OH `fs.read` 返回 0 是 EOF，因此返回 `null`，不会返回 Dart 不接受的空数组。

## 异步生命周期

模块级物理 lease 覆盖系统 picker、正在进行的 open/stat/read、以及所有未确认关闭的 FD。取消只退休逻辑 owner，不把“已回复 Flutter”当作面板关闭或 I/O 停止。旧 picker Promise 迟到时只释放自身物理状态；旧 engine 的 detach 不影响后来绑定的 engine。

每次仅一个 I/O 工作，无排队堆积。取消期间返回的 FD 会立即纳入关闭流程，读取结果在 owner 退休后丢弃。读操作结束前不会抢先 close FD，从而避免 FD 数字复用与异步 read 的竞态。关闭失败时保留实际引用及物理 lease；同 owner 可再次 cancel 重试，其他选择明确 busy。公开接口未提供已核实的取消任意 fs.read / DocumentViewPicker 能力；若系统操作不返回，本实现保持 busy，不伪报物理释放。

旧插件解绑后的恢复也有公共入口：新插件、新引擎或新 owner 的 pick 发现旧 lease 时，可以触发一次退休资源的实际 close 重试。仅当旧选择已经 inactive、picker 已结束、没有在途 I/O、原关闭尝试已经结束时才允许重试；当前这次 pick 仍明确 busy，物理清理完成后下次用户选择才能打开新面板。清理 Promise 本身绝不接着弹选择器，避免用户随后取消却遇到迟到面板。同引擎同 owner 的原显式 cancel 重试保持不变，不让 busy 查询额外插入一轮关闭并遮掉紧随其后的重试。

五分钟计时从接受 pick 起算，read 不续期。结果传输层抛错不会中断退休/关闭，也不会触发第二次方法回复。

## 可复现证据及限制

`runtime/tests/ohos/native-files-linux.py` 启动真实 Node 24.22.1，TypeScript 5.9.3 仅去除类型后执行原产品 ETS 方法体；真实 Linux FS 与 FD 处理包含短读、空文件、目录、FIFO、在途取消、close 失败与重试。Picker、URI 权限和 Flutter 生命周期是显式边界替身，不能据此声称手机功能通过。

作者实际记录：首轮 22/24，其中原始 URI 规范化检查遗漏为产品缺陷，FIFO 创建被沙箱拦截为测试环境问题；修订后 24/24。追加旧结果传输层异常反例复现 25/26，修复后 26/26。固定公开 `.d.ts` 检查两模块零 TypeScript 诊断。严格 ArkTS 编译、HAP、系统选择器权限及真机仍待根集成记录，作者不自行宣布 PASS。

本后继补充真实关闭失败反例：旧引擎 read 后仍持有 fd，detach 的 close 注入一次拒绝并注销 handler；恢复故障后，全新插件两次 pick 都 busy，FD 仍为 1。同插件重挂为可恢复控制。修复后原探针两场景均恢复至 FD0；第一轮广泛触发 cleanup 的候选造成原同 owner 重试测试失败（28/29），收窄为旧 owner 已不可直接调用的身份变化后，原 26 项加四项恢复门回归共 30/30，旧断言不改。保留所有失败前像。

严格 ArkTS 的两处 Map 显式注解及 `Error | NativeFileError` 形参也包含在本后继；它们与资源恢复是独立的类型修订。最终严格编译必须绑定集成 Entry 的精确产品字节，本文件的 TypeScript 测试不代替该门。

公开来源固定至 OpenHarmony docs `f41b9345badd47c7ab0c263344cd7f4b5a549afb`：

- [媒体选择与读取指南](https://raw.githubusercontent.com/openharmony/docs/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/media/medialibrary/photoAccessHelper-photoviewpicker.md)，SHA256 `6394f9f8e376acfbbdc1c8e072ade1f7e7dbb26f64fcea9a6a62aeea7cd8c37d`。
- [文档选择指南](https://raw.githubusercontent.com/openharmony/docs/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/file-management/select-user-file.md)，SHA256 `fb775f3c3c58ae89b20b9a54eb888a17f953e2a6b9b4b6aeeee413d0414a33e0`。
- [URI 说明](https://raw.githubusercontent.com/openharmony/docs/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/file-management/user-file-uri-intro.md)，实际来源 URL 和原字节另存交付的 `public-photo-source.json`；正文媒体 PhotoAsset 临时授权说明不替代上面的读取指南。

SDK 声明来自固定 `interface_sdk-js` 提交 `8a86234f0d542e5062e24e948652f5a484d90904` 的 `@ohos.file.fs`、`@ohos.file.picker`、`@ohos.file.photoAccessHelper`、`@ohos.file.fileuri`、`@ohos.uri`、`@ohos.util`、`@ohos.data.uniformTypeDescriptor`。产品未使用废弃 `PhotoAsset.getReadOnlyFd`，也未申请 READ_IMAGEVIDEO 或持久文件权限。


## 530 基底的收束边界

本包产品方法体与 `logs/arkts/integrated530-archive-life-hms-01` 的实际 44 源编译输入逐字相同；该组合的真实严格 ArkTS 结果为零错误。它包含其他通道的非官方 HMS 占位声明，不是本包独立 Entry 后像的编译记录，更不证明 HMS SDK 或设备功能。新主补丁和顺序增量的 Entry 后像各自记录摘要，需由集成者针对准确组合完成公开 SDK 严格编译；独立审查状态单独报告。

主补丁可直接应用于纯 530。`feature-only.diff` 是交付说明指定的已有生命周期组合上的顺序增量，与本功能主补丁二选一。性能的 `OhosDeviceFacts.ets` 和 `OhosThermalState.ets` 为共享辅助模块，Diagnostics 后继应复用相同字节。实际命令、公开来源原文、当前重跑日志及历史缺陷前像见交付包，不以作者检查点代替独立 PASS。
