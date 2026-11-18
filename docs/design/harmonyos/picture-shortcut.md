# 1307 图片桌面快捷方式：鸿蒙后端与待本机接线

## 范围与当前结论

补丁基于 `8faafe6`，只增加鸿蒙原生后端、最小非官方 HMS 声明及定向测试。`dsh/picture_shortcut` 的实际 Dart consumer、Android、UI、模型及应用权限清单均保持原样。当前源码仍由 Android 条件隐藏入口，因此本项不能写成“鸿蒙用户已经可见”。本轮没有正式 HarmonyOS SDK / HAP 编译或手机 AppGallery 测量，状态为 `UNCOMPILED_HMS`。

宿主测试执行实际 `EntryAbility`、插件和工作流 ETS 方法体，并使用真实 Linux 文件读写。ImageKit 编解码、AppGallery 的系统交互和 Flutter messenger 是明确替身；它们证明参数、资源所有权、取消边界和事件合同，不证明手机显示效果、服务授权或系统确认框。

## 既有合同

权威源是 `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/icons/PictureShortcutPlugin.kt` 和 `app/lib/state/icon_shortcut_state.dart`。

| 项目 | 保持的行为 |
|---|---|
| 通道 / 方法 | `dsh/picture_shortcut` / `pin`；其他方法 `notImplemented` |
| 参数 | `label` 字符串及 `png` 字节数组；零长、缺失或超过 2 MiB 返回 `invalid` / `no picture` |
| 名称 | 合并空白、trim、空白回退 `DSH Go`，最多 24 个 Unicode 码点 |
| 不支持 | `{supported:false, requested:false}`；Dart 为 `PinRequest.unsupported` |
| 校验、系统拒绝、取消或运行错误 | `{supported:true, requested:false}`；Dart 为 `PinRequest.failed` |
| 成功 | `{supported:true, requested:true}`；Dart 为 `PinRequest.asked` |
| 确认事件 | `pinned`、参数 null，只有系统添加结果成功时发送；仅提交请求绝不发送 |
| 点击桌面图标 | 仅打开本应用的 `EntryAbility`；没有新会话、语音、执行或网络参数 |

Android 的 `requested:true` 表示系统接受请求，后续确认另有回调。AppGallery 的 Promise 按官方流程在用户决策并处理后返回结果，因此鸿蒙这里等该结果再返回 true，并紧接着发送既有 `pinned`。现有 Dart consumer 能接收这一顺序；不增加新枚举，不把取消转换成成功。现有 UI 对 `failed` 显示失败提示，若本机希望取消不提示，需要自行设计可区别的 UI/协议，本补丁没有改变此合同。

## 官方 API 证据

以下是官方文档核对，不是从宿主声明反推 SDK。查证日期为 2026-11-15。

1. [productViewManager API](https://developer.huawei.com/consumer/en/doc/harmonyos-references/store-productviewmanager/)：公共入口为 `@kit.AppGalleryKit` 的 `productViewManager`。自定义资源版 `checkPinShortcutPermitted` 接受 UIAbilityContext、ID、Want、label、前景文件路径及空背景字段，返回校验结果；`requestNewPinShortcut` 接受 context 和 tid。两者从 API 14 / 5.0.2 起提供，Stage 模型，SysCap 为 `SystemCapability.AppGalleryService.Distribution.Recommendations`。Phone 在当前设备表中受支持。
2. 同一 API 页的自定义资源约束：ID 最长 63 字节，label 最长 255 字符，前景图标必须是沙箱中的 PNG 或 WebP，最多 100 KB；背景字段预留为空。`CheckShortcutResult.code` 为 0 才通过；tid 可缺省，expired 是剩余毫秒。后端拒绝非零 code、空 tid、非正或非有限 expired。
3. [添加快捷方式流程](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/appgallery-productview-addshortcut/)：系统展示确认，用户同意后处理，再返回添加结果；成功后 tid 失效。该能力不能用 Emulator 验证。本补丁每次真实点击都生成新 ID 并重新校验，不缓存授权 tid。文档建议提前校验以缩短点击延迟；既有 Flutter 合同仅在最终 PNG 生成后调用一次 pin，故本补丁在这次点击内顺序校验及提交，不增加启动时请求。
4. [官方错误码](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V14/store-error-code-V14/) 与 [当前错误说明](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/errorcode-appgallery/)：`1006620007` 是用户拒绝；旧版官方说明明确包括点击 Cancel。过期、数量上限、校验失败和服务失败也分别保留未成功结果，没有改成 `pinned`。
5. [参数错误 FAQ](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/appgallery-faq-32/)：不能为其他应用加桌；路径不存在、无权读取、格式及大小不符会失败。本补丁使用实际 UIAbilityContext 的 bundle/module/ability，只读写自己的 filesDir，不请求图库权限。
6. [查询已固定快捷方式](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/appgallery-productview-getshortcut)：API 24 起可查询当前应用所有桌面快捷方式；后端只使用 ID 判断自己保留的图标是否已不再对应桌面条目。查询失败不等于列表为空。
7. [AppGallery API 24 差异](https://developer.huawei.com/consumer/cn/doc/harmonyos-releases/js-apidiff-appgallerykit-6111/) 和 [自定义图标接口差异](https://developer.huawei.com/consumer/cn/doc/harmonyos-releases/js-apidiff-storekit-b123sp18/) 给出了内部声明文件 `@hms.core.appgalleryservice.productViewManager.d.ts`。这支持最小 stub 的模块定位；stub 本身仍不是正式 SDK。
8. [ImageKit API 14 文档](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V14/js-apis-image-V14/)：`ImageSource` 可从 ArrayBuffer 建立；PixelMap 支持指定解码尺寸；API 13 起 `ImagePacker.packToData` 支持 PNG，并有 release API。编码及像素是否按手机实现生效仍须本机测量。

文档里自定义资源示例采用动态 ID，但同段还写 Want 应匹配 wants。该句是否也要求一项静态 shortcuts 配置，在公开示例中没有完全解释。本补丁按 API 自定义资源重载提供自有 EntryAbility 的普通 Want，没有复制 new_chat / voice_input 的副作用参数，也没有新增静态长按项目。本机必须用最终签名 HAP 验证这一 Want 被服务接受；若服务拒绝，当前合同会诚实返回 failed，不能将宿主成功解释为已通过该校验。

## 图像与文件所有权

现有 Dart 输出 432 × 432 PNG，其中包含 Android adaptive icon 的外围延伸区域。后端保留整个图像布局和透明度，不擅自改变 UI 裁剪。PNG 超过 AppGallery 限制时最多尝试 432、256、128 三个最长边，等比缩小，PNG 无损编码；每轮确实校验返回尺寸，最终字节数须为 1～100000。降低分辨率可能影响大倍率清晰度，手机桌面的 mask / padding 仍须比对实机，不能把 Android 的可见中间区域规则当成鸿蒙已证实规则。

输入仍受 2 MiB 合同限制，另拒绝非正、非整数或超过 16 Mi 像素的元数据；既有 432 像素生产者不触及此防止异常大图解码的上限。每次只有一组 ImageSource / PixelMap / Packer 所有权，前一轮 PixelMap 释放后才进入下一轮。编解码释放失败会保留句柄，停止进入系统确认；下次用户点击先重试退休，不能堆积第二组资源。写文件使用私有新建目录及 NOFOLLOW，完整处理部分写入，零进展立即失败，fsync 和 close 完成后才给 AppGallery 路径。

官方材料没有明确保证添加成功时系统已经复制了图标。因此成功后图标保存在 `filesDir/picture-shortcuts/<时间戳>-<随机ID>/icon.png`，不会在 Promise 返回时删除。最多保留 16 个本项目录，每张最多 100000 字节。达到限额时本次返回未成功，不擅自移除已安装图标。

API 24 及以后，后续用户点击时可以清理“查询确定不在桌面、且已满 24 小时”的本项旧目录。保留最近目录，避免进程重启后尚未结清的系统交互被立即清理；旧流程本身不跨进程续作。低于 API 24 不查询、不据猜测清理，仍遵守容量上限。只处理严格自有目录名及唯一 `icon.png` 内容，保留符号链接和未知文件。查询失败或不完整、文件释放失败都保留旧记录及预算占用。当前目标 Phone API 26 可用查询 API，但具体服务结果仍待设备。

## 异步与生命周期

全进程只有一个物理请求所有者。并发 pin 会立刻返回未成功，不排队等待用户稍后看到第二个确认框。进入后台发生在校验、转码或写入期间时，旧请求被标记失效并回答一次；即使很快回前台，迟到结果也不能打开系统确认。

调用 requestNewPinShortcut 前才标记 submitted。系统确认页可能让应用进入后台，因此提交之后的普通后台事件不伪造取消；等待系统本来的结果。引擎或 Ability 解绑会使旧 Dart 回复和事件失效，但公开 API 没有取消这个系统交互的方法：物理所有者和图标持续保留到其 Promise 结清，新引擎不能越过它。若旧请求最终成功，保留成功图标，但不向新引擎发送旧 `pinned`。这一差异在证据中明示，不宣称调用者取消等于系统已经取消。

用户确认可以持续较长时间，本项没有假造一个时间到即视作物理取消的超时。永不结清的系统 Promise 最多占用一个请求和一个图标；这种设备故障需本机观察，不能用第二个请求叠加解决。所有清理句柄在失败后可重试，成功请求的图标寿命与该临时所有权分开。

## 本机 UI 接线点（本补丁不改 UI）

| 文件 | 本机要核对的条件 |
|---|---|
| `app/lib/ui/settings/appearance/appearance_page.dart` | `IconShortcutTile` 目前在 `androidFeatures` 条件中；本机在目标 OH 能力确认后单独开放此入口，不要整体打开所有 Android 功能。 |
| `app/lib/ui/settings/index/spots.dart` | `Spots.iconShortcut` 当前 `androidOnly:true`；应与实际 OH 入口保持一致，避免搜索与页面互相矛盾。 |
| `app/lib/ui/settings/appearance/icon_shortcut_sheet.dart` | 已有 `_add` 仅在用户点击后生成 PNG 并调用 pin；保持这一时机。`pinned` 可关闭面板；取消当前映射 failed。OH 上原 Android “快捷方式权限页面”提示及 mask/padding 应按本机结果调整。 |
| `app/lib/state/icon_shortcut_state.dart` | 现有方法参数、返回和事件可直接复用；没有模型文件、Node 服务或网络 TTS 依赖。`openPermissions` 仍指向原 Android popup 设置路径，不能据此声称 OH 可打开同一权限页。 |
| `app/lib/plugins/native/native_file_platform.dart` | 图片选择仍走已有 NativeFiles 授权与字节读取；本后端只接收 PNG 字节，不扩展 URI 或文件系统授权。 |

需要的手机证据：用户确认与取消分别产生真实结果；点图标只打开本应用；权限/服务拒绝可见；旋转、前后台和引擎销毁没有二次弹框或旧事件；桌面图标颜色、透明边缘、裁剪位置和清晰度；移除桌面图标后的有界清理；正式 SDK 编译及最终签名 HAP 的自定义 Want/图标文件接受情况。

## 定向验证命令

```bash
python3 runtime/tests/ohos/picture-shortcut-linux.py \
  --node /path/to/node \
  --typescript-prefix /path/to/typescript-5.9-prefix \
  --mode plain --out /new/evidence/picture-shortcut-plain

python3 runtime/tests/ohos/picture-shortcut-linux.py \
  --node /path/to/node \
  --typescript-prefix /path/to/typescript-5.9-prefix \
  --mode jitless --out /new/evidence/picture-shortcut-jitless

# 在已用原锁解析依赖、加载真实测试字体的独立 Flutter 副本的 app 中：
flutter test --no-pub --reporter expanded ../runtime/tests/ohos/picture_shortcut_data_test.dart
flutter test --no-pub --reporter expanded test/settings/icon_shortcut_sheet_test.dart
```

`--baseline-root /readonly/8fa` 运行同一入口测试，原版应实际失败于 `PICTURE_SHORTCUT_CHANNEL_MISSING`。每份 runner 输出命令、所有输入前后 SHA、原始日志及 JSON 计数。普通和 jitless 原生组、真实 Flutter 数据 consumer 已登记进 `run-gates.py`。宿主 TypeScript 严格检查只检查最小声明边界，不代替真实 ArkTS SDK。

本轮完整既有 Flutter 文件中 7 项行为通过；2 项 golden 比较因源码快照缺失对应 PNG 而失败，保留原始失败。没有更新或生成 golden 以消去失败，也没有宣称该完整文件全绿。真实 Flutter 数据测试与受控七项行为复跑的确切结果见交付证据；全应用 analyze、完整统一门、HAP 和设备留给本机既定流程。
