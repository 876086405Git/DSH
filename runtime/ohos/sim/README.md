# O0 真实引擎回合测量

基底 afb5cdd；Node **24.22.1**；锁定 DSH **0.2.1-rc.4**。只在 Linux 上模拟约束，不证明鸿蒙系统或 ARM ABI 行为。

## M3-3 仿真入口迁移（基底 c0949d6）

`DSH_GO_OHOS_SIM=1` 不再启用任何生产分支或仿真限制。调用方必须明确预加载：

- `--import runtime/ohos/sim/marker.mjs` 只在当前 JavaScript isolate 设置 `globalThis[Symbol.for('dsh.go.ohos.sim')] = true`，用于保留 JIT 的网络、虚拟进程对照。
- `--jitless --import runtime/ohos/sim/preload.mjs` 设置同一标记并施加完整 O0 限制。`run.sh` 使用这个入口；`round.mjs --mode sim` 也明确加载它，不再写入旧开关。

`DSH_GO_OHOS_SIM_PLATFORM` 和 `DSH_GO_OHOS_SIM_ADDONS` 仍是完整预加载器的测试配置：前者选择是否模拟 `openharmony` 平台，后者给出原生插件绝对路径白名单。仅设置这些环境变量不会装入预加载器。普通 Android 的网络模块只判断平台和已经由测试预加载器设立的布尔标记。

Worker 的全局对象不共享标记。Node 24.22.1 的真实 Worker 测试验证了默认继承 `--import` 时会在新 isolate 再次运行预加载，既保留 marker-only 的 JIT 对照，也传播完整 O0 限制。自行覆写 Worker 的 `execArgv` 时必须明确保留测试预加载；环境变量不能替代它。此工具用于测试约束，不是安全沙箱。

运行 `node --test runtime/tests/ohos/sim.test.mjs` 可验证这组迁移；M3-3 实测 10/10、0 skip/TODO。网络门控及旧环境变量负对照见 `../net/M3-3.md`。本段不改变下文 O0b 同一剧本的工具与协议验收条件。

## 一条命令

在仓库根目录，先应用 O0a 的预加载器补丁及本 O0b 补丁，然后运行：

```bash
NODE=/path/to/node-v24.22.1/bin/node bash runtime/ohos/sim/measure.sh /tmp/ohos-round-new
```

输出目录必须不存在。脚本用项目锁文件 `npm ci --ignore-scripts`，应用当前 `runtime/patches/pins.json` 全部补丁，然后依次运行 JIT、jitless、严格仿真。需要 Node 旁边的 npm、Python3、可访问锁文件所指 npm 源；没有新运行时依赖。可以用 `DSH_OHOS_PREFIX=/already-prepared/prefix` 跳过安装；这时调用方必须确保依赖和 pins 已完整应用。每个 case 的 DSH_HOME、工作区、启动 token、端口互相隔离。

为了逐项定位故障，驱动器支持 `--expose-internals`、多次 `--import /preload.mjs` 与 `--patch /overlay.yml`。例如 O1 loader 修复需要前者；O5 网络 preload 用第二项。所有附加选项都记录在复现命令里；不能把改了配置的数字与原基线混称同一条件。仿真默认加平台覆写，单独调用 round.mjs 可以不覆写。测量父进程不加载仿真限制，只有真实 DSH 子进程受限，便于监控、保存日志和结束它。

## 实际协议与成功条件

依据 `packages/dsh_client/lib/src/{connection,carrier,mux,session_api}.dart`：GET 启动 token 换 dsh-auth Cookie；HTTP `client-request` / `server-response` 调用 session/create 与 session/prompt；WebSocket `/api/remote.mux` 订阅 `$events` 及 session/follow；收到 approval/request 后通过 `$events/result` 回复 allowed-once。

假模型通过本地 OpenAI Chat Completions SSE，分片返回工具参数。真实引擎必须依次执行 **write、edit、read、grep、bash**，经历审批并产生正常 turn/end。断言五个 tool/result 均成功，读取与搜索结果含修改后中文文本、bash 结果含固定标记、最终文件字节完全匹配。只看到模型工具调用不算成功。凭据仅为固定本地夹具字符串，子进程环境不继承用户密钥；所有服务仅监听 127.0.0.1。

## 输出与测量口径

每个 case 有 `report.json`、已脱敏 `engine.log`、临时测试工作区和 DSH_HOME。报告保存实际事件序列、模型步骤、审批数及失败，不只记录退出码。`urlReadyMs` 为启动子进程至 CLI URL 可见，`hostReadyMs` 为再到真实 App 事件通道 ready；`firstRoundMs` 为提交 prompt 至 turn/end，均用父进程单调时钟。失败回合的耗时不能当成功首轮耗时。

这里的“冷启动”仅表示全新 Node 进程及全新 DSH_HOME，**没有清理操作系统页缓存**。首次单样本是功能定位证据，不是性能分布，也不是手机预测。O2 将另做固定条件多次测量。

JIT 正常、jitless 或严格仿真失败是 O0 允许且必须保留的诊断结果；measure.sh 有任一失败就返回 1，仍执行剩余模式。无兼容补丁时的 dlopen / wasm / flock / spawn 等阻断正是后续任务输入，不允许通过给原生模块放宽白名单或恢复 child_process 来伪造通过。

## 范围

仿真仅覆盖预加载器明确拦截的公开 Node 入口，不构成安全隔离；内核权限、签名分发、实际后台冻结和 Native SDK 均须真机确认。日志中的源码行号对应锁定 npm 模块和具体 pins 状态。附带历史失败清单明确区分夹具错误、引擎兼容问题和未运行情形。
