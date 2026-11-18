# 单归档运行时：组成与实际安装产物验收

本增量把组成器的 HAP rawfile 输出改成单个 `dsh-runtime/runtime.zip`。清单 schema、逐文件 size/SHA256、逻辑 `runtimeVersion`、固定 npm 输入、静态导入审计、六个宿主必需入口、Android 目标及 native 分离规则保持原契约。安装端使用独立的 `RuntimeZip`、`OhosRuntimeArchive` 和 `OhosRuntimeStorage`，具体事务、公开 API 与故障恢复规则见 [单归档安装](runtime-archive.md)。

## 一、输出与装配契约

| 对象 | 格式及用途 |
| --- | --- |
| `rawfile/dsh-runtime/runtime.zip` | 唯一需要进入 HAP rawfile 的运行时文件；内部首成员是 Stored manifest，其余是 Deflate 文件 |
| `dsh-runtime-rawfile.zip` | 构建传输归档，只有一个 Stored 成员 `dsh-runtime/runtime.zip`；构建系统只展开这一层 |
| HAP 的 `resources/rawfile/dsh-runtime/runtime.zip` | 必须仍为 Stored，以取得有界 raw FD；最终检查由新的 `audit-hap.py` runtime 审计执行 |
| 输出根的 `manifest.json`、组成报告及逐文件清单 | 构建、重现和测试元数据，不在 rawfile 中，不随 HAP 作为裸运行时文件交付 |
| `expanded/dsh-runtime/` | 仅 `--keep-expanded` 时保留的构建检查树；默认在归档逐成员回读通过后删除，不进入 HAP |

`build-hap.sh` 仍属主线维护范围。本增量不修改该脚本或 CMake、Node 构建。主线接线应把旧的裸 `manifest.json` 存在检查改为单归档路径，并保证 HAP 中该成员 Stored；不能在 rawfile 中再展开内层 ZIP。配套 Controller/Diagnostics 通过 `readBundledManifest()` 读取，安装入口在 `withBundledRuntime()` 租期内执行；旧的逐 rawfile 读取链不能与新格式混装。仅组成成功不证明上述构建和 Ark 接线已经完成。

## 二、固定 ZIP32 子集

内部归档按清单原有词典顺序写入，第一项 `manifest.json` 用 Stored，后续 `files/<path>` 用 Deflate level 9。时间固定为 2026-01-01 00:00:00，Unix 类型与权限为普通文件 `0100644`；不复制源文件的 mtime、执行权限或其他宿主元数据。非 ASCII 文件名由 UTF-8 标志表示。

组成器不生成目录成员、加密、注释、extra、data descriptor、ZIP64 或多卷。安装器与审计器还逐项核对 local/central 记录及首尾连续性。组成器先拒绝超出安装器明确上限的输入：

| 限制 | 上限 |
| --- | ---: |
| 成员数量，含 manifest | 2 至 65,534 |
| 归档总字节、展开总字节，含 manifest | `0x7fffffff` |
| central directory | 32 MiB |
| manifest | 16 MiB |
| 单个文件 | 512 MiB |
| 带 `files/` 前缀的成员名称 | 4096 个 UTF-8 字节 |

这些是项目采用的有界格式，不是对通用 ZIP 最大能力的说明。路径、原生后缀、文件/目录冲突和八个入口先经过真实 `RuntimeCore.validateManifest`；组成时的文件头门继续拒绝 ELF/wasm/PE/Mach-O。`.node.js` 仍作为普通 JavaScript 名称保留。

写完后逐成员回读 SHA256、size 和 CRC，核对方法、顺序、名称集合和元数据，再生成外层 Stored 归档并回读其完整字节。完整组成在自己的临时目录完成，所有门通过才将该目录 rename 到新的输出名；已有输出拒绝覆盖。正常异常会清理本次 staging，进程被强制杀死后的未发布 staging 可能保留，不能把它当成可安装产物。

Python 公开 `ZipFile.writestr(..., compress_type=ZIP_DEFLATED, compresslevel=9)` 明确设置每个成员的压缩等级；不依赖 `open(ZipInfo)` 隐式继承。测试把真实压缩体与独立 `zlib.compressobj(level=9, wbits=-15)` 比对，并先证明同一数据的 level 6 字节不同。[Python 3.11 的公开 zipfile 文档](https://docs.python.org/3.11/library/zipfile.html#zipfile.ZipFile.writestr)。

构建器会在宿主上读入单个文件以调用该公开 API；这不是设备上的内存预算。设备安装由另一个作者的 256 KiB 流式 inflater 完成。实际 RSS 必须以该安装器的大树测量为准，不能把块大小称为总进程峰值。压缩容器 SHA 的重现还需相同的 Python/zlib 工具版本；逻辑 runtimeVersion 仍只由原组成配方和文件内容决定。

## 三、实际组合输入

本轮组成源码从 `530f183906be2a218b1b09000400e01c9a572dba` 开始，依次应用表中前五项；安装消费使用第六项的精确模块及组成 v2 的 RuntimeCore 后像。产品补丁只包含组成器、测试和本说明，其他作者的冻结代码不会被复制进本补丁。完整 App 接线仍须同时装配这些依赖及调用方增量。

| 输入 | SHA256 |
| --- | --- |
| Worker v2 | `46b1b09b2b96ac774ada4d3b78b6e4accd450642b88287ea6a1bfe1424b44909` |
| 懒加载增量 | `c1f470fed52fa393175a666a53dd64425f47183102c9cfb617430b7c9a198215` |
| 已独审组成 v2 | `b8420b4351fbae0f9fb3c6e395e8f7e061b6f8c8a2eaaf75245b7302721436b1` |
| 宿主生命周期后端三文件候选 | `d8b64be860cee2d0f4cecd79f9b43a4484f05019b4c56bd26a7cfeb23febaea6` |
| 后台能力单读修复 | `5436fc874cd5fcfc8e116af565be9d9e3a80a8b752d792b61f5cfc8689d2ed36` |
| 本轮实际消费的安装器 v1 | `3773b7627839ef40de7db536266094fcb8333383f043c136dbe737580bc6447a`；生产模块已执行，审计器后续修订另记 |

后台候选的 coordinator/index 保留作者的精确后像；capabilities/snapshot 同时保留 Worker v2 的 `worker-rebased` 选项，组合 SHA 为 `ac0010ec61a7980aab06fefe00b8ca27713e331d9b94324270d365f2bdaa38bc`。这个组合后像有记录，不能直接引用后台作者在另一文件上下文中的 SHA。旧后台候选加单读修复得到正式生命周期 v2 的后端逻辑；正式完整包 SHA 为 `4625f65b2b83090e3329a191db856e5c1741aecef7ff90244a09d4c0762ba8b0`，不能同时叠加其完整包和旧分步补丁。

DSH 与 process 复用组成 v2 两次真实 npm ci 中已核的最后一份只读输入；新组成再次逐文件校验完整收据，SHA 为 `22f820fa973437ec2bdbfe5b2557bf9ce6c99f128c63ac36ee945a45e40082a7`。没有为本轮重新执行 npm，不能将它写成第三次 fresh install。Node 24.22.1、npm 11.9.0 的固定配方、27项 OH pins、esbuild 0.27.3 和 RE2 字节不变。实际压缩写入工具为 CPython 3.12.14 / zlib 1.3.2，完整版本记录随交付保存。

本轮实际重新运行完整 composer CLI、私有 Bash 构建、静态导入门及真实 RuntimeCore 清单函数，不是把旧 ZIP 改名。与已冻结目录载荷比较，路径集合完全相同，只有上述后台的三个 JS 文件改变，其余 14,250 个文件的 size/SHA256 完全相同。

## 四、实际单归档产物

| 对象 | 实测结果 |
| --- | --- |
| 逻辑运行文件 | 14,253 个，160,395,773 字节 |
| manifest | 2,804,962 字节 |
| 内层 `runtime.zip` | 48,389,806 字节，14,254 个成员 |
| 外层传输 ZIP | 48,389,950 字节，1个 Stored 成员 |
| runtimeVersion | `ohos-d6863796135182cec1c74a77` |
| 逻辑 payload SHA256 | `d6863796135182cec1c74a77441eb5bb863b97d233d27aa6903095f91159fa0c` |
| 内层 SHA256 | `45264ae6a136c374a6fc4d9ca43ae8002295ad90f0134cf245bc88a81dd351f3` |
| 外层 SHA256 | `15dd59daa902dcd1a4119c33812bc21a6c48d19665cdb5f8ca07ea0730e64898` |

同一逻辑载荷加裸 manifest 为 163,200,735 字节，单 rawfile 归档为 48,389,806 字节，差值 114,810,929 字节。这只是运行时资源输入的实际字节差，未构建本轮完整 HAP，不能把它当作整 App 下载体积或安装后的磁盘节省。安装后的逻辑文件仍需原来的展开空间。

内层清单 Stored 是显式协议，因此新归档大小不能直接与历史目录 ZIP 的 46,628,202 字节比较来推断裁剪退化：两者 manifest 的压缩方式、成员名称及后台文件都不同。137 个包含点路径组件的文件均在内层归档中，经另一位作者冻结的审计器逐 size/SHA/CRC 回读通过；rawfile 目录本身只有一个正常文件，没有裸 manifest/files 树。

## 五、验证层次与当前边界

小格式测试执行实际文件和 ZIP 字节：12项通过，覆盖 local/central/EOCD 一致性、确定性、真实 Deflate9、外层单 Stored、点文件、中文路径、空文件、任意非 UTF-8 内容、`.node.js`、未知文件、链接、覆盖拒绝及安装器数量/大小上限。草稿在上限门上真实出现5个失败断言，精确前像和原日志保留；修复后同一测试文件通过。该草稿不属于已冻结组成 v2。

另一个作者用冻结的实际3个 ETS 安装模块执行组成器生成的小包：10文件219字节，从测试 ZIP 的非零 raw offset 117 读取3503字节，真实 libz inflate 10次，资源打开/关闭各一次，结束后 FD 与 inflater 均为0。这里的资源接口明确是 Linux 替身，文件与解压是真执行；没有把它称为 Ark ResourceManager 实测或设备安装。

完整当前内层归档已经由独立编写的 `runtime_archive_audit.py` 回读全部文件，missing/wrong/extra 都为0；外层与内层压缩文件全字节一致。安装器对首份归档完成真实 fresh 安装，再使用最终归档在同树增量升级。升级实际只 inflate/替换一个3,061字节文件，另外14,252个文件的 inode 保持不变；完整文件集合随后再次逐 size/SHA256 校验，资源打开/关闭各一次，FD/inflater 均为0。

两次都是新 Linux Node 测量进程，没有清 OS 页缓存；fresh 为118.881秒、峰值 RSS 163,528 KiB，增量为32.945秒、峰值 RSS 193,944 KiB。增量仍读取全树校验并持有新旧清单/归属状态；只解压一个文件不能推出进程峰值必然下降。这是实际 ETS 方法、真实文件和测试专用 native libz 边界的测量，不能换算为设备耗时或 Ark 内存。

由实际 installed.json 和安装树产生的稳定快照随后直接传给 `host-layout.py --assembled-payload`。标准模型与 Node 脚本模型的两条链均真正编译原样 HostCore、调用 `Host::Start`、执行生成的 argv/env/profile、检查实际 DSH 消费者并完成各自严格五工具/两审批回合。两个回合前后安装载荷的集合、size/SHA 都不变。原进程矩阵也从同一升级后快照执行，JIT156/156、strict156/156 全过；没有使用开发 npm 前缀代替安装结果。

新后台候选曾把每次能力快照中的 owner.status() 读取重复两遍。组合中的原测试真实4过1败，断言为14次与期望7次不符；后台作者的单读修复后，同一测试5项全过（其中含 Worker 协议项）。首份完整归档与其118.881秒真实 fresh 安装、已通过的 Host 回合均保留为前像；不能因普通工具回合通过而忽略独立能力门失败。最终归档只在该前像之上改变一个 snapshot.mjs，采用真实增量安装后再次验收。

独立复核随后发现安装包 v1 的 Python 审计器对四种畸形 ZIP 存在假通过：Deflate 尾附字节、展开尺寸谎报、布尔 schema 及缺少生命周期入口；实际 ETS 安装器拒绝这些输入。该审计器不是本格式增量的代码，作者已另行修订。上述实际归档的成功回读记录保留其原版本与范围，不代表旧审计器已完整拒绝所有非法输入；最终组合发行必须使用修订后的审计器，并另记对同一实际归档的复核结果。这里的实际安装树、全部 SHA 和 Host 通过证据不因此改写。

本增量不新增原生库、依赖或权限，不改 Android recipe、输入、版本串与 Flutter UI；原来的两个独立重定向打开同一路径截尾限制仍存在。设备上的 raw FD offset、公开 zlib 的实际资源寿命、完整 unsigned HAP 审计及安装、中断/升级峰值和生命周期前后台行为仍须按各自证据范围验收。原目录格式的冷热20回合保留为历史数据，不迁移成单归档安装的性能结论。
