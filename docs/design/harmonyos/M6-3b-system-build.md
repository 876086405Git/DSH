# M6-3b：熔断状态绑定的系统版本来源

本篇补充崩溃熔断所需的系统身份来源、原生构建输入和测试边界。**公开源码已核；Linux Node 绑定已实跑；目标 HarmonyOS 手机上的实际值、SDK 编译和目标 ABI 仍为 NOT_RUN。** 熔断状态机、归属账本和真实 SIGKILL 恢复另见同包的实现与测试报告。配套独立增量已在 Linux 严格仿真的真实 DSH 中验证认证 HTTP 发布能力片段，入口与装配见 `runtime/ohos/capabilities/README.md`；这仍不等于完整 O6、Dart 或手机验证。

## 1. 使用系统版本元组

新增 linked binding 方法 `getSystemBuildIdentity()`，同步返回固定四字段对象。它直接调用公开 C API，既不读取 JavaScript 环境变量，也不使用 Node 版本或 Linux 内核版本来代替系统版本。

| 返回字段 | 公开 C API | 固定实现中的来源 |
| --- | --- | --- |
| `osFullName` | `OH_GetOSFullName` | `GetOSFullName` 经 `GetFullName_` 与系统发布类型生成完整版本名；失败可能为空字符串 |
| `displayVersion` | `OH_GetDisplayVersion` | `const.product.software.version` |
| `incrementalVersion` | `OH_GetIncrementalVersion` | `const.product.incremental.version` |
| `securityPatchTag` | `OH_GetSecurityPatchTag` | `const.ohos.version.security_patch` |

来源为 OpenHarmony `startup_init` 固定提交 **`08addb7868567eed729072efa93b59380366cf22`**，对应所取 `OpenHarmony-v6.1-Release`。公开头文件把这四个接口均标为 API 10、`SystemCapability.Startup.SystemInfo`，并允许查询失败时返回 NULL。实现是公开 API 包装到系统参数读取，不需要设备序列号、UDID 或用户标识。[公开头文件](https://raw.githubusercontent.com/openharmony/startup_init/08addb7868567eed729072efa93b59380366cf22/interfaces/kits/syscap/include/deviceinfo.h)；[C API 包装](https://raw.githubusercontent.com/openharmony/startup_init/08addb7868567eed729072efa93b59380366cf22/interfaces/kits/syscap/src/deviceinfo.c)；[参数实现](https://raw.githubusercontent.com/openharmony/startup_init/08addb7868567eed729072efa93b59380366cf22/interfaces/innerkits/syspara/parameter.c)。

完整来源 URL、字节数与 SHA256 在 `runtime/tests/ohos/system-build-identity/sources.json`。关键头文件 SHA256 为 `3dbf1c80762cd50ddec5a152fd55267087f5d844e44da109334fdc839d34621f`，参数实现为 `2719af315a10e8200f8b83c16f0c75c8f3a404b36185d326e035418c29ada3f3`。本补丁只保存引用元数据和作者编写的下载校验器，不提交第三方实现或 SDK 文件。

四字段按规定字段顺序序列化后形成版本身份，不能用没有分隔或长度信息的字符串拼接。应用版本、Node 版本、进程标识、启动时间或随机值都不参与这个身份。任一字段改变即视为不同系统版本；因此系统升级改变这些公开字段后可以重新尝试。若厂商实际更新了策略却完全保留四个公开字段，单凭这个接口无法识别该变化；必须在设备记录中核实，不能宣称已经识别所有厂商更新。

## 2. 无法取得可靠身份时的明确行为

原生层拒绝任一 NULL、空字符串或超过 **1024 UTF-8 字节**的值，抛出 `ERR_OHOS_SYSTEM_BUILD_IDENTITY`。JavaScript 接入还校验四字段的类型、空白、NUL、UTF-8 字节上限与重复读取一致性，并以稳定的 `ERR_OHOS_PUBLICATION_SYSTEM_BUILD` 报出身份不可用。

本版选择**拒绝 publication 预加载启动**。身份验证在打开归属账本之前完成：不修改旧 `trying` / `disabled-after-crash` 文件，不把未知版本换成一个新版本，不尝试 rename，也不把身份失败记录为 `unsupported`。统一预加载因此不能进入 DSH 主入口；不能将这种失败描述为“已安装 O6 能力”或“已经完成非原子降级”。

这是一项可用性限制。官方头文件允许空值，所以尚不能断言每台目标手机都能通过该前提。真机首先应记录四字段是否可读取、是否稳定，以及升级后哪些字段发生变化。如果需要在身份不可用时继续提供非原子发布，应另行冻结一个明确的降级状态及恢复合同，保留旧 epoch，并验证其不会重新尝试未知的 syscall；本轮没有加入这个分支。

## 3. 产品与 Linux 夹具的构建输入

产品 runner 编入 libnode，`runtime/ohos/node/build-node.py` 要求 SDK 中的 `deviceinfo.h`，并把 `libdeviceinfo_ndk.z.so` 链接到 libnode。官方 C API 文档及固定 `BUILD.gn` 支持这个库名与 NDK 接口归属。[官方 API 文档](https://raw.githubusercontent.com/openharmony/docs/OpenHarmony-v6.1-Release/zh-cn/application-dev/reference/apis-basic-services-kit/capi-deviceinfo-h.md)；[固定库构建定义](https://raw.githubusercontent.com/openharmony/startup_init/08addb7868567eed729072efa93b59380366cf22/interfaces/kits/syscap/BUILD.gn)。

Linux 没有这个系统库。`build-publication-native.sh` 因此显式加入 `runtime/tests/ohos/publication-deviceinfo-fixture/` 的四函数测试实现；返回值带 `DSH-Linux-Test-` 前缀。这个目录不在产品构建的 include 或 source 列表中。测试值没有环境变量覆盖；故障用编译宏生成独立测试产物。这里没有在产品源中增加“非 OHOS 时假装有系统版本”的分支。

真实崩溃测试中的系统 A/B 切换也是显式测试输入，用来覆盖持久状态跨版本行为。它不是在 Linux 上测到两个 HarmonyOS 系统版本。测试必须同时记录真实测试 binding getter 的返回值和 A/B 覆盖来源，以免把版本模拟混成设备证据。

## 4. 已执行的原生验证

`publication-system-build.py` 以固定 Node 24.22.1 编译并调用真实 publication Node-API 绑定，包含：

- 普通 addon 与 linked 两条加载路径，各在 JIT / `--jitless` 下核对主线程及真实 Worker 中的四字段值和重复读取一致性。
- 四字段分别注入 NULL、空串、1025 字节值，共 12 个预期错误对照；另核对 1024 字节边界可返回。
- 旧真实 binding 缺少新增方法的先失败对照。
- 使用固定官方 `deviceinfo.h` 替换测试声明后重编并运行；该正常 addon 与使用测试声明的正常产物逐字节相同。

首次执行报告共 **34 个成功操作记录**，其中包含编译命令和预期失败对照，不能写成“34 个产品功能或设备能力通过”。正常 addon SHA256 为 `443a64a9630927881e5a77dec0163c20b9a8750629e45573d5930250febfbfe2`，linked 测试库为 `09dbe1af70e5376f65b5d3ba696c69d96b85ea7721ac672640ccb9c4f357e883`。这些是 Linux 测试产物，不能进入 HAP。旧39的四函数产物及 M6-5对旧39的评估证据保持原身份，不因本轮新增第五个函数而改写历史测试。

复现（输出目录必须不存在）：

```sh
python3 runtime/tests/ohos/system-build-identity/fetch.py --cache /绝对路径/来源缓存
python3 runtime/tests/ohos/publication-system-build.py \
  --node-root /绝对路径/node-v24.22.1-linux-x64 \
  --out /绝对路径/新测试目录 \
  --official-deviceinfo-header /绝对路径/来源缓存/interfaces__kits__syscap__include__deviceinfo.h
```

可加 `--baseline-addon /绝对路径/旧39/publication.node` 重放旧接口负例。未提供旧 addon 时少一项记录。报告包含真实命令、返回码、stdout/stderr、输入和产物 SHA256。

## 5. 尚未得到的证据

目标 SDK 中头文件、库文件及 symbol 是否与公开来源一致；实际应用身份是否能取得四字段；真实系统升级前后元组变化；目标 arm64/musl ABI、HAP 加载和 Ark/Node 符号边界，均未在本环境执行。以 Linux fixture 的公开声明编译成功，不足以替代这些步骤。系统元组变化本身也不证明 seccomp 放行或某个挂载支持 flags；仍须执行 `M6-3-device-prerequisites.md` 的设备清单。

调查中的错误路径已保留：最初把 C API 猜为 `interfaces/kits/syspara/` 得到404；之后以官方仓库 tree 找到 `interfaces/kits/syscap/`。将 release 名按 heads 查询也得到404，实际 commits 接口成功解析到上述固定提交。最终证据只使用真正取得且核过哈希的文件。
