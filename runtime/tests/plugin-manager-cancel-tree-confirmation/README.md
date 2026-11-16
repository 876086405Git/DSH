# 自有 package 进程组的取消确认

本组测试针对 service/POSIX 路径；实际运行 rc4 `runCli()`、正式 HTTP RPC 和真实本地进程。包管理器是自写的受控夹具，不运行 pnpm，不下载任何依赖，不访问外部 registry；`.invalid` 地址只是参数和分类输入。测试不是 Android/PRoot 或完整 ABI 运行时构建证明。

## 准备与命令

在仓库根目录准备一个打过补丁的 DSH 0.2.1-rc.4 prefix，做法与 `runtime/build-runtime.sh` 的 `install_dsh` 和打补丁步骤相同：

1. 把 `runtime/locks/dsh-0.2.1-rc.4/package.json` 和 `package-lock.json` 复制到一个新的空目录（下称 prefix），在其中执行 `npm ci --ignore-scripts --no-audit --no-fund`。build-runtime.sh 另外传 `--cpu`、`--os=linux`、`--libc=glibc` 选目标 ABI；在 Linux 宿主上跑本测试时用宿主平台即可。
2. `python3 -I runtime/lib/rtbuild.py patch-dsh --prefix /absolute/own/prefix --dsh-version 0.2.1-rc.4 --target android`。它按 `runtime/patches/series` 的显式顺序应用 `runtime/patches/pins.json` 里 `targetSets.android` 登记的补丁链（与 build-runtime.sh 相同），并按 `runtime/patches/pins.json` 核对每个文件补丁前后的 SHA-256。改动 `dsh-plugin-manager` 的是 `install-log-redaction.diff`、`plugin-manager-active-run-guard.diff` 和本测试对应的 `plugin-manager-cancel-tree-confirmation.diff`。

不要用修改 pins 或跳过校验的方式接受补丁链中间状态的文件。对已完整打过补丁的 prefix 重复执行第 2 步是幂等的。

```sh
DSH_PREFIX=/absolute/own/prefix node --test --test-isolation=none --test-reporter=tap runtime/tests/plugin-manager-cancel-tree.test.mjs
python runtime/tests/plugin-manager-cancel-tree-confirmation/run.py --prefix /absolute/own/prefix --out /absolute/own/results --port 39311
```

`--cases` 可明确选择表内任意子集。运行器需要 Linux `/proc` 及 `prctl(PR_SET_CHILD_SUBREAPER)`。`--port` 指定的端口必须空闲（默认 39311），同一台机器上的其他测试不要同时占用。不要将测试 home 指向用户真实配置。

## Golden 场景

| 名称 | 必须观察到的结果 |
| --- | --- |
| cooperative | 组已消失，两接口 cancelled，两个文件恢复，记录和锁移除 |
| term-resistant | 父已退出、同组后代抗 TERM；确认 KILL 后组消失才返回 cancelled，无门控迟到写入 |
| stop-unconfirmed | 父子抗 TERM，仅该组 KILL 被屏蔽；cancel 为 RPC 错误，install failed，保留现状文件和运行记录 |
| nonzero | PM exit17；停止确认、恢复、无记录泄漏 |
| success-remove | 正常 disabled 安装及正式 remove 均 applied，两个操作均无记录泄漏 |
| outer-not-bundle | primary 正常退出且后台后代仍活；外层 not-bundle 失败须先停组再恢复和释放 |
| success-background | 普通成功保持原有后台行为，不主动杀掉正常后台后代，关闭取消窗口后释放记录 |
| late-cancel | 真实 runPnpm 已返回，测试仅暂缓外层续行；取消仍停止它持有的后台组，再恢复并释放 |
| stop-unconfirmed-emit | 停止失败时额外注入 install-log 发射异常；私有停止事实仍使 cancel 错误、文件不恢复 |
| compat-primary-unconfirmed | primary 安装后才产生不兼容 manifest，后代无法停止；不进入内部 restore，不启动 repair |
| compat-repair-success | 确实进入 repair，启动时两个文件已是原值，新独立组承接记录，最终按不兼容安装 failed |
| compat-repair-cancel | repair 自有组接受取消，后代确认停止后两接口 cancelled，恢复并释放 |
| compat-repair-unconfirmed | repair 父子仍活，取消错误、安装 failed；不再次恢复、不删后继 repair 记录 |
| compat-repair-timeout | repair 持续输出心跳仍触发原绝对超时；确认组停止后安装 failed、恢复并释放 |
| registry-retry | 两次受控 add；第二次启动前两个文件已恢复、第一组已消失；第二次成功 applied |

## 证据边界

前两种 unconfirmed 故障是显式屏蔽自有组 KILL，不能据此声称自然发生 D 状态、权限故障或真实操作系统丢信号。EPERM/EIO/ESRCH 差异由生产 helper 的单元注入覆盖。late-cancel 在真实服务实例的 runPnpm 返回处加等待门；emit 场景只对停止失败日志注入异常。这些测试门均在观察器/启动器里，不写入产品代码。

所有进程清理先核 PID/startTicks/PGID，仅处理本次已记录身份；子回收器只 waitpid 指定自有孤儿，不用 waitpid(-1)，不夺取 Host Popen 的退出状态。Z 态仍是组存在，必须完成实际回收后才能断言消失。`--out` 下每次运行的 `evidence/` 包含 HTTP 信封、前后文件、真实加载模块 SHA、信号注入和清理；带登录 token 的 Host 原始日志只留在每例的 `private/` 目录，不复制进 `evidence/`。

测试报告中的耗时是本次观测，不是端到端 SLA。产品守卫每阶段使用既有5秒等待值；调度、文件 IO、错误发射和其他最终处理没有因此获得统一时限。正常成功后台组、脱离该进程组的后代、PID/PGID 再分配的系统级竞态，以及 CLI/Windows 的不同语义，不由本修复宣称全面解决。
