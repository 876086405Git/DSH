# HAP 原生库与 Node addon 的文件映射

本项只闭合 JS 入口到两个固定库文件的映射。Linux 已用真实 addon 完成严格仿真；目标库的交叉编译和 ELF 审计已离线完成（`runtime/ohos/node/BUILD.md`），HAP 安装和设备加载均未验证。宿主目录接线另属 P1B/P2 后继版本，不能把本项单独视为可发行的 HAP。

## 两类文件

| 生产者 | HAP `entry/libs/arm64-v8a/` 文件 | 消费方式 |
|---|---|---|
| libnode 主线构建，含 `runtime/ohos/host/` 的 runner | `libnode.so` | `libdsh_host.so` 的 ELF 依赖；Ark 宿主只调用 `dsh_node_start` / `dsh_node_stop` C 接口。由主线核实实际输出及导出表 |
| `app/ohos/entry/src/main/cpp/` | `libdsh_host.so` | Ark 真正的 N-API 模块 |
| `runtime/ohos/native/build-flock.py` 的 `system.node` | `libdsh_flock.so` | OH 专用 flock 入口，显式 `process.dlopen` |
| `runtime/ohos/native/loader/build-loader.py` 的 `require_builtin.node` | `libdsh_require_builtin.so` | OH 专用 require-builtin 入口，显式 `process.dlopen` |

后两项只改变 HAP 文件名，不修改原生实现或把它们伪装成 Ark 模块。Node 的 addon 导出入口仍是 `napi_register_module_v1` / `node_api_module_get_api_version_v1`；这些入口不能被 N-API 前缀头一并改名。消费的函数导入则必须经过 P1C 的 `dsh_napi_*` / `dsh_node_api_*` 验证。Linux 夹具使用桌面 Node 原始 N-API，不能替代该目标门。

JS、JSON、配置和静态资源进入 rawfile，再由 P2 按 SHA256 增量落地；ELF 和 `.node` 不进入运行时数据树。`NARB_DISABLE_NATIVE_CACHE=1` 保持启用，不把已安装库复制到可写临时缓存后再加载。

## 显式加载接缝

`runtime/ohos/native/hap-loader/` 是本仓库的自有代码，安装为 `@dsh-go/ohos-native`，没有增加外部 npm 依赖。仓库 AGPL-3.0-only 许可证随包保留。

`ohos-hap-native-libraries.diff` 只登记在 pins 的 `ohos` 目标。它在真实 `process.platform === 'openharmony'` 时改变两个接缝：

- `@deepseek-ai/node-addon-system/flock` 请求固定 `flock` 产品。
- `node-addon-native-custom-loader` 只接受 AUTO/NAPI 后端，再核原生 binding 声明的产品和 ABI；不尝试平台 optional 包、local build、Node ABI 后端或 native cache。

helper 只接受两个产品名，把它们映射到上表文件名。库目录来自宿主保护的 `DSH_GO_OHOS_NATIVE_LIBRARY_DIR`，必须是非根绝对目录；实际库必须为该 canonical 目录中的普通文件，库文件符号链接拒绝。缺目录、缺文件、未打包产品分别返回稳定的 `ERR_OHOS_NATIVE_LIBRARY_DIRECTORY`、`ERR_OHOS_NATIVE_LIBRARY_PATH`、`ERR_OHOS_NATIVE_PRODUCT`。不会搜索工作区、当前目录或数据树中的替代库。

`.so` 不是 Node 的 `.node` require 扩展，故这里明确调用 `process.dlopen(module, filename)`，不注册全局扩展、不覆盖 Node 内建模块，也不读取生产禁止的仿真开关。

## 宿主目录的证据与待接线条件

公开 `Context.applicationInfo.nativeLibraryPath` 自 API12 可用，但不能推断它本身是绝对路径。固定 OpenHarmony-v6.1-Release 的 `MainThread::GetNativeLibPath` 把该字段加在 `LOCAL_CODE_PATH` 后。固定官方 Context 文档将 `bundleCodeDir` 定义为应用沙箱的安装包目录。后继宿主应以系统提供的 `bundleCodeDir` 和经逐段检查的相对 `nativeLibraryPath` 构造路径，再由 C++ 核对实际目录、两个固定库，不硬编码 `/data/` 前缀。

同版本 module 配置文档规定：`extractNativeLibs` 从 API20 起支持，设为 true 时安装到解压的 libs 目录；`libIsolation` 默认 false，设为 true 会引入模块子目录。本应用是单 entry 模块，后继接线应明确 `extractNativeLibs:true`、`libIsolation:false`，不能把直接从 HAP 映射的路径当作普通文件目录。正式 SDK 编译、实际安装值与文件访问仍须本机/设备验证；不满足条件时启动拒绝，不能转而复制 ELF 到数据目录。

来源（仅研究平台行为，没有复制其他移植项目实现）：

- [官方 main_thread.cpp，OpenHarmony-v6.1-Release](https://raw.githubusercontent.com/openharmony/ability_ability_runtime/OpenHarmony-v6.1-Release/frameworks/native/appkit/app/main_thread.cpp)，SHA256 `fa2073829e92d5a66bd8d32b85d9235e37591abaa062120e3432c0786fed6d24`。
- [官方 Context 文档，同版本](https://raw.githubusercontent.com/openharmony/docs/OpenHarmony-v6.1-Release/zh-cn/application-dev/application-models/application-context-stage.md)，SHA256 `b089ae98b390e7736cb453fa9b021e700643b60361ed18d9074e7568b1a382d6`。
- [官方 module 配置文档，同版本](https://raw.githubusercontent.com/openharmony/docs/OpenHarmony-v6.1-Release/zh-cn/application-dev/quick-start/module-configuration-file.md)，SHA256 `d7c0556fe882c23ff50927bd2fc30e06c15f43dc7d4140010dd067cb0a13a900`。

## 生成与验证

只在独立前缀安装锁定依赖，然后真实执行：

```sh
python3 -I -B runtime/lib/rtbuild.py patch-dsh \
  --prefix "$O2_PREFIX" --dsh-version 0.2.1-rc.4 --target ohos \
  --out "$O2_LOGS/patches.json" --target-report "$O2_LOGS/target.json"
mkdir -p "$O2_PREFIX/node_modules/@dsh-go/ohos-native"
cp runtime/ohos/native/hap-loader/index.cjs runtime/ohos/native/hap-loader/package.json \
  "$O2_PREFIX/node_modules/@dsh-go/ohos-native/"
cp LICENSE "$O2_PREFIX/node_modules/@dsh-go/ohos-native/LICENSE"
```

构建已固定源的 Linux flock，并使用已核来源的 Linux require-builtin addon：

```sh
python3 runtime/tests/ohos/hap-native-paths.py \
  --prefix "$O2_PREFIX" --node "$NODE24" --headers "$NODE24_HEADERS" \
  --loader-addon "$LINUX_REQUIRE_BUILTIN" --compiler clang-18 --out "$O2_NEW_LOGS"
```

驱动使用官方 Node24.22.1 与真实 flock 系统调用，逐例保存命令、stdout、stderr、产物摘要。8 例覆盖正常加载及真实锁竞争/释放、目录缺失、相对目录、缺库、链接库、严格 allowlist 拒绝、Node ABI 拒绝和非 OH 的 Linux 原路线。

完整 `runtime/ohos/sim/round.mjs` 增加明确的 `--native-library-dir` 与 `--compile-cache-dir` 测量输入。allowlist 仍绑定每个实际 canonical 文件及 SHA；除 `.node` 外仅接受两个固定 HAP addon 名，未扩大到任意 `.so`。真实 DSH 的 write/edit/read/grep/bash 回合及审批必须另跑，不能用小夹具代替。缓存冷热是“空的/已有的 Node 编译缓存”，没有清理操作系统页缓存，不称为设备冷启动。

Android 目标集合、所有选中 diff 与选中 pins 不变；不改 `build-runtime.sh` 或 `rtbuild.py`。交付实测 c818155 与本项 `--target android` 的完整文件内容、路径、模式、链接摘要相同，实际 Android recipe 输入流也相同；没有据此声称构建了 APK。
