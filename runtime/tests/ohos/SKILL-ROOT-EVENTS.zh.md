# 1245：缺失技能根的原生事件监听

## 范围与结果边界

`ohos-skill-root-events.diff` 只加入 `pins.json` 的 `ohos` 目标，在既有公共链与 OH 覆盖之后应用。固定 DSH 版本为 `0.2.2-rc.1`。它修改 `@deepseek-ai/dsh-skill-filesystem` 的缺根监听，不修改 Android 目标、ArkTS、Dart、Node 构建、现有根的 chokidar 参数或技能解析协议。

此前真实 Host 的 1242 资源证据发现四个存活且未引用事件循环的 `fs_poll`。对应源码对缺失路径无条件调用 `watchFile(..., interval: 100)`，即使 `watchUsePolling=false` 也如此。1242 没有成功取得 syscall 频率，也没有把整进程 CPU 分配给这四个资源。本项同样不报告 CPU 百分比、设备节电量或每秒 stat 次数。

本项组件测试用真实 Cordis、SkillRegistry、FileSystemSkillProvider、私有目录和实际 Node 原生句柄。默认单缺根的 `fs_poll` 从 1 变为 0；显式私有项目及私有用户目录的四个缺根从 4 变为 0，并保留原生事件发现能力。原有空 bundle 根仍使用 chokidar。原生事件创建失败时会回到原 stat polling，因此不能称所有环境均零轮询。

## 行为

| 条件 | 行为 |
|---|---|
| `watch=false` | 不创建监听，保持原有停用语义。 |
| 根已存在 | 沿既有 chokidar 分支、稳定写入阈值及配置。 |
| 根缺失且 `watchUsePolling=true` | 继续原 `watchFile`，保留显式 polling 选择。 |
| 根缺失且默认配置 | 在最近存在的祖先目录创建 `fs.watch`，`persistent:false`。事件后重新解析根；有变化时按原链失效目录缓存并转换监听。 |
| 原生事件创建或运行报错 | 记录明确警告，包含回退 polling 及其配置间隔；该根在同一 anchor 上不反复尝试已失败的原生事件，而使用原 `watchFile`。 |
| 打开前祖先消失 | 仅对真实 `ENOENT` / `ENOTDIR` 重走原有模式解析循环；其他模式探测错误仍使发现不完整，不伪造成功。 |
| 最后 owner 释放或 provider dispose | 沿原资源释放链关闭句柄；附加的回退 anchor 只随该 root state 存活。 |

`nativeFallbackAnchor` 是每个现有 root state 上的一条字符串。原生创建或 error 报错时置为该 anchor，成功打开另一个原生 watcher 时清除；root state 释放后不留全局记录。它不产生新周期任务，也不修改原项目根数量上限。

## 目录身份与异步归属

`fs.watch` 监听 inode。目录被删除或重命名后，同路径重建的目录可能拥有另一个 inode；只比较路径字符串会漏掉这种更换。缺根 mode 复用实际 `stat(..., {bigint:true})` 的 `dev`、`ino`，打开前后以及事件后的 mode 比较都包含这两个字段。普通根仍沿原有 mode/chokidar 行为。

两次 stat 相同也不充分：在两次探测间，路径可以 A→B→A，而 `fs.watch` 实际绑定 B。真实局部导入夹具已复现这个反例。因此原生 `rename` 事件会保守重挂载，即使前后 mode 相同；不依赖 filename 一定存在。对于同 mode 的重挂载，不先失效技能缓存；重挂载完成后再检查 mode，期间若根或祖先真的变化，仍会失效。无关子项 rename 会增加事件驱动的关闭/打开工作，这个成本明确保留；普通 `change` 且目录身份未变时无需重挂载。没有定时健康检查。

所有祖先事件捕获其具体 handle，等待 opening 结束后核对它仍属于当前 root state。重新解析 mode 的成功与异常出口再次核对 handle，防止旧 inode 的延迟结果把新 watcher 标坏。原生 error 回调也等待 opening 并校验关闭状态、owner 和 handle；关闭后晚到 error 不复活资源。测试覆盖排队 stat 成功和 EIO 两个分支。

## 针对性验证与夹具说明

在 `tooling/ohos/run-gates.py` 登记 `skill-root-events-plain` 和 `skill-root-events-jitless`，每门 27 项：11 项真实目录/配置/资源行为、11 项局部导入故障与竞争边界、5 项既有 watcher recheck 测试。旧 polling recheck 用显式 `watchUsePolling=true`；其时序夹具只包装本次自有 provider 的方法，不再全局替换 Node 内建函数。

局部导入夹具只把一份临时模块的两个 `node:fs` / `node:fs/promises` 导入指向测试文件。模块其余源码与锁定后像一致，其他依赖继续用固定 prefix，正常操作仍调用实际 Node fs。ENOSPC、异步 error、延迟 EIO 是明确注入；打开间 ENOENT、ELOOP、同路径 inode 更换和 A→B→A 使用真实私有目录变更。迟到 EventEmitter 事件用于可控交错，不宣称自然设备故障已发生。symlink 仅为宿主模块解析和 ELOOP 夹具，不是新增产品能力或手机操作。

原 177 项 OH prefix 上，同一最终 core/recheck 测试实际为 16 项中 14 绿、2 红，红点为 1 个 / 4 个 `fs_poll` 不能满足零默认 polling。被拒绝的早期事件候选另保留 ENOSPC、打开间 ENOENT、同路径 inode 更换和 ABA 的真实红。最终结果与精确补丁 SHA 见外层交付说明。

## 应用与复现

在 a836880 仓库根应用外层补丁后，对按原锁安装的私有 prefix 执行：

```sh
python3 -I -B runtime/lib/rtbuild.py patch-dsh \
  --prefix /absolute/private/dsh-prefix \
  --dsh-version 0.2.2-rc.1 --target ohos \
  --target-report /absolute/evidence/ohos-target.json
```

这里是独立 a836880 补丁：OH 177→178，最终 pin 路径仍 124；Android 仍 145。后续累计树必须取已有系列、pins 与门的并集，不可用本件较早的整份 pins/series 覆盖后续累计项。

不运行统一门，仅运行上述两个正式登记或等价单条命令：

```sh
DSH_PREFIX=/absolute/private/dsh-prefix node --jitless \
  --experimental-import-meta-resolve --test --test-isolation=none --test-reporter=tap \
  runtime/tests/ohos/skill-root-events.test.mjs \
  runtime/tests/ohos/skill-root-events-fault.test.mjs \
  runtime/tests/skill-watcher-recheck.test.mjs
python3 -I -B tooling/ohos/tests/run-gates.test.py
```

移除 `--jitless` 即 plain 形式。需要实际 Node 支持 `process.report`；本项实际执行版本为 24.22.1。Android 核验只物化 124 个目标输入文件并实际执行原/新 `--target android` 准入，全部文件及 145 项 recipe 一致；未运行完整 Android runtime。

## 尚未验证

未运行完整门、OH SDK、HAP、实际 Flutter/ArkTS 或手机。设备侧仍需在私有真实项目和用户目录核对 `fs.watch` 是否可用、错误是否明确回退、根创建/原子安装/删除重建的发现，以及后台/保活同窗 CPU。宿主的 native 事件成功不能替代这些结论。网络或虚拟文件系统的事件可靠性遵循 Node fs.watch 本身的限制；本件没有增加轮询健康保证。

API 依据：Node 固定版本 [fs.watch 的 caveats、inode 与 filename 合同](https://nodejs.org/download/release/v24.11.0/docs/api/fs.html#fswatchfilename-options-listener)、[fs.watchFile](https://nodejs.org/download/release/v24.11.0/docs/api/fs.html#fswatchfilefilename-options-listener)、[诊断报告原生句柄字段](https://nodejs.org/download/release/v24.11.0/docs/api/report.html)。资源可见性与测试结果以本项实际 24.22.1 二进制记录为准。
