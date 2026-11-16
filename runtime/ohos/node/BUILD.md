# O7b：鸿蒙专用 libnode.so 的可复现构建入口

**未在真机核实。** 交叉编译与链接已在 Linux 主机完成，结果见下文「实测」；HAP 装载和一切运行行为均为 NOT_RUN。离线 ELF 审计不能替代真机加载。

## 固定输入

Node 必须为 **24.22.1**，源归档为 [node-v24.22.1.tar.xz](https://nodejs.org/dist/v24.22.1/node-v24.22.1.tar.xz)。官方 [SHASUMS256.txt](https://nodejs.org/dist/v24.22.1/SHASUMS256.txt) 列出的 SHA256 为 `4f5379796280cdaeb0c2f358fd04b6a16cc4fb7dfa83b5a8c91a9d963b435231`，脚本强制核验。

SDK 为 OpenHarmony native SDK **API 26（26.0.0.38）**，由 `native/oh-uni-package.json` 的 `version` 确认。Flutter-OH 同样要求 API 26。脚本只用它的 sysroot、`ld.lld` 和 `llvm-ar` / `llvm-nm` / `llvm-ranlib` / `llvm-readelf` / `llvm-strip`，不用它的编译器。

LLVM 必须为 **23.1.1**，源归档为 [llvm-project-23.1.1.src.tar.xz](https://github.com/llvm/llvm-project/releases/download/llvmorg-23.1.1/llvm-project-23.1.1.src.tar.xz)（179168672 字节），SHA256 `ebe9be46fe8756d58c5b198ffad0fa2a766257add81a4dc52179bfacc7888ee6`，脚本强制核验。本机核对过 GitHub 发布资产摘要，并用 [release-keys.asc](https://releases.llvm.org/release-keys.asc) 验证了同目录 `.sig`（Tobias Hieta，指纹 `D574 BD5D 1D0E 9889 5E3B F900 44F2 485E 45D5 9042`）。

构建主机为 Linux，Python 3.12+、GNU make、GNU patch、CMake、Ninja、clang 23.1.1（本机为 Arch `clang 23.1.1-1`）、宿主 C/C++ 编译器（本机 GCC 16.2.1）和官方 Node 24.22.1。Node 官方 [BUILDING.md](https://github.com/nodejs/node/blob/v24.22.1/BUILDING.md) 的 Linux GCC 下限为 12.2。目标编译器与宿主编译器分开设置；不让交叉编译器去产生构建时需要运行的宿主工具。构建工具 esbuild 固定为 0.27.3，由 O7a 的完整性锁安装。

## SDK 编译器不能构建 Node 24

SDK 自带 clang 15.0.4 和它的 libc++ 实测在两处失败，均不是加参数能解决的：

- `deps/ada/ada.h`：`no member named 'find_if' in namespace 'std::ranges'`，以及 lambda 捕获结构化绑定（clang 16 起支持）。要求更新的编译器和 libc++。
- `deps/zlib/crc32_simd.c`：`Cannot select: intrinsic %llvm.aarch64.crc32b`，clang 15 忽略 `target("arch=armv8-a+aes+crc")`。clang 23 能正确编译这个属性，`zlib.gyp` 不需要改。

因此目标代码用主机 clang 23.1.1 编译，配同版本源码构建的静态 C++ 运行库。上游 clang 自 17 起认识 `aarch64-linux-ohos`，不需要 OpenHarmony 的 LLVM 分支。脚本没有回退到 SDK 编译器的路径：`--clang` 和 `--cxx-runtime` 必填，且运行库记录的编译器摘要必须与 `--clang` 一致。

## 执行

内嵌 Undici 由 `tooling/ohos/prepare-node-fetch.mjs` 准备：它包含 `patch-undici.mjs` 的请求体重定向修复和响应体取消原因修复，只跑这一个入口。旧入口不认识新 bundle，第二次运行会拒绝。构建完 `build-node.py` 核对 libnode 里恰好有一份这个 bundle，结果写进 `build.json` 的 `embeddedUndici`。js2c 按 Latin-1 或 UTF-16 存源码，所以比的是这种编码，不是文件的 UTF-8 字节。

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix runtime/ohos/node/build-tools

python3 runtime/tests/ohos/node-build.py --source /absolute/pristine-node-v24.22.1

python3 runtime/ohos/node/build-runtimes.py \
  --sdk-native /absolute/sdk/native \
  --clang /usr/bin/clang \
  --source-archive /absolute/llvm-project-23.1.1.src.tar.xz \
  --work /absolute/new-runtimes-build \
  --output /absolute/ohos-llvm-runtimes \
  --jobs 4

python3 runtime/ohos/node/build-node.py \
  --sdk-native /absolute/sdk/native \
  --clang /usr/bin/clang \
  --cxx-runtime /absolute/ohos-llvm-runtimes \
  --source-archive /absolute/node-v24.22.1.tar.xz \
  --host-node /absolute/node-v24.22.1-linux-x64/bin/node \
  --work /absolute/new-node-ohos-build \
  --output /absolute/new-node-ohos-artifacts \
  --jobs 4
```

`build-runtimes.py` 只解压运行库需要的目录，产出 `lib/{libc++,libc++abi,libunwind}.a`、`include/c++/v1`、`clang-resource/`（compiler-rt builtins 与 crt 对象，`include` 指向主机 clang 的资源目录）和 `runtimes.json`。`--output` 可以在多次 Node 构建间复用；换了 clang 就要重建。

`--work` 和 `--output` 必须是新目录。脚本在校验输入后创建它们，不删除旧构建；中断时保留 `build-plan.json`、工具链包装脚本和阶段日志。`configure.log` / `make.log` 给出实际编译失败点。本机可用 `build-plan.json` 中的精确环境和命令，在保留的源目录继续执行（`make` 从中断处接着编）；不要未经核对就复用别的 Node/SDK 版本的构建缓存。脚本只构建 `libnode` 目标，默认目标还会链接 cctest、embedtest 等不发布的可执行文件。

脚本先按归档实际成员大小检查解压空间，记录开始时的可用空间；`build.json` 记录实际耗时和工作目录大小。主机内存同样是约束：宿主 GCC 编译 V8 时单个进程可达 1.8 GB，14 GB 内存、与其他任务共用的机器上 `-j6` 实测耗尽了内存和交换区，`-j4` 配 `systemd-run --user --scope -p MemoryHigh=6G` 可以跑完。

## 产物与配置

| 项目 | 构建设置与核验 |
| --- | --- |
| 目标 | `--dest-os=openharmony --dest-cpu=arm64 --cross-compiling --shared` |
| 编译器 | 主机 clang 23.1.1，`--target=aarch64-linux-ohos`，SDK sysroot，`-resource-dir` 指向 `--cxx-runtime`；宿主 GCC 单独配置 |
| 链接器 | SDK `ld.lld`（`--ld-path`），`-Wl,--no-undefined`；clang 23 的目标文件可由 lld 15 正常链接 |
| 线程局部存储 | 模拟 TLS（`__emutls_*`）。SDK clang 15 和上游 clang 23 对这个目标的默认值相同，实测两者生成相同的重定位；SDK 工具链文件只在 HWASan 时才加 `-fno-emulated-tls`。`__emutls_get_address` 来自静态链入且隐藏的 builtins |
| 默认执行 | `--v8-options=--jitless`，宿主启动参数再次固定 `--jitless` |
| Node 内置功能 | SQLite、zstd、OpenSSL 保留原来的静态内置配置，配置文件中断言其相关选项 |
| ICU | `small-icu`，`root,en`；Unicode 字符串和 UTF-8 文件名保留，完整的中文 Intl 本地化数据不是本构建的承诺 |
| 环境选项 | 禁用 `NODE_OPTIONS` 解析，宿主明确传 `--import`、`--expose-internals` 等固定参数 |
| Inspector | 禁用；本机引擎不开放调试端口 |
| 内置快照/代码缓存 | 交叉构建显式禁用；不禁止 O2 对用户模块启用 `module.enableCompileCache` |
| ELF | AArch64、ET_DYN、无 PT_INTERP，SONAME 必须为 `libnode.so` |
| C++ 运行库 | LLVM 23.1.1 的 libc++、libc++abi、libunwind、compiler-rt builtins 经 `-static-libstdc++` 静态链入，`libnode-exports.map` 不导出它们 |
| 嵌入 runner | `runtime/ohos/host/node_runner.cpp`、`publication_binding.cc` 在 configure 后用 `out/libnode.target.mk` 里的 gyp 参数预先编译，再经 `toolchain/link` 链入 libnode。不改 Node 源码和 gyp。Node 关闭 RTTI，RTTI 开关会改变 `std::function` 的布局，所以参数必须一致。`make` 还会链接 openssl-cli，所以只属于 libnode 的链接项放在 `link` 包装脚本里，不放 `LDFLAGS` |
| N-API 与导出表 | 全程 `-include napi-rename.h`；`libnode-exports.map` 默认拒绝，只导出 `dsh_napi_*`、`dsh_node_api_*`、`dsh_node_start`、`dsh_node_stop` 和 require-builtin 的六个符号。V8、libuv、OpenSSL、zlib、ICU、SQLite 都不导出 |

输出包括精简后的 `libnode.so`、Node 合并许可证和 `build.json`。`libnode.so` 不再依赖 `libc++_shared.so`，不需要为它分发；HAP 仍要带 SDK 的那份给 `libdsh_host.so`。报告记录源码/补丁摘要、实际 SDK manifest、编译器和链接器的摘要与版本、运行库摘要、精确环境与命令、原始和精简库大小及摘要、ELF 动态信息和符号审计。仅在构建真正完成后才产生这些大小。

脚本在产出前审计：NEEDED 全部存在于 SDK sysroot；每个导出都匹配 `libnode-exports.map`，因此没有 `napi_*`、`node_api_*`、`uv_*` 和 C++ 运行库符号；C++ 导出恰好是 `native/loader/source-pins.json` 的六个，反修饰后不含 `std::`；`napi-rename.h` 的每个目标名和导出表的每个确切符号都确实导出；带 `NODELETE`，无 RUNPATH；通过 `runtime/ohos/host/napi_isolation.py`；所有强导入都能由 NEEDED 库在 sysroot 中的版本提供。sysroot 的 `libc.so` 是接口存根，这证明的是 SDK 公开接口，不证明设备上的实现。

Node 上游 [共享库说明](https://github.com/nodejs/node/blob/v24.22.1/doc/contributing/shared-library.md) 将共享库构建列为非正式支持方式，列出的已测试平台不包含 OpenHarmony。固定源码已包含 OpenHarmony 目标支持，也不等于本脚本的所有链接步骤已获设备验证。

## 五处固定源码变更及其依据

所有源码前后摘要在 `node24-ohos-pins.json`，源码 diff 在 `node24-ohos.diff`。它们只应用到本脚本新解压的鸿蒙构建树；没有接入 Android 构建入口。

1. **共享库命名。** [configure.py](https://github.com/nodejs/node/blob/v24.22.1/configure.py) 约 1849 行只对 Android 使用 `so`，其他 Linux 宿主目标会得到 `so.137`。为 OpenHarmony 也选择 `so`，让实际链接产物和 SONAME 都是 `libnode.so`，不靠重命名一个不同 SONAME 的库补救。
2. **完整关闭 io_uring 探测。** [libuv linux.c](https://github.com/nodejs/node/blob/v24.22.1/deps/uv/src/unix/linux.c) 的 `uv__use_io_uring` 在约 479 行，对非 SQPOLL 分支先返回 1，到约 489 行才读取 `UV_USE_IO_URING`。因此环境变量 0 不能覆盖该路径。仅当同时定义 `__OHOS__` 与 `DSH_GO_EMBEDDED_RUNTIME` 时，采用已有 Android 分支同样的直接返回 0，使用 epoll/线程池路径。手机 seccomp 行为仍须实测；不安装可能干扰 Ark 的 SIGSYS handler。
3. **保留宿主的进程设置。** [node.cc](https://github.com/nodejs/node/blob/v24.22.1/src/node.cc) 的专用分支调用初始化时传入 `kNoStdioInitialization`、`kNoDefaultSignalHandling`、`kNoAdjustResourceLimits`；这些标志来自该版本公开 `node.h`，分别避免 Node 接管已经由宿主处理的 stdio、信号和资源上限。其他初始化仍由 `node::Start` 完成。
4. **把正常 JS process.exit 限定到引擎结束。** 官方 [node.h](https://github.com/nodejs/node/blob/v24.22.1/src/node.h) 明确说明默认退出处理会调用进程级 `exit()`。在 `NodeMainInstance::Run` 的专用分支安装 `SetProcessExitHandler`，记录原退出码并 `Stop(env)`，随后不让空的 SpinEventLoop 返回值覆盖它。这是针对进程内嵌入的源码修复候选，尚未执行重编后的 Node。`process.abort()`、原生崩溃、OOM 等仍可能终止整个应用；线程不是故障隔离边界。

5. **补上 V8 缺的 `<atomic>`。** [wasm/pgo.h](https://github.com/nodejs/node/blob/v24.22.1/deps/v8/src/wasm/pgo.h) 声明里用了 `std::atomic`，只靠其他头文件间接带入；libc++ 23 不再提供，编译报 `no template named 'atomic' in namespace 'std'`。宿主 GCC 不受影响。

后四处仅在 **`__OHOS__ && DSH_GO_EMBEDDED_RUNTIME`** 同时成立时启用。针对真实固定源码，测试比较了预处理主体（`#include` 行保留为惰性文本，不展开）：Linux、Android，以及未开启专用宏的 OpenHarmony，修改前后逐字一致。Python 的命名分支也实测 Linux / Android / macOS 结果不变。此证据证明补丁选择边界，不证明目标二进制 ABI 或字节完全一致。

链接时给目标设置 `-Bsymbolic-functions`，让 Node 库内部函数优先绑定其自身定义；Node/Ark 的隔离靠下文的 N-API 改名，不靠这个选项。

## 宿主与原生 addon 须知

Ark 的 `libace_napi` 在同一进程导出同名 `napi_*`，env 和 value 语义不兼容。按 OpenHarmony 6.1 musl `dynlink.c` 的审读结论（本机未独立复核），普通应用 `.so` 运行在 `moduleNs_*` 命名空间，`is_permitted` 拒绝它调用 `dlns_create2` / `dlopen_ns`，linker namespace 隔离不可用；musl 上的符号版本也靠不住。所以 Node 的 N-API 改名，不和 Ark 共用任何名字：

| 组件 | 编译方式 | 用到的符号 |
| --- | --- | --- |
| `libnode.so`，含 runner 和 `dsh_ohos_publication` | 目标编译全程 `-include napi-rename.h`（包装脚本注入，宿主工具不受影响） | 导出 `dsh_napi_*`、`dsh_node_api_*`、`dsh_node_start`、`dsh_node_stop` |
| `.node` addon | **必须同样** `-include runtime/ohos/node/napi-rename.h` | 导入 `dsh_napi_*`，`NEEDED libnode.so` |
| `libdsh_host.so` | 不 force-include，用 Ark 的 `napi/native_api.h` | 用 Ark 的真 `napi_*`，只经 C 函数 `dsh_node_start`、`dsh_node_stop` 进入 Node |

`napi-rename.h` 由 `gen-napi-rename.py` 从固定的 `src/js_native_api.h`、`src/node_api.h` 生成，两个头文件的 SHA256 钉在脚本里；构建和 `runtime/tests/ohos/node-build.py` 都用 `--check` 确认它是最新的。列表与官方 Linux Node 24.22.1 动态导出的 161 个 `napi_*` / `node_api_*` 函数逐一相同。

addon 构建者要做的：

1. 编译时加 `-include <repo>/runtime/ohos/node/napi-rename.h`，其余照常包含 Node 24.22.1 的 `node_api.h`，源码不用改。`napi_register_module_v1` 和 `node_api_module_get_api_version_v1` 是 addon 自己导出的入口，不在改名之列。
2. 链接 `libnode.so`，加 `-Wl,-z,defs`。
3. 产出后检查 `llvm-nm -D --undefined-only`：不得出现 `napi_*`、`node_api_*`（否则会绑定到 Ark），`dsh_*` 必须都在 libnode 的导出里。`build-flock.py`、`build-loader.py` 已包含这项拒绝。未经此法构建的现成预编译 addon 不能用。
4. 只能用 N-API。libuv、`v8::`、`node::` C++ API 不导出，依赖它们的 addon 在 `-z defs` 下链接失败。
5. 不得依赖 `libc++_shared.so`，`napi_isolation.py` 会拒绝。C addon 用哪个编译器都可以（flock 用 SDK clang）；C++ addon 用 clang 23 和 `--cxx-runtime` 的静态 libc++（`build-loader.py`）。

libnode 内部的 libc++ 是 `std::__1`，SDK 的是 `std::__n1`，两者都带 `__cxa_*` 和 `operator new`；libnode 的那份不导出，所以不会互相干扰。不要让 C++ 异常或 `std::` 对象跨过 addon 与 libnode 的边界。

`dsh_node_start`、`dsh_node_stop`（`runtime/ohos/host/node_runner.cpp`）编入 libnode，是 `libdsh_host.so` 进入 Node 的唯一入口。runner 用的 `node::`、`v8::` 嵌入 API 带 `std::` 类型，留在库内不导出，`node::Start` 也不再导出。`libnode-exports.map` 另导出 `native/loader/source-pins.json` 列出的六个符号，供 require-builtin addon 经 `dlsym(RTLD_DEFAULT, …)` 读取；这要求 libnode 处于全局查找范围，是否成立只能在设备上确认。

`-Bsymbolic-functions` 只让 libnode 内部调用绑定自身，挡不住别的库绑定到它的导出，真正起隔离作用的是改名和默认拒绝的导出表。模拟 TLS 的键也归各库自己：`dlclose` libnode 不受支持，它的 pthread key 和析构函数不会卸载，库应驻留到进程退出。

## HAP 原生库集合

`runtime/ohos/native/build-hap-libs.py` 在 `build-node.py` 的输出旁构建其余的库，放进新目录，并把集合作为整体审计：

```sh
python3 runtime/ohos/native/build-hap-libs.py \
  --sdk-native /absolute/sdk/native \
  --clang /usr/bin/clang++ \
  --cxx-runtime /absolute/ohos-llvm-runtimes \
  --libnode-output /absolute/new-node-ohos-artifacts \
  --node-source /absolute/pristine-node-v24.22.1 \
  --flock-package /absolute/node-addon-system-0.1.2 \
  --loader-source /absolute/dsh-node-addon-require-builtin-a58d3599 \
  --node-addon-api /absolute/node-addon-api-8.9.2 \
  --work /absolute/new-hap-libs-build \
  --output /absolute/hap-libs/arm64-v8a
```

三个第三方输入都不进仓库，由 `build-flock.py`、`build-loader.py` 按各自的 SHA256 核对：`@deepseek-ai/node-addon-system` 0.1.2 和 `node-addon-api` 8.9.2 来自 npm，loader 源码来自 `native/loader/source-pins.json` 的 `archiveURL`。

| 库 | 来源 |
| --- | --- |
| `libnode.so` | `build-node.py` |
| `libdsh_host.so` | `app/ohos/entry/src/main/cpp/CMakeLists.txt`，SDK 工具链文件，`-z defs` |
| `libdsh_flock.so` | `build-flock.py` 的 `system.node`，SDK clang |
| `libdsh_require_builtin.so` | `build-loader.py` 的 `require_builtin.node`，clang 23 和静态 libc++ |
| `libc++_shared.so` | SDK `llvm/lib/aarch64-linux-ohos`，只有 `libdsh_host.so` 依赖它 |

审计（写入 `--output` 旁的 `audit.json`，有问题则失败）：每个库的 NEEDED 闭包都在集合或 SDK sysroot 内；每个强导入都能在自己的 NEEDED 闭包里解析；无 RUNPATH；原名 N-API 导入只出现在 `libdsh_host.so` 且由 `libace_napi.z.so` 提供；`dsh_napi_*` 导入只流向 libnode，只有 libnode 定义它们；除 addon 两个入口外，没有库定义原名 N-API。

`tooling/ohos/build-hap.sh` 从 `DSH_OHOS_NATIVE_LIBS` 把 `libnode.so`、`libdsh_flock.so`、`libdsh_require_builtin.so` 放进 `app/ohos/entry/libs/arm64-v8a`，缺任何一个都直接失败，退出时清掉，`app/ohos/.gitignore` 挡住它们。`libdsh_host.so` 和 `libc++_shared.so` 不放：`entry/build-profile.json5` 的 `externalNativeOptions` 让 hvigor 按同一份 CMake 对放入的 libnode 重新构建宿主，放进预编译的一份会重名。因此 HAP 里的 `libdsh_host.so` 与这里审计的不是同一份字节，同一个 CMake 门会在 hvigor 构建时再跑一次。hvigor 是否打包 `libc++_shared.so` 本机没有验证过。

## 实测

本机（16 核、14 GB，与其他任务共用）从空目录完整重跑 `build-runtimes.py` 和 `build-node.py` 的结果，API 26 SDK、clang 23.1.1、lld 15.0.4、GCC 16.2.1：

| 项目 | 结果 |
| --- | --- |
| 耗时 | 运行库 30 秒（`-j5`）；Node 4147 秒（`-j4`，内存上限 6 GB）；其余原生库 8 秒 |
| 磁盘 | Node 工作目录 1696484303 字节；运行库构建目录 278 MB，安装目录 20 MB |
| 可复现性 | 保留树增量重链和从空目录重建，未精简库 SHA256 相同（`7613329a…`），下表五个库逐字节相同。两次用同一 `--work` 路径；换路径未测 |
| ELF | ELF64、AArch64、ET_DYN，无 PT_INTERP，SONAME `libnode.so`，无 RUNPATH，BIND_NOW |
| NEEDED | `libdeviceinfo_ndk.z.so`、`libc.so` |
| 动态导出 | 169 个：161 个 `dsh_napi_*` / `dsh_node_api_*`、`dsh_node_start`、`dsh_node_stop`、require-builtin 的 6 个；无 `napi_*`、`node_api_*`、`uv_*`、C++ 运行库符号，无带 `std::` 的导出 |
| 动态导入 | 476 个，强导入全部由 SDK sysroot 的 `libc.so`、`libdeviceinfo_ndk.z.so` 提供；sysroot 之外只有 8 个弱引用（`ZSTD_trace_*` 4 个、`__cxa_thread_atexit_impl`、`__register_frame_info`、`__deregister_frame_info`、V8 的 `_ZTH…g_thread_in_wasm_code`） |
| TLS | 无 PT_TLS，无 TLS 重定位 |
| 大小 | 未精简 107838320 字节，`--strip-unneeded` 后 81662168 字节（SHA256 `6771313b…`） |

`build-hap-libs.py` 产出的集合，审计无问题：

| 库 | 精简后字节 | NEEDED | 导出 | 强导入 | 原名 N-API 导入 | `dsh_*` N-API 导入 |
| --- | --- | --- | --- | --- | --- | --- |
| `libnode.so` | 81662168 | `libdeviceinfo_ndk.z.so`、`libc.so` | 169 | 466 | 0 | 0 |
| `libc++_shared.so` | 1262248 | `libc.so` | 2357 | 167 | 0 | 0 |
| `libdsh_require_builtin.so` | 872840 | `libnode.so`、`libc.so` | 4 | 147 | 0 | 32 |
| `libdsh_host.so` | 121888 | `libace_napi.z.so`、`libhilog_ndk.z.so`、`libnode.so`、`libc++_shared.so`、`libc.so` | 41 | 140 | 19 | 0 |
| `libdsh_flock.so` | 9248 | `libnode.so`、`libc.so` | 4 | 27 | 0 | 23 |
| 合计 | 83928392 | | | | | |

合计不含 Flutter 自己的 `libflutter.so`、`libapp.so`，本机没有这两个库。`libdsh_flock.so`、`libdsh_require_builtin.so` 的 SONAME 仍是 `system.node`、`require_builtin.node`，只有文件名按 HAP 映射改过。

离线负向检查：审计拒绝缺 `libc++_shared.so`、缺 `libnode.so`、未改名 addon、不依赖 libnode 的改名 addon、带 RUNPATH、第二个定义改名 N-API 的库、无处解析的强导入；门拒绝把 addon 当 Ark 模块、把 Ark 模块当 addon，以及已删除的 `runner` 角色。libnode 里 `builtin_module_require` 的实际机器码是 `bti c; ldr x0, [x0, #440]; ret`，loader 的解码器支持这个形状；这只是读了指令和解码器源码，没有在 ARM64 上跑过探针。

## 本机必须完成的验收

下列项目仍为 **NOT_RUN**，没有 HarmonyOS 设备：HAP 构建与打包、签名分发、`libnode.so` 实际装载、Ark/Node 符号解析、require-builtin 的 `dlsym(RTLD_DEFAULT, …)` 能否看到 libnode、首次/重复启动、内置 SQLite、zstd、TLS 证书校验、jitless 无 wasm、普通 `process.exit(7)` 返回退出码且应用存活、Node 退出后不能再次启动。最终内置 Fetch 的 multipart 测试必须去掉 O7a 的候选 bundle 替代加载，直接针对编入共享库的内置版本运行。
