# P1A：Node 退出返回宿主，而不结束整个 App

基底 `c818155`，Node 固定 `runtime/ohos/node-version.json` 的 24.22.1。**Linux 真实 Node 已运行；OpenHarmony SDK、Ark 运行时与手机行为未在真机核实。** 本项只处理已有 runner 的嵌入生命周期，不改 `runtime/ohos/node/` 工具链、Android 输入或 DSH vendor 补丁。

## 问题与改动

原 runner 最后调用 `node::Start`。固定 Node 的默认 `process.exit` 处理器会调用 C 的 `exit()`。这会结束同一进程的 Flutter/Ark 宿主，不会给 Ark 返回一个退出码。锁定 DSH 的 `lib/bin.js` 在参数错误与 `StartupError` 中确实调用 `process.exit`，不是只有人为测试才能触发。

runner 改用 Node 的公开 C++ 嵌入 API：`InitializeOncePerProcess`、`MultiIsolatePlatform`、`CommonEnvironmentSetup`、`LoadEnvironment`、`SpinEventLoop`。`SetProcessExitHandler` 保存原始整数退出码并调用 `node::Stop`；随后在正常 C++ 清理路径返回给宿主。自然结束、异常结束、ESM 语法错误与显式退出分别保留实际 Node 结果；负退出码也不与内部“未退出”状态混淆。

`LoadEnvironment(env, StartExecutionCallback{})` 使用 Node 默认入口，不手写替代模块加载器。产品参数仍只有一个 `--import runtime/ohos/preload.mjs`，原 `--jitless`、非空 `NODE_OPTIONS` 拒绝、绝对入口验证均保留。linked publication binding 仍走既有、已固定版本的注册接缝；本项没有将它换成另一套 API。

Node 初始化不接管宿主的信号处理、stdio、资源上限、调试信号与大页设置。Environment 不取得操作整个进程状态的权限，不提供可变更 App 全局 cwd/uid/title 的默认拥有权。宿主应把实际工作区写进 Cordis `working-directory.defaultDirectory`、`sandbox-policy.workspaceRoot` 和 `ohos-subprocess.workspaceRoots`，不能靠修改整个 App 的 cwd 传递权限。

`dsh_node_start` 在参数验证成功后锁定为一进程一次：之后再次调用返回 64 与 `ERR_OHOS_HOST_ALREADY_STARTED`，包括首次启动失败或正常退出后。非法参数在 Node 初始化前拒绝，不消耗这一次机会。

新增 C ABI `int dsh_node_stop()`。返回 1 表示已接受对当前实例的停止请求，0 表示没有活跃实例。它调用公开的、允许跨线程使用的 `node::Stop`，不会发进程信号。互斥锁保护 Environment 指针直到调用完成；正在初始化时记住停止请求，建成 Environment 后执行。停止没有保证业务写入回滚或所有应用级异步清理完成，其语义近似 Worker 终止。退出后不能在当前 App 进程重新启动 Node，界面必须明确提示重新打开 App。

## Linux 验证与复现

`runtime/tests/ohos/host-embedded.py` 使用桌面 clang、固定官方 Node 头文件，把真实产品 runner 与 publication binding 编成测试 DSO。Linux/glibc 专用入口 shim 在真实 `std::thread` 中运行它；Node API 符号来自固定的官方 Node 可执行文件。它不是 `node::Start` 的替身。只有 deviceinfo 的四个系统函数使用既有、明确带 Linux Test 身份的夹具。

脚本覆盖自然退出、显式退出、负退出码、未捕获异常、ESM 语法错误、初始化失败、中文 stdout/stderr、jitless 无 wasm、真实 Worker、已有事件循环的停止、同步死循环的停止和初始化期停止。每个结果检查宿主 after 哨兵、保留的 SIGTERM handler、二次启动拒绝和结束后 stop 返回 0。可传 `--baseline` 指向原快照，独立重编前像并观察原显式退出/异常导致宿主 after 哨兵消失。

```sh
CXX=clang++-18 python3 runtime/tests/ohos/host-embedded.py \
  --node /固定Node目录/bin/node \
  --headers /固定Node目录/include/node \
  --out /不存在的新测试输出目录 \
  --baseline /原c818155源码目录

CXX=clang++-18 python3 runtime/tests/ohos/host-startup.py \
  --node-root /固定Node目录 \
  --dsh-prefix /已按锁文件安装且显式target-ohos打补丁的prefix \
  --out /另一测试输出目录
```

第二条是原有 34 项启动与预加载回归。各报告记录实际源码/二进制 SHA256、命令、退出码和输出；具体成绩随交付日志，不把历史 M6-4 的通过数移到新补丁。测试 DSO/shim、生成版本头、临时 JavaScript 和编译产物都不进入 HAP。

## 仍需核实

- Ark 与 Node 同名 `napi_*`/libuv 符号的隔离、本机 libc++ ABI、libnode 与原生 addon 的 HAP 加载：本项未解决，不能仅凭 Linux 结果启用设备启动。
- `process.abort()`、原生 abort、内存损坏和被系统杀死仍可能终止 App；此改动处理常规 Node 退出及公开停止，不是故障隔离容器。
- 停止时的真实 DSH 业务清理、应用后台冻结恢复、publication 持久账本重启恢复和设备资源行为须按对应模块与真机清单验证。
- 该入口必须保持库驻留到进程结束，不允许 Ark 生命周期结束时 `dlclose` 正在使用的 runner/libnode。

## 固定官方依据

- [Node 24.22.1 node.h](https://github.com/nodejs/node/blob/v24.22.1/src/node.h)：`SetProcessExitHandler` 默认退出行为、公开 `Stop`、ProcessInitializationFlags 和 EnvironmentFlags。
- [Node 24.22.1 embedding.md](https://github.com/nodejs/node/blob/v24.22.1/doc/api/embedding.md)：平台、Environment 及清理次序的公共合同。
- [Node 24.22.1 node.cc](https://github.com/nodejs/node/blob/v24.22.1/src/node.cc)：固定版本的初始化/清理与 `node::Start` 调用路径。

这些文件已从固定官方 tag 读取，来源 SHA256 单独随交付保存；没有拷贝其他鸿蒙移植项目的实现。
