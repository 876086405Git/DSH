# M3-2：临时进程内锁与固定 Node 的 close 契约

基底 `c0949d6`，固定 Node `24.22.1`。本子项仅新增回归测试和前提说明，不修改发布回退、生产锁函数或 Android 路径。

## 正确性前提

**一个应用只有一个主 Node 实例。** 会话存储及临时锁表只在这个实例的主 Node 线程运行；同一文件通过不同路径打开时，以实际打开文件的 `dev/ino` 区分。已有 `tryLockOhos` 在 worker 中直接拒绝，不能让 worker 各持一张互不相见的锁表。O4 的命令 worker 不因此获得管理会话锁的权限。

这不是跨 Node 实例、跨进程或跨应用锁。若将来允许多个主 Node 实例或多个进程共同打开会话库，必须先改用已经完成设备验证的原生文件锁；不能以本测试通过支持那种部署。宿主的单次初始化约束仍须由 O7 实现和真机验证，本测试没有替代它。

当前实现保存 `handle.close`，再给这一实例安装关闭后释放锁的包装；它会不带接收者调用保存的函数。其前提是固定 Node 的 `FileHandle.close` 为每个实例自己的、可写的已绑定方法，且返回的 Promise 在文件描述符实际关闭后完成。这个实例属性形状并非本项目可以替上游保证的稳定 API，因此必须保留版本与行为双重检查。

## 新增的实测门槛

`runtime/tests/ohos/lock-node-contract.test.mjs` 在分配临时文件或载入 provider 前，先断言 `process.version === 'v24.22.1'`。换成任何其他版本，测试会明确失败，要求重新核实，不能只修改版本字符串绕过复核。版本断言本身是源码中的显式门槛；本次未安装另一个 Node 来冒充升级测试。

同一测试还使用三个真实 `FileHandle`，检查实例属性、提取原始 close 后的绑定、返回 Promise、关闭正确的文件描述符、实际 provider 的竞争/关闭/后继获取，以及 `Symbol.asyncDispose` 是否仍经过实例方法。它没有全局改写 fs 或模拟一个假的 FileHandle。provider 仅经已有测试辅助器临时追加导出，原安装文件字节不变。

已有 `publication-locks.test.mjs` 中的异步关闭等待、close 报错、stat 与 close 交错、文件身份替换、fd 重用及 worker 拒绝测试继续保留。新增测试不是对这些已过用例重新计数。

## 复现

先用新基底的锁文件和 pins 准备独立 DSH 前缀，然后使用固定官方 Node：

```sh
DSH_TEST_PREFIX=/absolute/patched-prefix /Node24.22.1/bin/node --test --test-isolation=none \
  runtime/tests/ohos/lock-node-contract.test.mjs

DSH_TEST_PREFIX=/absolute/patched-prefix \
DSH_GO_OHOS_SIM_PLATFORM=openharmony \
LD_PRELOAD=/absolute/publication-linux/libpublication-test-linked.so /Node24.22.1/bin/node \
  --jitless --import ./runtime/ohos/sim/preload.mjs \
  --import ./runtime/ohos/publication/preload.mjs --test --test-isolation=none \
  runtime/tests/ohos/lock-node-contract.test.mjs \
  runtime/tests/ohos/publication-locks.test.mjs \
  runtime/tests/ohos/publication-integration.test.mjs
```

自 M3-1 起，OHOS 路径的两个 provider 通过发布服务提交，第二条命令需要 `runtime/ohos/publication/preload.mjs` 与 linked 测试库（`bash runtime/tests/ohos/build-publication-native.sh <Node24.22.1目录> <输出目录>` 生成）；缺任一项时 provider 抛 `ERR_OHOS_PUBLICATION_PRELOAD_MISSING` 或预加载报 binding 缺失。前缀须用 `--target ohos` 打补丁。

依据为新基底 `zzzzzzz-ohos-session-publication.diff` 的 `tryLockOhos`、同版真实 `FileHandle` 的本地运行，以及上述原 provider 测试。结果与精确补丁哈希写在交付复核报告中。OHOS 上文件身份、原生 flock、SDK/HAP 加载和冻结行为仍需设备证据；本项不把 Linux 仿真当成这些结论。
