# agent 与插件命令进入 App 内 Linux（940）

鸿蒙版的 agent 在聊天里跑 `gh`、`python3`、`pip`，插件起 `python3 -m server` 这类进程，都交给 App 内 Linux 客体执行；看到的工作区就是本会话的 App 工作区，路径与宿主一致。用户授权的逻辑目录（933–939 的 FD 租约）不在本期范围，明确拒绝。

## 路径

```
bash -c '<脚本>'（虚拟 shell Worker）
  └ gh / python3 / python / pip / pip3 / linux <命令>   ← 只有这几个名字转发
      → 父线程 linux-forward 服务（绑定外层作业的 workspaceRoot 与 mode）
      → LinuxCommandBackend.forward → spawn
      → LinuxControl.spawnRouted（开关、恢复等待、唯一作业通道、931 代理）
      → LinuxRuntimeBackend（start 帧带 mounts）→ guest agent
插件 child_process.spawn('python3', …) → CommandRouter.spawnPlugin → 同一个 LinuxCommandBackend.spawn
工具直接 prepare 非虚拟命令 → CommandRouter.select → 同上（confinement 声明 read-only / workspace-write）
```

`bash`、`sh`、`rg`、`git`、`node` 仍在虚拟运行时。转发命令按 just-bash 语句缓冲：命令结束后一次交回 stdout/stderr（合计上限 64 MiB，超出即取消并报 `ERR_OHOS_LINUX_OUTPUT_LIMIT`），退出码原样，被信号结束时按 shell 惯例为 128+N。stdin 为该语句的批量输入。`ctx.signal`（外层取消、`timeout`）→ 客体取消，客体用 PID namespace SIGKILL 回收整棵树。`linux <命令> [参数…]` 运行客体里任意程序，例如 `linux sh -c '…'`。

`pip`/`pip3` 与 `python3 -m pip` 换成 `python3 -c <引导>`：Alpine 的 pip 只以 ensurepip 自带 wheel 的形式存在，引导在没装 pip 时从该 wheel 运行。作业环境默认 `PIP_BREAK_SYSTEM_PACKAGES=1`，安装落在客体私有 HOME（`/workspace/.local`），系统 site-packages 归 root、作业改不了。（`python3 -m ensurepip` 会清掉所有 `PIP_*` 变量，过不了 PEP 668，不能用。）

**pip 慢**：从 zip 里的 wheel 运行，每次都要重新编译 pip 的源码，宿主上 `pip --version` 约 29 秒。用户执行一次 `pip install --user --no-index /usr/lib/python3.14/ensurepip/_bundled/pip-*.whl`（约 87 秒）后约 12 秒。更好的做法是把 py3-pip 及其 pyc 放进工具镜像，属于后续镜像变更；本期不自动装，避免第一次 pip 就要跑一分半。

## 工作区：virtio-9p 导出与每个作业的挂载

- 导出：OHOS 运行时把 router 自己的根（App 工作区 `filesDir/workspace` 与本次运行的私有临时根）在第一次启用前交给 LinuxControl，owner 在安装与恢复的 TinyEMU 配置里写成 `fs0..fs3`（tag `dsh0..dsh3`，TinyEMU 上限四个）。一次 attempt 启动后导出不再变；之后不在导出内的目录按“未导出”拒绝。
- 宿主侧：嵌入构建的 9P 后端是 `native/fs_export.c`，不再是上游 fs_disk。每个按名字的操作（walk、open、create、mkdir、setattr、link、symlink、mknod、readlink、rename、unlink）都从导出根逐级 `openat(O_NOFOLLOW)` 重新解析，拒绝 `.`、`..` 与含 `/` 的名字，客体造的符号链接只在客体内核里解析；改权限用 `fchmodat(AT_SYMLINK_NOFOLLOW)`，检查与修改落在同一对象上，遇链接拒绝。正文读写不重新解析：它们作用于 open/create 时已持有的描述符，所以文件在打开后被改名、移走，已打开的读写仍指向原对象，已交付的字节不会因后来的路径变化而撤回。mknod 的类型交给宿主，宿主进程无权建设备节点，FIFO 与 socket 可以建在导出内；打开得到的对象不限于普通文件。所有对象报告为客体作业身份 60081（于是宿主权限位按“属主”生效），chown 到 60081 视为无操作、到别的身份为 EPERM；错误码按 Linux errno 原样回传；打开带 O_NONBLOCK，FIFO 不会卡住 VM 线程。
- 客体侧：agent 的 start 帧可带 `mounts:[{tag, source, target, readOnly}]`。作业 leader 仍是 root 时：首次用到某个 tag 就在根命名空间把它挂到只有 root 能进的 `/run/dsh-9p/<tag>`（`cache=none,access=any`），然后 `unshare(CLONE_NEWNS)`、整棵设为 private、把导出内的子目录 bind 到与宿主相同的绝对路径，只读的再 `remount,bind,ro`，最后在本作业命名空间里卸掉 `/run/dsh-9p/*`，再 chdir、丢权限、exec。作业因此只看得到自己的两个目录。挂载失败按 exec 失败处理：stderr 说明、退出码 126。
- 换算（`process/linux-backend.mjs`）：有会话 policy 时挂 `policy.workspaceRoot` 与临时根，mode 为 read-only 时两者都只读（只覆盖宿主共享的这两个目录；客体自己的 `/tmp` 与私有 `/workspace`（HOME）仍可写，所以这不等于虚拟运行时 read-only 的“拒绝一切写入”）；没有 policy 的插件进程挂它的 cwd 与临时根。cwd 必须落在其中，否则 126。`TMPDIR` 是宿主临时根（与虚拟 shell 共用），`HOME=/workspace` 是客体私有目录，`PATH` 先找 `/workspace/.local/bin`。
- capabilities：`LinuxCommandBackend.capabilities.confinement` 为 `['read-only','workspace-write']`。宿主共享目录的只读与可见范围由客体内核（私有挂载命名空间、ro bind、作业无任何 capability 且 no_new_privs）保证，mount 的源与目标仍由客体内核按路径解析，前提是这些路径在受信资产里只归 root 所有；客体内核若被攻破，这层不再成立，但宿主侧的 fs_export 仍把访问限制在导出根内。`LinuxRuntimeBackend` 自身仍是 `confinement: []`，只接受 owner 换算好的 mounts。

## 开关、恢复、忙

- 未开启：退出 127，`ERR_OHOS_LINUX_DISABLED: Linux 环境未开启：请在 设置 · 能力 · Linux 环境 中打开后重试。`（虚拟 shell 不再追加“鸿蒙本机不可用”的通用提示）。`resolveExecutable` 此时抛 SubprocessExecutableNotFoundError。路由命令从不触发安装。
- 已开启、正在恢复保留的实例：最多等 120 秒到 opened；首次安装（要下载）不等，127 并指向设置页进度；其他状态（failed/unknown/stopped…）127 并带状态与错误码。
- 客体同一时间只跑一个作业，`runPrivateGuest` 与路由命令共用。路由命令最多等 10 秒，之后 126 `ERR_OHOS_LINUX_BUSY` 并说出占用者的命令名；`runPrivateGuest` 忙时照旧立即 409。**限制**：一个常驻的 stdio MCP 服务器会一直占着通道，期间 agent 的每条 gh/python3/pip 都会在 10 秒后报忙。等待是轮询，不保证先来先得。

恢复和忙等待的两个预算都从 `spawnRouted` 调用时起算；每轮先检查准入及空闲，仍需等待时才检查预算，继续使用 100 ms 定时轮询。预算使用 Node 的单调计时，日历时钟前后调整不会被算作等待时长。Linux 的 `CLOCK_MONOTONIC` 不包含整机 suspend；进程暂停或回调晚调度也不会让本方法提前执行。因此这不是包含深睡和任意 OS 调度延迟的硬墙钟截止，也不改变权限／lease 使用的时钟。
- 开关 false 与最终停止会取消正在跑的路由命令（与 `runPrivateGuest` 作业相同）。
- 代理：931 的 LinuxProxyPolicy 逐作业生效。shell 环境里从 App 进程继承来的代理变量（值与父进程相同）先去掉，由策略决定；脚本里刻意设置的不同值在 manual/direct 下冲突，126 并说明。

## 资产与兼容

agent 变了（mounts、opened 里 `mounts:true`），六件资产必须重建；931 资产代际的已装实例会以 `ERR_OHOS_LINUX_ASSET_GENERATION` 拒绝恢复，需要用户在 设置 · 能力 · Linux 环境 点「重新安装 Linux」（控制动作 `discardRetained`，见 [CONTROL.zh.md](CONTROL.zh.md)）删掉旧数据再开启（本期没有迁移）。新 host 配旧 agent：无 mounts 的作业照常，带 mounts 的明确拒绝。`libdsh_linux.so` 需要用含 `fs_export.c` 与补丁 0016 的源码重建（宿主测试与 OH arm64 两份）。

## 命令适配器的最终关闭

`LinuxCommandBackend.dispose()` 封闭该适配器并取消存活作业，也放弃该适配器尚未消费的输出：先解除自有 pipe 到调用方 sink 的连接，再排空自有 stdout/stderr 和实际 guest 输出流。它不关闭或销毁调用方的 Writable，也不操作全局 stdout/stderr。这样，已停止读取输出的插件不会仅因宿主背压而阻断 guest EOF/ACK 收尾。每个存活 handle 的排空函数在 settle 时移除；`spawnRouted` 晚于 dispose 返回 raw handle 时，也在接好流后排空，重复 dispose 仍返回同一完成 Promise。

这只适用于适配器的最终 dispose。普通 `terminate()` 保留原有背压和输出消费合同；最终排空也不会替代 guest 的双 EOF、全部 ACK 和真实 complete。只收到 EOF/ACK、未确认客体任务树退出时，原取消宽限仍产生 UNKNOWN，并保留原错误、隔离状态及未确认的 raw owner。此处没有改变 VM stop/join、普通 Linux 开关或 native FD 生命周期。

## 验证

- `runtime/tests/ohos/linux-routed-disposal.test.mjs`（linux-routed-disposal-plain/strict）：实际控制器、路由适配器、底层 backend/流与 TCP 协议；客体及 native owner 为明确夹具。覆盖两路背压、最终关闭/普通取消的区别、外部 sink 所有权、晚到准入、排队取消及 EOF/ACK 不得冒充 complete；不代表真实 VM、SDK 或设备结果。

- `runtime/tests/ohos/linux-command-routing.test.mjs`（command-router-plain/strict）：生产 router、虚拟 shell Worker、LinuxCommandBackend、LinuxControl、LinuxRuntimeBackend，客体为真实 socket 上按协议应答的替身。
- `tooling/ohos/tests/guest-mounts.test.py`（linux-guest-mounts）：真实 agent 的 mounts 校验与挂载序列，在宿主内核的非特权 user+mount 命名空间里执行；9P 由 tmpfs 代替。
- `tooling/ohos/tests/linux-fs-export.test.py`（linux-fs-export）：生产 fs_export.c 面对 `..`、客体符号链接、被换成链接的父目录下的旧 fid、FIFO。
- `tooling/ohos/research/linux-routing/run.py`（linux-command-routing-guest）：agent 式 `bash -c` 经生产链路进入真实 TinyEMU 客体。

真实客体一次运行（Linux 宿主、host-test 原生库、本分支六件资产，13 项全过）：首次安装并打开 32.8 秒；`gh --version` 1.3 秒，`python3 -c 'print(1)'` 0.6 秒，`pip --version` 29 秒；客体经 9P 读宿主写的文件、写回后宿主与虚拟 `cat` 都看到，0.6 秒；作业为 uid 60081、cwd 即宿主路径、`/run/dsh-9p` 不可见、本命名空间只有两个 9p 挂载；read-only 会话读得到、写入报 `Read-only file system`；取消后作业树被杀、通道立即可用；最终停止 native join 与 clean checkpoint 成立。原有 linux-control、linux-owner、linux-resume、linux-proxy、linux-backend 与 tinyemu-native/block-io/poweroff 研究组用同一份新资产和原生库仍通过。这些都不是 HAP 或手机上的结果。
