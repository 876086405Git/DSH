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
pnpm -r pack            # 在各自目录生成 <name>-<version>.tgz
cd plugins/dsh-prompt-enhance && npm pack
```

## 安装到 DSH

```bash
# 从本地源码链接（开发态）
dsh plugin --profile desktop add link:/path/to/plugins/dsh-prompt-enhance

# 从打包产物
dsh plugin --profile desktop add ./dsh-prompt-enhance-1.1.0.tgz
```

改完插件需要重启 DSH 才生效。
