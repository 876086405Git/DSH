# P2 v6 通道与目录约定

本篇记录 v6 协议；当前56e增量只迁入懒加载，已合入的26/27保持基底内容。历史v7完整替换版基底为 `2c2e799f42c4e506580e6d4a7a4c13f246976630`，增加追加7要求的动态原生加载及文件通道实例归属修复。精确组合经过公开 SDK 严格 ArkTS 编译，设备未验证。此前 v6 的执行数字保留为历史记录，v7 证据另附。原有安装、启动、状态及日志字段继续遵守 `runtime-channel.md`，本次不改变 Android 路径或协议。

## 固定目录

所有路径取自 `RuntimeController` 保存的同一个应用 Context；不调用 path_provider，不拿 AbilityContext 的目录作比较。

| 用途 | 路径 |
| --- | --- |
| `guestRoot` 通道返回值 | `context.filesDir + '/runtime/rootfs'` |
| `HOME` | `<guestRoot>/root` |
| `DSH_HOME` | `<guestRoot>/root/.dsh` |
| `DSH_AGENTS_HOME` | `<guestRoot>/root/.agents` |
| 唯一默认工作区和 `workspaceRoots[0]` | `<guestRoot>/root/workspace` |
| 用户交付目录 | `<guestRoot>/root/workspace/DSH-Go` |
| 诊断 Markdown | `<DSH_HOME>/dsh-app/diagnostics.md` |
| 运行时安装基目录 / 已提交代码树 | `context.filesDir + '/dsh-runtime'` / 其下 `tree`，保持原位 |

`rootfs` 是沿用的目录名，本地引擎仍运行于 App 进程，不创建 Linux 根文件系统。DSH 固定版本的共享 agents 消费端读取显式配置或 `DSH_AGENTS_HOME`，不从 `DSH_HOME` 推导；因此原生宿主显式设置并保护这两个变量，`HOME` 也单独指向 `root`。不迁移旧实验目录中的文件，不扩大用户文件导出白名单至 `.dsh` 或 `.agents`。

## 方法行为

| 方法 | 本次约定 |
| --- | --- |
| `guestRoot` | 无参，已绑定引擎即可同步从 Context 路径返回；不等待 rawfile 清单或 Node，不产生文件 IO。 |
| `getStatus`、事件 status | 延续字段；仅实际 Node ready 且有效 Flutter owner 存在时提供 `managedSkillGeneration`。 |
| `install` | 保留原运行时增量落地和中断恢复行为。 |
| `start` | 创建上述必要目录，传固定 `guestRoot`、`DSH_HOME`、单个工作区；保留一次性 Node 限制。现有 Dart `start` 不传 cwd，新会话 cwd 由已合入的 LocalPaths 消费端传固定工作区。 |
| `stop` | 先撤销托管技能权限，随后沿用已有 Node stop 请求和退出轮询；异步启动准备也被取消。 |
| `reopenApp` | 无参，目标由当前 UIAbility 自己的 bundle/module/ability 信息取得；先走 stop，再调用公开 `UIAbilityContext.restartApp(want)`。无窗口或 SDK 拒绝时向 Dart 返回错误。 |
| `installManagedSkill` | 与 Kotlin 同形的 requestId/expectedRoot/expectedToken/expectedGeneration/name/files 请求；结果含 result/current/reason。只有固定四个随 App 技能可写。 |
| `cancelManagedSkill` | 按当前 owner 和精确 requestId 取消，始终 success(null)；不允许旧 owner 取消新 owner 的同名请求。 |
| `publishDiagnostics` | 原 256 KiB 限额和原子写入，目录跟随 `DSH_HOME`。 |
| 其他已实现方法 | 延续原响应形状和错误行为。 |
| reset、safe、direct 等已有不支持方法 | 继续明确 `ohos_unsupported`。 |

托管技能按 Kotlin 的逐文件语义：有限请求，严格 UTF-8，逐文件 fsync 后同目录 rename，`SKILL.md` 最后提交。取消后已提交文件可以保留，不承诺整个目录回滚。一个物理写任务加最后一个待处理任务；取消回调不提前释放物理 IO 槽。安装、投递回调时均核对实际 Node 世代、token、Flutter owner 及本次 grant，Activity 变化不退休 Flutter owner。

## 重开 App 的公开证据和边界

固定公开声明 `interface_sdk-js@8a86234f0d542e5062e24e948652f5a484d90904/api/application/UIAbilityContext.d.ts` 的 `restartApp(want): Promise<void>` 要求主线程、聚焦的 UIAbility；目标限当前应用。声明给出 801、16000011、16000050、16000063、16000064、16000065 等错误；不会触发原 UIAbility 的 onDestroy，因此不能依赖该回调停止 Node。本实现先发送既有 stop 请求，再请求系统重开；不把 stop 请求返回称为 Node 已物理退出，也不调用 process.exit。

这一固定 `UIAbilityContext` 声明标注 since22 dynamic / since23 static；追加中的 API12 说法不能由该文件证实。工程最低 API26，具体 SDK 编译、目标设备焦点状态、频率门、重开和退出清理仍须主线验证。系统错误码和消息保留到 PlatformException，Dart 已有手动重开提示。

## 验证记录

新基底尚未实施本增量时，新增布局、同步 guestRoot、无 Ability 重开和系统错误传播四项实际测试为 0/4；最终联合通道为 30/30，零跳过。它执行擦除类型后的实际 Controller/Plugin/Storage/ManagedSkill 源码和真实 Linux 文件 IO；Flutter、OH API、原生状态与系统 restartApp 均是明确替身，不能称为设备重开成功。

托管技能独立真实文件套件 19/19；原 Kotlin 文件在 JVM 17、固定 Kotlin 2.4.0 上实际编译并运行 16/16 对照。HostCore 的真实线程与环境套件为 30/30，N-API 适配层由桌面 Node 实际加载。原生 profile 不改字节地交给固定 DSH 执行，实际路径/skills/AGENTS 消费端读取新目录；另有严格仿真五工具、两审批回合，创建 session 时省略 cwd，验证宿主默认工作区。所有层的精确输入、原始输出及命令随交付保存。

递归公共声明核查使用 TypeScript 5.9.3、固定公开 OH `.d.ts` 和明确的最小 Flutter 签名。初次在文件写入缓冲区发现诊断，改为明确的 ArrayBuffer 并复制当前 subarray 后，最终 RuntimePlugin 的 8 个产品模块图为零诊断；真实短写/子视图测试也通过。该结果不等于 ArkTS/hvigor 编译通过。最终补丁 SHA 与专职复核结论见交付根说明。

v6 时专用产出列表的 FilesMediaPlugin 单独交付为27号；v7 为去除该插件顶层原生导入，完整并入这部分，统一替代26和27。共享 RuntimePaths、启动时创建 DSH-Go 和受管理的 AGENTS 指令保留。不要在 v7 上再重复应用26或27。
