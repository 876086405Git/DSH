# M6-3：原子发布的设备前提——固定源码查证，待真机核实

## 结论与范围

本项完成公开源码与离线策略核验，**目标 HarmonyOS / OpenHarmony 手机的有效 seccomp、实际挂载、目标 ABI 和发布能力全部仍为 `NOT_RUN`**。没有给生产进程增加探测、修改过滤器、替换发布算法或改变 Android 路径。

1. 在固定 **OpenHarmony-v6.1-Release、Linux 6.6、ARM64** 的已核策略层中，`renameat2` 是不检查参数的放行项。官方生成器得到的 BPF 对该调用只读取架构和 syscall 编号，不读取 flags。按编译分支分别组合父、子过滤器后也放行。这个结论不能外推到任意厂商镜像或未知的祖先/后装过滤器。
2. 参考源码把普通应用的 el2 `base` 绑定到 `/data/app/el2/<用户>/base/<包变量>`。现代配置的 `shared` 是绑定挂载传播属性，**不是 `sharefs` 文件系统名称**。所取公开源码没有给出用户手机实际 `/data` 的后端文件系统，不能据此认定 el2 是 f2fs、ext4 或 sharefs。
3. 不能把应用主线程或 Worker 中试调一次 `renameat2` 当作安全准入检查：seccomp 的 `TRAP` 会产生 SIGSYS，`KILL_PROCESS` 可直接结束整个进程；它们不保证返回 errno。推荐先补齐同一设备/应用启动上下文的被动证据和受控独立测试，现阶段不自动加入可能杀死 App 的首用探测。

58 个固定官方来源的 URL、字节数与 SHA256 位于 `runtime/tests/ohos/device-prerequisites/sources.json`。本补丁只带作者编写的说明、元数据和审计脚本，不带第三方实现源文件、生成的过滤器 C 文件或 tarball。下文 `来源名:行` 对应这个清单；清单的 URL 和 SHA 是精确身份，不以仓库默认分支代替固定版本。

## 一、seccomp：调用点、分支条件、继承与叠加

### 1. 实际可达的安装链

| 层或入口 | 固定源码证据 | 能推出什么 |
| --- | --- | --- |
| init 启动服务的通用调用点 | `init-common-service.c:89–110,290–292` | 有 `SetSystemSeccompPolicy` 包装调用，但内部 92–93 行明确跳过 appspawn / nwebspawn 前缀。不能因找到包装调用就多算一次 appspawn 过滤器。 |
| appspawn preload | `appspawn-common.c:547–552,675–679`；`appspawn-adapter.cpp:144–165` | `WITH_SECCOMP` 下普通路径安装名为 appspawn 的策略；`SECCOMP_PRIVILEGE` 分支在 154–155 行提前返回，省去该父层。nwebspawn 是另外的路径，不在本项普通应用结论内。 |
| fork 后应用设置身份 | `appspawn-common.c:291–317,689`；`appspawn-adapter.cpp:168–222` | 子流程选 app 策略；custom、输入法隔离、atomic、ALLOW_IOURING 以及开发者特权分支可替换策略名。后面的选择可覆盖前面的选择，不能把所有名字当作同时安装。 |
| 策略库加载及安装 | `seccomp-policy.c:99–189,211–254` | 通过配置路径找到对应动态库及过滤器符号，再调用 `seccomp(SECCOMP_SET_MODE_FILTER, …)`；应用策略找不到时不会悄悄退到任意 system 策略。这里证明加载机制，不证明目标设备库内容等于参考源码。 |
| 继承及后装层 | `kernel-seccomp-filter.rst:67–81,87–121,165–171` | fork/clone/exec 保留已有约束，多个过滤器按动作优先级决定结果。已知两层都 ALLOW，仍不能覆盖未知层的 TRAP/KILL/ERRNO。 |

`appspawn.gni:24–43` 的默认声明包括 `appspawn_seccomp_privilege=false`，但产品构建可覆盖；`WITH_SECCOMP` 和实际 app flags 同样必须来自目标构建/启动证据。`IsEnableSeccomp` 的调试构建分支也存在，本项没有建议或执行关闭策略。

当前已核组合为：

- `WITH_SECCOMP` 启用且没有 `SECCOMP_PRIVILEGE`：父 `spawn` + 当前选中的 `app` / `app_atomic` / `app_custom` / `app_allow_iouring`。
- 启用 `SECCOMP_PRIVILEGE`：该父过滤器被跳过，当前选中的上述四种子策略或 `app_privilege` 单层；`app_privilege` 选择还要求源码中的开发者/flag 条件。
- 输入法 `IMF_EXTENTOIN_NAME`、nweb/render 路径、厂商增补、init 更早继承状态和运行中额外加载的过滤器：本项未形成完整有效链，不能列为放行。

这两类组合是对固定源码中条件分支的离线展开，不是对某台设备编译宏或实际 HAP flags 的观测。

### 2. `renameat2;all` 的准确含义

参考应用策略把 `renameat2` 放在普通 `allowList`，没有其 `allowListWithArgs` 条件。这里的 `all` 是生成器支持的架构集合，不是“已检查所有 flags”。源码依据为 `seccomp-generator.py:230–249,309–323,885–904,926–950`。普通 allowList 生成直接返回 ALLOW 的 syscall 分支；参数读取单独位于 `load_arg`，ARM64 第五参数的低 32 位在 `seccomp_data` 偏移 48。

固定 UAPI 与 musl 都把 ARM64 `renameat2` 定为 276。`kernel-namei.c:5055–5059` 的真实 syscall 接收 `unsigned int flags`；离线输入中的超 32 位数只用于证明 BPF 不读取参数，不表示这些数是有效的文件系统 flag。

### 3. 已实际完成的离线矩阵

使用未修改的官方 `seccomp-generator.py`，其 SHA256 为 `1bdb05dc08ff8063b34211f5755cf00ab5fa5e211f795bb1917ff7c563537ddd`。GN 来源规则为 `seccomp-fixer.gni:35–108,113–160`；本次采用相同固定 `kernel_linux_patches/linux-6.6/prebuilts` UAPI 头文件，由宿主 GCC 13.3 的 C 预处理器执行 `-dD -E -Wall -nostdinc`。**这不是 OHOS clang 工具链构建、目标策略库编译或设备 BPF 加载测试。**

官方生成器同时解析 arm/arm64/riscv64 表。ARM64 syscall 映射共 298 项，排序规范 JSON 的 SHA256 为 `1c97cfddc46679af0824d5875f1543bd1445b0fed5163336ee5f9ba3d89c5dcb`。预处理原文件含绝对路径，因此跨工作目录应比较规范映射和生成 C 的内容，不能拿原预处理文件的哈希要求路径无关。

| 生成的策略 | process_type / blocklist | 参数读取观察（nr=276） |
| --- | --- | --- |
| appspawn | system / system.blocklist | 只读偏移 4 和 0；重复装载 nr；不读 args |
| app | app / app.blocklist | 只读偏移 4、0 |
| app_atomic | app / app.blocklist | 只读偏移 4、0 |
| app_custom | app / app.blocklist | 只读偏移 4、0 |
| app_allow_iouring | app / app.blocklist | 只读偏移 4、0 |
| app_privilege | system / system.blocklist | 只读偏移 4、0 |

每个输入均绑定 `privileged_process.seccomp.policy`，设置 `target_cpu=arm64`、`is_debug=false`。这些目标按其 GN 的 `uid_is_root` 或 appspawn 例外，不额外合入 `system_uid_filter`；脚本记录每个策略的完整输入和生成 SHA。

- **62 条单层断言通过**：6 个过滤器 × 8 个 flags 值为 48 条；每个过滤器分别检查未知架构和未知 syscall 的 12 条负对照；父过滤器 UID=0 被 TRAP、UID=10000 被 ALLOW 的 2 条参数对照。
- **72 条条件组合通过**：上述 9 个可达条件组合 × 8 个 flags 值。每条记录确切层列表、编译条件、每层返回动作；设备最终动作仍记 `NOT_RUN`。
- 8 个 flags 输入为 0、1、2、4、7、`0xffffffff`、`0x100000000`、`0xfeedface00000001`。有效的生产 NOREPLACE 值为 1。由于这些 nr/arch 路径没有参数读取，源码与指令路径一起支持该过滤层不依赖 flags 的推论，不能只把有限样本当作全域证明。
- 应用未知 syscall 负对照为 TRAP；spawn 的 `ONLY_CHECK_ARGS` 对无关 syscall 为 ALLOW。所有过滤器的未知架构均 TRAP。负对照保证没有把“总是 ALLOW”的解释器误当验证。

审计器仅解释实际访问到的固定 BPF 指令子集；遇到未知指令/表达式、越界分支、输入哈希不一致即失败。它没有执行 `seccomp`、`prctl`、`renameat2`、fork 或安装任何内核过滤器。生成 C 和原始来源仅位于运行输出/缓存目录，不提交到源码。

复跑（从仓库根目录；缓存可复用本包对应已固定来源，`--fetch` 仅在缺文件时下载并核 SHA）：

```sh
python3 runtime/tests/ohos/device-prerequisites/audit.py   --cache /absolute/path/to/verified-source-cache   --output /absolute/path/to/offline-audit-output   --fetch
```

预期为 `cases=62`、`chains=72`、`device=NOT_RUN`。`audit.json` 含每条 pc / load 偏移轨迹和每个生成文件哈希，`commands.json` 含真实命令、返回码与日志。宿主 Python/C 预处理工具应事先可用，脚本不会安装依赖。

## 二、SIGSYS 风险及首用探测判断

固定内核文档把 TRAP、KILL、ERRNO 分为不同动作：TRAP 不执行 syscall，发 SIGSYS；KILL_PROCESS 结束整个进程；只有 ERRNO 动作有明确的用户态错误码返回约定。参考应用策略的缺省动作是 TRAP。JS 的 `try/catch` 只能处理返回到原生绑定后的错误，不能将未知过滤器的 SIGSYS 自动转换为可控 EINVAL。[固定内核文档](https://raw.gitcode.com/openharmony/kernel_linux_6.6/raw/OpenHarmony-v6.1-Release/Documentation/userspace-api/seccomp_filter.rst)

| 候选检查 | 评估 |
| --- | --- |
| 主线程直接调用，参数设为无效 fd 或不存在路径 | seccomp 在文件系统处理前生效，无效路径不能保证先返回 EBADF/ENOENT；可能结束 App，不作为安全探测。 |
| Node Worker 中调用 | Worker 仍在同一进程，无法隔离 KILL_PROCESS；TRAP 的线程/信号处理也不是可靠的 JS 异常契约。不作为安全探测。 |
| 临时 native SIGSYS handler | 不能捕获 KILL_PROCESS；TRAP 恢复需处理体系结构寄存器和既有崩溃处理器，且改变信号上下文。本项没有实现或证明其通用安全性。 |
| `/proc` 的 Seccomp 状态、actions_avail、GET_ACTION_AVAIL | 可说明模式或内核支持的返回动作，不能回答 nr=276、flags=1 在所有已装过滤器下的结果。 |
| 被动取得目标镜像、策略库和实际启动上下文 | 可缩小不确定性；必须覆盖已继承/后装层与真实架构、编译宏、HAP flags，不能仅对照参考 app 表。 |
| 平台正式支持的独立测试进程/测试 HAP | 可在开发阶段隔离失败并记录退出原因；必须证明其身份、AppSpawn 分支、策略、SELinux 与挂载上下文能代表目标应用。本题尚未证实手机有这样的等价运行机制，不通过 fork/exec 或改策略绕开限制。 |

因此本次**不建议自动在生产首用前盲测**，也没有以来源研究替代设备准入。若本机具备正式独立测试路径，先在无用户数据的专用目录进行开发验证；没有等价隔离路径时，应由本机明确承担一次测试 App 可能退出的实验风险，不把它包装成不会杀 App 的能力查询。

另外，目标若采用 ERRNO 过滤器，单个 EINVAL 也未必来自文件系统；归因需要结合完整策略链。生产已有的仅 `renameat2/EINVAL` 回退条件，本项未扩大。

## 三、el2 的挂载链与断点

### 1. 传统与现代两套公开配置都核对

`appspawn.gni:30` 默认 `appspawn_sandbox_new=false`；产品可覆盖，`sandbox.gni:23–49` 据此选 normal 或 modern 实现。因此不能只引用现代配置作为每台手机的事实。

| 应用内目标 | 传统配置的源 | 现代 el2 组对应源 |
| --- | --- | --- |
| `/data/storage/el2/base` | `/data/app/el2/<currentUserId>/base/<variablePackageName>` | 相同，先挂到 el2 依赖节点的 base |
| `/data/storage/el2/database` | `/data/app/el2/<currentUserId>/database/<variablePackageName>` | 相同 |
| `/data/storage/el2/log` | `/data/app/el2/<currentUserId>/log/<variablePackageName>` | 相同 |
| `/data/storage/el2/distributedfiles` | `/mnt/hmdfs/<currentUserId>/account/merge_view/data/<PackageName>` | 相同来源体系 |
| `/data/storage/el2/auth_groups` | `/mnt/hmdfs/<currentUserId>/non_account/merge_view/data/` | 相同来源体系 |
| el2 share | 单独配置 | `/mnt/share/<currentUserId>/<PackageName_index>` |

来源：`sandbox-classic.json:97–145`、`sandbox-app.json:642–668`。这说明 base、distributedfiles 和 share 具有不同来源，不能互相替代。DLP、文件管理权限和更深层覆盖挂载还有额外分支，本表不是所有应用配置穷举。

传统配置明确使用 `bind,rec`，最终在 `sandbox-common.cpp:1091,1115` 等处调用 mount。现代 `sandbox-load.c:283` 解析 category，`appspawn-sandbox.c:250–262` 取模板，72–96 行实际发起首次挂载并设置传播标志。`sandbox-mount-template.c:57–65` 显示：

- `shared`：fstype 为 NULL，`MS_BIND | MS_REC`，传播 `MS_SHARED`。
- `default`：同为 NULL + bind/rec，传播 `MS_SLAVE`。
- `dac_override` / `dac_override_delete`：才显式选择字符串 `sharefs`。

所以名为 shared 的 el2 依赖节点不会仅因该名称而转换成 sharefs。绑定挂载保留其后端，但**后端链在 `/data/app/el2/...` 的实际承载挂载处中断**：当前没有用户设备的 fstab、mount namespace 或挂载信息。

`fstab-mount.c:97–114` 支持 ext4、f2fs、overlay，并允许扩展；683–700 行使用具体 fstab item 的 `fsType`。这能说明类型由实际条目决定，不能从源码支持列表反推出设备选择了哪一种。

### 2. 参考内核的 NOREPLACE 行为

| 实现 | 精确源码 | 可成立的限定结论 |
| --- | --- | --- |
| VFS | `kernel-namei.c:4925–4982,5012–5025` | 检查 flags；源/目标挂载不同可 EXDEV；持 rename 锁后若 NOREPLACE 且目标 dentry 已存在返回 EEXIST，之后仍经过安全检查和具体 FS 回调。 |
| f2fs | `kernel-f2fs-namei.c:1260–1285` | flags 掩码接受 NOREPLACE，随后执行 fscrypt 等检查；源码具备该语义入口，实际挂载/权限/密钥状态仍需设备验证。 |
| ext4 | `kernel-ext4-namei.c:4235–4256` | 同样接受 NOREPLACE 位并继续 rename 路径；不是对目标镜像的实测。 |
| sharefs | `gitcode-sharefs.c:264–265` | 若调用到该回调，任何非零 flags 返回 EINVAL，因此新目标的 NOREPLACE 发布可能落到已知回退。已存在目标也可能先被 VFS 以 EEXIST 拒绝，不能说每一次调用都到该 EINVAL。 |
| hmdfs local | `kernel-hmdfs-inode_local.c:632–633` | 该回调拒绝非零 flags。 |
| hmdfs remote / merge | `kernel-hmdfs-inode_remote.c:795–805`；`kernel-hmdfs-inode_merge.c:1256–1258` | 掩码接受 NOREPLACE，但后续视图、远端和底层转发仍有条件；不能概括所有 hmdfs 都支持，或都拒绝。 |

这张表仅限固定公开分支。更不能从“文件系统支持 flags”跳到“发布服务全部前提成立”：34 的持久账本还需要 flock、user xattr、持有 fd 的身份验证和文件/目录同步等设备条件，本项没有重新给这些条件做真机验收。

发布服务先尝试硬链接；只有约定错误集合才进入临时文件 + rename 提交。如果硬链接已成功，rename 分支并未执行。因此“某层拒绝非零 rename flags”不能直接推出“每次 publish 都回退”。应在测试时记录实际 method：link / rename / exclusive-copy-fallback，并区分哪些前提导致该路径。

## 四、本机需要补的最小设备证据

1. 记录手机系统/内核构建身份、Node/原生 binding 身份、真实 HAP UID/权限/启动 flags，以及策略相关构建宏。公开 OpenHarmony 6.1 不是 HarmonyOS NEXT 商用设备镜像的等价证明。
2. 取得实际 appspawn 与应用选中策略库的身份/生成输入；结合祖先继承和运行中新增层确认有效链。无法取得完整链时，保持“可能 SIGSYS”，不能以 `Seccomp: 2` 代替放行证明。
3. 在目标应用自己的 mount namespace 中记录实际 DSH_HOME、session/attachment 目标目录的规范路径、mountinfo 和文件系统类型。取最长匹配的可见挂载并处理叠加挂载；必要时追踪 bind root、设备号和外层后端。不能只看外部 hdc shell 的 `/data`，也不能只看 `/data/storage/el2` 父目录而忽略更深覆盖。[mountinfo 定义](https://man7.org/linux/man-pages/man5/proc_pid_mountinfo.5.html)
4. 在得到可接受的受控运行前提后，以同一目录中的自有临时文件测试缺失目标提交、已存在空文件/普通文件/目录/悬空符号链接不覆盖、竞争提交的一胜一 EEXIST，以及失败时 source/final 的完整性。保留 errno / SIGSYS / 退出状态和实际 method，不能把“普通 rename 成功”当作 NOREPLACE 成功。
5. 回放34的真实 provider 持久账本与 kill/restart 矩阵。若实际固定走 EINVAL 回退，明确半 final 风险仍在；若 SIGSYS，现有 errno 回退根本没有执行机会。两种失败不能混记。

以上是将当前静态结论升级为设备结论所缺的证据，不是本包已经完成的测试。

## 五、调查过程与反例保留

- 首次把 musl syscall 模板当作官方 GN 的预处理 UAPI 表，生成器对 arm 的 clock_settime 校验失败。修正为固定 linux-6.6 UAPI 后成功；这是作者输入错误，不是 OH 构建失败。
- 初次猜测 kernel patches 目录为 `6.6/` 得到404；官方目录查询显示为 `linux-6.6/`。最终清单仅包含实际成功下载并核哈希的路径。
- 首版解释器不接受官方生成 C 的 `(unsigned long)` 常量转换，UID 负对照抛 SyntaxError；修正只接受这一固定 ARM64 转换后重跑通过，没有跳过 UID 断言。
- 找到 init 的包装调用点后曾暂推可能再加一层；完整条件明确跳过 appspawn，因此已撤回。早期统一双层组合还没有体现 `SECCOMP_PRIVILEGE` 去掉父层；最终改为9个源码条件组合。旧调查文件保留，正式结果只引用 `audit-final-02` 的62/72。
- 全程未在研究宿主或目标设备安装过滤器，未执行可能因未知策略终止应用的盲探测；目标全部待真机核实。

## 六、M6-3b 后继：崩溃熔断的真机核验记录

前五节保留37号来源查证的范围；本节是追加12后的设备验收增补。后继发布服务在每个进程第一次实际进入 NOREPLACE 提交前持久写入 `trying`，重启发现未结束的尝试则记为 `disabled-after-crash` 并降级。它没有增加一个额外的试探 syscall。以下各行目前均为 **NOT_RUN（目标设备）**。

| 必记维度 | 要保存的实际证据与判定 |
| --- | --- |
| 机型和系统 | 机型、四项系统版本原值、版本身份、内核、应用/Node/binding 构建身份；分别登记哪些组合得到 `available`、哪些得到 `unsupported`，不能把一台机的结果外推到其他版本。 |
| 版本字段可靠性 | 冷启动多次读取四字段；检查 NULL/空白/不稳定导致的明确启动拒绝。升级前后记录元组，确认确实变化后才声称“升级重新尝试”已验证。字段来源与限制见 `M6-3b-system-build.md`。 |
| 实际文件系统 | 在应用自己的 mount namespace 中对 session、attachment、账本和最终目标分别取可见挂载；对 sharefs、hmdfs 的 local/remote/merge、f2fs 分别登记。未取得某种挂载就填 NOT_RUN，不用相似目录替代。 |
| 成功路径 | 记录 link 与 rename 的实际方法。link 成功时本来就无需试用 rename；只有真实 NOREPLACE 成功才支持 `available`。之后同进程不再为成功调用反复写状态，新进程第一次实际 rename 仍重新持久 arm。 |
| EINVAL 路径 | 区分实际 native `renameat2/EINVAL` 与账本写入/临时文件/同步错误。登记 `unsupported`、明确警告和后续无额外 rename；非原子回退的半 final 风险继续存在。 |
| 崩溃恢复 | 在持久 `trying` 后受控终止测试 App，再以相同版本启动；核对 `disabled-after-crash` 持久化、rename 次数为0、回退能否完成，以及旧归属临时资源的恢复结果。不能删除标记后重试冒充自动恢复。 |
| 误触发 | 分别记录调用前被杀、原生已成功但 available 未持久化、低电/断电等未确认窗口。残留 trying 只证明上次没有完成状态记录，不证明发生了 SIGSYS。误触发仍必须保留已提交 final，不能回滚或覆盖。 |
| 能力观察 | 读取发布服务的动态 `atomic` 状态，并核对已鉴权 `GET /dsh-go/v1/runtime-capabilities` 的 `publication.atomic`。配套增量已在 Linux 严格仿真的真实 DSH/connection 下验证 HTTP；本表的目标设备项与 Dart 仍为 NOT_RUN。完整 O6 其他能力字段未在本项实现。 |
| 状态持久化失败 | 在允许的测试目录检验状态文件与目录同步失败如何暴露；禁止绕过未落盘的 trying 继续 native。已有 final 成功但记录 available 失败应明确报错并保留 final。 |

“最多崩一次”的范围必须限定为**同一个已识别系统版本、已持久 arm 的首次实际调用及稳定策略前提**。同进程已有成功后再发生动态过滤策略变化、标记被清除/数据被恢复到旧备份、系统身份不可用等情形，不在一个未加限定的保证内。Linux SIGKILL 证明进程死亡恢复路径；不等于真实 SIGSYS、设备断电持久性或任何挂载上的实现已经验证。
