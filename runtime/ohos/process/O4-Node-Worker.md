# O4：Node 脚本专属 Worker 与路径重定位

本项基于 `2c2e799f42c4e506580e6d4a7a4c13f246976630`、Node **24.22.1** 和既有锁定依赖，不新增 npm 依赖、不改 package/lock。追加2明确允许专属 Worker 内的 cwd/fs 修改；此前“不修改内建入口时 Worker 不能提供 cwd”的阻断证据仍成立，保留为旧约束下的历史结论。

交付范围是 Linux 上真实 Node Worker、锁定 DSH/Cordis、严格 O0 与纯 Dart 协议验证。目标 OHOS 设备上的线程、原生 cwd、资源耗尽及系统生命周期仍须真机确认；这份文档不把桌面进程平台覆写当成目标 ABI 证明。精确结果和冻结哈希见同包交付说明。

## 入口与可观察行为

| 项目 | 实现与限制 |
| --- | --- |
| 命令 | `node <script.js\|script.cjs\|script.mjs> [args...]`，允许脚本前一个 `--`。不实现 `-e`、`--eval`、CLI 选项、stdin 脚本、目录入口、TS 或任意可执行程序。 |
| Worker 主入口 | Worker 的入口就是脚本文件，使用 Node 原生 CJS/ESM 入口装载；保留 require.main、import.meta.main、脚本相对 require/import、argv 和普通退出码。没有用 eval 包一层来伪造主模块。 |
| cwd | 私有变量初值为本次调用的实际目录；process.cwd、process.chdir 和依赖它的 path.resolve 使用该值。chdir 只能在本次 workspaceRoots 中移动，不能因临时目录可读写而把它当作工作区。 |
| 环境 | 沿用既有 scrubbedParentEnv，加显式 env 覆盖及 undefined 删除；TMPDIR 仍由服务设为私有临时根。未把父引擎 DSH 身份与凭据复制给脚本。 |
| stdin | 一次性字符串或 Uint8Array，最多 64 MiB；在 Worker 内提供有限 Readable，读取时字节精确，不读取也不拖住正常退出。fs.readFileSync(0) 不等于这个输入流。 |
| stdout/stderr | 直接 node 任务按实际字节持续交付；继续使用公开 pipe 与原 OutputCollector 的尾部/spill。bash 内的 node 命令先缓冲，等其外层语句完成路由后交付，以保留管道、替换和重定向。 |
| 退出 | process.exit(n)、自然退出及未捕获异常属于脚本 Worker；异常写 stderr 并得到实际 exit 1。脚本向 parentPort 发任意 exitCode/failure 消息不会伪造后端结果。 |
| 取消 | 排队尚未启动可直接取消；已启动则调用真实 Worker.terminate，等实际退出及输出排空。同步死循环和真实后代 Worker 均有取消测试。已写入的内容不会回滚。 |
| CLI 拒绝 | 不支持的 Node CLI 形式 exit 2；找不到脚本 exit 1；缺少可继承预加载器 exit 127，且 node 从能力命令表中移除。越界/read-only 等实际策略错误保留 EACCES。 |

宿主仍只有 `runtime/ohos/preload.mjs` 一个产品 `--import`；追加13后依次完成 child_process 产品边界、network、publication、Node Worker 预加载。Node Worker 预加载器自身的主线程分支仅登记可继承标记，专属 Worker 由 workerData 协议选择路径适配。普通 Worker 不修改 cwd/fs；嵌套的普通 Worker 也不会自动得到父脚本的私有 cwd。预加载器必须真实存在于继承的 execArgv；只在主线程动态 import 一个标记不能宣称入口可用。

独立产品边界使 OH 主线程和普通 Worker 的 OS 子进程调用报 `ERR_OHOS_NO_SPAWN`；专属协议1 Worker 的后继路径适配器仍报原 `ERR_OHOS_CHILD_PROCESS_UNAVAILABLE`。这不改变本节 cwd/fs、私有 stdin 或线程取消合同，具体入口范围见 [虚拟进程说明](README.md)。

Worker 不显式设置 execArgv。Node 24 会拒绝显式传给 Worker 的 `--jitless`，而默认继承主线程 V8 标志与预加载是实际可跑路径。测试同时验证主线程、普通 Worker 与原 App stdio 未被专属脚本替换。

## 固定 fs 路径表

`node-path-table.mjs` 逐项登记固定 Node 24.22.1 的公开 fs 与 fs/promises 导出。清单中有 106 个路径入口，加 realpath.native、realpathSync.native、Utf8Stream.prototype.reopen 三个嵌套入口；路径位置、双路径、fd 替代、symlink target、glob cwd 和完成形态均明确列出。检查使用全部自有属性名，包含不可枚举的 F_OK/R_OK/W_OK/X_OK。新增或遗漏导出会报 `ERR_OHOS_NODE_FS_SURFACE_CHANGED`，测试有反向对照。

每个登记入口都由真实文件夹具执行，不能只测几个常用方法再推断全表。固定 Linux Node 中 fs.lchmod/lchmodSync 不存在，fs.promises.lchmod 返回 ERR_METHOD_NOT_IMPLEMENTED；这些作为原生不可用记录，不算实现成功。O0 对 link/linkSync/promises.link 的 EACCES 仍保留，适配器不绕过平台原本的拒绝。

字符串、UTF-8 Buffer 和 file URL 路径转换为当前私有 cwd 下的绝对路径；非 UTF-8 Buffer 路径显式拒绝。普通空路径仍交给原生报错，mkdtemp 的空前缀使用私有 cwd。路径中 symlink/.. 的权限检查使用 native realpath，而非会先规范化 dot segments 的 JavaScript realpath。已存在的越界链接会拒绝。公开 realpath 内部会 lstat 已知根的祖先，因此 stat/lstat 只放行这些祖先的元数据；不允许列举或改写祖先目录。

Node 的 glob 限定显式 cwd，不允许 followSymlinks:true 或通配符之后的父目录跳转；cp 的递归 filter 会核验每个实际源/目标。所有检查与随后的 I/O 并非原子操作，其他线程替换路径仍是结构性竞态。返回的 Dir.path、mkdtemp 名字等可因传入绝对路径而呈绝对形式，不能宣称完全保留 Node CLI 的相对路径拼写。

## 文件描述符归属

公开 fd 操作只接受本脚本 Worker 实际打开的描述符。继承的数字 0/1/2 不作为 App stdio 能力暴露，脚本应使用自己的 process.stdin/stdout/stderr。fs.open、openSync、promises.open 都登记归属；FileHandle 保持强引用，防止 GC 关闭后旧数字仍被当作可用。

fs.close/closeSync 在进入底层 close 之前撤销归属。FileHandle close 事件撤销对应记录，使用前还检查 handle.fd，避免 transfer/关闭后的旧数字被继续信任。移除记录只针对同一拥有者，不能误删后来登记的条目。read-only 同时检查路径写、fd 写与 FileHandle 写方法。

真实回归分别用同步 close、回调 close、自动关闭 ReadStream、FileHandle.close、FileHandle 自动关闭流，以及实际转移 FileHandle 后由接收线程关闭，然后让主线程打开实际文件直到取得**同一个数字 fd**。子 Worker 对旧 fd 的读/写/关均须拒绝，父线程文件保持原字节。这个证据不扩大为全部原生 API、任意 fd 传递协议或操作系统沙箱证明。

fd 包装使用保留原函数属性的 Proxy。初稿普通函数包装曾在真实 Node 对照中丢失 read/write/readv/writev 的 customPromisifyArgs，使 util.promisify 只返回数字；修订保留原有符号元数据，并用原生返回结构和实际 Buffer 身份回归。该失败与前像未删除。

## 输出完成门与取消边界

首次真实运行时回归测得：2 MiB stdout 触发背压时，Worker exit 已到达，但其可读流仍持有最后一个汉字的 3 个字节；原 finish 提前结束公开流导致丢尾。当前实现等待“Worker 已退出 + stdout/stderr 已 end/close”，再进入基底 O4b 的异步 finish：等待父线程已经接受的 I/O、RPC、归属清理与描述符关闭，之后才 seal/end/settle。直接 Node 脚本不创建 Git broker，用户 parentPort 消息不能取得其权限。正在执行时保留消费端背压；线程退出后排空已经发出的有限尾部，避免未读公开管道阻塞取消完成。

同一调用栈 spawn 后立即 terminate 不会启动脚本。运行中的同步忙循环、Node 脚本建立的实际后代 Worker，以及 bash→Node→后代 Worker 链均有 join 后文件不再增长的实测。取消不保证回滚已发起的外部 I/O 或业务事务；脚本自己调用原生绑定的行为不在公开 JS 重定位边界内。内存 old-generation 限制不等于 Buffer、native 或进程 RSS 上限。

### v2：Bash 内二进制 stderr

v1 的独立复核抓到：脚本写出 `00 ff c3 a9 0a` 时，原生 Node 与直接 node 任务都保留原字节，bash 内的普通 stderr、`2>`、`2>&1` 却把 `ff` 变成 `ef bf bd`。原因是 node-command 在路由前把 stderr 解码为 UTF-8，而固定 just-bash 的 stderr 聚合原本只有文本契约。旧补丁与失败证据保留为 BLOCKED，不能引用旧全组通过来覆盖该反例。

v2 在 OH 私有 ESM 增加 `stderrKind: "bytes"`，用 Latin-1 字符串保存实际字节。Node 命令结果、重定向、脚本/语句聚合、管道、循环及控制流错误之间都传递这个类型；普通诊断文本仅在进入字节通道时编码为 UTF-8。输出预算按原始字节计量，Worker 最终按各自类型写入两路 stdio，不在内部猜测非法 UTF-8 的含义。原 npm 安装、共享 Node 内建模块和 Android 构建输入均不改；四个私有变换模块仍核对原始完整 SHA 与变换后 SHA。

修订完整回归也抓到一次旧中文函数 return 输出被重复编码：路由后的 byte stdout 写回原本只接受 text stdout 的控制流错误对象。修复在该既有 text 边界显式恢复有效 UTF-8，原断言保留；stderr 仍带显式字节类型。失败前像与全组日志分别保存。

原生 Bash 相邻对照还抓到 `2> file 1>&2` 会先 append stdout，再由 stderr 的第二次 write 截掉 stdout。修复只按准备阶段同一个已打开描述符对象的身份合并通道；两个独立 open 恰好指向相同文件名时不当作 dup。回归保留重定向顺序、独立双路、合流、追加、持久描述符、函数/循环/子 shell/替换/source/eval、errexit/return/break/continue、大块非 UTF-8 邻接有效中文尾部、拆成多次写入的合法 UTF-8 与非法字节、stdout 先复制到 stderr 后再经过文件/管道，以及原始字节预算。

这项修复没有新增跨 stdout/stderr 写入的实时交错顺序承诺；bash 内 Node 仍按原缓冲路由。M4-4b 文档中已登记的任意二进制 **stdout** 经 `exit/return` 控制流路径的旧限制不由本项消除，不能把 stderr 的回归扩写成所有 shell 字节语义已等价。

该 stdout 边界另由后继 [O4-stdout-control-flow.md](O4-stdout-control-flow.md) 处理；Worker v2 原包及本节历史测量保持原结论。新修复需要重新构建 OH 私有 Bash，并经过独立组成验收。

## 能力协议与主线界面衔接

实际注册的 subprocess 服务在预加载条件成立时声明 `nodeScripts: "worker-rebased"`，否则声明 none 并移除 node 命令。O6 快照逐次读取该服务，旧枚举 worker/process/none 继续兼容。Dart 新增 `RuntimeNodeScripts.workerRebased` 并显式映射带连字符线值；旧客户端会把未知新值保守解析为 unknown。

按 TASK 分工，产品补丁不修改 Flutter 界面。主线合入模型前须在 `app/lib/ui/engine/engine_capabilities.dart` 的穷尽 switch 接上新枚举，最小衔接如下（仅供主线，不包含在本补丁的 UI 文件差异中）：

```diff
-    RuntimeNodeScripts.worker || RuntimeNodeScripts.process => l10n.engineCapYes,
+    RuntimeNodeScripts.worker || RuntimeNodeScripts.workerRebased || RuntimeNodeScripts.process => l10n.engineCapYes,
```

这沿用现有“可用”文案，能力细节展示仍由主线决定。纯 Dart 包 analyze/tests 不覆盖该 UI 文件；未做此衔接时整个 App 的穷尽 switch 将不完整，不能把本包模型测试结果写成整 App 编译通过。

## 可重现验证与证据限制

- `node-script.test.mjs`：固定导出清单、逐个真实路径入口、输入流、中文双 cwd、越界链接、fd 重用与只读。
- `node-script-runtime.test.mjs`：真实服务的 CJS/ESM 入口、首段时序、exit/异常/伪造消息、排队取消、同步忙循环、后代 join、背压尾部、原 collector 和实际 bash 路由。
- `node-script-stderr.test.mjs`：实际 Node 二进制 stderr、双路编码/重定向顺序、复合语句与控制流、大输出尾部及按原始字节计费；随包保存原生 Bash/Node 对照和修复前反例。
- `node-script-unavailable.test.mjs`：在命令行未加载 Node 预加载器的独立进程验证 none/127；动态 import 标记仍不可用。
- `test.sh`：既有过程测试、Android 条件对照与上述回归，分别普通模式和严格 O0。
- `node-script-model.mjs`：在真实完整五工具/两审批回合中，把 bash 步骤换为 Node 脚本；脚本检验中文参数、环境、cwd、相对模块、edited file、无 WASM、继承 jitless，并留下真实 JSON 文件观测。
- 既有 `publication-capabilities-http.mjs` 在真实已鉴权 DSH 上核对 worker-rebased 同源能力及实时熔断；Dart 模型/HTTP 另由固定 Dart SDK 实跑。

源材料是官方 Node 24.22.1 源码与文档中的 fs、worker_threads、module、worker_thread 启动顺序和 FileHandle close 实现，以及锁定 DSH/just-bash 的现有契约。具体源码归档 SHA、实际命令、原失败、版本迁移与冻结交付哈希随报告保存。没有把 TypeScript 替身、普通 Linux ABI、工具存在或静态源码审读算作 OHOS 设备通过。
