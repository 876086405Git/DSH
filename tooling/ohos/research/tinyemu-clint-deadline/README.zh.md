# 1208 CLINT unsigned deadline 的针对性门

RISC-V 机器级规范的 [Machine Timer](https://docs.riscv.org/reference/isa/priv/machine.html) 节要求按无符号的 mtime >= mtimecmp 判断 MTIP。旧固定 TinyEMU 将 `mtimecmp - mtime` 存入 int64_t，误把一部分极远未来值判断为到期；0018 先做 unsigned 比较，只在未来分支计算非溢出的无符号剩余量。没有更改10ms最大等待、时钟源、毫秒取整、CPU中断使能或设备/资源生命周期。

```sh
python3 -I -B tooling/ohos/research/tinyemu-clint-deadline/run.py \
  --source-archive /inputs/tinyemu-2019-12-21.tar.gz \
  --node-headers /inputs/node-v24.22.1/include/node \
  --cc /usr/bin/gcc --node /node/bin/node \
  --out /evidence/clint-deadline
```

归档 SHA256：`be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555`，Node 24.22.1。输出目录须不存在。正式 run-gates 的 `tinyemu-clint-deadline` 调用默认新鲜编译；`--built-native` 仅用于作者加载原基线对象做红对照，正式门不使用。

`timer-boundary.c` 直接包含既有 clock-cpu.c 夹具所编译的真实 RISC-V machine/CPU。明确注入单调时钟，实际执行启用 MTIE 与 WFI 的指令，逐项核 UINT64_MAX/高bit未来、近未来、等于/晚于截止、低32位回卷前后，共 RV32/RV64 14项。再执行既有13项clock回归与低字写1项。该夹具不用真实等待，不可当作设备计时测量。

另一条路径从真实生产对象重链接测试 select observer，以真实 Node N-API 创建VM线程。小 RISC-V BIOS 用真实指令写 UINT64_MAX 到 CLINT、启用 MTIE、循环 WFI；约600ms观察窗口记录 select 进入/返回/零等待数量、请求的等待总量和 VM线程 CPU 时钟。plain 与 jitless 都实际 requestStop/join。测试新增的导出观测方法与链接wrapper不进入生产库。Node这条路径使用真实时钟，仍是明确的小 BIOS，没有 Linux内核、应用任务或设备。

CPU时钟在 VM select 边界采样，前后边界与 Node窗口有最多一个运行片段的偏差，因此保留原数值，不把比值包装成精确设备CPU百分比。修复后的这个远未来 WFI 仍沿既有10ms等待；不能把“零等待忙转消失”写成“所有空闲轮询消失”。普通Linux off/on继续复用VM；1203最终join后的RAM页退休与运行中的deadline问题分开。
