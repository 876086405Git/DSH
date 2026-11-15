# O4：外层 shell 语句分段输出

本补丁基于 `c818155`，固定 Node `24.22.1`、DSH `0.2.1-rc.4`、just-bash `3.6.0`（Apache-2.0）。交付的是外层语句完成后的分段输出：`printf first; sleep 0.4; printf last` 的 `first` 会在 sleep 结束前到达调用方。stdin 仍为批量输入，没有 PTY。目标 SDK、OpenHarmony Worker 和设备行为待真机核实。

## 输出边界

| 形态 | 本补丁的交付时机 |
| --- | --- |
| `echo a; sleep 1; echo b` | 第一个外层语句完成后交付 `a`，随后执行 sleep，最后交付 `b`。 |
| `a && b`、`a \| b` | 整个外层语句完成后交付；保留条件链与管道的现有内部结果路由。 |
| `for` / `while`、函数调用、花括号组、source/eval、嵌套 shell | 整个外层复合语句完成后交付；内部仍缓冲。 |
| `value=$(...)`、`> file`、`2>&1`、持续 fd | 捕获与重定向完成后，只交付实际应到达调用方 stdout/stderr 的结果。 |
| 已观察到前缀后取消 | 原 Worker terminate / exit 屏障保留；已经交付的前缀保留，未交付的复合语句内部输出可能丢失。已经完成的文件写入保留。 |
| 二进制及中文 | stdout 按现有 typed-output 标记分别用 Latin-1 字节或 UTF-8 编码；后继 [Node Worker v2](O4-Node-Worker.md) 为 stderr 补上独立 bytes 类型与路由，避免脚本的非 UTF-8 错误输出被解码损坏。每个语句保持自己的字节形态。 |

`streamingOutput: true` 在本后端中的含义就是上表的外层语句粒度。该字段来自执行器同一份 `commands.mjs`，OHOS 工具说明依据它显示精确边界。O6 的 v1 数据模型没有额外扩展流式字段；其命令清单仍读取同一个实际后端。`nodeScripts` 仍为 `none`（由独立 O6 补丁声明），未将 node 命令加入执行清单。

原 OutputCollector 的 `readFrom` 是字节偏移协议，仍按收到的字节窗口转换 UTF-8；若调用方恰好在不完整 UTF-8 字节处切分读取，会沿原协议看到替换字符。本项验证原始管道字节和最终完整窗口拼接正确，没有改变此既有解码契约。

## 实现和成立条件

Worker 仍只把固定 `bash` 或 `sh` 字面命令及独立 `args` 传给解释器。用户脚本不拼接进外层命令，位置参数不会再次插值。私有 sink 要求这一固定入口，带额外外层重定向的入口被拒绝。

固定 bundle 的 `Bash.execInScope` 只在第一个 child exec 上把 sink 传给 `Interpreter.executeScript`。这是实际 bash/sh 命令调用用户脚本的位置。其后的脚本调用与解释器内部的 `executeScript` 调用都不带 sink。因此，`$(...)`、管道、source/eval、函数、循环、嵌套 shell 不会把中间结果提前泄露到宿主。

外层 `executeScript` 在完成一条语句并将结果计入 ExecutionOutputAccumulator 后，等待 Worker stdout/stderr 的 write 回调。两路都交付之后，才清空该累积器的已交付内容。共享的 ExecutionScope 和总输出预算继续存在，既不刷新 64 MiB 上限，也不重复计费。退出、errexit 和其它控制流错误所带的未交付尾部仍由原结果路径返回，Worker 最后只交付这部分尾部。此设计没有通过字符串前缀猜测或去重丢弃结果。

Worker 的输出仍走原有 stdout/stderr 管道、背压和 OutputCollector；运行时的真实 exit 才释放执行队列。本补丁没有添加父端文件事务，也没有修改已有取消、临时根归属和写入保留规则。硬取消的验证在观察到真实输出后才执行，随后等待真实 Worker 退出，确认排队任务和自有临时目录清理的顺序。

没有改全局 Node 内建模块，没有新增依赖。构建继续核验完整 npm bundle 集合、每个输入 SHA256、唯一替换锚点和每个输出 SHA256，保留 Apache-2.0 LICENSE 及修改标记。`upstream-review-sources.json` 增补固定提交 `7537a260e38648e8998db7a95504102ad80b0194` 的 bash 命令和 pipeline 源码身份；构建输入仍是锁定的已发布 JavaScript，不宣称重建了上游全部 TypeScript。

## 作者已实际执行的验证

- 旧批量实现首先失败：同一个首块断言只能收到包含首尾的一个输出块。失败日志保留在交付物 `logs/before-batch.log`。
- 受影响进程模块的完整旧回归加最初 11 个新测试：JIT **84/84**，严格 O0 **84/84**，均无 skip/TODO。覆盖实际 Cordis、LocalBashExecutor、tool-bash、原审批路径、文件权限、取消、rg、输出尾部/spill 和延后消费大输出。
- 补充跨语句 UTF-8 字节和工具描述断言后，重点严格组 **20/20**：12 个流式测试及 8 个权限/真实工具测试。原 84 项的产品输入未改变。
- Android 对照 **3/3**：OHOS 后端不能误装入，原 rg resolver 契约保持，实际注册的工具 description/schema 逐字相同；Android 目标选中的 11 个 diff 及其 pins 输入哈希不变。
- 固定 DSH 的严格五工具完整回合 **PASS**，经过 write/edit/read/grep/bash 和 2 次审批。该次 URL ready `5159.156694 ms`，host ready `6018.160723 ms`，回合 `2931.227490000001 ms`；这是一次 Linux 严格仿真观测，不是设备性能或统计分布。
- 最终重点严格组中的首次 stdout `286.943173 ms`，完成 `697.855272 ms`；脚本含 `sleep 0.4`。两路最终中文输出完整，无重复。

普通与严格测试均运行真实 Worker；严格模式继承父线程的 `--jitless` / preload，不向 `Worker.execArgv` 显式传 `--jitless`。Node 24 会拒绝显式传该 V8 参数。

## node 脚本的独立阻断

实际 Node 24.22.1 Worker 探针显示：两个不同请求的脚本 cwd 都等于父进程 cwd，设置 Worker 的 `env.PWD` 无法改变 `process.cwd()`；在 Worker 调用 `process.chdir()` 抛 `ERR_WORKER_UNSUPPORTED_OPERATION`。原生与严格 O0 两种模式结果相同。

本任务禁止全局改写 Node 内建模块，且 App 只有一个长期 Node 实例。父线程全局 chdir 会影响并发服务和其它 Worker，不能提供请求级 cwd。因而 `node <脚本>` 保持未实现，命令继续返回既有中文不可用提示和退出码 127。退出码、UTF-8 输出、env/argv、throw/process.exit 与同步循环 terminate 的底层 Worker 探针通过，只证明这些独立性质，不能解除 cwd 阻断。后续需要主线明确接受不同 cwd 语义，或提供可保持原接口语义的宿主隔离方案，才可继续实现。

## 构建与复跑

按本目录 README 的固定 npm/DSH 版本准备独立 prefix；应用厂商补丁必须带 `--target ohos`。本次更新现有 OHOS-only `zzzzzzzzzz-ohos-shell-limit-description.diff` 的最终文字与 after pin。全新安装可直接按 pins 构建；复用已经应用旧版该 diff 的验证 prefix 时，先在独立副本撤销旧版这一个 diff，再应用新版完整 pins。不要修改共享 prefix。

```bash
npm ci --prefix runtime/ohos/process --ignore-scripts --omit=optional
node runtime/ohos/process/link-dsh.mjs /absolute/ohos-prefix
node runtime/ohos/process/build-rg-regex.mjs /absolute/esbuild-0.27.3-prefix
python3 runtime/ohos/process/build-just-bash.py
```

若 `build/just-bash` 已是旧生成物，构建器会明确拒绝。先将自己的旧生成目录移走，再重新构建；不要编辑 npm 原包或生成目录来凑齐哈希。交付物 `commands.sh` 提供完整回归、Android 对照及严格真实回合命令；所有生成物均未纳入源码补丁。
