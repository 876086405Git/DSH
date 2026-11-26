# DS Bot 联动设计

> 2026-10-24。roadmap P3 #3「DS Bot 联动」的定稿。DS Bot（[Fei2411/DeepSeek-Bot](https://github.com/Fei2411/DeepSeek-Bot)，Apache-2.0）是把 DSH 变成一组长期 Bot 的插件：主 Bot「Chief」、用户自建的 Bot（各有记忆和模型）、带管理员的群聊、@ 点名、Bot 之间派活。DS Bot 侧的接口说明在它仓库的 `docs/plans/2026-10-24-mobile-api.md`（分支 `dsh-app-mobile`）。

## 0. 结论

- **手机是 DS Bot 的一等客户端，原生画，不嵌网页。** Bot 首页、私聊、群聊、Bot 详情、群详情、新建 Bot / 群聊都是原生页。
- **协议走 DS Bot 自己的通道**：本机和 SSH 走 `POST /api/bot` + `GET /api/bot/feed`（SSE），和它的桌面应用一样；同一套调用也注册成 DSH Remote 方法 `dsBot/call` + `dsBot/feed`（流），给只转发 Remote 方法的中继用。上面是「移动端 API v1」（握手、群聊条目、提醒补发、头像引用、直接改记忆、用量汇总），两边都改了。
- **跟着当前主机走**：主机切换器选本机，Bot 页就是手机里那个 DSH 的团队；选 NAS，就是 NAS 上的团队。本机没装就一键「安装 DS Bot」。
- **SSH 能用；中继走 Remote 方法**：手机在中继上通过 `dsBot/call` 和 `dsBot/feed` 访问 DS Bot。远端需启用 DS Bot，并使用包含 [ds-harness-remote #605](https://github.com/liguobao/ds-harness-remote/pull/605) 的 Host 插件版本；发布版 `0.6.8` 尚未包含这一改动。
- **通知由 Bot 自己发**：DS Bot 的提醒（Bot 说话、群里发言、交活、等你回答 / 批准）变成「Chief：……」这样的系统通知；通用的「一轮完成」通知跳过 DS Bot 的会话，不然一句话会响好几次。

## 1. 两种形态

| | 本机 | 远程（NAS / 电脑） |
|---|---|---|
| DS Bot 在哪 | 手机里 DSH 的 `ds-bot` 插件 | DS Bot 的 Docker 镜像，或电脑上 `dsh web` + 插件 |
| 怎么连 | 本机 HTTP（现有 `DshHttpCarrier`） | SSH 隧道：同一个 `DshHttpCarrier`，原样可用；中继：Remote 方法 `dsBot/call` / `dsBot/feed`，白名单放行后可用 |
| 没装时 | 「安装 DS Bot」：走插件页同一条安装流程（`runPluginInstall`，包名 `ds-bot`），装完提示重启引擎 | 显示在那台电脑上要执行的命令，不远程装（远程装插件要重启对方的 DSH） |
| 版本太旧 | 「更新 DS Bot」：同一条流程，`replaceInstalled` | 提示到那台电脑上更新 |
| 后台 | 本机引擎有前台服务，feed 一直连着 | 尽力而为：App 进程活着、链路通时才收得到（与现有远程通知一致） |

手机本机跑团队的代价要说清楚：Bot 的每一轮都在手机的 proot 里跑，群聊一轮要叫几个模型、跑几个会话，耗电和内存都明显高于普通对话。适合「随身带一个 Chief」，重活交给 NAS。

## 2. 协议契约（App 依赖的部分）

传输：HTTP carrier 上用 `DsBotHttpTransport`（`DshConnection` 的地址、`Host` 头和会话 cookie，`connection.dart` 不改）；其他 carrier 上只要放行了 `dsBot/call` 和 `dsBot/feed`，就用 `DsBotRpcTransport`（`rpc.call` + `mux.open`），回答和错误与 HTTP 一样。都不通时 `DsBotApi.of(client)` 返回 null；中继拒绝（`METHOD_NOT_ALLOWED`）也算「中继」。两种情况页面都显示「中继连接暂不支持 Bot」。

| 用途 | 接口 / 事件 | 来源 |
|---|---|---|
| 握手 | `hello {client, api:[1]}` → `api / apiMin / apiMax / capabilities / boot / seq / plugin.version / readOnly` | 新增 |
| 团队 | `state {since, avatars:'ref'}`（`unchanged` 时只带 live） | 已有 + 新参数 |
| 头像 | `avatar {botId}` → `{ref, image}`，按 `ref` 缓存 | 新增 |
| 私聊 | `chat {botId, cursor}`、`send {sessionId, text}`；feed `message` / `stream` | 已有 |
| 群聊 | `room-chat {roomId, cursor}` → 带发言人的条目、`running`、`speaking`；feed `room` | 新增 |
| 提醒 | feed `notice`；`notices {boot, since}` 补发，`reset` 时重读团队 | 新增 |
| 卡片 | `answer-question`、`dismiss-question`；群成员审批 `approval-answer` | 已有 |
| 管理 | `create-bot` / `update-bot` / `delete-bot` / `set-main` / `create-room` / `update-room` / `delete-room` / `stop-member-work` | 已有 |
| 记忆 | `memory-view` / `memory-forget`；`memory-add` / `memory-edit`（不经模型） | 已有 + 新增 |
| 用量 | `usage-summary {botId}` → 近 24 小时 / 7 天 / 30 天、按模型 | 新增 |
| 中继 | Remote 方法 `dsBot/call {endpoint, payload}`、流 `dsBot/feed {}`（每项 `{event, data}`）；`hello.rpc`、能力 `rpc` | 新增 |

**版本规则**（两边都按这个演进）：

- 只加东西（新接口、新字段、新条目 / 提醒种类、新 feed 事件）不升 `api`，写进 `capabilities`；客户端一律跳过不认识的字段和种类。
- 会让旧客户端读错的改动才升 `api`，服务端在 `apiMin..apiMax` 内都回答；App 发它会的版本列表，拿交集里最高的。
- 没有 `hello`（`bot/not-found`）= DS Bot 太旧；`api: null` = 没有交集。两种都显示「更新 DS Bot」，本机一键更新。
- App 用到某个可选能力前先看 `capabilities`（比如 `memory-edit` 不在就只给删除）。

**断线与补发**：feed 断了按 0.5 / 1 / 2 / 5 / 10 秒退避重连；每次 `hello` 带 `boot` 和 `seq`，App 记着上次的，先 `notices {boot, since}` 补上错过的，再按需重读 `state`。回到前台、网络切换、主机重连都走这一条。

## 3. App 页面

| 页面 | 骨架 | 内容 |
|---|---|---|
| Bot 首页 | C 列表 | 大标题「Bot」+ 一行状态（「本机 · 4 个 Bot」）→「Bot」组：主 Bot 置顶（小「主」标），其余按最近活动；行 = 40 头像（照片 / 首字 + Bot 色）、名字、最后一句或「正在运行命令」、时间、未读数 →「群聊」组：成员头像叠放、群名、「Writer：最后一句」→ 底部「新建 Bot」「新建群聊」两行 |
| Bot 私聊 | 聊天 | 复用聊天页的 `Composer`、`MarkdownBody`、`UserBubble`；顶栏 = 返回 + 头像名字 + 状态（「正在思考」「正在运行命令」）+ 详情；条目来自 `chat` 分页（跨段连成一段对话），feed 的 `stream` 实时打字；提问卡、等模型卡、待批准 |
| 群聊 | 聊天 | 每条发言带头像 + 名字（同一人连续发言合并）、「管理员」小标、一轮里的事件行（「Writer 开始干活」「Writer 完成了工作」）；正在说话的成员显示「Coder 正在输入」；输入框上方 @ 成员选择条 |
| Bot 详情 | B 详情 | `PageHero`（头像、名字、角色、三格数据：今日 tokens / 记忆条数 / 所在群聊数）→ 资料（模型（复用 `showModelSheet`）、名字、角色、说明、颜色）→ 记忆（概要、列表、编辑、删除、添加）→ 用量（日 / 周 / 月、按模型）→ 完整记录、设为主 Bot → 删除 |
| 群详情 | B 详情 | 待批准 +「允许本次 / 拒绝」→ 成员（管理员标；正在干活的带「停下」；点开：私聊 / 设为管理员 / 移出群聊；添加成员）→ 谁先回答（管理员先答 / 全员轮流）、群名、群公告 → 群记忆 → 删除群聊 |
| 新建 Bot | D 表单 | 名字、角色、说明、颜色、模型；底部固定「创建」 |
| 新建群聊 | E 弹层 | 群名（可空）、勾选成员（2–12 个）；管理员用 DS Bot 的默认（成员里的主 Bot），建好后管理员先打招呼；「创建」 |

决定：

- **私聊用 DS Bot 的条目，不直接套通用聊天页。** Bot 的私聊横跨多段会话（上下文满了换段），段首是交接包，中间有 Bot 之间的隐藏回合，通用聊天页会把这些当成用户消息画出来、换段后像清空了一样。条目由 DS Bot 拆好，手机只管画。代价是工具调用的细节不显示；详情页留一个「完整记录」入口，用通用 `ChatList` 只读打开当前段，需要时看得到每一步。
- **群聊的发言人规则只在服务端一份**（`room-chat`），手机不拆 `group_relay`。
- **未读按设备算**：不在看的那个 Bot / 群，每来一条提醒未读加一，打开就清零。DS Bot 不存已读；手机记着每台主机读到的提醒序号（`boot` + `seq`），App 重开、断线重连后先补读错过的提醒。
- **前台不弹横幅**：在 App 里时只更新未读点；切到后台才发系统通知。正在看的那个 Bot / 群不提醒。

## 4. 通知

| DS Bot 提醒 | 系统通知 | 渠道 |
|---|---|---|
| `message`（Bot 在私聊里说话） | 标题「Chief」，正文是那句话 | 「一轮结束」 |
| `group`（群里发言） | 标题「群名」，正文「Writer：……」 | 「一轮结束」 |
| `done`（交活） | 标题「群名」，正文「Writer 完成了工作」 | 「一轮结束」 |
| `question` / `view` | 「Chief 问你：……」 | 「需要你确认」 |
| `approval` | 「Writer 等你批准：bash」 | 「需要你确认」 |

- 每个 Bot / 群一组（`notifyGroup(host, 'dsbot:<id>')`），新的替换旧的，打开对应页面时清掉。锁屏只写「Bot 有新消息」。
- 复用 `NotifyChannel` 和设置 → 通知里的开关：`message` / `group` / `done` 跟「一轮完成」，`question` / `view` 跟「提问」，`approval` 跟「审批」。
- **去重**：通用的 `HostAlertTracker` 会对 Bot 的私聊段、群会话、成员在群里的隐藏会话各弹一次「一轮完成」，标题还是内部会话名（「Writer · 群名」）。DS Bot 在时，这些会话交给 Bot 通知，通用通知跳过（一行接线，见 §6）。
- **点通知**：`kind` 为 `dsbot-bot` / `dsbot-room`，`sessionId` 放 Bot / 群 id，点了打开对应页（一行接线）。

## 5. 两边改了什么

**DS Bot（分支 `dsh-app-mobile`，基于 `dev`，4 个提交，未推送）**

- `src/host/mobile.js`（新）：`hello`、`notices`（内存环形缓冲 200 条、`boot` 区分重启）、`room-chat`（从群会话拆出发言人条目，进行中的一轮就地放上目前的发言、id 前后一致）、`avatar` 与 `state {avatars:'ref'}`、`usage-summary`、`memory-add` / `memory-edit` 路由。
- `feed.js`：新事件 `notice`、`room`；`hello` 带 `api / boot / seq`。
- `groups.js` / `tools.js` / `approvals.js`：在记下一行群聊、出提问卡 / 视图卡、等批准的地方各加一个钩子产生提醒。
- `memory.js`：`memoryEdit` / `memoryAdd`，检查与工具相同。
- 测试 `test/mobile.test.js`（9 个）、`test/remote.test.js`（2 个）、`install.test.js` 顺序表；变基到 `dev` 后全量 974 个（972 通过、2 个原本就跳过），lint 没有新增告警，`client.js` 未动。
- `src/host/remote.js`（新）：`dsBot/call`、`dsBot/feed` 两个 Remote 方法，`TypertRemoteService` + 手动套上的 `@Remote` 标记（纯 JS 插件没有 Typert 生成器，由 Gateway 的源码模式服务），只在有 Typert Gateway 时挂载；`feed.js` 加订阅接口，和 SSE 同一份事件。用一次性 DSH 实测过：一元调用、流、断开重开都通。
- 文档 `docs/plans/2026-10-24-mobile-api.md`（中文，按它仓库的约定）。

为什么改 DS Bot 而不是让手机自己拼：群聊的拆法、提醒的判定、头像的体积都是服务端最清楚，也只有放在服务端，桌面应用和以后的其他客户端才能共用。网页版用的接口和事件一个没动。

**dsh-go**

- `packages/dsh_client/lib/src/dsbot_api.dart`（新）：两种传输（HTTP 路由、Remote 方法）、模型、全部接口、自动重连的 feed、Bot 颜色算法（与 DS Bot 的 `defaultColor` 同一结果，有对照测试）。
- `app/lib/state/bots_state.dart`（新）：当前主机的 DS Bot 状态（未装 / 太旧 / 中继不支持 / 就绪 / 出错）、团队与 live 状态、feed 与补读、私聊和群聊控制器、未读与 Bot 通知、头像缓存、记忆与用量。
- `app/lib/ui/bots/`（新）：`bots_page`（首页）、`bot_chat_page` / `room_chat_page`（聊天）、`bot_chat_kit`（顶栏、页面框架、消息行、提问卡 / 视图卡 / 选模型卡）、`bot_details_page` / `room_details_page`、`memory_card`、`new_bot_page`、`new_room_sheet`、`bot_mention`（@ 选择条）、`bot_avatar`、`install_card`、`bot_sheets`、`bot_alerts`（外壳接线用）、`drawer_row`（抽屉里的「DS Bot」一行）、`bot_format`。
- 测试 `app/test/bots/`：状态与纯函数、页面流程、几何、8 组浅色 + 深色 golden。另外用真实的一次性 DSH（`ds-bot` 分支 + 它的 mock 模型）跑过一遍状态层：发消息 → 回复 → 后台通知 → 未读，群聊一轮 → 带发言人的条目。

## 6. 需要别处接的线

| 位置 | 改动 | 原因 |
|---|---|---|
| 抽屉 / 全部功能 | 加入口「Bot」→ `Navigator.push(BotsPage.route())`（`ui/bots/bots_page.dart`），图标 `Icons.smart_toy_outlined`；角标可用 `ref.watch(dsBotInboxProvider).total` | 首页入口 |
| `notify_state.dart` `ChatAlertsController._onAlert` 第一行 | `if (ref.read(dsBotSessionFilterProvider)(alert.host, alert.sessionId)) return;` | 通用「一轮完成」等通知跳过 DS Bot 的会话 |
| `ui/notify/chat_alert_host.dart` `_onTap` 的 `if (!mounted) return;` 之后 | `if (openDsBotTap(context, tap)) return;` | 点 Bot 通知打开 Bot / 群聊页 |
| `ui/shell/sessions_drawer.dart` 取会话列表处 | `final hidden = ref.watch(dsBotOwnedSessionsProvider);` 再 `.where((s) => !hidden.contains(s.sessionId))`，列表最前放 `DsBotDrawerRow(onOpen: …)`（`ui/bots/drawer_row.dart`，没有 DS Bot 时不占位） | Bot 的会话折成一行「DS Bot · 3 个 Bot」，带未读数 / 运行点 |
| `packages/dsh_remote/lib/src/carrier/tunnel_carrier.dart` 的 `harnessRemoteAllowlist` | 放行 `dsBot/call` 和 `dsBot/feed` | 旧 Host 仍可拒绝；本机和 SSH 的 HTTP 路径不变 |
| `ui/shell/home_shell.dart` 外壳的 Stack 里（`ChatAlertHost` 旁） | `const BotAlertsHost(),` | Bot 通知跟着外壳活着，回到前台时重连 feed |
| `ui/chat/composer.dart` | 加 `final String? hintText;`（构造里 `this.hintText,`），`hint` 的最后一支改成 `: widget.hintText ?? '给 DSH 发消息…',`；然后 `bot_chat_page.dart` 的 `Composer(` 里加 `hintText: '给 ${bot.name} 发消息…',`，`room_chat_page.dart` 里加 `hintText: '在群里说点什么…',` | Bot 页的占位文字 |

@ 选择条是自带的：`BotMentionController(input: 文本控制器, members: 成员, admin: 管理员 id)` + `BotMentionPicker(controller: …)`，群聊页把它放在输入框上方，`Composer(onKeyEvent: mentions.handleKey)` 接硬件键盘。输入框左键与发送键镜像：群聊是 40 圆的「@」键（`MentionKey`，点了插入 `@` 并打开成员列表），私聊没有附件（DS Bot 的 `send` 只收文字），左边留一个同尺寸的空位（`ComposerSeat`），正文起点和主聊天一致；几何测试按 `composer_geometry_test.dart` 的端盖规则量过。

## 7. 风险

- **最可能出问题的地方**：feed 是一条长连接，Android 后台、SSH 隧道重连、DSH 重启都会断。补发只保证「重启前的提醒」不丢；DSH 重启期间的提醒会丢（服务端不落盘），手机只能重读团队、用列表里的最后一句兜底。
- **反对这个方案的最强理由**：它把 DS Bot 绑进了 dsh-go 的维护面，DS Bot 改一次群聊的内部格式，手机就可能画错。缓解：格式拆解留在 DS Bot 的 `room-chat` 里，手机只依赖条目；版本规则让 DS Bot 可以先加字段、手机后跟上。
- 手机本机跑群聊很重（§1）。
- 首次打开 Bot 页会让 DS Bot 自动建出 Chief（`state` 的既有行为），Chief 先等用户选模型才打招呼。

## 8. 已定（2026-10-24，owner 委托决定）

1. **中继**：DS Bot 的接口同时做成 DSH Remote 方法（`dsBot/call`、`dsBot/feed`），本机 / SSH 仍走 HTTP；中继上 `DsBotApi.of` 自动用 Remote 方法。双方白名单都必须放行这两个方法（§6）。
2. **推送**：先不做；远程 Bot 的消息在 App 活着时到。
3. **抽屉**：Bot 的会话不散在列表里，折成一行「DS Bot」（`DsBotDrawerRow`），点进 Bot 首页。
4. **预装**：不预装，保留一键安装。
5. **DS Bot 分支**：已在本地变基到 `dev`，测试和 lint 通过；是否推送、提 PR 由 owner 在会话里确认后执行。

## 9. 仍然开放

- 中继端到端验证需要部署包含 #605 的 Host 插件；旧 Host 返回 `METHOD_NOT_ALLOWED` 时仍显示中继不支持。
- Remote 方法走 Gateway 的源码模式：参数和回答只校验是 JSON，不按生成的类型校验。DSH 若给插件开放生成器或手写描述的注册方式，再换成严格模式。
