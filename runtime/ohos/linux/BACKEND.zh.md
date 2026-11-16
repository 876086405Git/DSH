# LinuxRuntimeBackend（914，931 同步关闭增量）

这是正式宿主 JS 后端，通过 912 固定可信目录下的 libdsh_linux.so 与固定源码身份的客体控制器通信。工厂 `createLinuxRuntimeBackend(options)` 同步返回对象；`await backend.opened` 仅在真实客体 opened 帧通过校验后完成。931 增强 closed 的同步合同；旧客体没有同步字段的 closed 会被明确拒绝，不能混用旧资产。

options 包含可信 nativeLibraryDirectory、绝对 configPath、与客体一致的 64 位小写十六进制 epoch、已有私有 temporaryRoot；closeTimeoutMs 默认 10000。生产路径不读取 SIM 开关。第二参数 internals.createSession 只用于显式测试注入。共享 owner 负责配置、镜像和 native 目录的可信来源。

## 授权边界

当前 confinement=[]，workspaceLease=false。prepare 明确抛 ERR_OHOS_BACKEND_CONFINEMENT，不签发无法落实的票据；spawn 同样拒绝 policy 与 confined argv。940 起 spawn 另接受可信 owner 给出的 `mounts`（本 VM 启动时导出的 9P tag、导出内相对路径、客体绝对目标、是否只读），仅当客体 opened 帧声明 `mounts:true`；宿主 cwd 必须落在其中一个目标内，否则唯一可接纳 cwd 仍是显式客体私有 /workspace。policy 到 mounts 的换算与只读视图由路由后端负责，见 [ROUTING.zh.md](ROUTING.zh.md)。通常插件传入的是宿主 cwd，必须先完成授权 9P 映射才能运行；本后端不偷换 cwd、不假装已有宿主工作区隔离。PTY 未实现。

## 作业与流

spawn 接受现有 subprocess spec，返回 stdin Writable、stdout/stderr Readable（pipe 模式）、collected、started、done、terminate、waitForExit。串行提交作业，严格验证 epoch/seq/job、偏移、base64、帧序和结果。环境仅由客体 PATH/HOME/TMPDIR/LANG 默认值和显式 env 组成；不隐式继承宿主变量。显式 env 可覆盖默认值或用 undefined 删除。App 代理由 LinuxControl 的 LinuxProxyPolicy 逐作业生成显式别名后传入；直接调用 backend 不自动取得 App 代理或其他宿主环境。

每个输出流的客体未确认信用窗口为 64 KiB；pipe 另有 64 KiB Readable 高水位，不能把两者相加误称总共仅 64 KiB。push(false) 后停止 ACK，消费恢复后才续传。collector 使用现有公开 OutputCollector；ACK 在 Buffer 已交给 collector.push 后发出。ignore 是明确丢弃，inherit 等待写入接受及 drain。stdin 每次切片最多 4096 字节，最多 64 KiB 未确认，Writable 回调要等客体实际 write ACK；调用方仍须遵循标准 Writable 背压。

完成必须有双 EOF、全部输出被宿主 sink 接受并确认、客体 produced 偏移一致，以及客体 PID namespace 树回收后的 complete。cancelled 原样保留，不能由 exitCode 推测。SIGTERM/SIGKILL 均是取消请求，903 实际用 namespace SIGKILL；结果保留真实 leader exitCode/signal 和 requestedSignal。leader 先退出而子孙仍在时，最终可合法得到 exitCode=0、signal=null、cancelled=true。取消宽限到期没有释放事实则进入 UNKNOWN，绝不虚构强杀完成。

## 生命周期

断线、乱序、错误或无法确认回收会拒绝 done/waitForExit 并保留 live owner 隔离。每个作业不会 stop/join VM。backend.dispose 先封闭准入、取消与排空作业，等待原任务树及双流 EOF/ACK 收尾后，才发送 close。重复 dispose 共享同一个完成结果，不产生第二次关闭。

客体只在显式 close 且无 active job 时打开 `/` 的目录 FD，以 `ctypes.CDLL(None, use_errno=True).syncfs(fd)` 同步根文件系统，关闭 FD 后发送 `closed`。成功帧必须包含 `rootfsSync:true`、`syncMethod:'syncfs'`、`syncScope:'rootfs'`，并具有本轮 epoch、严格递增 seq 与 `job:null`。既有 controller 先验证版本、epoch 和 seq；backend 还要求处于 closing、没有 live/active 作业且未接受过 closed。宿主 join 或镜像文件关闭不能生成这些客体事实。

同步接口、打开或关闭根 FD 失败时，客体发送 `close-failed`，含固定 method/scope、`rootfsSync:false`、`code:'ERR_OHOS_GUEST_SYNC'` 和可观察的 errno（1…4095，无法取得时为 null），随后抛错，不发送成功 closed。backend 将其作为 `ERR_OHOS_LINUX_UNKNOWN` 的 cause 保留，cause.code 为 `ERR_OHOS_LINUX_GUEST_SYNC`；错误帧字段不合法则按协议故障隔离。断流、超时、失败 owner 或关闭后再来命令也不能被提升成正常关闭。

正常关闭路径在收到同步 closed 后才请求 native stop/join；失败路径仍尝试 native 退役，但 dispose 必须拒绝，不能补造同步事实。成功路径同时要求 native 返回 joined=true、retirementError=false 及既有正常停止 API 结果 -3/-4。成功 dispose 返回 `{closed:true, guestClose, ownerQuarantined:true, native}`，其中 guestClose 是冻结的 `{epoch, rootfsSync:true, syncMethod:'syncfs', syncScope:'rootfs'}`。owner 只能消费本轮 fulfilled dispose 返回的证明建立 clean checkpoint。guestClose getter 是历史观察；如果随后发生重复帧、协议或 native 退役错误，即使 getter 仍有值或 native 后来 join，catch 分支也不得据此写 clean。

syncfs 返回 0 的含义限于实际客体内核支持的接口与错误观察范围，不能推出所有写回错误均可见，也不承诺宿主 fsync 或掉电耐久性。同步只针对根文件系统，不是全部挂载。closeTimeoutMs 仍默认 10000；实际客体关闭耗时需要实测，不能用宿主测试耗时替代。

成功 dispose 仍报告 ownerQuarantined=true：TinyEMU 堆设备未完整释放，不重置 native claimed，不支持同 App 重建 VM。resourcesRetired 与 clean checkpoint 是不同事实；未知态不提升为 closed/READY。

## 验证

运行 tooling/ohos/research/linux-backend/run.py，参数 --node、--dsh-prefix、--native-library-dir、--guest-config、--output。它复制所有可写盘后执行 JIT/strict 协议测试（包括 clean-close.test.mjs）及两个真实客体（正常与断线），记录固定输入 SHA256。run-gates.py 登记 linux-runtime-backend；需 prepared/dsh、tinyemu_native_library_dir 与 tinyemu_guest_config 输入，客体配置必须指向包含本版 agent 的盘。

另一个登记入口 linux-guest-clean-close 运行 tooling/ohos/tests/guest-clean-close.test.py。它用实际 Python Agent.run/command 和真实 stdin/stdout 管道，正常项调用实际宿主 root FD 的 syncfs；EBADF 项实调无效 FD，EIO、open/close 和符号缺失项明确使用受控边界。backend 的 close/protocol 单测使用实际生产模块和 OutputCollector，但 native/guest transport 是显式替身。两者均不能替代真实客体内核与跨进程数据恢复的验证。

真实 VM 记录应包含客体 uname、根挂载、关闭耗时、本 epoch 同步 closed 及 native 退役事实。跨 App 恢复必须由 owner 的明确 clean checkpoint 与新进程启动流程另行证明；写入测试数据时不得手动 sync 来替生产关闭补步骤。Linux host 的 Node NAPI/TinyEMU 测量不代表 SDK/HAP 或真机通过，工作区 9P 和完整 VM 释放仍不在本后端能力声明内。
