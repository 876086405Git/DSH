# 原生 require-builtin 加载器：来源、构建门控与未验证边界

本子项保留追加 3 的首选路线：编译上游原生 addon，放到原 JS 加载器已经识别的平台包目录，不修改 DSH 的 profile resolution，也不使用 `module.registerHooks`。当前没有 SDK 和已构建的 OHOS `libnode.so`，因此交付的是固定输入、构建脚本、自检与源码证据；不能称鸿蒙 ABI 或 HAP 加载已经通过。

## 三个前置问题的答案

**源码公开。** npm 中的 `node-addon-native-custom-loader@0.1.9` 是共享 JS 加载器，发布包不含 C++。真正原生实现位于同一公开仓库的 `packages/native/`；用 `NARB_PRODUCT=1` 编译为 `require-builtin` 产品。默认的 `internal-loader` 只开放 CJS/ESM 两个模块，不够 DSH 使用的五个模块。

本次实际取得的发布提交为 `a58d3599a2e551d7d706d1ff796c9fd4bbaff63c`，提交信息 `release: 0.1.9`，日期 2026-10-08。固定归档 URL：

<https://codeload.github.com/deepseek-ai/dsh-node-addon-require-builtin/tar.gz/a58d3599a2e551d7d706d1ff796c9fd4bbaff63c>

归档实算 SHA256 为 `286616f15e4f12013988e45ad27a69b4968a9f059c8bd351e412505230577948`，147,144 字节。npm 的精确 0.1.9 元数据没有 `gitHead`，仓库 tags 接口当时为空；因此这里以实际发布提交、版本文件和逐文件 pins 固定输入，不声称 npm integrity 额外证明了该提交的身份。`source-pins.json` 固定全部原生源文件、相关 JS 入口、许可证及构建声明。构建脚本不修改这些文件。

**许可证是 MIT。** 固定源码 `LICENSE` 与实际安装的共享 loader 许可证字节相同。生成的平台包保留原许可；C++ 包装头文件的许可也单独随包保留。许可证原文见固定提交：

<https://github.com/deepseek-ai/dsh-node-addon-require-builtin/blob/a58d3599a2e551d7d706d1ff796c9fd4bbaff63c/LICENSE>

**符号条件需要分层描述。** 原生入口使用 Node-API v9，但它的实现不是只使用稳定 Node-API。POSIX 实现用 `dlsym(RTLD_DEFAULT, …)` 读取下表的导出符号，再依赖 Realm 槽位、getter 的机器码与内部句柄表示。它不调用已知未导出的 Node 符号；必需符号缺失时拒绝加载。目标 OHOS 共享库尚未生成，无法确认这些符号在最终目标库和实际宿主加载作用域中可见。

| Node 24.22.1 必需的动态符号 | 作用 |
| --- | --- |
| `_ZN2v82V810GetVersionEv` | 读取原生 V8 版本，选择运行时分支 |
| `_ZN2v87Isolate10GetCurrentEv` | 当前 isolate |
| `_ZN2v87Isolate17GetCurrentContextEv` | 当前 context，依赖平台 C++ 返回约定 |
| `_ZN2v87Context29GetNumberOfEmbedderDataFieldsEv` | 核对 context 槽位数量 |
| `_ZN2v87Context37SlowGetAlignedPointerFromEmbedderDataEi` | Node 20/22/24 的未标记槽读取 |
| `_ZNK4node14PrincipalRealm22builtin_module_requireEv` | 解析/调用私有 getter，取得内部 require |

带 `Eit` 后缀的两个 tagged getter 只用于 Node 26+ 或专门识别的 Electron 分支；它们没有从官方 Linux Node24.22.1 导出，不能据此判定当前 Node24 不可用。固定源码 `runtime_context/runtime_profile.cc`、`embedder_data.cc` 给出了该分支选择，官方 Linux Node24.22.1 实际 ELF 的六个必需符号均存在。

Node24.22.1 的 `node.gyp` 中，隐藏 Node 源符号的选项仍处于注释状态，共享目标包含 node_base 的 whole-archive 链。这支持“默认构建可能保留私有 getter”的源码推断，但 `PrincipalRealm` getter 没有 `NODE_EXTERN` 保证；不能把这个推断替代目标 `readelf` 和运行态 `dlsym`。脚本在编译 addon 之前检查最终输入 libnode 的六个符号及 Node-API 导出。

## 原实现仍有的私有运行态依赖

原生实现从 context 的 `38` 号槽读取 Realm；这个默认值可对照固定 Node 源码 `src/node_context_data.h` 中 `NODE_CONTEXT_REALM_INDEX`。随后校验 Realm vptr 和 getter 归属同一映像，解析 ARM64 getter 指令得到字段偏移，读取 `Realm + offset`，调用 getter 比较返回值，再通过 Node-API 检查函数类型，最后验证 `internal/bootstrap/realm` 中的 require 自指身份。

这些都是原 addon 的行为，不是我们增加的公开 API 保证。字段表示、getter 指令形状、AAPCS64 返回约定、POSIX `msync`/`dladdr` 检查有任一不满足，原 addon 会报 unsupported；真实 ARM64 运行自检才能确认全部条件成立。源码中针对 Linux ARM64 的分派要求 `__linux__ && __aarch64__`，构建脚本让真实 SDK 预处理器输出宏并核验，不能仅在说明里把 OpenHarmony 当作 Linux。

## Node-API 与 Ark NAPI 必须区分

这里的 `node_api.h` 来自官方 Node24.22.1，C++ 的 `node-addon-api` 包装的是 Node-API。ArkTS 宿主的 `napi/native_api.h` 是另一套运行时接口，不能混用头文件、环境对象或句柄。

Ark 和 Node 不再共用符号名：本脚本 force-include `--napi-rename-header` 给定的 `runtime/ohos/node/napi-rename.h`，经 `napi_isolation.py` 核对，要求 Clang 23 或更新版本，生成的 addon 导入 `dsh_napi_*`，显式依赖 `libnode.so`，并静态检查这些导入都在输入 libnode 的导出表中，任何残留的 `napi_*`、`node_api_*` 导入都拒绝构建。详见 `runtime/ohos/node/BUILD.md`。**这只是必要条件，不证明运行时绑定。** HAP 中 Ark NAPI、Node 与 addon 同时加载时，仍须记录：libnode 的真实加载方式与作用域、六个 `RTLD_DEFAULT` 查找地址所归属的映像、原生 probe 完整返回结果。

## 构建输入与输出

`build-loader.py` 不联网，不安装依赖，输入路径必须由调用方提供。构建所需的 `node-addon-api 8.9.2` 在 O4 锁中是可选传递依赖；仅按虚拟进程运行说明执行 `--omit=optional` 不会安装这些头文件。原生加载器的构建准备应使用固定 Node 24.22.1 工具链，在独立的构建依赖目录包含可选项：

```sh
# 从仓库根目录执行；使用一个新建的构建依赖目录。
mkdir /absolute/loader-build-deps
cp runtime/ohos/process/package.json runtime/ohos/process/package-lock.json /absolute/loader-build-deps/
npm ci --prefix /absolute/loader-build-deps --include=optional --ignore-scripts
```

该命令沿用仓库的精确 lock，不改变依赖版本；`--ignore-scripts` 不执行依赖安装脚本。`--include=optional` 的选择规则见 [npm ci 官方说明](https://docs.npmjs.com/cli/v11/commands/npm-ci/#include)。这只是加载器构建头文件的准备步骤，O4 运行依赖的安装策略仍由其运行说明定义。随后把本次目录传入构建器：

```sh
python3 runtime/ohos/native/loader/build-loader.py \
  --sdk-native /absolute/open-harmony-sdk/native \
  --source /absolute/dsh-node-addon-require-builtin-a58d3599 \
  --node-headers /absolute/node-v24.22.1/include/node \
  --node-addon-api /absolute/loader-build-deps/node_modules/node-addon-api \
  --compiler /absolute/clang-23/bin/clang++ \
  --cxx-flag=-nostdinc++ --cxx-flag=-isystem/absolute/cxx-runtime/include/c++/v1 \
  --ld-flag=-L/absolute/cxx-runtime/lib \
  --napi-rename-header runtime/ohos/node/napi-rename.h \
  --libnode /absolute/o7b-output/libnode.so \
  --libnode-build-json /absolute/o7b-output/build.json \
  --output /absolute/fresh-loader-output
```

libnode 的 build.json 必须绑定官方 Node24.22.1 源归档 SHA256 与输入 `.so` 的实际字节，并声明 OHOS arm64 shared 配置。SDK 的真实 manifest、编译器版本/哈希、编译命令和 ELF 结果写入输出 build.json；缺 SDK 在创建输出目录之前明确退出，目标构建记为 NOT_RUN。

上游自己的锁文件使用 `node-addon-api 8.9.0`。这里复用已批准 O4 锁中实际已有的 **8.9.2**（MIT）作为构建头文件，`source-pins.json` 固定 `napi.h`、两个内联头、package.json 与许可证。这一处与上游构建锁不同，已明确记录；原 `.cc/.h` 实现不变。未新增运行时 npm 依赖；上述准备只安装锁中已有的可选构建头文件，不静默采用现有 DSH 树中较旧的 7.1.1。

输出为私有平台包：

`node_modules/node-addon-require-builtin-openharmony-arm64/prebuilt/openharmony-arm64-napi-v9.node`

平台包的 `index.js` 调用原 `loadPrebuild(__dirname)`，manifest 明确 `product=require-builtin`（由原生导出核对）、`backend=napi`、`abi=napi-v9`。原共享 loader 根据实际 `process.platform/process.arch` 自然选到该包。原入口也有 `build/napi/napi-v9-openharmony-arm64/require_builtin.node` 的 local-build 备选接缝；本脚本固定使用平台包，避免交付时混淆两种路径。

该平台包是 App 自带构建输入，未向 npm 或任何公开渠道发布。HAP 最终安装路径、代码签名目录与 `dlopen` 授权需由本机打包方确认。宿主应在第一次 require 前设置现成的 `NARB_DISABLE_NATIVE_CACHE=1`，让原 loader 直接加载受信安装路径；否则原 loader 默认先复制到运行时 tmp cache。关闭复制不等于签名目录权限已验证。

## 启动自检与证据边界

`probe.cjs` 锁定 Node24.22.1、OHOS 平台、原生 napi-v9 产品和禁用 native cache。宿主必须明确传独立的 `--jitless`；参数名先将单/双连字符前缀及下划线归一化，拒绝 `--expose-internals`/`--expose_internals`，也拒绝 `--no-jitless`、`--nojitless`、`--no_jitless` 及其单连字符、赋值形式。另检查五个内部模块仍不能经公开 `process.getBuiltinModule` 取得，并检查 WebAssembly 缺席。

不能只以 WebAssembly 不存在作为 jitless 证明：O0 预载本身会删掉它。v1 的这两个漏洞已由独立复核实际重现，修复过程中又实际确认 V8 接受 `-nojitless` 等单连字符写法；所有先失败证据均保留。v2 的真实子进程测试包含“没有jitless但有O0”和“先jitless后禁用”的各类负对照。随后自检通过原 addon 加载 DSH 使用的五个内部模块，检查八个函数成员。缺一个就明确失败，不静默转另一实现。

```sh
NARB_DISABLE_NATIVE_CACHE=1 node --jitless \
  runtime/ohos/native/loader/probe.cjs /absolute/dsh-prefix
```

实际已有的严格 O0 接线探针使用官方 Linux x64 prebuild、精确单 addon 白名单和测试专用 `openharmony-x64` 平台包；没有修改原 JS/native 字节，没有 `--expose-internals`，五模块八成员均可用。这证明原平台包接缝和 API 接线可行。它不证明 OHOS arm64 ABI、HAP 签名目录或 Ark/Node 符号归属。

这份源码分析没有证明首选路线在目标上失败，因此没有自动切换到追加 3 授权的 expose-internals 后备方案。若真实交叉编译/运行证明首选前置不成立，应先保存具体错误与输入 hash，再使用仅 OHOS 宿主参数、固定 Node 版本、五模块八成员启动自检的后备方案。Android 启动参数不应受影响。

交付日志应分别列：固定源/头文件核验、Linux 原生/严格仿真探针、Linux 源码重编（若执行）、缺 SDK 失败路径、OHOS 交叉编译、OHOS ARM64 probe、HAP 符号归属。后三项当前均为 `NOT_RUN`。源码或构建脚本的复核通过不改变这个结论。
