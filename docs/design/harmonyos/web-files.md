# 鸿蒙 WebView 文件选择通道

基底 `fd2890c`，实现 `dsh/web-files` 的 `pick` 和 `cancel`。实际 ETS 处理器和策略已在 Node 边界夹具中执行；系统选择器、Flutter messenger 与 OH URI 解析器仍是明确夹具。本版另在公开 SDK 26.0.0.38、hvigor 6.26.9 上完成严格 ArkTS 与未签名 HAP 构建，0 错误；源码注释中的旧 UNCOMPILED_SDK 标记由本版精确构建证据更新。系统 UI、授权及设备仍 NOT_RUN_DEVICE。

## 协议与选择器

现有 Dart `app/lib/ui/web/web_file_chooser.dart` 已为 OH WebView 接上 `setOnShowFileSelector`，无需修改 Flutter UI。`pick` 的字段为 `owner`、`webViewId`、`url`、`acceptTypes`、`multiple`。返回系统提供的 URI 字符串列表，取消、失效和启动失败都返回空列表；`cancel({owner})` 返回 null。其他方法返回 notImplemented。

原生仅接收非空 owner、非负安全整数 WebView ID、带非空 authority 的 HTTP(S) URL。owner 最多 200 字符，URL 与 accept 输入总长分别限 16384，accept 数组最多 100 项。与 Kotlin 一样，缺少 accept 列表使用空列表，multiple 只有布尔 true 才开启多选。Flutter 的真实 StandardMessageCodec 将 Map 解码为 JS Map；大于安全整数的 ID 不会取整使用。

`new picker.DocumentViewPicker(currentUIAbility.context).select(options)` 负责显示系统文件界面。明确 `selectMode:FILE`，单选最多 1 项、多选最多 500 项。500 是本实现给回包数量设的上界；不宣称 API 21 以后的系统仍只有 500 项上限。返回多于请求数的结果整批拒绝，不静默截断。

选择器需要当前 Engine 已附着的 Ability。新 Engine attach 时立即清除旧 Ability；在新 Ability 尚未 attach 的窗口里不借用旧上下文。通过实际处理器重放该顺序，修复前确实错误启动一次 picker，修复后不启动。旧 Engine 的迟到 detach 或已排队 handler 不得影响新 Engine。

## 页面归属与取消

公开 Flutter OH 接口没有此处可用的「由 webViewId 取可见原生 WebView 并核 URL」入口，本实现不伪造此项证明。ID 和 URL 只作参数准入；Dart 继续负责页面导航、同 URL reload、renderer 丢失、dispose 和选择结束后再次核 URL。存在 Ability 不等于已经证明 WebView 可见或应用在前台；系统 UI 的前台约束与真实 WebView 回调必须在设备上验。

同一 Ark 模块只允许一个实际 picker 在途，所有 WebFilesPlugin 实例共享该槽。槽在调用系统 API 前同步占用，期间另一 pick 返回空列表。只有系统 select 的 Promise 完成或同步启动失败，才释放槽。

owner 取消、Ability detach 或 Engine detach 立即结束当前网页回调，并让迟到结果失效，**不会声称关闭系统 picker**。公开 DocumentViewPicker 没有取消方法；取消回调后仍占住物理槽，避免新请求、同 owner 文本或新 Engine 接到旧选择。每个请求至多回包一次。这里不声称跨多个独立 Ark JS 环境实现进程全局互斥。

## acceptTypes 的保留方式

DocumentViewPicker 的公开选项是文件后缀筛选，不是 HTML 的完整 MIME 匹配器。处理规则如下：

| 输入 | 行为 |
|---|---|
| `.pdf`、`.tar.gz` 等安全后缀 | 小写、去重，直接作为筛选提示 |
| 精确 MIME，如 `application/pdf` | 用公开 UDMF `getUniformDataTypeByMIMEType` 和 descriptor.filenameExtensions 获取后缀 |
| 多个可映射类型 | 一个逗号分隔的联合筛选项，避免初始 UI 只展示第一种后缀 |
| `*/*`、`image/*` 等通配 | 使用系统全部文件视图，不凭一个不完整的静态扩展名表排除文件 |
| 精确 MIME 无可靠映射、UDMF 调用失败、后缀超限 | 同样使用全部文件视图，保留用户手动选择能力 |
| 无效 MIME/后缀文本 | 忽略；全部无效等价无筛选 |

accept 是选择提示，不是文件内容安全证明。不从 URI 名字推断 MIME，不读取文件内容，不执行任何选中文件。真实系统 MIME 表、后缀筛选显示和通配回退尚待设备验证。

## URI 与权限

URI 只能来自本次系统 picker 的返回值。逐项核对固定 `file://docs/…` 或 `file://media/…` authority，使用公开 URI 解析器核结构；拒绝 app 私有路径、任意其他 authority、content/http URI、控制字符与损坏的 percent escape。任一项不合格时整批为空。单选在去重之前就核数量；多选保留顺序并去重。

不把结果复制进 Dart、不申请媒体读写权限、不申请相机/麦克风权限、不持久化 URI grant、不接受调用方提供的任意文件作为结果。Dart 中的 capture 提示仍走普通系统文档选择，save 模式在 Dart 已拒绝。本实现依赖系统选择器授予的临时访问；URI 校验不是自行签发授权。ArkWeb 是否能在当前系统版本使用这些临时 URI，以及授权有效期/设备撤销行为，未在设备证实。

## 实际检查与重跑

```sh
node --test --test-isolation=none tooling/ohos/tests/web-files.test.mjs
```

16 项测试覆盖实际 ETS handler 的参数与选项、docs/media 整批拒绝、单/多选、MIME 回退、并发 pick、精确 owner 取消、取消后的迟到成功/失败、同步 API 错误、Ability 变化、新旧 Engine handler、跨 plugin 实例在途槽和不支持方法。所有平台响应都由明确夹具控制，不伪称打开过真实系统 UI。测试结束清理未完成的平台夹具仅用于失败隔离，不算产品取消成功。

先失败记录保留了「新 Engine 尚无 Ability 却使用旧 Ability」的真正状态错误。另一个 URI 形式反例使用 Node URL 作为 OH URI 夹具时发生规范化；产品因此先验证原始 HTTP(S) 层级形式，结论限定为准入规则不依赖解析器规范化，不能据此声称 OH 解析器存在同样错误。

公开 TypeScript 检查对两个实际模块无语义诊断。使用的最小 Flutter 声明增加 `MethodCall.args: Any`，该字段来自真实固定 embedding 源码；没有扩大产品类型或绕过调用检查。没有改 Android 源码、构建输入、权限、依赖或 HMS 通道。

## 固定公开来源

- [OpenHarmony 文件选择指南](https://github.com/openharmony/docs/blob/OpenHarmony-v6.1-Release/zh-cn/application-dev/file-management/select-user-file.md)；[DocumentViewPicker API](https://github.com/openharmony/docs/blob/OpenHarmony-v6.1-Release/zh-cn/application-dev/reference/apis-core-file-kit/js-apis-file-picker.md)。当前公开页面和固定声明都区分选择器授权与持久化权限。
- 固定 `interface_sdk-js` commit `8a86234f0d542e5062e24e948652f5a484d90904`：[picker 声明](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@ohos.file.picker.d.ts)，SHA256 `b1b583498eeb44fadc94e9b4e90ae20045b29265ab4484161dcf1ff8625a77b8`；URI 声明 SHA256 `b4159afd438c4754d4eee7a2a8d040dbebb0210e821b907b2197900f0e37b9d6`；UDMF 声明 SHA256 `657d4543c9c02ccaed7ee0373a0ac926d0a71319959a3f794d63031c30f8b1a2`。使用 API 10–12 起的公开字段，不新增系统权限。
- 实际 Flutter OH `MethodCall.ets` SHA256 `7e2afe24d5cbd634d93b494ed137b8317c942d8ee596e391958157eb59ced3f6`；`StandardMessageCodec.ets` SHA256 `6f5fb3d4e307b4598a37f7beaf98a829ab8b04cdbe3301454086f60830b207f8`，其中 MAP 分支构造 `Map`。
- 本仓库只读参照：`app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/web/{WebFilesPlugin,WebFilePolicy}.kt`、Dart chooser 与已有测试。未执行 Flutter widget 测试或 Android App 构建。

## fd2890c 严格编译修订

本版基底为fd2890cf9ae5ee2bb4faead2fbbf3689a4a29b92。唯一逻辑模块差异为遍历acceptTypes时显式视为Object[]，避免Any元素的隐式类型违反严格ArkTS规则；所有逐项类型/URI检查保留。实际check-arkts结果和编译输入SHA另附交付证据。SDK中系统选择器真实UI、临时URI授权和ArkWeb上传仍待设备核实。
