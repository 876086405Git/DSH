# 鸿蒙插件包管理的明确拒绝

## 范围与契约

固定输入为 DSH `0.2.1-rc.4` 和仓库 `c818155` 的既有补丁链。本补丁只加入 `ohos` 目标；Android 目标的补丁选择、产物字节及 recipe 输入不变。市场兼容性扫描与现有插件的启停不在本补丁中。

鸿蒙应用内不能启动 pnpm 或任意外部进程。安装、更新、卸载插件包均在创建请求控制器、改写 profile 或调用包管理器前拒绝，稳定诊断前缀为 `OHOS_PLUGIN_INSTALL_UNAVAILABLE`。用户看到：

> [OHOS_PLUGIN_INSTALL_UNAVAILABLE] 鸿蒙本机不支持安装、更新或卸载插件包；可启停随包插件，或连接电脑管理插件。

判断仅使用真实 `process.platform === "openharmony"`。生产代码不读取模拟开关，不改全局 builtin，不引入新协议枚举或新依赖。

## 返回形式与实际客户端

`PluginManager.installBundle` 返回现有协议的已解决 Promise：`stage: "install"`、`application: "failed"`、`changed: false`、原 `target` 与请求的 `enabled`。错误沿用 `ManagementError.code = "operation-error"`，详细原因放在 `diagnostic` 中。请求不进入 `installs` 集合，不创建取消控制器、诊断日志或安装状态事件。

`PluginManager.removeBundle` 同样在最外层返回 `stage: "remove"`、原 `target`、`application: "failed"`、`changed: false` 和同一错误。它不能仅依靠内层 `runProfilePnpm` 守卫：固定实现会先 `selectBundle(name, false)` 并 reload，再运行包管理器。v1 的独立实际服务反例已经证明这一顺序会在拒绝之前修改 profile 并禁用包。v2 将拒绝放在 `this.change` 之前，避免该副作用，也不发送 changed/install-log 事件。

这是对固定源码调用方的适配：`@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js` 的 `resolvedChangeResult → settleInstall` 将该返回值落为 `failed`；仅抛出远程调用错误会走 `installUncertain → waitForInstall`，最终可能显示 `unconfirmed`。因此拒绝必须是实际 `ChangeResult`，不能伪装成成功，也不能只依靠超时后解释。

同一固定 Web 客户端的 update 操作，对已安装包先调用 `removeBundle`，随后打开安装对话框；即使 removal 是失败的 ChangeResult，也可能进入后一个步骤。v2 不改客户端：前一入口无副作用地拒绝，后续 inspect/install 仍各自拒绝。验证按这个服务调用顺序运行，不宣称执行了浏览器界面。

`inspect` 在解析安装规格、访问 profile 和网络之前返回既有 `refused("unknown", reason)`；`registries` 返回已配置注册表与复制的后备列表，将 `resolved` 设为 `null`，避免打开安装对话框时执行 `pnpm config`。两个返回值均经过包内真实生成的 TYPERT/Zod schema 解析验证。

运行时内嵌的 `runProfilePnpm` 及导出的 `operations.runProfilePnpm`、`operations.runPluginCommand` 均在入口设置同一守卫。直接调用 operations 时抛出 `ERR_OHOS_PLUGIN_INSTALL_UNAVAILABLE`。后者的守卫在创建目录与取得文件锁之前。既有随包插件的启停路径未改；所有非鸿蒙分支继续执行原代码。

## 固定补丁与 hash

`runtime/patches/zzzzzzzzzzzzz-ohos-plugin-install-refusal.diff` 的两处前像均由既有固定补丁链产生，`pins.json` 同时记录前后像。目标列表的文本位置不决定应用顺序；`rtbuild.select_dsh_patches` 按名称排序，本补丁在前述既有插件管理守卫之后执行。

| 固定产物 | 前像 SHA-256 | 后像 SHA-256 |
| --- | --- | --- |
| `dsh-plugin-manager/lib/index.js` | `7978a5b16f406b3c223de5a83c93e86125677ece1265d39d79dcba19de13cd45` | `be812f844e6da171a7e2a874fca716f05a157dcab96ded1c79a35f679285b6c7` |
| `dsh-plugin-manager/lib/types/operations.js` | `a9f2c4bbcfcad95eaac8878358e5aecb2532cfa4a7a9c6f981ff507fe3403f94` | `baa52993c097351842b4446cdba0a4a63cb63c5db4d906ab94180216f951a32c` |

## 已实际执行的验证

环境为 Linux x86_64、官方 Node `24.22.1`。严格仿真使用既有测试 preload：禁 spawn、禁止非白名单 addon、删除 WebAssembly、将 platform 改为 openharmony。该仿真只用于测试，不属于产品启动参数。

1. 对真实固定 DSH 导出的方法运行 `plugin-install-refusal.mjs`。未补丁前像 **0/10**；旧 v1 **7/10**，恰好遗漏三种 remove 入口；最终后像 **10/10**，覆盖安装选项、卸载名称、检查、注册表和两条 operations。代理对象在任何 profile/control 属性访问时立即报错；实际 TYPERT schema 解析安装、卸载、检查与注册表结果。Linux 原分支另有 **6/6** 回归。
2. 将 `plugin-install-observer.mjs` 注入实际 DSH，校验 service `instanceof` 与模块 hash。在新 profile 写入两个只有空 YAML 的受控本地包，再由真实 `listBundles` 确认两者均 installed/enabled/removable。分别测 install、remove 及 update 的 remove→inspect→install 顺序。v1 留下六项实证失败：两包的启用状态、profile 字节及事件均受影响；v2 的八个受控文件 hash（四个 profile 文件、两个包的 metadata/YAML）、依赖、启用和安装状态、请求集合、来源映射均不变，事件 **0**。
3. v1 与 v2 各自完成严格模式的五工具回合与两次审批。v1 的工具回合成功不抵消其拒绝契约失败；两个判据分别记录。测试包没有经过包管理器下载或安装，也不含可执行代码。
4. 实际重放 `--target android`，逐项比较 **30,473** 个文件、目录及符号链接的模式、目标和内容，全部相同。Android recipe 输入为 **3,789 字节**，SHA-256 `67a8c2a119a9d254ba27f6e657f11fca73ee30de499a723f2084f57f213f5f39`。

作者的完整命令、stdout/stderr、未补丁及旧 v1 失败、schema 结果、实际服务证明、严格回合以及 Android 比较随独立交付包保存。旧 v1 补丁和其独立审查证据保留原字节；本次交付是基于同一源码快照的完整 v2 替换包。

## 尚未验证

没有 OpenHarmony SDK、目标设备或 Flutter 端到端环境；未宣称 HAP、目标 ABI、真机 UI 或远程电脑安装验证通过。客户端分支兼容性来自固定源码与真实 wire schema，不等于手机界面截图验收。该小补丁不提供任意插件兼容保障，插件静态扫描和最终全栈重建另行交付。
