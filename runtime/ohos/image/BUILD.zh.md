# SDK26 图片 Node 插件：CMake / Ninja 构建

本配方生成 OH arm64 `libdsh_image_codec.so`，供固定 Node 24.22.1 的鸿蒙图片后端使用。实现从 ohos10 的最终 `author402` 草稿恢复到本波 `a836880` 基底；包含已选定的 bridge v3、NDK v3 与构建输入 verifier v3。

本波已经用 GCC 14、G++ 14 和官方 Node 24.22.1 实际运行纯容器扫描、有限编码阶梯、假 SDK NDK 两种颜色空间释放配置及 Node 异步桥 plain/jitless。它们只证明宿主参数、错误和资源生命周期合同。**未在真机核实**：没有运行目标 CMake configure、OH 编译/链接/ELF 审查、真实 Image NDK、HAP 或设备像素测试；下列命令由本机在完整输入齐备后执行。

## 为什么分开两种编译

固定仓库 `runtime/ohos/node/BUILD.md` 明确：SDK clang15 不用于构建 Node24；Node C++ addon 使用与实际 libnode 匹配的 clang23 和自建静态 libc++。现有 `runtime/ohos/native/loader/build-loader.py` 接收独立编译器及实际 libnode/build.json；`runtime/ohos/native/build-hap-libs.py` 明确把匹配的 resource-dir、C++ include、静态库和 SDK linker 参数传给它。

v2 的 CMake 只启用 `LANGUAGES C`。SDK toolchain 编译 `codec_ndk.c`、`container_facts.c`、`encoding_ladder.c` 三个纯 C OBJECT；Node `addon.cc` 和最终共享库链接使用独立的 `DSH_NODE_CXX_DRIVER` custom command。这样 SDK toolchain 即使定义自己的 CXX 默认值，也不参与 Node 编译或链接。Node 的 forced rename、Node 头、NAPI_VERSION 和 C++ flags 不传给 NDK C 对象。

## 必需输入与身份

| 输入 | 实际要求 |
| --- | --- |
| 完整 SDK native 目录 | `oh-uni-package.json` 版本 26.0.0.38，真实 C toolchain / sysroot / linker / readelf / arm64 stubs。五份选定图片头继续固定 SHA。 |
| Node 头 | 官方 24.22.1；现存隔离 verifier 核两份 API 头固定 SHA，另记录 types/version 等实际输入。 |
| libnode 与 build.json | 本 App 实际隔离版 OH arm64 libnode.so，以及固定 `build-node.py` 产生的对应 build.json。实际库大小/SHA、Node 源 pin、OH arm64 configure、rename 摘要必须吻合。 |
| `DSH_NODE_CXX_DRIVER` | 实际 `clang++`（可为指向同一 Clang 可执行文件的符号链接，或 clang++-版本号）。其底层文件 SHA 必须与 Node build.json 和 runtimes.json 的 compilerSha256 **同时一致**，并实际报告 23.1.1。保留 clang++ 的调用名；不把符号链接解析后的 clang 文件名直接用于 C++ 链接。 |
| `DSH_NODE_CXX_RUNTIME` | 固定 `build-runtimes.py` 的输出根。其 LLVM23.1.1/source pin、六项 static runtime/builtins/CRT 摘要须与 Node build.json 内 cxxRuntime 完全一致，并逐件核实际文件。 |
| 完整 rename | 本仓库原字 `runtime/ohos/node/napi-rename.h`，沿用 `napi_isolation.py`；两个 addon 入口保留原名。 |
| SDK 四库 | 显式 arm64 libimage_source.so、libpixelmap.so、libimage_packer.so、libnative_color_space_manager.so，位于同 SDK sysroot 的 arm64 目录，检查 ELF/SONAME。 |

固定运行库的六项文件是 `lib/{libc++,libc++abi,libunwind}.a` 与 `clang-resource/lib/aarch64-linux-ohos/{libclang_rt.builtins.a,clang_rt.crtbegin.o,clang_rt.crtend.o}`。Node 和 runtime 记录必须描述同一组，当前实际文件也必须同字。SDK manifest 在两个构建记录与当前文件之间核合；SDK linker 的当前版本要与 Node 记录相同，实际 linker 摘要另记。

旧记录的 compilerSha256 来自 `build-node.py --clang` 对底层 Clang 可执行文件的摘要。此配方接受相同可执行字节的 clang++ 调用入口，**不把任意 wrapper、不同字节的另一编译器或只有相同版本号视为配对**。若 owner 的编译器布局不满足这一已有记录可证明的关系，应补清真实来源并修订配方，不能改记录凑合或退回 SDK C++。

历史 runtimes.json 记录静态产物和 LLVM 源归档，未列全套安装头文件摘要。v2 记录当前 `__config` / `__config_site` / `version`，核 compiler-rt include 链接指向该 driver 的资源头；不倒填完整历史头摘要，也不宣称这些校验单独证明全部 C++ ABI。

## 固定命令

选择合成源码根、完整 SDK 和真实配对输入，赋给以下专名变量。以新的构建目录执行，任一检查或命令非零即停止。没有 full SDK 时，不应把小头文件包填入 SDK 路径。

```bash
: "${DSH_IMAGE_SOURCE_ROOT:?set the assembled source root}"
: "${DSH_IMAGE_SDK_NATIVE:?set the complete SDK native directory}"
: "${DSH_IMAGE_NODE_HEADERS:?set exact Node 24.22.1 include/node}"
: "${DSH_IMAGE_LIBNODE:?set the actual OH arm64 libnode.so}"
: "${DSH_IMAGE_NODE_BUILD_JSON:?set its actual build-node.py build.json}"
: "${DSH_IMAGE_NODE_CXX_DRIVER:?set the matching clang++ invocation path}"
: "${DSH_IMAGE_NODE_CXX_RUNTIME:?set its matching build-runtimes.py output}"
: "${DSH_IMAGE_LIB_SOURCE:?set SDK arm64 libimage_source.so}"
: "${DSH_IMAGE_LIB_PIXELMAP:?set SDK arm64 libpixelmap.so}"
: "${DSH_IMAGE_LIB_PACKER:?set SDK arm64 libimage_packer.so}"
: "${DSH_IMAGE_LIB_COLORSPACE:?set SDK arm64 libnative_color_space_manager.so}"
: "${DSH_IMAGE_CMAKE:?set the SDK-compatible cmake executable}"
: "${DSH_IMAGE_NINJA:?set the Ninja executable}"
: "${DSH_IMAGE_BUILD_DIR:?set a new, separate build directory}"
test ! -e "$DSH_IMAGE_BUILD_DIR"

"$DSH_IMAGE_CMAKE" -S "$DSH_IMAGE_SOURCE_ROOT/runtime/ohos/image" \
  -B "$DSH_IMAGE_BUILD_DIR" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$DSH_IMAGE_NINJA" \
  -DCMAKE_TOOLCHAIN_FILE="$DSH_IMAGE_SDK_NATIVE/build/cmake/ohos.toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DOHOS_ARCH=arm64-v8a -DOHOS_PLATFORM=OHOS -DOHOS_STL=c++_static \
  -DDSH_REPOSITORY="$DSH_IMAGE_SOURCE_ROOT" \
  -DDSH_OHOS_SDK_NATIVE="$DSH_IMAGE_SDK_NATIVE" \
  -DDSH_NODE_HEADERS="$DSH_IMAGE_NODE_HEADERS" \
  -DDSH_NODE_NAPI_RENAME_HEADER="$DSH_IMAGE_SOURCE_ROOT/runtime/ohos/node/napi-rename.h" \
  -DDSH_NODE_LIBRARY="$DSH_IMAGE_LIBNODE" \
  -DDSH_NODE_BUILD_JSON="$DSH_IMAGE_NODE_BUILD_JSON" \
  -DDSH_NODE_CXX_DRIVER="$DSH_IMAGE_NODE_CXX_DRIVER" \
  -DDSH_NODE_CXX_RUNTIME="$DSH_IMAGE_NODE_CXX_RUNTIME" \
  -DDSH_IMAGE_SOURCE_LIBRARY="$DSH_IMAGE_LIB_SOURCE" \
  -DDSH_IMAGE_PIXELMAP_LIBRARY="$DSH_IMAGE_LIB_PIXELMAP" \
  -DDSH_IMAGE_PACKER_LIBRARY="$DSH_IMAGE_LIB_PACKER" \
  -DDSH_IMAGE_COLORSPACE_LIBRARY="$DSH_IMAGE_LIB_COLORSPACE" \
  -DDSH_IMAGE_DESTROY_COLORSPACE_GETTER=1

"$DSH_IMAGE_NINJA" -v -C "$DSH_IMAGE_BUILD_DIR" dsh_image_codec
```

`OHOS_STL=c++_static` 仅保留 SDK toolchain 的设置要求，Node 链接实际由独立 clang++ 的 `-static-libstdc++` 与已核 runtime 路径确定。旧 `DSH_NODE_CXX_OPTIONS` / `DSH_NODE_LINK_OPTIONS` 非空时会拒绝；它们不能替代配对。v2 从真实输入固定派生 `--target=aarch64-linux-ohos`、sysroot、resource-dir、`-stdlib=libc++`、C++ include、runtime 库目录、SDK ld.lld。Node TU 保持 C++17、完整 rename、NAPI8、PIC、hidden visibility 和桥所需的 exceptions；无 C++ / N-API 对象穿过纯 C 边界。

最终链接明确引用四个 SDK 库与实际 libnode，保留 `-z defs`、静态库符号隐藏、两入口 version script 及 SONAME；只传链接期 rpath-link，不设置运行时 RPATH/RUNPATH。链接后再次核输入与 configure 回执未变，并运行原隔离门和本配方的 ELF 检查。通过后才创建 `image-build-complete.stamp`；失败留下的 .so 不是完成产物。

## 输出和双配置

- `libdsh_image_codec.so`、`image-build-elf.json` 和完成 stamp 只有实际成功构建后才存在；本次没有生成。
- `image-build-inputs.json` 记录选定 SDK/Node/driver/runtime 输入及配对关系。它在 configure 阶段读取文件、调用 driver 版本/资源目录查询和 ELF 工具，不装载目标库。
- `compile_commands.json` 由 CMake覆盖三个 NDK C TU。Node TU 与最终链接是 custom commands，须保留 `ninja -v` 的真实命令/输出；不能声称它们已自动进入该 JSON。Node编译同时产生 depfile，后续头依赖变化会触发重新编译。
- 默认 getter 宏为1（destroy）；0（borrow）必须选择另一新的构建目录，配方拒绝在同一目录切换。使用同一组源码/配对输入，只修改该宏；分别保存产物 SHA 和回执。

实际后端 `codecIdentity` / `colorGetterPolicy` 继续由未改源码产生。身份串为 `oh-image-ndk26-v1;decode=rgba8-sdr-srgb;resize=high-fit-inside;orient=explicit;quality=85,75,60;cap=52428800;verify=container+decode;getcolor=destroy`；另一编译配置末段为 borrow。该串是选项身份而非完整源码/二进制摘要。两配置不混库/缓存/回执；owner选择默认Destroy不等于已证getter所有权。

## 验证边界与来源

本波宿主测试使用原 SDK 头声明和自有假实现，未调用系统 Image NDK。目标 CMake configure、完整 SDK 配对、实际编译/链接/ELF、HAP 装载、像素/颜色/方向/透明度/缩放、资源退休与手机行为仍待本机分别验证。宿主通过不代表这些目标步骤通过。

仓库依据：`runtime/ohos/node/BUILD.md`、`runtime/ohos/node/build-node.py`、`runtime/ohos/node/build-runtimes.py`、`runtime/ohos/native/loader/build-loader.py`、`runtime/ohos/native/build-hap-libs.py`，均只读未改。CMake 3.20 官方说明支持在 OUTPUT custom command 中使用 OBJECT 列表、COMMAND_EXPAND_LISTS 和 Ninja DEPFILE；此文档依据不是本轮 configure 证据：

- https://cmake.org/cmake/help/v3.20/command/add_custom_command.html
- https://cmake.org/cmake/help/v3.20/manual/cmake-buildsystem.7.html#object-libraries
