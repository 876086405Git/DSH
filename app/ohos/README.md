# HarmonyOS 工程

用 [oh-flutter](https://atomgit.com/oh-flutter/flutter_flutter) 3.47.9-ohos 构建，最低 API 26（模板的 `compatibleSdkVersion`，也是这一版 Flutter 引擎的要求）。安卓不读这个目录。

```sh
FLUTTER_OHOS=/path/to/flutter-ohos/bin/flutter \
DSH_OHOS_NATIVE_LIBS=/path/to/hap-libs/arm64-v8a \
DSH_NODE_HEADERS=/path/to/node-v24.22.1/src \
  tooling/ohos/build-hap.sh
```

`DSH_OHOS_NATIVE_LIBS` 是 `runtime/ohos/native/build-hap-libs.py` 的输出（见 `runtime/ohos/node/BUILD.md`），只在本次构建放进 `entry/libs/arm64-v8a`，缺任何一个库都直接失败。

## 现状

- 本机引擎的通道和原生宿主都在仓库里（`docs/design/harmonyos/`），还没有在设备上跑过。没有 `dsh/runtime` 原生宿主的构建，「本机」入口全部转去远程（`LocalRuntimeState.available`）。
- 权限包括联网、读网络状态、振动和麦克风（`ohos.permission.MICROPHONE`）。录音与语音识别在使用时检查麦克风授权；文件走系统选择器，不申请 `READ_MEDIA`。
- 读剪贴板要 `READ_PASTEBOARD`（`user_grant`、`system_basic`，大概率要 ACL），还没有申请，所以粘贴多半拿不到内容，待真机确认。
- 图标是 1024px 分层图，来自 `app/assets/brand/tile.svg`；三个备用图标和两个快捷方式图标由 `tooling/ohos/make-launcher-icons.py` 生成。
- 长按桌面图标有新对话和语音输入。最近对话发不到桌面，公开的 `shortcutManager` 没有发布接口。语音输入只在系统说明是桌面快捷方式拉起时才开麦克风，其他应用带同样参数只会开新对话。
- 设置 › 主题可以换桌面图标（`bundleManager.setAlternateIcon`）。文档没有提到确认弹窗，切换后的表现待真机确认；图片快捷方式没有公开接口，仍然隐藏。
- 冷启动有默认启动动画（`dsh/launch`）。系统启动页的图标不能跟着备用图标换，所以动画里总是默认图标；自定义启动画面仍然隐藏。

## 依赖

插件的鸿蒙实现在 `pubspec_overrides.ohos.yaml`，按 tag 锁定，只在构建 HAP 时生效。`material_ui`、`cupertino_ui`、`xterm`、`gpt_markdown` 没有鸿蒙 fork，它们的 `switch (defaultTargetPlatform)` 因为多出 `TargetPlatform.ohos` 而编不过，构建时由 `tooling/ohos/vendor_platform_switches.py` 复制到 `.vendor` 并让 `ohos` 走 android 分支。框架里长按振动、长按拖选的放大镜、滚动时工具栏淡出直接读 `defaultTargetPlatform`，`ThemeData.platform` 改不到，由 `tooling/ohos/patch_framework.py` 在 SDK 里改这几处分支（Dart 由 Actions 编译，所以要走那边才生效）。`flutter_webrtc` 没有鸿蒙实现，远程连接会自动退回中继。`share_plus`、`connectivity_plus` 没有可用的公开 fork，由 ArkTS 侧实现它们的通道（待做）。

## 宿主

| 步骤 | Linux | macOS arm64 |
|---|---|---|
| `flutter create` / `pub get` / `analyze` / `test` | 可以（要先去掉 pub 缓存里 `fluttertpc_dart_native` 对 `Abi.ohos*` 的引用：官方 Dart 没有这些成员，定制 Dart 没发 Linux 版） | 可以 |
| `flutter build hap` | 不行：3.47 配套的 `gen_snapshot`、`frontend_server` 只发布了 macOS 版，OBS 上的 Linux 版还是 Dart 3.12.2，快照格式对不上 | 可以 |
| `hdc install`、真机调试 | 可以 | 可以 |

`hvigor`、`ohpm` 来自 HarmonyOS Command Line Tools（要登录华为账号下载），版本跟 DevEco 26.0.0。OpenHarmony 公开 SDK 只够编原生库，打不了能装到华为手机的 HAP。

## ArkTS 检查

```sh
JAVA_HOME=/path/to/jdk tooling/ohos/check-arkts.sh --sdk /path/to/ohos-sdk/linux
```

真编译，不是类型擦除：公开源的 hvigor 6.26.9 → restool → ets-loader 严格 ArkTS → es2abc → 未签名 HAP，不用登录，下载一次后可以断网跑。它在临时副本上工作，诊断按文件写进 `<work>/diagnostics.txt`，有错误或有文件没进字节码就退出 1；警告默认不算失败，`--werror` 才算。`--with-forks` 把 `pubspec_overrides.ohos.yaml` 的七个 fork 一起编。

`--full` 再往前一步，打出除签名外完整的 HAP：Dart 产物来自 Actions 的 `ohos-aot-<sha>`，原生库来自 `build-hap-libs.py`，运行时来自 `compose-runtime.py`，`libdsh_host.so` 由 hvigor 走 `entry/src/main/cpp/CMakeLists.txt` 现编。之后 `tooling/ohos/audit-hap.py` 把 HAP 里的每个库、每个运行时文件和输入逐一核对。

```sh
JAVA_HOME=/path/to/jdk tooling/ohos/check-arkts.sh --sdk /path/to/ohos-sdk/linux --full \
  --aot /path/to/ohos-aot-sha --native /path/to/hap-libs/arm64-v8a \
  --runtime /path/to/dsh-runtime-rawfile.zip --node-headers /path/to/node-v24.22.1/src
```

- 这个 HAP 的 `compileSdkType` 是 OpenHarmony，真要上华为手机还得用 Command Line Tools 走 HarmonyOS 分支重打一次。
- `entry/build-profile.json5` 的 `ignoreResourcePattern` 不能删：restool 默认丢掉所有以点开头的文件，运行时清单里有 180 个，缺一个安装就失败。
- 用的是 OpenHarmony 分支，公开 SDK 只有这个。另用空 HMS 层跑过 HarmonyOS 分支（除 `externalNativeOptions` 外配置不改，用真的 `flutter-hvigor-plugin`），ArkTS 诊断逐条相同；但只有 HMS 才有的 API 这里编不过，真 HMS SDK 没跑过。
- 不带 `--full` 的 HAP 不能运行：没有原生库，没有 Dart 产物。
- 工具不查的东西：权限名、分层图标的键名和图片内容；`entry` 下与 `AppScope` 同名的资源会被遮蔽，改坏了也不报。依赖里的部分类型错误会被降成警告。
