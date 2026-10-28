# DSH 插件集合

DeepSeek Harness（DSH）插件源码仓库，每个插件一个独立包。

## 目录结构

```text
plugins/
└─ dsh-prompt-enhance/    提示词增强：一键把输入框内容改写成结构化提示词
```

## 插件列表

| 包名 | 说明 |
| --- | --- |
| `dsh-prompt-enhance` | 会话输入框的「提示词增强」按钮，生成后自动填入并可一键撤回 |

## 开发

每个插件目录是独立的 npm 包（`main` + `dsh.bundle.patch`），无构建步骤：

```bash
pnpm -r pack            # 在仓库根目录生成 <name>-<version>.tgz
cd plugins/dsh-prompt-enhance && npm pack
```

## 安装到 DSH

```bash
# 从本地源码链接（开发态）
dsh plugin --profile desktop add link:/path/to/plugins/dsh-prompt-enhance

# 从打包产物（pnpm -r pack 的 tgz 输出在仓库根目录，产物不进版本库）
dsh plugin --profile desktop add ./dsh-prompt-enhance-1.1.0.tgz
```

改完插件需要重启 DSH 才生效。

## 开发方式

本仓库插件由 **DeepSeek Harness（DSH）内的 AI 助手按需求实现**，人工负责需求定义、验收与迭代决策；代码、文档与截图由 AI 生成后经人工确认。git 历史自 2026-10-28 建立，此前 10-23 至 10-24 的开发过程未入库；`v1.1.0` 标签对应首个完整可用版本。
