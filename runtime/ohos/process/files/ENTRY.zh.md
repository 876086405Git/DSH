# 932：主进程授权服务到正式虚拟 shell 工厂

本层把系统选择器已发布的目录对象，接到 `OhSubprocessRuntime.prepare/spawn` 所创建的正式虚拟 shell Worker。目录仍通过同一 `libdsh_host.so` 的 FD 租约访问；逻辑名固定为 `/workspaces/<UUID>`。这里没有把授权 URI 或主机路径转写为普通宿主工作区。

这份实现只覆盖虚拟 shell 工厂。完整 DSH 会话的 WorkspaceRegistry、WorkingDirectory、文件服务及工具前级，必须另有实际入口证据。Linux guest 的 9P/FID 授权未由本层启用；Node 脚本 Worker 与 owned-git 对目录租约仍明确拒绝。

## 进程服务与可信输入

唯一产品 `runtime/ohos/preload.mjs` 在插件加载之前调用 `files/process-authority.mjs` 的 `installProcessGrantAuthority()`。只在主 Node 环境和 OpenHarmony 平台执行。测试通过既有 test-only preload 建立平台观测；产品没有新增 SIM 环境读取。

初始化使用既有固定产品加载器取得 `libdsh_workspace_grants.so` 的规范路径，从同目录确定 `libdsh_host.so`，要求它已经被 App 加载。底层 `bindOwner` 使用 `RTLD_NOLOAD`；此路径不会另建宿主授权登记表。初始化同时捕获 native 方法和路径，后来的 `process.env`、加载器导出或 binding 方法替换不影响已捕获的主进程服务。

内部接口如下：

| 接口 | 约定 |
| --- | --- |
| `borrowProcessGrantAuthority()` | 仅主 Node 返回同一个冻结服务；不提供 `close` 或重新绑定入口。 |
| `snapshot()` | 返回真实 native 快照行 `{id, generation, writable, mountPoint}`。错误直接传播，不转换为“空列表”。 |
| `issue(grants, {readOnly, workspaceRoot})` | 维持既有单根合同。`workspaceRoot` 必须恰等于一个快照根；写权限取任务权限与 native 授权的交集。每个任务获得自己的单用票据。 |
| `unavailableReason` | 最终退休未确认时为 `ERR_WORKSPACE_DRAIN`；这项进程债务不会随某个 Cordis runtime 被销毁而清除。 |
| `processGrantNativeDirectory()` | 只给内部 shell Worker 构造器提供早期捕获的加载输入，不作为 shell 命令环境或用户配置。 |

如果预加载阶段缺组件、host DSO 尚未加载或绑定失败，初始化记住该错误。普通 App 私有物理工作区仍可工作；逻辑授权请求得到原错误。后续 ETS 才加载 host，也不会自动补绑定。主 `napi_env` 死亡后，既有 native `owner_dead` 规则仍有效；本层不清该标志，不声称同 App 进程内可重建 Node owner。

## 精确工作区与工作目录

`prepare` 对逻辑根查询真实快照并保存该 native key/generation。逻辑根不调用宿主 `realpathSync`。既有物理工作区继续使用原规范路径与目录检查。

授权范围必须是完整且精确的 `/workspaces/<UUID>`。把策略根写成子目录会返回 `ERR_WORKSPACE_SCOPE_UNSUPPORTED`，不会扩大到整个授权目录。当前目录可以在这个确定根内，但必须是规范的绝对逻辑路径；正式 Worker 用已消费的目录租约验证它确为目录。没有 `prepare` 的逻辑 cwd 返回 `ERR_WORKSPACE_CONFINEMENT_REQUIRED`。

授予 Worker 的文件系统只有本次逻辑根和本次私有临时根。不会把该逻辑字符串放进 `ReadWriteFs` 的宿主根数组，也不会附带其他已选目录。native generation 在真正发票时再次检查，因此撤权、后台失效或重新选择不能复活旧 prepared 请求。目录对象被重命名后仍访问原对象；原路径上的替换目录不因此获得授权。

Worker 的 native 加载目录由工厂的可信输入覆盖，调用者 `spec.env` 不能替换它。这个内部输入与传入 Bash 的命令环境分开；不改变公共 `scrubbedParentEnv`，也不把该目录送给 Linux guest。

## 退休与实际结束

`prepare` 只保存进程内请求，没有发 native 票。任务真的开始时才 issue；队列中的同栈取消因此不会留下未消费票据。Worker 使用 native 单次 consume，不能 snapshot、issue 或重绑主 owner。

正常路径先关闭 Worker 文件系统租约，随后等实际 Worker exit 和 stdout/stderr 都结束，再完成原 owned 资源的收尾，最后要求 native `retire()` 返回 1。只有这些事实闭合，`done` 与 `waitForExit` 才成功完成，后续 grant 任务才可获得新票据并启动实际 Worker。失败时这两个 promise 拒绝；队列可以继续处理下一项，但共享 quarantine 会拒绝其 grant issue，不能启动新的授权 Worker。

取消先调用 retire 关闭任务的新 I/O 准入，再终止实际 Worker。第一次返回 0 可以只是“已退休、尚未排空”，不能立即当成永久故障。实际 Worker exit 与双流结束后仍返回 0 或抛错，才记为 provider failure，并在共享服务封闭后续 grant issue。新的 Cordis runtime 也不能绕过这项债务；物理私有工作区不受这项授权债务影响。没有按超时、新 generation 或重新建 router 清债的机制。

每个 runtime 只回收自己的工作和临时资源，不关闭或重新建立进程 authority。既有 `NativeGrantFs.close()` 与 N-API 环境清理共同覆盖普通结束和初始化异常。这里的“排空”不是掉电耐久保证，也不是释放整个 VM 或 App 的内存。

## 验证入口与范围

正式窄入口为 `runtime/tests/ohos/workspace-authority-entry.py`。它要求官方 composer 的实际 payload 与 manifest，校验四个相关产品文件等于当前源码，再用真实 DSH bin、唯一产品 preload、真实 Cordis 公共工厂、同一宿主 DSO 和真实 ETS 方法体执行。SDK 选择器、权限服务、Preferences 与 Ark 注册运输边界明确是宿主夹具；实际 URI-open 对应普通目录 FD、native 发布、消费和退休均是真实实现。

驱动可以用 `--native-directory` 接收已建宿主库，也可以用 `--cxx`、`--node-headers`、`--round-native-directory` 在自身新输出内构建三份小库。编译器 argv 保留调用方给的 driver 名称。额外输入为固定 Node 24.22.1、TypeScript 5.9.3、真实 linked publication 测试库；不需要新第三方依赖，不需要 guest 大盘。

每轮包括普通 JIT 与 jitless/strict 模式。正常用例覆盖真实读写、任务 RO、嵌套 cwd、范围拒绝、多 runtime、取消/排队、后台失效后重选、新代际、实际目录对象身份，以及主/Worker N-API 所属。另一轮明确注入“真实 retire 已执行但确认被返回为 0”的故障，只验证不确定结局下的保守处理；它不冒充真实内核 close 失败。最后一轮不预载 host，验证晚到的 ETS 发布不能补授权初始化。

严格仿真需要自己的 test-only native allowlist。`workspace-authority-instrumentation.mjs` 只为测试 Worker 建立该名单；产品没有恢复被公共 scrubber 去掉的 SIM 参数。负向 owner probe 是单独的真实 N-API Worker，只验证拒绝；所有正向目录访问都由正式 shell 工厂创建，未手工 issue 票据或改用专用测试 Worker。

历史红例是同一入口上：物理 marker 读取成功，ETS `pathThrow` 下 native ready、借用 FD 已关闭，但逻辑根在 `prepare` 的宿主 `realpathSync` 抛 ENOENT。实际 DSH bin 本身正常退出。后像使用官方 composer，保留同一 marker 断言得到真实目录内容。

每轮 `CONFIG/COMMAND/INPUTS/REPORT/RESULT` 和 stdout/stderr 必须一起保存。结论以整个 driver 返回值、所有 case、缺少 cleanupError、native 最终 leases=0/drained=true 为准，不能只看 marker。准备参数缺失、缺既有 IO-gate preload、存储 ENOSPC 与产品行为失败分别记账。没有运行完整统一门，也没有 SDK、HAP、手机或 Linux guest 授权通过的声明。
