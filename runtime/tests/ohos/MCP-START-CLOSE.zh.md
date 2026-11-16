# stdio MCP 启动前关闭的结算

OH 子进程门面在已主动 kill、且命令还未启动时保留既有合同：`exit/close`，不额外发 `spawn/error`。SDK 2.2.0 的 `StdioClientTransport.start()` 原来仅在 `spawn/error` 结算。因此主会话等待 Linux 单槽准入时，公开 `close()` 可以结束门面而留下未结算的启动 Promise；真实 MCP 插件的最终 dispose 又等待该连接尝试，因而也不结算。

`ohos-mcp-start-close.diff` 只在 SDK 的既有 `close` 回调中拒绝这次启动 Promise，错误码为 `CONNECTION_CLOSED`。ESM/CJS 各一行代码加注释。若 `spawn` 已经成功，或 `error` 已经拒绝，Promise 已结算，后续 close 不改变结果。没有增加状态、轮询或超时，也没有改变门面的 kill-before-start 事件合同。

`mcp-start-close.py` 是两个正式门的有限入口：

- 实际 Cordis MCP 插件正常 initialize、tools/list、同一真实 Python 进程两次 EOF 前 tools/call，然后卸载。
- auto-probe 后由另一个真实 routed job 占 Linux 单槽，主会话尚未 spawn 时调用实际插件 dispose，确认关闭结算、工具未注册且 initialize 为零。
- 相同交错分别走实际 ESM 与 CJS SDK，确认 connect 拒绝为 `CONNECTION_CLOSED`。

每种 Node 模式共四个案例。guest 协议两端是真实 TCP，MCP 回答来自真实 Python stdin/stdout；installation owner/native session/guest kernel 是明确夹具，没有启动 VM。`mcp-stdio-guest-fixture.mjs` 与 `mcp-stdio-server.py` 沿用已经验证的 1204 原字节；本独立 a836 补丁带入它们，以保证新门的输入闭合。

运行参数：`--source` 指向源码，`--prefix` 指向实际 OH patch 后的依赖，`--node` 为 Node 24.22.x，`--python` 为本机 Python，`--out` 为全新私有目录；`--jitless` 为第二模式。入口核对当前完整 OH final pins、声明输入前后身份、四个子进程的退出与断言结果。输出中的 `RUN.json` 是真实报告，不能只凭收到 `close` 就判成功。

原版反例中两个真实 Python 及路由资源最终都能退出，本修复处理的是启动/插件关闭 Promise 的悬空，不声称修复了进程泄漏。Cordis 对已卸载 fiber 的 await 结算也不是 MCP 连接成功；测试额外核对该主会话从未 initialize、没有注册工具。150 ms 是宿主观察窗，20 s 是测试子进程保护，不是产品新超时或设备时限。

正式登记仅执行上述四案例，不执行完整命令路由门、完整 guest、SDK/HAP 或设备测试。Node patch 版本只在记录中列出，准入不固定到 24.22.1。
