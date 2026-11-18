# M3-1c：从已完成临时文件执行 EINVAL 独占复制的评估

## 结论与建议

**可以少读一遍原始源文件，但这条修改没有减少旧 30 号 core 的总 payload 读取字节数，也没有消除回退留下部分 final 的风险。** 本次用真实 FileHandle 读写计数证明：稳定内容大小为 N 时，30 号基线读取原 source 2N；候选读取原 source N，再读取已完成 temp N。这里的“总读 2N、总写 2N”仅指这三个旧 core 实验副本复制正文时的 `FileHandle.read` / `writeFile` 调用字节，不是整个 App 或 34 号 ledger 版本的总 I/O。

临时文件作为第二次复制的输入有一个明确收益：发布内容与已经完成并 fsync 的暂存版本一致，不必重新打开一个可能改变或消失的 source。这个收益是本次实际验证的行为变化，不能改称速度提升。只把 `source` 实参换成临时路径有可达错误：路径在 `await onFallback` 期间被替换后，会把外来文件内容写入 final，直到后续 cleanup 才报错。

本次保留一个很小的隔离候选：用 O_NOFOLLOW 重新打开 temp，持有该 fd，fstat 核对原 receipt 的 dev/ino 和常规文件类型，在核对成功后才以 `wx` 创建 final。它在本次路径替换与 symlink 反例中均先拒绝、未创建 final。它仍不能阻止同一 inode 的内容被协作模型以外的代码原地改写，也不是原子 compare-and-unlink 的实现。

**建议不把它以“减半 I/O”或已证性能优化合入正在冻结的 M3-1b。** 如后续要减少对原始 source 的第二次访问，可把带身份核对的候选作为独立的小修；需要对 M3-1b 的 marker/账本版 core 重新接线、复跑并独审，不能直接套用本报告对 30 号旧 core 的结论。本轮只交评估、可复现实验与边界，不修改任何生产发布协议、provider、pins 或依赖。

## 固定输入和实验方式

实验基线是已审 30 号 `runtime/ohos/publication/atomic.mjs`，SHA-256：

`c774041d8174cd495bfcb4e2deda2dc3f5eb8100ffcb5557ceae2a107d7f78cc`

`build-variants.py` 先核对这个 SHA，随后只在输出目录生成三份实验模块：

| 模块 | 相对基线的变化 | 实验模块 SHA-256 |
|---|---|---|
| baseline | 原字节复制 | `c774041d8174cd495bfcb4e2deda2dc3f5eb8100ffcb5557ceae2a107d7f78cc` |
| naive | 第二次复制只将 source 实参换成 receipt.path | `bfe1331081d46d107c09be4b41cfcef72e925f59c7898739cfd39cd759a11dc3` |
| guarded | 新增 O_NOFOLLOW 打开和 fstat 核对，之后从同一个打开的 fd 复制 | `c27799029727563ecbf252bc23ad95c2769139ffbadb4cd8ab2b88bcb40fc077` |

基线的原 temp 是 `open('wx')`，仅写 fd；本候选保留这个条件，没有把生产临时文件改成 `wx+`。再次打开后才读 temp，避免用不可读的 fd 冒充复用成功。

另一个可以考虑的方向是创建时就保留可读的原 fd，并用显式 offset 从零读取它，避免再次通过路径打开。但这需要改变打开模式、核对写完后的读取位置和完整收尾时序，并重新进行取消/SIGKILL/重启试验。本轮没有实现或验证这个方向，不能据此宣称它更安全、更快或更省 I/O。

固定 Node 为官方 Linux x64 24.22.1，二进制 SHA-256 `e32e2d16081cf644f88392934288086e7662529d0d43277c34f7aad2207cfafb`。每个用例新建自己拥有的真实临时目录，真实执行 FileHandle.open/read/writeFile/sync/close；包裹方法只在真实调用成功后累计字节数，不用内存文件系统替代磁盘文件。

为了准确走到待研究分支，实验明确注入 `link→EACCES` 和 `renameNoReplace→EINVAL/syscall=renameat2`。这是分支选择，不是声称本机 renameat2 实际不支持。其余错误门控也用明确注入的返回值单列。测试外的 fixture 准备、故意改写和读回断言不计入发布算法的 I/O 计数。

计数还明确排除目录项、open/stat、xattr 等 metadata I/O、cache 和物理块读写。三个副本没有运行 34 号新增的持久 ledger，因而也没有统计账本 JSON 的读写或原子替换。open/close/sync 的调用次数只单列记录，不被换算成 payload 字节；任何完整 App/34 号性能评价都需要另测。

普通 JIT 与完整严格 O0 各实跑 34/34、零失败、零跳过、零 TODO。严格组使用已审 M3-3 preload，并在测试中逐项断言进程内 marker、无 WebAssembly、spawn/link/dlopen 拒绝；并非只使用 `--jitless`。所有实际打开的发布句柄在每次 publish 完成后为零，pending 队列也为零。

## 旧 30 号复制 payload 的真实稳定文件计数

样本 N = 262,267 字节，64 KiB 分块。两个模式得到相同逻辑计数：

| 项目 | baseline | naive | guarded |
|---|---:|---:|---:|
| 原 source 打开次数 | 2 | 1 | 1 |
| 原 source 读取字节 | 524,534 | 262,267 | 262,267 |
| temp 读取字节 | 0 | 262,267 | 262,267 |
| payload 总读取字节 | 524,534 | 524,534 | 524,534 |
| temp 写入字节 | 262,267 | 262,267 | 262,267 |
| final 写入字节 | 262,267 | 262,267 | 262,267 |
| payload 总写入字节 | 524,534 | 524,534 | 524,534 |
| 文件 sync 次数 | 2 | 2 | 2 |

每次完整读取是五次非空 read 加一次 EOF read。因此基线 source 一共 12 次 read；候选 source 六次、temp 六次，总 read 调用数也未减少。候选的 temp 打开次数为二：原始仅写打开加一次只读打开；基线 temp 只打开一次。

这不是块设备 I/O、缓存未命中、物理写放大、CPU 或耗时的测量。没有清缓存、没有目标设备，也没有把测试总耗时拿来做性能排名。可能的缓存局部性、远程 source、跨挂载 source 成本等仍需对应真实工作负载的测量，不能从本表推出。

## 内容变化与错误路径

每一行均在三个副本上真实运行；门控错误另对 baseline 与 guarded 各跑五项，共 34 项。

| 情形 | baseline | naive | guarded |
|---|---|---|---|
| 暂存后原 source 改变 | 发布改变后的 source | 发布已暂存内容 | 发布已暂存内容 |
| 暂存后原 source 删除 | ENOENT，final 不存在 | 发布已暂存内容 | 发布已暂存内容 |
| 暂存路径改名，原位放外来普通文件 | 发布原 source 后，cleanup 因替换报错 | **先把外来内容写入 final**，随后 cleanup 报错 | 核对失败，final 尚未创建 |
| 暂存路径替换为 symlink | 发布原 source 后，cleanup 报错 | **跟随 symlink 发布外来内容**，随后 cleanup 报错 | 打开返回 ELOOP，final 尚未创建 |
| temp 同 inode 原地改写 | 发布原 source | 发布改写内容 | 也发布改写内容：身份核对不保证内容不变 |
| final 首个真实写入完成后取消 | 留下 65,536 字节部分 final | 同样留下部分 final | 同样留下部分 final |
| final 预先存在 | EEXIST，原字节不变 | 同左 | 同左 |

路径替换测试将原 temp 改名到测试私有的 saved 路径，原 output fd 仍打开，因而没有依赖 inode 被快速复用来制造结果。外来替换内容在 cleanup 后仍保留，未被按名称删掉。symlink 测试也检查其目标内容未改。

同 inode 改写用例专门确认改写前后 dev/ino 与 receipt 一致。它是对候选限制的实际反例：持有 fd 和核对身份只约束“读的是哪个打开的文件对象”，不能为正文建立不可变快照。M3-1b 新 marker 也不是正文校验值；本实验没有声称其能抵御同 UID 的任意伪造或原地修改。

取消用例在第一次 final.writeFile 已实际完成后才触发 AbortSignal，避免把尚未开始写的取消误报为中途取消。三个版本都拒绝为原 reason，关闭句柄并清理 temp，但留下已经写出的 64 KiB final。用户已明确接受并单列的 EINVAL 回退风险没有因读入路径改变而消失。

`EACCES/renameat2`、`EXDEV/renameat2`、`ENOSYS/renameat2`、`EIO/renameat2` 和 `EINVAL/open` 在 baseline、guarded 中均不会调用 onFallback，不创建 final，原错误码保留。没有把普通 EINVAL 或其他 errno 扩大成许可回退。

## 复跑与产物

生成脚本和测试是本次新增、可读的实验源码；三份变体只存在构建输出/证据目录，不作为生产源码提交。补丁只添加本文和 `runtime/tests/ohos/publication-fallback-evaluation/` 下的两个实验脚本。`EVALUATION_SCRIPTS` 指向该脚本目录，`EVALUATION_OUT` 指向自己可写的实验输出目录。用已保存的 30 号原 core（M3-1b 之后的树里取 `git show 8238b75:runtime/ohos/publication/atomic.mjs`） 执行：

```sh
mkdir -p "$EVALUATION_OUT/evidence"
python3 "$EVALUATION_SCRIPTS/build-variants.py" "$BASELINE_ATOMIC" "$EVALUATION_OUT/build"
DSH_TEST_M3C_VARIANTS="$EVALUATION_OUT/build" \
  DSH_TEST_M3C_RESULTS="$EVALUATION_OUT/evidence/M3c-io-jit.json" \
  "$NODE24_ROOT/bin/node" --test "$EVALUATION_SCRIPTS/fallback-io.test.mjs"
DSH_TEST_M3C_STRICT=1 DSH_GO_OHOS_SIM_PLATFORM=openharmony DSH_GO_OHOS_SIM_ADDONS='[]' \
  DSH_TEST_M3C_VARIANTS="$EVALUATION_OUT/build" \
  DSH_TEST_M3C_RESULTS="$EVALUATION_OUT/evidence/M3c-io-strict.json" \
  "$NODE24_ROOT/bin/node" --jitless --import "$M3_MARKER_PRELOAD" \
  --test "$EVALUATION_SCRIPTS/fallback-io.test.mjs"
```

manifest 记录源码、测试、Node、严格预加载器及逐用例 JSON/日志的 SHA-256。JSON 的 counters 区分 source/temporary/final；结果同时保留完整 execArgv、注入的门控、实际 final 字节数与哈希。没有附第三方源码或 tarball。

本报告为 **EVALUATED，生产修改未做；独立复核 PASS_SCOPED，只覆盖评估与实验源码，不批准生产修改**（报告 SHA256 `f1e668e9ddecb4d56a58cc65e20260077207e8913a19301a4b0369dad1f6e847`）。目标 OHOS 文件系统、权限、ABI 和真实 source 工作负载均 NOT_RUN；SIGKILL、断电、M3-1b ledger/marker 的集成由相应独立包验证，不借这 34 项代替。
