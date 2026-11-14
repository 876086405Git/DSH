# 1203 主 RAM 页退休的针对性宿主门

本门编译固定 TinyEMU、真实 Node N-API binding 和生产 `embed-ram.c`，验证真实 pthread join 之后才调用页丢弃。正式入口 `tooling/ohos/run-gates.py` 的 `tinyemu-ram-retirement` 会调用本脚本；本地仅跑该针对门：

```sh
python3 -I -B tooling/ohos/research/tinyemu-ram-retire/run.py \
  --source-archive /inputs/tinyemu-2019-12-21.tar.gz \
  --node-headers /inputs/node-v24.22.1/include/node \
  --cc /usr/bin/gcc --node /node/bin/node \
  --out /evidence/tinyemu-ram-retirement
```

归档 SHA256 为 `be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555`，Node 头与运行时为 24.22.1。输出目录必须不存在。默认从生产 build.py 新建宿主构建，运行 9 场景各 plain/jitless：正常 stop、HTIF poweroff、刚 create 即 stop、madvise EIO、disk.raw fclose EIO、超大 BIOS fatal、缺配置、pthread_join 失败和 async completion 取消。错误由 test-only linker wrapper 明确注入，不属于生产异常机制。`--built-native` 仅供作者对原基线对象做红对照，正式门不使用它。

monitor.c 仅在测试库链接。它识别 16 MiB 主 RAM 分配，在 VM 线程上用宿主写入逐页触及完整页，并以 mincore 量到触页后的驻留数。实际小 RISC-V BIOS 运行到串口标志/WFI 或 poweroff；Node 调真实产品 requestStop/join，随后再次 mincore。madvise wrapper 同时核实已经真实 join、地址、长度与 advice；只在这些条件正确时转给内核。错误返回不得冒充 0 页：两次 mincore 的成功状态均断言。测试还检查映射保留、两端边界字节、重复 join 不重复 advice、owner 永久隔离，以及失败不改变磁盘 apiResult/retirementError。

这是“宿主测试主动触页后的主 RAM 内部完整页”证据，不是 Linux guest 应用负载、OH SDK/HAP/设备测量或 App PSS。成功调用只证明 `advisedBytes` 范围被内核接受；实际驻留量另看 mincore，设备收益仍须按设备方法核实。32/64 位 CPU 低 RAM、设备/9P/slirp、配置和 owner 不在回收范围。原始 stdout/stderr、编译与执行命令、对象/输入 SHA、逐场景观测均在 report.json 所指路径保存。

控制层的独立回归 `runtime/tests/ohos/linux-ram-retirement.test.mjs` 已加入 `linux-app-control-plain/strict`。它使用既有真实 native flock 与 TCP 夹具，native/guest 返回值是明确替身；断言成功和 EIO 观测透传、unknown 的 null 保留、旧字段形状兼容、status 深拷贝，以及 clean 记录严格三字段和随后重新打开同一磁盘。第五项明确普通 switch-off 不 stop/join，off/on 继续复用同一 VM，最终 shutdown 才观察 RAM 退休。它不能替代本门的原生 join/页驻留证据。
