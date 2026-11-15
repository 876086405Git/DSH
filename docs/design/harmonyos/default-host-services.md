# 默认宿主装配 O6 与 O8

基底 fd2890cf9ae5ee2bb4faead2fbbf3689a4a29b92。此补丁只补默认宿主遗漏的两个服务，不重复包含 P2 v6 或 O8 实现。

## 问题和改动

默认 HostCore 只注册虚拟进程和 sandbox。文件存在不等于 Cordis 已装配服务：O8 的日志/恢复入口和 O6 的能力 HTTP 路由都必须显式插入 profile。

现在 Start 在消耗进程唯一启动机会之前检查两项入口文件；Run 把 `ohos-lifecycle` 与 `ohos-capabilities` 注册为安装树中的绝对路径。仍只有一个 --import，不增加新入口或环境变量，不把能力查询当作恢复动作。

## 组合前提

- P2 v6（26号）的 guestRoot/布局及真实 Host profile 驱动；本补丁的两个 C++ 小 hunk 可在纯 fd 普通 apply，并可叠加 P2 v6。
- O8 v2（28号）的模块和仅 OH engine pins。O6 已在 fd 基底。
- 最终 O2 运行包必须包含 runtime/ohos/lifecycle 的五个 .mjs。旧21组成漏复制此目录，后续组成包单独修；不能只加profile后仍发旧运行包。
- 不修改 N-API/runner 链接边界、CMake、node/或 Android。

## 验证与边界

`CXX=clang++-18 python runtime/tests/ohos/host-lifecycle-profile.py --out <新目录>` 实际编译生产 HostCore，验证两个服务恰好注册一次、唯一 import、任一入口缺失时不进入runner。这个回调仅记录参数，不能称为真实引擎。原实现0/3，修后3/3。

原 host-core.py 全部30项需完整运行。真实引擎使用 P2 v6 的 host-layout.py（新私有home/workspace）与 O8 的 lifecycle-round-fixture.mjs；保留原五工具、两审批断言，追加真实鉴权/生命周期/O6查询。测试运行器的本地HTTP/WS需允许127.0.0.1。

早期诊断回合故意保留：默认 O8 路由401而能力路由404；补注册后完整 HTTP 控制和 O6 reconcile→none 通过。重用工作区的另一轮触发 FS_NOT_OBSERVED，必须另用全新guest目录重跑，不能放宽真实文件观察保护。

此改动没有连接 Ark 的前后台通知，不宣称后台计算授权、目标 ABI、断电或设备生命周期通过。日志路径沿 O8 默认 DSH_HOME/ohos-lifecycle，不进入工具工作区。
