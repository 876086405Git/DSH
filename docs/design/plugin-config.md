# 插件配置的原生页（PLUGIN-CONFIG）

> 2026-10-29。App 端完成，已对接 dsh-go bridge 的 `/dsh-go/v1/plugin-config`（接口见 §2）。bridge 路由由后端实现，App 侧以假服务器测试。

## 0. 结论

- **DSH 0.2.1-rc.4 自身没有能写非 volatile 字段的接口**，读也读不到：`settings/describe` 只投影 `.volatile()` 字段，一个 volatile 字段都没有的插件整条不返回；`settings/mutate` / `update` / `replace` 写非 volatile 路径一律拒绝。网页版同样只有 volatile（Pro 的约定 §1 用真机复核过）。
- 完整配置走 **dsh-go bridge 的 v1 路由**，内部调用主机已有的 `ConfigEditor`（校验、落盘 profile `cordis.patch.yml`、Loader 协调、失败恢复）。不改 DSH 内核的 `settings/*`。
- App 有两个数据源，自动选用：
  - **bridge**（`BridgePluginConfigApi`）：主机提供 `/dsh-go/v1/plugin-config` 时用，普通字段和 volatile 字段都能改；
  - **volatile**（`EngineSettingsPluginConfigApi`）：路由 404（没有 bridge 或 bridge 版本旧）、或连接到不了 bridge（relay）时用，就是之前的行为：`settings/describe` + `settings/mutate`，全部即改即生效。
- **只有插件进这个页（白名单，默认拒绝，§7）**。bridge 列出的是整个 profile，DSH 核心也在里面且都能写；App 只放行「用户选中的 bundle 的行」——市场 / 本地安装的、打开了的官方可选插件——依据是 `pluginManager/listBundles` 的字段，不是命名空间名单。列表、状态、页面、写入层四处都按这一条，核心条目不显示、不读、不写。

## 1. 查证记录（rc.4 包，只读）

| 包 | 关键代码 | 结论 |
|---|---|---|
| `@deepseek-ai/dsh-settings` | `volatileForm(schema)`：只保留 `meta.volatile` 的节点；`describe()` 里 `form === undefined` 的条目直接跳过；`plainSchema()` 删掉 `meta.volatile`；`write()` 先 `isVolatilePath` 校验，非 volatile 抛错 | 读写都只覆盖 volatile |
| `@deepseek-ai/dsh-api-settings-controller` | Remote：`settings.describe/update/replace/mutate/openSettingsDocument`，`credentials.describe/set/unset` | 全部委托给上面的 settings 服务，没有别的写入口 |
| `@deepseek-ai/dsh-config-editor` | `configEditor.edit(entry, change)`：校验 → 写 profile patch → Loader 协调 → 失败恢复 | 能力齐全，但只是进程内服务；bridge 方案就是把它包成路由 |
| `@deepseek-ai/dsh-client-ui-plugin-manager` | 只调 `pluginManager.*`、`pluginInventory.list`；配置页靠插件自己注册到插槽 | 网页版没有通用表单 |
| `@deepseek-ai/schemastery` 3.18.5 | `.volatile()` 即 `meta.volatile = true`，`toJSON()` 会带出 | 完整 schema 里保留它，客户端就能逐字段判断生效方式 |

## 2. 对接的接口（以 Pro 的约定为准）

基路径 `/dsh-go/v1/plugin-config`，沿用 bridge 的鉴权与路由守卫（不进 openRoutes）。

| 路由 | App 用法 |
|---|---|
| `GET /dsh-go/v1/plugin-config` | 能力探测兼目录：200 → bridge 模式；**无 code 的 404** → 退回 volatile。条目带 `entryId`、`package`、`label`、`state`、`configurable`、`reason`。`configurable: false` 的不出入口；直接打开时按 `state` / `reason` 说明原因（未启用 → 「插件没有在运行」；failed → 「插件没有启动」；其余 → 「暂不支持在这里设置」） |
| `GET /dsh-go/v1/plugin-config/<entryId>` | 页面打开时才读（一次一个条目，不在列表时批量拉）。schema 是 `uid/refs` 图，live 节点带 `meta.volatile`；`revision` 是不透明字符串，原样回送 |
| `POST /dsh-go/v1/plugin-config/<entryId>` | `{revision, ops}`，ops 同 `settings/mutate` 的 set / unset。live 字段即改即发一次；普通字段攒到「保存」一次发出。成功回包即新条目（含新 revision），以回包为准 |
| `credentials/describe` · `set` · `unset` | 有 `credentialRef` 绑定的密钥走这里，和配置保存是两个事务；unset 后重新 describe（可能还有环境变量回退） |

`secrets[].credentialRef` 由 bridge 的 `secretFacts()` 提供。同一父对象的实际路径下，恰好一个 `secret` 字段和一个不同的 `credential-ref` 字段才绑定；交集或联合分支在同一字段路径上的重复访问只计一个字段，任一角色有多个字段则不绑定。角色取 schema 节点的 `meta.role`，包括标在包装节点上的角色，不按字段名猜测。同一 ref 路径或其父路径被任一分支标为 secret 时，沿用遮蔽规则，不通过 `credentialRef` 回传隐藏值。

引用先取运行中 `effectiveConfig` 经 `plain()` 得到的 resolved 值，只有 `undefined` 才取该 ref 节点的 `meta.default`；结果须为非空字符串，显式空字符串不回退到默认值。raw 配置继续只用于既有 `configured` 判定，不用原始表达式替代运行中的引用。未绑定时省略 `credentialRef`，App 的显式空绑定保持不可写。fact 的 `writable:false` 保持不变：secret 不能经此配置接口落入 profile YAML；绑定后仍走独立的 `credentials/*`，最终是否可写由凭据服务回答。

错误码与 App 的处理：

| 状态 / code | 含义 | App |
|---|---|---|
| 400 `invalid-operation` | 改动不合法，未写入 | 「这项改动无法应用」，改动保留 |
| 404 `entry-unavailable` | 条目没了 | 「插件已不在运行，已刷新」，重新读取，条目和改动随之消失 |
| 409 `conflict` | revision 过期 | 「刚在别处改过，已刷新」，重新读取，改动保留，可重试（用新 revision） |
| 409 `overridden` | 被更高层覆盖 | 「由配置文件固定」，改动保留 |
| 409 `apply-failed` | 写入后协调失败，**已恢复**旧配置 | 「没能生效 · 已恢复原设置」，改动保留，可重试 / 放弃 |
| 422 `invalid-config` | 校验不过 | 「值不合法」，有 `path` 时标在那一项上 |
| 503 `host-unavailable` | 主机暂不可用，未写入 | 「没能连上引擎」 |
| 500 `recovery-failed` | 协调失败，**恢复也失败** | 「没能生效，原设置也没能恢复」，重新读取；可「恢复原设置」（App 用保存前的 user 层算出逆操作，按新 revision 发出）或「重试」 |
| 网络超时 / 断线 | 结果未知 | 「连接中断，已重新读取」；重试前先重读，**已落地就不再发**，没落地才重发；不自动重放 |
| 无 code 的其它状态 | — | 「引擎没有接受这个值」 |

界面文案只用 App 自己的词，不显示主机返回的 message（约定 §4.3：校验异常可能带输入内容）。

进度：约定没有进度协议（§4.3「有界状态」），bridge 模式下保存栏只显示「正在保存…」，回包后「已生效」或失败；不显示虚构的「正在重新载入…」。保存前保存栏已写明「保存后重新载入插件」。

能力探测细节：每次连接首次读目录时探测一次；404 后本连接一直用 volatile，主机重启（`HostReady`）后再探测。目录读失败（非 404，如 503）显示读取失败并可重试，不静默降级。

relay：`/dsh-go/*` 是 HTTP 路由，只有本机和 SSH 隧道（`DshHttpCarrier`）够得着；relay 只转发放行表里的 RPC，碰不到这些路由，所以**不需要也无法登记**，relay 连接直接用 volatile。

## 3. 被替换掉的草案

上一版本文提议改 DSH 内核：`settings/describe` 加 `{scope:'all'}`、新增 `settings/apply`、错误码 `settings/apply-failed {rolledBack}`、可选进度事件 `settings/apply-progress`、describe 返回启动失败的条目（`phase: failed`）、relay 放行 `settings/apply`。**全部不采用**，以 bridge 路由代替：

| 草案 | 现在 |
|---|---|
| `settings/describe {scope:'all'}` 一次返回全部完整表单 | `GET …/plugin-config` 只给目录，表单按条目 `GET` |
| 整数 `revision` | 不透明字符串 `revision`，绑定启动代际、条目、schema 和原始配置 |
| `settings/apply`，失败统一 `apply-failed {rolledBack}` | `POST …/<entryId>`；恢复成功 409 `apply-failed`，恢复失败 500 `recovery-failed`，另有 400 / 404 / 409 / 422 / 503 |
| 进度事件 `saved / reloading / settled` | 无进度协议，只有「提交中 → 已应用 / 失败」 |
| 启动失败的条目也可编辑（`phase: failed`） | v1 不为未成功加载的条目编 schema；列为 `state: failed`、不可配置，页面说明原因 |
| 裸 `role('secret')` 字段随配置写入 | v1 拒绝：裸密钥会落进 profile YAML。只有带凭据绑定的才可写；裸密钥显示「需插件适配后设置」 |
| relay 放行 `settings/apply` | 不需要（见 §2 relay） |

## 4. App 端做了什么

| 要求 | 做法 |
|---|---|
| 每个装了的插件都有入口，只有插件有 | 插件详情页「设置」行、插件清单详情、设置 › 引擎参数 › 插件分组、设置搜索都按同一份目录（`pluginConfigEntries`）列出；市场、本地、打开了的官方可选插件一视同仁。是不是插件由 `PluginConfigScope` 判定（§7），DSH 核心、App 自己插入的行、认不出来的条目一律不列。`settingsPageFor` 的非内置分支改为 `PluginConfigPage`，它对非插件条目只显示「暂不支持在这里设置」 |
| volatile 即改即生效 | `isLive(path)`：路径上任一节点带 `meta.volatile` 即为 live，直接写 |
| 非 volatile 保存后生效 | 编辑先暂存（行上「未保存」），底部保存栏「N 项更改 · 保存后重新载入插件」；保存时表单只读；成功「已生效」后收起 |
| 失败可回滚、可重试 | 见 §2 错误码表 |
| 密钥只写不读 | 只显示「已设置 / 未设置」，值从不回显；绑定凭据的走 `credentials/*`；裸密钥不可写 |
| 分组、说明、默认值、恢复默认、i18n | 对象嵌套成组，`.collapse()` 照原样折叠；描述按界面语言取；数字 / 文本弹层里有恢复默认；页尾「全部恢复默认」（确认后执行，密钥保留）；文案中英两套 |
| `auto: false` 且有网页设置页 | 顶部「在网页版设置」，下面照样画原生能画的字段；网页页另由插槽占用情况判断。网页版改的是同一份配置：保存（重新载入插件）或 live 写入进行中时入口置灰，不进网页版；有未保存的更改先问「放弃修改？」，放弃后才去，免得回来再保存时盖掉网页版的改动。表单里的「在网页版编辑此项」走同一条路，落到插件自己的卡片（条目 id 本身对不上任何卡片） |
| 没有配置不显示空页 | 没有可画字段（或目录标为不可配置）的插件不出入口 |
| 好找、好读 | ≥ 8 个字段出搜索（标题、说明的中英文、键名、选项都能搜，折叠里的也能搜到）；常用项在前（必填、密钥、开关、选项、live 字段）；≥ 7 个字段且有 ≥ 3 个「管道」字段（超时、上限、路径、带默认值的地址）时收进「高级」；≥ 12 个字段且有多个标题组时各组折叠。schema 自己声明了 `.collapse()` 的，尊重作者的布局，不再额外折叠 |

代码：`packages/dsh_client/lib/src/plugin_config_api.dart`（线格式与错误码）；`app/lib/state/plugin_config/`（接口层、bridge、volatile 退路、内存实现、控制器）；`app/lib/ui/plugins/config/`（页面、保存栏、排序折叠、入口）。

## 5. 测试

- `packages/dsh_client/test/plugin_config_api_test.dart`：假 bridge（真 HTTP）上的目录 / 无路由 / relay、条目读取、entryId 编码、写入回送 revision，八个错误码各一条、422 的 path、无 code 状态、坏回包、写超时。
- `app/test/plugin_config/plugin_config_bridge_test.dart`：同一假服务器上跑控制器：404 退回 volatile 且不重复探测、relay 不探测、按条目读取、live 即发、保存一次发出；apply-failed 重试用新 revision、recovery-failed 恢复原设置、conflict 重读后重试、overridden / invalid-operation / host-unavailable 不写入且不显示主机原文、invalid-config 标到字段、entry-unavailable 条目消失、断线后已落地不重发 / 未落地才重发；绑定密钥走凭据、裸密钥不可写。
- 页面、排序、几何、golden 见 `app/test/plugin_config/`。
- `app/test/plugin_config/plugin_config_scope_test.dart`：r13 真机夹具（§7.1）上，「插件」分组只有语音输入套件的三项和本地插件；7 个敏感条目和其余 79 + 1 个可配置条目都不出现；没读到插件清单、bundle 没打开 / 有错误 / 不是可选也不是用户安装、行 id 撞核心但包名不符、同一 id 两个 bundle 都声明，全都拒绝；写入层对夹具里每个核心条目的 `read` / `apply` 都在发请求前拒绝（假服务器上零 POST、零 GET）。`plugin_config_bridge_test.dart` 的 `scope` 组：核心条目混进列表时控制器和 bridge 都不发请求、bundle 关掉后其行出范围、volatile 退路下同样不写核心命名空间。
- `app/test/plugin_config/plugin_config_scope_fresh_test.dart`（CR-a17797b）：成功一次后刷新失败、首次就失败、重新读取进行中、乐观打开未确认、确认关闭、别的连接的清单、未连接：只有确认过的当前清单放行，其余情况零 GET、零 POST；凭据只认范围内插件表单声明的 ref（核心 ref、未读表单、清单失效时一律不写），volatile 退路同样。页面和引擎参数页在清单读取失败时显示原因和重试（`plugin_config_page_test.dart`）。

## 6. 风险

- **bridge 路由尚未实现**（约定 §7 待后端落地）。在它上线前，所有主机都走 volatile 退路，用户看到的和以前一样多。
- 约定 §2 提到 ConfigEditor 对文件路径 insert 的规范化缺陷（CR-CONFIG-EDITOR-PATH）：用路径插入的插件，写入可能被误报为 409 `overridden`。App 照实显示「由配置文件固定」，不吞错误；修补在后端。
- 裸密钥插件在 App 里只能改普通字段，密钥需插件改为凭据绑定。
- 普通配置写入会把字段当前原始值钉在 profile 层（ConfigEditor 已知限制）；「全部恢复默认」可清掉。
- 白名单靠插件清单：清单没读到（加载中、安全模式关了 plugin-manager、RPC 失败）时「插件」分组是空的，页面显示加载中或「暂不支持在这里设置」。这是有意的默认拒绝。

## 7. 范围：只有插件（PLUGIN-CONFIG-ALLOW）

> 2026-10-28。r13 联调发现旧的黑名单（排除 `curatedNamespaces` + `internalNamespaces`）把 DSH 核心条目放进了「设置 › 引擎参数 › 插件」且可写。改为白名单。

### 7.1 实测

r13 运行时（DSH 0.2.1-rc.4 + dsh-go-bridge 0.4.0，取自 r13 的 x86_64 rootfs），按 App 的方式启动 `dsh web`：r13 自己的 `dsh-web.patch.yml`，加上语音、登录（`dsh-app-auth`）、消息搜索、手机操控四个 `--patch`。经 `pluginManager` 打开官方的语音输入套件、从本地路径装一个第三方插件（`local-notes`，包名 `dsh-go-fixture-local-notes`）后，只读 GET：

| | 条目 | 可配置 |
|---|---|---|
| 全部 | 202 | 84 |
| DSH 核心（`dsh-base`、`dsh-web-app` 两层的行） | — | 79 |
| App 自己插入的（`dsh-app-phone`，手机操控开着时才有） | — | 1 |
| 用户的插件 | 5（语音套件 4 行 + 本地 1 行） | 4 |

旧规则放出了 58 个核心条目，外加 `dsh-app-phone`，全部可写，其中有 `webserver`、`connection`、`credentials`、`sandbox-policy`、`fs-sandbox`、`approval`、`system-prompt`。`dsh-app-phone` 的配置就是一个 stdio MCP 服务器的 `command` / `args`，能写就等于能让引擎执行任意命令。（另一次联调的 201 / 82 / 79 是用 3 个合成夹具代替了这里的插件，79 个核心条目一致。）

夹具：`app/test/plugin_config/fixtures/bridge_catalog_r13.json`（GET 原文，只重新缩进）、`plugin_bundles_r13.json`（同一时刻的 `pluginManager/listBundles`，`meta.icon` 的 data URL 换成 `"<icon>"`，本地插件 `source` 里的本机路径换成 `link:/root/plugins/local-notes`）。

### 7.2 能拿来区分的字段

| 来源 | 字段 | 能不能区分插件和核心 |
|---|---|---|
| `GET /dsh-go/v1/plugin-config` | `entryId`、`package`、`label`（就是 `entryId`）、`state`、`configurable`、`reason` | **不能**。`package` 只说模块来自哪个包：核心、官方可选插件、App 的 `dsh-app-phone`（`@deepseek-ai/dsh-mcp-client`）都是 `@deepseek-ai/*`；按路径加载的（bridge 自己、`dsh-app-auth`）是 `null`。没有来源、owner、bundle 字段 |
| `pluginManager/listPlugins` | `entryId`（`include:<id>`）、`moduleName`、`enabled`、`fiberPhase`、`patchId`、`readOnlyReason` | **不能**。`readOnlyReason: management-required` 只标了部分核心（`webserver`、`connection` 有，`sandbox-policy` 没有） |
| `pluginManager/listBundles` | `name`、`official`、`optional`、`installed`、`availability`、`source`、`enabled`、`error`、`readOnlyReason`、`rows[]`（`rowId`、`moduleName`、`entryId`）、`overrides` | **能**。核心 = 安装自带的层（`dsh-base`、`dsh-web-app`：`official` / `optional` / `installed` 都是 false，`availability: installation`，`management-required`）；官方可选 = `official && optional`；用户安装（市场、本地、按需安装的官方包）= `installed` 且有 `source`（「安装本身不提供的 profile 依赖」） |

所以以 `listBundles` 为准，不需要官方插件名单。

### 7.3 规则（`app/lib/state/plugin_config/plugin_config_scope.dart`）

条目 E 是插件，当且仅当存在 bundle B：

```
B.enabled && B.error == null
&& ((B.official && B.optional) || (B.installed && B.source != null))
&& B.rows 里有一行 rowId == E.entryId，且所有已开启的 bundle（核心层也算）里只声明了这一次
&& （bridge 给了 E.package 时）packageOf(该行 moduleName) == E.package
&& （bridge R7 给了时）E.owner ∈ {optional, installed}、E.kind == plugin、E.bundle == B.name
```

- 匹配用 `rowId`：`rows[].entryId` 是 Loader 的 `include:<id>`，和 bridge 的 `entryId` 不是一套。
- 要求 `enabled`、要求「可选或用户安装」：没选中的替代层会声明核心 id 的行（`dsh-sdk-minimal` 里有 `llm-deepseek`、`sandbox`），只看「是某个 bundle 的行」会把核心放进来。
- 不看 `overrides`（bundle 只是改配置的核心行）；`--patch` 插入的行（App 的 `dsh-app-*`、bridge 自己）不属于任何 bundle。
- 包名比对是额外一道：行 id 撞上核心条目、但模块不是同一个包时拒绝。
- 默认拒绝：插件清单没读到就什么都不算插件；认不出来的条目不显示。用户安装只认 `source`（不拿 `availability` 的缺省值兜底）：不给 `source` 的主机上，自装插件宁可不显示。
- 重复声明按所有已开启的 bundle 数（CR-a17797b）：合格 bundle 再声明一个核心层也声明的 id（哪怕包名相同），这个 id 就不是它独有的，不算插件。

**只认主机确认过的最新清单（CR-a17797b）**。`installedPluginsProvider` 为了显示会保留旧清单：刷新失败时它仍是原来的 `AsyncData`，乐观开关时是打了 `confirmed: false` 的派生值。白名单不能拿它直接授权。`pluginConfigScopeProvider` 同时看清单、`readListCache` 的刷新记录和来源戳：

| 情况 | 范围 | 页面 |
|---|---|---|
| 当前连接、当前身份、主机确认过的最新一次成功读取 | `confirmed`，按上面的规则放行 | 正常 |
| 正在读取 / 重新读取，或乐观开关还没得到主机确认，或清单来自别的连接、别的身份、没有来源戳 | `pending`，什么都不放行 | 加载中；写入被拒时说「插件清单正在更新，请稍后再试」 |
| 最近一次读取失败（旧清单仍在屏幕上） | `failed`，什么都不放行 | 「插件清单读取失败，稍后重试」+ 重试；引擎参数页的插件分组里也有这一行 |
| 没有插件管理可问（未连接） | `offline` | 未连接 |

bundle 被停用、出错后，一旦主机确认，新清单里它的行立即不算插件；确认之前（乐观状态）同样不放行。缓存的变化流每次发的是同一个值，当 provider 监听会漏掉「刷新失败」这一次，所以范围直接订阅缓存的变化重新计算。写入层在显示「正在保存」之后、真正发请求之前再查一次范围。

**凭据也按范围（CR-a17797b）**。`describeCredentials` / `setCredential` / `clearCredential` 只接受范围内插件条目声明过的 ref：bridge 模式下是读到过的插件表单里的绑定密钥和 `credential-ref` 字段，volatile 模式下是范围内命名空间声明的；不在其中的 ref 不查询、不写，直接拒绝。表单没读过的插件、清单失效时，连插件自己的 ref 也不写。剩下的边界：插件可以在自己的 schema 里把密钥绑到一个公共 ref（比如 `DEEPSEEK_API_KEY`），这时在它的设置页里填值会写这个 ref；这是插件声明的绑定，App 无法分辨，需要服务端约束绑定。

四处执行：列表（`hasPluginConfig` / `pluginConfigEntries` / `bundleConfigRows` / 设置搜索）；状态（`PluginConfigState[ns]` 只交出插件的表单，`load` 不为非插件发 GET，`set` / `save` / `resetAll` / 密钥都拿不到表单）；写入层（`BridgePluginConfigApi` 和 `EngineSettingsPluginConfigApi` 的 `read` / `apply` / 凭据三个方法在发请求前抛 `PluginConfigFailure`）；页面（非插件显示「暂不支持在这里设置」，清单状态不是 confirmed 时按上表显示）。

r13 夹具上的结果：显示 `speech-to-text`、`speech-to-text-sensevoice`、`api-speech-to-text`（语音输入套件和它的 provider、接口）、`local-notes`（本地插件）；`ui-voice-input` 是插件行但没有配置，不出入口。其余 80 个可配置条目都不显示。

不受影响：精选页（子智能体、智能体循环、命令执行、联网搜索……）直接走引擎设置，不经这里。DSH Web 设置插槽的原生座位（`SchemaConfigSeat`）内嵌时只画 `settings/describe` 的 volatile 字段，和 DSH Web 自己能改的一样；它以「行」出现时打开 `PluginConfigPage`，核心命名空间现在会显示「暂不支持在这里设置」。

### 7.4 建议 bridge 补的

1. **服务端也做白名单（最要紧）**。现在 App 只是客户端防线：任何拿得到 `/api` 凭据的客户端（DSH Web 页面里的脚本、别的插件页）都能直接 `POST /dsh-go/v1/plugin-config/webserver` 改核心配置、放宽 `sandbox-policy`、改 `dsh-app-phone` 的 `command`。建议 bridge 对不属于「已选中的官方可选 bundle 或 profile 自装 bundle」的条目一律 `configurable: false`（新 reason，如 `core`），GET 详情和 POST 都回 404 `entry-unavailable`（或新 code `not-a-plugin`）。判定可直接复用 plugin manager 的 `listBundles` 数据，和 App 的规则一致。
2. **列表直接带来源**：每项加 `owner`（`core` / `optional` / `installed` / `overlay` / `unknown`）和所属 `bundle` 名。`overlay` 指 `--patch` 插入的行（App 的 `dsh-app-*`、bridge 自己）。有了它 App 不必再交叉对照 `listBundles`。
3. **`label` 给真名**：现在 `label` 恒等于 `entryId`；`listBundles` 的 `rows[].meta.title` 已有中英文标题，建议直接带上。
4. **统一 id**：`listBundles` / `listPlugins` 的 `entryId` 是 `include:<id>`，plugin-config 的 `entryId` 是 `<id>`，两边只能靠 `rowId` 对照，建议在约定里写明或统一。
5. **被 `--patch` 钉住的条目**：App 的语音 overlay 整行替换 `speech-to-text-sensevoice` 的 config（`SpeechGuest.kt`），按 bridge 的实现，对这类条目写入大概率回 409 `overridden`（本次只做 GET，未验证）。语音 provider 现在是「插件」分组里仅有的几项之一，建议 bridge 在列表或详情里标出被 overlay 覆盖的字段 / 条目，App 好提前标「由配置文件固定」，而不是保存后才报错。

### 7.5 bridge R7（runtime r14）落地后

1、2、5 已由 R7 实现：服务端按 `listBundles` 默认拒绝（非插件条目 GET / POST 403 `entry-unavailable`）；列表每项多了 `owner`（`core` / `optional` / `installed` / `overlay`）、`bundle`、`kind`、`source`、`writable`；被覆盖的合格插件 `configurable: true, writable: false, reason: overridden`。3 没按建议做：`label` 是所属 bundle 的顶层 `meta.title`，同一 bundle 的条目同名。

App 端（夹具 `bridge_catalog_r14.json` / `plugin_bundles_r14.json` / `bridge_entry_r14_sensevoice.json`，来自真实 r14 Host，本机路径已去掉）：

- **范围**：仍以 7.3 为准（含「只认主机确认过的最新清单」），R7 字段只收窄不放宽——`owner` 是 `core` / `overlay` 或不认识的值、`kind` 不是 `plugin`、`bundle` 不是承载该行的 bundle，都拒绝；两边取交集，任何一方拒绝就拒绝，凭据范围也按同一判断。没有这些字段的旧 bridge 行为不变。
- **只读**：列表 `writable: false` 的条目在 设置 › 引擎参数 › 插件、插件详情、插件清单里副标题标「由配置文件固定」（`host-unavailable` 时标「只读」），页面顶部同样说明；旧 bridge 不标。
- **名称**（`plugin_config_entries.dart`）：bundle 里只有一个可设置条目时用 bundle 标题；有多个时「bundle 标题 · 条目名」。条目名依次取行自己的 `meta.title`、schema 的 `meta.title`（读过表单后）、App 的名称表（官方条目，中英两套）、entryId 的可读形式；只重复包名、与 bundle 标题或同组其他条目重名的标题让位给 entryId。bundle 没有自己的标题时只用条目名。设置搜索用同一套名称，中英都能搜到。
