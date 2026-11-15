# 非官方 HMS 最小声明

这些文件只用于公开 OpenHarmony 工具链检查调用方逻辑，依据用户提供的 `hms-contracts.md`（追加5/6）。它们不是华为 SDK，不可用作正式发行 SDK，不证明 HMS 签名、链接、SysCap、地区可用性或设备行为。即使本地严格 ArkTS 0 错误，相关分享、语音、PDF 仍标 `UNCOMPILED_HMS`。

`check-arkts.sh --hms-stubs` 在工作目录内复制 ETS 工具并加入三个 Kit 的最小声明。公开原 SDK 不改写；若原 SDK 已经包含某个同名声明，准备脚本拒绝覆盖。输入 SDK 内容、准备脚本和声明的 SHA 决定私有目录。输入目录中的符号链接在复制时展开为私有普通文件，避免写回输入；循环链接会拒绝。每次复用前核对全部公开文件和九个声明的路径及 SHA，额外、缺失、变更或私有链接均拒绝，不能只核对 stub。普通检查不走该目录。

`python3 tooling/ohos/tests/prepare-hms-sdk.test.py` 在临时微型 SDK 上验证九种实际文件系统情形；旧 helper 只通过三项，修后九项通过。原独立反例与旧 BLOCKED 报告保留在交付证据中；这些测试不代表正式 HMS SDK 编译。

`api/` 是非官方接口边界，`kits/` 和 `kit_configs/` 仅使公开 Kit 解析器能定位它们。完整来源和仍未知的七项设备行为，以工作区的 `hms-contracts.md` 为准。
