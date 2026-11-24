# 悬浮伙伴：同一宠物窗口的第二种画法

2026-11-12。**未在真机上验证**，下面的行为依据源码、单元测试和官方文档，真机要看的步骤在文末。

悬浮伙伴由原生悬浮窗、Dart 侧的会话与本地服务、WebView 里的舞台页三部分组成，还依赖 [创意工坊 App 数据层](workshop-app.md) 里 `CompanionPackStore` 的完整性检查与变更通知。这几部分按同一份合同工作，不能把其中一部分当作独立功能。

## 结论与证据边界

默认仍为像素宠物。用户明确选择伙伴后，`PetOverlay` 继续拥有唯一窗口、服务、显示策略、手势、吸边、气泡、问一句、今日隐藏和截图隐藏。`PetView` 容纳一个 WebView；没有第二个悬浮服务或菜单。`placeMenu` 不改。

在 Application context 里用 WebView、窗口硬件加速和透明 WebGL，有官方接口支持；并未证明 Android 8–16 所有厂商组合都成立。非 Activity context 不提供部分 Activity 功能，本舞台不使用 JS 对话框 / 自动填充。实际 `isHardwareAccelerated` 为假即进入一次恢复 / 像素回退。[A1–A3] 系统强制隐藏 overlay 是否及时送达可见性回调，仍须设备证据，不能据此承诺未知隐藏期间一定释放。

伙伴小屋与悬浮窗可能共享 renderer：小屋后台只暂停 JS，Android 要求每个受影响实例分别处理退出，而锁定的 `webview_flutter_android` 4.14.1 的原生 `WebViewClientImpl` 没有覆盖该回调，不能靠浮动实例返回 true 保护另一实例。[A4、A5] 小屋的 WebView 在加载前由 `IslandPlatform.attach` 接管并核对确认，renderer 退出和换包时自行收拾，见后文「小屋与页面接线」。这部分只在假 WebView 平台上跑过 Dart 测试；「小屋 → Home → 浮动」下 renderer 故障后宿主存活仍须设备证据，不能写成已验证。

## 选择与偏好

`PetPrefs` 保存 `pet.overlay_renderer`（`pixel` / `companion`）及 `pet.overlay_framing`（一个 JSON，`zoom` 和 `y` 同时写入）。旧值或未知模式为 `pixel`；`zoom` 须有限且在 (0, 4]，`y` 在 [-1, 1]；损坏的取景值只回到默认取景，不影响已明确选择的 renderer。默认 `zoom=0.9`、`y=0`，是可配置的工程取景值，不是可用性测量结论。

## 设置入口

`PetOverlaySettingsSection`（`app/lib/ui/pets/overlay_settings_tile.dart`）里有两行，都是与「显示时机」相同的 `SettingsSegmentTile`。

**「悬浮窗里显示」**两段：像素宠物 / 小屋里的她（`companionNameProvider` 有名字时写名字）。

- 读取与小屋相同的 `application-support/companion` 目录，用 `unavailableReason` 检查固定 runtime 聚合摘要、角色入口、引用和 moc 头版本；不自动下载，不把检查成功当作 Core / GPU 已运行。
- 未安装或不完整时整条不可选，副标题按三类说明原因：没有角色包（`companion_runtime_missing`）、角色包不完整或运行库不对（其余完整性码）、其他（存储、通道、原生、本地服务及未知码）。已经选中时仍允许切回像素。
- 选中后副标题依次是加载中、原因、回退、耗电说明。
- 原生报告 `companionFallback` 时，副标题后跟一个「重试」，调 `CompanionFloatController.retry()`：会话对同一选择重走 `_refresh`，原生收到新页面即开始新的故障周期。

**「取景」**只在选中伙伴时出现，两段写入 `PetOverlayFraming` 的预设：

- 全身：`zoom=0.9`、`y=0`。
- 半身：`zoom=1.8`、`y=0.5`。半身由舞台投影推出（模型高 2、以 0 为中心，屏幕 `y=(模型 y−floatY)×floatZoom`），未在设备上调过。

## 页面、本地服务与错误

`CompanionFloatSession` 按选择代与 store revision 丢弃迟到的检查 / 页面。像素默认不解析包、不开 socket、不创建 WebView。选择期间页面由随机令牌的 `CompanionServer` 提供；Dart 向原有平台通道发送 `configureCompanion(page, notice)`，关闭发送 `page=null`。确认只表示原生接纳，不表示首帧已显示。原生状态增加 `companionRendering`、`companionFallback`、`companionProblem`；未选择时不改变原来的像素状态 map。

`setup` 的 `MissingPluginException` 返回 `companion_native_unavailable`；`PlatformException` 返回 `companion_channel_failed`；文件、socket 错误分别为 `companion_storage`、`companion_server_failed`。错误只含稳定码，不含令牌 URL、文件路径或原始异常。原生启动、硬件、协议、上下文和 renderer 故障也只传固定码。

`CompanionPackStore` 同根实例共用队列、`revision` 与 `beforeChanges`。变更先公布 revision 并等待 reader 停止，再移动目录。float hook 先使旧代失效，串行等待原生销毁确认与 server 请求清理；hook 内不能再 await store 操作，否则会自锁。关闭失败仍保留页面清理责任并阻止目录变更。provider 只保留工厂，不长期缓存失败的 Future；新的显式选择或退出后重新进入设置可重试，活动 Session 保留成功的 store。旧代即使晚取得页面，也只关闭自己的页面，不把 capability 交给原生。

`CompanionServer.close` 拒绝新处理、强制关闭 socket，并等待已跟踪的 handler。异步 asset / type / length 读取恢复后先看 `closed`；旧 handler 不得在包替换后重新打开新目录中的文件。小屋也按同一 reader 合同接线，见后文。

## 舞台协议与资源

页面使用 `mode=float`；房间模式保留原路径。float 不创建 scene 的 2D context，不画背景 / 物件，不接房间触摸、语音、道具、昼夜计时或自动情绪事件。舞台、WebView 和窗口均透明。

每次提交间隔至少 1000/30 − 2 毫秒，由 `FrameGate` 把关；这 2 毫秒是 rAF 抖动容差，与房间渲染循环相同。设备刷新率与调度可能使实际帧率更低，上限不等于稳定 30fps。float 按屏幕密度渲染（DPR 上限 4；视口最高 640 view px，所以缓冲区最大 480×640），`maxTexture=2048`、`maskSize=1024`、`antialias=0`。最初是 DPR=1、贴图 1024、遮罩 512，在 3 倍屏上被放大三倍，真机上明显发糊，所以改了；这些仍是成本控制选项，不是内存或功耗保证。模型像素读回每次提交执行，复用 RGBA buffer，只有边界变化才向原生发消息。

原生 → JS：`petState(state, reduceMotion)`、`freeze`、`thaw`、`dispose`。JS → 原生：`floatReady`、`floatBounds(width, height, bounds)`、`floatError(code)`、`floatResume`。bounds 的 right / bottom 为开区间，null 表示全透明。ready 只说明模型建立，不保证异步 shader 已完成。

折叠 / 变暗的 freeze 在 ready 且收到第一个非空像素边界后才暂停 rAF，保留已画出的图；否则冷启动就变暗可能冻结在空白并触发超时。加载期间取消折叠不再冻结。屏幕关、真正隐藏、省电和销毁走释放路径，与保留图像的 freeze 不同。`reduceMotion` 随 `petState` 动态更新，停止已排动作，无需重载页面或重置故障预算。

`dispose` 幂等：先标记失效、abort 自有 fetch、停止 rAF，再 release 模型，最后尝试 `WEBGL_lose_context`；异常不能阻止原生收到固定错误。加载器在 await 后核对失效，晚到的 bitmap 必须 close，不继续创建纹理；晚到的 motion / physics / pose 不再分配模型资源。模型 release 本身不证明所有 app 创建的纹理或 Framework 静态 shader 都已释放。固定的 Framework 5-r.5 里 `generateShaders` 返回 void，内部独立异步 fetch，没有接本页的 AbortSignal，所以不能安全地把全局 dispose 当同步取消。最终清理由 context loss 与原生移除 / 销毁 WebView 完成。[A6–A8]

## 状态映射

只采用 `character.json` / adapter 明确给出的 emotions / actions。不存在的动作保持待机，不借房间通用动作表冒充模型能力；同状态重送不反复触发动作。这条只约束宠物状态的映射：单击的反应和小屋里一样用通用表（`TAPS`、默认表情和动作），不然没有自带映射的角色点哪儿都一个样。

| 宠物状态 | 已声明时的表情 | 已声明时的一次动作 |
|---|---|---|
| idle | calm | 无 |
| thinking | confused | tilt |
| working / juggling / sweeping / carrying | calm | nodSmall |
| attention | happy | nod |
| notification | worried | lookUp |
| error | sad | shake |
| sleeping | sleepy | yawn |
| waking | calm | stretch |

## 一个窗口内的几何与触摸

内部 WebView 视口固定，以 `EXACTLY` 测量；窗口只取实际 alpha 非零像素的包围盒。WebGL 原点在左下，报告先转左上；原生按 buffer / view 尺寸比向外 floor / ceil。包围盒外点击交给下层应用，盒内透明孔洞仍属于此窗口，不声称逐像素穿透。

设窗口坐标为 P、旧包围盒左上为 B、新左上为 B'，更新 P' = P + B' − B，内部视口原点 P − B 因此保持不动。同步修正 `dragStart` / `dropAt`，拖动时仍按原安全区域 clamp。`fullReach` 是固定视口相对裁切窗口的范围，让原来的吸边 / 菜单 / 气泡读取同一 `PetFrames` 合同。这个恒等式不是所有密度 / 屏幕 / 厂商场景的设备证明。

启动尚无真实边界时窗口 alpha=0 且 `NOT_TOUCHABLE`；不能让透明的完整视口挡住其他 App。首个非空边界之后恢复触摸。后来全透明时使用不可触摸、alpha=0 的最小窗口，仍继续渲染等待再次可见。15 秒内没有首个非空边界视为启动失败，此数值是工程超时。

`PetView` 父层截获手势，WebView 不聚焦、不直接收触摸；继续用 `showMenu`，不改 `placeMenu`。单击由原生换算成视口内 0–1 的坐标，以 `tap` 命令交给舞台，走小屋里轻点她的同一套反应（按头、脸、身体分区；不画小屋的标记），目光在点的位置停 0.7 秒；反应的表情到期后回到当前宠物状态的表情，而不是 calm。系统双击时限内、双击容差内的第二下才打开对话（`PetTaps`，像素宠物同样），第一下的反应照常播。无障碍的点击动作仍是打开对话。视口初始高度为选定像素宠物高度的四倍，经 640 view px 和「安全高度扣除两边吸边留白」裁切；宽为高的 0.75 倍，并受扣除同样留白后的安全宽度约束。上限扣除的是吸边留白而不只是系统 inset：视口占满安全高度时 `EdgeSnap` 仍在顶端加一份留白，只扣系统 inset 会使实际下沿越界；现在的上限让整个 `fullReach` 都能放入既有吸边区。系统报告的区域若在两边留白之间连一像素都放不下，就暂不创建伙伴 WebView，保留像素路径，等待后续有效区域，不消耗故障重试。默认取景仍可调，小屏 / 旋转与厂商仍需实测。

## 吸边、收边与她的菜单（2026-11-24）

**未在真机上验证。**原来吸边按整个视口留白，她画出来的身体离屏幕边还隔着视口两侧的透明部分（全身取景时约是视口宽的三成），看着像悬在半空、不贴边。现在按裁切后的窗口吸边：

- 第一帧非空边界到达时，窗口按包围盒停到边上（`EdgeSnap.hug`，离安全区边 2dp）；之后边界变化仍保持视口原点不动，只跟着裁切，所以她动一下手不会把整个人推来推去。拖动结束、取消拖动都按包围盒重新吸边，记住的仍是左右边和高度比例。代价是之后包围盒朝外长出来时，窗口可能超出边几像素，由屏幕裁掉。
- 只在「她一直在」时收边：没有触摸、没有气泡满 30 秒（此时已变暗），窗口滑到一半在屏幕外；甩向一边松手、菜单里「收到边上」会立刻收，她正显示的那条回复气泡一起收起，这条回复后面流式来的字不再把她拉出来，新的回复会（规则在 `CompanionTuck`，有 JVM 测试）。点一下只把她拉回来，不打开输入条；有气泡要说、长按菜单、打开输入条时立刻停到边上，正在滑也一样，气泡当场出来。从收着的状态拖动时先回到边上再跟手，不会卡在原地。收边靠窗口坐标超出屏幕（`FLAG_LAYOUT_NO_LIMITS`），厂商是否会把窗口夹回屏幕内要真机看。
- 问一句的输入条按她的包围盒放在旁边，不再按视口。
- 常驻时长按菜单换成她的：聊两句、去小屋、别看屏幕（看屏开着才有，调用通知里「暂停看屏」同一个开关）、停止任务（有任务时）、收到边上、隐藏一小时（沿用今日隐藏的机制，一小时后自己回来）。像素宠物的菜单不变。

包围盒里的透明部分仍然挡触摸：Android 12 起，系统按窗口外框判断触摸是否穿过了别的应用的悬浮窗，外框内透明处漏下去的触摸会被拦下，所以 `setTouchableRegion` 这类逐像素穿透在 `TYPE_APPLICATION_OVERLAY` 上靠不住，只能让窗口本身贴着她画出的部分。

## 显示与故障生命周期

选择有效、未回退、策略为 SHOWN、屏幕 interactive、系统报告 shown、非截图、非省电时才创建 renderer。已知隐藏、今日隐藏、暂停、熄屏、截图和省电会销毁，恢复时新建。`WebView.onPause` 不保证停止 JS，不能只靠它；也不调用影响所有实例的 `pauseTimers`。[A1]

故障预算属于选择的页面 capability，不属于每次窗口创建。第一次当前代的 context loss / renderer gone / 加载失败重建一次；第二次回像素，提示一次。正常 hide / resume 不重置预算，重复的旧代消息不消费预算。显式关闭或换包 / 取景产生的新 capability 开始新周期。故障的 WebView 不复用。[A4]

此功能复用已有服务与窗口；没有「加一个窗口提高后台存活」的保证。

## 小屋与页面接线

1. `CompanionStage`（`app/lib/ui/companion/companion_stage.dart`）在设置 navigation delegate 后、首次 load 前，用 `WebViewGuard.identifierOf` 取 Android WebView id，直接调 `IslandPlatform.attach` 并核对布尔确认；为假则以 guard 失败，不加载、不显示。`WebViewGuard.attach` 的 void 完成不能证明 attach 成功，所以不经它；不需要升级插件。只在 Android 上要求守护：其他平台的 attach 恒为假，而那里的控制器同样带 `webViewIdentifier`，一律要求会让小屋在那里打不开。
2. 舞台订阅 `IslandPlatform.events` 的 `IslandRendererGone`。所有 WebView 共享 renderer，任何实例的报告都算自己的，但只在本实例已守护后处理，不消费 float 的故障预算。收拾由 `_retire` 完成：代计数加一，撤销 timeout 与 controller 的 ready / WebView，移出 `WebViewWidget`，等 `CompanionServer.close`，再报失败。旧 `start` 在各阶段的 await 之后核对代，旧页面的 JS 消息和加载错误按代丢弃。旧 id 的 destroy 排在移出 widget 的那一帧之后，不等待。
3. 舞台在 `_start` 开头、起 `CompanionServer` 之前注册 `store.beforeChanges`，hook 即 `_retire`，不进入 store 队列。注册早于 server，是为了不留「server 已起、hook 未挂」的空窗；被换包抢先的 `start` 在 server 起来后发现代已过期，关掉它并放弃。dispose 不立即注销 hook，等 server 关完再注销：`CompanionPage._removePack` 先切到 setup（舞台随即卸载）再调 remove，立即注销会让目录变更跑在 server 关闭之前。hook 内不等 destroy：App 不可见时没有帧，在 store 队列里等一帧会把队列挂住；读者合同由 server 关闭满足，WebView 只经它读包。
4. 被 `_retire` 的舞台不再加载。`CompanionPage` 收到失败后进入失败页，舞台离开树，回到 stage 阶段时建的是新实例。失败页除原来的导入外，在角色包仍在时提供「重试」（`_retryStage`）。renderer 退出与换包这两种原因不显示给用户，用不带原因的说明，原因只进 debug 日志；其他原因照旧显示。页面不在 stage 阶段时忽略舞台的失败回调，移除角色包时 hook 报的失败不会把 setup 页翻成失败页。`_removePack` 捕获 `companion_readers_busy` 等失败：角色包保留，setup 页显示提示。
5. 小屋开着时由同根的另一个 store 换包，小屋进失败页，需重试或重新进入；页面不随 revision 自动重建。仅靠后台 pause 或「通常不共存」不能取代每个受影响实例的 guard；前后台切换有异步交错。
6. 验证约定：Dart formatter、analyzer、全量 CI 和受影响的 golden 照项目惯例执行；生成物不手改。若舞台 corpus 的固定摘要检查受影响，按原工具重录并审核，不把缺 Core 的 mock 当 corpus 实跑。

## 测试覆盖

- `app/test/companion/companion_float.test.cjs`（`node --test`）：纯帧门、alpha 边界、状态映射，并在隔离 VM 中执行真实 `stage.js` 的控制流，包括 float / room 两种模式、首次冻结、动态 `reduceMotion`、取消、晚到的 bitmap / motion、release 异常与 context loss。Core、WebGL、fetch 和窗口边界用替身；通过不证明实际渲染。
- `app/android/app/src/test/kotlin/io/github/ccch1mneyyy/dsh_app/pet/CompanionFloatPolicyTest.kt`：端点解析、每个选择一次重试和一次回退、各隐藏 / 省电门、变暗启动、几何与吸边、包围盒变化时视口原点不漂移。
- `companion_float_session_test.dart`、`companion_server_test.dart`、`companion_workshop_test.dart`：会话的选择代与迟到结果、重试、清理所有权、本地服务只读与回环、换包时 `close` 等待晚到 handler、store 的换包门与 revision。
- `companion_stage_guard_test.dart`、`companion_room_guard_test.dart`：小屋的 attach 顺序、renderer 退出收拾、换包等待、失败页与「重试」。
- `pet_overlay_renderer_prefs_test.dart`、`overlay_settings_tile_test.dart`（含 `overlay_settings_light.png` / `overlay_settings_dark.png` 两张 golden）、`overlay_channel_test.dart`：偏好、设置入口与原生通道。

故障时序的测试用屏障控制先后，不靠连续切换碰概率。需要覆盖的场景：切像素时检查晚到、原生确认晚到、换包期间关闭失败、store 工厂重试、被杀重启、旋转、所有菜单 / 气泡 / 问一句行为和像素默认路径。

## 真机上要看的

记录构建 SHA、Android API、厂商 / GPU、WebView provider 与版本、实际窗口类型、密度 / 刷新率。覆盖 Android 8 / 10 / 12 / 14 / 16 可取得的组合并明确缺项。

1. 硬件加速、透明、矩形触摸、小屏 / 大字体 / 横竖屏、熄屏、省电、今日隐藏、截图和系统强制 overlay 隐藏。
2. 「小屋 → Home → 浮动」与网页 / 图表共存时的 renderer 故障：宿主必须存活，首次至多重建一次，同一选择代再次故障只有一次回退提示。
3. 内存：同时记录宿主与 renderer 的 PSS，含加载峰值、稳定态和销毁后，不能只量 Dart heap。估算纹理下界为 4 × 宽 × 高，另加 mip、mask / FBO、读回和 Core；这不是实测上界。
4. 功耗：同设备、亮度、网络、温度，固定角色，pixel / float 配对 30 分钟，每组至少三次，分别测 idle 与动作，记录帧率、温升、电池 / 能量统计。没有这些测量，不给省电比例或驻留内存数字。

## 还没有做的

- 上面的设备步骤都还没有执行。
- 若直接透明 WebView 被设备证伪，保持像素回退并另选方案。软件 Canvas 上 `WebView.draw` 不能当可靠的 WebGL 位图替代，Chromium 明确列出软件绘制限制。[A9] `VirtualDisplay` / `SurfaceTexture` 或原生 SDK 是需另行测量和许可评估的方案，目前没有采用。

## 一手资料

访问日期 2026-11-11；官方契约和固定源码不等于全设备验证。

- [A1] https://developer.android.com/reference/android/webkit/WebView
- [A2] https://developer.android.com/reference/android/view/WindowManager.LayoutParams
- [A3] https://developer.android.com/develop/ui/views/graphics/hardware-accel
- [A4] https://developer.android.com/reference/android/webkit/WebViewClient#onRenderProcessGone(android.webkit.WebView,%20android.webkit.RenderProcessGoneDetail)
- [A5] https://github.com/flutter/packages/blob/9854cd5607da4001f2dd3cbdcd6903202d28958c/packages/webview_flutter/webview_flutter_android/android/src/main/java/io/flutter/plugins/webviewflutter/WebViewClientProxyApi.java
- [A6] https://github.com/Live2D/CubismWebFramework/blob/198a3769c26ca3d7b600e932590433badd392edd/src/rendering/cubismshader_webgl.ts
- [A7] https://docs.live2d.com/en/cubism-sdk-manual/use-framework-web/
- [A8] https://registry.khronos.org/webgl/extensions/WEBGL_lose_context/
- [A9] https://chromium.googlesource.com/chromium/src/+/HEAD/android_webview/docs/software_draw_deprecated.md
