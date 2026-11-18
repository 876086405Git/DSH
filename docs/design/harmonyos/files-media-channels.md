# 鸿蒙文件与存图通道

**未编译、未在真机核实。** 这是 c818155 的 P3 文件/媒体子项；依赖 P1B 的原生 `openUserFile(root, relative): number` 及其 libdsh_host.so 类型，不重复交付 C++ 实现。只用公开 OpenHarmony 文件、系统选择器和相册创建确认接口，不新增 READ_MEDIA、WRITE_MEDIA 或无障碍权限。

## Dart 协议与实现范围

| 通道 / 方法 | 行为与返回 |
| --- | --- |
| dsh/files.resolveGuest | 工作区或应用 cache/temp 中的普通文件，安全打开后复制到受控缓存，返回绝对路径；无法物化返回 null。窗口分离中断返回 cancelled。 |
| dsh/files.listOutputs | 遍历 filesDir/workspace；默认深度3，最多500项，与 Android 上限一致；跳过隐藏名称与符号链接。返回 Map 数组，path、bytes、modified；mtime 秒换为 Dart 所需毫秒。 |
| dsh/files.open | 先复制，再以 viewData、MIME 和只读 URI 授权启动系统应用。返回空表示 startAbility 已成功返回，不宣称用户已阅读。chooser=true 明确 unsupported，替代为保存后从系统文件应用打开。 |
| dsh/files.saveToDownloads | DocumentViewPicker.save 让用户选目的地，写入实际选中 URI，返回该 URI。该方法名沿用 Dart 协议，不能声称强制写入某个 Download 目录。取消返回 cancelled，不返回 null 触发 Dart 的 Android 路径后备。 |
| dsh/files.pdfInfo / pdfPage | ohos_unsupported，提示通过“打开”交给系统 PDF 应用。公开 OpenHarmony SDK 快照中尚未确认可用的 PDF 渲染接口，不伪造页面尺寸或 PNG。 |
| dsh/files.pdfClose | 返回空；本实现没有持有 PDF renderer。 |
| dsh/media.saveImage | 接收 Uint8Array、name、mime；支持 png/jpeg/gif/webp。写应用临时文件，显示相册创建确认，向确认所得 URI 复制，返回该 URI。 |
| dsh/media.openSettings | false；当前采用逐次确认，不申请广泛媒体权限，没有需要授予的“读取所有照片”权限页。 |

消费方为 `app/lib/state/artifacts.dart`、`app/lib/state/artifact_files.dart`、`app/lib/media/gallery.dart`。本包不改 Dart/UI、Android、插件版本或生成的注册文件。插件在 configureFlutterEngine 阶段注册，避免依赖 super.onCreate 返回时 Dart 仍未启动的假设。

## 路径与文件身份

应用只接受 Context 提供的三个根：filesDir/workspace、cacheDir、tempDir。cache/temp 包含从远端下载后交给现有 Dart 文件流程的应用自有文件；不是授权任意系统路径。根由 ArkTS 计算，不从 MethodCall 接受。

P1B 原生函数从根 FD 出发逐层 openat，使用 O_NOFOLLOW，拒绝空段、点段、点点段、绝对相对路径参数及 NUL；最后 fstat 只允许普通文件。每个中间 FD 及时关闭，最终 FD 由 ArkTS 的 finally 关闭。这里也会拒绝完全位于工作区内的符号链接；需要使用其真实工作区文件。没有通过字符串前缀检查后再按原路径打开源文件。

这一区别来自实际公开源码：OpenHarmony File.path 的 GetPath 对保存的 path_ 做 RealPathCore，不是对已打开 FD 求路径。因此“open→File.path检查→读FD”本身不能证明该 FD 在根内。具体源码为固定 filemanagement_file_api 的 `interfaces/kits/js/src/mod_fs/class_file/file_n_exporter.cpp`。P1B 的逐层 FD 实现另有真实 Linux 换链竞争验证，不能将其等同于 OH 设备验证。

resolveGuest 不能直接返回原路径：Dart 随后打开时仍可能碰到路径置换，所以返回应用私有缓存副本。目录槽由原始路径的 SHA256 区分；展示名称去路径分隔符、控制字符及相册禁止字符，并在 UTF-8 完整码点边界限制到240字节。先由公开 mkdtemp 原子创建独立暂存目录，写入该目录内固定临时文件，完成后 rename 到稳定目标；同一路径和展示名称复用目标，避免每次点击都增加一份永久副本。缓存写入只来自已安全打开的源 FD。

该副本固定的是打开的文件身份，不是源文件内容的事务快照；另一个写者同时修改同一 inode 时仍可能影响复制。原大小读取后若提前 EOF，明确失败；之后增长的尾部不进入此次复制。返回的缓存路径在同一文件再次物化时可被新副本替换，不承诺长期版本存档。

## 资源、取消与系统交互

文件复制按256KiB缓冲区循环，处理短读和短写；源内容不整份装入 ArkTS。saveImage 的整份 bytes 已由既有 Dart 通道传入，原生层分块写入，并正确处理有非零 byteOffset 的 Uint8Array；不声称这消除了通道本身整图传输的内存成本。

系统文档选择器与相册创建确认共用一个进行中标志。标志在首次 await 前设置，避免同时点击保存打开多个窗口；finally 释放，包含取消、平台拒绝和窗口分离。每次 attach/detach 的 generation 使旧选择器结果不能继续写文件。文件 FD、PhotoAccessHelper 和临时图片均在正常异常路径中关闭/释放/清理。卸载时清 MethodChannel handler。

被选中的文档 URI 或相册 URI 一旦开始写入，后续磁盘错误可能留下部分文件；公开 URI 提供方没有本实现已证明的跨提供方原子替换或回滚保证。通道会报失败，不把部分内容报告成功。确认框已经创建相册目标后再被中断，也可能留下空目标。进程被杀不会执行 finally，临时缓存可能留到系统清理；全局缓存配额与启动恢复清理不在本子项内。

相册接口的公开注释说明：应用私有文件 URI 可以保存，但确认窗口可能不展示其预览。这是当前公开接口的限制，需要真机核实体验。拒绝确认为 cancelled，不误报 permission，也不自动弹出更多权限申请。

## 实际验证与不能推出的结论

Linux 测试使用实际产品 ETS 经 TypeScript 语法擦除后的逻辑、真实 Linux 文件、基于生产 `OpenUserFile` 的 Node 测试桥；Flutter messenger、选择器、相册、URI 映射及 OH fs 外层是明示替身。没有编译 ArkTS，也没有把测试替身当成可安装的系统插件。

15项覆盖：协议/unsupported、中文与特殊字符、700003字节短读短写、真实 symlink 越界拒绝、打开后路径置换、零写/提前EOF、复制中 detach、mtime单位/深度/隐藏文件、真实选中目标字节、并发选择器、取消不写目标、只读 URI、相册 bytes子视图/短写/清理、相册取消与不支持格式、跨通道忙状态与迟到回调、8路并发缓存提交、UTF-8名称边界。

首轮13/15：一个真实缺陷是保存的忙状态在 await close 后才设置，两个调用都进入系统选择器；已修到首次 await 前，并保留失败日志。另一个失败是测试用固定次数 setImmediate 等相册窗口，真实文件I/O尚未完成就 detach；改为明确的窗口已打开事件同步，没有缩减断言。修后15/15。

原生边界另有10000次真实父目录换链竞争，所有成功打开均读取根内内容，其余拒绝；循环前后 FD 数量相同。该证据随 P1B 原生子项交付。文件层协议测试中的本机 C++桥仅供 Linux 测试，不进 HAP。

## 固定公开来源

- [OpenHarmony SDK声明固定修订](https://github.com/openharmony/interface_sdk-js/tree/8a86234f0d542e5062e24e948652f5a484d90904/api)：`@ohos.file.fs.d.ts`（fd读写、stat.mtime秒、NOFOLLOW、mkdtemp）；`@ohos.file.picker.d.ts`（DocumentViewPicker.save）；`@ohos.file.photoAccessHelper.d.ts`（showAssetsCreationDialog、AssetCreationConfig、release）；`@ohos.file.fileuri.d.ts`；`@ohos.app.ability.wantConstant.d.ts`；`@ohos.security.cryptoFramework.d.ts`。归档 SHA256 `772f9db136c163e7b0ad0111230768f547fa9a7acc230c115a88aea8565f1099`。
- [File.path实现固定修订](https://github.com/openharmony/filemanagement_file_api/blob/53a68044278f75bdc7141d9124b31db4342940c2/interfaces/kits/js/src/mod_fs/class_file/file_n_exporter.cpp)。归档 SHA256 `50a5f15fb4a09af64c92826da6ccf0f7f4d84824be07228c9c67d6524c69f443`。
- [oh-flutter官方仓库](https://atomgit.com/oh-flutter/flutter_flutter)，固定 `e5f752df3e25ec897da3c98a74bcced7c21b0bd3` / `3.47.9-ohos-1.0.0`：MethodCall、MethodChannel、Any、AbilityAware、AbilityPluginBinding、FlutterAbility。只核接口，没有复制其他移植插件。
- c818155 `FilesPlugin.kt` 的 MAX_OUTPUTS=500、默认深度3、Dart Map字段；`gallery.dart` 的 MIME/返回URI/错误协议。

## 主线验证门

先合 P1B 原生用户文件函数与 lib 类型，再用 API26 hvigor 编译，检查公开接口的目标版本和 ArkTS 类型限制。设备上验证：Context根实际路径；导出中文及大文件；选取消、后台/退出、磁盘满；系统应用读权限与自定义MIME；相册确认、私有URI预览、各图片格式、取消后目标残留；选择器打开时 Ability 生命周期；真实 StandardMessageCodec bytes/Map 往返。

内嵌PDF预览、强制应用选择器、外来分享/深链文件复制、WebView文件选择、全局缓存回收仍由后续子项处理。不能因本通道注册成功就宣称完整 P3 或端到端 UI 已完成。


## v2：公开 API 反例与修正

08号完整包使用了 `fs.OpenMode.EXCL`，但固定公开 `@ohos.file.fs.d.ts` 没有此字段；此前 Linux double 额外提供 O_EXCL，掩盖了两个 TS2339 诊断。这是已经复现的接口缺陷，旧限定通过不再适用。v2完整替换08号，以c818155为基底；旧补丁和报告保留。

修正不使用私有数字标志。公开 `fs.mkdtemp(cacheRoot + '/.part-XXXXXX')` 以底层 uv_fs_mkdtemp 原子创建本次独占的新目录，再在其中创建普通文件并保留 NOFOLLOW。固定官方 file_api `53a68044278f75bdc7141d9124b31db4342940c2` 的 `interfaces/kits/js/src/mod_fs/properties/mkdtemp.cpp` 直接调用该函数，六个末尾 X 是模板，不能照搬 Node fs.mkdtemp 的追加后缀语义。

同时公开 `fs.rmdir` 会递归删除，旧测试映射成 Node rmdir 不准确。新版测试使用真实递归删除语义；产品清理先 unlink 本次路径，再要求本次目录仍是非链接目录且为空才 rmdir。有未知内容时保留目录。没有声称此检查抵抗同UID恶意进程在检查与删除之间改目录；应用私有缓存与同进程插件共享信任边界。设备跨应用沙箱隔离仍需真机确认。

新增真实测试覆盖临时目录创建失败后的FD关闭、8路并发的8个独立目录、未知内容保留、临时叶symlink拒绝且目标不改；整套18/18通过。另使用固定公开OH声明与已核Flutter最小公开签名作TS5.9.3语义检查，从旧版两处TS2339变为0诊断。该检查不是ArkTS/hvigor，不能替代主线SDK构建。

运行公开类型检查：`node runtime/tests/ohos/public-plugin-types.mjs app/ohos/entry/src/main/ets/plugins/FilesMediaPlugin.ets /固定interface_sdk-js/api /新的测试输出目录 /固定TypeScript npm前缀`。输入声明版本和来源见上节；不会向SDK或产品目录写生成文件。
