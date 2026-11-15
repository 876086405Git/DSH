# O3 原生 flock 的交叉构建

**未在真机核实。** 此目录只构建锁文件已有的 `@deepseek-ai/node-addon-system@0.1.2` 的 `src/flock.c`，不移植该包的 Landlock 可执行文件，也不改变 Android 的原生锁路径。BSD-3-Clause 许可证随原包保留。源码 SHA256 钉为 `c1aa773c7a62b03ce3973156b928f41773fef9407afd79d71b2f625b5616421f`。

## 输入与命令

在 Linux 主机上准备公开的 OpenHarmony native SDK、官方 Node 24.22.1 头文件和仓库锁文件安装出的 npm 依赖：

```sh
python3 runtime/ohos/native/build-flock.py \
  --sdk-native /absolute/sdk/native \
  --package /absolute/prefix/node_modules/@deepseek-ai/node-addon-system \
  --node-headers /absolute/node-v24.22.1-linux-x64/include/node \
  --compiler /absolute/sdk/native/llvm/bin/clang \
  --napi-rename-header runtime/ohos/node/napi-rename.h \
  --libnode /absolute/o7b-output/libnode.so \
  --output /absolute/build/flock-ohos-arm64
```

SDK 必须来自官方发布包，下载后先用该发布目录的 `.sha256` 校验；保存 SDK 归档的 URL、发布版本和实算摘要。脚本记录实际 SDK `oh-uni-package.json`、其摘要、编译器摘要和版本、完整命令以及输出 ELF 元数据。它验证目标为 AArch64 的共享对象且不含 `PT_INTERP`，不把改名的 PIE 当共享库。

本次选定的公开发行候选是 [OpenHarmony 6.1 Release](https://gitcode.com/openharmony/docs/blob/master/zh-cn/release-notes/OpenHarmony-v6.1-release.md)，公开 SDK 版本 6.1.0.31、API 23；[发布目录](https://repo.huaweicloud.com/openharmony/os/6.1-Release/) 中 Linux 与 Windows SDK 合包约 2.3 GiB。本次执行环境请求归档与校验文件都收到 HTTP 200 的 195 字节 `Site Unavailable` HTML，未取得 SDK，未取得有效官方摘要，也未实际交叉编译。不能把 HTTP 200 当成 SDK 下载成功。具体请求证据和磁盘限制在随包验证记录中。

编译目标、sysroot 和 LLVM 目录遵循 [OpenHarmony SIG SDK 使用说明](https://gitee.com/openharmony-sig/tpc_c_cplusplus/blob/master/lycium/doc/ohos_use_sdk/OHOS_SDK-Usage.md)。`Node-API` 头文件来自 Node 24.22.1，**不是** ArkTS 的 `napi/native_api.h`；本插件属于 Node 的 V8 环境，不能把它链接到 `libace_napi.z.so` 冒充 Node 绑定。

## 接入边界

产物是 `system.node` 和 `build.json`。它必须随 HAP 签名分发，不能从下载目录当可执行扩展加载。当前 O3b 仍走主 Node 线程内按已打开文件身份区分的锁；本脚本不自动注册一个未经设备验证的原生后端，不改变 `pins.json` 中已复核的 O3b 字节。

上游 `lib/flock.js` 只选择 Linux/macOS 的预编译包；即使构建成功，也还需单独的、仅在 OpenHarmony 生效的加载补丁以及设备验证，才能替换 O3b。下列检查不能用 Linux 结果代替：

1. 脚本 force-include `--napi-rename-header` 给定的 `runtime/ohos/node/napi-rename.h`，经 `napi_isolation.py` 核对头文件、libnode 和产物，插件导入的是 libnode 的 `dsh_napi_*`，不与 ArkTS 的 `napi_*` 同名（见 `runtime/ohos/node/BUILD.md`）。确认这些导入在设备上解析到 **Node**；不能将 ArkTS 的 `napi_env` 与 Node 的 `napi_env` 互换。
2. 签名 HAP 内 `process.dlopen` 成功，运行 `tryLock` 而非仅检查动态装载返回值；覆盖竞争、关句柄释放、worker 环境退出时的异步清理。
3. 用两次独立 `open()` 得到的句柄验证同一 inode 排他，`close()` 后后继获得锁；在设备允许的独立进程测试环境验证跨进程竞争。没有该环境时仍记 `NOT_RUN`。
4. 核对设备是否实际支持 `flock(2)`，失败时返回具体 errno。SDK 声明和 Linux 成功都不足以证明设备支持。

脚本保留上游异步 `flock(LOCK_EX | LOCK_NB)` 和 `napi_add_async_cleanup_hook` 代码，没有把争用改成成功、没有轮询、没有擅自关闭调用方 fd。调用方必须在异步完成前保持 fd 所有权。所有设备相关结论目前为 `NOT_RUN`。
