# DSH体检中心（包名 `dsh-checkup`，旧名 `dsh-electronic-dog`）

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

`package.json` 里是 `"dsh-checkup": "file:<你的插件源目录>"`（下面用 `$repo` 表示），
pnpm 装进 profile 后是**实体副本**（不是软链）：

```text
<你的插件源目录>\                                    ← 源（作者维护）
%USERPROFILE%\.dsh\profiles\desktop\node_modules\dsh-checkup\   ← 生效副本
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

## 开发全过程：问题与解决方案总览

> 从 0.0.1 到 0.3.3 一共踩过 30 多个坑。按类别列在这里，每条都是「现象 → 根因 → 解法」，
> 遇到同类弹窗直接对号入座，不用重新排查。

### A. 加载与槽位（最容易连环踩）

| # | 现象 | 根因 | 解法 |
| --- | --- | --- | --- |
| A1 | host 启动失败：`waiting for services (1): client-hmr → clientModules` | `package.json` 声明了 `dsh.client` 却没有 `exports["./client"]` | `exports` 必须含 `"."` / `"./client"` / `"./package.json"` 三项 |
| A2 | `web boot: 1 entry did not activate` | client 里用了 `ctx.slots` 但 `inject` 没声明 `slots` | 用到的每个 `ctx.X` 都要写进 `inject` |
| A3 | 面板完全不渲染，无任何报错 | `package.json` 缺 `dsh.client.inject`，boot manifest 里这条 entry 没有 `inject` 字段，客户端激活被静默跳过 | `dsh.client: { platform: "web", inject: [...] }` 三项都要写 |
| A4 | `plugins.bundle.config` 不出现 | 该槽是 keyed 型，注册时缺 `key` | 补 `key`（与插件名一致） |
| A5 | `plugins.row.config` 不出现 | 同上，keyed 型 | 补 `key`，格式 `<插件名>#<行 id>` |
| A6 | `settings.section` 不出现 | 缺 `id` / `order` / `label` 任一 | 三项齐全，`label` 用函数返回字符串 |
| A7 | `plugins.detail.section` 静默消失 | 这个槽是 **list 型**，每条必须带 `id` | 补 `id`（如 `dsh-checkup/preflight`）+ `order` |
| A8 | `shell.overlay` 注册被吞 | 缺 `id`，或两个 overlay 用了同一个 `id` | 每个 overlay 唯一 `id`（本插件用 `checkup-confirm` 与 `checkup-sentinel-toast`） |
| A9 | 确认浮层被 DSH 的弹窗盖住 | 槽容器形成了新的 stacking context，`z-index` 再大也压不过祖先 | 不用 `h()` 渲染，改为**原生 DOM 挂到 `document.body`** 并用高 `z-index` |
| A10 | 徽标显示「❌ 0 项阻止」 | profile 里残留了测试期的 `blockOnWarn: true` | 徽标文案区分「❌ N 项阻止」与「⚠️ 严格模式拦截 · N 项提醒」；配置回写默认 `false` |
| A11 | 设置导航两项图标不对（浏览器 / 体检中心） | 导航图标由 shell 的 `navIcon(id)` 硬编码，插件无法声明 | `MutationObserver` 打补丁，按 `textContent` 匹配后替换 `<svg>` 的 `path`，并打 `data-ed-nav-icon` 标记防重复 |

**通用教训**：插件的加载错误**分层暴露** —— 先 host（`package.json` 声明），再 web（client 运行时依赖）。
修好一层才会看到下一层，别以为改完一处就完事。弹窗文案是转述的，**永远以 `crash-*.log` 的 `--- error ---` 为准**。

### B. 环境探测与降级（打包版才会踩）

| # | 现象 | 根因 | 解法 |
| --- | --- | --- | --- |
| B1 | 打包版里 `dshVersion` 显示 `0.0.0`、`clientPackages = 0` | 宿主安装在 `resources/app.asar`，插件只找了 `resources/app` | 候选路径同时尝试 `app` 与 `app.asar`（Electron 内 asar 透明挂载，`existsSync('<x>/app.asar/package.json')` 可直读） |
| B2 | 所有插件都被判「版本不兼容」并拒绝安装 | `dshVersion` 读不到时按 `0.0.0` 比对，任何 `engines.dsh` 都不满足 | 增加「降级探测」：`dshVersionKnown === false` 时该规则转 **warn「无法核对 DSH 版本」**，不 block |
| B3 | 所有带 `dsh.client.inject` 的插件都被判「依赖不存在」 | `clientPackages` 为空集合时逐项判定必然缺失 | 包列表为空 → warn「无法核对客户端注入依赖」，不 block |
| B4 | peer 依赖全报「未安装」 | 安装清单读不到时 `installedVersions` 为空 | 清单为空 → 跳过该项，不再断言「未安装」 |

**教训**：**探测失败 ≠ 环境不合格**。凡是「读不到 → 判死」的规则，都要区分「确定不兼容」和「没查到」，
后者只能给提醒，否则打包版一装就是全红。降级保护必须配**反向插桩测试**：信息齐全时该判死还得判死。

### C. 误报（体检类功能的最大风险）

| # | 现象 | 根因 | 解法 |
| --- | --- | --- | --- |
| C1 | `@deepseek-ai/dsh-base`、`dsh-web-app` 被判「实体缺失，建议删除」 | 采集时没检查宿主 `app/dsh/node_modules`，且把官方包当第三方 | **官方包硬保护**：`@deepseek-ai/*` 永远判「DSH 内置包 · 保留」，任何情况不建议卸载；采集端 `inNodeModules` 对官方包兜底为 true |
| C2 | python 包被拿去 npm registry 查，报「包不存在」 | 没判断包来源类型 | 只有 npm 来源才查 registry，其余标注「不适用」 |
| C3 | skill 自己和自己算重名 | 扫描时把被检目录自身也计入 | 排除 `selfName` |

**教训**：这条风险最高 —— C1 一旦被用户照做删掉内置包，DSH 直接起不来。
**给用户的「删除建议」必须极保守**，并给不可绕过的硬保护。新增保护后必须反向插桩：第三方缺失仍要判卸载。

### D. 功能缺陷

| # | 现象 | 根因 | 解法 |
| --- | --- | --- | --- |
| D1 | 军械库装 skill「完全没触发检查」 | 哨兵其实在跑（`/api-checkup/guard` 里有 `action: passed`），但**通过时静默**，事件只在面板里能看到 | 新增 `SentinelToast`（第二个 `shell.overlay`）：每 2.5 s 轮询，按动作弹右下角提示（通过绿 / 提醒黄 / 拦截红） |
| D2 | 四类检查缺「专家」，技能也只扫了一个根 | 专家落盘是 `dsh-agent-preset` 行（id `preset-wbexpert-*`）；专家捆绑技能在 `~/.agents/skills` | 新增 `lib/armory.js`：连接器 / 技能 / 插件 / 专家各 2 项共 8 项；技能同时扫 `~/.dsh/skills` 与 `~/.agents/skills` |
| D3 | 连接器命令被删了也判「配置均合法」 | `collectArmory` 采集了 `commandExists` 却从未使用（死数据） | `arm-connector-shape` 纳入 `commandExists === false` → block |
| D4 | 哨兵摘除坏 MCP 条目后，怀疑破坏了配置注释 | 担心 YAML 重新序列化丢注释 | 实测**保留注释**（`yaml` 的 `parseDocument`），且摘除前留 `.checkup.bak`；文档里写明「文件会被重写但注释保留」 |

**教训**：功能"在工作"和"用户能感知在作用"是两件事。**静默通过 = 用户以为没检查**。

### E. UI 与文案

| # | 现象 | 根因 | 解法 |
| --- | --- | --- | --- |
| E1 | MCP 检查配置里的选项框溢出到卡片外 | 三层叠加：`gridTemplateColumns: '120px 1fr'` 第二列最小宽是 `auto`；`<select>` 没设宽度；`TextInput` 写死 `width: 320/420` 且无 `box-sizing` | `minmax(92px, 120px) minmax(0, 1fr)`（那个 **0** 是关键）+ 控件 `width: 100%` / `boxSizing: border-box` / `minWidth: 0` |
| E2 | 插件列表里描述显示成 `DSH??????????? / ?? / ?? / ???` | 用 `Out-File -Encoding ASCII` 写脚本，脚本里的中文被替换成 `?`，再写进 `package.json` | 写中文进配置文件**一律用 write / edit 工具（UTF-8 无 BOM）**，禁止 PowerShell 的 ASCII 编码 |

**教训**：CSS 布局问题要看 `scrollWidth` vs `clientWidth` 和控件右边界，别靠肉眼；
**中文内容禁止经过任何 ASCII 编码环节**。

### F. 安全与健壮（第一轮全面审计发现）

| # | 现象 | 根因 | 解法 |
| --- | --- | --- | --- |
| F1 | 任意本地请求「先 `/check` 再 `/install`」就能真实执行安装 | 门禁只比对 `spec` + 10 分钟，`/check` 一调就把 `approved` 写好了 | `/check` 返回一次性 `approvalToken`（`randomUUID`），`/install` 必须携带且用后失效 |
| F2 | 同机其它网页可以跨源调全部接口 | `jsonRoute` 只包 try/catch，不查 `Origin` | 带 `Origin` 时只放行 `dsh-app://` 与本机 `http(s)://127.0.0.1` / `localhost`，其余 **403** |
| F3 | `/check-skill` 传任意路径就能扫本机目录 | 只判断 `existsSync` | `resolve` 后按前缀限制在两个 skills 根内，越界/穿越 **403** |
| F4 | 超大 POST body 会无限累积 | `readBody` 没有上限 | 先看 `content-length`，超 1 MB 直接 `req.resume()` 排空并返回 400（早期版本用 `req.destroy()` 会导致连接重置而非 400） |
| F5 | 会话流式输出时每次都全量扫 `button` | 图标补丁的 `MutationObserver` 无节流 | 200 ms 合并，卸载时 `clearTimeout` |
| F6 | 长期运行两个集合缓慢增长 | toast 的 `seen` 只增不减；旧品牌状态目录未清理 | `seen` 超 200 条裁掉最早 100 条；启动时把 `~/.dsh/electronic-dog` 并入新位置后删除 |
| F7 | 报错类名仍是旧品牌 `ElectronicDogBlocked` | 改名时漏了类名 | 改 `CheckupBlocked`，保留 `export { CheckupBlocked as ElectronicDogBlocked }` 兼容别名 |

**教训**：**「只有 UI 会调这个接口」是错觉**。每个写操作接口都要能回答：「谁能调？凭什么？」

### G. 测试与工具链（坑中之坑）

| # | 现象 | 根因 | 解法 |
| --- | --- | --- | --- |
| G1 | 假绿：删掉 `ctx.effect(() => patchSettingsNavIcons())` 后测试仍通过 | 断言只检查了**函数是否存在**，没检查**调用点** | 断言改为检查调用表达式本身；新增断言必须做**反向插桩**（人为破坏 → 测试必须失败） |
| G2 | 用 PowerShell here-doc 写含中文的脚本，内容全变 `?` | PowerShell 管道/文件编码不是 UTF-8 | 中文脚本一律用 write 工具写；PowerShell 只跑不含中文的逻辑 |
| G3 | `.cjs` 里用 top-level `await` 报 `await is only valid in async` | CommonJS 不支持顶层 await | 改 `.mjs`，或包一层 async IIFE |
| G4 | 写脚本时模板字符串里嵌套反引号导致语法错误 | 外层模板字符串被内层反引号提前闭合 | 内层反引号转义，或改用数组 `join('\n')` 拼 |
| G5 | 脚本报告「OK」但文件根本没改 | 中途有锚点 FAIL 设置了 `exitCode = 1`，最后的写入判断跳过了写文件 | 每个替换单独校验锚点唯一，**失败即中止并明确输出"未写入"** |
| G6 | 误判配置文件被破坏（26408 → 28009） | 用 `String.length`（字符数）和 `Get-Item .Length`（字节数）对比 | 比文件大小要统一量纲；中文 UTF-8 一字符 3 字节 |

**教训**：脚本化改动要**每次验证结果**，不能只看「脚本没报错」。
G5 这次真的差点让一轮修复白做 —— 现在每个脚本都明确输出「OK / FAIL」和「changed: true/false」。

### H. 代码审查（第二轮：逐文件审查 + 插件包）

这次是把整个目录（lib / test / 配置 / tgz 包）当外部代码审了一遍，找出 12 个问题。
**其中 3 个是「会丢数据」级别的**，值得单独记下来。

| # | 级别 | 现象 | 根因 | 解法 |
| --- | --- | --- | --- | --- |
| **H1** | 严重 | `quarantine\..\skills` 能通过校验，随后 `rm -rf` 会删光所有技能 | 路径校验用裸 `startsWith(quarantineDir)`，既没 `resolve()` 规范化，也没按分隔符边界比对 —— `<quarantine>-evil` 和 `quarantine\..\x` 都能通过 | `resolve()` 两边后比 `=== root \|\| startsWith(root + sep)`；隔离区根目录本身也拒绝操作；`/guard/release` 路由再校验一次（双保险） |
| **H2** | 严重 | 保存设置后，`levelOverrides` / `maliciousPackages` / `confirmTimeoutMs` **不会写进文件**，重启即丢 | `renderConfigBlock()` 只渲染 6 个字段，漏了后加的 3 个 | 渲染 `normalizeSettings` 支持的**全部**字段；以后新增字段必须同步这里 |
| **H3** | 严重 | 源码目录混入 `node_modules/`、`package-lock.json`（版本还是 0.2.0）、`*.tgz`，且没有 `.gitignore` | 一直在源码目录直接 `npm install` + `npm pack` | 加 `.gitignore`（`node_modules/`、`*.tgz`、`*.bak`、`dist/`），产物与源码分离 |
| **H4** | 一般 | MCP 条目写成 `- id: mcp-cad   # 备注` → 整个连接器从体检里消失；`command: ... # 注释` → 命令值带注释被误判「不存在」 | `readMcpEntries()` 用正则逐行扫 YAML，`\s*$` 要求行尾干净 | 改用 `yaml` 库解析（`logLevel: 'error'` 静音 `!!js` 警告）；行扫描保留作兜底 |
| **H5** | 一般 | `- id: "checkup"` 或带注释的条目匹配不到 → 保存时**追加第二条重复条目**；写坏也没备份 | `writeProfileConfig()` 的正则过严，且写入前不备份 | 正则放宽（引号 / 行尾注释）；写前 `copyFile` 到 `<file>.checkup.bak` |
| **H6** | 一般 | 78 次 `existsSync` 在 `/armory` 请求路径上同步阻塞 | 每个包 × 每个 node_modules 目录都查一次 | 改成一次 `readdir` 读成集合再查表（3 次代替 78 次） |
| **H7** | 一般 | 3 个导出零引用（`MCP_RULE_IDS`、`SKILL_RULE_IDS`、`isNewer`） | 功能改版后忘了删 | 删除，规则真源统一到 `RULE_IDS` 与各 check 函数 |
| **H8** | 一般 | registry 读取失败走 `console.warn`，宿主日志里无统一格式 | 顶层函数拿不到 `ctx` | 模块级 `moduleLogger`（`apply` 时注入），无 `ctx` 才退 `console` |
| **H9** | 一般 | `engines` 只有 `dsh`，没有 `node`；用了 `randomUUID` 等新 API | 早期只考虑了宿主版本 | 补 `"node": ">=18"`，源码与安装副本同步 |
| **H10** | 轻微 | `escHtml` 没转义单引号 | 当时属性都用双引号，看起来够用 | 补 `.replace(/'/g, '&#39;')` |
| **H11** | 轻微 | `cordis.patch.yml` 模板缺 `levelOverrides` / `confirmTimeoutMs` 说明 | 新功能没回填配置模板 | 补齐注释与默认值 |
| **H12** | 轻微 | README 标题写 `dsh-electron-dog`，与包名不符 | 改名时漏了标题 | 标题统一为「包名 dsh-checkup，旧名 dsh-electronic-dog」 |

**修 H6 时自己踩出来的 3 个回归**（都已修，写下来提醒：「优化」也要实测）：

| 回归 | 怎么发现的 | 原因 | 修法 |
| --- | --- | --- | --- |
| `@dsh-pet/bridge` 被判「实体缺失」 | 改完 `readdir` 查表后立刻跑采集 | **pnpm 的包是 symlink**，`Dirent.isDirectory()` 返回 false → 被过滤掉 | `isDirectory() \|\| isSymbolicLink()` |
| 真专家「火眼眼」被判 `hasPersona: false` | 同上，跑 `collectArmory` 看输出 | 专家 persona 嵌在 `config.plugins[].config.prefix`，按行切块把内层 `- id: persona` 当成条目边界 | 专家解析也改 `yaml`，按 `plugins[].config.prefix/suffix` 取 |
| 每个专家都误报「来源插件已不存在」 | 同上 | `plugin` 字段只是 WorkBuddy 的专家标识，不是 npm 包名 | 孤儿判定改看 `externalRefs`（只收真正的包名，过滤 `@deepseek-ai/*` 与 `cordis:group` 这类标记） |

**教训**：路径校验一定要 `resolve()` + 分隔符边界，`startsWith` 单独用等于没校验；
「读得到但写不下」是最隐蔽的一类 bug（H2），功能测试全绿也发现不了，必须直接看落盘文件。

## 当前版本核对表

| 版本 | 主要变化 |
| --- | --- |
| 0.0.1 | 首次安装，连崩两次（A1 / A2） |
| 0.1.0 | 三类 23 条规则、环境体检、哨兵 |
| 0.1.1 | asar 探测修复 + 五处降级保护（B1~B4）+ 官方包硬保护（C1） |
| 0.2.0 | 逐项自定义处理方式（block / warn / pass） |
| 0.3.0 | 军械库四类检查（D2）+ 落盘提示 toast（D1） |
| 0.3.1 | MCP 表单溢出修复（E1） |
| 0.3.2 | 落盘提示补齐（D1 完整化） |
| 0.3.3 | 第一轮全面审计的 10 项修复（F1~F7、D3、B3 增强）+ 描述乱码（E2） |
| 0.3.4 | 第二轮逐文件审查的 12 项修复（H1~H12）+ symlink / 专家 persona / 孤儿误报 3 个回归 |
| 0.4.0 | **候选 vs 已装交叉比对**：8 条新规则（插件版本/依赖排斥、连接器重名/工具冲突、技能内容重复、专家三查）；修 MCP 重名自过滤（原来永远 warn 不到）；技能比对纳入 `~/.agents/skills` |

## 验证基线（0.4.0）

每次改动后跑这套，全绿才算完：

| 项 | 命令 | 期望 |
| --- | --- | --- |
| 语法 | `node --check lib/*.js`（12 个） | 全部 exit 0 |
| 全量自检 | `test/` 下 14 套 | 全 ok、0 fail |
| 反向插桩 | 把 8 条交叉比对规则逐条改回失效，跑 `test/cross-check.test.mjs` | 必须大面积 FAIL（20+ 项） |
| 源码↔副本 | SHA256 比对 12 个文件 | 0 不一致 |
| 副本独立自检 | `node test/offline-client-check.mjs <副本目录>` | ALL PASS |
| 运行时（重启后） | `/api-checkup/{state,armory,inventory,guard,audit}` | 全 200；四类 8 项 pass |

14 套套件清单：`verify` / `security-stability` / `skill-mcp` / `audit` / `degraded-probe` /
`level-override` / `armory` / `guard` / `hardening` / `review-fixes` / `config` / `real-patch` /
`offline-client-check` / `cross-check`。

> `test/probe_env.mjs` 与 `test/fixtures-check.mjs` 是**手工排查工具**，不在自检清单里：
> 前者打印当前环境探测结果，后者校验 `fixtures/` 两个 package.json 是否仍符合预期用途。


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
| `dup-plugin-version` | warn | 已装同名包时比版本（升级 / 降级 / 换版），或同名包只作为依赖存在 |
| `conflict-deps` | block/warn | 候选 `dependencies` 与已装版本互斥：宿主单例包（`@deepseek-ai/*`）block，普通包 warn |
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

## 交叉比对：候选 vs 已装（0.4.0 新增）

0.3.4 之前只判「这个包能不能装」，不判「装上之后会不会和已装的打架」。0.4.0 补上这一层：
**准备安装的对象**逐一与**本地已装对象**比对，判断重复、冲突排斥、不兼容。

| 对象 | 规则 | 级别 | 判什么 |
| --- | --- | --- | --- |
| 插件 | `dup-plugin-version` | warn | 已装同名包时比版本：同版本 / 升级 / 降级 / 同名但只作为依赖存在 |
| 插件 | `conflict-deps` | block / warn | 候选 `dependencies` 要求的版本与本地已装版本是否互斥；`@deepseek-ai/*` 是宿主单例包，装出第二份实例会静默失效 |
| 连接器 | `dup-connector-name` | warn | `serverName` 与已配连接器撞车（大小写不敏感），工具前缀 `mcp__<server>__*` 会互相覆盖 |
| 连接器 | `conflict-connector-tool` | warn | 名字只差分隔符（`c_ad` vs `cad`），或同一个后端（命令+参数完全相同）换了名字重复接入 |
| 技能 | `dup-skill-content` | warn | 改名重装同一份技能：SKILL.md 正文指纹相同，或 frontmatter `name` 撞车 |
| 专家 | `cand-expert-shape` | block / warn | id 前缀、名称、人设正文是否完整（空人设 / 不足 20 字） |
| 专家 | `cand-expert-dup` | block / warn | 与已装专家撞 id（block）、同一套人设换名（warn）、名称撞车（warn） |
| 专家 | `cand-expert-refs` | warn | 专家引用的第三方插件是否已安装 |

设计要点：

- **数据来源不再各扫各的**：`collectArmory()` 已经拿得到四类快照，现在这些数据直接进预检环境，
  不再是「装前只看包名、装后才看全貌」。
- **`candidatePersisted` 解决自己撞自己**：哨兵复查和「已装项体检」检查的是**已经写进配置**的条目，
  重复计数要减掉自己那一份，否则每条都会自报重复。面板的装前检查传 `false`（候选还没落盘）。
- **锚定规则改了**：连接器重名从 `mcp-servername` 搬到 `dup-connector-name` —— 名字合法性归前者，
  「和已装的撞不撞」归后者，两边可以分别调级。
- **技能两个根都算**：`~/.dsh/skills` 与 `~/.agents/skills` 一起比对，只扫前者会漏掉 agent 根里的同名冲突。
- 专家走 `POST /api-checkup/check-expert` 预检（`{ candidate: { id, name, persona, externalRefs? } }`）。

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
| `sk-name` | 提醒 | 命名规范、与已装 skill 重名（`~/.dsh/skills` 与 `~/.agents/skills` 两个根都算） |
| `sk-scripts` | 阻止 / 提醒 | skill 内 `.js/.py/.sh/.ps1` 的隐私读取、下载即执行、混淆执行 |
| `sk-instructions` | 提醒 | SKILL.md 里教用户 `curl \| sh`、PowerShell 编码命令等 |
| `sk-deps` | 通过 | 是否有 requirements.txt / package.json |
| `sk-size` | 提醒 | 文件数 > 500 |
| `dup-skill-content` | 提醒 | 与已装技能内容完全相同（SKILL.md 正文指纹），或 frontmatter `name` 撞车 |

### MCP 检查（`lib/mcp.js`）

| id | 级别 | 内容 |
| --- | --- | --- |
| `mcp-shape` | 阻止 | transport ∈ {stdio, sse, streamable-http}；stdio 必须有 command |
| `mcp-servername` | 提醒 | `^[A-Za-z0-9_-]{1,32}$`（只管名字本身合法；撞名见下一条） |
| `dup-connector-name` | 提醒 | `serverName` 与已配连接器重复（大小写不敏感；已落盘条目复查时减掉自己那份） |
| `conflict-connector-tool` | 提醒 | 名字只差分隔符，或同一后端（命令+参数相同）换名字重复接入 |
| `mcp-command` | 阻止 | 启动命令在 PATH / 绝对路径上是否存在 |
| `mcp-package` | 提醒/通过 | npm 包（npx）→ 复用插件整套规则预检；python 包（uvx）只校验命令与参数 |
| `mcp-env-secret` | 提醒 | env 里明文写 API key/token（建议 `${ENV}` 引用） |
| `mcp-known-bad` | 阻止 | serverName / 包 / 程序名命中黑名单 |

### 专家检查（`lib/expert.js`，0.4.0 新增）

| id | 级别 | 内容 |
| --- | --- | --- |
| `cand-expert-shape` | 阻止 / 提醒 | id 必须是 `preset-*`（`preset-wbexpert-*` 才被军械库面板识别）、名称非空、人设正文非空 |
| `cand-expert-dup` | 阻止 / 提醒 | 与已装专家撞 id → block；同一套人设换个名字 → warn；名称撞车 → warn |
| `cand-expert-refs` | 提醒 | 专家引用的第三方插件没装，启用后工具不可用 |

入口：`POST /api-checkup/check-expert`，body 为 `{ candidate: { id, name, persona, externalRefs? }, selfId? }`。

## 逐项自定义处理方式（block / warn / pass）

每条检查都可以单独指定处理方式，不必接受规则写死的等级。面板「检查规则」里每行右侧有一个下拉：

| 选项 | 效果 |
| --- | --- |
| 默认 | 按规则自身的判定（等价于不设置） |
| 阻止 | 这条一旦不通过，直接拒绝安装 |
| 提醒 | 只提示，不阻断 |
| 通过 | 完全放行这一条（即使它本来会阻止） |

选择后该行会立刻标上「自定义」角标并换成对应颜色，保存后写入 profile 的 `cordis.patch.yml`：

```yaml
levelOverrides: { "runtime-version": "warn", "sec-scripts": "block" }
```

实现要点：

- 覆盖只改 `level`，不动 `title/detail/hint` —— 用户改的是「怎么处理」，不是「检查结论」。
- 覆盖发生在汇总之前，所以 `ok` / `blocked` / `warned` / `passed` 与三类统计都跟随覆盖。
- 被覆盖的条目带 `overridden: true` 与 `originalLevel`，界面据此标注「自定义」。
- 非法值（如 `"ignore"`）直接忽略，退回规则默认，**不猜**。

## 军械库四类检查（连接器 / 技能 / 插件 / 专家）

覆盖 `dsh-armory`（大肥鱼军械库）面板里的四类对象。每类两项：一项看结构是否合法（兼容性），一项看是否重复或失效（稳定性），**共 8 项，四类各 2 项、不遗漏不重复**。

| 类 | 落盘位置 | 识别凭据 | 检查项 |
| --- | --- | --- | --- |
| **连接器** | profile `cordis.patch.yml` 的 `@deepseek-ai/dsh-mcp-client` 条目 | `config.serverName` | `arm-connector-shape`（transport / serverName / command 齐全）· `arm-connector-dup`（serverName 重复） |
| **技能** | `~/.dsh/skills/<name>/` 与 `~/.agents/skills/<name>/` | 目录名（专家捆绑技能带 `wbexpert__` 前缀） | `arm-skill-manifest`（缺 SKILL.md）· `arm-skill-dup`（跨两个根重名） |
| **插件** | profile 的 `dsh.profile.bundles` + `node_modules` | 包名 | `arm-plugin-entity`（登记了但无实体，`@deepseek-ai/*` 除外）· `arm-plugin-dup`（重复登记） |
| **专家** | profile `cordis.patch.yml` 的 `@deepseek-ai/dsh-agent-preset` 行 | 行 id `preset-wbexpert-*`、`config.name` 前缀 | `arm-expert-shape`（id 规范 / 名称非空 / 人设正文非空）· `arm-expert-orphan`（来源插件已卸载） |

与安装前检查的分工：那边判「这个包能不能装」，这边判「已装对象有没有问题」。

接口：`GET /api-checkup/armory`，返回 `{ checks, byKind, kinds, rules, counts }`。

> 技能数比 `~/.dsh/skills` 多，是因为把 `~/.agents/skills` 也算进来了——专家捆绑技能落在那里。

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
        preflightEnabled: true          # false = 只记录不阻断
        blockOnWarn: false              # true = 有 warn 也拒绝安装
        registries:                     # 包元数据的读取顺序
          - https://registry.npmmirror.com
          - https://registry.npmjs.org
        lookupTimeoutMs: 8000           # 单个源单次读取上限（1000–60000）
        lookupAttempts: 2               # 同一源的重试次数
        knownBad: []                    # 例：["dsh-broken-plugin@0.1.2"]
        maliciousPackages: []           # 例：["evil-pkg"]，命中直接阻止
        levelOverrides: {}              # 例：{"runtime-version": "warn"}
        confirmTimeoutMs: 180000        # 市场点安装后等面板确认的最长时间
```

字段全集与 `normalizeSettings()` 一一对应：**新增字段必须同时改 `normalizeSettings`、
`renderConfigBlock` 和这份示例**——0.3.4 之前就是因为 `renderConfigBlock` 漏字段，
导致 `levelOverrides` 保存后不落盘、重启即丢。

## 安装

```powershell
# 0. 三个路径都按本机推导，不用改常量
$repo = 'D:\你的路径\dsh-checkup'                       # ← 只改这一处：本插件源目录
$app  = "$env:LOCALAPPDATA\Programs\DeepSeek Harness"   # 桌面端安装根
$node = "$app\resources\runtime\primary-runtime\dependencies\node\bin\node.exe"
$pnpm = "$app\resources\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.mjs"

# 1. 装包（本地目录方式）
& $node $pnpm --dir "$env:USERPROFILE\.dsh\profiles\desktop" add "file:$repo"

# 2. 加进 bundles（无 BOM，务必用 Node 写）
#    dsh.profile.bundles 末尾追加 "dsh-checkup"

# 3. 重启桌面端；设置 → 插件 → dsh-checkup 可见面板
```

## HTTP 接口

全部接口都有来源校验：请求带 `Origin` 时必须是非跨源的 `dsh-app://` 或本机 `http(s)://127.0.0.1` /
`localhost`，否则一律 **403**；不带 `Origin`（本地脚本 / curl）放行。请求体上限 **1 MB**，超限回 400。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api-checkup/state` | 环境摘要 + 规则 id + 最近记录 |
| GET | `/api-checkup/config` | 当前配置 |
| POST | `/api-checkup/config` | 保存配置（写 profile 的 `cordis.patch.yml`，写前留 `.checkup.bak`） |
| GET | `/api-checkup/pending` | 被拦下等待确认的安装请求 |
| POST | `/api-checkup/confirm` | 确认/拒绝挂起请求 `{ id, action }`；过期返回 404 |
| POST | `/api-checkup/check` | 手动预检 `{ spec }` → `{ ok, report, approvalToken }` |
| POST | `/api-checkup/install` | 执行安装 `{ spec, token }`；缺 token / token 不匹配 → **409** |
| POST | `/api-checkup/check-skill` | 检查 skill 目录 `{ path }`；不在两个 skills 根内 → **403** |
| POST | `/api-checkup/check-mcp` | 检查 MCP 配置 `{ config }` |
| GET | `/api-checkup/inventory` | 已装 skill / MCP 快照 |
| GET | `/api-checkup/armory` | 军械库四类：`{ checks, byKind, kinds, counts }` |
| GET | `/api-checkup/audit` | 环境体检（保留 / 卸载建议） |
| GET | `/api-checkup/guard` | 哨兵状态：`{ events, quarantined, roots }` |
| POST | `/api-checkup/guard/release` | 隔离项放行/删除 `{ dir, action }`；路径越界 → **403** |

`/api-checkup/install` 的两道门：检查必须通过（否则 409 带 report），且必须携带 `/check`
返回的一次性 `approvalToken`（10 分钟内有效，用后失效）。

## 卸载

从 `dsh.profile.bundles` 移除 `dsh-checkup` 并 `pnpm remove dsh-checkup`，
拦截器随插件卸载自动还原。

## 实时哨兵（0.2.1 起）：skill / MCP 落盘兜底拦截

**为什么需要**：`pluginManager.installBundle` 拦截器只覆盖插件安装。军械库（dsh-armory）装 skill
是自己下载解压**直写 skills 目录**（`~/.dsh/skills` 与 `~/.agents/skills`），装 MCP 是**直接写
profile 的 cordis.patch.yml**——宿主也没有 skill 安装 API（dsh-skill-filesystem 只做目录发现）。
所以装 skill / MCP 不会触发预检，这是通道问题，不是规则问题。

**哨兵做什么**：watch 上述两个 skill 根与 profile patch 文件。运行期**新落盘**的 skill 目录 /
MCP 条目在数秒内自动过检（启动时已存在的存量不拦，由体检面板覆盖）：

| 情形 | 动作 |
| --- | --- |
| skill 脚本命中恶意特征（sk-scripts） | 目录移入 `~/.dsh/checkup/quarantine/`，面板可放行/删除 |
| skill 缺 SKILL.md（sk-manifest） | 复查一次仍缺才隔离（避免解压未完成的瞬时误伤） |
| MCP transport 非法 / 黑名单命中 | 行级摘除该条目（写前备份整份 patch，摘后 YAML 校验，失败自动回滚） |
| MCP 启动命令不存在（mcp-command） | **只告警不摘除**（宿主进程 PATH 与终端不同，误报率高） |

拦截事件与隔离区在体检面板「实时拦截哨兵」卡片查看；放行/删除走
`POST /api-checkup/guard/release`。
