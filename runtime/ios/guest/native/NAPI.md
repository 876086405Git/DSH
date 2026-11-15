# iOS guest N-API owner (I2)

**未在 Apple 上编译 / 运行。** `DshGuestBridge.framework` 提供 Node-API 8 addon；
`DshGuest.framework` 持有唯一 iSH 内核。两者均随 App 嵌入、签名，不从数据目录加载原生代码。
本阶段交任务接口与生命周期，安装合同和真实批准后的 G1 路由分别由 I3、I4 接入。

## 加载与信任边界

可信宿主用 `process.dlopen(module, frameworks + '/DshGuestBridge.framework/DshGuestBridge')`
加载固定 framework 可执行文件，`module` 为 `{ exports: {} }`，然后使用 `module.exports`。
无 `.node` 后缀的 framework 不能交给普通 `require()` 猜测格式。
宿主必须在用户已安装 Linux 后才导入 guest JavaScript；仅加载 framework 不启动内核。

此 addon 是内部能力接口，不是批准验证器。G1 必须先取得现有工具批准票据，
再传入宿主认可的工作区和受控临时目录。`root`、`protectedPaths` 和 framework 路径由可信宿主提供，
不能采用工具或模型传来的值。root 是含 `data/`、`meta.db` 的安装容器，不能传 `data/` 本身。
宿主环境不自动继承。kernel 同时拒绝 guest mount/umount 和受保护目录交叠，
`readOnly` 决定 `/workspace` 的写能力，`/tmp` 是独立受控临时目录。

## JavaScript 合同

`start(request, callback)` 同步返回正 `BigInt` 任务 ID，随后在该 Environment 的循环发事件。
request 必须含：

| 字段 | 类型及含义 |
| --- | --- |
| `root` | 绝对路径，固定 fakefs 安装容器 |
| `protectedPaths` | 非空绝对路径字符串数组，完整的宿主保护集合；第一次初始化后不可缩减/替换 |
| `argv` | 非空字符串数组，不改写调用者脚本 |
| `env` | `KEY=value` 字符串数组，仅由 G1 白名单构造 |
| `cwd` | 规范化的 `/workspace` 或其子目录 |
| `workspace` | 批准的宿主工作区绝对路径 |
| `temporary` | 与工作区及保护目录不交叠的临时目录绝对路径 |
| `readOnly` | 必须显式提供的布尔值，匹配批准模式 |

路径拒绝 NUL，argv/env 总字节数和条目数有上限。callback 事件：

* `{type: 'started', id}`：原生任务已成功启动，才开始写 stdin。
* `{type: 'stdout' | 'stderr', id, end, data}`：`data` 是独立 Buffer，`end` 是该流的累计 BigInt 偏移。
* `{type: 'exit', id, exitCode, error, abandoned, resourcesSettled}`：终止结果。

`error` 是宿主 errno 数字，0 表示无桥接错误；它不是 guest 的 exitCode。
`resourcesSettled: false` 必须当作原生清理失败，不能宣称任务已完整回收。
每个流至多一个未确认块，每块不超过 65536 字节。
消费者只有在其输出消费 Promise 成功后才调用 `ack(id, stream, end)`，stream 为 stdout=1/stderr=2。
ACK 必须精确对应已交付块的 end；重复、提前或不同 Environment 的 ACK 被拒绝。
消费者失败应调用 `abandon(id)`，不能用 ACK 冒充成功消费。

`stdinWrite(id, Buffer)` 每次最多 65536 字节，返回实际写入数；处理短写，并在 EAGAIN 时让出循环后重试。
`stdinClose(id)` 关闭输入；可以在 started 前请求关闭。
`cancel(id)` 请求 TERM，200 毫秒后仍未退出则 KILL；`kill(id)` 立即请求 KILL。
`abandon(id)` 同时放弃剩余输出并取消任务。
这些方法非阻塞，不在 JS 循环等待 guest pthread。
同步错误带 `code = 'ERR_IOS_GUEST_NATIVE'` 和 `errno`；过期/跨 Environment ID 不可控制其他任务。
`status()` 返回 `{available: true, state: 'cold' | 'ready' | 'running' | 'quarantined'}`，
仅表示本 addon 的能力与内核状态，不等于镜像已安装。

## 一个内核与有界 Environment 收尾

一个 App 进程只有一个内核；成功任务顺序复用。单个 Environment 至多拥有一个任务，
底层同时 start 返回 EBUSY；G1 应在其宿主 provider 队列串行任务，不创建第二个内核。
正常任务没有总时长上限。取消或放弃后，独立 native coordinator 等待收尾最多 2 秒；
如未成功，内核永久隔离直到 App 重启，保留其仍可能借用的原生上下文。

Environment cleanup 不 join、不等 ACK、不等 guest：在同一互斥锁下关闭投递并唤醒等待者，
删除本循环上的 JS 引用，关闭 uv_async 后移除 async cleanup hook。
native 线程只持独立引用计数 Owner，不调用已关闭的 Env。输出块用共享所有权，避免队列保留裸指针。
原生线程可能晚于 Node Worker 析构；addon 使用自身代码地址解析已加载映像，
以 RTLD_NOLOAD 额外保留一次 dlopen 引用，避免 Worker dlclose 后仍执行已卸载代码。
该引用进程结束前不释放；不接受路径参数，不加载新映像。

## 已运行的验证与边界

Linux 上用固定 Node 24.22.1、真实 N-API/libuv、原生多线程 fixture 运行十项：
同步/异步 ACK、短写 stdin、started 取消、消费回调抛错、exit 重入启动、跨 Worker 控制拒绝、
欠 ACK 时 terminate、启动中的 terminate、原生延迟 3 秒退出时 terminate。
作者测得三个 terminate 分别约 2.43、2.33、3.68 毫秒，独立复核亦通过；
它们只证明该 Linux 环境的结果，不是 Apple 时延承诺。
复核另测 started/stdout/exit 回调中的 `process.exit(0)`。

真实 iSH C 后端另在 ARM64 Linux/QEMU 执行七个任务，验证 rootfs、工作区读写、退出码、stdin、
长于 cleanup 窗口的正常任务、TERM→KILL、输出放弃、SIGPIPE、只读工作区与可写 tmp。
这些与 Node fixture 分开，尚不是 Apple N-API+iSH 联合执行或真实批准链端到端。
Apple CI 必须补编译、加载和动态运行；保留未验证标记，不能把 Linux PASS 改写成 iPhone PASS。
