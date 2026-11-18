# Ark 与 Node 的原生符号边界

本约定是本机引擎的 N-API 隔离方案。目标库的交叉编译和 ELF 审计已离线完成（`runtime/ohos/node/BUILD.md`），HAP 装载和设备运行尚未验证。Linux 的双 DSO 实验只验证 ELF 名称绑定，不代表 Ark 与 Node 已在设备共存。

## 两侧各用自己的 N-API

`libdsh_host.so` 使用 OpenHarmony SDK 的 `napi/native_api.h`、`libace_napi.z.so` 与 `libhilog_ndk.z.so`。此目标不包含 Node 头文件，不强制包含改名头，不把 `napi_env`、`napi_value` 或回调交给 Node。

runner 和其 linked binding `dsh_ohos_publication` 编入 `libnode.so`，使用锁定 Node 24.22.1 的头文件，和 libnode 其余目标代码一样整体强制 `-include napi-rename.h`。`system.node` 与 `require_builtin.node` 的独立构建配方同样强制包含此头。Ark 与 libnode 之间只有 `dsh_node_start(int, char**)` 和 `dsh_node_stop()` 的 C ABI；runner 用 Node 的 C++ 嵌入 API，这些带 `std::` 类型的符号留在 libnode 内部，不导出。

产品改名头是 `runtime/ohos/node/napi-rename.h`，由同目录的 `gen-napi-rename.py` 生成。公开 Node API 函数 `napi_X`、`node_api_X` 分别映射为 `dsh_napi_X`、`dsh_node_api_X`。Node 库不导出原名 API 或 bundled `uv_*`；publication 的 errno 查表另由 P1C-uv 补丁消除 uv 函数调用。

### addon 入口保留原名

`napi_register_module_v1` 和 `node_api_module_get_api_version_v1` 是 `node_api.h` 的 token-paste 宏生成的 addon 导出入口，不是 addon 调用的运行时 API。固定 Node 加载器通过这些名字查找入口，所以这两个导出保留原名；不是给 libnode 保留原名 API 的例外。改名头若重命名它们，构建门直接拒绝。linked binding 使用 Node 公共 `AddLinkedBinding`，不借用 Ark 的注册对象。

## 构建门

`runtime/ohos/host/napi_isolation.py` 同时核对真实头文件和实际 ELF：

1. `js_native_api.h`、`node_api.h` 必须匹配官方 24.22.1 字节哈希；其中 161 个 `NAPI_CDECL` 函数声明必须逐一映射到规定前缀。这里不重命名类型。
2. 真实 libnode 导出的 161 个 API 都必须有前缀；原 `napi_*`、`node_api_*`、`uv_*` 导出或导入均拒绝。libnode 必须导出 C ABI start/stop，带 ELF `NODELETE` 标志。
3. addon 的未定义符号不得包含原名 N-API/uv；每个改名 API 导入必须由同一个待打包 libnode 提供，且 `NEEDED libnode.so`。addon 两个入口保持原名。
4. Ark 模块必须导入真正的 `napi_module_register` 和 C ABI start/stop，start/stop 必须由 `NEEDED` 的待打包 libnode 提供；不得导入 Node 的改名 N-API、Node/V8 C++ 符号或 libnode 的其他导出。
5. Ark 模块必须有 ELF `NODELETE` 标志。Node 侧库拒绝依赖另一个共享 libc++/libstdc++；两端独立使用各自 C++ 运行时，不跨边界传 C++ 对象。

没有「已经隔离」布尔开关；缺头、错误导出、漏改名或漏符号都会使构建失败。检查发生在配置输入与最终链接产物上，不以 `RTLD_LOCAL` 替代隔离证据。普通 App 自建动态链接 namespace 的权限限制因此不再是本方案的前提。

## 工具链与输入

- Ark 模块由 SDK 的编译器构建，语言层面是 C++17。
- runner 由 `build-node.py` 用 libnode 目标自身的 gyp 编译参数和同一份 Clang 23、自建 libc++ 编译，再链入 libnode。Node 关闭 RTTI，RTTI 开关会改变 `std::function` 的布局，所以这些参数必须完全一致。
- 原生加载器也要求显式的同一编译器；`build-loader.py --cxx-flag=... --ld-flag=...` 传入匹配的自建 libc++ 搜索参数，不能落回 SDK 的默认 C++ 头/库。
- flock 是 C 的 N-API 模块，不交换 C++ 对象；`build-flock.py --compiler` 显式选定目标 C 编译器。它同样校验改名头、链接明确的 libnode，并以 `-z defs` 拒绝未解析符号。
- 两个脚本都新增必填 `--napi-rename-header`；flock 新增必填 `--libnode`。原生加载器原有 libnode/build.json 的源码与二进制哈希约束继续有效。

Ark CMake 读取 `DSH_NODE_NAPI_RENAME_HEADER`，默认值是 `runtime/ohos/node/napi-rename.h`，仅作为 Python 校验输入。Ark 侧 `DSH_NODE_HEADERS` 可通过同名环境变量提供；它不会成为 Ark C++ 编译的 include 路径。真实库默认放在 `app/ohos/entry/libs/arm64-v8a/`，由 `tooling/ohos/build-hap.sh` 在构建时放入。SDK 编译的 ELF 已离线核实，打包结果仍未核实。

## Linux 实验的范围

运行 `python3 runtime/tests/ohos/napi-isolation.py --node-headers /path/include/node --node-executable /path/bin/node --compiler clang++ --out /absolute/fresh/directory`。

实验先加载两个都导出 `napi_create_function` 的替身 DSO，再加载只导出改名函数的 Node 替身；addon 使用固定官方头声明。两种先后顺序中，改名 addon 都只调用 Node 替身。未改名负对照都调用先加载的原名替身。每个进程只有测试占位参数，没有在两个引擎间共享 N-API 对象。实验直接使用产品改名头 `runtime/ohos/node/napi-rename.h`，其中 161 项 API 逐一核对。

拒绝测试还覆盖漏映射、错改 addon 入口、真实官方未改名 Node ELF、未改名 addon 导入和 Ark 错用改名 API。通过这些实验仍不能回答目标设备的装载器、C++ ABI、arm64 原生加载器探针或应用生命周期问题；这些必须对待打包字节及设备另行验证。

## 来源

- 固定 Node 头：<https://github.com/nodejs/node/blob/v24.22.1/src/js_native_api.h>、<https://github.com/nodejs/node/blob/v24.22.1/src/node_api.h>。
- addon 入口查找：<https://github.com/nodejs/node/blob/v24.22.1/src/node_binding.cc>。
- Ark 公共注册接口：<https://github.com/openharmony/arkui_napi/tree/OpenHarmony-v6.1-Release/interfaces/kits/napi>。
