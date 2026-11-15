# 随包运行时的单归档安装

## 范围与依赖

本改动把 HAP 中的逐文件 rawfile 改成一个 `dsh-runtime/runtime.zip`。这个外层资源在 HAP ZIP 中必须使用 Stored；归档内部的运行时文件使用 Deflate。安装前仍核对清单，每个变动文件仍经 SHA256、暂存文件、原子替换与持久归属记录后发布到原来的 `filesDir/dsh-runtime/tree`。

代码基底为 `530f183906be2a218b1b09000400e01c9a572dba`。完整接线同时依赖组成 v2 的固定入口修订：`RuntimeCore.ets` 后像 SHA256 为 `7ea53d11c41e7d74a56d2886a6a8e034fa2f8f7df7b3349932d27c028d8f2644`。该文件由组成补丁提供；归档补丁不复制或改变启动入口集合，也不改变 manifest schema 或 `runtimeVersion` 的逻辑文件计算方式。

三个模块各自承担一个职责：

| 模块 | 职责 |
| --- | --- |
| `RuntimeZip.ets` | 有界 ZIP32 索引解析、local/central 对照、manifest 校验、成员与清单一一对应 |
| `OhosRuntimeArchive.ets` | 单个公开 raw FD 的租期、256 KiB 分块解压、CRC、解压长度和 ELF 拒绝、失败资源的所有权 |
| `OhosRuntimeStorage.ets` | 把流写入已有安装器的 staging，保留 SHA256、fsync、rename、journal 与归属清理契约 |

这些模块不导入 `libdsh_host.so`，也不启动 Node。构造 `OhosRuntimeStorage` 只建立内存对象，不读取资源、不探测磁盘。远程连接和 `guestRoot` 查询可继续保持零原生宿主加载。

## 打包格式

组成器交给构建脚本的 `dsh-runtime-rawfile.zip` 只含一个 Stored 成员 `dsh-runtime/runtime.zip`。构建脚本只展开这一层。它不得再把里面的运行时文件展开到 rawfile，也不得在归档旁保留裸 `manifest.json` 或 `files/`。

HAP 中对应的唯一运行时资源为 `resources/rawfile/dsh-runtime/runtime.zip`，同样使用 Stored，供 `resourceManager.getRawFd('dsh-runtime/runtime.zip')` 获取实际 FD、offset 和 length。资源可能位于 HAP 的非零偏移；所有读取位置均为公开 offset 加上已检查的归档内相对偏移。

内部 ZIP32 的约定如下：

| 项目 | 约定 |
| --- | --- |
| 首成员 | `manifest.json`，Stored，原 schema 1，UTF-8 JSON |
| 其余成员 | `files/<manifest.path>`，Deflate，与清单顺序完全相同 |
| 组成器顺序 | 原逻辑清单的词典序；归档解析器核对清单和 ZIP 顺序一致 |
| 组成器元数据 | Unix 普通文件 `0100644`，时间固定为 2026-01-01 00:00:00 |
| 标志 | 只接受 0 或 UTF-8 标志 `0x800` |
| 禁止 | 加密、data descriptor、ZIP64、多卷、注释、extra、目录项、链接项、重复名、隐蔽间隙或前后附加数据 |
| 大小上界 | 整体及展开总量不超过 `0x7fffffff`；central directory 不超过 32 MiB；manifest 不超过 16 MiB；单文件不超过 512 MiB；成员名不超过 4096 UTF-8 字节 |
| 数量上界 | 2 到 65,534 个成员，包括 manifest |

解析器核对两个目录记录中的版本、标志、压缩方法、时间、CRC、压缩/解压长度和名称。解压流必须恰好消耗声明的压缩字节，得到声明长度并以 `STREAM_END` 结束；末尾多余压缩数据也不接受。CRC 用于 ZIP 格式一致性，SHA256 仍是文件内容验收依据。

原来的路径规则继续由 `RuntimeCore.validateManifest` 决定：拒绝空组件、绝对路径、`..`、反斜杠、NUL、重复路径、文件/目录冲突以及终端 `.node`、`.so`、纯数字版本 `.so.1.2`。`client.node.js` 仍是合法 JavaScript 名称。解压时另外检查文件前四字节，拒绝把 ELF 通过其他后缀落到可写目录。原生库继续由 HAP 的 libs 交付。

## 安装与查询接口

`OhosRuntimeStorage` 保留原 `RuntimeStorage` 接口，并增加：

```typescript
readBundledManifest(): Promise<RuntimeManifest>
withBundledRuntime(work: () => Promise<void>): Promise<void>
```

Controller 的安装入口应在一次租期内完成读取和安装：

```typescript
await storage.withBundledRuntime(async () => {
  const manifest = await storage.readBundledManifest();
  await installer.install(manifest, progress);
});
```

Diagnostics 单独调用 `readBundledManifest()`。不得继续读裸 `dsh-runtime/manifest.json`。同一个归档对象缓存经过验证的索引和 manifest；再次查询不重新打开资源。该缓存假定同一进程内资源来自不可变的已安装 HAP；换包使用新的进程/Storage。它不是对任意可写 ZIP 的热替换缓存。再次打开时仍检查资源长度变化。

`withBundledRuntime` 不可递归嵌套；callback 内的 `readBundledManifest` 是允许的。所有归档对象共享串行租期，避免 ResourceManager 按资源名关闭 FD 时，一个诊断请求关闭另一个安装请求的资源。安装器本身的 busy 门、Controller 的活动 Node 禁止更新门继续有效。

`copyRawFile` 的旧参数仍作为清单路径一致性检查使用，调用方不必改安装事务。它不再按此路径逐个请求资源，而是在当前单归档中按索引取相应压缩成员。

## 解压状态与资源寿命

采用公开 `@ohos.zlib` 的 `createZip`、`inflateInit2(-15)`、`inflate`、`getZStream`、`inflateEnd`。`-15` 对应 ZIP 成员中的原始 Deflate 流。输入块和输出块均不超过 256 KiB。完整压缩包和展开树不读入一个大 ArrayBuffer；索引与 manifest 则按上述明确上界一次解析。进程 RSS 还包含 JavaScript 堆、索引、清单、安装器集合及分配器保留内存，不能把 256 KiB 宣称为进程峰值。

公开实现把 `nextIn`/`nextOut` 的 ArrayBuffer 指针写入内部 `z_stream`，并没有把解压结果写回调用方的 `ZStream` 对象。因此每次 `await inflate(...)` 后必须 `await getZStream()` 读取内部计数；不得从原 request 对象猜测消费量，也不得使用只在实现里出现、但固定公开 SDK 未声明的 `getZStreamSync`。产品在异步调用以及释放失败期间显式保留输入/输出 ArrayBuffer 的所有者。[公开实现：SetZStreamValue 与数组指针转换](https://github.com/openharmony/bundlemanager_bundle_framework/blob/7865b761797896f384e9465298014cdb541cb73e/interfaces/kits/js/zip/napi/common/common_func.cpp)、[getZStream/inflate](https://github.com/openharmony/bundlemanager_bundle_framework/blob/7865b761797896f384e9465298014cdb541cb73e/interfaces/kits/js/zip/napi/class_zip/zip_n_exporter.cpp)。

释放失败不视为释放成功：

1. `inflateEnd` 拒绝或返回非 OK，保留 Zip 对象和两个缓冲区，下一次会话先重试释放；失败时不开新会话。
2. `closeRawFd` 拒绝，保留原 ResourceManager，下一次会话先向原 owner 重试关闭，再打开新资源。
3. 写入/目录 `fs.close` 拒绝，保留 File 对象；下一次可写打开前按顺序重试。新 Storage 实例也能接续退休 owner 的清理。

这些重试没有忽略错误或伪造空闲状态。Linux 故障注入覆盖了失败后换新对象的恢复路径；目标系统真实错误时序仍要在设备验证。

## 增量与中断

`RuntimeInstaller` 继续先验证清单和前次归属记录、持久写入 `installing.json`，然后对目标文件逐个检查 size/SHA256。命中的文件不解压、不重写，原 inode 保留。只对变动成员执行分块解压，写 staging，验证完整 SHA256，fsync 后 rename，再同步父目录。

`installed.json` 仅在全部成员完成后提交，最后清除安装中标记。进程被杀时，旧 journal 继续阻止把半安装目录报告为 ready；下次按相同清单重新检查，已完成且 SHA 命中的文件直接复用。换清单恢复只清理前次已登记的文件和 staging hash，不递归删除未登记内容。

“无变动不解压”不等于“完全无写入”：原有 journal 与 installed 元数据提交仍会发生，SHA 检查也仍读取目标文件。本实现没有改动这一持久化语义。

## 公开能力与构建接线

本包核对的公开声明来自 SDK `26.0.0.38`：`@ohos.zlib` 的流式 Zip API 自 API 12 提供，系统能力 `SystemCapability.BundleManager.Zlib`；`resourceManager.getRawFd/closeRawFd` 自 API 9 提供，系统能力 `SystemCapability.Global.ResourceManager`。这些方法不引入新的应用权限。异步操作仍可能失败，错误会向准备/安装调用方传递。[固定官方 zlib 文档](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/reference/apis-basic-services-kit/js-apis-zlib.md)。

`tooling/ohos/runtime_archive_audit.py` 验证 HAP 的单 Stored 成员与组成输入压缩包中对应成员全字节相同，再检查内部 ZIP 和所有文件 SHA/CRC、ELF、路径及多余成员。`audit-hap.py` 只将原运行时审计段切换到该 helper，原 native、资源和其他门继续执行。该 helper 单独跑过不代表完整 HAP 审计已跑过。

审计必须验证完整压缩流，不能把 `ZipExtFile.read()` 返回的声明长度当作实际展开长度：它会在 ZIP 声明的 `file_size` 处截断可见数据，可能隐藏实际展开的额外字节或流后的压缩输入。v2 直接按已核对的 local header 取得原始压缩范围，使用 `decompressobj(-15)`，每次最多产生 `min(256 KiB, 剩余声明长度 + 1)` 字节；只有 `eof`、全部压缩字节消费、无 `unused_data` / `unconsumed_tail`、实际长度、CRC 和 SHA 同时满足才放行。这个额外字节只用于判定超量，不把整个恶意展开流先分配出来。外层 Stored 资源和传输成员也要求 compressed/uncompressed 两个长度相同。

Python 清单验收与实际 `RuntimeCore.validateManifest` 的 JSON 输入域对齐：数字 `1` 与 `1.0` 都是合法 schema 1，布尔值 `true` 不是；size 使用 JS 安全整数语义，允许 `1.0`、拒绝布尔、非有限值、非整数和越界；空字符串 `dshVersion` 保持合法。JSON 非标准字面量 NaN/Infinity 拒绝，路径后缀匹配采用与 JS 相同的 ASCII 数字和绝对结尾语义。必需入口从现有 `Host::Start` 的 `File(options.runtime_root, literal)` 和 Core 的固定 entry 数组提取并要求集合一致，不再维护第三份路径清单；源码形状变化或两端漂移会明确使审计失败。

独立反例已实际显示旧审计会放行而安装器拒绝的四个输入：Deflate 后附字节、实际展开 1 MiB 而清单/CRC/SHA 声明 1 B、`schema:true`、缺少 lifecycle 必需入口。它们的 local/central 元数据一致，HAP 与组成输入的内部 ZIP 全字节一致，排除了“只是外层包不同”的解释。原探针和原字节保留；v2 对相同输入与合法控制逐项重跑，四项都拒绝、合法控制仍通过，实际安装器终态 FD/inflater 均为零。三个 ETS 模块没有因此修改。

530 基底中 `build-hap.sh` 和 `check-arkts.sh` 仍检查裸 manifest 路径；接线方必须改为 `runtime.zip` 的存在和 Stored 交付。归档补丁不修改被列为主线专属的 `build-hap.sh`，也不修改 CMake、Node 构建、原生库、Android target 或 Flutter UI。

## 验证层次

作者的测试直接转译实际 ETS 方法，资源接口是显式替身，文件操作使用真实 Linux 文件系统；zlib 边界使用测试专用原生 shim 执行真实 inflate。测试 shim 不进入 HAP。该证据支持格式解析、字节完整性、事务、故障恢复和 Linux 测量，不能替代 ResourceManager/zlib 在 Ark 上实际运行。

基底旧 Storage 在新单归档上实测因仍索取裸文件而失败；旧审计段也因查找裸 manifest 而失败。另保留写入 FD 关闭失败后旧 owner 丢失、local/central 版本号不一致被接受的前像和对应修复后证据。真实大树测试包括 SIGKILL、续装、空目录完整安装、再次校验以及只改一个成员的升级。

离线审计保留原 18 项并补充为 28 项；原测试的有效起点补齐 Host/Core 的全部真实入口，避免缺入口掩盖 CRC、ELF 等原负例。另有 87 个清单输入直接与未经改写的 Core 方法体对照，包含整数/浮点写法、布尔、JSON 边界、路径、冲突和逐个缺入口，接受条件无差异。`runtime-archive-manifest-contract.py` 调用固定 Node 读取原样 Core 的 `.mts` 副本，仅由 Node 去除类型；这项结果不是 Ark 编译。

严格 ArkTS 编译的精确输入摘要、逐轮日志和大树原始测量随交付证据给出；作者不把类型检查、Linux 测试、局部 Ark 编译合并成“设备通过”。正式发行前仍需在真实完整 HAP 上验证 Stored raw FD、流式 zlib、首次安装/中断恢复、峰值内存和冷启动表现。
