# iOS W3 手机操控：主线接入合同

本合同最初对应 ios5 的 W3 / ADDENDUM-01–06，原组合基底为
`a394e435f90ad97e59d7886f39520d1b674afcb6`。本次按 ADDENDUM-09 §3.1，
以 `ae4b0564d73e17d8c134c8d84bf05f367feca995` 补充第 2 节配对存在性与后端选择，
其余章节保留已有范围。它描述原生接口与实现边界；
**不是已完成 Dart 设置页、Apple 编译或真机验收的声明**。本轮不改
`app/lib/ui/`、`app/lib/l10n/`，也不改变 Android/OHOS 的接口行为。

## 1. 主线需要接入的入口

设置使用 `MethodChannel('dsh/phone_link')`，订阅
`EventChannel('dsh/phone_link/events')`。这些是前台设置入口，不能注册成模型工具。
首屏读 `status`，以后用事件刷新。`status` 直接返回 map；其余已实现方法返回
`{ok: bool, code: string, status: map}`，不支持的方法返回 Flutter 的 not-implemented。

一次只进行一个设置操作。导入、开启开关、准备镜像、恢复剪贴板等入口会自己显示
原生说明/选择界面；Dart 不要叠加一个会自动点击或代答的确认层。等待方法返回期间
用 `operationPending` 禁用重复提交，保留取消入口。离开 App 会取消尚未回答的
选择框或文件选择；不能把一次切回来当成同意。

| 方法 | 参数 | 行为与界面要求 |
| --- | --- | --- |
| `status` | 无 | 只读；无凭据、原始文件名、私钥、配对标识或剪贴板内容 |
| `importPairing` | 无 | 原生先问“记住在这台手机上 / 只用这一次”，再用 Files 选择一个 Remote Pairing plist |
| `migrateLegacyPairing` | 无 | 同样先问保存方式；只迁移旧 `Documents/pairingFile.plist`，保存成功后删除该旧位置 |
| `clearPairing` | 无 | 需前台；先使当前使用失效并关掉本机连接与 XCTest 开关，再删除本 App 持有记录及历史位置；不替用户删除外部原文件 |
| `setEnabled` | `{enabled: bool}` | 本机开发者连接，默认 false；开启需前台原生确认及有效记录，关闭使当前任务/连接失效 |
| `setXCTestEnabled` | `{enabled: bool}` | XCTest 增强，默认 false；开启需独立原生说明确认，提醒某些 App 可能要求重登或拒绝；不自动安装 helper |
| `setAppBackend` | `{app: bundleID, backend: 'automatic'|'coredevice'|'xctest'}` | 需前台；最多 512 条；`automatic` 删除该条规则；XCTest 必须已明确启用 |
| `checkConnection` | 无 | 需连接开关；只检查已存在的服务，不自动下载或挂载 DDI，不启动屏幕共享/输入会话 |
| `mountDDI` | 无 | 需前台另一次原生确认；按设备/服务选择固定资产，缺缓存时下载、核验、个性化并挂载；不抢占已有其他镜像 |
| `cancelPreparation` | 无 | 取消本次设置操作，只停止其自己的 native owner；旧取消不能停止新的任务 |
| `restoreClipboard` | 可选 `{overwriteChanged: bool}`，默认 false | 原生要求用户先核对目标已完成或取消粘贴；只有明确覆盖选择才允许覆盖后来变化的剪贴板 |
| `discardSavedClipboard` | 无 | 原生明确确认后只丢弃本进程保存的旧副本，不写当前系统剪贴板；没有隐含于“取消/暂不恢复” |

保存失败、撤销失败、取消和连接失败均保留明确错误码。UI 不要把 `ok=false`
显示为“已准备”，也不要自动换一种保存方式、重试挂载或重复输入。

## 2. 状态字段

| 字段 | 类型/含义 |
| --- | --- |
| `schema` | `1` |
| `enabled`, `xctestEnabled` | 两个独立持久化开关；保存了凭据不等于开启 |
| `buildAvailable` | 当前构建包含 native 实现，且系统至少 iOS 17；不是连接成功 |
| `defaultBackend` | 固定 `coredevice`；不提供给模型选择后端的参数 |
| `appRoutes` | 包名到 `coredevice` / `xctest` 的 map；默认无规则 |
| `pairing.present` | 保存状态查询发现记录；不保证此刻能读取／校验，也不表示 pair-verify 成功 |
| `pairing.storage` | `device` / `session` / `none` / `unknown` |
| `pairing.code` | `OK` 或稳定错误码；Keychain 错误不回传原始系统对象 |
| `legacyPairingNeedsMigration` | 旧明文位置存在；需要用户明确迁移，不自动沿用 |
| `connection.phase` | `idle` / `starting` / `ready` / `stopping` / `failed` / `faulted` |
| `connection.stage` | 存在时是配对、隧道、服务发现、校验、个性化、上传、挂载、刷新等机器阶段名；本合同下面给出准确值 |
| `connection.checks` | 可分别含 `vpnReachable`, `pairingVerified`, `lockdownReady`, `ddiMounted`；只有实际回调到达才出现 |
| `connection.capabilities` | ready 时的实际布尔能力；不能用一个“已连接”替代所有能力 |
| `connection.code` | `OK` 或 `ERR_PHONE_...`；`variant` 只可能是 `personalized` / `cryptex` |
| `connected` | 此刻 native owner ready；设置检查结束会主动停止，因此它可能很快恢复 false |
| `lastCheck` | 最近一次设置检查的 `{time, connection}` 快照；时间是 Unix 秒；不是常驻连接保证 |
| `ddiCache` | `catalogId`, `downloading`, `verifiedThisProcess`；已校验缓存不等于已挂载 |
| `operationPending` | 当前是否有设置操作，不能据此推断手机任务仍在运行 |
| `progress` | 下载期间 `{stage:'downloading', completedBytes, totalBytes}`；结束/取消清空 |
| `clipboard` | 仅下面的布尔状态，绝不显示或上传保存内容 |
| `consent` | `{foregroundGrantMinutes:30, perCallRequired:true, notificationTapApproves:false}` |

当前 Swift 公开的 `connection.stage` 白名单是
`pairing`, `tunnel`, `services`, `verifyingAssets`, `personalizing`, `uploading`,
`mounting`, `refreshingServices`。Lockdown 的实际结果由 `checks.lockdownReady`
表示。阶段缺失只表示尚无该项观测，不能补成成功。

`faulted` 表示 native 清理没有获得确定完成；本进程不启动第二条后端抢占或重放。
`stopping` 也不能当作已停止。初始连接检查成功只证明这一次已完成的阶段，后续
模型调用会重新取得自己的 owner 并核对 generation。

旧 `dsh/phone` 的 `bridgeListening` 精确定义为
`bridge != nil && IOSPhoneSelfRunner.shared.isConfigured`。生产内存配对路径的
`isConfigured` 只确认 native client 存在和 `hasRecord` 为真，不读取配对私钥，
也不完整检查启动配置。**桥已绑定且记录存在，仍可能读不出或校验不过该记录**；
`bridgeListening=true` 不能显示成“运行器就绪”或“连接已验证”。`pairing.present`
和其 `code=OK` 也只是保存状态查询成功，不是新一次凭据内容验证。

ADDENDUM-09 §3.1 选择保留该存在性查询；加载失败不自动转 Mac。选中端上
XCTest 后，记录读取／校验失败以既有 `.setup` 失败返回，原生说明会提示配置或
记录不可用；Runner 继续明确说明本次不会自动转向 Mac，请用户检查后重新发起。
没有新增专门的状态键或错误码来表示“存在但不可读”，不能由 UI 猜造一个值。
方法、参数、phase 和现有错误码集合都不变；调用结果仍通过 `isError=true`
与 `text` 说明失败。只有既有路线起初没有选中端上 XCTest 时，才可能使用已有
Mac endpoint；不要把它解释为对这次失败的重试。

界面文案建议：凭据状态显示“已保存配对记录，仍需检查连接”；旧桥字段显示
“本地桥和配对记录已配置，尚未验证运行器就绪”。主线手机连接卡继续读取
`dsh/phone_link` 的分阶段 `connection/checks`，不要用旧字段推断 CoreDevice。
本包不实现 Dart 设置页；读取失败也不承诺解锁一定能修好，损坏记录仍需用户处理。

剪贴板 map 的字段为 `pendingRestore`, `foregroundRequired`（true）、
`memoryOnly`（true）、`pasteMayHaveBeenDispatched`, `restoreRequested`。
一旦 `pendingRestore=true`，显示醒目的“回到 App 恢复原剪贴板”入口；下次手机调用
会先走独立恢复确认，再询问那次调用本身。恢复确认不能代替手机动作批准。

## 3. 配对存储与 DDI

接收的是 Remote Pairing (`RpPairingFile`)，不是普通 Lockdown `UDID.plist`。
最大 64 KiB，校验 plist、公私钥长度与 Ed25519 对应关系、identifier 和可选 IRK，
再规范化。导入成功只证明结构合格，连接检查才会实际 pair-verify。

Files 的协调、受限读取和规范化在单个后台 reader 进行，主线程不等待 iCloud
下载。取消立即结束本次 UI 等待并丢弃迟到结果，但不能声称底层 provider 已停止；
旧物理读取确实返回前，新导入会收到 `ERR_PHONE_BUSY`，不累积读取队列。
`operationPending=false` 也不表示这个底层占位已经释放。若 provider 始终不返回，
本进程的导入槽会一直占用；其它设置和取消入口仍可响应。

“记住”使用 `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`、同步关闭；要求设备
已有解锁密码，移除密码后这一类项失效。“只用一次”先删除以前记住的项，之后只
留在本进程 RAM，不能在下次启动悄悄恢复旧记住记录。写入或删除失败保持封闭状态，
不默默退回旧凭据。原 Files 文件、Windows 电脑文件由用户自行保管/清除。
Apple 对这一具体类别的说明见[钥匙串保护](https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web)
和[可访问属性](https://developer.apple.com/documentation/security/ksecattraccessiblewhenpasscodesetthisdeviceonly)。

DDI catalog 固定为 `ddi-e2aaeac89ca8fa56c2fa1f144d182994e07a525b-v1`，
资产来自固定提交的 [DeveloperDiskImage 镜像仓库](https://github.com/doronz88/DeveloperDiskImage/tree/e2aaeac89ca8fa56c2fa1f144d182994e07a525b)。
UI 要如实说明这是第三方镜像仓库，并非 Apple 下载站。每个文件按固定字节数和
SHA-256 校验，Swift 写入缓存及 native 实际读取各自核验；无“校验失败继续”。
个性化请求走 Apple 服务。普通检查缺 DDI 时只返回需要准备，不自动挂载。

只有 iOS major 至少 27 且实际提供 `CryptexInstall` 服务时选择固定 Cryptex；
其他路线要求 Personalized manifest 与设备 board/chip 匹配。这个保守选择
不是 iOS 26.x/27 全机型兼容承诺；版本/服务/身份不支持就失败，不猜另一镜像。

Windows 无 Mac 配对流程见 [PAIRING-WINDOWS.md](PAIRING-WINDOWS.md)。它包含固定
版本和哈希、真实 USB 命令及 GUI 自动动作限制；当前只核了源码/发布物，未进行
Windows、PowerShell 或 iPhone 配对实测。

## 4. 批准与后端选择

一次有效调用的顺序是：任务 owner/PiP 源准备 → 用户回前台 → 如需先恢复剪贴板则
单独处理 → 首次取得本任务 30 分钟资格 → **每个调用都点一次新的原生允许按钮**
→ Node 当前请求仍然有效 → 实际连接/派发。Node 的缓存批准、自动批准配置、通知
点击、模型输出均不能代答这个按钮。30 分钟从含睡眠的单调时钟计算，绑定 run 和
session；暂停、结束、配对/设置 generation 变化会使当前使用失效。run/session
切换会清除两条路线的观察、资格与旧 native owner；新会话必须先重新读屏。

原生确认显示完整输入、目标编号/标签和 submit 请求；CoreDevice 可显示旧观察的
本机预览，明确它不是实时画面。允许读屏后，用户需要自行回目标界面，DSH 处于
后台且实际 PiP active、未 suspended 才准入。任何锁屏、暂停或 PiP 丢失都会停止
继续派发；已进入系统的动作只能报告“结果可能发生”，不能宣称撤销成功。

默认使用同一个 Rust owner/tunnel 的 CoreDevice 分支。只有显式开启 XCTest 才
能用增强；每 App 规则来自前台设置，不来自工具参数。XCTest 对它实际核到的包名
再次检查 CoreDevice 专用集合，不把上次路线当作当前 App 身份证明。

自动切换只允许发生在 CoreDevice **准备连接失败，或新的 screen 准备时确认缺少输入能力、确认未派发、清理完成**时，且
没有不兼容规则/旧观察绑定。共享屏幕准备、启动应用、触摸、输入或任何结果不明
之后都不在另一个后端重试。端上 XCTest bootstrap 失败也不自动转 Mac runner。
已有 Mac runner 只是用户已开启增强时的独立准备路线，不代表不需要逐次批准。

## 5. 屏幕与输入合同

| 场景 | 实现约束 |
| --- | --- |
| CoreDevice 读屏 | 优先直接 capture 服务；较早系统通过同一 owner/RSD 的 Instruments DVT 截图，不启动 XCTest。随后本机 Vision OCR，最多 200 个文字元素/约 24 KiB；OCR 框是文字框，不是系统可交互元素树 |
| CoreDevice `screen(image:true)` | JPEG 标号图，长边至多 1280，必要时降质/缩小，原始 JPEG ≤880 KiB；坐标按返回图大小解释，不截断图片 |
| XCTest `screen(image:true)` | 沿用 XCUIScreen 的原图 JPEG(.5)，没有宣称加上 Core 的标号/缩放链；原生 caller 拒绝超过 880 KiB 的图，不截断后继续使用 |
| `screen(image:false)` | 可返回文字编号；不因此授权按模型未见的截图像素坐标输入 |
| CoreDevice 编号/坐标动作 | 绑定 session、native run generation、screen token、方向和完整原图像素；120 秒含睡眠观察有效期，最终输入前重新捕获，成功/失败均不复用已经消费的票据 |
| XCTest 编号/坐标动作 | helper 内存观察绑定该认证服务端、controller ID、实际 App ID、方向、原像素和 120 秒含睡眠寿命；caller 另按 run/session owner 资格及 lastXCTestScreen 核验；不能冒称具有 Core 的同一 native run binding |
| native 输入帧 | 同 owner 的新 UUID 帧、30 秒含睡眠有效期；发输入前再核方向；一个输入消费一帧 |
| CoreDevice 触摸 | 当前仅 portrait 方向允许 HID 触摸；横屏拒绝；竖屏坐标映射本身仍待真机验证 |
| 文本 | 整串预检；4096 UTF-8 字节上限，ASCII 1024；LF/TAB/C0/C1/双向控制字符拒绝；不截断、不分批掩盖超限 |
| 敏感输入 | 密码/验证码/支付相关启发式拒绝；3–8 位纯数字及含空格/连字符的等价 Unicode 数字也拒绝；交给 handoff，启发式不保证识别所有敏感界面 |
| CoreDevice ASCII | 完整字符串 HID 输入；准备通道只在先前的 screen/open 逐次批准内显式建立，输入不暗中建立共享会话 |
| CoreDevice 非 ASCII | 原剪贴板 representation 只在 RAM 保存，临时 localOnly + 10 分钟内容过期；前台核 marker/text 后只有12秒的一次派发资格，后台不回读。派发 Command+V 后仅固定回执，不再捕获/OCR/缓存/回传新屏幕；恢复按下一节 |
| XCTest 文本 | 使用已有 XCTest 输入机制；新鲜 App/方向/焦点复核，删除后确证空才输入，完整焦点值核对才允许 submit；不能宣称具有 Core 的剪贴板保存/恢复合同 |
| `submit` | 单独在同次确认说明中展示；Core ASCII 仍使用新 OCR 文字启发式；Core 剪贴板不能核实来源，不自动派发回车并返回未完成固定回执，请用户核对；XCTest 核焦点完整值。未派发回车也不能保证目标应用没有自行提交 |
| `collect` | 一个明确批准的有界连续操作，最多 30 页；每次新滚动前检查当前资格/帧/截止；不是无限后台采集授权 |

XCTest 的内部 `validate` RPC 不向模型注册、不消费观察；真正动作还会重新截图并
消费。RPC 外层的 `controllerBundleID`、`xctestDeniedBundleIDs` 和截止由原生设置/
当前调用生成，不从 params 取。helper 按收到请求时把剩余截止转换为含睡眠的
单调期限，观察到连接断开后拒绝后续动作；取消 HTTP 并不证明已进入 XCTest 的
同步按键串被中断。

最终 runner `/result` 还检查文字（包含 warning）≤512 KiB、图的 base64 ≤1200 KiB，
以及包含 owner 字段、按 JSON 实际转义后的整包≤2 MiB。超限会以同一调用的小型
错误结果上传，不截断文字或图片、不再执行动作。网络本身失败仍只能报告未知，
这些大小检查不保证任意上传必达。XCTest collect 在继续滚动前也检查预算。

### 剪贴板恢复限制

最多保留 16 个 item、每项 32 个 representation、总数据 4 MiB；不能完整读取的
表示或超限在临时写入前拒绝。UIKit 需要先 materialize 数据才能报告其大小，
因此这里是保留量上限，不是 OS 分配前的内存上限。

临时写入前实际逐项回读；前台准备完成时核 marker/完整文本/精确类型集合及前后计数。
后台派发只使用12秒、含睡眠计时的一次本地资格，不读取任何剪贴板getter，不能检测
其间的其他App或通用剪贴板写入。12秒是缩短风险窗口的策略值，没有设备时间保证；
它与临时剪贴板内容的10分钟系统过期时间不同。前台派发和恢复仍核归属，恢复写入后
也要逐项读回一致才释放 RAM 副本。原内容不传给模型、日志或诊断包。

整屏OCR出现预期子串不能证明目标字段等于完整输入，也无法排除“预期文字+其他内容”。
所以所有Core剪贴板粘贴都不做派发后的截图或读屏，不返回文字/图片，不建立新的屏幕
令牌，并清除本地观察/预览。仅返回固定说明“可能粘贴了其他内容，请用户核对”。没有
submit时回执表示派发动作已执行；请求submit时返回未完成并明确未派发回车／发送按键。
目标应用仍可能自行处理粘贴；回执不承诺未发生提交。下一次读屏需要另一次真实批准。
App 被终止前没有恢复的话，RAM 副本会丢失；系统的原 Handoff/过期属性不可从
该 API 重建，恢复的是 representation 内容，使用 localOnly。

Apple 明确 `changeCount` 在当前事件循环结束后才发布，变化可以合并，不能当成
同步写入或目标已消费粘贴的 ACK，见 [changeCount](https://developer.apple.com/documentation/uikit/uipasteboard/changecount)。
这些多次检查缩小竞态窗口，**不构成跨进程原子 compare-and-swap**。一次可能发出
的粘贴之后，不按固定延时在目标背后擅自恢复；用户需回前台确认完成/取消，再恢复。
发现后来复制必须另行明确选择覆盖，暂不恢复保留两边现状。

## 6. 宠物 PiP 接线

继续使用原 `dsh/pet_overlay` 通道、Dart `PetState` 和现有素材；具体字段/方法见
[PiP 接入合同](../pet-overlay-tests/README.md)。原生注册及 phone task owner 已在
AppDelegate/PhoneControl 组合接线；默认可见 160×106 pt 源可由主线移入设置/任务卡，
不能隐藏成 1 px 或画一个不可点击的“停止”按钮。

原生调用通过既有任务行显示“等待本次确认 / 正在准备连接 / 正在处理本次调用 /
请核对手机结果”，暂停与继续也有固定状态文字。更新核对 runtime、session、
request 与当前 task，旧回调不改新任务；任务行不包含模型参数、输入或剪贴板内容。
这些是所处阶段，不是目标 App 已成功执行或结果上传已获 ACK 的证明。

UI 要区分 `usable` 与 `keepingAlive`：前者只是开关/资产就绪，后者才是当时实际
PiP、音频所有权及 protected-data 状态。启用和 alwaysShow 各需用户明确选择。
任务模式结束就收起；alwaysShow 是另一次授权。系统暂停先暂停准入，回 App 之后
原生继续/停止框按当前 task id 和对话框身份核验。系统关闭导致 snooze，不由 push
悄悄重开。标准 PiP 的还原按钮负责回 App，不承诺任意点画面都执行跳转。

使用 AVKit sample-buffer PiP、`UIBackgroundModes = audio`；没有静音音频循环，
没有定位保活，不占用麦克风。记录/播放会话接管、电话中断、锁屏、PiP 失败均不得
继续显示“正在保活”。不能承诺固定后台时长、能耗或不同设备完全相同的行为。

## 7. 已知限制及验收项目

以下限制必须保留在主线验收记录中：

1. 本研究环境没有 Apple SDK；Swift/XCTest 源与 CI 入口已提供，尚未编译/运行。
   Rust/Linux/C ABI 通过不证明 iOS 能启动、控屏或长期后台运行。
2. CoreDevice 的固定服务没有可靠 OS 前台 App 身份证明；launch 返回 PID 不是
   foreground ACK。OCR、键盘线索与全文 readback 都只是保守观察。
3. CoreDevice 保留完全相同像素路径，只对符合[有限容差](CORE-FRAME-MATCHING.md)
   的细窄变化放行；全图轻微变色、文字或几何变化、键盘过渡仍拒绝。这些启发式
   不能证明前台 App 或真实焦点。尤其必须实测“同一目标界面 + 动画 PiP → 再次
   输入”：若服务截图包含 PiP，宠物动画仍可能使旧图失效。当前没有设备证据确定
   是否包含，不能据此删掉校验或声称闭环已可用。
4. 完成后返回按最后实际使用的路线执行。CoreDevice 只复用同任务、同 native
   generation 的现有连接，固定启动主 App；XCTest 保留既有返回 RPC。不为返回
   准备新连接，不跨路线兜底，不重复输入。launch ACK 不等于前台成功，桥接层
   仍等待并核对 UIKit 前台状态。两路线的实际返回均需按组合版本进行真机验收。
5. 需要真实 iPhone 验证配对两种存储模式、撤销/锁屏、已有 foreign DDI/media
   不抢占、portrait HID/方向变化、剪贴板多表示/权限提示/后来复制/进程终止、
   XCTest App 切换/控制 App 拒绝/过期请求，以及暂停、PiP 关闭与迟到 callback。
6. 所有设备记录只写版本、阶段、稳定错误码、时长及成功/失败。配对记录、私钥、
   Keychain 项、剪贴板内容不进入日志、截图证据或交付。

正式交付的 reviewer 报告应绑定**最终组合 patch 的精确 SHA**，逐项说明
PASS_SCOPED / BLOCKED 与未执行项目；本合同不会把组件签核合并成真机通过。
