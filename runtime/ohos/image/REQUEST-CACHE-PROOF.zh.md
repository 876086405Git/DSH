# 1230：最近一次已验证图像发布的进程内证明复用

## 交付范围与前置

这是以 `a836880` 为基底的 **OH 产品输入补丁**，不是完整 NDK 安装包或新的累计补丁。它包含完整更新后的 `ohos-image-codec.diff`（保留 941-12 编码接线和 1221 诊断顺序修复）、该差分的 OH pin/series 登记、针对性测试与本说明。它**不重新包含** 941-12 的原生源码、preload、构建器、加载器接入及原有 `image-attachment-*` 门；运行需要这些已经审过的前置组件。单独应用到裸 a836 不等于图像能力已经可用，缺少前置时应按缺输入处理。

本输入视图为 OH 178 项 / 124 个最终 pin，Android 145 项。当前累计 1226 为 OH 182 项 / 126 个最终 pin；合入累计时只替换现有 image 差分及其 after pin，合并新增门和测试，**不能用本输入视图的整份 pins/series/runner 覆盖累计文件**。本件没有更改 Native ABI、协议版本、codec identity 或任何 C/C++/NDK 源码。无需为本件另改原生编译，但必须已有 941-12 实际组件。本机 SDK/设备验证仍沿原范围。

## 修正目标

1224 已测到：保存一张图后，两个紧邻相同请求的 pack 累计计数是 1 → 2 → 3。当前原生 `inspect` 只给容器事实，不给源像素 sRGB，因此已有缓存即使是上一轮自己编码、完整复验、关闭并发布的输出，仍会因 `space === undefined` 而 miss。

本件只让 **同一服务 owner、同一当前 variant、同一磁盘字节及事实** 复用刚完成的证明。真实宿主链上的相同序列变成 1 → 2 → 2；第二次的 source decode、scale、pack、output verify decode 增量均为 0。读取原附件、完整性检查、缓存读盘、容器 probe 和 SHA-256 仍会执行，不能把它称为“零工作”。

没有把源色彩未知改成已知，也不调用会转色的 `open/detect` 充当原样色彩证明。实际 `codec.probe(cache).space` 仍为 `undefined`。新进程、另一个服务 owner、记录被淘汰或校验不符时继续原来的保守重编码路径；不是跨进程或任意缓存的命中保证。

## 一条记录的成立条件

每个加载的 attachment 模块实例只有一个模块私有 `ohosCacheProof`。记录保存 owner 标识、variant 字符串、输出 SHA-256、宽高、媒体类型及 alpha；没有图像 Buffer、ArrayBuffer、frame、NDK handle 或 sidecar。后完成的成功发布替换前一条记录；这不是按每次访问更新的 LRU。已有明确 sRGB 的缓存命中、公开 helper 调用及普通读取不登记新证明，也不主动清空旧证明。

登记必须同时经过以下实际顺序：

1. `encodeOhosImage` 等待固定 preload 的 `encode` 成功。preload 的 `checkedEncoded` 要求原样输出解码得到 8-bit/sRGB/尺寸/alpha 等事实；`usingFrame` 又等待 native close 成功，之后才返回。
2. `verifyRequestImage` 确认该 image 属于本模块的成功编码 WeakSet。失败、关闭未确认、编码或复验拒绝都到不了登记点。
3. 对尚未返回给请求调用方的私有输出字节计算 SHA，复制其标量事实。addon 的 `napi_create_buffer_copy` 先把已验证 C 输出复制为 JS Buffer，之后 C 输出释放；preload 只建这个 Buffer 的视图，不借用输入或已关闭的像素对象。
4. `await writeCached` 完成真实临时文件写入、rename 及 finally 清理。只有该 await 成功，且共享请求 signal 未 abort、owner 仍 active，才替换记录。发布或清理失败不登记。

返回给调用者的 `Uint8Array` 可以被修改；证明只保留之前的摘要和标量，不再引用它。调用者通过 `Buffer.from(result.data.buffer, ...)` 改原始返回值、改命中后的返回值或改返回 metadata，都不会改变证明。下一次命中还要从磁盘重新读出并计算摘要。

证明登记当时成功且未取消即可。登记之后、调用者收到结果之前才发生的取消，不应追溯地把已验证且已完成发布的磁盘结果变成无效；一个共享请求的部分 waiter 取消、另一个 waiter 成功，也允许正常登记。

## 命中和撤销

`readCached` 继续对当前磁盘读取的字节执行实际 `probeImage`。只有记录属于当前 active owner，且当前 variant、SHA、probe 得到的宽高、媒体类型和 alpha 逐项相符，才允许为 **undefined 的 space** 复用该输出曾经验证过的 sRGB 事实。显式 `space: 'other'`、非 uchar、尺寸超 target、alpha 不兼容、当前字段和已验证事实不符，仍然 miss；未知事实不是默认 sRGB。

当前 variant 仍由原有 descriptor 重新计算，包含 attachmentId、目标尺寸、字节预算、transformVersion 和完整当前 codec identity。因此身份改变也会失配，不另外改持久 variant 格式。缓存中不可用或损坏的字节继续回退有效原附件；未确认回收的 native owner 错误不能吞掉，取消继续保留原 reason。

每个服务构造时闭包持有自己的 owner。Cordis 的真实 service tracing Proxy 不适合直接在经代理方法中读取 JS `#private` 字段，因此采用模块私有 Symbol 所指向的执行闭包。**Symbol 可以被反射枚举，闭包也可以被调用，不能将其称为安全隔离。** 闭包参数仍沿既有内部 `readRequestImageFile` 的“已核实 attachment”合同；它没有 owner/proof 注入参数，也不返回这些状态。公开导出的 `readRequestImageFile(root, attachment, target, signal)` 仍为四参数，不持有 owner，因此不借用这条私有证明。本件不试图防御任意能反射、改写服务或文件系统的同进程恶意插件。

服务所属 fiber 的 disposer 将 owner.active 永久置为 false，并且只清除仍属于该 owner 的全局记录。旧 owner 的迟到 dispose 不能清掉另一个 owner 的新记录；关闭或发布在 dispose 后才完成也不能重新激活 owner。保留旧 service 引用再调用的行为仍沿原实现，但这些调用不会再登记或复用证明。本件不改变原有请求取消、compression limiter 或原生资源关闭语义。

## 作者实际验证

全部为宿主范围，产品 JS / N-API / scanner / ladder / C 实现真实执行；SDK 像素与 SDK 方法由 941 固定宿主夹具提供，不是真机像素解码。

| 项目 | 实际结果 |
| --- | --- |
| 最终同版 native actor 对旧模块，JPEG/WebP 紧邻请求 | 2 项真实行为红；第二次四项转换各 +1 |
| `attachment-cache-proof-strict` / `-sim`，实际登记 | 各 22/22，0 skip/cancel/todo |
| `attachment-cache-proof-native-plain` / `-jitless`，实际登记 | 各 11/11，0 skip/cancel/todo |
| 原附件诊断 strict/plain | 9/9、8/8，组件缺席时 missing/corrupt 码保持 |
| 原 codec seam 缓存 strict/sim | 各 8/8 |
| 原 image-attachment 真实宿主入口 plain/jitless | 两次原有完整 actor 通过，输出字节、variant 与 owner 关闭检查保持 |
| runner 单测 | 25/25 |
| patcher 单测，补齐原始 npm fs-local 输入后 | 32/32，0 skip |
| 官方 `patch-dsh --target ohos` | 178 项链、124 个 final pin 核验，精确生成新 attachment 后像 |
| Android 输入身份 | 145 项顺序、字节、pins 全同 a836；指纹 `9054e3703e4fc16c5ff5a5276c617ec9bde974d8647b64735e81d80898656c5b` |

11 个 native 场景覆盖 JPEG、透明 WebP、返回值 alias、相同容器字段但字节被改、坏缓存、variant 淘汰、双实例及旧 owner dispose、销毁后保留引用、无 owner 的公开 helper、原附件丢失及损坏。所有公开 await 边界都核对 SDK create/release 平衡、inflight/压缩队列归零。

22 个 codec completion seam 场景另覆盖受控 close 延迟/未确认、实际 rename 失败、真实 rename 之后的 abort/dispose、全部 waiter 取消和部分 waiter 取消、当前 codec 身份变化、相同字节但不同宽高/alpha/格式/depth/space。其 close 失败是明确的协议边界注入，不假称目标 NDK 曾发生该故障。原生 C 源与已验证库均未变，本件复用固定宿主 SO，未新编原生库。

准备过程中保留了四类原始记录：Node 默认 spec reporter 导致早期 TAP 计数解析为空；原文件 0444 导致计划损坏夹具先遇 EACCES；小 native view 缺完整诊断依赖；patcher 初跑缺 `DSH_FS_LOCAL_ORIGINAL_JS` 导致 1 skip。它们均未计作产品功能红或完整通过。最终分别改正测试载体/输入并有完整结果；只重跑具体缺失项，不重跑全门。

没有运行完整门、完整 compose、OH SDK 编译/HAP、真机或设备性能测量；不报 PSS、CPU、功耗或毫秒收益。新增成本是命中路径的 SHA，收益证据仅为这里记录的转换操作数。

## 有限复现

实际正式入口是 `tooling/ohos/run-gates.py` 中新增的四个门。native 两门依赖原 `image-attachment-{mode}` 的 source/view/native 完成输出，再调用 `runtime/tests/ohos/attachment-cache-proof.py`；wrapper 在输入前后核验摘要，子进程逐场景保存 COMMAND、TAP、SDK trace 和 OBSERVATION，并由主 runner 再审 `test.log`。

单独有已准入的 host view、宿主 SO 和 publication fixture 时：

```bash
python3 -B runtime/tests/ohos/attachment-cache-proof.py \
  --source "$PWD" --prefix /absolute/current/image-view \
  --native-library-dir /absolute/existing/host-native \
  --publication-fixture /absolute/libpublication-test-linked.so \
  --node /absolute/node --out /absolute/new-proof-output --jitless
```

`--prefix` 中 attachment 的 SHA 必须等于本 source 的 image after pin；参数不能跳过该检查。原生 host 库应来自未改的 941-12 官方头形状夹具。本入口不会下载、安装、编译或准备完整门。随包中文说明和证据列出本轮的确切绝对命令、输入 SHA、当前累计组合视图及独立复核身份。
