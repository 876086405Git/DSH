# DSH 插件集合

[![Release](https://img.shields.io/github/v/release/876086405Git/DSH?display_name=tag&label=release&color=2ea44f)](https://github.com/876086405Git/DSH/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/876086405Git/DSH/total?label=downloads)](https://github.com/876086405Git/DSH/releases)
[![Last commit](https://img.shields.io/github/last-commit/876086405Git/DSH/main)](https://github.com/876086405Git/DSH/commits/main)
[![Plugins](https://img.shields.io/badge/plugins-3-blue)](#插件列表)

DeepSeek Harness（DSH）插件源码仓库，每个插件一个独立包。

## 插件列表

| 包名 | 一句话说明 |
| --- | --- |
| [`dsh-checkup`](#dsh-checkup--dsh体检中心) | 装插件 / skill / MCP **之前先预检**，不兼容直接拦下；装完还能体检、救场、看军械库四类 |
| `dsh-prompt-enhance` | 会话输入框的「提示词增强」按钮，生成后自动填入并可一键撤回 |
| [`dsh-session-watchdog`](#dsh-session-watchdog--会话哨兵) | 实时监控会话；异常停止提醒并按**真实会话内容**自动续跑；任务完成弹窗 + 6 种叮咚提示音 |

## 目录结构

```text
plugins/
├─ dsh-checkup/            DSH体检中心：安装前预检 + 环境体检 + 军械库四类检查
├─ dsh-prompt-enhance/     提示词增强：一键把输入框内容改写成结构化提示词
└─ dsh-session-watchdog/   会话哨兵：异常停止提醒 + 真实上下文续跑 + 任务完成铃声
```

---

# dsh-checkup — DSH体检中心

## 它解决什么问题

DSH 的插件、skill、MCP 都直接写进运行环境：装错了轻则报错，重则**桌面端起不来**——
启动时崩、界面进不去、只能去翻 `crash-*.log` 才知道是哪个包干的。

这个插件把「装完才发现崩」变成「**装之前就知道为什么**」，并且在装完之后继续兜底：

- 插件安装走 `pluginManager.installBundle` → **装前拦截**，不兼容直接拒绝并列出原因
- skill / MCP 宿主根本没有安装 API（军械库是直接往目录和 `cordis.patch.yml` 里写）→ **落盘哨兵**兜底
- 已经装上的东西 → **环境体检**给「保留 / 卸载」建议，**军械库四类**逐类核查

**适用场景**：日常装插件怕崩、想清掉没用的插件 / skill、想查某个连接器为什么起不来、
或者想知道「我这台机器的 DSH 环境现在到底健不健康」。

## 主要功能

### 1. 安装前预检（拦截器）

包住宿主 `pluginManager.installBundle`，安装前读包元数据（npm registry / 本地目录 / tarball），
按 **3 类 23 条规则**判定：

| 分类 | 规则数 | 关注点 |
| --- | --- | --- |
| 兼容性 | 10 | 能否在当前 DSH 客户端正确加载（`engines.dsh`、`engines.node`、平台、客户端注入依赖、bundle 声明、peer 依赖、崩溃黑名单、重复安装、bundle 数量） |
| 安全性 | 6 | 隐私泄露 / 恶意代码（安装脚本、依赖投毒、仿冒包名、来源可信度、溯源字段） |
| 稳定性 | 7 | 运行稳定（入口点、版本声明、依赖负担、包体积、维护信息、Node 版本声明） |

结果分三档：**阻止 / 提醒 / 通过**。被阻止时抛错，错误信息自带完整原因（插件市场只会展示一行文本）。

> 读不到环境信息时不会「一刀切判死」：`dshVersion` 未知、客户端包列表为空、安装清单为空时，
> 相关规则自动降级为「提醒」——**打包版 / asar 安装环境也不会全红**。

### 2. 逐项自定义处理方式

每条检查都能单独指定「**默认 / 阻止 / 提醒 / 通过**」，不必接受规则写死的等级。
设置面板「检查规则」每行右侧有下拉，选完立刻标「自定义」，保存后写进 profile 配置：

```yaml
levelOverrides: { "runtime-version": "warn", "sec-scripts": "block" }
```

覆盖只改「怎么处理」，不改「结论是什么」，所以徽标、统计、`ok` 判定都跟着覆盖走。

### 3. 环境体检（保留 / 卸载建议）

扫已装的插件、skill、MCP，逐项给 **保留 / 卸载** 建议 + 理由。
对 `@deepseek-ai/*` 官方包有**硬保护**：永远判「DSH 内置包 · 保留」，任何情况下不建议卸载
（删了 DSH 直接起不来）。

### 4. 军械库四类检查（连接器 / 技能 / 插件 / 专家）

覆盖 `dsh-armory`（大肥鱼军械库）面板里的四类对象，每类两项共 **8 项**：

| 类 | 落盘位置 | 检查项 |
| --- | --- | --- |
| **连接器** | profile `cordis.patch.yml` 的 `dsh-mcp-client` 条目 | 配置是否完整、serverName 是否重复、启动命令是否存在 |
| **技能** | `~/.dsh/skills` 与 `~/.agents/skills` | 是否有 `SKILL.md`、是否跨根重名 |
| **插件** | profile `dsh.profile.bundles` + `node_modules` | 登记了是否真有实体（symlink 也算）、是否重复登记 |
| **专家** | profile 的 `dsh-agent-preset` 行 | id 规范 / 名称非空 / 人设正文非空、是否引用了已卸载的插件 |

### 5. 实时哨兵（skill / MCP 落盘兜底）

`skill` 和 `MCP` 的安装不经过 `installBundle`，所以额外 watch 文件系统：

- 新 skill 目录落盘 → 数秒内自动检查；命中恶意脚本特征 → **移入隔离区**（可放行 / 删除）
- 新 MCP 条目落盘 → 结构性问题（缺 `command` 等）→ **自动从配置摘除**，摘除前留 `.checkup.bak`
- 每条结果都会在右下角弹一条提示：✅ 通过 / ⚠️ 提醒 / ⛔ 已拦截

> 落盘后会自动检查，**通过也会提示**——早前版本通过时静默，用户以为「没检查」。

## 使用方法

装好后打开 **设置 → 体检中心**（左侧导航，护盾图标），面板分 9 个区块：

| 区块 | 用途 |
| --- | --- |
| 总览 | 当前生效状态与环境（DSH 版本、Node 版本、客户端包数、bundles 数） |
| 拦截设置 | 安装预检总开关、提醒项是否也算不通过 |
| 检查规则 | 23 条规则一览，逐项可改处理方式 |
| 包源与读取 | registry 顺序、超时、重试次数 |
| 崩溃黑名单 / 恶意依赖名单 | 命中即阻止的包名清单 |
| Skill / MCP 检查 | 装前手动检查一个 skill 目录或一份 MCP 配置 |
| 实时拦截哨兵 | 最近的落盘事件 + 隔离区（可放行 / 删除） |
| 军械库四类检查 | 一键扫描四类对象，8 项结果 |
| 环境体检 / 安装插件 / 最近记录 | 保留或卸载建议、面板内预检并安装、最近 50 次检查记录 |

**典型流程**：插件市场点「安装」→ 被拦下 → 面板弹确认 → 看报告决定「仍然安装」或「取消」。
也可以在面板里手动填包名预检，通过后再点「开始安装插件」。

## 安装

插件是标准 DSH bundle 包，装进 profile 后重启桌面端生效：

```bash
# 方式一：从仓库里的发布包
dsh plugin --profile desktop add ./dsh-checkup-0.3.4.tgz

# 方式二：从本地源码（开发态）
dsh plugin --profile desktop add link:/path/to/plugins/dsh-checkup
```

桌面端 profile 由 Electron 独占管理，直接 `dsh plugin --profile desktop add` 可能被拒；
此时在 `~/.dsh/profiles/desktop` 里用 `pnpm` 装包，再把 `dsh-checkup` 追加进
`package.json` 的 `dsh.profile.bundles`，然后重启。

**卸载**：从 `dsh.profile.bundles` 移除并卸载包，拦截器随插件卸载自动还原宿主原方法。

## 依赖与兼容性

| 项 | 要求 | 说明 |
| --- | --- | --- |
| DSH | `>=0.2.0` | 用到了 `pluginManager.installBundle` 与 web 路由 |
| Node | `>=18` | 用到 `randomUUID`、可选链等 |
| `yaml` | `^2.9.0` | 解析 profile 的 `cordis.patch.yml`（保留注释） |
| 宿主服务 | 全部可选 | `pluginManager` / `webServer` 用 `ctx.inject` 延迟获取，缺了只降级不崩 |

数据落在 `~/.dsh/checkup/`：`history.json`（最近 50 次检查记录）与 `quarantine/`（隔离区）。

## 配置

配置写在 profile 的 `cordis.patch.yml` 里（条目 id `checkup`）：

```yaml
- insert:
    - id: checkup
      name: dsh-checkup
      config:
        preflightEnabled: true          # false = 只记录不阻断
        blockOnWarn: false              # true = 有 warn 也拒绝安装
        registries:
          - https://registry.npmmirror.com
          - https://registry.npmjs.org
        lookupTimeoutMs: 8000           # 单个源单次读取上限（1000–60000）
        lookupAttempts: 2               # 同一源的重试次数
        knownBad: []                    # 例：["dsh-broken-plugin@0.1.2"]
        maliciousPackages: []           # 例：["evil-pkg"]，命中直接阻止
        levelOverrides: {}              # 例：{"runtime-version": "warn"}
        confirmTimeoutMs: 180000        # 市场点安装后等面板确认的最长时间
```

面板里改完点保存就会写回该文件（写前留 `.checkup.bak`）。

## 本地 HTTP 接口

面板通过这些接口与宿主通信（全部有来源校验：带 `Origin` 时必须是非跨源的本机页面，否则 403；
请求体上限 1 MB）：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api-checkup/state` | 环境摘要 + 规则 + 最近记录 |
| GET/POST | `/api-checkup/config` | 读 / 写配置 |
| GET | `/api-checkup/pending` | 被拦下等待确认的安装 |
| POST | `/api-checkup/confirm` | 确认或拒绝挂起请求 |
| POST | `/api-checkup/check` | 手动预检（返回一次性 `approvalToken`） |
| POST | `/api-checkup/install` | 执行安装（必须携带 token，否则 409） |
| POST | `/api-checkup/check-skill` | 检查 skill 目录（限两个 skills 根内） |
| POST | `/api-checkup/check-mcp` | 检查 MCP 配置 |
| GET | `/api-checkup/inventory` | 已装 skill / MCP 快照 |
| GET | `/api-checkup/armory` | 军械库四类结果 |
| GET | `/api-checkup/audit` | 环境体检（保留 / 卸载建议） |
| GET | `/api-checkup/guard` | 哨兵事件与隔离区 |
| POST | `/api-checkup/guard/release` | 隔离项放行 / 删除（路径越界 403） |

## 自检

仓库里带 13 套离线自检（254 项断言），改完代码跑一遍不用重启桌面端：

```bash
cd plugins/dsh-checkup
DSH_APP_DIR="<DSH 安装目录>/resources/app" node test/verify.mjs
# 其余套件见 test/ 目录，完整清单与验证基线见 plugins/dsh-checkup/README.md
```

插件本身的详细文档（规则逐条说明、槽位注册踩坑记录、开发全过程 51 个问题与解法）
见 [`plugins/dsh-checkup/README.md`](plugins/dsh-checkup/README.md)。

---

# dsh-prompt-enhance — 提示词增强

会话输入框加一个「提示词增强」按钮：把当前输入改写成结构化提示词，生成结果自动填入输入框，
可一键撤回恢复原文。1.5.0 起支持深度理解上一条消息、并严格执行字数上限（150～800 字）。
发布包：`dsh-prompt-enhance-1.5.0.tgz`。

---

# dsh-session-watchdog — 会话哨兵

## 它解决什么问题

DSH 的一次 turn 可能因为模型报错、限流、进程被杀、输出超长或长时间无响应而中断；人不在电脑前时，
会话就停在半路，任务没人接。会话哨兵做三件事：

1. **看得见**：宿主侧订阅 `session/event`，用「turn 结束原因 + 假死心跳 + 启动恢复」三通道判定异常停止；
2. **叫得应**：页面卡片、侧栏徽标、系统通知；**任务正常完成也会弹窗并播放叮咚提示音（6 种可选）**；
3. **接得上**：从该会话的**真实对话原文、未完成待办、目标、最后动作与错误**生成续跑指令（默认交给该会话自己的模型来写，失败自动回落到上下文拼装），走与 GUI 发消息相同的 `sessionController.prompt` 通道投递。

## 主要功能

### 1. 停止判定（三通道）

| 通道 | 依据 | 说明 |
| --- | --- | --- |
| turn 结束原因 | `turn/end.reason.kind` | `error` / `interrupted` / `max-tokens` / `blocked` 视为异常；`completed` 完成提醒；`aborted` 默认静默 |
| 假死心跳 | 运行中但长期无会话事件 | 无未完成工具 10 分钟、有未完成工具 15 分钟；每个 turn 只报一次；默认只提醒不自动续跑 |
| 启动恢复 | 状态文件 + `sessionQuery` 扫描 | 上次退出时 turn 未闭合记为 `interrupted`；历史遗留会话默认只提醒 |

误报控制：等待用户审批（`approval/asked` 未决）、用户手动继续（新 `turn/start`）、子代理会话（默认不监控）、排除目录/会话都按规则放行或静默。

### 2. 提醒：页面卡片 + 徽标 + 系统通知 + 提示音

- 异常提醒卡片带「续跑」「忽略」；完成提醒卡片只带「忽略」，**永不自动续跑**；
- 卡片固定在**右下角**、从下往上堆叠并置于最顶层；卡片与系统通知里的会话名与会话列表**完全一致**（取 `displayTitle`），不出现「未命名」；
- 侧栏徽标：红=异常、黄=续跑中、绿=已恢复/已完成（30s 自清）；
- 系统通知：页面隐藏时发送，点击跳回对应会话；
- 提示音：6 种 Web Audio 合成音色（叮咚（双音）/ 清脆双击 / 轻快三连音 / 水滴 / 柔和小铃 / 电子脉冲）+ 关闭，音量 0-100 可调，设置里可试听。

### 3. 依据真实内容续跑

- 事实来源：该会话最近 400 条事件里的真实对话原文（最近 10 条）、未完成 todo、目标、最后工具动作、最后错误、cwd；
- 两种生成方式：`llm`（默认，用该会话的 provider/model 生成，禁止套模板/编造）与 `context`（不上模型，用真实内容拼装）；
- 续跑前安全检查：等用户审批时暂停、cwd 不存在不续跑、子代理不续跑、同判定幂等、每会话 2 次/30min、全局 5 次/10min、连续失败 3 次熔断；
- 3 秒延时，期间用户手动继续会自动撤销。

### 4. v0.3.1 ~ v0.3.3 修复记录

- **v0.3.1 崩溃修复**：续跑路径直接读未注入的 `ctx.llm` 会抛 `CordisError`，未捕获异常导致宿主
  `fatal load failure`、桌面端重启。改为 `ctx.get()` 读可选服务 + 续跑全 try/catch + `fireResume` 兜底。
- **v0.3.2 恢复上下文**：宿主重启后自动续跑会先用 `sessionQuery` 补读真实会话日志再生成指令，不再出现
  「没有可用的对话记录」；完成卡片改右下角、会话名与会话列表一致、层级置顶。
- **v0.3.3 摘要修复**：正常完成的卡片不再把历史工具错误码（如 `CODE_RUN_FAILED`）拼进摘要，
  仅异常停止时显示并标注「最近工具失败 <code>」。

### 5. 设置面板

**设置 → 会话哨兵**，四组：提醒开关（含完成提醒 / 提示音 / 音量）、监控内容规则（含续跑指令生成方式）、监控范围（目录与会话白名单/黑名单）、阈值与预算。保存后**即时生效**（写入 `~/.dsh/session-watchdog/config.json`，优先级高于 profile 的静态 config）。

## 安装与使用

```bash
# 方式一：仓库根目录的发布包
dsh plugin --profile desktop add ./dsh-session-watchdog-0.3.3.tgz

# 方式二：本地源码（开发态）
dsh plugin --profile desktop add link:/path/to/plugins/dsh-session-watchdog
```

装好后打开 **设置 → 左侧「会话哨兵」**。默认已完成：完成提醒开、叮咚音、音量 70、续跑指令用模型生成。

## 依赖与兼容性

| 项 | 要求 | 说明 |
| --- | --- | --- |
| DSH | 0.2.2-rc.1（实测） | 使用 `session/event`、`ctx.agents`、`sessionController.prompt`、`ctx.llm`、`webServer` 路由 |
| Node | >= 22.19 | 插件为 ESM，无构建步骤 |
| 宿主服务 | 全部惰性获取 | `sessionController` / `webServer` / `ctx.llm` / `sessionQuery` 缺了自动降级 |

## 验证

```bash
cd plugins/dsh-session-watchdog
node --test                                # 59 项单测/集成/前端假环境自测
node test/client-settings.selftest.mjs     # 设置面板 19 项断言
node test/client-sound.selftest.mjs        # 完成提醒与铃声 11 项断言
```

反向插桩脚本 `test/mutation-check.ps1`（Windows PowerShell）证明关键断言可杀死 A~J 共 10 类变异体。

## 配置

配置写在 profile 的 `cordis.patch.yml`（条目 id `dsh-session-watchdog`），或直接在设置面板改（写 `config.json`，优先级更高）：

```yaml
- insert:
    - id: dsh-session-watchdog
      name: dsh-session-watchdog
      config:
        autoResume: true
        notifyOnCompletion: true
        completionSound: dingdong
        completionVolume: 70
        resumePromptMode: llm
```

数据落在 `~/.dsh/session-watchdog/`：`state.json`（运行态/未闭合 turn）、`config.json`（运行时配置）。

## 文档与截图

- [设计说明](plugins/dsh-session-watchdog/docs/01-设计说明.md)
- [实现方案](plugins/dsh-session-watchdog/docs/02-实现方案.md)
- 真机截图：[基础设置](plugins/dsh-session-watchdog/docs/preview/截图1-提醒开关.png)、[完成提醒与提示音](plugins/dsh-session-watchdog/docs/preview/截图6-任务完成提醒与提示音.png)、[续跑指令生成方式](plugins/dsh-session-watchdog/docs/preview/截图7-续跑指令生成方式.png)、[完成卡片右下角真机验证](plugins/dsh-session-watchdog/docs/preview/实测-完成卡片右下角.png)

---

## 开发

每个插件目录是独立的 npm 包（`main` + `dsh.bundle.patch`），无构建步骤：

```bash
pnpm -r pack            # 在仓库根目录生成 <name>-<version>.tgz
cd plugins/dsh-checkup && npm pack
```

## 安装到 DSH

```bash
# 从本地源码链接（开发态）
dsh plugin --profile desktop add link:/path/to/plugins/dsh-checkup

# 从打包产物（pnpm -r pack 的 tgz 输出在仓库根目录；发布版 tgz 随仓库提交）
dsh plugin --profile desktop add ./dsh-checkup-0.3.4.tgz
```

改完插件需要重启 DSH 才生效。

## 开发方式

本仓库插件由 **DeepSeek Harness（DSH）内的 AI 助手按需求实现**，人工负责需求定义、验收与迭代决策；
代码、文档与截图由 AI 生成后经人工确认。git 历史自 2026-10-28 建立，此前 10-23 至 10-24 的开发过程未入库；
`dsh-prompt-enhance` 的 `v1.1.0` 标签对应首个完整可用版本；`v1.2.0` 补上引用芯片保留与无边框闪烁；
`v1.5.0` 为当前发布版本（深度理解上一条消息 / 严格执行字数上限 / 超限自动压缩重写 + 兜底截断）。
