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

## 许可

固定 TinyEMU 核心 MIT；实际编入的 slirp 包含 MIT/BSD 类声明及原作者通知，逐文件首部原文收入 THIRD-PARTY-NOTICES.txt 并随 runtime ZIP 分发。这里没有新增 HAP 用户态工具包；Alpine/BusyBox、Bellard Linux内核及903 APK工具的对应源码/许可证闭包仍属镜像分发，不能以本 native notices 替代。Node N-API 为已固定 Node 依赖。
