# DSH 全自动升级工具

一键搞定 DeepSeek Harness 桌面端升级：查版本 → 下载 → 校验 → 杀进程 → 备份 → 安装 → 核验 → 启动 → 健康检查 → 失败自动回滚。

## 为什么需要它

DSH 自带升级在国内网络和特定环境下经常失败。本工具针对实测踩到的 21 个问题逐一做了防护，其中 5 个是会导致「环境搞坏」或「假绿误报」的致命问题。

## 快速开始

### 方式一：双击运行（推荐）

下载本目录的 `一键升级-v4.bat`，双击，按中文菜单选数字。

### 方式二：命令行

```powershell
# 日常升级
powershell -NoProfile -ExecutionPolicy Bypass -File "DSH-AutoUpgrade-v4.ps1" -Silent

# 只预检，不下载不安装
powershell -NoProfile -ExecutionPolicy Bypass -File "DSH-AutoUpgrade-v4.ps1" -DryRun

# 升级出问题，退回上一版
powershell -NoProfile -ExecutionPolicy Bypass -File "DSH-AutoUpgrade-v4.ps1" -RollbackOnly

# 修复安装（强制重装当前版本）
powershell -NoProfile -ExecutionPolicy Bypass -File "DSH-AutoUpgrade-v4.ps1" -Force -Silent
```

### 方式三：让 AI 代跑

把脚本路径给 AI 即可。脚本会自动检测自己在 DSH 进程树内，用计划任务脱离后执行，**不需要手动关 DSH**。

## 参数

| 参数 | 作用 |
|---|---|
| （无参数） | 查最新版 → 升级 |
| `-Silent` | 静默安装（NSIS `/S`） |
| `-Force` | 目标版本 ≤ 当前版本也强制装（允许降级） |
| `-ProbeLatest` | 主动探测更高版本（默认已开，应对官方 feed 滞后） |
| `-DryRun` | 只检查版本/空间/占用 |
| `-RollbackOnly` | 从最近备份恢复，不升级 |
| `-NoStart` | 安装后不启动 DSH |
| `-InstallerPath <路径>` | 跳过下载，用指定安装包 |

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 升级成功 |
| 5 | 装完但有警告 |
| 6 | 升级失败，已自动回滚 |
| 7 | 升级失败且回滚也失败（需手动恢复） |
| 10 | 安装目录不存在 |
| 11 | 磁盘空间不足 |
| 12 | 无法确定目标版本 |
| 13 | 下载失败 |
| 14 | SHA512 校验失败 |
| 15 | 备份失败（保护性中止） |
| 16 | 没有备份可回滚 |
| 20 | 进程无法结束 |
| 21 | 已有实例在运行 |
| 22 | 未知参数 |
| 30 | 安装目录被占用 |

## 文件说明

| 文件 | 说明 |
|---|---|
| `DSH-AutoUpgrade-v4.ps1` | 主脚本，UTF-8 带 BOM |
| `一键升级-v4.bat` | 中文菜单启动器，UTF-8 无 BOM + CRLF |
| `bom-guard.ps1` | BOM 自愈工具（脚本被改坏 BOM 时用） |
| `README-v4.md` | 各版本修复明细 |
| `技术文档.md` | 完整技术文档：21 个问题的现象/根因/修复、注意事项、验证记录 |

## 数据安全

升级**只碰程序目录**，明确保护以下用户数据：

- `~/.dsh/sessions`
- `~/.dsh/attachments`
- `~/.dsh/.credentials.yaml`
- `~/.dsh/storages`
- `~/.dsh/skills`
- `~/.dsh/integrations`
- `~/.dsh/rewind-snapshots`
- `~/.dsh/profiles/desktop/node_modules`

只备份程序目录 + 5 个配置文件（`package.json` / `cordis.yml` / `cordis.patch.yml` / `pnpm-workspace.yaml` / `pnpm-lock.yaml`）。

备份保留最近 2 份，位置 `C:\dsh-rollback\`。

## 验证状态

在 Hyper-V 虚拟机（Windows 11 专业工作站版 Build 26300，无真实 GPU）实测四个场景全部通过：

| # | 场景 | 结果 |
|---|---|---|
| 1 | 正常升级 rc.1 → rc.2 | ✅ 退出码 0，261 秒 |
| 2 | 强制降级 rc.2 → rc.1 | ✅ 退出码 0，安装 1 次不白跑 |
| 3 | 手动回滚 rc.1 → rc.2 | ✅ 退出码 0，120 秒 |
| 4 | 最终回归 rc.1 → rc.2 | ✅ 退出码 0，445 秒，0 新崩溃 |

## 重要提醒

- **`DSH-AutoUpgrade-v4.ps1` 必须保持 UTF-8 带 BOM**。多数编辑器保存会丢 BOM，丢了会产生几十个语法错误导致脚本完全跑不起来。用 `bom-guard.ps1` 修复。
- **`一键升级-v4.bat` 必须保持 CRLF 行尾、无 BOM**。仓库已配置 `.gitattributes` 锁定这两点，请勿删除。
- **`-Force` 允许降级**。当官方 feed 版本低于当前版本时，`-Force` 会真的降级，这是设计语义。

## 已知限制

1. 虚拟机 GUI 无法通过 PowerShell Direct 观察，界面显示需人工确认。
2. `-RollbackOnly` 只回滚最近一份备份。
3. 无 GPU 环境下 DSH 固定走 Web 模式（Electron 行为），用浏览器打开 `http://127.0.0.1:<端口>/`。
4. probe 只能探测 bin 目录里真实存在的版本，无法发现尚未上传的版本。

---

完整技术文档见 [技术文档.md](技术文档.md)。
