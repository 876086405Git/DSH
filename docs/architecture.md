# dsh-Go 架构与代码地图

> 给要改这个仓库的人（或 AI）：§0 看全局，§1 找目录，§2–§5 看各层（鸿蒙宿主在 §3B），
> §7 按「要改什么」找入口和检查，§8 查专题文档。
> 代码是事实来源；本文与源码冲突时以源码为准，发现过时请直接改这里。

## 0. 一页全貌

```text
┌──────────────────── Android App 进程（Flutter + Kotlin）────────────────────┐
│ Dart: ui/ ──Riverpod──> state/ ──DshClient(packages/dsh_client)──┐          │
│        │                                                         │ HTTP+WS  │
│        └─ MethodChannel/EventChannel ─> Kotlin 原生层            │          │
│             runtime/ PRoot 生命周期   phone/ 无障碍·Shizuku·ADB  │          │
│             update/ pet/ notify/ files/ media/ voice/ ...        │          │
└──────────────────────────────────────────────┬───────────────────┼──────────┘
                                               │ 127.0.0.1:3080    │
                                               │ 或 SSH / 中继（远程主机）
┌──────────────────────────────────────────────▼───────────────────▼──────────┐
│ PRoot Ubuntu 24.04 用户态                                                    │
│   dsh web --patch /etc/dsh-app/dsh-web.patch.yml --host 127.0.0.1 --port …  │
│     ├─ 官方 DSH 引擎（runtime/patches 打了补丁）                              │
│     └─ dsh-go-bridge（Cordis 插件：/dsh-go/v1/*，原生插件协议/伙伴/删除/配置） │
└─────────────────────────────────────────────────────────────────────────────┘
```

上图是 Android。鸿蒙版共用同一套 Dart，宿主换成 ArkTS、本机引擎换成 App 进程内的 Node，见 §3B。

iOS 复用同一套 Flutter 页面、Riverpod 状态、`dsh_client` 和引擎桥协议，宿主实现不同：

```text
Flutter Dart ── MethodChannel ──> Swift（DshPlugin / EngineChannel）
      │                                  ├─ 同进程 NodeMobile + 专门生成的 runtime.zip
      │                                  ├─ 可选 iSH Linux guest（DshGuest.framework）
      │                                  ├─ CoreDevice / XCTest PhoneRunner 手机操控
      │                                  └─ WidgetKit 伙伴小组件、语音、可选宠物 PiP
      └──────── DshClient ── 127.0.0.1 本机引擎或远程 Host
```

技术栈：

| 层 | 选型 | 说明 |
|---|---|---|
| UI | Flutter 3.47（Dart 3.13）+ Riverpod 3 | 玻璃质感用 `BackdropFilter`；手写 Notifier，无 codegen |
| 原生层 | Android Kotlin（`app/android/`）；iOS Swift（`app/ios/Runner/`） | 各自管理运行时、系统接口和手机操控；Dart 通道需逐平台实现 |
| DSH 客户端 | 纯 Dart `packages/dsh_client` | 无 Flutter 依赖，可单测；本机与远程共用 |
| 本地运行时 | Android：Ubuntu 24.04 + Node，经 PRoot；iOS：NodeMobile + iOS 专用运行时包，可选 iSH Linux guest | 两端共用上游 DSH/桥协议，但不能把 iOS just-bash 当成 Linux |

五条贯穿主线：

| 主线 | 一句话 | 入口（详见 §5） |
|---|---|---|
| 对话 | UI 订阅 session/follow 事件流，ChatTranscript 折叠成 ChatState | `state/chat_state.dart` → `dsh_client` `watch()` |
| 插件 | 引擎桥 /dsh-go/v1/* 提供 contributions/invoke/stream，App 只读渲染 | `state/plugins_state.dart`、`plugins/` |
| 手机操控 | 引擎发工具调用 → 各平台原生执行并按任务所有者结算结果 | Android `phone/`；iOS `IOSPhoneBridge`/`IOSPhoneRunner`；`state/phone_state.dart` |
| 远程 | 另开一条加密隧道（SSH 或 WebRTC/中继），复用同一个 DshClient | `packages/dsh_remote`、`remote/` |
| 自更新 | Android 检查→下载→校验→安装（可走 Shizuku/ADB 特权） | `state/update_state.dart`、`update/`（Kotlin）；iOS 不复用 APK 安装器 |

## 1. 仓库地图

| 路径 | 是什么 | 关键入口 | 备注 |
|---|---|---|---|
| `app/` | Flutter App + Android/iOS 原生实现 | `lib/main.dart`、`android/.../MainActivity.kt`、`ios/Runner/AppDelegate.swift` | 本仓库主体 |
| `packages/dsh_client/` | DSH Web API 纯 Dart 客户端（连接/RPC/mux/事件/各域 API） | `lib/dsh_client.dart`（barrel） | 不依赖 Flutter，可单测 |
| `packages/dsh_remote/` | 远程传输：账号、SSH 宿主、Noise IK 加密通道、WebRTC/中继、隧道 carrier | `lib/dsh_remote.dart` | 依赖 dsh_client 的 carrier 抽象 |
| `packages/dsh_tavern/` | SillyTavern 兼容酒馆引擎（纯 Dart，191 个测试文件） | `lib/dsh_tavern.dart` | 与 AGPL 上游同许可，来源见 NOTICES |
| `packages/dartssh2/` | vendored dartssh2 4.1.0 + 补丁 | `VENDORED.md` | app 的 SSH 链路用它 |
| `runtime/` | 引擎运行时：构建脚本、锁定补丁、桥、boot/direct 启动、iOS 特化与测试 | `build-runtime.sh`、`patches/series`、`bridge/`、`ios/` | Android 产物在 `runtime/out/<abi>/`；iOS 构建输出不入库 |
| `sdk/plugin-kit/` | 原生插件作者 SDK（schema、checker、视图解析 JS 孪生、技能） | `bin/check.mjs`、`schema/` | private 包，不发 npm |
| `examples/plugins/` | 10 个插件示例 + e2e（只覆盖 weather/usage/quick） | 各 `package.json` `scripts.check` | |
| `services/share-worker/` | Cloudflare Worker：分享链接、下载、市场/工坊、统计 | `src/index.ts` | sparse-checkout 外 |
| `market/` | 插件市场目录源码（schema/审核/构建） | `scripts/check.mjs` | sparse-checkout 外 |
| `infra/forum/` | Discourse 部署配置 | `containers/app.yml` | sparse-checkout 外 |
| `site/` | 官网与分享页静态站 | `home/`、`share/` | sparse-checkout 外 |
| `tooling/` | 构建/发版/真机脚本与 Python 工具 | `build-apk.sh`、`dev-run.sh`、`release_assets.py` | |
| `app/ohos/` | 鸿蒙 ArkTS 宿主工程（Ability、通道插件、运行时、桌面卡片） | `entry/src/main/ets/entryability/EntryAbility.ets` | Android 不读；§3B |
| `runtime/ohos/` | 鸿蒙本机引擎：Node 宿主、虚拟进程、生命周期、组成器、Linux 客体 | `package/compose-runtime.py`、`preload.mjs` | 只进 OH 组成物 |
| `tooling/ohos/` | 鸿蒙构建、ArkTS 检查、门禁、真机脚本 | `check-arkts.sh`、`run-gates.sh`、`device.sh` | `research/` 是一次性实验记录 |
| `docs/` | 设计（50）、维护合同（61）、测试（14）、用户指南、插件教程 | `architecture.md`（本文） | §8 有索引 |
| `.github/workflows/` | CI（ci/goldens/pr-gate/runtime/ohos-compile） | `ci.yml` | §9 |
| `.agents/skills/` | 内部流程技能：pr/review/audit/bug/vuln-check | `SKILL.md` | |

> **sparse-checkout**：默认工作区只检出 `.agents .github app docs examples packages runtime sdk/plugin-kit tooling`；
> `market/`、`site/`、`services/`、`infra/` 需要 `git sparse-checkout add <dir>` 才在工作区；
> root CI 会跑 market/site/services 的检查，`infra/` 没有 CI（线上运维不在普通贡献检查内）。不要为此 checkout/reset 整个仓库。

## 2. App 的 Dart 层

### 2.1 启动与外壳

```text
main.dart → app.dart(DshApp/MaterialApp) → RootGate ─┬─ 引导未完成 OnboardingFlow
                                                     └─ ModeHome ─┬─ HomeShell(原生界面)
                                                                  └─ WebHome(官方 Web)
HomeShell = [ChatScreen] + [SessionsDrawer 左] + [QuickPanel 右] + [SystemEntryHost/LinkHost（只分发，不绘制）]
```

1. `lib/main.dart`：帧探针 → 载入语言与启动画面 → 注册许可与深链 → `runApp(ProviderScope(DshApp))`。唯一的 `ProviderScope` 在这里（全仓不锁定屏幕方向，平板由自适应布局处理）。
2. `lib/app.dart`：唯一 MaterialApp；主题/语言/动效/启动层；主题按 accent/语言/blur/instant/fluid 缓存重建（`_themesFor` 的缓存键要同步扩）。
3. `lib/ui/shell/root_gate.dart`：落地页判定（`initialOnboardingStep()` 是单一判据）：引导 / 首页 / Web 兜底；负责自动起引擎与诊断发布。
4. `lib/ui/shell/home_shell.dart` + `sessions_drawer.dart` + `quick_panel.dart` + `adaptive/`：原生外壳（聊天 + 左抽屉 + 右快捷面板 + ≥840dp 自适应）。
5. 二级页统一用 `ui/shell/page_frame.dart` 的 `AppPage`（浮动返回/大标题/滚动淡出）。

### 2.2 ui/ 目录（40 个子目录，按职责分组）

| 分组 | 目录 | 说明 |
|---|---|---|
| 外壳/路由 | `shell/` `modes/` | 主壳、抽屉、快捷面板、系统入口、自适应；深链集中表在 `app/lib/links/page_links.dart`（不在 ui/ 下） |
| 聊天 | `chat/`（123 文件） | 页 `chat_screen.dart`、列表 `chat_list.dart`、行模型 `chat_rows.dart`、`render/`（Markdown/流式修补/代码块/diff）、`widgets/`（消息/工具卡）、`dsh_ui/`（App 声明式视图卡）、`composer`、`voice/` |
| 会话 | `sessions/` `session/` `replay/` | 列表、详情、导出/回放 |
| 设置 | `settings/`（六组：AI/能力/外观/通用/主机/帮助） `engine_settings/` `access/` `safe_mode/` `providers/` `account/` | 设置 hub + 子页 + 搜索索引（`settings/index/spots.dart` 是标题与页面的单一来源） |
| 引擎/连接 | `engine/` `remote/` `onboarding/` `web/` | 引擎状态与日志、远程主机、首次引导、官方 Web 兜底 |
| 扩展 | `plugins/` `cordis/` `workshop/` | 原生插件详情/列表、Cordis、创意工坊 |
| 内容功能 | `tavern/`（酒馆） `bots/` `companion/` `pets/` `star/` | 酒馆页、机器人、伙伴小屋、桌宠、Star 提示 |
| 工具 | `phone/` `terminal/` `files/` `workspace/` `agents/` `notify/` `update/` | 手机操控/审批页、终端、文件、工作区、子代理、通知、更新 |
| 分享/外观 | `share/` `share_code/` `share_hosted/` `wallpaper/` `launch/` `theme/` `common/` `features/` | 分享、壁纸、开屏、设计系统（`theme/` 主要 import l10n；个别文件 import `common/`，已有 theme↔common 循环）、功能目录 |
| 其他 | `forum/` `community/` | 论坛、社区 |

> 路由是**分散的**：页面自己 `Navigator.of(context).push(...)`（ui 下 168 处、106 个文件，其中 `MaterialPageRoute` 155 处），
> 只有深链（`app/lib/links/page_links.dart`）和设置索引（`settings/index/spots.dart`）有集中表。
> 二级页的转场统一走 `theme/page_transitions.dart`。

> **加新页面**：放 `ui/<域>/`，用 `AppPage`，状态放 `state/`（不要在 ui 里新建跨页状态）。
> 入口至少接一处：抽屉 `_openDestination`（`home_shell.dart`）/ `SettingsPageId` + `settings_pages.dart` /
> `featureSections`（`ui/features/feature_catalog.dart`）；可深链则再加 `app/lib/links/page_links.dart` 的 id 并在 `main.dart` 注册。

### 2.3 state/ 状态所有权（123 文件）

| 状态 | owner | 关键点 |
|---|---|---|
| 主机列表/SSH/ActiveHost/relay 账号 | `state/hosts_state.dart` | 写 prefs + 安全存储；`ActiveHostController` 唯一改当前主机 |
| 三路连接装配 | `state/connection_state.dart` | `_connectionForHost()` 是唯一装配点（本机/SSH/relay）；`activeConnectionProvider` 给全 App 用 |
| 单会话聊天 | `state/chat_state.dart` | `autoDispose.family(sessionId)`；mux 事件折叠、发送/停止、审批、inbox |
| 会话列表 | `state/sessions_state.dart` | hostEvents 驱动刷新；删除是占位+确认流 |
| 设置与密钥 | `state/settings_state.dart` | 普通偏好 prefs；API key/provider key 只走 secure storage |
| 插件 | `state/plugins_state.dart` + `state/plugins/` | 安装队列、失败归一、市场索引、更新后需重启引擎 |
| 更新 | `state/update_state.dart` + `update/` | 检查/下载/校验/安装/特权安装 |
| 本机运行时 | `runtime/runtime_state.dart` | **事实源在 Kotlin** `RuntimeController.status()`；Dart 只镜像 dsh/runtime/events |
| 手机操控 | `state/phone_state.dart` + `phone/` | 开关/审批应答/自检/技能；原生 `SafetyGate` 是最终门 |

> 约定：一个状态只有**一个 owner**；UI 通过 `ref.read(x.notifier).method()` 改，不直接写状态。
> 全局 provider 一律在 `lib/state/`（手写 `Notifier`/`AsyncNotifier`，无 riverpod_generator）；
> 页面级 provider 留在页面文件里，用 `UncontrolledProviderScope` 覆盖的只有测试/重放。

**聊天流式性能契约**（改聊天页必须守住）：

- `ChatScreen.build` 只 watch 一个 `select` 元组；全量 `ChatState` 只在 `ChatList.build` 里 watch。
- 行缓存 `ChatRowsCache` 依赖 item identity、「仅 draft 变化时不清 `_built`」、以及 `deriveRows` 的键比对；
  改行模型要跑 `app/test/chat/chat_rows_test.dart`、`chat_rows_cache_test.dart`、`stream_geometry_test.dart`。
- 抽屉/快捷面板共用一组 AnimationController，抽屉移动时聊天不得重建。

### 2.4 其余业务目录（app/lib）

| 目录 | 职责 | 关键入口 |
|---|---|---|
| `l10n/` | 71 组 `parts/*_{zh,en}.arb` → 合并 ARB → 生成 `gen/`（生成物入库，CI 校验不手改） | `app/tool/l10n_merge.py`、`l10n.dart` `appL10n` |
| `ui_config/` | ui.json 声明式界面：读取/校验/缓存/恢复默认（本机 `root/.dsh/dsh-go/ui.json`，远程 `workspaceFiles/`） | `ui_config_state.dart` `uiOverridesProvider`、`ui_config_source.dart` |
| `plugins/native/` | 原生插件协议客户端（contributions/view/invoke/stream/assets） | `native_state.dart`、`native_surface.dart` |
| `plugins/seams/` | 原生座位：4 个 adapter（cordis/dsh_ui_panel/pet/schema_config）+ 座位规划 | `seat_planner.dart`、`slot_catalog.dart` |
| `phone/` | 手机操控 Dart 端（通道/审批/自检/技能录放） | `phone_channel.dart`、`phone_approval.dart` |
| `diagnostics/` | 诊断快照/zip/脱敏/发布 | `diagnostics_bundle.dart`、`diagnostics_publish.dart` |
| `share_code/` `share_hosted/` | 分享码/对话导出（打码）；加密托管链接 | `conversation_redact.dart`、`hosted_client.dart` |
| `remote/` | 远程 UI 侧：链路状态、网络监测、WebRTC peer、SSH 转发 | `relay/webrtc_peer.dart`、`ssh/local_forward.dart` |
| `tavern/` `companion/` `pets/` | 酒馆逻辑、伙伴小屋、桌宠 overlay 桥 | 各自 `*_state.dart`/`*_bridge.dart` |
| `links/` `launch/` `notify/` `voice/` `usage/` `performance/` `wallpaper/` `forum/` `workshop/` | 深链、开屏、通知、语音、用量、性能、壁纸、论坛、工坊 | 各自通道/服务 |
| `dev/` | 开发探针入口（不进发行包） | `runtime_probe_main.dart` 等 |

> **ui.json 现状**：内核/解析/schema 齐全，但当前只有 4 处真正接线——
> `theme.mode`、`composer.quickActions`、`hide.pluginCapsule`、`plugins.seats`；
> `header.actions`、`emptyState.suggestions`、`drawer.*`、`density`、`shortcuts`、`pet` 已解析但 lib 内无消费者。
> 改 parser ≠ 生效，先全局搜 provider 符号。
> `app/assets/skills/dsh-go-ui/schema.json` 与 `ui_config_schema.dart` 必须同步（`app/test/ui_config/schema_sync_test.dart`）。

### 2.5 依赖方向、生成物与 l10n

- 硬规则：`ui/` 可以 import 任何目录；**`ui/` 以外不能 import `ui/`**（入口 `main.dart`/`app.dart` 除外）。
  守卫：`app/test/arch/import_direction_test.dart`（当前允许 56 条历史边，**只减不增**）；
  用 `cd app && dart run tool/import_graph.dart --edges` 看现状。**ui 内部互引不受守卫**（已有 theme↔common 循环）。
- 语言/主题不是 InheritedWidget：`appL10n` 是静态跟随，语言切换靠 `app.dart` 手动重建全树；
  widget 里优先用 `context.l10n`，不要在 `initState`/const 里缓存 `appL10n.xxx`。
- 不手改生成物：`l10n/gen/`、`app/assets/skills/*`、`sdk/plugin-kit/types/`、`lib/bridge/`、
  `lib/messages.json`、`test/parity/*`。改输入后跑对应生成器（§9）。
- l10n 链路：改 `parts/*_{zh,en}.arb`（中英同步、key 全局唯一 lowerCamel、占位符一致）
  → `python3 app/tool/l10n_merge.py` → 产物入库；CI 用 `git diff --exit-code -- lib/l10n` 防手改。

## 3. 原生层

以下 §3.1–§3.5 是 Android Kotlin 实现，集中四大块：引擎运行时、手机操控、外设/通知、自更新。

### 3.1 注册与入口

`MainActivity.kt`：单例 FlutterEngine（`dsh-main`）+ 一次注册 26 个插件；处理 `dsh/app` 通道、启动画面、刷新率。

### 3.2 引擎运行时（`.../runtime/`）

Android/iOS 后台执行的机制、系统回收恢复和三方方案取舍见 [后台运行](design/background-execution.md)。

| 文件 | 职责 |
|---|---|
| `RuntimePlugin.kt` | `dsh/runtime` + `dsh/runtime/events`：install/start/stop/reset/safe/LKG |
| `RuntimeController.kt` | 引擎生命周期单例：Phase 状态机、`runGen/stopGen` 运行代、健康/重启决策 |
| `RuntimeInstaller.kt` | rootfs 安装/升级/reset/保留：`filesDir/runtime/{rootfs,rootfs.version,staging}`；`filesDir/runtime.reset` 与 `filesDir/runtime-keep` 在同级 |
| `DshProcess.kt` | PRoot/direct/tawc 启动、日志泵与 token 识别、`/proc` 归属清理 |
| `DshService.kt` | 前台服务：安装/运行/停止、通知、网络回调 |
| `SafeMode.kt` | 救援 profile 与失败决策（崩溃后自动重启的策略） |
| `EngineUpgrade.kt` / `RuntimeUpgradeCompatibility.kt` | 分层升级事务（prepare/pending/version/done）与兼容拒绝 |

> **事实源**：本机引擎状态只认 `RuntimeController.status()`；Dart `LocalRuntimeController` 是只读镜像。
> `EngineUpgrade` 的 `ENGINE_PATHS` 与 `rtbuild.py` 的清单必须一致，否则升级被兼容检查拒绝。

### 3.3 手机操控（`.../phone/`）

`McpServer`/`PhonePlugin`（`dsh/phone` 通道）→ `PhoneCore`/`PhoneTasks`（任务状态机）→
`SafetyGate`（最终审批门）→ 执行器：`a11y/`（无障碍读屏与操作、OCR、浮层、受保护页面）、
`background/`（不打扰模式特权虚拟屏/Shizuku/ADB）、`shell/`（Android shell 会话）。
技能录放在 `phone/skills/`；自检在 `phone/selfcheck/`。
手机工具与提示词由 Kotlin 侧注入：`PhoneGuest.kt` 启动时往 rootfs 写 `/opt/dsh-app/phone/{relay.cjs,phone.patch.yml}`，用 `--patch` 挂上 `@deepseek-ai/dsh-mcp-client`（serverName=phone）；`PhoneToolCatalog.kt` 定义固定工具集；`GuestSetup.kt` 把 `PhoneGuest.AGENTS_SECTION` 写进 `$DSH_HOME/AGENTS.md`。`dsh-go-bridge/lib/native/` 只实现原生插件协议（contributions/views/stream/invoke），与手机工具无关。

### 3.4 其余原生块

| 目录 | 职责 |
|---|---|
| `update/`（含 `privileged/`） | 自更新：APK 下载/校验/安装，Shizuku/ADB 特权安装与恢复 |
| `pet/` | 桌宠悬浮窗、精灵渲染、边缘吸附、菜单/截图 |
| `notify/` | 通知、实时活动（Live Activity）、回合提醒、通知动作回调 |
| `files/` `media/` `nativemedia/` | 文件选择器/保存、相册权限队列、视频/音频/麦克风、JS 预览 |
| `launch/` `icons/` `shortcuts/` `tile/` | 开屏、桌面图标、快捷方式、磁贴 |
| `links/` `share/` `theme/` `islands/` `voice/` `usage/` `performance/` `web/` `mlkit/` `i18n/` | 深链、分享接收、动态取色、插件岛、语音、用量、性能策略、Web 文件、ML Kit、原生文案 |

### 3.5 平台通道（Dart ↔ Kotlin）

| 通道 | 用途 | 形态 |
|---|---|---|
| `dsh/runtime` + `dsh/runtime/events` | 引擎安装/启动/停止/重置、状态/日志/进度/通知事件 | Method+Event |
| `dsh/phone` + `/events` + `/preview` | 手机操控方法面、任务事件、预览图 | Method+Event |
| `dsh/update` | 自更新安装 | Method |
| `dsh/app` | 置前台、时区等应用级查询 | Method |
| 其余 `dsh/files` `dsh/diagnostics` `dsh/share` `dsh/notify` `dsh/native-media` `dsh/voice` `dsh/islands` `dsh/web-files` `dsh/launcher_icon` `dsh/picture_shortcut` `dsh/dynamic_color` `dsh/launch` `dsh/launch_clip` `dsh/links` `dsh/shortcuts` | 各功能域 | 以各目录的 `*Plugin.kt` 与 Dart 端 `*_channel.dart` 为准 |

> `dsh/runtime` 的方法/状态模型以 `app/lib/runtime/runtime_bridge.dart` 为准
> （`RuntimeStatus`/`RuntimePhase`/事件类型都在那里；本文不再复制方法表）。

### 3.6 iOS 原生层（Swift）

`app/ios/Runner/AppDelegate.swift` 注册 `DshPlugin`，后者把文件、通知、相册、语音等通道接到同一 Flutter 引擎。`EngineChannel.swift` 实现 `dsh/runtime`：在 App 沙盒安装运行时，启动同进程 NodeMobile 的 `dsh web`，把本机地址与状态交给 Dart；Dart 的 `LocalPaths.load()` 在首帧前向它读取 `guestRoot`，新会话才会使用真实的 iOS 工作目录。iOS 工程用 Swift Package Manager，包含单独签名的 NodeHost、原生 addon 和可选 `DshGuest.framework`，见 [`app/ios/README.md`](../app/ios/README.md)。

| 入口 | 职责与边界 |
|---|---|
| `runtime/ios/`、`tooling/ios/prepare-engine.sh`、`specialize-runtime.py` | 在验证过的共享运行时组合上做 iOS 特化，生成 `Engine/runtime.zip`；NodeMobile 24.22.1 与 framework 随 App 签名，不把 Android PRoot/APK 产物直接放进 IPA |
| `tooling/ios/ish/`、`GuestChannel.swift` | 可选 Linux guest。未安装时用 just-bash；安装 guest 后才有真实 Linux 环境，Python 等包还取决于 guest 内实际安装情况 |
| `runtime/ios/phone/`、`IOSPhoneBridge.swift`、`IOSPhoneRunner.swift` | 引擎的手机工具请求以运行代/会话所有者绑定，经原生任务授权后选择 CoreDevice 或已启用的 XCTest；失败结果不自动跨路线重放 |
| `IOSPhoneCoreDevice.swift`、`IOSPhoneSelfRunner.swift`、`PhoneRunner/` | CoreDevice 负责可用的应用控制和观察；本机缺少输入服务时，已签名的独立 PhoneRunner 承担 XCTest 元素观察与点按。能力以设备实际服务和用户设置为准 |
| `IOSPhoneTaskConsent.swift`、`ContinuedRun.swift` | 每个手机任务首次在前台授权，最长 30 分钟；后续普通动作可在目标 App 前台继续。离开 DSH Go 时才请求 iOS 26 持续任务，系统可拒绝、过期或中止；画中画不是手机操控准入条件 |
| `CompanionWidget/`、`IOSCompanionWidget.swift` | WidgetKit 小/中尺寸伙伴卡；主 App 写有限展示快照到专用 Keychain，扩展只读快照，不分享 Host 凭据 |
| `PetOverlay/IOSPetOverlay.swift`、`VoiceChannel.swift`、`IOSAudioSessionCoordinator.swift` | 像素宠物 PiP 默认关闭且可选；`dsh/voice` 负责系统听写/录音，`dsh/speech` 负责通话与朗读 PCM，音频会话由原生协调器管理 |

iOS 仍有明确缺口：内置视频预览、通话实时 PCM 字幕、网页伙伴画中画渲染和 APK 式自更新没有等价原生实现；相关入口须降级或隐藏。每次共享 Flutter 新增平台通道，都要核对 iOS 注册及方法返回类型；当前清单和轻量 CI 检查在 [`tooling/ios/CHANNEL_COVERAGE.md`](../tooling/ios/CHANNEL_COVERAGE.md)。真机上的后台持续执行、XCTest 输入与可选 guest 软件包不能由模拟器编译推断。

## 3B. 鸿蒙宿主层（ArkTS）

> 同一套 Dart（`app/lib`），宿主换成 `app/ohos/`（ArkTS，105 个 `.ets`），本机引擎换成 App 进程内的 Node。
> 现状、能力差异和每个通道的协议在 [`docs/design/harmonyos/README.md`](design/harmonyos/README.md)；本节只给地图。

```text
┌──────────────── 鸿蒙 App 进程（oh-flutter 3.47.9-ohos + ArkTS）─────────────────┐
│ Dart: 与 Android 同一份 app/lib；operatingSystemProvider == 'ohos' 时按功能分支   │
│   └─ MethodChannel（与 Android 同名：dsh/runtime、dsh/files、dsh/speech …）       │
│ ArkTS: entryability/ → plugins/（各通道）  runtime/（安装、生命周期、后台任务）   │
│        phone/（系统操作）  companion/ formability/ widget/（伙伴桌面卡片）         │
│   └─ NativeHost 首次按需加载 libdsh_host.so（Ark N-API）                          │
│        └─ C ABI → libnode.so：Node 24.22.1 --jitless，独立线程，一进程只启动一次  │
│             dsh web + dsh-go-bridge，补丁 = 公共链 + OH 覆盖补丁                  │
│             虚拟进程 runtime/ohos/process：just-bash、JS rg、isomorphic-git、     │
│             node 脚本走 Worker；可选 Linux 客体（TinyEMU，libdsh_linux.so）       │
└──────────────────────────────────────────────────────────────────────────────────┘
```

和 Android 的根本差别：没有 PRoot、不能 exec 外部程序、不能加载任意 native addon、不能在别的 App 上面画东西或读屏。
因此手机操控换成「系统操作」（打开应用/系统页、通知、剪贴板，`ets/phone/`），App 外宠物、悬浮条、无障碍不存在；
命令行工具要么由虚拟进程实现，要么交给可选的 Linux 环境，要么连电脑。

| 部分 | 位置 | 说明 |
|---|---|---|
| ArkTS 工程 | `app/ohos/entry/src/main/ets/` | 构建与现状见 [`app/ohos/README.md`](../app/ohos/README.md)；凭据见 `app/ohos/secrets.md` |
| 原生宿主 | `app/ohos/entry/src/main/cpp/`、`runtime/ohos/native/`、`runtime/ohos/node/` | `libdsh_host.so`（hvigor 现编）、`libnode.so` 等由 `build-hap-libs.py` 构建 |
| 运行时组成 | `runtime/ohos/package/compose-runtime.py` | 一个 Stored `runtime.zip` 放在 HAP rawfile，安装时逐文件核 size/SHA |
| 引擎补丁 | `runtime/patches/series` + `pins.json` 的 `targetSets` | `series` 是唯一顺序；`android` 集合等于 main 的整条链，`ohos` 集合是公共链加 `ohos-*` 覆盖补丁。**新补丁必须登记进两个集合之一或两者**，否则 rtbuild 拒绝构建 |
| OH 专属 JS | `runtime/ohos/{process,lifecycle,capabilities,publication,linux,net,plugins,preload.mjs}` | 只进 OH 组成物，Android 运行时字节不受影响 |
| Dart 分支 | `state/android_features.dart` | `operatingSystemProvider`、`androidSystemFeaturesProvider`；另有少量 `*_ohos.dart`（语音、Linux、附件、空闲诊断） |
| 无 OH 版的插件 | `app/ohos/pubspec_overrides.ohos.yaml`、`tooling/ohos/vendor_platform_switches.py`、`patch_framework.py` | 只在构建 HAP 时生效，不影响 Android |
| 用户指南 | `docs/guide/harmony/` | 鸿蒙版单独一套，`guide_sync.py` 生成 `app/assets/skills/dsh-go-guide/harmony-*` |

规则：

- **按功能放开，不全局放开。** 能在鸿蒙实现的功能直接走同一套 UI；做不到的才用 `androidSystemFeaturesProvider` 或 `operatingSystemProvider` 隐藏，并在鸿蒙指南里写明替代。隐藏是最后手段。
- **鸿蒙和 iOS 都不是「安卓」。** `androidSystemFeaturesProvider` 在两者上都是 false，所以它只能表示「没有安卓专属功能」；只属于鸿蒙的东西（系统操作、Linux 环境、`SettingsIndex.ohosLink`、`ohosOnly` 页面）一律判断 `operatingSystemProvider == 'ohos'`，iOS 也有的安卓功能用 `SettingSpot.iosToo`。
- **Android 不变。** 鸿蒙改动不能改变 Android 的运行时字节和行为：门禁里 `android-targets`、`android-version-tree` 对照 main 的运行时，`runtime/locks/android-recipe-compat.json` 记录允许的差异。
- **严格 ArkTS。** for-of 变量要显式类型、子类传给 `Error` 参数要 `as Error`、静态方法里不能用 `this`；`check-arkts.sh` 能在 Linux 上真编译查出来。
- **Dart 产物只在 macOS 上编。** oh-flutter 的 AOT 工具只发 macOS 版，`.github/workflows/ohos-compile.yml` 在推到 `claude/harmonyos-ohos` 或 `ohos/**` 时编出 `ohos-aot-<sha>`；HAP 的打包、签名、安装都在 Linux 上做。

## 4. 包

### 4.1 dsh_client（连接层，40 个导出文件）

```text
DshConnection      单个 Host 的物理连接：launch-token → cookie、Host 头、HTTP/WS upgrade
  └─ DshCarrier    传输抽象；默认 DshHttpCarrier（POST /api/<endpoint> + WS）
       ├─ DshRpc     unary Typert 调用（{type:client-request,rpcId,method,payload}）
       └─ DshMux     /api/remote.mux 逻辑流 + $events ready 世代 + 重连退避
            └─ DshClient  会话/提示/审批/模型/工作区/插件/终端…（27 个 *_api.dart extension）
                 └─ ChatTranscript  $events → 聊天条目 reducer
```

- 业务/网关错误：**HTTP 200 + `result.ok:false`**；只有传输拒绝用 4xx。
- 错误类型 `DshRemoteException`（Host 决定）vs `DshCarrierRefusedException`（管道故障）要分清。
- 没导出的内部件：`background_session_read`、`rpc_envelope` 等只供 `lib/src/` 内部 import（barrel 头注释只列 5 层，不列它们）。

### 4.2 dsh_remote

`RemoteAccount`（登录/设备/Host 目录/key pinning）→ `RemoteServerApi`（REST）+
`RelayTransport`（控制 WS）→ Noise IK `SecureChannel` → `WebRtcTransport`（LAN/P2P/TURN）或 relay →
`RemoteRpcClient` → `RemoteTunnelCarrier`（实现 `DshCarrier`，交给普通 `DshClient`）。
端点白名单 `harnessRemoteAllowlist` 与上游 Host 插件版本耦合，新增端点前先看它。

对话备份走 `RemoteSessionTransfer` 的顶层 `session.transfer.*` Noise RPC，不经 Harness 端点白名单。
`state/session_backup_state.dart` 连接当前会话与私有备份存储，`ui/remote/session_backup_page.dart` 提供单条／工作区备份和恢复；
`remote/session_backup/backup_store.dart` 用系统安全存储中的随机密钥加密文件和清单，提交前持久保存待核对记录。
Remote 一次只连一台主机，跨主机复制采用先备份、再切换恢复，不另建第二套设备身份。

Remote WebUI 通过 `RemoteDshWeb` 在原 Noise 连接上串行调用 `dsh.web.open/close`，不经 Harness 业务白名单。
`state/remote_web_state.dart` 观察当前会话能力，`ui/remote/remote_web/` 负责一次性表单 POST、同源导航与页面收尾；
访问票据不进入 URL、日志或持久化存储，普通刷新只 GET 干净根地址。原生 WebView 的隔离能力按平台实际 API 使用，
不清空全局 Cookie；RPC／HTTP 的明确 429 使用友好繁忙提示，其余连接失败不猜测成限流。

### 4.3 dsh_tavern / dartssh2

酒馆引擎（SillyTavern 兼容：角色卡/世界书/宏/斜杠命令/正则）纯 Dart；dartssh2 是 vendored 上游加压缩补丁。

## 5. 协议与数据流

### 5.1 一次对话

```text
UI 输入 ─> ChatController.send() ─> DshClient.prompt(sessionId, text)
                                    │ POST /api/session/prompt（RPC 信封）
引擎 ─> $events 流 ─> DshMux ─> DshClient.watch(sessionId) ─> ChatTranscript.apply() ─> ChatState ─> UI
         （快照 + 连续 seq 事件 + assistant-stream 增量；断线重连后重开 follow 并重新快照）
```

- 审批/提问：引擎发 `approval/request`/`user-questions/request`，客户端经 `$events/result` 应答；
  断线重连后按同一 `eventId` 重投，已结算的不重放。
- 发送结果未知（连接中断）：同一内容重发复用 requestId，由 Host 去重。
- `watch()` 保证：每世代先快照；durable 事件 seq 严格连续；assistant revision 跳跃强制重同步；
  连续 6 次瞬时失败结束；401/403 等下一次登录。

### 5.2 RPC 与 mux

- RPC：`POST /api/<namespace>/<method>`，body `{type:"client-request",rpcId,method,payload:{args}}`；
  响应 `{type:"server-response",rpcId,result:{ok,value|error}}`。
- mux：WebSocket `/api/remote.mux`；每世代先开 `$events` 流，首帧必须 `ready`；
  帧词汇 `open/item/end/cancel`（上行）、`item/end/error`（下行）。跨 socket 不重放任何东西。

### 5.3 bridge（/dsh-go/v1/*）

| 路由家族 | 提供 | 消费方 |
|---|---|---|
| `/capabilities` `/inventory` `/occupancy` | 能力协商、boot/桥版本、卸载占位表 | `dsh_client/src/dsh_go_api.dart`、`client_inventory_api.dart` |
| `/contributions` `/views/...` `/invoke` `/assets/...` | 原生插件协议 v1（清单/视图/调用/资源） | `plugins/native/`、`state/plugins_state.dart` |
| WS `/stream`、`/media/...`、`/files/{id}/upload` / `complete` | 插件流、媒体、文件选择 | `ClientNativeBridge` |
| `/plugin-config`（含 `/{entryId}`） | 插件配置编辑（含安全字段路径 `error.path`） | `plugin_config_state.dart` |
| `/sessions/deletion` `/sessions/delete` | 安全删除会话（须先读 `supported:true`） | `session_deletion_state.dart` |
| `/companion/...` | 伙伴状态/事件/记忆/召回/signals | `companion/`、`dsh_client companion_*` |

- 错误统一 `{error:{code,message}}`；未知路由 404 `route-not-found`（旧桥降级判据）。
  完整契约：`docs/design/bridge-contract.md`。
- 注入方式：本机 = rtbuild 生成 `/etc/dsh-app/dsh-web.patch.yml` + `dsh web --patch`；
  远程 = 插件包的 `dsh.bundle.patch`。`cordis.patch.yml` 里 `# --- shared rows ---` 是构建切分标记，改缩进会构建失败。
- 新增路由要同时改：`bridge/lib/index.js`（分派 + `CAPABILITIES`）、`bridge-contract.md`、客户端消费端。

### 5.4 运行时构建与分层升级

```text
DSH npm 前缀（runtime/locks）→ rtbuild 按 series 应用目标平台的补丁（pins 双哈希校验）
  → 加 bridge/boot/direct/patch.yml → assemble → runtime/out/<abi>/assets/runtime/
       ├─ manifest.json（版本/baseId/分层或单包）
       └─ rootfs-<abi>.tar.xz（schema 1）或 base+engine 两层（RUNTIME_LAYERS=1，schema 2）
→ Gradle flavor 打为 APK 资产
```

上图是 Android 构建链。iOS 则从同一 DSH 版本和桥出发：`runtime/ohos/package/prepare-inputs.py` 先准备隔离的 npm 前缀，`compose-runtime.py` 组合共享运行时，再由 `tooling/ios/specialize-runtime.py` 换入 iOS 的图像、存储与原生 addon 路径；`tooling/ios/prepare-engine.sh` 把 `runtime.zip`、NodeMobile 和 addon/framework 输入放到 `app/ios/Engine/`。Xcode 编译 iOS framework 并嵌入 App，产物与缓存不进 git。可选 iSH guest 单独构建，不是共享运行时 ZIP 的替代。

升级：`manifest.upgrade` → `RuntimeInstaller` 解 staging → `EngineUpgrade` 事务
（`engine.prepare` → `engine.upgrade` → 换入 → `rootfs.version`）→ 只替换固定引擎路径，
用户 `/root` 数据保留；中断在任一步由 recover 续跑。详见 `docs/design/runtime-layers.md`。

### 5.5 补丁（runtime/patches）

- `series` 定序；`pins.json` 记录每个 DSH 版本的 before/after 哈希链；无 fuzz，
  每个 hunk 必须唯一匹配。`targetSets` 显式列出 Android 与 OHOS 公共/平台补丁；
  iOS 消费验证过的共享组合后另做特化，改 `series` 时要复核 iOS 组合链。
- 改一个补丁 = 改 `.diff` + `pins.json --record` + 同名 `runtime/tests/<name>.test.mjs`
  + `docs/maintenance/<name>-contract.md`。改 `DSH_VERSION` 要全量重 pin。
- `zzzzzz-session-deletion.diff` 文件名是 rtbuild 的硬编码开关，别改。

### 5.6 打包与本地连接

- Android Gradle 产品风味 `abi`：`arm64`（真机）/ `x64`（模拟器）；各风味只带自己的
  `runtime/out/<abi>` 资产与 jniLibs，并设 `abiFilters`；`targetSdk = 28`（与 Termux 同，避开
  Android 10+ 对私有目录 exec 的限制），`minSdk = 26`。
- 构建：`tooling/build-apk.sh`（默认 release arm64，`-f x64` / `-f all`），versionCode 按构建时间生成。
- proot 等可执行文件以 `lib*.so` 放 jniLibs，`useLegacyPackaging = true` 使其解压到 `nativeLibraryDir`。
- Android 本地连接：原生层启动 `dsh web --host 127.0.0.1 --port 3080 --no-open`，从 stdout 解析 token；
  Dart 侧 `dsh_client` 用 token 换 cookie（`dsh-auth-<base64url(sha256(authority))>`，30 天，绑定 host:port），
  之后 HTTP/WS 带 cookie、不带 Origin；WebView 兜底直接打开 `http://127.0.0.1:3080/?token=…`。
- iOS Xcode 用 `Runner.xcworkspace`、Swift Package Manager；带本机引擎的构建必须先运行
  `tooling/ios/prepare-engine.sh`。`EngineChannel` 在 App 内启动 NodeMobile 和本机 `dsh web`，
  通过实际端口与 token 建立本机连接；不能把 Android 的固定端口或 APK 安装器带过来。

## 6. 关键约束速查

1. **状态单一 owner**：见 §2.3；跨页状态放 `state/`，UI 不新造全局状态。
2. **不改生成物**：§2.5、§4.1 列出的文件只改输入再跑生成器。
3. **依赖方向**：`ui/` 外不 import `ui/`（守卫只减不增）。
4. **危险操作**：删会话/权限/凭据以 Host 实际回答为准；失败给稳定错误码，不静默吞。
5. **协议改动**：客户端/桥/插件协议改一处要查另一端的调用方与旧版本兼容。
6. **验证边界**：手机操控、PRoot、直接启动、更新安装必须真机验证；桌面/CI 不能替代。
7. **本机限制**：这台开发机是手机，默认不跑全量测试/编译，见 `AGENTS.local.md`。
8. **鸿蒙**：按功能分支、不全局放开；不改变 Android 的运行时字节；新引擎补丁登记进 `pins.json` 的 `targetSets`（§3B）。
9. **iOS 准入**：共享 Dart 通道编译通过不代表 Swift 已注册；查看
   `tooling/ios/CHANNEL_COVERAGE.md`，并在实际 iPhone 上验收手机操控、可选 guest 与覆盖安装。

## 7. 改哪儿：任务导航

| 要改什么 | 先读 | 主要文件 | 检查 |
|---|---|---|---|
| 聊天页/消息渲染 | `docs/design/rendering.md`、§2.2/§2.3 | `ui/chat/**`、`state/chat_state.dart`、`dsh_client transcript.dart` | `(cd app && flutter analyze && flutter test)`（本机禁止全量） |
| 流式性能 | §2.3 | `ui/chat/chat_list.dart`、`chat_rows(_cache).dart` | `app/test/chat/chat_rows*_test.dart` |
| 新建页面/设置项 | `docs/design/settings-ia.md`、§2.2 | `ui/features/feature_catalog.dart`、`settings/index/spots.dart` | 同上 + 截图 |
| 文案/本地化 | §2.5 | `l10n/parts/*.arb`（中英） | `python3 app/tool/l10n_merge.py --check` |
| 用户指南 | §8 | `docs/guide/**` | `python3 app/tool/guide_sync.py --check` |
| 原生插件协议/座位 | `docs/design/native-plugins.md`、`plugin-seams.md` | `plugins/native/`、`plugins/seams/`、`sdk/plugin-kit` | `cd sdk/plugin-kit && npm test` |
| 桥路由 | `docs/design/bridge-contract.md` | `runtime/bridge/**`、`dsh_client dsh_go_api.dart` | `node --test runtime/tests/*.test.mjs` |
| 引擎补丁/升级 | §5.4/§5.5、`docs/maintenance/*-contract.md` | `runtime/patches/**`、`runtime/build-runtime.sh` | `python3 -I runtime/tests/test_patch_dsh.py`（构建需 x86_64 主机） |
| 本机引擎生命周期 | `docs/design/runtime-cold-start.md` | Kotlin `runtime/`、`state/engine_control.dart` | 真机 + `(cd app/android && gradle :app:testArm64DebugUnitTest)` |
| 手机操控 | `docs/design/phone-*.md` | Kotlin `phone/`、`state/phone_state.dart` | 真机 |
| iOS 引擎 / guest | §3.6、`app/ios/README.md` | `EngineChannel.swift`、`runtime/ios/`、`tooling/ios/prepare-engine.sh` | iOS compile/guest CI + 真机启动 |
| iOS 手机操控 | §3.6、`tooling/ios/phone-self-runner/README.md` | `IOSPhoneRunner.swift`、`IOSPhoneCoreDevice.swift`、`PhoneRunner/` | CoreDevice 服务探测、真机截图/输入/返回，逐项核对 |
| iOS 小组件 / 语音 / PiP | §3.6、`tooling/ios/CHANNEL_COVERAGE.md` | `CompanionWidget/`、`VoiceChannel.swift`、`PetOverlay/` | 对应原生/Flutter 测试 + 真机行为 |
| 远程连接 | `docs/testing/remote-*.md` | `packages/dsh_remote`、`app/lib/remote/` | `cd packages/dsh_remote && dart test` |
| 自更新 | `docs/design/self-update-installation.md` | `state/update_state.dart`、Kotlin `update/` | `dart test` + 真机 |
| 插件 SDK | `docs/plugins/README.md`、`sdk/plugin-kit/README.md` | `sdk/plugin-kit/**` | 按序生成链（§9） |
| 插件市场 | `docs/design/plugin-market.md` | `market/**`、`state/plugins/plugin_market.dart` | `cd market && npm test` |
| CI/构建 | `docs/release.md`、`CONTRIBUTING.md` | `.github/workflows/**`、`tooling/**` | 看 `CI OK` |
| 鸿蒙功能/通道 | §3B、`docs/design/harmonyos/README.md` 与对应专题 | `app/ohos/entry/src/main/ets/plugins/`、Dart 侧同名通道、`state/android_features.dart` | `tooling/ohos/check-arkts.sh`、对应 `runtime/tests/ohos/` 或 `tooling/ohos/tests/` |
| 鸿蒙本机引擎 | `docs/design/harmonyos/README.md` §1–§2 | `runtime/ohos/**`、`app/ohos/.../ets/runtime/` | `bash tooling/ohos/run-gates.sh`（`tooling/ohos/GATES.zh.md`） |
| 鸿蒙用户指南 | §8 | `docs/guide/harmony/**` | `python3 app/tool/guide_sync.py --check` |

## 8. 文档索引（docs/）

| 目录 | 数量 | 什么时候读 |
|---|---|---|
| `docs/architecture.md` | 1 | 本文，全局入口 |
| `docs/design/` | 50 | 实现规格/方案：改对应子系统前读（`bridge-contract`、`native-plugins-*`、`runtime-*`、`plugin-*`、`settings-ia`、`rendering`、`roleplay-*`、`pets`、`companion`、`phone-*`、`share-*`、`self-update-installation` 等） |
| `docs/maintenance/` | 61 | 45 份 `*-contract` 是某行为/补丁的合同（复现+边界+测试），改对应代码前读；其余是故障/迁移记录 |
| `docs/testing/` | 14 | 真机/专项验证记录（remote、self-update、android-shell 等） |
| `docs/guide/` | 12+12 | 用户指南（中文/英文），App 内置技能输入；`docs/guide/harmony/` 是鸿蒙版单独一套 |
| `docs/design/harmonyos/` | — | 鸿蒙宿主与本机引擎：`README.md` 是总览和现状，其余是逐个通道/组件的协议与证据 |
| `docs/plugins/` | 23+23 | 插件作者教程（含能力边界、发布与上架） |
| `docs/pets/` | 2 | 宠物包作者指南（格式/导入/校验/发布） |
| `docs/live2d/` | 2 | Live2D 伙伴作者指南（素材包/适配/限制/许可） |
| `docs/release.md` | 1 | 发版、构建号、签名、渠道 |
| `docs/roadmap.md` / `official-parity.md` / `changelog.md` | 3 | 方向、与官方客户端对照、变更记录 |
| `docs/i18n-*.md` / `docs/phone-eval/` / `docs/ops/` | — | 增量文案流程、评测、运维 |

## 9. 验证与 CI

按改动面选命令，PR 里写实际执行结果（完整说明见 `CONTRIBUTING.md`）：

| 改动面 | 命令 |
|---|---|
| Flutter 应用 | `(cd app && flutter pub get && flutter analyze && flutter test)` |
| Dart 包 | `(cd packages/dsh_client && dart pub get && dart analyze && dart test)`；dsh_remote / dsh_tavern 同理 |
| 桥/补丁 | `node --test runtime/tests/*.test.mjs`；`python3 -I runtime/tests/test_patch_dsh.py`；`bash runtime/tests/run-guard-tests.sh "$DSH_PREFIX"`、`bash runtime/tests/run-native-tests.sh "$DSH_PREFIX"` |
| 插件 SDK | `(cd sdk/plugin-kit && npm install && npm test)`（含生成物过期检查） |
| 生成链（改 SDK/bridge/schema 后按序） | `gen-types → sync-bridge → sync-messages → gen-parity → sync-skill` |
| 文案 / 指南 / 教学技能 | `l10n_merge.py --check`、`guide_sync.py --check`、`sync-skill.mjs --check` |
| Android JVM | `(cd app/android && gradle :app:testArm64DebugUnitTest)`（需 JDK17） |
| 真机 | `tooling/dev-run.sh`（热重载）/ `tooling/build-apk.sh`；真机结论不能由桌面替代 |
| 鸿蒙 ArkTS | `tooling/ohos/check-arkts.sh --sdk <OpenHarmony SDK> --hms-stubs`（严格 ArkTS 真编译，Linux 可跑） |
| 鸿蒙全量门禁 | `bash tooling/ohos/run-gates.sh --config <inputs.json> --out <dir>`：运行时、虚拟进程、通道、Flutter、与 main 的 Android 对照；输入见 `gate-inputs.example.json` |
| 鸿蒙真机 | Actions `ohos-aot-<sha>` → `check-arkts.sh --full …` → `tooling/ohos/device.sh install <hap>`（见 `app/ohos/README.md`） |
| iOS | `python3 -B tooling/ios/test-channel-contract.py`；`iOS compile`/`iOS guest`/`iOS UI tour` CI；Xcode unsigned 编译和签名后的真机安装分别记录 |

CI：`.github/workflows/ci.yml` 按 paths-filter 在 PR 上跑改动涉及部分，push `main` 全量，看 `CI OK`；
`ios-compile.yml`、`ios-guest.yml`、`ios-ui-tour.yml` 在相关路径改动时检查 iOS 编译、运行时与界面（含 `main`），
不能代替签名和 iPhone 真机结果；`ohos-compile.yml` 在推到 `claude/harmonyos-ohos`、`ohos/**` 时于 macOS 编鸿蒙 Dart 产物（`ohos-aot-<sha>`）；
`pr-gate.yml` 关闭外部 PR；`goldens.yml` 手动渲染 golden。
本机（手机）默认只做静态阅读/轻量检查，不跑全量测试/编译（`AGENTS.local.md`）。
