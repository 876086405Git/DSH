# 参与贡献

[English](CONTRIBUTING.en.md) · [项目首页](README.md)

## 暂不接受外部 Pull Request

本仓库目前**不接受任何外部 Pull Request**（代码、文档、配置、模板都不接收）。

- 外部 PR 会被入口检查自动关闭，见 `.github/workflows/pr-gate.yml`。
- 想提功能建议、改进想法或反馈问题：请[开 Issue](https://github.com/ccch1mneyyy/dsh-Go/issues/new/choose)，写清使用场景和期望的行为。
- 维护者自己（及其代理）的内部 PR 不受影响。

这是暂时限制，恢复接收外部 PR 时会更新本页。

## 欢迎参与

欢迎通过 Issue 反馈问题、改善文档和翻译、补充测试，或开发插件。影响协议、数据格式或权限行为的较大改动，先说明问题和方案，便于协调。

## 提交问题

使用仓库的 Bug 或功能建议模板。说明 App 版本、Android 版本、主机连接方式，以及可以重复的最小步骤。界面问题附截图或短视频；提交前检查并遮盖隐私信息。

涉及凭据泄漏、越权访问、未授权操作或其他安全问题，请按 [SECURITY.md](SECURITY.md) 私密报告。

## 准备开发环境

按 [README](README.md) 完成工具链与运行时准备。普通 App 开发不需要维护者的签名密钥、内测通道令牌或生产部署凭据。

- Flutter/Dart：使用仓库对应的 Flutter 版本和 App 的 Dart SDK 要求。
- Android：JDK 17，运行时 ABI 与 APK flavor 匹配。
- 插件 SDK：Node.js 22.19 或更新版本。SDK 在 `sdk/plugin-kit/` 内使用，尚未发布到 npm。
- 鸿蒙：OpenHarmony 公开 SDK（API 26）和 JDK 17 就能在 Linux 上编 ArkTS；Dart 产物由 Actions 在 macOS 上编。详见 [app/ohos/README.md](app/ohos/README.md)。

## 修改范围

让一个 PR 解决一个可以单独审阅的问题。修复时说明原来的行为、触发条件和改后的行为；避免夹带无关重命名、格式化和目录调整。

- UI 文案按现有中英文结构维护，优先使用项目已有组件和图标。
- 对行为改动补充能覆盖问题的测试；仅改文字或布局时，给出相应检查或截图即可。
- 修改客户端、桥接或插件协议时，同时检查兼容性和另一端的调用方。
- 不手工编辑生成文件；修改其源文件并运行对应生成器。
- 新增或移植第三方内容时，说明项目、版本或提交、源文件和许可证，并保留必要的署名、许可及修改说明。确认来源条款与目标目录许可兼容；移动文件不会自动改变许可。

## 常用检查

以下命令从仓库根目录运行。按改动范围选择；在 PR 中写明实际执行的命令和结果。缺少设备、资源或依赖时，明确写“未运行”和原因。

[CI](.github/workflows/ci.yml) 会在 PR 和 `main` 上跑这些检查：PR 跑通用检查和改动涉及的部分，合入 `main` 后跑全量，结果看 `CI OK`。CI 不碰真机和真实账号，这部分仍要单独验证。

PR 上的 Flutter 测试按目录打包运行（`app/tool/bundle_tests.py`）：一个目录的测试文件编译一次、共用一个进程，每个文件开始前把共用的状态复位。在包里失败的文件 CI 会单独再跑一次，以单独跑的结果为准；单独能过、在包里不过的文件，CI 会在警告里点名，把它加进 `app/test/bundle_solo.txt`。`main` 上仍然每个文件单独跑。

**Flutter 应用：**

```bash
(cd app && flutter pub get && flutter analyze && flutter test)
```

**真机调界面（热重载）：** `tooling/dev-run.sh` 把 debug 包覆盖安装到手机上已有的 release 版，再挂上 Flutter，按 `r` 几秒内生效。它用 `adb install -r` 加 `flutter attach`，不用 `flutter run`，因为后者安装失败时会先卸载，清掉手机上的数据。debug 模式动画偏卡，只用来看布局、尺寸和颜色，判断流畅度要打 release 包。需要 `app/android/key.properties` 和手机上的包同一把 key。

**Dart 通信包：**

```bash
(cd packages/dsh_client && dart pub get && dart analyze && dart test)
(cd packages/dsh_remote && dart pub get && dart analyze && dart test)
```

**插件 SDK：**

```bash
(cd sdk/plugin-kit && npm install && npm test)
```

SDK 的类型检查需要开发依赖 TypeScript；未安装时，相应测试会跳过。请检查测试输出，不能将跳过写成通过。生成器与同步顺序见 [SDK 维护说明](sdk/plugin-kit/README.md)。

**界面文案：** 修改 `app/lib/l10n/parts/` 的中英文 ARB，再生成并检查：

```bash
python3 app/tool/l10n_merge.py
python3 app/tool/l10n_merge.py --check
```

**用户指南：** 修改 `docs/guide/`（鸿蒙版在 `docs/guide/harmony/`，功能在鸿蒙上不同时两套都改），同步 App 内置的教学技能：

```bash
python3 app/tool/guide_sync.py
python3 app/tool/guide_sync.py --check
```

**插件教学技能：** 修改 `sdk/plugin-kit/skill/` 或 SDK 对应输入，再同步：

```bash
node sdk/plugin-kit/scripts/sync-skill.mjs
node sdk/plugin-kit/scripts/sync-skill.mjs --check
```

**鸿蒙：** 改了 `app/ohos/` 先跑严格 ArkTS 编译；改了 `runtime/ohos/`、引擎补丁或鸿蒙通道，跑全量门禁（输入和结果说明见 [GATES.zh.md](tooling/ohos/GATES.zh.md)）。鸿蒙改动不能改变 Android 的行为和运行时字节。

```bash
JAVA_HOME=/path/to/jdk tooling/ohos/check-arkts.sh --sdk /path/to/ohos-sdk/linux --hms-stubs
bash tooling/ohos/run-gates.sh --config ../gate-inputs.json --out ../gate-run-001
```

需要 APK 验证时，使用 README 中的构建入口。涉及 Android 进程、PRoot、直接启动、手机操控或更新安装的改动，应说明测试的 ABI、Android 版本、启动方式和设备；桌面测试结果不能替代真机结果。

`services/` 和 `infra/` 的线上检查、部署和发布脚本不属于普通贡献检查。修改配套服务时，先确认测试目标是自己的本地环境；不要用生产凭据运行示例。

## 提交 PR

填写默认 PR 模板，用中文或英文均可：

1. 问题是什么，为什么需要改，以及改后的行为。
2. 关联 Issue、主要受影响模块与兼容性影响。
3. 实际运行的检查、结果和未验证范围。
4. UI 改动的前后截图或录屏；使用测试数据，遮盖个人内容。
5. 新引入内容的来源、许可证和必须同步的声明。

提交前检查差异，排除密钥、个人配置、真实对话、设备序列号、构建缓存与私有运维资料。诊断包和日志也需要人工检查；不要把自动打码当成保证。

评论请围绕问题、证据和实现，尊重不同使用环境。使用 AI 辅助的改动也需要由提交者读懂、验证并承担维护责任。
