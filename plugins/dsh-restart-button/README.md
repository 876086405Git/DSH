# dsh-restart-button

在 DeepSeek Harness 桌面端侧边栏底部加一个「重启」按钮：确认后自动重启整个应用，全程无感。

> 一个 DSH 插件（bundle）。Host 半侧注册本地接口，浏览器半侧渲染按钮与确认框。

## 这个插件解决什么问题

桌面端改了插件、配置或主题之后，必须重启才能生效。原来只能：

1. 右键任务栏图标 → 退出；
2. 再从开始菜单重新打开。

中间要手动操作两次，而且很容易忘了退出——安装目录被占用时升级还会失败。这个插件把两步合成一次点击。

## 功能

| 场景 | 行为 |
| --- | --- |
| 正常界面 | 侧边栏底部、账号头像右侧显示「↻ 重启」（透明背景，与侧栏其它图标按钮同风格）|
| 打开设置面板 | 按钮自动隐藏，不干扰设置界面 |
| 悬停 | 淡色底提示可点击 |
| 点击 | 弹出确认框「要重启 DeepSeek Harness 吗？」，说明当前任务会被中断 |
| 确认 | 显示「正在重启…」遮罩，应用关闭并自动重新打开 |
| 失败 | 错误框列出具体原因 + HTTP 状态 + 日志尾部，提供「重试一次」「复制日志」 |

## 安装

```bash
dsh plugin --profile desktop add ./dsh-restart-button-1.0.0.tgz
```

或者在 DSH 的 **插件** 页面用「添加插件」选择本地目录 / 压缩包。

安装后重启一次桌面端生效（这一次还得手动重启 😅）。

## 为什么重启要绕这么大一圈

桌面端的进程结构是：

```
Electron 主进程
  └─ Host 子进程   ← 本插件运行在这里
```

如果直接在主进程里「杀掉自己再拉起来」，杀掉的那一刻发起重启的代码也一起死了，重启动作断在半路。所以必须把「关掉 + 重新拉起」交给一个**脱离进程树**的进程去做。

实现路径：

```
插件（Host 子进程）
  └─ schtasks /Create + /Run          创建并触发计划任务
       └─ wscript.exe                   Windows 脚本宿主（GUI 子系统，无控制台）
            └─ powershell.exe -WindowStyle Hidden
                 └─ restart.ps1        等 3 秒 → 杀进程 → 等退干净 → 重新拉起
```

计划任务的父进程是 `svchost.exe`，与 DSH 没有父子关系，因此杀掉 DSH 不会把它一起带走，它能继续把应用拉起来。

### 为什么中间要夹一层 wscript

最早是让计划任务直接跑 `powershell.exe`。实测会**闪出一个黑窗**：powershell 是控制台程序，即使加了 `-WindowStyle Hidden`，进程启动瞬间 conhost 仍会先创建控制台窗口，窗口一直留到脚本结束（约 3 秒）。

改成 `wscript.exe`（GUI 子系统，本身不带控制台）之后，它用 `WshShell.Run(cmd, 0, False)` 隐藏着拉起 powershell：参数 `0` = 窗口隐藏，`False` = 不等待。整条链路上不再出现任何可见窗口。

> 实测验证：`schtasks → wscript → powershell` 三步全程 `MainWindowTitle` 为空，日志正常写入。

## 接口

插件在 Host 侧注册三个路由（沿用 DSH 插件常规的本地接口约定）：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api-restart-button/state` | 当前环境是否支持重启、上一次重启回执 |
| POST | `/api-restart-button/restart` | 触发一次重启（确认由前端完成）|
| GET | `/api-restart-button/log` | 上一次重启的日志尾部 |

安全栅栏：只接受无 `Origin`（同源导航）、回环地址或 `dsh-app://` 的请求，跨源一律 403。

## 失败排查

重启脚本与日志都落在临时目录：

```
%TEMP%\dsh-restart-<随机>\
  ├─ restart.ps1     重启脚本
  ├─ launch.vbs      无窗口启动器
  └─ restart.log     执行日志
```

日志内容形如：

```
[2026-11-16 21:51:46] restart requested (pid=392)
[2026-11-16 21:51:49] stopped DeepSeek Harness pid=15288
[2026-11-16 21:51:49] stopped total 12
[2026-11-16 21:51:50] relaunched
[2026-11-16 21:51:50] done
```

| 现象 | 原因 |
| --- | --- |
| 错误框：当前不是桌面端环境 | 在 `dsh web` 或 CLI 里点了按钮，没有桌面应用可重启 |
| 错误框：找不到桌面端可执行文件路径 | `DSH_NODE_EXECUTABLE` 缺失且 `process.execPath` 不是 `.exe` |
| 错误框：创建/启动重启任务失败 | 受管控的机器不允许建计划任务，错误框里有 `schtasks` 原始输出 |
| 重启后没起来 | 应用已退出所以不会再弹提示，看上面日志的 `FAILED` 行 |

## 限制

- **只支持 Windows。** 依赖 `schtasks` + `wscript`，macOS / Linux 会明确拒绝并提示。
- 重启会中断当前正在执行的任务，包括正在跑的 Agent 回合。
- 需要当前用户有创建计划任务的权限（普通用户默认有）。

## 文件结构

```
dsh-restart-button/
├─ package.json        插件清单（bundle patch + client 声明）
├─ cordis.patch.yml    插入插件行
├─ icon.svg            插件图标
├─ locale/en.json      英文文案 + 插件元信息
├─ locale/zh.json      中文文案
├─ docs/DETAIL.md      插件详情页
└─ lib/
   ├─ index.js         Host 半侧：三条路由 + 状态管理
   ├─ relaunch.js      重启执行器：schtasks / wscript / PowerShell 生成
   └─ client.js        浏览器半侧：按钮、确认框、错误提示
```

## 验证情况

| 验证项 | 状态 |
| --- | --- |
| 按钮位置 / 透明背景 / 与账号行对齐 | ✅ 已实测（截图确认）|
| 设置面板打开时按钮隐藏 | ✅ 已实测 |
| 确认框弹出与文案 | ✅ 已实测 |
| 确认框主按钮对比度 | ✅ 已修复并实测（原白底白字）|
| `wscript → powershell` 无窗口执行 | ✅ 已实测（进程无窗口，日志正常）|
| `schtasks → wscript → powershell` 整链无窗口 | ✅ 已实测 |
| 端到端真实重启（点按钮 → 应用关闭重开）| ✅ 用户实机验证通过 |

## License

MIT
