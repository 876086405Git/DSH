# DSH 插件集合

DeepSeek Harness（DSH）插件源码仓库，每个插件一个独立包。

## 目录结构

```text
plugins/
├─ dsh-prompt-enhance/     提示词增强：一键把输入框内容改写成结构化提示词
└─ dsh-checkup/     DSH体检中心：安装前预检 + 环境体检（插件 / skill / MCP）
```

## 插件列表

| 包名 | 名称 | 说明 |
| --- | --- | --- |
| `dsh-prompt-enhance` | 提示词增强 | 会话输入框的「提示词增强」按钮，生成后自动填入并可一键撤回 |
| `dsh-checkup` | DSH体检中心 | 装插件 / skill / MCP 之前先做兼容性、安全性、稳定性预检；已装项体检并给出保留 / 卸载建议 |

### DSH体检中心（`dsh-checkup`）

- **安装拦截**：包装宿主 `pluginManager.installBundle`，点安装先挂起 → 弹出检查面板 → 通过才真正安装
- **三类检查**（23 条规则）：兼容性（版本 / 平台 / 注入依赖 / bundle 声明 / peer）、安全性（安装脚本、恶意依赖名单、源码隐私与恶意特征、包名仿冒）、稳定性（入口声明、版本成熟度、依赖与体积、维护信号）
- **技能与 MCP**：`skill` 与 `MCP` 没有宿主安装 API，改为「装前检查目录 / 配置」+「已装项体检」
- **环境体检**：扫描已装插件、skill、MCP，逐项给出「保留 / 建议卸载 / 待确认」及理由
- **入口**：插件详情页配置区、市场详情页预检区、设置左侧导航「体检中心」

## 开发

每个插件目录是独立的 npm 包（`main` + `dsh.bundle.patch`），无构建步骤：

```bash
pnpm -r pack            # 在仓库根目录生成 <name>-<version>.tgz
cd plugins/dsh-checkup && npm pack
```

## 安装到 DSH

```bash
# 从本地源码链接（开发态）
dsh plugin --profile desktop add link:/path/to/plugins/dsh-prompt-enhance

# 从打包产物（pnpm -r pack 的 tgz 输出在仓库根目录；发布版 tgz 随仓库提交）
dsh plugin --profile desktop add ./dsh-prompt-enhance-1.2.0.tgz
```

改完插件需要重启 DSH 才生效。

## 测试

`dsh-checkup` 自带离线测试，不需要安装到 DSH 即可运行：

```bash
cd plugins/dsh-checkup
node test/verify.mjs                    # 兼容性规则
node test/security-stability.test.mjs   # 安全 / 稳定性规则
node test/skill-mcp.test.mjs            # skill / MCP 检查
node test/audit.test.mjs                # 环境体检判定
node test/config.test.mjs               # 配置读写
node test/offline-client-check.mjs .    # 客户端 bundle 离线自检
```

## 开发方式

本仓库插件由 **DeepSeek Harness（DSH）内的 AI 助手按需求实现**，人工负责需求定义、验收与迭代决策；代码、文档与截图由 AI 生成后经人工确认。git 历史自 2026-10-28 建立，此前 10-23 至 10-24 的开发过程未入库；`v1.1.0` 标签对应首个完整可用版本，`v1.2.0` 为当前发布版本（引用芯片保留 / 无边框透明闪烁 / Host 修复）。
