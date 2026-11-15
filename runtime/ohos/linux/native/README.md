# TinyEMU Node 插件与 HAP 构建入口（912）

本目录把固定 TinyEMU 2019-12-21 直接链接进 `libdsh_linux.so`，只公开 Node N-API 注册入口，不依赖运行时选择或加载外部 TinyEMU 动态库。生产构建使用现有 Node 24.22.1 的 `napi-rename.h`，所有 Node API 导入必须为 `dsh_napi_*` / `dsh_node_api_*`；不链接 Ark N-API。HAP、SDK 与设备尚未运行，不能由宿主成功推导设备 READY。

## 内部 ABI 与所有权

原生 `create(absoluteConfigPath)` 返回 `{fd, requestStop(), join()}`。fd 是新建 socketpair 的 Node 端，成功返回时所有权一次性交给调用方；调用方必须立即交给 `new net.Socket({fd, readable:true, writable:true})`，此后只能由该 Socket 关闭。native 永不关闭或重用已移交 fd。VM pthread 持有另一端，运行返回后仅关闭自己的 peer。配置失败也通过 peer EOF 与 join 结果报告，创建线程以后 owner 已被占用，不能重试新 VM。

`native-session.mjs` 是 host 内部包装：目录必须来自原生 runtime publication 的签名库目录；不得来自插件参数、环境覆盖或文件选择授权。库名固定 `libdsh_linux.so`，没有任意 libraryPath 参数，也不读取 SIM 环境变量。`create` 返回 `{socket,requestStop,join}`；Socket 构造异常时关闭尚未交付的 fd、请求停止，并在异常上附 `linuxJoin` Promise 供 owner 追踪。close 自身失败另保留 linuxFdCloseError / linuxUnsettledFd 作为未决债务，不允许据此盲目重试 close（EINTR 后 FD 所有权可能已不确定）。

`requestStop` 仅原子置位，不等待、不中断线程、不 signal/terminate Worker。`join` 必须在显式 requestStop 后调用，否则同步抛 `ERR_OHOS_LINUX_STOP_REQUIRED`；只在此时创建 `napi_async_work` 等待 pthread_join。VM 整段寿命用自有 pthread，不占 libuv 池；测试用 UV_THREADPOOL_SIZE=1 在 VM 运行时实际完成文件 I/O。先成功建立 Promise 引用，再排队；引用失败不排队，可显式重试。排队后重复 join 返回同一个 Promise。

join 结果有 `joined`（仅 OS 线程已 join）、`apiResult`、`fatalReason`、`retirementError`、`ownerQuarantined:true` 和 `joinError`。pthread_join 失败或 async work 取消时，不读取机器线程字段，apiResult/fatalReason/retirementError 为 null，joined 为 false，保留 unknown/quarantine。`joined:true` 不是作业成功或环境可复用。-4 为明确停止，-3 为 HTIF poweroff，-5/-7 为输出/输入错误，-8 为盘 seek/write、历史 stream error 或 flush/fclose 失败，-9 为捕获的显式 TinyEMU fatal。-1/-2 启动失败仍须保留 native owner，第二次 create 明确拒绝。GC/env cleanup 只请求停止，不伪装 join；VM heap、设备对象、线程 owner 和库寿命保留，库链接 NODELETE。

RW 写入检查 seek 和完整 fwrite；失败返回给既有 virtio IOERR，并按盘保留错误。退休仍只 flush/close 一次，同时检查先前 ferror，后续调用不会把失败改成成功。stdio 缓冲中的写失败可能到退休时才可见，因此 guest 的 syncfs/closed 不能替代成功的 native 退休结果；这里没有新增逐写 fsync，也不承诺宿主掉电耐久。

## 1203：最终受控停机并 join 后丢弃主 RAM 的驻留页

普通 Linux 开关关闭不触发本优化。安装完成后，`LinuxControl#setEnabled(false)` 只关闭准入并等待当前 job 收尾，保留同一运行 VM，以便再次启用；该分支没有 dispose/requestStop/join。最终 `shutdown()`，或安装尚未完成时的取消处置，才沿 owner.dispose → backend/native requestStop → join 到达本节边界。不可将“开关已关闭”当成页回收确认，也不改变一进程一个 VM 的复用合同。

0017 仅登记 `riscv_machine_init` 中单独分配的主 RAM；低地址 RAM、CPU/TLB、设备、9P/slirp、owner 与配置对象仍保留。正常 controlled 返回 -3/-4 且没有 fatal 才允许处理，真正成功的 `pthread_join` 建立机器线程完成屏障后，join worker 才调用 `embed-ram.c`。启动失败、输入/输出/盘错误、fatal、join 失败或未执行的取消工作均不丢弃页。固定构建中的 CPU、设备、网络 select 和同步块设备/9P 回调都由同一 VM 线程驱动；没有可在 join 后继续触碰主 RAM 的已登记任务。

只对 malloc payload 内从向上页对齐的起点到向下页对齐的终点执行一次 `madvise(MADV_DONTNEED)`。两端不完整页保持原样，因此不覆盖 malloc 元数据或相邻分配。虚拟地址、phys_mem 映射、TLB 地址和设备对象保持有效隔离，既不 free/munmap，也不恢复 guest 执行。第二次 create 仍拒绝，重复 join 仍复用同一 Promise；GC/cleanup 仍只请求 stop，不执行未确认的回收。

成功 join 的结果增加可选观测 `ramRetirement`：`eligible` 表示正常停止且登记了主 RAM；`attempted` 表示对非空完整页区间发起了建议；`trackedBytes` 是登记的主 RAM 分配范围；`eligibleBytes` 是选中完整页区间；`advisedBytes` 仅在系统调用成功时等于该区间；`errorCode` 为 0 或保留的 errno。`advisedBytes` 不是设备实际回收字节数，也不是 PSS 差值。未知 join 的该字段为 null，不读取机器线程字段。页大小/范围错误或 madvise 失败单独报告，失败不填成功字节数，不改变 `apiResult`、盘 `retirementError` 或 clean checkpoint 三字段。

`tooling/ohos/research/tinyemu-ram-retire/run.py` 在正式门中以 `tinyemu-ram-retirement` 登记。它重编真实生产对象，用单独链接的测试 observer 在 VM 线程的 mallocz 后主动触页，真实测 mincore 前后值，并经产品 Node async join 路径验证 9 个场景的 plain/jitless 两种执行。触页来自宿主夹具，不能称为客体负载。主 RAM 之外的分配未处理；完整 VM 内存寿命和 `nativeMemoryRelease:'process-exit'` 合同不变。OH SDK 编译、HAP 和设备的回收行为仍须实测。

## 已处理的宿主终止边界

0001–0011 是此前已冻结的嵌入、CPU/CLINT、初始化错误、HTIF返回、非阻塞控制socket、只读盘及盘FILE退役源差。0012 在 controlled C 入口设线程局部 setjmp，仅对这个库链接的 exit/abort/__assert_fail 引用作 GNU/LLD --wrap；不改全局信号 handler、不 interpose 整个 App、不 monkeypatch Node。显式 fatal 以 -9 返回，fatalReason 1/2/3 分别为 exit/abort/assert。已登记的自有盘会退役；发生退役错误以 -8 优先，仍保存 fatalReason。此边界只穿过 TinyEMU 的 C 调用栈；生产 callbacks 为 NULL/只读原子，不允许从外部 C++/JS 回调跨 longjmp。

还修复 copy_bios 中 kernel/initrd 长度检查位于 memcpy 之后的问题：先用不溢出的剩余容量检查，再复制。超大 BIOS/kernel/initrd 都有真实旧宿主退出/崩溃与新 Node 存活的对照。C 回调故障 fixture 明确注入 exit/abort/assert，验证已初始化边界；它不是“guest 恶意指令已覆盖”的声明。源码中的 cpu_abort 在固定 riscv_cpu.c 只有 unused 定义，没有调用点；其它显式 abort 由同一链接边界处理。

0013 给 slirp 的所有实际 send/sendto 路径增加局部 MSG_NOSIGNAL（只在 TEMU_EMBED）；不依赖 App 全局忽略 SIGPIPE。真实 slirp_send 对关闭的 stream peer，旧独立宿主 -SIGPIPE，新实现 EPIPE 返回且存活。现有 console send 亦使用 MSG_NOSIGNAL。

残留：无法兜底任意 OOM、NULL 解引用、内存破坏、UB、外部 kill 或 libc 内部自己发生的终止；setjmp 不是内存安全隔离。固定库的直接 exit/abort/assert 动态导入已查无残留，_Exit 只作为不处于 controlled 边界的不可支持 legacy 路径兜底；legacy C 入口已 hidden，Node 只调用 controlled。同步文件 I/O 与 callback 仍可能永不返回；不承诺有界 join。fatal 途中的 VM/RAM/其它分配不释放，不能复用 owner。这里没有全量 VM teardown。

## 构建

固定源码归档 SHA256：`be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555`。`source-lock.json` 校验所有补丁及 native 输入。Linux 宿主用官方 Node 24.22.1 头；host-test 模式故意导入普通 Node N-API，绝不能把此输出放 HAP。

```sh
python3 runtime/ohos/linux/native/build.py \
  --source-archive /inputs/tinyemu-2019-12-21.tar.gz \
  --node-headers /inputs/node-v24.22.1/src \
  --output /build/linux-host --cc /usr/bin/cc --host-test
```

OH 正式路径（本环境未执行）：

```sh
cmake -S runtime/ohos/linux/native -B /build/linux-oh -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/sdk/native/build/cmake/ohos.toolchain.cmake \
  -DOHOS_ARCH=arm64-v8a \
  -DDSH_TINYEMU_ARCHIVE=/inputs/tinyemu-2019-12-21.tar.gz \
  -DDSH_NODE_HEADERS=/inputs/node-v24.22.1/src \
  -DDSH_NODE_LIBRARY=/build/arm64-v8a/libnode.so \
  -DDSH_NODE_RENAME_HEADER="$PWD/runtime/ohos/node/napi-rename.h" \
  -DDSH_OH_SDK_NATIVE=/sdk/native
cmake --build /build/linux-oh
```

输出 `/build/linux-oh/generated-linux/libdsh_linux.so`。也可在原有 `runtime/ohos/native/build-hap-libs.py` 全部参数后附 `--tinyemu-source /inputs/tinyemu-2019-12-21.tar.gz`，自动 CMake 构建、strip、加入原生集合并执行现有全 ELF/N-API audit。TinyEMU 与 slirp 静态进入该库；仅系统库/既有 libnode 动态依赖，未新添 C++ runtime。生产 build.py 不接受省略 SDK/libnode/rename 输入。

`build-hap.sh` 和 `check-arkts.sh` 在 native 目录包含该库时才随 HAP 放入；前者结束时清理本次放入文件。`audit-hap.py` 以实际 native 输入决定必需库集合并比较载入段字节；existing native set audit 自动检查 renamed N-API 与 libnode DT_NEEDED。compose-runtime 加入 linux 顶层 .mjs 和 TinyEMU/slirp notices，C/native 研究文件不进入运行时 ZIP。调用 HAP 的其它既有参数和权限不变，Android 未修改。

## 验证和未完成项

`tooling/ohos/research/tinyemu-native/run.py` 是登记的定向门：真实重编基线/候选、Node jit/strict socket/stop/join、EMFILE 构造失败恢复、三类 oversized 真实启动错误、三类显式 fatal 边界、slirp 断开、受影响 core3/CLINT13/低写1、实际 rename-header 编译导入、NODELETE/RUNPATH 检查。可附 `--guest-config`，接已生成独立909镜像执行真实 Node插件→四盘安装→pivot_root→903 agent→python/gh/git/rg→双EOF/ACK→stop/join。guest config 是本机测试输入，不是 production SIM 开关。

940 增加 `fs_export.c` 与补丁 0016：嵌入构建（`-DDSH_FS_EXPORT`）里 `fsN` 设备不再用上游 fs_disk，而是逐级 `openat(O_NOFOLLOW)` 从导出根重新解析每个操作的路径、拒绝 `.`/`..`、所有对象报告为客体作业身份 60081、错误码按 Linux errno 原样回传、打开时带 O_NONBLOCK。上游 fs_disk 用路径字符串交给宿主解析，客体造一个指向宿主路径的符号链接或把已打开 fid 的父目录换成链接，宿主就会跟着走出导出根；`tooling/ohos/tests/linux-fs-export.test.py` 对这些情形逐项验证。授权 FD 根（grants/）仍是研究件。本件不负责正式安装 RPC。首次下载/准备/guest tar/工具overlay/同VM交接已有不同范围真实证据，但还没有一份最终签名 HAP 实装证据。所有工具测试均在 Linux host 仿真，gh pr list 真实账号留本机测。关闭 Linux 后 owner 仍隔离，不能同 App 重新启动；正常连续作业必须复用仍运行的 VM，不以每 job 停机。父级必须把 903 的取消标志、leader实际退出状态、双流ACK与租约收尾保留，绝不以 native join 代替 job complete。

## 1208：CLINT 的无符号未来截止时间

0018 修复 `riscv_machine_get_sleep_duration` 先计算 unsigned 差再存入 int64_t 的错误。`mtimecmp` 为 UINT64_MAX 或其它相差超过 INT64_MAX 的未来值时，旧实现误置 MTIP、唤醒真实 WFI 并把 sleep delay 变成 0。RISC-V 的比较是 unsigned mtime >= mtimecmp；现在先按这个关系判断到期，只有确定在未来才计算 uint64_t 剩余量并按原毫秒取整/上限截断。等于截止或邻近过去、低32位回卷、已 pending MTIP、CPU 非休眠与原 10 ms 上限保持既有行为。极远过去值也被纠正：例如 mtime=UINT64_MAX、mtimecmp=0 时，旧差值回卷成1而漏置MTIP，新实现按unsigned关系正确置位。

针对入口 `tinyemu-clint-deadline` 重编实际宿主对象，覆盖 RV32/RV64 各7个边界、既有13个clock用例和低字写1项，另由真实 Node/TinyEMU 执行设置 UINT64_MAX、启用 MTIE 再 WFI 的小客体 BIOS，在 plain/jitless 两模式计数零等待 select 和 VM线程CPU时钟。clock 注入只用于边界C夹具；Node BIOS 用实际时钟。该错误能使特定裸 BIOS 忙转，尚无实际 Linux 内核空闲路径或设备CPU占比归因证据。没有扩大 MAX_SLEEP_TIME；普通 WFI 的约100Hz轮询与 slirp/停止唤醒调度另行处理。详见 `tooling/ohos/research/tinyemu-clint-deadline/README.zh.md`。

## 1217：embedded RISC-V 微秒等待

0019 在实际 embedded RISC-V 的 select 最后边界使用微秒下取整，避免未来不足1ms的CLINT截止时间被毫秒取整成零而反复忙转。先保留slirp/fs的毫秒预算，再用CPU微秒预算截断；仍保留10ms最大请求、不足1µs可零等待、旧毫秒接口及其他class语义。它包括0018前置，不改停止唤醒或slirp调度。真实旧毫秒API与非embed兼容边界、RV32/RV64实际WFI/select及原clock回归由 `tinyemu-sleep-micros` 门验证；目标设备和完整Linux网络/9p语义不由边界夹具代证。详见 `tooling/ohos/research/tinyemu-sleep-micros/README.zh.md`。

## 0020：嵌入 slirp 的 UDP 到期身份（1220）

上游 `curtime` 与 `so_expire` 是 32 位毫秒。新 UDP 在 `UINT32_MAX-1000` 创建时，四分钟后的截止值回卷成一个更小的非零数，既有 `so_expire <= curtime` 会在下一次 fill 立即关闭真实 FD；截止值恰为零又会和“永久 listener”哨兵混淆。该边界是受控时钟注入的宿主复现，没有手机已经遇到的证据。

0020 只在 `TEMU_EMBED` 为私有 socket 保留 64 位最近续期起点和 32 位 duration，以 duration 0 表示未启用超时。`slirp_select_poll` 仍只读取一次 `CLOCK_MONOTONIC`，宽值供 UDP 使用，其低 32 位仍写回原 `curtime`；DNS 一秒缓存、TCP fast/slow timer 的字段与判断没有改变。固定 duration 仍为 240000/10000 ms，并在编译期检查为正且小于 `2^31`。不能仅凭 duration 小于半周期，就假定宿主停止调度的间隔也小于半周期；因此没有只改成 32 位 signed 差比较。

对可表示的单调时间区间，UDP 在 `now-start >= duration` 时到期；所有 attach/listen/send/recv 续期以及清零调用统一走该状态。低 32 位 `so_expire` 保留给原诊断显示，不再兼任 OH 的永久哨兵。成功发送才续期；普通接收续四分钟、DNS foreign-port 为 53 的分支续十秒；永久 listener 收发仍永久。非嵌入构建继续使用原字段、原零哨兵和原比较，没有把修复扩散到 Android 或独立上游模拟器。

首次 poll 的合同来自实际调用顺序：`slirp_open`/`slirp_init` 只初始化空 UDP 链；`virt_machine_run` 先完成 net select/poll，随后才 dispatch CPU。客体 virtio TX 经 `slirp_input` 到 UDP/ICMP 创建临时 socket，RA 临时 listener 也只在 TCP 流量处理中创建。可早期调用的公开 host-forward listener 使用永久标志；固定 OH 启动链没有调用这个 API。产品网络回调在唯一 VM 线程同步执行，未新增线程或全局信号。任意外部调用者在首次 poll 前直接调用内部 `udp_attach` 不属于该 OH 调用合同。

私有 socket 布局在嵌入构建改变，必须完整重编所有 slirp 对象，不能把新旧布局的对象混链。当前 Linux x86_64 宿主实测 socket 168→184 字节、Slirp 1088→1120 字节；这不是目标 SDK ABI 检查。非嵌入两边布局相同。库名、N-API 导出、Node 与 Dart 接口不变。

定向门 `slirp-udp-expiry` 从固定归档新鲜构建完整生产链；在研究副本依次逆掉依赖层 0024、0023，得到公共历史层，再仅逆 0020 构造旧实现。后两者只有 0020 的六个文件不同；同一 31 用例旧实现 11 个缺陷断言失败、公共历史层和完整当前 OH 候选分别 31/31；非嵌入两边 31 行真实行为记录完全相同，刻意保留其 11 个旧缺陷。另用实际 `temu.c` 私有 slirp 适配器与真实 loopback UDP 检查首 poll 在首包前更新时钟；CPU 批次是显式测试包生产者，并非客体指令。所有 `fcntl`/`EBADF`、socket 收发及 slirp list 操作真实执行。没有将旧缺陷复现算成 31 项通过。

此补丁不扩大 10 ms 等待预算、不增加 waker、不修 TCP fasttimo 的零哨兵，也不消除 1211 的其它阻点。到期仍在原 fill/poll 顺序按已采样时间判定，不承诺宿主墙钟精确四分钟或有界线程调度。宽计时的证明限于单调、有效且可表示的毫秒区间；没有新加对既有 clock_gettime 失败的兜底。SDK/设备尚未运行。

## 许可

固定 TinyEMU 核心 MIT；实际编入的 slirp 包含 MIT/BSD 类声明及原作者通知，逐文件首部原文收入 THIRD-PARTY-NOTICES.txt 并随 runtime ZIP 分发。这里没有新增 HAP 用户态工具包；Alpine/BusyBox、Bellard Linux内核及903 APK工具的对应源码/许可证闭包仍属镜像分发，不能以本 native notices 替代。Node N-API 为已固定 Node 依赖。

## 1228：TCP delayed ACK 的零时基

0021 仅在 TEMU_EMBED 下把 fasttimo 的挂起状态与32位时间戳分开。真实 TCP 输入置 TF_DELACK 后，fill 首次登记当前时间并置 pending；poll 到达原有2ms条件时执行 tcp_fasttimo 并清 pending。curtime 在32位回卷恰为0也可登记，不会被误当成无定时器而推迟到下一次 fill。不会改变2ms条件、499ms slow timer、select等待上限、UDP或停止唤醒；非嵌入预处理结果保持相同。32位模时间的旧有限范围仍在，未扩成跨完整32位周期暂停的期限保证。

针对门 slirp-fasttimo fresh 构建固定源码，以真实 slirp/TCP/loopback 与明确的 guest Ethernet/单调clock边界验证13场景；原7绿6红、候选13绿，另核重复登记、第二数据段、连接关闭及select错误路径。该门没有执行guest指令，也不测手机或墙钟ACK时限。SDK/设备需本机验证；不是1211长等待方案。

## 1267：历史对照的依赖闭包

`--host-test --host-baseline` 仅用于 fatal/SIGPIPE 反例，排除 0012、0013、0017 及依赖它们的 0023、0024。当前 NAPI binding 仍使用唤醒入口，因此此模式另外编译研究目录 `tinyemu-native/baseline-entry.c`：它只把新入口转到真实旧 controlled ABI，并提供零值 wait-error TLS，不模拟事件等待。构建收据记录全部跳过项与桥源码摘要。原 oversized、exit/abort/assert、SIGPIPE 反例之前，新增真实 Node 加载、客体输出、stop/join 阳性控制，防止未解析符号被误算成预期进程退出。正常宿主/正式 OH 构建不编译此桥，仍应用完整生产补丁链。

UDP 与 TCP 研究门均在完整生成源码的副本上用 `--fuzz=0` 逆掉 0024→0023，再分别仅逆 0020 或 0021。两层间六/一个 C/H 文件差及原 11/6 个失败集合独立检查；完整当前生产链另以 `candidate-embed` 执行同样 31/13 场景，不能用历史层通过代替它。UDP 两侧非嵌入行/布局、TCP 两侧非嵌入行/预处理结果与首 poll 原合同仍保留。历史层是目标修复的受控反例，不是当前生产版本。

正式 `tinyemu-native` 登记还要求独立四盘工具 guest 配置；没有该输入时，仅运行无 `--guest-config` 的宿主部分不能把整登记标为通过，也不能用小 BIOS 或 demo Linux 替代工具 guest。
