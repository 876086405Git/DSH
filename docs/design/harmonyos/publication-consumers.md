# M3-1b 补充：发布遗留物与实际消费者

## 可成立的结论

固定本次 DSH 版本时，会话发现先以规范日志名筛选，再读选中的文件；本地附件按明确引用构造路径。`.dsh-ohos-publish-*.tmp` 普通文件不会成为已审会话枚举器的日志候选，也没有在已审本地附件服务中发现自动枚举目录拾取这些文件的入口。

此结论由两类证据组成：固定消费者源码的逐段推导，以及真实 provider 的 Linux 内核文件事件观察。它不等于“全项目没有其他文件扫描器”，不证明遗留文件已经回收，也不把严格 O0 仿真当作 OH 真机。

## 固定输入与源码推导

| 输入 | SHA256 |
| --- | --- |
| session JSONL provider | 766947337bf8f64a97ef6e2729c14fb2e823b6f2942707beb6a5af845172e471 |
| local attachment provider | b1b9a6610a04643433c5dba552262bc68d2c034b71168228d380fe1ce7eb998d |
| publication index | cc74645eb64e24d0122f5078970982a4da53626e6ea380594acb65c7d5bf75e0 |
| publication atomic | e9c248509ecd17f92e728637c89620ae8dba8667994eae8181c79d4520cf026a |
| publication ledger | 2470d48eed3d44b914c27bbbeb1a88ada325bed0057e100191b1eb51fcfb10d9 |

完整审计在交付包 support/consumer-source-audit.json：307 个实际安装的 `@deepseek-ai` 包、1134 个 JS/MJS/CJS 文件、68,948,400 字节的词法盘点；18 个关键源码文件逐段审阅，前后摘要未变。7 个未安装的平台包列为 NOT_INSTALLED_NOT_AUDITED。JSON 保存全部文件身份、检索模式、命中行号以及各条推导的源码行区间；support 中提供只读重放脚本。词法检索不是完整调用图，零命中不推出全局不存在。

源码链为：`list/open → listArtifacts/findLog → resolveGenerationInDirectory → parseSessionFormatLogFilename`。规范名只接纳 `session.jsonl` 或相应正整数世代，zstd 路径先剥离对应压缩后缀；`.dsh-ohos-publish-*.tmp` 不会被打开为头、正文或相反编码候选。上两级主要枚举目录，项目层对旧平铺日志的拒绝也只针对 `.jsonl` / `.jsonl.zstd` 普通文件。

迁移入口和打包 worker 的 `inspectExpectedCurrent` 只检查指定 current 及大小写别名；删除接缝在 `lstat` 前筛选规范日志和另一套 `session.*.tmp` 名。它们不把发布临时名当日志，删除接缝也不会替账本回收该类文件。查询、SQLite 索引、Workspace 和 API 冷读取通过 persistence 的 list/open 服务取得会话；ZIP 导出以指定 ID 读取日志，并从日志中的附件引用集合调用附件服务。上述消费者的完整绑定见审计 JSON，而非仅凭名称猜测。

附件图像、file-object、缓存的实际叶子名由受校验摘要导出；普通文件附件按摘要和净化叶子名构造精确 alias 路径。`readFileStream` 直接打开引用目标并验证内容，没有“目标缺失则扫描临时文件”的路径。**普通文件的合法用户文件名可以长得像 `.dsh-ohos-publish-*.tmp`**；本次没有加入前缀封禁，正常引用仍应读到这样的附件。不能把“不会自动拾取 orphan”改写成“任意人工构造引用都不可能读到它”。

通用文件工具、技能根、文件引用浏览、应用发现和 spill 等另有枚举器；本结论不替代它们的授权与配置分析，也不覆盖错误地将这些根指到数据目录的用法。Projection cache 的 sessions 表与 JSONL 原始会话布局不同，其 JSON 存储仅按 `.json` 叶子名读取记录。

## 实际观察设计

新增 `runtime/tests/ohos/publication-scanners.py` 是 Linux 外部观察器，`publication-scanner-actor.mjs` 通过实际 Cordis 服务使用未改写的两个 provider。没有替换全局 fs API，也没有伪造一个附件扫描器。

每个场景先通过真实生产服务产生可读数据。关闭原服务后，将一份有效 canonical 日志或附件 alias 改名为发布临时名，另放入零字节、半条 JSON、无效内容和不同目录层级的测试遗留物。这样会实际存在“内容可用但名称不对”的反例候选。此处是受控遗留物构造；真正 SIGKILL 的六阶段／两 provider 矩阵已在 34 号交付，本补充不把 rename 夹具说成新增的杀进程测量。

Python 在收到 ready 屏障后给每个候选 inode 加 inotify OPEN/ACCESS 观察。新建冷服务，然后执行正常 list/stat/open 或附件引用读取。合法 canonical 文件必须产生 OPEN 与 ACCESS 阳性事件，临时文件必须没有这两类事件。随后另一个屏障让 actor 显式读取每个临时文件，要求全部产生 OPEN、非空文件还产生 ACCESS，并核对其内容没有被前一阶段改动。最后先停止观察，再恢复原 canonical 名；真正的消费者必须重新列出/读到该份有效数据。

观察不以“列表里没返回”代替“未读入”。inotify 事件可能合并，记录只证明阶段内事件是否出现，**不把事件条数当 read 调用次数**。队列溢出、观察失效、无法加 watch、重复 inode 映射或未知 watch 都直接使实验失败，不接受其零事件结果。

| 场景 | 正常读取阶段 | 独立阳性与语义对照 |
| --- | --- | --- |
| 未压缩 JSONL | list 只有真实会话；stat/open 成功；隐藏 canonical 缺失 | 临时文件可观测；恢复 canonical 后会话重新出现 |
| zstd JSONL | 相同服务操作，既不误解析临时内容，也不报相反编码冲突 | 有效压缩数据改回规范名即重新出现 |
| 通用文件附件 | 正常引用成功；临时样式合法用户文件名成功；缺失 alias 报 ATTACHMENT_NOT_FOUND | 临时文件可观测；恢复 alias 后按原引用成功 |

JIT+显式 OH marker 与严格 `--jitless`/O0/openharmony 仿真各跑三场景，共 **6 PASS / 0 FAIL / 0 SKIP**。每场景五个临时 inode，共 30 个场景内观察，正常读取阶段均无 OPEN/ACCESS；随后各自的正控都成立。严格 actor 实际断言禁止 spawn/dlopen/link、无 WebAssembly。此处 JIT 也明确启用了 OH 服务标记，不是 Android 对照。

最终观察报告 `evidence/scanner-observation-02.json` SHA256 为 `0d82bb4041f913d242aff593c123b70dd52cba371b866c4185f130f47467382c`，包含逐场景命令、约束、原始内核事件及输入 SHA；所有输入与 provider 前后摘要相同。首版 01 也有 6/6，但报告只绑定 preload 未枚举三份传递实现；02 补齐 index/atomic/ledger 的身份并重新运行。两版记录及旧观察器源码均保留，这次修正是证据绑定补强，不是产品先失败。

观察固定 Node 24.22.1 `e32e2d16…cfafb`，使用 34 的 Linux linked publication 夹具 `569b89fc…056aa`。它是初始化前注册的宿主测量夹具，不能据此认定 OH 目标 ABI 或真实应用 seccomp 允许调用。

## 复跑与未覆盖项

在已安装精确 OH DSH 补丁链、准备好 34 Linux linked 夹具的仓库中：

```sh
python3 -B runtime/tests/ohos/publication-scanners.py \
  --node "$NODE24" --prefix "$DSH_PREFIX" \
  --publication-preload runtime/ohos/publication/preload.mjs \
  --linked "$LINUX_PUBLICATION_LINKED_FIXTURE" \
  --simulation runtime/ohos/sim/preload.mjs \
  --marker runtime/ohos/sim/marker.mjs \
  --out /tmp/publication-scanners/report.json
```

脚本自行创建模式 0700 的 DSH_HOME 并清理自身夹具；不读写用户原数据。两个服务依赖必须来自该 prefix，而非临时手改导出。交付只新增两个测试及本文，产品代码、provider、pins 和 Android 输入不变。

源码审计没有运行 sharp 图像处理、SQLite 索引、ZIP 导出、迁移或删除全流程；这些路径仅有静态推导。动态插件、未安装平台包、其他版本、恶意同 UID 写入、错误配置根、系统掉电和 OHOS 真机仍不在本观察范围。created-before-identify 的未知身份残留仍按 34 保留为 UNRESOLVED；本补充说明其正常消费行为，不宣称已解决所有清理窗口。
