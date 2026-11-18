# 这个分支是什么：DSH Go 共存版

`DSH-go-coexist` 是 **DSH Go 的共存版（coexist）分支**，基于官方 [ccch1mneyyy/dsh-go](https://github.com/ccch1mneyyy/dsh-go) 的发布版改造而来。

## 📦 直接下载安装包

最新共存版 APK 在 Releases 里，不用自己构建：

**[⬇️ DSH Go 共存版 v1.1.0 (arm64)](https://github.com/876086405Git/DSH/releases/tag/coexist-v1.1.0)**

```
文件：dsh-go-1.1.0-coexist-arm64.apk
大小：685 MB
SHA-256：9fefc37c73919e60f01ec95082c1c4033dc4c52999b8400ddc8fcbefb8734966
```

国内直连慢的话，在下载地址前加 `https://gh-proxy.com/`：

```
https://gh-proxy.com/https://github.com/876086405Git/DSH/releases/download/coexist-v1.1.0/dsh-go-1.1.0-coexist-arm64.apk
```

> Release 标签用 `coexist-` 前缀（`coexist-v1.1.0`），和本仓库插件的 `v1.1.0` 区分开。
>
> 1.2.0 的共存包已经构建并在真机验证过（`versionName 1.2.0` / `versionCode 11182154`，见「六、版本基线」），但还没发 Release，所以上面的下载链接仍是 1.1.0。

---
> **和本仓库 `main` 分支的关系**：`main` 是「DSH 插件集合」（`plugins/` 下三个独立 DSH 桌面插件），和这个分支**内容零重叠、互不影响**。这个分支是完整的 Android 应用源码，不含任何插件代码。

---

## 一、共存版是什么

一个和官方 DSH Go **可以同时安装、同时运行**的独立 App。

| | 官方版 | 共存版 |
|---|---|---|
| 包名 | `io.github.ccch1mneyyy.dsh_app` | `io.github.ccch1mneyyy.dsh_app.coexist` |
| 桌面名 | DSH Go | DSH Go 共存 |
| 数据 | 独立 | 独立（各自登录、各自设置） |
| 签名 | 官方签名 | 本地签名（`CN=dsh-go local build`） |

因为包名不同，两者在 Android 眼里是完全不同的 App：**不需要同一把签名钥匙，装共存版不会覆盖官方版**。

---

## 二、相比官方版多了什么

### 1. 内置模型语音（第 6 档）

SenseVoice 跑在 App 进程里，**不依赖引擎、不依赖系统识别**，本机与远程主机都能用。

- 模型打包在 APK 内（`assets/voice/model.int8.onnx`，228MB），首次点麦克风解压到私有目录（10–30 秒），之后直接 mmap
- 走 sherpa-onnx 的 JNI 绑定（本地 AAR），不是 pub 包那个纯 FFI 版本
- 语音设置里是第 6 档「内置模型」

### 2. 提示词增强（✨）

输入框右侧的 ✨ 按钮，把草稿交给模型改写成更清晰的提示词。

- **手机本地直连** `api.deepseek.com`，不经过引擎、不依赖宿主装没装插件
- 成功才写回输入框，可点 ↺ 恢复原文
- 设置 → 个性化 → 提示词增强：可选模型（`deepseek-flash` / `deepseek-chat` / `deepseek-reasoner`），有「测试连接」按钮
- 没配 API key 时退回宿主那条路（本机引擎的桥 / 桌面插件）

> 为什么不用宿主插件转发：远程主机模式下 App 只是一条受限 RPC 隧道，宿主的 `plugin.route.call` 依赖 `launchToken`，从远程 RPC 拿不到（实测不带 token 访问根路径返回 401 且不下发 cookie）。本地直连绕开了这个依赖。

### 3. 内置角色素材

伙伴小屋打开即有鲸鱼娘，**不需要再「导入素材包」**。

- 素材在 `app/assets/companion/whale-girl.zip`（4.5MB）
- 不在 git 里（`.gitignore` 排除）——Live2D Cubism Core 是专有代码，构建时需自行放入

### 4. 关掉 App 内更新检查

共存版不显示「检查更新」和「每日自动检查」，启动时的自动检查也跳过。

原因：官方 Release 里的 APK 包名没有 `.coexist` 后缀，下载安装只会**多出一个 App**，不会更新共存版。留着一个点了会装错包的按钮比没有更糟。

开关是构建期 `--dart-define=DSH_COEXIST_BUILD=true`，官方构建不受影响。

### 5. 独有功能一览（官方版没有，合并上游时必查）

官方 changelog（`docs/changelog.md`）只写官方功能。下面这些**只存在于本分支**，每次合并新版本都要逐项确认还在：

| 功能 | 官方版 | 共存版 | 主要代码入口 | 引入提交 |
|---|---|---|---|---|
| 包名共存（可与官方同时安装） | ❌ | ✅ `io.github.ccch1mneyyy.dsh_app.coexist` | `app/android/app/build.gradle.kts` | `79640e08` |
| 内置模型语音（`VoiceMode.offline` 第 6 档） | ❌ | ✅ SenseVoice 跑在 App 里 | `app/lib/state/voice_settings.dart`、`app/android/app/src/main/kotlin/.../SenseVoiceEngine.kt`、本地 AAR | `79640e08`、`52178606` |
| 提示词增强（✨） | ❌（`v1.1.0` / `v1.2.0` 的 tag 里都没有这些文件） | ✅ 本地直连，没 key 时退回宿主 | `app/lib/state/prompt_enhance_local.dart`、`app/lib/ui/chat/prompt_enhance_button.dart`、`packages/dsh_client/lib/src/prompt_enhance_api.dart`、`runtime/bridge/dsh-go-bridge/lib/prompt-enhance/` | `79640e08` |
| 内置角色素材（鲸鱼娘） | ❌ 需自己导入素材包 | ✅ 开箱即有 | `app/assets/companion/whale-girl.zip` | `79640e08` |
| 关闭 App 内更新入口 | — 有更新检查 | ✅ 全部隐藏 | `app/lib/update/update_config.dart`（`coexistBuild`） | `79640e08` |

怎么自己确认（可复现）：

```bash
git cat-file -e v1.2.0:app/lib/state/prompt_enhance_local.dart
# 报错 = 官方确实没有这个文件

git diff --stat local/coexist-v2-pre120 HEAD -- app/lib/state/prompt_enhance_local.dart
# 空 = 合并 v1.2.0 时完全没动过它
```

---

## 三、怎么构建

### 前置资产（不在 git 里，需自行准备）

| 资产 | 位置 | 大小 | 来源 |
|---|---|---|---|
| 内置语音模型 | `app/android/app/src/main/assets/voice/model.int8.onnx` | 228MB | SenseVoice int8 |
| 模型词表 | 同目录 `tokens.txt` | 0.3MB | 同上 |
| sherpa AAR | `app/android/app/libs/sherpa-onnx-v2.0.1.aar` | 47.2MB | [GitHub Release](https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-2.0.1.aar)（国内用 gh-proxy 镜像） |
| 角色素材 | `app/assets/companion/whale-girl.zip` | 4.5MB | 从官方 APK 取出 |
| 签名配置 | `app/android/key.properties` | — | 自建 keystore |

### 构建命令

```bash
cd app
flutter pub get
flutter build apk --release \
  --flavor arm64 \
  --target-platform android-arm64 \
  --build-name 1.1.0 \
  --build-number <构建号> \
  --dart-define=DSH_APP_VERSION=1.1.0+<构建号> \
  --dart-define=DSH_COEXIST_BUILD=true
```

产物：`app/build/app/outputs/flutter-apk/app-arm64-release.apk`（约 685MB）

---

## 四、和官方版的差异清单

### 4.1 共存改造

| 改动 | 说明 |
|---|---|
| `applicationId` | 改为 `...dsh_app.coexist`；`namespace` 保持原包名（Manifest 里 26 处相对类名照旧解析） |
| Kotlin 包名常量 | 6 处改为读 `BuildConfig.APPLICATION_ID`（own-app 守卫、启动器别名、特权入口、自更新、IME 证据） |
| `buildConfig = true` | 生成 `BuildConfig` |
| 桌面名 | `res/values/strings.xml` 新增 `app_name` = 「DSH Go 共存」 |

### 4.2 内置模型语音

| 改动 | 说明 |
|---|---|
| `SenseVoiceEngine.kt` | SenseVoice 推理，含模型解压与 mmap |
| `VoicePlugin.kt` | 新增 `offlineStatus` / `prepareOffline` / `startOffline` 三个方法 |
| `WavRecorder.kt` | `companion object` 从 `private` 改 `internal`（`SenseVoiceEngine` 要读 `TARGET_RATE`） |
| `voice_settings.dart` | `VoiceMode` 追加第 6 档 `offline` |
| `voice_controller.dart` | 内置模型的探测与分流；**注意**：`stop()` 里 offline 判断必须排在 `_engine == VoiceEngine.system` 分支**之前**（内置模型借了 system 的状态，否则停止时会取 WAV 而不是文字） |
| `voice_cloud.dart` | 三处 switch 补 `VoiceMode.offline`（本机转写不走云端） |
| `build.gradle.kts` | `implementation(files("libs/sherpa-onnx-v2.0.1.aar"))` + `pickFirsts` 解决与 pub 包的 .so 重复 |

### 4.3 提示词增强

| 改动 | 说明 |
|---|---|
| `prompt_enhance_local.dart` | 直连 `api.deepseek.com`，`SYSTEM_PROMPT` 照抄 `dsh-prompt-enhance` 插件（两边改写结果一致） |
| `prompt_enhance_state.dart` | 三态状态机（idle / running / done），含撤销 |
| `prompt_enhance_button.dart` | ✨ 按钮组件 |
| `chat_screen.dart` | ✨ 优先本地直连，没 key 退回宿主 |
| `composer.dart` | 输入框插入 ✨ 的位置 |
| `personalization_page.dart` | 设置 → 个性化 新增「提示词增强」一节 |
| `settings_state.dart` | `promptEnhanceModel` 持久化 |
| `update_config.dart` | 新增 `coexistBuild` 开关 |
| `update_state.dart` | 共存版跳过启动自动检查 |
| `about_page.dart` | 共存版隐藏更新入口 |

---

## 五、构建踩过的坑（留给以后）

| 坑 | 现象 | 解法 |
|---|---|---|
| **sherpa 库重复** | `2 files found with path 'lib/arm64-v8a/libsherpa-onnx-c-api.so'` | `pickFirsts` 各取一份（`onnxruntime` 官方早写了，补上另外三个） |
| **官方 pub 包是纯 FFI** | `Unresolved reference 'OfflineRecognizer'` | `sherpa_onnx 1.13.4` 只有 3 个 .so，**没有 Kotlin 类和 `libsherpa-onnx-jni.so`**；内置模型必须用本地 AAR |
| **GitHub 直连不通** | `Could not connect to github.com port 443` | 用 `gh-proxy.com` 镜像下载 AAR |
| **`TARGET_RATE` 访问不了** | `Cannot access 'companion object': it is private` | `private` → `internal` |
| **模拟器验不了** | `CANNOT LINK EXECUTABLE ".../lib/arm64/libproot.so"` | x86_64 模拟器跑不了 arm64 的 PRoot，**官方包同样如此**；语音与引擎必须在 arm64 真机验 |
| **官方删了 `VoiceMode.offline`** | 合并 `v1.2.0` 后 `voice_settings_page.dart` 的 switch 非穷尽，编译失败 | 官方 `v1.2.0` 把 `offline` 从枚举里删了；合并时用官方新结构（`wordsForIos` / `harmonyLocal`）再补回 `VoiceMode.offline => l10n.voiceModeOfflineHint` |
| **l10n 冲突别手改** | 手写并集会把 `app_zh.arb` 写成坏 JSON | 文案不手改：只改 `app/lib/l10n/parts/*.arb`，再跑 `python app/tool/l10n_merge.py` 重新生成 arb 与 `gen/` |

---

## 六、版本基线

| 项 | 值 |
|---|---|
| 官方基线 | `v1.2.0`（`c1a84e3f`）；本分支合并提交 `3a5308d0` |
| 本分支 HEAD | 见 `git log` |
| versionName / versionCode | `1.2.0` / `11182154` |
| APK 体积 / SHA-256 | 685.7 MB / `30f3d8ecff163319f0100d2d0c074295eba4d50c49dc66cdc79075e76a89325d` |
| 合并前备份分支 | `local/coexist-v2-pre120`（回滚用） |
| 真机验证 | Redmi 25053RT47C（Android 17 / arm64-v8a）：安装、启动、本机引擎、提示词增强、语音输入均正常 |

---

## 七、许可证

本项目基于 [ccch1mneyyy/dsh-go](https://github.com/ccch1mneyyy/dsh-go)，遵循 **AGPL-3.0**（见 [LICENSE](LICENSE)）。

- 保留原作者的版权声明与 LICENSE
- 修改过的文件已在 git 提交信息里说明改动原因
- 若用于提供网络服务，使用者有权索取源码

---

## 八、相关文档

- 官方架构：[docs/architecture.md](docs/architecture.md)
- 贡献与验证契约：[CONTRIBUTING.md](CONTRIBUTING.md)
- 内置语音设计：[docs/design/voice-input.md](docs/design/voice-input.md)
- 伙伴小屋设计：[docs/design/companion.md](docs/design/companion.md)
