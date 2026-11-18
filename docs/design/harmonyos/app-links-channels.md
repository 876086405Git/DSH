# P3b：时区、回前台和深链通道

基底 c818155。**未编译、未在真机核实。** 本包实现的行为以以下表格为边界；不把文件导入或完整 P3 宣称为已完成。刷新率一节写于之后，同样没在真机核实。

## 协议

| 通道 / 方法 | 鸿蒙行为 |
| --- | --- |
| `dsh/app.getTimeZoneId` | 公开 `i18n.getTimeZone().getID()`，返回系统时区字符串；查询失败返回 `ohos_timezone`。 |
| `dsh/app.bringToFront` | 仅启动当前绑定 UIAbility 自身的 bundle/name；系统拒绝后台拉起或窗口已分离时明确报错，不承诺绕过系统限制。 |
| `dsh/app.setRefreshRateMode` | `auto`、`max`、`system`，见下面的刷新率一节；其他值返回 `ohos_unsupported`。 |
| `dsh/app.scanQrCode` | Scan Kit 默认界面扫码 `scanBarcode.startScanForResult(UIAbilityContext, {scanTypes: [QR_CODE], enableMultiMode: false, enableAlbum: true})`，返回 `originalValue`；用户关闭扫码页（1000500002）返回 null。非前台或无 ability 为 `no_ability`，已有扫码页为 `busy`，无 SysCap 或 Scan Kit 加载失败为 `unavailable`，其他错误或空结果为 `failed`。Scan Kit 只在首次扫码时动态加载。**UNCOMPILED_HMS**，未在真机核实。 |
| `dsh/app.setFrameActive` | `auto` 下开关保活定时器，返回空；约每秒重发一次 true 作为续期。 |
| `dsh/links.ready` | 返回 true，再按收到顺序回放等待中的链接。重复 ready 不重放。 |
| `dsh/links` 原生调用 `link` | 参数必须是 Map `{uri: string}`；外来文件尚无可读副本时为 `{error: 'unreadable', name: null}`。不是裸字符串。 |

精确消费方是 `app/lib/links/app_links.dart` 中的 `AppLinks.parseNativeLink`，以及 `app/lib/performance/refresh_rate.dart`、`app/lib/state/app_foreground.dart`、`app/lib/ui/features/schedule_editor/time_zones.dart`。本包只读取这些文件，没有改 Dart/UI 或 Android。

**时区还有 Dart 接线门：** c818155 的 `detectDeviceTimeZone` 仅在 `Platform.isAndroid` 时转入上述 MethodChannel；OHOS 当前不会走这条分支。主线需让鸿蒙也调用同一原生方法，才有端到端的系统 IANA 时区检测；仅应用本包不能据通道测试宣称该页面已接通。

## 深链与生命周期

EntryAbility 增加 `singleton` 和 `dshgo` scheme 的 viewData/browsable skill，用于已有 `dshgo://forum/auth?...`、分享码和 App 页面入口。仅注册自己的自定义 scheme；没有未经域名配置的 https App Linking 声明。若系统显式送来 http/https viewData，通道按原样交给现有 Dart 路由器决定，原生层不消费登录凭证，不记录 URI。

初始 Want 来自公开 `UIAbility.launchWant`；热启动来自 oh-flutter 的 `NewWantListener`。按 Ability 对象记录已取的冷启动，用弱引用集合避免长期持有旧窗口；有意重复到达的热链接不会按 URL 去重。等待队列在进程内保留，避免冷启动已取走、Dart ready 前引擎重建导致链接消失。队列交给当时已 ready 的 `dsh/links`，不是磁盘持久化；杀进程后的系统重放与多窗口路由仍需设备验证。

卸载插件时移除 Ability listener 和两条 MethodChannel handler；旧回调在没有绑定窗口时被忽略。注册放在固定 oh-flutter 的空 `super.configureFlutterEngine` 前，使用独立的前后文，与 P2、P3a 的注册增量可按普通 `git apply` 叠加。

v2 增加公开 viewData 的外来 file URI 复制，详见下节。content URI 保留 unreadable；该方案不实现 dsh/share 的系统分享载荷。

## 刷新率

公开 `@ohos.window` 声明没有可对任意窗口设置 Android preferredDisplayMode 的等价方法。`UIContext.requireDynamicSyncScene` 返回的是 ArkUI Swiper/Marquee 场景，不能当作 Flutter XComponent 的刷新率控制。`updateRefreshRate` 是向引擎报告当前值，不改变面板刷新率。

能用的杠杆在引擎里。固定 oh-flutter 在自己的 `OH_NativeVSync` 上投票（`ohos_vsync_voting_mgr.cpp`）：手指按下或抬起 100 ms 内 120；从没碰过或抬起超过 3 秒期望 60（`{30,120,60}`）；中间只有滚动、路由转场和 Hero 的动画票，否则 `{0,0,0}` 交给系统。App 自己的弹簧、Sheet 和流式输出不投票。`LTPODispatchHighFrameRate()` 是嵌入层给返回键用的公开方法，对引擎来说等于一次抬起，所以约每 80 ms 调一次就能留在 120 那一支。

| 模式 | 行为 |
|---|---|
| `auto`（默认） | Dart 连续看到动画节奏的帧（间隔不超过 50 ms，连续 3 个间隔）才 `setFrameActive(true)`，动画结束 0.7 秒后 false。闪烁的光标每秒约 2 帧，不会启动也不会撑住它。动作开头几帧仍是原来的帧率，手指引起的动作不受影响，因为此时引擎本来就在 120 |
| `max` | 前台一直调用。官方最佳实践（`bpta-ltpo-description.md`）明确不建议长期锁 120，所以只是用户手选的选项，不是默认 |
| `system` | 不调用，引擎和系统自己决定 |

`OhosFrameRate.ets` 的定时器在这些情况下停：inactive、换模式、`onBackground`、Ability 分离、引擎分离、`thermal.lightweight` 为真（降温后恢复仍需要的）、引擎已分离或调用抛错（到引擎换掉为止不再启动）。`auto` 还有租约：连续 50 次调用（4 秒）没有等到 Dart 续期就自己停，这样 UI 线程卡死也不会一直留在 120。

每次调用引擎都打一行 INFO（`nativeLTPODispatchHighFrameRate`）并投递两个任务，其中一个延迟 3 秒，也就是运行期间约每秒 12 行。这行只能靠改引擎去掉。手指按住时调用也会清掉引擎的 `is_touch_down_`：按住不动超过约 0.8 秒后再拖动，开头约 3 帧不在 120。设备上的检查方法见 [first-device.md](first-device.md)。

## 固定官方接口来源

- [OpenHarmony interface_sdk-js 固定修订](https://github.com/openharmony/interface_sdk-js/tree/8a86234f0d542e5062e24e948652f5a484d90904/api)：`@ohos.i18n.d.ts` 的 getTimeZone/getID；`@ohos.app.ability.UIAbility.d.ts` 的 launchWant；`application/UIAbilityContext.d.ts` 的 abilityInfo/startAbility 与 viewData/browsable 规则；`@ohos.window.d.ts`、`@ohos.arkui.UIContext.d.ts`。源码归档 SHA256 `772f9db136c163e7b0ad0111230768f547fa9a7acc230c115a88aea8565f1099`。
- [oh-flutter 官方仓库](https://atomgit.com/oh-flutter/flutter_flutter)，固定修订 `e5f752df3e25ec897da3c98a74bcced7c21b0bd3` / `3.47.9-ohos-1.0.0`：AbilityAware、AbilityPluginBinding、MethodChannel、FlutterAbility、FlutterView、FlutterNapi。核对接口和生命周期，没有复制其他移植插件实现。
- 本仓库 Android LinksPlugin 仅用于协议对照；其 Map 形状与 Dart 解析相符。Android 文件字节、recipe、版本串和依赖均未改。

## 验证

Linux 直接将产品 `.ets` 做 TypeScript 语法擦除，运行其方法，OS 与 Flutter messenger 是明确替身。9 项测试覆盖通道名、Map 形状、ready 顺序、冷启动仅消费一次、热链接不误去重、引擎替换、退订、非法 scheme/过长 URI、平台同步异常和异步拒绝、系统刷新模式边界。初稿 6/9；冷队列丢失、缺冒号 URI、同步 startAbility 异常三项先失败，修后 9/9。

```sh
# 在原锁准备的 runtime/ohos/process 中 npm ci，然后从仓库根运行：
OHOS_TYPESCRIPT_PREFIX=/absolute/runtime/ohos/process \
  node --test --test-isolation=none runtime/tests/ohos/app-links-channel.test.mjs
```

尚需主线：API 26 hvigor/ArkTS 编译；真实 StandardMessageCodec Map 往返；浏览器登录回调冷/热启动、onboarding 等待、引擎重建与图标重开不重放；后台 startAbility 被系统拒绝时的提示；系统时区切换；验证没有新增持续高刷或空闲唤醒。


## v2：公开 viewData 的外部单文件导入

本版以c818155为基底，完整替换05号P3b，保留时区/前台/刷新率/登录回调边界。只处理公开 `ohos.want.action.viewData` 的单个 Want.uri，要求只读授权flag；系统真正允许读取与否以 fs.open 的结果为准，flag本身不是授权证明。没有读取猜测的Want.parameters键，没有申请广泛文件/媒体权限或持久URI权限。

接收方声明 FileOpen：general.file、general.plain-text、application/octet-stream、application/pdf、image/*。这些是公开文件处理声明；具体文件管理器是否把某个扩展名匹配到本App，尤其.dshgo，以及目标SDK对混用UTD/MIME的匹配仍待主线实测，不声称全类型系统关联已完成。显式已授权Want的处理与该匹配门分开。

URI只接受外部 file:// authority；拒绝自身bundle（含大小写别名）、空authority、点段authority、百分号/凭据/端口authority、点路径分量、NUL、query/fragment。不接受原始路径或Android content URI。路径经OS按原始URI只读打开，不把外来路径拼进自己的源文件路径。fs.open含NONBLOCK，随后必须真实fstat为普通文件且不超过30MiB；对普通文件的有效授权和provider行为仍需设备测试。

最多4个在途复制；后续文件明确unreadable，不额外持有FD。每次以公开mkdtemp创建独占私有cache目录，分块256KiB读写并处理短IO；零进展、提前EOF、复制前后size不一致、fsync失败均不交付成功。FD关闭后才可见成功事件。名称按UTF-8完整码点限制240字节，保留不超过32字节的扩展名，使合法长中文.dshgo文件仍进入原Dart扩展名路由。副本是本地空authority的file:/// URI，供Dart File读取；它不用于跨App授权，不能换成带bundle的OS fileUri URI。原始文件/临时授权消失后，完成的副本仍可读。

全部到达先占一个顺序位置。慢文件复制期间，后来的链接等待；复制完成/失败后从队头依次交给当前ready引擎。引擎更换保留在途结果及到达顺序；冷启动Want按Ability只消费一次，热到达不误去重。新引擎不回放已交付事件，旧engine detach不会抹掉新接收者。文件读FD立即请求，不等待先前文件完成才开始申请授权。

成功缓存交由系统cache生命周期管理，本版没有全局配额/持久回收账本；不承诺进程SIGKILL后删除临时目录。失败只删除本次叶文件，确认仍为空的非链接目录后才调用OH递归rmdir。这里不是对同UID恶意并发写者的目录删除防御；与同进程插件共享信任边界。源FD保持inode身份，但等长原地修改仍可能形成混合内容，不声称事务快照。异步OS文件I/O没有已证的硬超时，4个在途上限不等于每次操作时限。

### 证据与边界

固定官方 [文件处理启动文档](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/application-models/file-processing-apps-startup.md) 明确 Want.uri、只读flag、FileOpen配置、fs.open消费；文件SHA256 `2be05d3360e0b469d327cb2ef997beb3541723b1b45ecfb5d13b5f6742174490`。同修订[文件分享](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/file-management/share-app-file.md)定义跨应用file URI及临时授权。完整来源metadata随包，不复制其他鸿蒙移植实现。

Linux真实文件、fd、短读短写与实际产品ETS方法执行覆盖16项：此前9项保留，新增正常中文700003字节/原文件删除、冷文件+慢复制+引擎替换、逐个非法authority/路径/授权拒绝、真实oversize/目录/EOF/零写/fsync失败和清理、4复制上限及到达顺序、零字节和源增长、长中文名称保留扩展名。旧P3b对正常外部文件返回unreadable的先失败记录保留；首次新增测试一处手写大写bundle多了一个字母，已改为从真实bundle生成大小写变体，产品不因该测试拼错而改变。非法URI每个单独等待完成，避免被并发上限代替路径校验。

公开OH固定声明+已核Flutter最小签名的TS5.9.3检查用于发现公开成员/参数错误。该检查不是ArkTS/hvigor；FileUri名称解码、OS授权寿命、实际挂载路径、FileOpen匹配、真实StandardMessageCodec与后台到达均待主线API26编译/真机验证。系统分享面板、share_plus结果与OH WebView属于另份BLOCKED接线记录，不计入本包完成。
