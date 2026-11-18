# P1 原生宿主与启动契约

本实现位于 `app/ohos/entry/src/main/cpp/`。平台无关的线程、参数、输出、状态和文件访问部分已在 Linux 运行；Ark N-API 适配层也通过桌面 Node N-API 替身执行。**本懒加载增量不改 C++；主线追加7报告的真实交叉编译与本轮 ArkTS 检查分开记录，尚未在真机运行。** 正式构建依赖 P1A 的进程内 runner、P1C 的 N-API 改名配方、主线生成的改名头和 libnode。

## 调用面与所有权

`types/libdsh_host/index.d.ts` 是 P2/P3 使用的唯一类型入口，声明各 named export；ArkTS 运行时由 NativeHost 的动态 import 取得 native 模块 default 对象，类型导入不装载库。见 `native-host-lazy.md`。

| 调用 | 行为 |
|---|---|
| `start(options)` | 同步验证固定目录和参数，再创建一条引擎线程；成功返回表示接收启动请求，监听就绪由状态/事件确认。 |
| `stop()` | 活跃时调用 runner 的线程安全停止入口；非活跃时不做事。完成必须等 `exited`，不能把调用返回当作已停止。 |
| `getState()` | 返回 phase、consumed、baseUrl、token、exitCode、errorCode、errorMessage；终态时回收已完成的引擎线程。 |
| `drainEvents()` | 一次取走有界队列中的 log/ready/exit/error；没有跨引擎回调或 Ark 对象引用。 |
| `openUserFile(root, relative)` | 打开可信 workspace/cache 根下的普通文件并返回 fd，调用方拥有 fd，必须在 finally 中关闭。 |

`start` 的七个输入是 `runtimeRoot`、`guestRoot`、`dshHome`、只含一个路径的 `workspaceRoots`、`cacheDir`、可信 `nativeLibraryDir`、字符串字典 `env`。路径由 P2 的 Ark 控制器提供，不是 Dart 传入的任意命令行。`openUserFile` 的根也只由 Ark 的工作区/缓存策略选择，不能允许 Dart 自选根或授权 `DSH_HOME`。

P2 v6 的 `guestRoot` 固定为同一个 ApplicationContext 的 `filesDir + '/runtime/rootfs'`；查询该路径不依赖引擎 ready，也不做目录或 manifest IO。`rootfs` 沿用既有目录名字，不表示存在 Linux 根文件系统、PRoot 或 chroot。宿主在启动时要求下表目录已存在，并拒绝根下四个目录被 symlink 重定向；`dshHome` 和唯一工作区必须等于表中路径。这些校验在消耗一次启动之前完成。

| 用途 | 相对 guestRoot 的路径 |
|---|---|
| `HOME` | `root` |
| `DSH_HOME`、诊断与应用配置 | `root/.dsh` |
| `DSH_AGENTS_HOME`、共享 skills / AGENTS.md | `root/.agents` |
| 唯一工作区 | `root/workspace` |
| 托管技能 | `root/.dsh/skills/<固定 name>` |
| 给用户交付的输出目录 | `root/workspace/DSH-Go` |

运行时代码仍放在原来的 `filesDir/dsh-runtime/tree`，不移进 guestRoot。托管技能的许可、取消和逐文件提交见 `managed-skills.md`；输出目录策略由文件通道负责。

模块内有应用寿命的 Host 单例。它不持有 `napi_env`、`napi_value` 或 JS callback；引擎线程和两个输出读取线程都不调用 N-API。Flutter detach 仅由 P2 移除事件接收者；P2 的模块级控制器继续抽取事件，重挂后读取同一原生状态。宿主和 runner 以 `-z nodelete` 链接，构建门检查实际 ELF 标志，避免 Ark 模块卸载时丢掉仍在运行的 C++ 代码。

## 启动前提逐项落地

1. runtime/home/cache/workspace 必须是已存在的绝对目录，不能是文件系统根；固定入口文件 canonical path 必须仍在 runtimeRoot 内。缓存的子目录不能被 symlink 重定向。
2. `NODE_OPTIONS` 必须缺省或严格为空。空格也拒绝。调用方不能覆盖 `HOME`、`TMPDIR`、`DSH_HOME`、`DSH_AGENTS_HOME`、`NODE_*`、`UV_*`、动态加载器变量、`DSH_GO_*`、`NARB_*` 或 OpenSSL 配置入口。
3. 命令行固定为下面的 13 个参数，只有一个 `--import`，不提供额外 CLI 参数接口：

   ```text
   dsh-node --jitless --import RUNTIME/runtime/ohos/preload.mjs
     RUNTIME/node_modules/@deepseek-ai/dsh/lib/bin.js web
     --patch DSH_HOME/ohos-host.patch.json --host 127.0.0.1 --port 0 --no-open
   ```

4. `HOME`、`DSH_HOME`、`DSH_AGENTS_HOME` 使用上表的三个不同目录；宿主显式设置它们，避免继承来的 agents 环境变量改变共享指令和技能的根。临时文件和 V8 编译缓存分别放在 cache 下的 `ohos-process`、`node-compile-cache`。`NARB_DISABLE_NATIVE_CACHE=1` 禁用另一路原生加载器缓存。临时修改的进程环境在终态发布前恢复，包括原先存在的 HOME 和 DSH_AGENTS_HOME。
5. `workspaceRoots` 写入实际 Cordis 的 `ohos-subprocess.config.workspaceRoots`，不是只写一个无消费者的环境变量。Host 生成 JSON 格式的合法 YAML patch：禁用旧 `subprocess`、`sandbox`；通过 `insert` 引入两个 OHOS 后端；保留 bash sandbox 和 approval 插件。
6. `working-directory.config.defaultDirectory` 与 `sandbox-policy.config.workspaceRoot` 都使用第一工作区根。权限模式与 `DSH_PERMISSION_MODE` 同步，允许既有 `workspace-write`、`read-only`、`danger-full-access` 三种值，默认 workspace-write。Cordis 的 config 是整块替换，因此明确给出 policy 所需字段。
7. publication 的可靠系统身份仍由 linked binding 直接调用 `OH_GetOSFullName`、`OH_GetDisplayVersion`、`OH_GetIncrementalVersion`、`OH_GetSecurityPatchTag` 四个公开 deviceinfo C API。没有 Ark 环境变量或 Linux kernel release 替代值。缺失/空值会在改动既有恢复状态前明确失败。**这四个 API 在设备上的值和可用性待真机核实**；Linux 回归使用明确的 deviceinfo 测试夹具。

profile 用私有临时文件写完、fsync，再 rename 发布；内容只含固定路径和权限模式，没有启动凭证或 API key。runtimeRoot 固定文件为 preload、DSH bin、process/index、process/sandbox。

## 生命周期、退出与日志

状态按 idle → starting → running/stopping → exited/error 演进。验证失败在启动前同步抛出稳定错误码；引擎线程中的启动错误通过原生状态与 error 事件返回。接收一个有效 start 后 `consumed` 永久为 true；即使随后退出或停止也不能重新创建 Node。P2 应提示重启应用，不应把 stop 做成「稍后原地重启」。

P1A 覆盖 Node 的默认退出处理，使 `process.exit(code)`、未捕获异常及正常退出返回 C 调用者而不是直接退出整个 App。此宿主把退出码原样送回 Ark。`stop` 是 Node 的硬停止请求，不承诺应用层事务已回滚或最后一条 JS 输出一定已提交。Native fatal error、abort 或内存破坏仍能终止整个进程；没有进程隔离保证。

stop 可能在引擎线程建立、进入 `dsh_node_start` 之前发生。Host 保存停止请求；若 runner 尚未 active，现有 stdout reader 最多每 50 ms 再试一次，封闭「先 stop 返回未活跃，随后 Node 才开始」的竞态。没有另建一个取消线程。

stdout/stderr 使用管道读取。fd 1/2 属于整个进程，捕获期间其他 App 原生组件写入这两个 fd 的内容也可能进入日志；这不是线程私有输出重定向。结束时先恢复 fd、排空并 join 两个 reader、恢复临时环境，再发布最终退出状态和 exit 事件。P2 看到终态、再 drain 当前批后就可以停轮询，尾部无换行的中文日志不会被先发布的退出事件越过。

单行上限 16384 字节，超长行整条丢弃并给提示，不把可能包含凭据的分片提前输出。队列保留至多约 512 个日志/生命周期项；满时丢弃最旧 log，保留 ready/error/exit，并报告丢弃行数。P2 另维护 2000 行带递增序号的协议日志环。

`ready` 只接受固定 DSH 的 `dsh web: http://127.0.0.1:PORT/?token=TOKEN` 行，核对端口范围与 token 字符。原凭证只经 ready/getState 交给本地 UI；写日志或 hilog 前遮盖 URL token 和传入 env 中 KEY/TOKEN/SECRET/PASSWORD 类值，多行值按实际输出行遮盖。未知来源的任意敏感文本不能据此宣称已自动识别；交诊断包仍需检查。

## 运行时与原生库的落点

P2 的 rawfile manifest 按文件哈希描述 JS/JSON 等普通资源，安装到固定 `filesDir/dsh-runtime/tree`；已有文件 hash 一致时保留，变动文件写私有临时文件再 rename。持久 installing 标记阻止中断后的半成品启动；重新执行安装续完后才清除。已经消耗 Node 实例的进程不更新活动树。home/workspace 不随运行时替换，缓存可重建。这一过程不是全量解压几百 MB 的归档。

`libdsh_host.so` 由 App CMake 构建；主线提供的 `libnode.so` 在 `entry/libs/arm64-v8a/`，runner 和 linked publication 已编入其中，产品不再依赖 `libdsh_node_runner.so`。相关 CMake、改名门与 libnode 工具链由主线负责，本补丁不修改。Ark target 不包含 Node 头、不强制改名，只以 `dsh_node_start` / `dsh_node_stop` 的 C ABI 进入 libnode。Linux 测试的独立 runner DSO 仅是测量夹具。详见 `napi-isolation.md`。

P1B v2 要求 P2 v5 从自己的可信 Context 生成 `nativeLibraryDir`：普通自有 Context 的 `bundleCodeDir` 加上 `applicationInfo.nativeLibraryPath` 的相对路径组件。公开 6.1 源码中后者不是绝对路径。Ark 必须拒绝空值、绝对 nativeLibraryPath、NUL、空组件、`.` 和 `..`，不接受 Dart 或配置传入的覆盖，也不硬编码安装路径。entry 模块固定 `extractNativeLibs: true`、`libIsolation: false`；这些 Ark 和模块字段由 P2 v5 提供。

Host 再 canonicalize 已存在的非根目录，要求 `libdsh_flock.so` 和 `libdsh_require_builtin.so` 是固定名字的普通文件，且两者 realpath 恰为目录加固定名字，拒绝库文件 symlink。失败返回 `ERR_OHOS_NATIVE_LIBRARY_PATH`，不消耗一次启动。引擎存活期间设置受保护的 `DSH_GO_OHOS_NATIVE_LIBRARY_DIR`，退出前恢复先前环境。O2 的固定助手仅接受这两个 product 并从该目录 `process.dlopen`；不复制 ELF 进入数据树、不读任意产品名或额外搜索路径。

这闭合了源码与 Linux 路径契约；它没有证明设备安装所得路径或目标 ABI。系统返回字段、HAP 提取路径/只读属性、改名后的两库及 libnode 在 Ark 同进程实际绑定，仍需 SDK/HAP/设备验证。路径检查本身不解析 ELF 或证明 N-API 改名，实际符号门继续由 P1C 构建配方负责。

## 工作区导出文件

`file_access.h` 逐层用 `openat` 打开相对路径：每层 `O_NOFOLLOW`，中间层 `O_DIRECTORY`，末端 `O_NONBLOCK` 并用 fstat 要求普通文件。拒绝空组件、点/父目录、绝对路径、NUL、symlink、目录和 FIFO。先打开的 fd 在路径被替换后仍指向原 inode；不依赖 Ark `File.path` 对原字符串做 realpath 的结果来证明安全。

该检查不禁止文件本身被合法写入，也不提供内容快照。P3 必须先从返回 fd 复制到自己控制的临时快照，再交系统选择器/分享流程，并在 finally 关闭 fd。根目录必须是应用拥有、由 Ark 选定的 workspace/cache，不能暴露任意私有路径。

## 已执行的检查与待验证项

- HostCore：Linux Clang 18，30 个场景，覆盖真实线程、固定 argv、环境恢复、有限队列、ready/token、尾日志、停止竞态、多行密钥、启动前提和路径越界；含可信原生目录、缺库/非普通文件/库 symlink、NUL/相对/根路径和 env 覆盖拒绝，以及 guestRoot 缺失/相对/根路径、home/workspace 错位、多工作区、agents 缺失/重定向和 DSH_AGENTS_HOME 覆盖拒绝。
- 适配层：公开 OH native_api/common/hilog 头配合官方 Node 24.22.1 的通用 N-API 声明，桌面实际调用五个导出。Node runner 与 hilog 是明确替身。这是接口转换检查，不是 OH SDK 编译或 Ark 运行结果。
- 工作区 opener：10000 次父目录与 symlink 置换，接受的 fd 全部读到授权根内容，其他请求拒绝；测试前后 fd 均为 4。具体成功/拒绝数随真实调度变化，不能作为性能指标。
- 配置：旧布局的两个真实回合证据保留。P2 v6 又从 `3fc4081` 的 22 个鸿蒙补丁重新构造私有运行目录，重新构建该基底的 just-bash/re2js，生产 driver 记录实际 HostCore 的 13 个 argv 和 8 个固定环境键。原样 profile 通过真实 `--dump-config`；严格仿真中 session/create 完全不传 cwd，实际中文默认工作区完成 write/edit/read/grep/bash 与两次审批，并观察到 native-addon 路线。生成 profile 没有改写。
- 目录消费者：新布局的实际 `dsh-home-paths`、`FileSystemSkillProvider` 和 `dsh-agent-instructions` 使用 HostCore 捕获的环境，验证 HOME、DSH_HOME、DSH_AGENTS_HOME，以及两个 home 中各自的 skill 和 AGENTS.md 读取。不是只核对环境字符串。
- 重跑入口 `runtime/tests/ohos/host-layout.py`。它只读取调用方给定的固定 prefix、npm 依赖缓存和 Linux addon 夹具，全部构建及写入发生在新的输出目录。严格回合在生产 argv 之外显式加入 sim/observe 测试导入及假模型 overlay，这些不属于产品启动参数。它不是冷/热性能比较，也不证明目标 ABI。
- 正式 SDK 编译、Ark 模块重挂、改名 Node 与 Ark 同进程、native addon 的实际 HAP 安装路径、真实 deviceinfo/errno、设备后台与恢复：**未验证，待主线/真机**。

## 来源

- Node 公开嵌入 API 与退出边界：`embedded-exit.md`，以及 <https://github.com/nodejs/node/blob/v24.22.1/doc/api/embedding.md>。
- Ark 公共 N-API 入口：<https://github.com/openharmony/arkui_napi/blob/OpenHarmony-v6.1-Release/interfaces/kits/napi/native_api.h>。
- HiLog 公开声明：<https://github.com/openharmony/hiviewdfx_hilog/blob/OpenHarmony-v6.1-Release/interfaces/native/kits/include/hilog/log.h>。
- 上游固定 DSH/工作目录/profile 代码由 `runtime/patches/pins.json` 与运行时锁文件锁定，实际安装树与测试报告的 SHA256 随交付保存。

### 原生安装路径的公开来源

- OpenHarmony 6.1 `MainThread::GetNativeLibPath` 将非空 `applicationInfo.nativeLibraryPath` 接到 `LOCAL_CODE_PATH` 后：<https://github.com/openharmony/ability_ability_runtime/blob/OpenHarmony-v6.1-Release/frameworks/native/appkit/app/main_thread.cpp>，固定下载 SHA256 `fa2073829e92d5a66bd8d32b85d9235e37591abaa062120e3432c0786fed6d24`。
- 普通自有 Context 的 `GetBundleCodeDir` 返回同一 `LOCAL_CODE_PATH`：<https://github.com/openharmony/ability_ability_runtime/blob/8222796f651bb5c19a91dbf927795ceb149c0e97/frameworks/native/appkit/ability_runtime/context/context_impl.cpp>，SHA256 `eb4ec82bc1ec88ca260c380677fb99caa5cab5412f1e497231fe8802a410c537`。据此推断的拼接关系仍需安装测量确认。
- 官方模块配置的 `extractNativeLibs` / `libIsolation` 语义：<https://github.com/openharmony/docs/blob/OpenHarmony-v6.1-Release/zh-cn/application-dev/quick-start/module-configuration-file.md>。目标 API 26 满足 `extractNativeLibs` 自 API 20 引入的要求。
