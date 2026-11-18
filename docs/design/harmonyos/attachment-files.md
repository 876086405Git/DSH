# OH 附件与文本文件选择

`attachmentPickerProvider` 在 `Platform.operatingSystem == 'ohos'` 时使用
`OhosAttachmentPicker`。聊天附件和 SSH 私钥导入沿用各自现有的 provider 调用；
Android 和其它平台继续使用 `DeviceAttachmentPicker`。图片选择和拍照也保留原路径。

固定 `file_picker 13.1.0-ohos.2` 会把系统返回的 `file://docs/...` 交给 Dart
`Uri.toFilePath()`，带 authority 的 URI 不能这样读取。OH 分支通过
`dsh/attachment-files` 调用独立的 `AttachmentFilesPlugin`：

1. `DocumentViewPicker` 提供选择结果 URI。
2. ArkTS 使用公开 `fs.open(uri)` 读取授权内容，每次最多读取 256 KiB，逐项复制到
   应用 `cacheDir` 下由 `mkdtemp` 创建的独立目录。展示名不参与缓存路径构造。
3. 有序返回每项的 `name/path/size/problem`。成功项的 `size` 是实际复制字节数；
   失败项无路径。Dart 读取普通私有路径，继续执行已有的流式预算检查。
4. Dart 在 `finally` 中用本次 `owner` 调用 `release`，释放已读、被拒绝和未消费的
   缓存。release 失败不覆盖已读成功的数据或原始读取错误；native 记录不含路径或
   内容的清理诊断，残留仍须回收。原始文档 URI、文件内容和私钥内容不写入日志。

## 预算与失败

文件单件上限 200 MiB，附件总预算 400 MiB，最多 9 项。Dart 把托盘已有字节数和
剩余数量扣除后传给 native，所以连续选择不能每次重新得到 400 MiB。真实 PNG、
JPEG、GIF、WebP 前缀使用 20 MiB 图片上限；扩展名不决定这一限制。

文本导入默认 64 KiB，调用者传入的较小 `maxBytes` 同时约束复制和 Dart 读取。
空文本保留为空字符串，用户取消为 `null`；畸形 UTF-8 仍按原合同使用替换字符。
文本超过预算抛出原有 `FormatException`，读取失败不返回部分私钥。

metadata 只能用于提前拒绝，不能授权后续读取。未知、过期或变化的长度仍由实际
读取计数约束。短写按已写字节同时推进文件偏移和 buffer 切片。一个文件超限或
复制失败会删除它的部分缓存，保留后面的合法文件；Dart 保留选择顺序中的首个问题。
256 KiB 是复制块大小，不是进程 RSS 上限；Dart 的现有附件模型仍会保留附件 bytes。
这里不使用插件桥的 `dsh/native-files` 8 MiB 通道。

## 取消与生命周期

公开 `DocumentViewPicker` 没有可用的关闭操作。显式 `cancel` 在 Ability 仍有效时
保留 busy 槽，等物理选择器返回再清理；Ability/engine 退役则立即使当前请求失效、
解除其本地槽，允许新世代继续选择，不依赖旧系统选择器必定回调。这不表示系统
picker UI 已被关闭，也不表示在途 I/O 同步停止，实际设备行为仍待真机核实。

旧回包在打开 URI 前检查请求对象及 Ability 身份；在途复制每个异步读取/写入
边界检查失效标记，结束后只清理自己的批次。旧清理 completion 只在当前指针仍
指向该请求时解除槽。Dart owner 包含时间与进程内递增序号，每次消费生成新值；
迟到旧 owner release 和重复 release 不清新批次，协议仍是 List 返回值及 owner。

成功交付后保留 busy 槽，直到 Dart 读取结束并 `release`。清理失败保留路径所有权，
返回 `ohos_attachment_cleanup` 并记录无敏感内容的诊断；显式 release 可重试，
Ability/engine 退役也会重试并解除本地槽。Dart 保留成功数据或原读取异常，不把
清理失败当作读取成功。仍有清理失败残留时，不能声称文件已删。

每个进程首次附着时，在开放选择之前扫描 `cacheDir`，回收强杀留下的
`dsh-attachments-` 加六位字母数字目录，只处理其 0–8 数字文件；跳过符号链接
目录和含非本功能文件名的目录，不访问原始 URI 或其它分享缓存。同进程后续
附着复用初始化结果，不扫描尚在收束的活批次。回收失败记录诊断并继续提供
选择能力，残留可在下次进程启动重试；不保证进程被强杀后的即时删除。

## 验证入口

- `tooling/ohos/tests/attachment-files-channel.test.mjs` 用固定 SDK TypeScript 适配器
  执行生产 ETS，使用真实 Linux 文件测试预算、短读写、取消、部分失败及释放；系统
  picker、URI 授权和 Flutter channel 明确是 API 替身。
- `app/test/ohos/attachment_files_test.dart` 用真实 Dart 私有文件流验证两种消费路径、
  默认平台工厂和释放协议。这个目录仅包含非视觉测试，不加载产品字体。
- 原有 `attachment_file_budget_test.dart`、`private_key_file_budget_test.dart` 与相应
  owner/callback 生命周期测试继续验证既有 Device 入口和 UI 消费合同，断言不变。
- SDK 26 编译、真机授权 URI、系统取消/后台切换、文档提供者长度变化仍须分开记录。
  Linux 替身通过不等于设备选择器或 OH AOT 已验证。

`EntryAbility` 应注册 `AttachmentFilesPlugin`；不需要额外系统权限或把外部 URI
转换为公共磁盘路径。
