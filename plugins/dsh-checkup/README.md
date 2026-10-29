# DSH体检中心（dsh-electron-dog / 包名 dsh-checkup）

在 DeepSeek Harness 里安装 **插件 / skills / MCP** 之前先做一次兼容性预检：不兼容直接拒绝并列出原因，
避免"装完才发现桌面端起不来、重启崩、进不去应用"。

## 为什么需要它

宿主自身的 `pluginManager.inspect()` 只覆盖：spec 能否解析、包是否存在、`engines` 与
`peerDependencies` 的粗检。真正把桌面端搞崩的，通常是它**不检查**的这几类：

| 崩溃原因 | 宿主原生检查 | 本插件 |
| --- | --- | --- |
| `dsh.client.inject` 指向当前版本不存在的 UI 包（boot 直接失败 → 宿主自杀重启） | ❌ | ✅ 逐项核对宿主 `@deepseek-ai/*` 包清单 |
| `dsh.bundle.patch` 字段存在但路径缺失 / 构建产物不完整 | ❌ | ✅ 声明校验 |
| `dsh.client.platform` 不是 `web`（desktop 端只加载 web） | ❌ | ✅ 平台校验 |
| 插件未声明 `engines.dsh`（版本适配未知） | ❌ 静默放行 | ✅ 明确提醒 |
| peer 依赖逐条版本偏差明细 | 部分 | ✅ 逐条列出当前版本 vs 要求 |
| 已知会拖垮桌面端的版本 | ❌ | ✅ 可配置黑名单 |
| bundle 数量逼近上限（boot 失败后难定位） | ❌ | ✅ 软阈值提醒 |

## 发布前自检清单（必查）

> 以下两条是 2026-10-29 在本插件上**真实踩过**的坑，每条都能让桌面端**完全起不来**。
> 宿主弹窗只显示一行被转述过的错误，真正原因要去 `logs/crash-*.log` 里翻。

### 1. 声明了 `dsh.client` → 必须给 `exports["./client"]`

```json
{
  "exports": {
    ".": "./lib/index.js",
    "./client": "./lib/client.js",
    "./package.json": "./package.json"
  }
}
```

- `dsh.client` 一旦存在，宿主 `modules`（**required** 插件）就会去 `package.json` 的
  `exports["./client"]` 找客户端 bundle，找不到直接抛：
  `client-modules: <包名> declares dsh.client but exports no "./client" bundle`
- 该错发生在 **host 启动阶段**，`modules` 是 required → **abort 整个启动**；
  GUI 只会显示 `Plugins waiting for services (1): client-hmr → clientModules`，
  **极具误导性**（别去查 hmr，那不是根因）。
- `"."` 不能漏：宿主靠 `import('<包名>')` 加载 host 侧，漏了就是「客户端修好、服务端崩」。

### 2. 用了 `ctx.X` → `inject` 必须含 `X`

| 客户端用了 | `inject` 必须含 |
| --- | --- |
| `ctx.slots.*` | `'slots'` |
| `ctx.sessions.*` | `'sessions'` |
| `ctx.locale.*` | `'locale'` |
| `ctx.uiWorkspace.*` | `'uiWorkspace'` |

漏声明时 cordis 的 Proxy `get` trap 直接抛（`cordis/lib/index.js`）：

```text
Error: cannot get property "slots" without inject
```

表现为 **web boot 阶段** `1 entry did not activate: <包名>: failed`。
这一层不 abort 启动，但插件功能**全部失效**。

> **host 侧相反**：`inject` 保持 `[]`，可选服务（`pluginManager` / `webServer`）用
> `ctx.inject(['x'], cb)` **延迟注入** —— 服务缺失时只是不启用该能力，不影响启动。

### 3. 离线自检（不用反复重启桌面端）

```js
// vm 里 mock loader + react，加载 client.js 后手动 apply，可离线复现 activate 失败
const fs = require('fs'), vm = require('vm')
let entry
const sandbox = { window: { __ModuleLoader__: { load: (e) => { entry = e } } }, console }
vm.createContext(sandbox)
vm.runInContext(fs.readFileSync('lib/client.js', 'utf8'), sandbox)

const mod = entry.factory((s) => s === 'react' ? {
  createElement: () => null, useState: (v) => [v, () => {}], useEffect: () => {},
  useCallback: (f) => f, useMemo: (f) => f(), useRef: (v) => ({ current: v }),
} : (() => { throw new Error('未预期的 require: ' + s) })())

console.log('inject =', mod.inject)   // 必须覆盖 apply 里用到的所有 ctx.X
mod.apply({ slots: { inject: (_, f) => f(), register: () => ({}) } }) // 不抛即通过
```

## 故障案例与修复（2026-10-29 实录）

> 本插件首次安装后**连崩两次**，两层各藏一个 bug，修掉第一层才露出第二层。
> 这里保留完整现象 / 根因 / 修复，方便以后遇到同类弹窗**对号入座**。

### 症状对照表

| 弹窗主文案 | crash 日志里的真凶 | 出问题的层 | 根因 | 修复 |
| --- | --- | --- | --- | --- |
| `Plugins waiting for services (1): client-hmr → clientModules` | `client-modules: dsh-checkup declares dsh.client but exports no "./client" bundle` | **host**（`phase: startup`） | `package.json` 缺 `exports["./client"]` | 补 `exports` 三项 |
| `web boot: 1 entry did not activate`<br>`dsh-checkup: failed` | `cannot get property "slots" without inject`（cordis 内部） | **web**（`phase: running`） | `client.js` 的 `inject = []` 却调 `ctx.slots` | `inject` 改 `['slots']` |

**关键**：第一行的 `client-hmr` 是**级联受害者**，不是根因。它只是在等 `clientModules` 服务，
而那个服务因为 `modules`（required）加载失败而没有出现。**看到 `client-hmr` 不要查 hmr。**

### 诊断流程（可复用）

```text
1. 读弹窗给的 crash 日志路径（%APPDATA%\@deepseek-ai\dsh-desktop\logs\crash-*.log）
2. 看头部三行：source（host / web-boot）/ phase（startup / running）/ app 版本
3. 直接跳到 "--- error ---" 段，抓第一条 Error 的 message
4. 按 message 里的源码路径定位（本仓库相关两处）：
     dsh-client-modules/lib/index.js:737-738   → exports["./client"] 缺失
     cordis/lib/index.js Proxy get trap         → inject 未声明就访问 service
5. 改完用上文「3. 离线自检」跑一遍，再重启桌面端
```

### 为什么改一处不生效

`package.json` 里是 `"dsh-checkup": "file:E:/kaifa/DSH-KAIFA/dsh-checkup"`，
pnpm 装进 profile 后是**实体副本**（不是软链）：

```text
E:\kaifa\DSH-KAIFA\dsh-checkup\                      ← 源（作者维护）
C:\Users\Administrator\.dsh\profiles\desktop\node_modules\dsh-checkup\   ← 生效副本
```

两处**内容相同但各自独立**，必须**同时改**，否则改了源不生效、改了副本重装又复发。

### 时间线

| 时间 | 事件 |
| --- | --- |
| 09:41 | 插件装进 profile（`file:` 依赖，产生实体副本） |
| 09:43 / 09:44 | 重启 → 连续两份 `crash-*-host.log`，`startup failed: 1 required plugin did not activate` |
| 10:0x | 补 `package.json` 的 `exports` → **能进界面了**，但立刻报 `web boot: 1 entry did not activate` |
| 10:0x | `inject` 补 `'slots'` → 正常启动 ✅ |
| 10:04 | 人工确认应用可正常启动 |

### 教训

1. **插件的错误会分层暴露**：先 host（`package.json` 声明）→ 再 web（client bundle 运行时依赖）。
   修好一层才会看到下一层，别以为改完一处就完事。
2. **弹窗文案是转述过的**，可能指向级联受害者。**永远以 `crash-*.log` 的 `--- error ---` 为准。**
3. **静态自检比启动试错快 100 倍**：一次 `electron` 启动崩掉要 1 分钟且要人工看弹窗，
   `vm` 脚本几百毫秒就能判定 `exports` / `inject` 是否配齐。
4. 本插件的存在意义就是「装之前拦住会崩的项」，**它自己必须先过这关**。

## 拦截点

```text
插件市场 / 插件管理器 UI
        │  RPC
        ▼
pluginManager.installBundle(spec)      ← 本插件在此处包装
        │ 1. 预检（HTTP 读 package.json + 本机版本）
        │ 2. 不通过 → 抛 ElectronicDogBlocked（带完整 report）
        ▼
      pnpm 安装（仅当预检通过）
```

- 拦截器在 host 侧：`ctx.inject(['pluginManager'])` 拿到服务实例后包装 `installBundle`，
  用 `ctx.effect` 注册还原函数，卸载插件即恢复原方法。
- 预检不依赖 `pnpm` 可执行文件：直接 HTTP 读 registry 的 `package.json`（默认 npmmirror → npmjs 兜底）。
- 记录写 `~/.dsh/checkup/history.json`（最近 50 条，权限 600）。

## 检查项（三大分类）

检查结果按 **兼容性 / 安全性 / 稳定性** 三类组织，面板与浮层都按分类分组展示。

### 兼容性（compatibility）— 能否在当前 DSH 客户端环境正确加载

| id | 级别 | 检查内容 |
| --- | --- | --- |
| `spec` | pass | 安装目标可解析（包名 / 版本 / 本地路径 / git） |
| `runtime-version` | block | 插件声明的 `dsh.engines.dsh` 是否满足当前桌面端版本 |
| `node-engine` | warn | `engines.node` 与内置 Node |
| `client-platform` | block | `dsh.client.platform` 必须是 web |
| `client-inject` | block | `dsh.client.inject` 的包必须在当前版本存在（boot 崩溃主因） |
| `bundle-declared` | block | `dsh.bundle.patch` 路径必须存在 |
| `peer-deps` | warn | peer 依赖逐条版本比对 |
| `known-bad` | block | 崩溃黑名单命中 |
| `duplicate` | warn | 已在 profile bundles 中 |
| `bundle-load` | warn | 接近 bundle 数量软上限 |

### 安全性（security）— 隐私泄露 / 恶意代码 / 病毒代码

| id | 级别 | 检查内容 |
| --- | --- | --- |
| `sec-scripts` | block | 安装钩子里的下载即执行（`curl\|sh`、`wget\|sh`）、PowerShell `-EncodedCommand`、`base64 -d \| sh`、`certutil -urlcache`、`mshta/bitsadmin/regsvr32`、`rm -rf /` |
| `sec-deps` | block | 依赖命中 `maliciousPackages` 名单（支持 scope 前缀） |
| `sec-typosquat` | warn | 包名与已装插件仅差一个字符（抢注 / 仿冒风险） |
| `sec-source` | block/warn | 源码特征：读取 `.ssh` 私钥 / `.aws` 凭据 / 浏览器 Cookie、`process.env` 外传、`base64 + eval`、子进程下载执行、shell 拼接 |
| `sec-traceability` | warn | 缺 `repository` / `author`，出问题无法追责 |

> 源码扫描只对**本地目录安装**生效（能读到文件）；registry 包只扫 `package.json`。
> 扫描上限：400 个文件、单文件 512 KB、跳过 `node_modules/.git/dist/build`。

### 稳定性（stability）— 运行稳定 / 潜在 bug 风险

| id | 级别 | 检查内容 |
| --- | --- | --- |
| `st-entrypoints` | block | 声明了 `dsh.client` 却没有 `exports["./client"]`（宿主会启动失败），或缺 main/exports |
| `st-version` | warn | `0.0.x` 或预发布版本（alpha/beta/rc/canary） |
| `st-deps-weight` | warn | 运行时依赖 > 60 个 |
| `st-package-size` | warn | 解包体积 > 30 MB |
| `st-maintenance` | warn | 缺 `license` / `repository`（维护信号弱） |
| `st-engine-declared` | warn | 未声明 `engines.node` |

每条返回 `{ id, category, level, title, detail, hint }`；任何 `block` 即拒绝安装。
`summarize()` 另给出 `byCategory` 统计（每类的阻止 / 提醒 / 通过数）。

## Skill 与 MCP（没有安装 API，靠检查 + 体检覆盖）

宿主对这两类**没有安装入口**，所以体检中心不拦截、只做检查：

| 类型 | 事实 | 体检中心做了什么 |
| --- | --- | --- |
| skill | 就是一个目录（`~/.dsh/skills/<name>/`），文件系统 provider 扫描发现；`dsh-skill` 的 `create()` 是 provider 工厂、`dsh-skill-filesystem` 的 `add()` 是 watch root，都不是安装 | `POST /check-skill` 装前检查目录；`GET /inventory` 体检已装 skill |
| MCP | 是 profile 配置（`cordis.patch.yml` 的 `@deepseek-ai/dsh-mcp-client` 条目），改完重启生效，无 API | `POST /check-mcp` 检查一条配置；`GET /inventory` 体检已配 MCP |

### skill 检查（`lib/skill.js`）

| id | 级别 | 内容 |
| --- | --- | --- |
| `sk-manifest` | 阻止 / 提醒 | 必须有 SKILL.md；frontmatter 要有 name + description |
| `sk-name` | 提醒 | 命名规范、与已装 skill 重名 |
| `sk-scripts` | 阻止 / 提醒 | skill 内 `.js/.py/.sh/.ps1` 的隐私读取、下载即执行、混淆执行 |
| `sk-instructions` | 提醒 | SKILL.md 里教用户 `curl \| sh`、PowerShell 编码命令等 |
| `sk-deps` | 通过 | 是否有 requirements.txt / package.json |
| `sk-size` | 提醒 | 文件数 > 500 |

### MCP 检查（`lib/mcp.js`）

| id | 级别 | 内容 |
| --- | --- | --- |
| `mcp-shape` | 阻止 | transport ∈ {stdio, sse, streamable-http}；stdio 必须有 command |
| `mcp-servername` | 提醒 | `^[A-Za-z0-9_-]{1,32}$`、不能与现有 MCP 重名（工具前缀 `mcp__<name>__*`） |
| `mcp-command` | 阻止 | 启动命令在 PATH / 绝对路径上是否存在 |
| `mcp-package` | 提醒/通过 | npm 包（npx）→ 复用插件整套规则预检；python 包（uvx）只校验命令与参数 |
| `mcp-env-secret` | 提醒 | env 里明文写 API key/token（建议 `${ENV}` 引用） |
| `mcp-known-bad` | 阻止 | serverName / 包 / 程序名命中黑名单 |

## 设置面板

入口：**设置 → 插件 → dsh-checkup（DSH体检中心）**，挂在 `plugins.bundle.config` 槽。

| 分组 | 可改 | 对应能力 |
| --- | --- | --- |
| 总览 | 只读 | 当前是否拦截、DSH 版本、Node、客户端包数、bundles 数 |
| 拦截设置 | ✅ `preflightEnabled` / `blockOnWarn` | 控制 `installBundle` 拦截器开关，以及「提醒级也拦」的严格模式 |
| 检查规则 | 只读 | 列出 10 条规则并标注「阻止 / 提醒」 |
| 包源与读取 | ✅ `registries` / `lookupTimeoutMs` / `lookupAttempts` | 预读 package.json 的镜像顺序、单次超时、每源重试次数 |
| 崩溃黑名单 | ✅ `knownBad` | 命中即阻止安装的包（包名或 包名@版本） |
| 手动预检 | 工具 | 调 `POST /api-checkup/check`，不改环境只跑一次 |
| 最近记录 | 只读 | 最近 10 条预检历史（最多留 50 条） |

**保存机制**：`POST /api-checkup/config` → 校验 → 备份 `cordis.patch.yml.checkup.bak` →
把 `- id: checkup` 的 `config` 写成单行 JSON（YAML 超集）→ 立即更新内存配置。
只改自己这一条，其余条目字节级不变。

**校验规则**：`registries` 必须 http(s) 且非空（去重、去尾斜杠）；`lookupTimeoutMs` 1000–60000；
`lookupAttempts` 1–5；`knownBad` 去空白去重；布尔项必须是布尔。

## 配置（`cordis.patch.yml`）

```yaml
- insert:
    - id: checkup
      name: dsh-checkup
      config:
        registries: [https://registry.npmmirror.com, https://registry.npmjs.org]
        lookupTimeoutMs: 15000
        knownBad: []        # 例：["dsh-broken-plugin@0.1.2"]
        blockOnWarn: false  # true = 有 warn 也拒绝
```

## 安装

```powershell
# 1. 装包（本地目录方式）
$node = 'C:\Users\Administrator\AppData\Local\Programs\DeepSeek Harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe'
$pnpm = 'C:\Users\Administrator\AppData\Local\Programs\DeepSeek Harness\resources\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.mjs'
& $node $pnpm --dir "$env:USERPROFILE\.dsh\profiles\desktop" add "file:E:\kaifa\DSH-KAIFA\dsh-checkup"

# 2. 加进 bundles（无 BOM，务必用 Node 写）
#    dsh.profile.bundles 末尾追加 "dsh-checkup"

# 3. 重启桌面端；设置 → 插件 → dsh-checkup 可见面板
```

## HTTP 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api-checkup/state` | 环境摘要 + 规则 id + 最近记录 |
| POST | `/api-checkup/check` | 手动预检 `{ spec }` → `{ ok, report }` |

## 卸载

从 `dsh.profile.bundles` 移除 `dsh-checkup` 并 `pnpm remove dsh-checkup`，
拦截器随插件卸载自动还原。
