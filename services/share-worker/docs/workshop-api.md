# 创意工坊 v1 数据合同

2026-11-12。**未在真机上验证**，也尚未部署。实现说明见 [workshop-worker.md](../../../docs/design/workshop-worker.md)，App 一侧见 [workshop-app.md](../../../docs/design/workshop-app.md)。

时间戳均由服务器生成，为 UTC ISO-8601。投稿者以 GitHub 账号为身份：App 自己走 GitHub 设备授权（device flow）取得令牌，每次作者请求带 `Authorization: Bearer <令牌>`。令牌只能是 1..255 位 ASCII 字母、数字或 `_`，缺失或不合形状返回 `401 / workshop_account_auth_required`。令牌仅随本次请求发送，Worker 用它向 GitHub 查一次身份，不出现在响应、日志或持久记录里。管理员沿用 `X-Admin-Key`。

创建、上传、本人列表 / 查看、撤回和举报还必须携带 `X-Workshop-Account-Origin: https://github.com`，说明令牌属于哪个账号体系。Worker 严格等值比较，缺失、空值或不等均返回 `409 / workshop_account_origin`，此时还没有向 GitHub 发出请求；没有省略断言的兼容回退。公共接口及管理员的独立身份门不要求此头。

Worker 校验令牌时只请求 `GET https://api.github.com/user`（15 秒超时、不跟随跳转），带 `Accept: application/vnd.github+json`、`X-GitHub-Api-Version: 2022-11-28`、`User-Agent: dshgo-workshop`。可选变量 `WORKSHOP_GITHUB_API_URL` 只供测试和本地演练换成本机的 HTTPS 替身（只接受不带路径的 HTTPS origin），生产不设置；它只来自部署配置，任何请求都不能指定。GitHub 回 401 时返回 `401 / workshop_account_auth_invalid`，App 应清掉本地令牌重新登录；回 200 且正文是不超过 64KiB 的 JSON、`id` 为正整数、`login` 为不超过 256 码点的文本时，得到作者身份 `Owner = {accountOrigin: "https://github.com", accountId: <GitHub 用户 id>, username: <login>}`。其余情况（403 限流、5xx、网络失败、跳转、正文不合形状）都返回 `503 / workshop_account_unavailable`，稍后重试即可，不代表令牌失效。身份以 `accountId` 为准，GitHub 改名只改变 `username` 的显示。

管理员配置须满足 `ADMIN_KEY.length >= 32`；缺失或过短时返回 `503 / workshop_admin_unavailable`。令 `provided` 为请求头 `X-Admin-Key` 的值；配置通过后，该值须非空、满足 `provided.length <= 4096` 且匹配配置，否则返回 `401 / workshop_admin_auth_required`。

## 公共查询

`GET /api/workshop/v1/capabilities`：

```json
{"schema":1,"features":{"uploads":true,"companion":true},"kinds":["pet","companion"],"licenses":["CC0-1.0","CC-BY-4.0","CC-BY-SA-4.0","MIT","Apache-2.0","BSD-2-Clause","BSD-3-Clause","LicenseRef-Author-Permission"],"account":{"origin":"https://github.com","clientId":"Iv23liExample"},"maxMocVersion":6,"preview":{"schema":1,"sources":["pet-idle","companion-preview"],"format":"png","maxWidth":512,"maxHeight":512,"maxPixels":262144,"maxBytes":2097152},"limits":{"archiveBytes":52428800,"expandedBytes":134217728,"companionMemberBytes":16777216,"companionEntries":1000,"petEntries":256}}
```

`account.origin` 固定为 `https://github.com`。`account.clientId` 是 App 发起 GitHub 设备授权所用 OAuth App 的公开 client id，取自 Worker 变量 `WORKSHOP_GITHUB_CLIENT_ID`；只有匹配 `^[A-Za-z0-9._-]{1,64}$` 时才公布，未配置或格式不对时为 `null`，此时 App 无从发起登录，作者请求也就无法进行。Worker 自己不提供任何登录端点。

`GET|HEAD /market/workshop.json`：

```json
{"schema":1,"generatedAt":"2026-11-11T00:00:00.000Z","features":{"uploads":true,"companion":true},"entries":[{"kind":"pet","id":"sample","version":"1.0.0","minApp":"1.0.13","title":{"zh":"示例","en":"Sample"},"author":"作者","license":"CC0-1.0","source":"https://example.org/sample","url":"/market/workshop/pet/sample/1.0.0/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1234,"blockedVersions":[]}],"withdrawn":[{"kind":"pet","id":"old-sample","version":"1.0.0","reason":"作者撤回","at":"2026-11-11T00:00:00.000Z"}]}
```

大于 20 MiB 的条目不在 `entries` 里，而在可选的 `largeEntries`（结构相同，没有这类条目时省略）：2026-11-15 之前的 App 见到超过 20 MiB 的条目会整份目录判为无效，它们不读这个字段。客户端须把两者合起来，作品身份在两者之间也不能重复。

`/market/companions.json` 是同一状态的 companion 过滤投影，字段仍为 `entries`，没有独立的发布存储。companion 关闭时，投影及其下载返回 503；主目录仍能浏览 pet，并保留所有种类的 `withdrawn`，以便本地处理已安装内容的撤回。目录支持条件 ETag；安装 / 更新前必须向服务器重新验证目录，不能凭失效缓存安装已关闭或已撤回的内容。

`GET|HEAD /market/workshop/<kind>/<id>/<version>/<sha>.zip` 必须匹配当前公开条目、不可变绑定、未撤回；支持 Range / If-Range。仅知道 SHA，或持有 draft / pending / rejected 投稿记录，不会新增公开授权。若另一投稿已使同一 kind / id / version、同一 SHA / size 的资源成为当前条目，后来的待审或拒绝记录不撤销该既有授权。接口不跳转裸桶。

### 公开 PNG 预览

公开预览由投稿 metadata 的可选 `previewSource` 显式启用：pet 只能用 `pet-idle`，companion 只能用 `companion-preview`。省略仍按无公开图投稿，不从文件名、模型纹理、其他投稿或旧版本猜图；显式 null、错误种类或未知模式返回 `workshop_bad_metadata`。声明属于同 requestId 的元数据比较，不能在原请求上悄悄切换。没有 `capabilities.preview` 的旧 Worker 不保证解释该声明；App 声明预览时须在 create POST 前确认能力对象和对应 source，不能自动降成无图投稿。

只接受静态 PNG：字节数 1..2097152，宽高各 1..512，像素数不超过 262144。既有完整 PNG 门继续核 CRC、chunk 顺序、色型 / 位深、zlib / IDAT 和像素，拒绝 APNG；小尺寸 / 字节门先于图片解压。声明后缺图、超限或校验失败会拒绝本次上传，不静默忽略声明，也不改变省略声明时的包接受域。

- `pet-idle`：完整宠物包通过后，取 `states.idle[0]` 指定动画的 `frames[0].i` 那一格，按原 frameW / frameH 裁剪并编码为 RGBA8 PNG，不缩放、不使用整张 sprite 或默认第 0 格。格尺寸超出公开门时拒绝；未声明的合法大格仍可投稿。ZIP 不新增图片成员。
- `companion-preview`：只取 ZIP 中精确的 `character/preview.png`，完整验证后保持原 PNG 字节。该文件必须由作者明确选择；不接受其他路径、JPEG / WebP、SVG 或由模型推测的肖像。它仍受原 ZIP 成员数、压缩 / 展开大小及完整包验证约束。

客户端仍只创建投稿并上传一个 ZIP，没有第二个图片上传步骤。draft 只有声明；首次成功上传进入 pending 时，`submission.preview` 登记固定的五字段。当前公开目录条目使用相同形状，无图时省略而不是 null：

```json
{"path":"/market/workshop/pet/sample/1.0.0/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/preview/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","size":1234,"width":128,"height":128}
```

`path` 严格绑定 kind / id / version / ZIP SHA / PNG SHA；`size` 是 PNG 字节数，不是 ZIP 大小。描述保留到该投稿后续审核或撤回状态。图片先以私有 `workshop/previews/<PNG SHA>.png` 条件创建，再与 pending 状态同次 CAS 登记；重复上传 pending 不重新派生，CAS 失败留下的未登记对象不能公开。新的批准重验原 ZIP 和已登记 PNG 的实际摘要、长度、尺寸及完整 PNG 有效性，不在审核后悄悄重画。图片缺失或存储摘要不符返回 503，不回退成无图。

登记绑定在 submission，不新增永久 Release 图片绑定。相同 release / 相同 ZIP 可以通过新的 requestId、pending 和人工批准，明确改选有图或无图；有图仍须由本次声明的固定来源派生，原图不是自动继承项。Release 仍锁定原 ZIP SHA / size 和作者，旧 withdrawn 版本不能恢复。旧客户端无声明的重投被审核为无图，不能暗中借用旧图。相同图片内容在不同版本的地址仍有不同的版本 / ZIP 部分。

`GET|HEAD /market/workshop/<kind>/<id>/<version>/<ZIP SHA>/preview/<PNG SHA>.png` 无需凭据。每次先读当前权威状态，须有 approved 的 current 投稿精确选择该 descriptor，且对应 Release 的 ZIP SHA / size 一致、版本未撤回，之后才读图片对象。仅有待审记录、PNG SHA 或裸桶对象不会新增授权；若另一个已批准 current 投稿已授权同一地址，后来的待审记录也不会撤销它。被替换、移除图片选择或撤回后，不再被 current 授权的旧地址返回 `404 / workshop_not_found`。

成功返回固定 `image/png`、登记 `Content-Length`、`nosniff`、`Cache-Control: private, no-store`，不跳转。图片请求按客户端单独计数（限流键前缀 `workshop-preview:`），不占目录和包下载的额度。GET 还核实际正文长度与 SHA；HEAD 核 R2 原生摘要 / 长度并不返正文。图片没有 Range / 304 协议，条件头不跳过授权：获准时 GET 为完整 200、HEAD 为无正文 200。关闭 uploads 不隐藏已有公开图；关闭 companion 时对应图片和 ZIP 一样先返回 `503 / workshop_companion_disabled`，主目录仍保留全部 withdrawn。撤回不能追回浏览器已经取得的副本；页面须随目录、来源或条目变化清除不再对应的图片。

## metadata 与投稿记录

```json
{"kind":"pet","id":"sample","version":"1.0.0","minApp":"1.0.13","title":{"zh":"示例","en":"Sample"},"author":"作者","license":"CC0-1.0","source":"https://example.org/sample","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1234,"rightsConfirmed":true}
```

- `id`：小写字母 / 数字，以单个连字符分隔，最多 40 字符。
- `version`：用既有的 `validVersion`（无 build metadata）。
- `source`：必须是 HTTPS 且无用户密码。
- `title`：中英文各最多 120 码点；`author` 最多 256。
- `description`：可选字符串，省略或空字符串表示无简介；非空时最多 512 码点，沿用非空白、无控制字符的文本门。
- `tags`：可选字符串列表，省略或空列表表示无标签；最多 8 条，每条非空白且最多 32 码点，原字符串必须唯一。保留文字和顺序，不做大小写或 Unicode 归一化。
- 这两个展示字段的 null / 错类型拒绝；规范投稿 metadata 和 App 序列化省略空字段。目录与缓存保留非空值，它们不嵌入 ZIP，也不改变既有必需字段及 JSON 大小上限。
- `previewSource`：可选的公开 PNG 声明，模式、硬限、登记与读取合同见上节；它不替代 ZIP 的 SHA / size 或 `rightsConfirmed`。
- pet 包内的 `id` / `author` / `license` / `source` 必须一致。
- companion 的 `character.json` 必须有 `schema=1`、`name`、`model`、`author` / `license` / `source`；`name` 可为模型原名，`model` 为 character 内相对的 `model3.json`；拒绝 runtime 与 `index.json`（后者由安装器重建）。

所有投稿成功响应为 `{submission: 记录}`。记录形状：

```json
{"submissionId":"0123456789abcdef0123456789abcdef","owner":{"accountOrigin":"https://github.com","accountId":42,"username":"sample"},"metadata":{},"status":"draft","createdAt":"2026-11-11T00:00:00.000Z","updatedAt":"2026-11-11T00:00:00.000Z"}
```

`metadata` 是上面的完整对象。`status` 枚举为 draft / pending / approved / rejected / withdrawn。

- pending 增加 `submittedAt` 与 `validation`（`validator`、`files`、`expandedBytes`，以及 `sheets?` 或 `mocVersions?`）；声明公开预览时还增加已登记 `preview`。例外：没有预览功能的 Worker 接过包的投稿会声明了 `previewSource` 却没有 `preview`，按无图处理，客户端不要据此判记录非法。
- approved / rejected 增加 `review: {at, decision, reason}`。
- withdrawn 增加 `withdrawal: {at, reason}`。
- 可选键不存在时省略。

`status` 描述这条投稿的审核 / 撤回历史。approved 不等于当前公开：另一版本上架后，旧投稿仍可为 approved。页面须用重新验证后的 `catalog.entries` 核对 kind / id / version / SHA / size，判断作品版本是否当前公开；公开标题、许可、来源等元数据也以目录为准。entries 不包含 submissionId，不能据此区分多个相同投稿中哪一个 sid 是内部 current。

withdrawn 投稿记录不能恢复。撤回尚未获批准的 draft / pending / rejected 只终止该记录，不新增版本封禁；撤回曾获批准的投稿会撤回整个 release，并更新同 release 的全部已批准记录。版本封禁以目录 withdrawn / blockedVersions 为准，不能仅由某条投稿的 withdrawn 状态推算。撤回当前版本不会自动回退到旧版。

| 请求（前缀 `/api/workshop/v1`） | 请求体 | 成功 |
| --- | --- | --- |
| `POST /submissions` | `{requestId, ...metadata}`；`requestId` 为 16..128 位 ASCII 字母数字 `_-` | 首次 201 返回 draft；同一 `requestId` 且 metadata 一致的重试 200 返回现有状态，`{submission}` |
| `PUT /submissions/<id>/archive` | `application/zip` 原始 ZIP | 200 `{submission}`；验证后为 pending；pending 状态下相同字节重试可 200 |
| `GET /submissions?limit=20&cursor=<id>&status=pending` | 无 | 200 `{submissions:[...], nextCursor: null 或 id}`，仅本人；`limit` 默认 20、最大 100，按 createdAt 降序、同毫秒 id 二进制字典序升序 |
| `GET /submissions/<id>` | 无 | 200 `{submission}`，仅本人 |
| `POST /submissions/<id>/withdraw` | `{reason}`，1..2000 码点 | 200 `{submission}`；上传关闭时仍允许撤回；已撤回幂等 |
| `POST /reports` | `{kind, id, version, reason}`，`reason` 1..2000 码点 | 201 `{reportId}`；只举报曾获批准发布的版本，不自动下架 |
| `GET /admin/submissions` | `?status=pending&kind=pet&limit=20&cursor=<id>`；status、kind 可省略 | 200 `{submissions, nextCursor}`，所有作者；先筛选再分页 |
| `GET /admin/submissions/<id>` | `?filesLimit=50&filesCursor=0` | 200 `{submission, current, inspection}`，下文定义 |
| `GET` 或 `HEAD /admin/submissions/<id>/preview` | `?file=<文件索引>` | 200 私有 PNG / JPEG / WebP；重新核对包绑定、成员 CRC 与预览门 |
| `GET` 或 `HEAD /admin/submissions/<id>/public-preview` | 无，任何 query 均拒绝 | 200 私有读取本 sid 已登记的公开 PNG；先管理鉴权；draft / 无登记图为 404 |
| `GET` 或 `HEAD /admin/submissions/<id>/archive` | 无 | 200 / 206 私有审核 ZIP，Range 可用 |
| `POST /admin/submissions/<id>/withdraw` | `{reason}`，1..2000 码点 | 200 `{submission}`；管理员可撤回废弃的 draft / pending / rejected 以及已批准版本，保留审计与历史 |
| `POST /admin/submissions/<id>/review` | `{decision: "approve" 或 "reject", reason}`，`reason` 1..2000 码点 | 200 `{submission}`；对 pending 的新 approve 重验字节后 CAS；相同终态决策幂等返回 |
| `GET /admin/reports` | `?status=open&kind=pet&limit=20&cursor=<reportId>`；status、kind 可省略 | 200 `{reports, nextCursor}`；先筛选再分页；status 为 open / resolved |
| `GET /admin/reports/<reportId>` | 无 | 200 `{report, target}`，包括被举报版本的当前指向与撤回记录 |
| `POST /admin/reports/<reportId>/resolve` | `{decision: "handled" 或 "dismissed", reason}`，理由必填且 1..2000 码点 | 200 `{report, target}`；处理与审计同次 CAS，不自动撤回版本 |
| `GET /admin/audit` | `?limit=20&cursor=<eventId>` | 200 `{events, nextCursor}`；只读 |
| `POST /admin/releases/withdraw` | `{kind, id, version, reason}`，`reason` 1..2000 码点 | 200 `{withdrawn:{kind, id, version, reason, at}}` |

review 重复相同终态决策不重验、不改变当前公开行或原 review 信息，也不新增审计；对相反终态决策或已撤回记录返回 409。要重新发布未撤回的旧版，须使用新的 requestId，以原 SHA / size 创建新投稿、进入 pending 后再批准；对旧 approved 原 sid 重发 approve 只返回历史记录，不会重新上架。已进入版本撤回账本的 release 不能通过新投稿恢复。

公开查询无需身份。创建、上传、本人列表 / 查看、撤回、举报都需要 GitHub 令牌。外层 UI 先让用户明确确认用 GitHub 账号登录并把令牌交给这个 Worker；数据层不隐式授权。

### 本人投稿的顺序与游标

本人列表在服务端对完整匹配集合按 `createdAt` 新的在前排序，同一毫秒按 `submissionId` 二进制字典序升序；`updatedAt`、审核和撤回时间不参与排序。App 保留服务器返回的页序，不能靠每页本地排序替代这个全局顺序。

`cursor` 仍为上一页末行的 32 位小写十六进制 ID。服务端先从本人全部投稿中解析该行的创建时间，再按本次 status 筛选和严格后续区间分页；锚点刚被审核或撤回而离开当前筛选时仍可续翻。投稿记录不自动删除，`createdAt` 不随状态变化重写。格式正确但不存在于本人记录中的游标与其他作者的游标都返回 400 `workshop_bad_query`，不猜时间、不回到第一页，也不把未知锚点当作列表结束；调用方可明确刷新首页重新开始。

多页是实时视图，不是跨请求快照。翻页期间出现在游标前方的新投稿或新进入筛选的行需要刷新首页；位于游标后方的行可在后续页出现，离开筛选的行不再返回。同毫秒的新行也按同一 ID 比较规则落在前方或后方。更改 status 应从无 cursor 的首页开始。

## 审核台与管理详情

`GET|HEAD /workshop/admin` 是 Worker 托管的公开单页，内联 CSS 和脚本，不包含投稿数据或密钥。`wrangler.jsonc` 的 `assets.run_worker_first` 显式包含该路径，同名静态资产不能替换它的路由和 CSP。脚本 CSP 使用该版本内联脚本的精确 SHA-256，连接仅同源；不允许任意内联脚本、外部资源、嵌入页面或包内脚本 / 模型执行。

页面输入的管理密钥只留在这个标签页的内存，退出或 pagehide 时清除，不进 URL、日志或持久存储。所有 `/api/workshop/v1/admin/…` 数据端点在读取状态、ZIP 或解析正文前先鉴权；成功与错误都为 `Cache-Control: private, no-store`。JSON 与图片使用 `nosniff`、同源资源策略和 `no-referrer`。鉴权只证明持有共享管理密钥，不能辨认是哪位自然人。投稿文本、文件路径、原因均按纯文本显示；图片用带密钥的同源 fetch 取得 Blob，再交给图片元素。

管理投稿与举报列表的 `limit` 默认 20、最大 100，`cursor` 为上一页最后一个 32 位小写十六进制 ID。ID 按二进制字典序升序，不是按提交时间排序。状态 / kind 筛选先于分页；多页仍是实时视图，不是跨请求快照。审核台待审页使用 `status=pending`；也可查看已批准历史以撤回版本。审核、拒绝、撤回、举报处理前须确认目标与理由，操作后 GET 具体投稿或举报再核对。连接断开、超时或服务端写结果不确定时，不能把失败提示当作未执行，更不能自动重发另一种决策。

### 投稿详情和文件清单

详情返回完整 `submission`、布尔 `current` 和 `inspection`。`current` 表示内部当前指针是否精确指向此 submissionId；同版本 / 同字节的其他投稿不等于这个 sid。这个字段不包含功能开关造成的临时隐藏，不单独证明当时的公开下载可用。

`inspection` 字段如下：

| 字段 | 合同 |
| --- | --- |
| `status` | `valid`：当前完整包校验通过；`invalid`：当前复核遇到错误；`not_uploaded`：未有已校验上传包。均不改变审核状态。 |
| `validator` | 当前校验器标识；与 `submission.validation` 中上次上传 / 批准时的标识区分。 |
| `summary?` | 当前完整复核通过时才有：`validator`、`files`、`expandedBytes`、`sheets?` / `mocVersions?`。 |
| `checks` | `{level: "pass" / "error" / "info", code, message}` 列表。完整验证器遇到第一个阻断错误即停止；返回该错误及审核台自身的范围提示，不声称汇总了全部潜在问题或旧校验器本不存在的 warnings。 |
| `files` | 当前页的常规文件，行形状见下文；ZIP 目录项不作文件行。 |
| `nextFileCursor` | 下一页索引的十进制字符串，或 `null`。 |

文件行是 `{index, path, size, compressedSize, preview, previewIssue}`。`path` 为完整原路径，不截断或默默改名；`size` 是 ZIP 声明的展开字节数，`compressedSize` 是压缩成员字节数。完整验证通过时成员读取也核过实际长度与 CRC；复核失败时不要把所有声明大小标成已经展开验证。索引按路径二进制字典序从 0 起，绑定该投稿不可变 ZIP；预览 URL 只由 sid 与索引生成，不接受远程图片 URL。

`filesLimit` 默认 50、最大 100；`filesCursor` 默认为 `0`，只接受 0..1000 的规范十进制字符串。每页文件行 JSON 合计不超过 512KiB，达到字节或行数门时返回下一游标，后续仍可取完整清单。包仍受 20MiB 压缩、64MiB 展开和最多 1000 条归档成员的既有门约束。详情逐成员检查，不缓存全部解压成员，也不把文件清单或图片存入状态对象。详情及预览沿用 `READ_LIMIT`；达到限制返回 429。

完整包校验失败时，能安全读取的 ZIP 清单仍可显示；某张图片预览失败只在该行给出 `previewIssue: {code, message}`，不阻止人工审查其他元数据 / 文件。ZIP 目录本身不能安全读取时，详情保留元数据和错误提示，文件列表为空。R2 不存在、原生摘要 / 长度不匹配或读取失败仍返回 503；不伪造一个有效清单。

### 包内图片的私有预览支持域

本节是 `/preview?file=<索引>` 的审核工具，与上一节的公开 PNG descriptor 及固定 `/public-preview` 端点分开；其 8MiB / 4096 上限不会放宽公开图的 2MiB / 512 门。

只考虑 `.png`、`.jpg` / `.jpeg`、`.webp`，大小非零且不超过 8MiB，宽高各不超过 4096，宽×高×4 不超过 16MiB。这是预览政策，**不改变投稿包接受域**。通过后 `preview` 为 `{url, mediaType, width, height, validation}`；否则是 `null`。非图片文件的 `preview` 与 `previewIssue` 都是 `null`。

- PNG 的 `validation="full-png"`：复用完整 CRC、压缩流、元数据和像素重建验证，拒绝 APNG 的 acTL / fcTL / fdAT。
- JPEG 的 `validation="structure-only"`：支持普通 8 位 Huffman 顺序 / 渐进 DCT（SOF0 / SOF1 / SOF2）；检查 SOI、单帧尺寸、段边界、扫描头、字节填充 / 重启标记边界和最终 EOI。分层、算术、无损或延迟高度等编码不预览；不熵解码或证明像素内容正确。
- WebP 的 `validation="structure-only"`：支持静态 VP8 / VP8L 及对应扩展容器，核 RIFF 长度、块边界 / 补零、单张图像、画布与位流头尺寸；允许受支持的 alpha / ICC / EXIF / XMP 结构，拒动画旗标、ANIM / ANMF 和未知扩展块。不执行完整 VP8 / VP8L 解码。

JPEG / WebP 结构门不等于完整图像解码；浏览器仍可能拒绝图片，页面须提供可恢复的载入失败提示。PNG 完整验证也不构成所有浏览器实现或设备内存的安全证明。这里的 16MiB 只是名义 RGBA 载荷门，不是进程内存峰值。格式依据：[ITU-T T.81 Annex B](https://www.w3.org/Graphics/JPEG/itu-t81.pdf)、[WebP RIFF](https://developers.google.com/speed/webp/docs/riff_container)、[VP8 帧头 §9.1](https://datatracker.ietf.org/doc/html/rfc6386#section-9.1)、[VP8L 位流头](https://developers.google.com/speed/webp/docs/webp_lossless_bitstream_specification#riff-header)。

图片端点每次先核管理身份，再校验 R2 原生 SHA / 长度、同一归档目录、选定成员 CRC 和格式门。固定返回 `image/png`、`image/jpeg` 或 `image/webp`，不跟随文件里的链接，不返回 SVG / HTML。GET 返回原图片字节；HEAD 同样校验而不返正文。预览不提供 Range / ETag 缓存协议。

### 审核本次登记的公开图

详情的 `submission.preview` 表示本次投稿的公开图选择；文件行的 `preview` 只是包内图片查看能力。`GET|HEAD /admin/submissions/<sid>/public-preview` 先鉴权并按本 sid 取登记，不借 current 或其他投稿的图片，也不接 `file` / 任意路径参数。所有 query 返回 `400 / workshop_bad_query`；draft / 无登记 descriptor 返回 `404 / workshop_not_found`。已登记但被拒绝或撤回的投稿仍可由管理员读取该图，便于复核；这不恢复公开授权。成功头、实际 GET 摘要与 HEAD 无正文合同同公开 PNG，仍为私有、不缓存。

审核页通过带管理头的同源 fetch 取得 Blob，核 descriptor 的固定路径、PNG 类型、字节数与 SHA，再核已验正文中 IHDR 的原始像素尺寸；图片成功载入后，才开放有图投稿的批准按钮。浏览器的 naturalWidth / naturalHeight 是可经方向、密度修正的 CSS 尺寸，不拿它们与原始像素数强制相等。失败可手动重读，元数据、文件清单及拒绝操作仍可用；无图投稿明确显示无图，不借用旧图。批准前的人工内容判断仍不可省略，页面载图门也不代替服务端批准时的重新校验。

### 举报处理和审计

管理接口返回的举报行为 `{reportId, kind, id, version, reason, reporter, createdAt, status, resolution?}`，`reporter` 是 `Owner`。没有 `resolution` 的旧形状显示为 `status="open"`；处理后为 `resolved`，增加 `resolution: {at, decision: "handled" / "dismissed", reason, actor: "admin"}`。两种决策分别表示已处理与无需处置；均不自动下架。

单条举报 GET 和 resolve POST 还返回 `target: {release, current, withdrawal}`：`release` 为永久绑定记录（kind / id / version / SHA / size / owner / approvedAt），`current` 表示内部当前指针是否指向该版本，`withdrawal` 是当前撤回记录或 `null`。需要下架时另调已有 `/admin/releases/withdraw` 并再次 GET 此举报核对目标；标记举报处理不能代替撤回。

处理是终态。同一决策的重试返回首次理由、时间和结果，不再写审计；改为另一决策返回 `409 / workshop_report_state`。处理和 `resolve_report` 审计在同一个状态 CAS 中提交；冲突返回 `workshop_state_conflict`，应先 GET 核对获胜结果。若响应丢失，记录可能已经提交；GET 后再决定是否显式重试同一决策。

审计行是 `{eventId, at, action, actor, submissionId?, releaseId?, reportId?, reason?}`。action 为 create / submit / approve / reject / withdraw / report / resolve_report；`actor="admin"` 仅代表共享管理密钥，其余 actor 是 GitHub 作者 `Owner`。相关 ID 给出目标，不从密钥或密钥摘要捏造操作者姓名。审计按 eventId 分页，至少保留 186 天；只在之后一次状态写入中清理更早事件。举报处理记录、永久版本绑定和撤回记录不随这项审计清理删除。

### 状态容量与部署前提

状态对象仍为私有 `workshop/state-v1.json`、schema 1、8MiB 上限。令 B 为提交时 JSON 的 UTF-8 字节数，N 为未撤回投稿数，R 为未撤回 release 数，U 为未处理举报数，A 为保留的审计数。写入必须同时满足：

- `B + 24576×N + 12288×R + 20480×U <= 8388608`；
- `A + N + R + U <= 20000`，以及原 `withdrawn.length + R <= 4000` 和各数组上限。

新增 20KiB 预留与撤回预留相加。每个处理理由最多 2000 码点，现有文本门使两份理由的 JSON 字符载荷至多 16000 字节，剩余空间覆盖处理记录与审计固定字段。处理一条举报释放它的字节预留和一个审计槽，再写入一次终态 / 审计；从这些新预算接纳的状态出发，不挤占既有撤回能力。

读取无 resolution 的旧形状不等于任意旧容量状态都能直接升级写入：旧 writer 没有预留举报处理容量。首次上线从该私有状态对象不存在开始；共享桶中其他分享 / 下载对象不受此要求影响。若对象已存在，先保留备份并核对新预算，暂停无条件首次部署；不要删历史、混写旧 / 新 writer，或把 R2 数据当成部署版本的一部分。

写入 `resolve_report` 后，原先不认识该 action 的校验器会拒绝状态。回滚只选择理解新 resolution、审计 action 及预留规则的构建；Worker 版本回滚不会回滚 R2。旧 / 外写状态的迁移不由此接口自动完成。

## 失败

失败响应固定为 JSON `{error: "workshop_<code>"}`，不含底层异常、GitHub 响应正文或凭据。GitHub 响应过大、格式不符、身份不明时失败关闭。

| HTTP | code（统一加 `workshop_` 前缀） | 含义 |
| --- | --- | --- |
| 400 | `bad_metadata` / `bad_request` / `bad_request_id` / `bad_query` / `bad_reason` / `bad_decision` / `bad_file_cursor` / `bad_limit` | 输入无效 |
| 400 | `archive_*` / `json_*` / `pack_*` / `sheet_*` / `png_*` / `inflate_*` / `zlib_*` / `pet_extra_file` / `companion_*` | 包验证失败；本次操作未完成上传 / 批准，已有投稿状态以重新查询为准 |
| 400 | `preview_size` / `preview_dimensions` / `preview_format` / `preview_unsupported` / `preview_animated` | 该图片不能预览；详情会在对应文件行给出具体 code 和说明，仍可继续人工审查 |
| 400 | `preview_missing` / `preview_size` / `preview_dimensions` | 已声明公开预览但缺少固定 PNG、超过字节或尺寸门；本次上传不完成新登记，不会静默改成无图，已有投稿状态以重新查询为准。PNG 内容错误沿既有 `png_*` / `inflate_*` / `zlib_*` 码 |
| 401 | `account_auth_required` / `account_auth_invalid` / `admin_auth_required` | 身份失败：缺少或不合形状的令牌 / GitHub 拒绝令牌 / 管理密钥不对 |
| 404 | `not_found` | 无记录 / 非本人 / 非公开资源 |
| 405 | `method_not_allowed` | 方法不支持 |
| 409 | `account_origin` | 作者请求缺少 `X-Workshop-Account-Origin`，或它不是 `https://github.com`；尚未向 GitHub 请求身份 |
| 409 | `request_id_reused` / `state_conflict` / `submission_state` / `report_state` / `version_rewritten` / `owner_conflict` / `version_withdrawn` | 并发、处理终态或不可变冲突，GET 重新核对 |
| 413 | `body_too_large` | 大小超限 |
| 415 | `content_type` | 需要 `application/json` 或 `application/zip` |
| 422 | `size_mismatch` / `sha_mismatch` | 字节与 metadata 不同 |
| 429 | `rate_limited` | 限流，带 `Retry-After` |
| 503 | `upload_disabled` / `companion_disabled` | 紧急开关关闭 |
| 503 | `account_unavailable` / `admin_unavailable` / `storage_unavailable` / `state_invalid` / `capacity` / `moc_policy_unavailable` / `inspection_page_size` | 服务或维护错误 |

提交超时不能证明未写入：用同一 `requestId` 重试创建，并 GET 原 submissionId 核对状态。CAS 冲突返回 409，孤立的私有 blob 不会成为已批准。分页是实时视图，不承诺并发写入时的快照一致性。moc 上限 6 依据仓库 `tooling/companion/fixtures/live2d-core-sources-v1.json` 保存的历史测量，不证明 Core 一致性、当前 runtime 身份或 GPU / 真机表现。
