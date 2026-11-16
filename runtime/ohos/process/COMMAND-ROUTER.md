# 鸿蒙命令路由与 stdio MCP

本实现复用现有 Node 脚本 Worker。工具入口仍保留虚拟 Bash/rg/git/Node；插件导入的 child_process 只在已登记的插件 profile 内映射到私有 facade。宿主、不属于插件的模块、getBuiltinModule 和原有 Node 内建边界不变。

## 已实现的行为

- 插件 `spawn('node', ...)`、execFile、异步 execFile 的 promisify 形式使用真正 Worker。Node 支持脚本、`-e`、`-p`、`--version`；流式 stdin 与脚本源分开，流式 `node -` 明确不支持。批量 stdin 保持原行为。
- 各 stdio MCP Node 服务独立运行，不占用普通工具的串行执行 lane。stdout/stderr 独立，保留背压；done 等真正 Worker exit 与输出收尾，child close 等输出 readable end。取消请求不伪造 join。
- SIGTERM/SIGKILL 在 Node lane 均为 Worker 终止请求，返回接受的信号名称；它们不是独立 Unix 进程，也不运行 Unix signal handler。pid 不捏造。IPC/fork、同步 child_process、PTY、传入 fd、继承 stdin 等不可实现的能力明确拒绝。
- 关闭命令 owner 同步封闭所有准入；共享临时目录只有在所有后端真实关闭后才能删除。关闭失败保留资源证据，不能恢复准入。
- SDK 的 StdioClientTransport 原类接受私有 spawn 参数，探测 sibling 复制同一参数。DSH 通过 ctx.subprocess.pluginProcess 注入；没有替换 SDK 的 JSON-RPC 协议或版本协商，也没有改写全局 Node 内建模块。
- SDK send 在 write callback、drain、error、close 之间恰好结算一次；关闭拒绝仍等待的发送。写入完成不代表 MCP 响应或 Linux 作业完成。

## 后端边界

CommandRouter 的第二个构造参数仅供可信应用 owner 安装 linux/nativePython，不来自命令参数、插件环境或 DSH 配置。未安装时其他插件命令保留 ERR_OHOS_NO_SPAWN。exec 需要真正可用的 `sh -c` 后端，不拿虚拟 Bash 冒充系统 shell。

工具 prepare 的票据在原入口消费后才选择外部后端。显式要求 read-only/workspace-write 的调用必须被后端真实支持；不能把 policy 清除后交给原生 Python。当前 905 Python 自报 confinement:none，必被此路径拒绝。

可信 owner 已注入 Python 工厂时，router 与工厂共用 `python`、`python3`、`pip` 及它们的 `/bin/`、`/usr/bin/` 别名名单。其他路径不会仅凭 basename 获得 Python 路由。`pip` 仍转为 `-m pip` 并明确返回 ERR_OHOS_PYTHON_ARGUMENTS，不会因为名单不一致悄悄落到另一个后端。

Python provider 提供 live、started 与 dispose：started 来自实际 owner Worker 的作业准入；dispose 同步封闭准入，协作取消并等待作业双流生产完成、collector 封口，再等待真实 Worker exit。共享临时根在该屏障之后才可删除。失败时保留资源错误。关闭不调用 Worker.terminate 或 Py_Finalize，主解释器仍隔离保留，不能在同一 App 内重新初始化；这也不表示消费者已读完 Readable 的全部缓冲。

940 起 OHOS 运行时把 App 内 Linux 装进 linux 槽（工厂形式，拿到本 router 自己的根），虚拟 shell 里的 gh/python3/python/pip/pip3/`linux` 按语句缓冲转发为客体作业，见 `runtime/ohos/linux/ROUTING.zh.md`。本补丁仍不自动装入 905 Python、913 授权目录；那些后端仍需要统一生产装配和各自生命周期。新 Worker 也不因此获得嵌套 child_process 或任意原生库权限。Linux/Python/9P、安装下载和 HAP 真机验收不在本子项的已验证范围内。

## 固定依赖与构建

DSH 锁为 0.2.2-rc.1，MCP SDK @modelcontextprotocol/client 2.2.0（MIT），均来自已有锁，不增加依赖。新增 ohos-mcp-command-router.diff 只登记在 pins 的 ohos 集；Android 集、原有 diff、构建版本串不变。

先按既有 process 构建步骤产生 just-bash 与 re2js，再对独立锁定 npm 前缀执行：

```sh
python runtime/lib/rtbuild.py patch-dsh --prefix /absolute/locked-prefix --dsh-version 0.2.2-rc.1 --target ohos
DSH_PREFIX=/absolute/locked-prefix node --import /absolute/repo/runtime/ohos/process/node-worker-preload.mjs --test runtime/tests/ohos/node-streaming-stdin.test.mjs runtime/tests/ohos/plugin-process.test.mjs runtime/tests/ohos/mcp-command-router.test.mjs
```

严格模式额外加 --jitless 和绝对路径 sim/preload.mjs，并设置既有仿真显式变量。绝对 import 路径不能在会主动 chdir 的测试里替换为相对路径。需要真实外部链接输入的已有测试必须通过 process-link-fixture.py，不能恢复被严格仿真禁止的 fs.symlink。

新测试登记 command-router-plain/strict；旧 add13 complete 改为真实 Worker stdio peer、注册工具调用和 marker。existing 仍观察原 OS 路径；guard-only 没有专用 DI，保留无 marker 的拒绝，failOnStartupError:false 使插件 fiber 保持原 active 状态。这两项历史对照不等于生产支持。
