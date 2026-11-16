# 1217：embedded RISC-V 最后等待边界的微秒精度

本补丁以 a836880 为基底，**包括 1208 v2 的 0018 unsigned CLINT 前置补丁及原门**。
新增 0019 只修改 TinyEMU 的 `machine.h`、`riscv_machine.c`、`temu.c`，不扩大等待上限。
不应把这些文件的整份后像覆盖到另有 0017 RAM 退休的树；应按顺序应用补丁，保留已有改动。

## 原因与行为

RTC 为 10 MHz，旧 `remaining / 10000` 把仍在未来的不足 1 ms 截止时间取成 0。
1215 的固定真实 Linux 观测已捕获 WFI、mip=0、timecmp>now 的此类忙转；本门另以明确时钟夹具
重现 8889 ticks → 0 µs 的真实 `virt_machine_run` 反例。0019 在 embedded RISC-V 最后一次
select 预算计算用 `remaining / 10`，该例变成 888 µs，仍为下取整。

只有 `TEMU_EMBED` 且实际 `m->vmc == &riscv_machine_class` 才走新分支：先给 slirp/fs
原单位的 10 ms 预算，待它们填写 fd 集合、缩小预算之后，再以微秒精度按 CPU 截止时间截断。
不能先把 CPU 预算取成毫秒 0，再与微秒值求最小值。最终 timeval 用 `/1000000` 与 `%1000000`。
既有 10 ms 最大请求保留；不是宿主线程墙钟返回、stop/join 或客体中断响应的硬时限。
请求精度提高也不表示实际定时语义完全不变：旧尾段忙等可以更贴近截止点，阻塞 select 则可能
受宿主调度晚醒影响。CPU 收益须与实际 timer lateness 一起审视，不能只报告忙转减少。
不足 1 µs 仍可以取成 0，已到期和非 WFI 也保持零等待，因此不以“所有零 select 消失”为目标。

共用的内部 helper 保留 0018 的 uint64 先比较：到期才置 MTIP，未来分支才计算差值，
缩窄成 int 前先与正 cap 比较。已 pending 但被屏蔽的 MTIP 可以仍处于 WFI；此时不读 clock，
保留传入 cap，不能不分情况强制零等待。旧毫秒 API、VirtMachineClass 布局保持不变。
其他 class 仍先调原毫秒方法；jsemu.c 没有改动且继续使用该方法。没有改变 slirp timer、
fs 网络逻辑、停止标志、fd 所有权、最大解释器批次或资源生命周期。

固定上游没有 CONFIG_RISCV 宏：普通 Makefile 无条件编 RISC-V，CONFIG_X86EMU 是追加 PC；
非 EMSCRIPTEN 的 machine.c 类表始终包含 RISC-V。产品 build.py 同样固定编 RISC-V，定义的是
CONFIG_RISCV_MAX_XLEN=64。Makefile.js 使用 jsemu.c 而非 temu.c，不定义 TEMU_EMBED。
因此没有添加会把当前产品分支错误关闭的 CONFIG_RISCV 守卫，也不为未提供的新构建组合扩展接口。

## 有限正式入口

```sh
python3 -I -B tooling/ohos/research/tinyemu-sleep-micros/run.py \
  --source-archive /inputs/tinyemu-2019-12-21.tar.gz \
  --node-headers /inputs/node-v24.22.1/include/node \
  --cc /usr/bin/gcc --out /evidence/sleep-micros
```

归档 SHA256 为 `be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555`；
正式 run-gates 的 `tinyemu-sleep-micros` 默认新鲜编译，输出目录必须不存在。
`--built-native --native-include` 仅给作者明确的复用/红对照，报告标明 reusedNative，不能冒充 fresh。
没有为此准备或运行整套门矩阵。

`sleep-boundary.c` 包含既有 clock-cpu.c，使用实际 RV32/RV64 CPU 指令进入 WFI，真实 timer 状态
和真实 `virt_machine_run`；clock/select/net 是显式夹具。在等待之后的解释器批次用 CPU class
的副本仅替换 interp 方法，隔离本次等待边界，其余 CPU 方法保持真实，随后恢复原 class。
这不证明真实系统按请求时间唤醒，也不是 slirp/9p 集成测试。

覆盖 52 项 µs/select/MTIP/fd/network 预算边界、旧毫秒 API 14 项、其他 class 分派 3 项、
既有 clock 13 项、低字写 1 项、1208 unsigned 边界 14 项。另实际把 temu.c 和夹具编成非 embed
版本，执行旧毫秒 API 14 项及其他 class 3 项，确保它不依赖 embedded-only µs 符号。
没有执行 x86 客体或 Emscripten 浏览器；这些路径的结论限于共享接口/编译守卫的源级范围。

## 性能与设备界限

修复前后真实 Linux 对照由独立测量包保存相同内核、fresh 原始盘、observer、完整命令和 SHA。
宿主 VM 线程 CPU 数值包含测量环境影响，不能归给手机某个 CPU/PSS bucket；无设备收益百分比。
本件没有扩大成 1211 长等待方案，slirp deadline/时钟回卷、可取消 waker 与 Worker 退出问题仍另列。
