# 真机验证清单与放行条件

这是一份**待执行清单**。本文件没有新增设备测量，以下设备项目初始状态全部为 **NOT_RUN_DEVICE**。Linux 文件/Worker/HTTP、公开 SDK 严格 ArkTS、HMS 占位声明编译、完整未签名 HAP 和真实设备是不同层；每项结果必须附实际输入身份，不借用相邻层通过。[证据与当前状态](evidence-20261102.md)

## 1. 先固定此次要验证的产物

每轮只需记录能解释结果的事实与摘要，避免把大量无关设备信息当成证明：

| 记录 | 必填内容 | 不能替代它的东西 |
|---|---|---|
| 源码组合 | 530 完整 commit，选定补丁 SHA，冲突合并后的文件 SHA | “用了最新包”、只给分支名 |
| 工具和 SDK | 实际 SDK、Flutter/AOT、embedding/HAR、Node 与编译器身份 | 普通 Linux Node 版本代替目标库 |
| HAP | 完整 HAP SHA、签名/安装结果；是否真正 `--full` | 普通 ArkTS 检查 HAP、占位 app.so |
| 运行时 | manifest、内层 runtime.zip、runtimeVersion、文件数和字节数 | 开发 prefix、同名旧 ZIP |
| 原生库 | 待安装 libnode、host、flock、require-builtin 的 SHA 和 ELF 审计 | 源码可编译、测试 DSO |
| 系统 | 机型、实际 ABI、OH API、四项 deviceinfo 身份及系统版本 | Android SDK 数字或桌面 `uname` |
| 测量状态 | 安装/升级/重开/锁屏的实际次序，权限/ACL 是否配置，缓存冷热定义 | 凭日志间隔猜冻结时间、称所有“第一次”都是冷启动 |

正式报告保留原失败、退出码、可观察效果和原始时钟；应用日志先脱敏，启动凭证、API key、用户对话和原始音频不作为共享证据。截图或录屏可证明界面现象，不能代替文件字节、资源释放和鉴权检查。

### 上设备前的构建门

| ID | 执行内容 | 达标条件 |
|---|---|---|
| B01 | 从准确基底选择每项主补丁或增量，普通 apply/check | 没有主补丁和 feature-only 重复叠加；所有后像摘要明确；旧 HMS/native 候选与新版本不混用 |
| B02 | 完整目标 Node/addon/host 构建和 ELF 审计 | runner 在 libnode 内；改名 API 与保留的 addon 入口正确；NEEDED/强导入/ABI/NODELETE 成立，无数据目录 ELF 路径 |
| B03 | 实际采用 O5 统一准备器、39 prepared HAR 和最终构建入口 | O5 内嵌 bundle 摘要相符；HAR helper 三条结算分支确实进入产物；不是只把工具文件放进仓库 |
| B04 | 对最终 App 源运行真实严格 ArkTS | 唯一工程；所有源前后 SHA、诊断路径、HAP 内 ABC 相符；0 errors/tool errors/not compiled，警告独立记录 |
| B05 | 对 HMS 使用真正 HMS SDK | ShareKit/CoreSpeechKit/PDFKit 真正声明与调用通过；`--hms-stubs` 只能登记占位层，不能完成本门 |
| B06 | 真正完整 `--full` 打包并审计 | 实际 Dart AOT、目标 native、最终单归档都进入 HAP；仅一个 Stored runtime.zip，内部摘要与组成器一致，点文件未丢 |
| B07 | 真实组成物→安装器→Host::Start→严格回合 | 使用最终 installed 树，固定六入口无漂移，原样 profile、五工具/两审批，前后树 SHA 一致 |
| B08 | Android 对照 | 本次涉及的目标 pins、构建 recipe 和字节输入保持原约定；没有把 OH-only 修复扩散到 Android；是否另构 APK 单独记录 |

B01–B08 中已有某些精确版本的离线证据，见 [E01–E10](evidence-20261102.md)。**换了完整组合以后，只能复用逐字相同且不受新调用路径影响的部分；发布产物身份门必须重新核对。** 当前主线 `build-hap.sh` 仍有单归档接入要求，属于主线维护范围，不能由文档假定已修好。

## 2. 第一轮：安装、启动、退出和库装载

建议从一个允许清理测试数据的自有测试安装开始，所有异常注入都应在专用数据与明确测试构建中执行，保留失败后像；不要向用户唯一数据做破坏性实验。

| ID | 实际场景 | 要观察和保存的判据 |
|---|---|---|
| R01 | 安装准确签名 HAP 后，只使用远程主机并查询 guestRoot/status | 没有因这些查询映射 Node/创建引擎/读运行时清单；原生库暂缺或加载错误不摧毁远程路径。映射量必须由设备工具测，不能从 import 源码推算 |
| R02 | 第一次真正 install | ResourceManager 只打开单 runtime.zip；raw offset/length 正确；完整文件集合、size/SHA、ELF 拒绝和最终 installed 状态一致；记录实际耗时/RSS/可用空间 |
| R03 | 重复 install、一个文件改变的升级 | 未变化文件不解压/不写出；已变化和元数据实际提交；记录全树读取成本，不只列变化文件大小 |
| R04 | 在已确认成员提交后终止安装，再重开续装 | installing/归属记录阻止半成品 start；续装只承认已完成的合法文件；不删除未知资源；最终全树与新清单一致 |
| R05 | 清单、ZIP、哈希、CRC、尾附 Deflate、大小谎报、必需入口缺失 | 审计器与实际安装器一致拒绝；schema true 拒绝，数值 1/1.0 按相同协议接受；未留下泄漏 raw FD/inflater 或可启动半树 |
| R06 | 一次 raw close / inflater end / 文件写入失败后显式重试 | 旧资源仍由原 owner 清理，新操作不偷换归属；Controller 不能把已拒绝的初始化 Promise 永久缓存成不可重试状态；成功重试后资源归零 |
| R07 | 正常 start，使用中文默认工作区且 session/create 不传 cwd | 六入口、唯一 preload、空 NODE_OPTIONS、实际 Cordis roots/defaultDirectory 正确；监听固定 IPv4 loopback；凭证只走既定消费路径 |
| R08 | 重复 start、启动后即 stop、ready 后 stop | 一次性 consumed 稳定；stop 请求不冒充已退出；join/尾日志后才有终态；继续查询与远程界面可用 |
| R09 | 脚本正常退出、process.exit、未捕获异常 | 退出码回到 Ark，整个 App 仍活；记录 fatal/abort 的不同边界，不推定所有 native 故障都可恢复 |
| R10 | restartApp 前台/后台、快速重复、错误返回 | 只重启当前 Ability；活动 Node 先走停止契约；前台条件和 3 秒重复错误如实传给 Dart；不直接 exit，不谎报重启成功 |
| R11 | Context 原生库路径、两个固定 addon、N-API 双引擎同进程 | 记录实际 bundleCodeDir/nativeLibraryPath 拼接、库 canonical path、加载次序、符号提供者；缺库/链接库/错 ABI 明确失败，不转去数据树搜索 |
| R12 | 长行、大输出、中文无换行尾部、旧 Flutter engine 迟到 detach | 事件有界，丢行有提示，token/key 既有规则打码；旧 detach 不影响新接收者；终态不越过 reader 排空 |

R04 的“终止”要记录真实方式；如果只是正常关句柄/新建对象，应写冷重开，不能改称 SIGKILL。R06 的异常注入要说明发生在平台 API 前、后还是设备真实错误；失败替身不能被写成手机系统故障复现。

## 3. 发布、文件系统和工作线程

| ID | 场景 | 达标条件与限制 |
|---|---|---|
| F01 | 工作区内中文/特殊字符文件、父目录换链、叶 symlink、FIFO/目录 | native 安全 opener 只接受授权根的普通 FD；拒绝路径逃逸，不依赖 File.path 的字符串 realpath |
| F02 | 打开后同名路径被替换、同 inode 合法写者并发修改 | 前者读原 FD 身份；后者如实记录可能混合/提前 EOF，不冒称内容事务快照 |
| F03 | DSH_HOME/.agents 与用户输出 | 用户导出不进入私有 home；listOutputs 只枚举 DSH-Go；AGENTS managed 标记与自有文本保持；技能根与实际消费者一致 |
| F04 | 托管技能 start/cancel、旧 owner、旧 token、旧 Node 世代、发布失败 | 旧授权不写新世代；取消不留下半个可用技能；失败恢复不删未知目录；engine/Ability 更换的归属与协议一致 |
| F05 | publication 首次实际 link/rename、目标已存在、竞争发布 | 记录实际方法、errno、final/source 字节及挂载；只有真实 NOREPLACE 成功才支持 available；普通 rename 成功不能代替 |
| F06 | 持久 trying 后终止、相同/新系统身份恢复 | 相同版本 disabled-after-crash 后不再试 rename；旧 final 保留；新系统身份可靠变化才讨论重试。残留 trying 不是 SIGSYS 证明 |
| F07 | 四项 deviceinfo 缺失/空白、不稳定与版本更新 | 启动在改恢复状态前明确失败；真实值与系统升级对应；不能用环境变量或 Linux kernel 字符串替代 |
| F08 | 原生锁竞争、会话写入与跨线程 | 分别核 publication 锁和会话主线程锁，能力字段不混淆；fsync/目录同步失败不继续进入不可恢复的发布步骤 |
| W01 | Node CJS/ESM 主入口、中文参数、相对 import、两个并发私有 cwd | 主引擎 cwd/stdio 不变；每个脚本的原生入口与路径适配保持协议；不能拿相对路径成功证明 OS 沙箱 |
| W02 | queued cancel、同栈 cancel、同步死循环、后代 Worker | 没开始的脚本不晚启动；已启动真实 terminate/join 后不再增长测试文件，父 I/O/归属清理完成前不释放槽 |
| W03 | 两路原始字节、大输出、背压中文尾部、shell 重定向 | 直接 Worker 字节准确；shell 缓冲边界明确；现存 stdout 控制流/独立 open 差异必须按最终后继补丁复验，不掩盖在总回合通过中 |
| W04 | fd close/自动关闭/transfer 后数字重用 | 旧脚本不能操作后来属于主线程或其他 owner 的 FD，且正常新 owner 文件字节未变 |
| W05 | Git cancel/硬终止与临时索引、恢复后的快照 | 按归属账本精确清理，实际 workspace 快照与原判据一致；清理未结算前不回报完成 |

F05–F08 按 [M6 设备前提](M6-3-device-prerequisites.md) 安排受控条件。未知 seccomp 策略可能直接终止进程，不能用随便执行一次 syscall 的方式替代版本/策略前提查证。设备上的 SIGSYS、Linux SIGKILL、errno 返回和掉电是四种不同证据。

## 4. 后台、网络和恢复

| ID | 场景 | 关键观察 |
|---|---|---|
| L01 | 前台→后台→前台，两个 Ability 交替及旧回调迟到 | 只有当前 Ability 的单调观察生效；旧后台/销毁不盖新前台；未有引擎时不加载 Node、不发控制 HTTP |
| L02 | 手动 pause 后前台；后台时手动 resume；两者交错重开 | 两暂停原因分别保留，门不开错；持久手动意图恢复，历史 host 观察不冒充新进程系统事实 |
| L03 | 303 登录、真实签名 cookie、401 重认证、重定向/Host/Origin 拒绝 | 只访问固定 loopback，关闭代理/重定向，限制响应体；取消可能已送达的旧请求仍由 revision 防倒退 |
| L04 | 网络失败、慢确认、stop/新观察中断重试 | 单 timer、有界退避，只重试相同观察；现有 Dart error/notice 持续可见，当前确认才清除，不把 Node phase 改成假退出 |
| L05 | 无/有 KEEP_BACKGROUND_RUNNING 和 MODE_TASK_KEEPING 资格，API异常 | granted/denied/unknown 与实际公开查询对应；不因 onForeground 报 granted，不把9800005一概说成用户拒绝；policy仍 may-freeze |
| L06 | 已确认逻辑暂停后锁屏/冻结，以及无预告直接冻结 | 两场景分开；活动预算只扣已确认时段；未预告时不猜精确冻结时长、不自动重放副作用 |
| L07 | dispatch 后丢结果、outcome 后未 committed、并发 A慢B快 | 用实际文件/HTTP计数验证 unknown 或恢复同一次结果；顺序正确，无重复副作用，不因超时自动新建请求 |
| L08 | 日志截断、结果文件丢失、取消与完成同到、换 bootId | 损坏不被当空日志，结果未知保留；新的回合不能借旧句柄/预算；传输恢复先重新鉴权 |
| N01 | 实际手机 DNS/TLS/系统 CA/代理/IPv4/IPv6 | 生产 dispatcher 的真实请求；Linux自签TLS通过不替代系统证书和网络服务 |
| N02 | FormData307/308重放、正文阶段 abort(undefined/null/0/false/对象) | 对最终目标 libnode 复跑 O5 原断言；未加载的旧准备输入不能被测试机 Linux 修复遮住 |
| N03 | 网络在后台/锁屏切换、连接半开、超时后外部副作用 | 不把 socket 错误当业务未发生；重连/凭据墙钟期限与工具活动预算分开记录 |

后台资格查询没有创建后台计算任务。本轮没有授予无限 CPU 或免冻能力，不能依据一次 granted 就宣传后台任务持续运行。

## 5. 系统通道与现有界面

| ID | 场景 | 达标条件与必须保留的边界 |
|---|---|---|
| C01 | 保存/打开中文和大文件、取消、磁盘满、复制途中 detach | 真实 StandardMessageCodec 往返；安全 FD→缓存→只读 URI；失败不报成功；目标可能已有部分内容时明确展示 |
| C02 | 相册确认、各图像 MIME、bytes子视图、私有 URI 预览 | 只向系统确认所得 URI 写入；用户取消不扩大权限；预览是否显示实测，不以 API 返回成功替代 |
| C03 | 冷/热 file Want、源授权很快失效、慢复制与 engine 替换 | URI及时打开并受限复制；到达顺序保持，成功副本在原源消失后仍可用；普通启动不误 terminateSelf |
| C04 | WebView单/多选、MIME/通配、同URL reload、navigate/dispose、旧结果 | 网页回调至多一次、旧 owner 不复用、物理 picker 未完不再开；真实 ArkWeb 能消费系统 URI；可见页面/前台证明的缺口明确 |
| C05 | native-files 授权 URI、8MiB/16MiB及 own30MiB边界、增长和EOF | 实际字节预算，64KiB分块，EOF null；无任意路径或持久grant；取消中的实际FD按所有权释放 |
| C06 | native-files 旧插件close失败，换全新engine/plugin | 旧资源真正退休且异步尝试结束后可重试清理；本次busy不迟到弹picker，下一次正常用户请求可继续 |
| C07 | audio正常播放/暂停/完成，后台、焦点中断、sink取消 | 真实fdSrc范围、MIME/codec、缓存根与path_provider一致；停止确认后才允许Dart删除；不伪报声音已经播放 |
| C08 | audio release或close拒绝后新插件、两个新owner同时恢复 | 旧物理lease保留至真实释放；最多一个新owner得到资源；活动owner不可被抢占；取消等待不晚开FD |
| C09 | Wi-Fi/蜂窝/VPN切换、无默认网、服务错误、多engine订阅 | 列表协议正确；查询失败不说none；observer实际回收，网络存在不等于互联网可用 |
| C10 | 通知允许/拒绝、槽位、锁屏、冷/热点击、并发cancel | 仅publicText；HMAC导航正确；旧engine不发新通知；系统publish结果与实际展示分别记录；不从通知直接审批 |
| C11 | 时区、system刷新策略、后台bringToFront | 正确时区/当前自身Ability；auto/max不伪成功；真实后台拉起拒绝可见 |
| C12 | 内存和热状态、冷却30秒、休眠、多个Flutter owner | OH事实不进Android字段；active uptime和截止重读成立；单系统callback、注销失败恢复；真实UI默认结果与Dart消费一致 |
| C13 | 诊断info、脱敏磁盘日志、轮转、短写/失败、跨进程冷读 | 实际磁盘完整行，有界队列和省略计数；原token不回流；未flush尾部和掉电轮转不宣传完整性 |
| C14 | 输入法粘贴拒绝/INVALID/Promise异常、正反选区、成功粘贴 | Promise结算且选区不误删、不发空编辑delta；prepared HAR确实被用；ACL未授予与UI fallback另记 |
| C15 | usage协议缺失与未知平台 | 不向Android sdk字段填OH数字；未改v1时按已见消费者处理，不私自上报或扩schema |

### HMS 单独一轮

先完成 B05，之后才能把下列项目写成 HMS API 或设备结论。当前仍是 **UNCOMPILED_HMS / NOT_RUN_DEVICE**。

| ID | 场景 | 观察 |
|---|---|---|
| H01 | 分享completed先到、dismiss先到、面板关闭迟到、engine/Ability变换；Application与UIAbility缓存目录不同 | 每个回调至多一次；可靠completed才映射完成，先dismiss无法判准时unavailable；物理面板未结算不换owner；实际path_provider输出可消费。5dee后继已关闭旧193c的Linux路径反例，仍须核真实设备目录与授权 |
| H02 | 冷/热分享接收、多文件、临时URI撤销、失败清理 | 原授权消失前及时复制；字节/数量限制、顺序和专有目录归属成立；普通Want不误退出 |
| H03 | 麦克风未授予/已授予/申请中转后台/设置中转后台 | 每次权限UI调用前复核当前binding、同Ability和前台；不能只在第一次await前查一次 |
| H04 | 录音PCM到WAV、停止/取消/失败、识别语言和地区 | 真实格式、真实设备采样和识别服务；Linux wave解析不是麦克风或识别成功；不支持的离线模型明确返回 |
| H05 | PDF多页/损坏/加密/巨大页面、renderer失败、缓存文件被系统清理 | 实际PDFKit页尺寸/PNG和资源释放；自身cache document或slot明确ENOENT可退休，其余释放失败仍保留owner；无需手工重装才能恢复 |
| H06 | 音频与语音并发、可见停止UI、字幕overlay | 现阶段native-media voice/overlay不广告；只有新的统一麦克风/可见UI契约实现并实测后，才可更新能力，不因已有dsh/voice就自动启用 |

## 6. 结果怎么写才可复核

每项用下面的最小格式记录，不用一个笼统“通过”替代所有层：

```text
案例：R06 / 第一次 raw close 失败后的显式 install 重试
输入：base + patch SHA；HAP SHA；manifest/runtimeVersion；设备/系统标识
方式：真实设备错误 / 测试构建平台边界注入（写清二者之一）
观察：第1次返回值；重试后的安装状态；FD/inflater；实际文件SHA
结果：PASS_SCOPED / BLOCKED / NOT_RUN_DEVICE
限界：本项没有证明的系统行为
证据：原始日志、文件摘要、必要截图/时间序列
```

任何一项阻断先保存可重放的前像与实际后果，再做小修和相关完整回归；不要用后来一次完整五工具成功掩盖早先单项副作用、字节损坏或资源泄漏。系统/输入版本变化时新建记录，不覆盖旧结论。
