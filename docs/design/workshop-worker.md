# 创意工坊 Worker：投稿、审核与公开下载

2026-11-12。**未在真机上验证**，没有用真实 GitHub 账号走过投稿；下面的行为依据源码和本地测试，上线前要做的事在文末。

权威入口是 `/market/workshop.json`，`/market/companions.json` 是它的过滤投影；既有的 `/market/pets.json`、适配表和定时同步保留原发布路径。权威对象与旧宠物市场分开，是因为原 Cron 会从维护者的上游目录同步宠物：把用户投稿直接写到旧对象，会被后一次同步覆盖。

协议的精确请求 / 响应、错误码和分页见 [workshop-api.md](../../services/share-worker/docs/workshop-api.md)，公开目录 schema 见 [workshop.schema.json](../../market/schema/workshop.schema.json)。App 一侧见 [workshop-app.md](workshop-app.md)。App 应按 kind 分派安装器，忽略未知 kind；以后追加 wallpaper、launch、theme、card 的能力与验证器不要求改写旧 pet / companion 行。

## 状态和发布

私有 `BUCKET` 的 `workshop/state-v1.json` 是唯一权威对象。一次 R2 条件 PUT 原子提交投稿状态、公开当前版本、永久版本绑定、作者绑定、撤回记录、举报和审计。更新用读取到的 ETag 做 `If-Match`；首写用 `If-None-Match: *`。CAS 输家返回 409，不覆盖胜者。存储异常返回 503，不能从异常推断远端未写；客户端用同一 `requestId` 重试创建，再 GET 原 submissionId 核实。

ZIP 先完整验证，再以 `workshop/blobs/<sha>.zip` 创建一次；R2 还核对原生 SHA-256。blob 在审核通过后仍留在私有桶，没有公开可访问的裸桶路径。blob 已存在不是审批凭据；对 pending 投稿执行新的批准时，重新读实际字节、核 size / SHA，再执行当前验证器，最后提交权威状态。

投稿状态机是 draft → pending → approved / rejected；作者可从这些状态撤回，withdrawn 记录不能恢复。status 描述单条投稿的审核 / 撤回历史。批准另一版本会替换这个 kind / id 的当前公开行，旧投稿仍可保持 approved；因此 approved 不能直接显示为「当前公开」。页面须根据重新验证后的目录，核对 kind / id / version / SHA / size 判断作品版本是否当前公开，并采用目录中的公开元数据。目录没有 submissionId，不能区分多个相同投稿中哪一个 sid 是内部 current。

新 id 在首次批准时绑定账号来源（`https://github.com`）+ 数值 GitHub 用户 id；draft 不占有 id。版本首次批准后绑定 kind / id / version / SHA / size；升级、撤回、当前行消失均不删历史。未撤回旧版可使用新的 requestId，以原 SHA / size 创建新投稿，上传成为 pending 后再由管理员批准为当前版；相同版本不同字节、另一作者接管、恢复已写入撤回账本的版本都被拒绝。重复对原 approved / rejected 记录发送相同审核决策，只返回已有记录，不重验、不改变当前行、原审核信息或审计；对旧 approved 原 sid 重发 approve 不会重新上架。

撤回未获批准的 draft / pending / rejected 只终止该记录，不新增版本封禁。撤回曾获批准的投稿会撤回整个 release，并更新同 release 的全部已批准记录。撤回旧版本不隐藏当前新版，但其 `blockedVersions` 永久携带旧版本；撤回当前版本不会自动回退到旧版。没有当前条目时，目录仍保留 withdrawn 账本。举报针对曾获批准发布的版本，不会自动下架；管理员先查证再撤回。

公开下载授权来自当前条目。仅知道 SHA，或持有 draft / pending / rejected 投稿记录，不会新增授权。若另一投稿已使同 kind / id / version、同 SHA / size 的资源成为当前条目，后来同资源的待审或拒绝记录不撤销既有授权；共享 blob 也不因此变成另一版本的公开下载凭据。

每次公开的 GET、HEAD、Range、条件请求都先读当前权威状态。ZIP 下载必须精确匹配当前行和永久绑定；真实 R2 GET / HEAD 的 checksum 也须匹配。ZIP 的 Range / 条件语义复用既有的 `serveObject`，并补充 If-Range 检查。客户端下载响应为 `private, no-store`，目录为 `no-cache, must-revalidate`；ETag 覆盖实际目录和开关投影。关闭 companion 后，旧 ETag、HEAD 或 Range 均不能绕过 503。主目录继续返回 pet 及全部撤回记录，companion 投影和对应下载一起关闭。审核用的私有下载仍可用，便于处置存量问题。

If-Range 的日期按 [RFC 9110 §13.1.5](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.5) 与 Last-Modified 精确匹配，R2 的 `uploaded` 按 HTTP 秒精度比较。强验证的前提来自不可变内容对象及实际摘要检查；较早或较晚的日期均忽略 Range 并返回完整 200，不能使用 If-Unmodified-Since 的 ≤ 比较。强 ETag 精确匹配可返回 206，弱 ETag 不能匹配，没有 Range 时忽略 If-Range。

## 单 ZIP 与公开预览

预览是作者对本次投稿的明确选择。metadata 可选 `previewSource`：pet 对应 `pet-idle`，companion 对应 `companion-preview`；省略时保持原无图行为，既有合法包不用为新功能增加图片或缩小动画格。capabilities 的 `preview` 对象公布 schema 1、两种 source、PNG 格式、宽高各 512、面积 262144、2097152 字节的硬限。App 在 create 之前核能力；缺能力不能把有图意图悄悄按旧协议发送。

图片仍来自同一份经过 SHA / size 核验的上传 ZIP。宠物选 `states.idle[0]` 的动画，再按 `frames[0].i` 与 cols / frameW / frameH 裁首帧，不假定第 0 格，也不缩放。伙伴只取精确的 `character/preview.png`；其原 PNG 字节即公开内容，不猜模型肖像或公开 texture atlas。只有声明后才执行这套较小尺寸门，超限或缺图明确拒绝，不能自动取消声明。客户端没有独立图片上传、另一个草稿或第二个恢复事务。

小尺寸 / 文件门先于图像解压，完整包与完整 PNG 校验继续执行；公开格式拒绝 APNG 和其他图像类型。宠物裁剪复用原 PNG 像素重建过程，完整验证源图而只额外保存选中格的 RGBA，最多 1048576 字节，不生成源图的完整 RGBA 副本。输出为 RGBA8、filter 0、非交错、单 IDAT 的确定编码，使用 zlib stored blocks；令 `N = h × (4w + 1)`，PNG 总字节为 `N + 5 × ceil(N / 65535) + 63`，在 512 × 512 时最多 1049236，低于 2MiB 门。这个算术只约束输出，原 ZIP、源 PNG 完整 scanline、压缩缓冲及并发请求仍有独立的内存成本。

ZIP 通过完整验证后先写原 `workshop/blobs/<ZIP SHA>.zip`；派生图以 `workshop/previews/<PNG SHA>.png` 条件创建，原生摘要与长度必须一致。随后重新读取权威状态，只有仍为 draft 才将 `submittedAt`、包 validation 和 `preview: {path, sha256, size, width, height}` 一起 CAS 为 pending。图片在 pending 登记时固定，重复上传不会重画；上传期间被撤回或其他写入赢得 CAS 时，不覆盖其结果。孤立私有对象不构成公开授权，也不能通过任意成员路径接口取出。

对 pending 的新批准重验原 ZIP 与登记 PNG 的实际 SHA / size、尺寸和完整像素合同，然后再读最新状态并 CAS。管理员看到的登记图与批准后返回的字节是同一份，不在批准后按新版算法重新派生。缺对象、摘要不符或存储失败不能自动改为无图；同终态审核的幂等行为仍只返回原记录。

图片选择绑定 submission，永久 Release 仍只锁定版本的 ZIP SHA / size / 作者。旧无图 release 不自动补图；要选择公开图，须以新的 requestId、声明和 pending 重新接受审核。未撤回的相同 release / 相同 ZIP 经新审核可以由有图改成无图，或由无图改成该声明派生的图；无声明的旧客户端重投不继承图片。版本撤回继续永久生效，不能借新图片解除。 已提交的投稿如果声明了 `previewSource` 却没有登记图片（没有预览功能的 Worker 接过它的包会留下这种记录），按无图读取：目录条目不带 `preview`，公开图片地址返回 404，包照常发放，整份状态不因此判为非法。

公开地址为 `/market/workshop/<kind>/<id>/<version>/<ZIP SHA>/preview/<PNG SHA>.png`。GET / HEAD 先核功能开关与最新状态：current 必须指向 approved 投稿并选择精确 descriptor，Release 的 ZIP 绑定须相符，版本不得在 withdrawn 中。相同 blob 或同一 PNG 被其他版本使用不能授予这条路径；同一地址若本来就由 current 授权，后来出现同内容待审记录也不会撤销它。被替换或撤回的旧选择不再授权，返回 404；关闭 companion 返回 503；uploads 关闭仍允许读取已公开图片。

图片固定为 `image/png`、登记长度、`nosniff` 和 `private, no-store`，不提供 Range / 304，也不跳转裸桶。GET 校验实际图片正文长度和摘要；HEAD 校验 R2 原生摘要及长度，不读取正文。旧图片已经到达设备后不能被远程收回；App 随来源、条目或目录变化清理展示，图片错误不等同 ZIP 错误，也不应自动删除安装包。

管理员固定端点 `/api/workshop/v1/admin/submissions/<sid>/public-preview` 在身份门后读取该 sid 的登记图，GET / HEAD 无 query，draft / 无图返回 404。它与原 `/preview?file=<索引>` 的私有 PNG / JPEG / WebP 查看工具分开；后者的 8MiB / 4096 门不能用来扩大公开图上限。审核台校验 PNG 摘要、长度和 IHDR 登记像素尺寸，再确认浏览器载入成功，有图未显示成功前不开放批准，仍允许拒绝与重试。接口不执行包内脚本、模型或音频。

这个功能复用私有 BUCKET、既有限流和两个开关，不新增 binding、env、公开桶或上传端点。备份与保留范围同时包括 state、ZIP 和 `workshop/previews/`。回滚目标必须理解并保留声明、登记和授权合同；只因 state schema 仍为 1，不能推断任意旧 writer 或灰度混写都兼容。

## 身份、开关和滥用限制

`WORKSHOP_UPLOAD_ENABLED=1` 与 `WORKSHOP_COMPANION_ENABLED=1` 在 `wrangler.jsonc` 里默认设为 1，未配置时也视为开启；设为 0（或其他非 1 的显式值）分别返回稳定的 `workshop_upload_disabled` 或 `workshop_companion_disabled`。上传关闭不阻止本人查询、撤回、举报和管理员拒绝 / 撤回。旧宠物市场不受这两个开关影响。

`WORKSHOP_AUTO_APPROVE=1`（线上 `wrangler.jsonc` 自 2026-11-15 起设为 1；未配置或其他值为关闭）：上传通过上面的包验证、成为 pending 的同一次提交里直接批准，审核意见记为「自动通过」，审计照常有 submit + approve 两条。批准时撞上版本冲突（id 已归别的作者、版本已撤回、同版本换字节）的不报错，留在 pending 等人工。自动通过后重复上传同一投稿仍返回原记录。举报、管理员撤回和下架不受影响；关掉开关即回到人工审核。

Worker 用作者请求里的 `Authorization: Bearer <token>`（只收 `[A-Za-z0-9_]{1,255}`）请求 `https://api.github.com/user`，以 manual 方式接收响应、拒绝跟随重定向；本地 workerd 里 `redirect: 'error'` 不受支持，不能沿用浏览器 / Node 的该选项。GitHub 回 401 记为 `account_auth_invalid`；只信 200 响应里的正整数 `id` 和 `login`，其余状态、过大或无有效身份的响应、网络错误都记为 `account_unavailable`（503），不把它当成凭据失效。令牌不落 R2 / KV / 日志，也不作持久指纹。用户名是显示快照；稳定身份是账号来源 + GitHub 用户 id。`WORKSHOP_GITHUB_API_URL` 只给测试和本地演练换成 HTTPS 替身，线上不设。

每个作者身份请求都必须携带 `X-Workshop-Account-Origin: https://github.com`，声明凭据所属的账号来源；缺失或不等返回 `409 / workshop_account_origin`，在请求 GitHub 之前拒绝。公共查询与管理员的独立身份门不要求此头。

capabilities 的 `account` 给出账号来源和 GitHub OAuth App 的 `clientId`（变量 `WORKSHOP_GITHUB_CLIENT_ID`，不合格或未设时为 null，App 据此不提供登录）。它用于事前核对，不能替代作者请求自己的断言。

App 自己向 GitHub 走设备码登录，只要公开资料（scope 为空），Worker 不参与登录、不持有 client secret。令牌发给工坊之前，App 外层必须核对 `account.origin` 并让用户确认凭据转交；数据层按单次调用显式接收。管理员使用既有的 `X-Admin-Key`，审计 actor 为 `admin`，不能据此归因到某一个管理员个人。

沿用现有限流绑定及 KV 计数，向 GitHub 核对身份前做每 IP 读限流，写入增加突发限制；每个 GitHub 用户每小时 5 次新投稿；archive 尝试、举报和撤回分别每小时 20 次。archive 失败的尝试也先计数。KV 跨 colo 是近似计数，既有计数器异常时 fail-open，不能称为强配额或全局 DoS 防护。所有鉴权 / 存储错误在此路由转换为固定码，不输出底层异常或 GitHub 正文。

## 审计和容量

metadata 强制中英文 title、author、固定的 license 列表、HTTPS source、`rightsConfirmed=true`，以及 SHA 和 size。服务器 `createdAt` 记录确认时间；create / submit / approve / reject / withdraw / report 的状态变更及其操作者、原因都与审计一起 CAS 提交。审计至少保留 186 天，覆盖六个日历月；只在后续写入时清理更老的事件。永久版本绑定、作者归属、撤回和投稿元数据不自动清理。`workshop` 前缀不能配置 7d / 30d 的生命周期。

展示字段 `description` 与 `tags` 可省略，分别默认空字符串和空列表。非空简介最多 512 码点；标签最多 8 条，每条最多 32 码点、非空白、按原字符串唯一；非空值沿用同一个文本门，不修剪、不归一化，标签顺序保留。空字段在新投稿的规范 metadata 中省略，保持既有默认形状。它们随投稿及公开目录保存，也属于同 requestId 的元数据一致性比较，但不要求写入 ZIP。现有 16 KiB 投稿 JSON 与 8 MiB 权威状态上限不变。

权威对象上限 8 MiB，当前条目最多 1000、永久绑定最多 10000、撤回 4000、投稿 / 举报各 10000、审计 20000；它们都是硬上限而非容量保证。每个未撤回的投稿另预留 24 KiB、每个未撤回的发布另预留 12 KiB，含最坏 UTF-8 撤回原因 / 审计字节及名额，避免普通投稿或举报填满后无法撤回已有内容。实际容量会较早触顶，返回 `workshop_capacity`；不丢弃六个月内的审计或历史来腾空间。管理员可通过 `admin/submissions/<id>/withdraw` 终止废弃的 draft / pending / rejected，释放预留但保留记录；不会让无人完成的 draft 永久占住预留。规模化前需由维护者设计带校验的历史归档 / 分片迁移，不能手删 binding。当前没有声称能承载万级活跃投稿。

## 包验证与 App 的关系

pet 复用 App 的精确规则 JSON、其 Unicode 15 固定表和既有的 88 项合成共享夹具（另有 6 项专项测试）。构建生成数据（`src/generated/workshop-data.ts`），指纹覆盖验证源码、生成器、锁文件、规则和 Unicode 数据。ZIP 在解压前逐个检查目录、路径、NFC 后全 casefold 冲突、局部头、重叠区间、链接、压缩 / 加密标志；有界 inflate 检查实际 EOF、尾随字节、CRC 与声明长度。JSON 严格 UTF-8，无 BOM、重复的已解码 key、孤立代理项、非有限数或过深嵌套。其中 24 项 manifest 夹具只补入投稿必需的固定授权元数据，几何 / 引用内容不变；缺少市场元数据的本地包不能直接投稿。schema、frame / scale 整数、Float32 几何、所有动画引用、atlas 边界遵守当前 App 本地导入的门槛。

PNG 检查完整 CRC 和 chunk 顺序、合法色型 / 深度、PLTE / tRNS、连续 IDAT、zlib EOF / Adler32、元数据解压预算、Adam7 / 普通 scanline、filter 0..4，并逐像素还原 RGBA 采样，不是只读图片 header。每张 PNG 最多 8 MiB，单边最多 4096，宽 × 高 × 4 最多 16 MiB；后者是 RGBA8 像素预算，不是 16 bit 解压工作区的内存上限。IDAT 采用两遍扫描后定长拼接，不累积每 chunk 的对象；重建时复用当前行和上一行缓冲，但完整解压 scanline 仍在内存中。校验 ZIP / PNG 时不保留完整状态快照，完成后再读最新状态和 CAS。合法输入的接受域没有靠缩弱校验来扩大。

投稿 ZIP 是 App 本地导入的一个更严的子集：

- 压缩后 ≤ 50 MiB（2026-11-15 由 20 MiB 放宽；App 宠物本地 ≤ 64 MiB），只收 ZIP32。上传按投稿登记的大小一次分配缓冲、边收边写，不再先攒分块再拼接，50 MiB 的包只在内存里占一份。超过旧上限 20 MiB 的作品在目录里放进单独的 `largeEntries`：50 MiB 之前的 App 遇到超过 20 MiB 的条目会把整份目录判为无效，而它们只读 `entries`，看不到这些作品；新 App 两个字段合起来读。之后再放宽上限时，App 对比本机上限大的条目逐条显示「App 版本太旧」（`workshop_app_too_old`），不让整份目录失效。同一个 isolate 里同时只读、查一个超过 16 MiB 的包（上传和管理员批准时的重验），另一个直接得到 429 `workshop_rate_limited`（Retry-After 60）稍后重试，免得两个 50 MiB 的包同时占内存；小包照旧并行。这个占位 10 分钟后自动失效，运行时中途丢掉的请求（finally 来不及执行）也占不住它；读请求体最多等 9 分钟，超时返回 408 `workshop_upload_timeout` 并放开占位。忙时的 429 在扣作者上传配额之前判定。
- 目录必须为空且完整 CRC / EOF 有效。
- pet 仅一个根或单层目录的 `pack.json` 及引用的 PNG，拒绝多余成员，元数据必须与投稿声明一致。
- 服务端不猜测或修补作品几何。

App 导出应生成这一干净子集。

companion 只收 character / 数据白名单（json、moc3、png、jpg、jpeg、webp、wav、mp3、txt、md），拒 runtime 代码，拒 `index.json`（由安装器重建）。所有成员的 CRC / 实际展开长度受限，JSON 严格解析，所有 model3 的必需 Moc / Textures 及 expression / motion / physics / pose / userdata / display 文件引用必须在角色目录内实际存在。`character.json` 的授权元数据必须一致，`name` / `model` 必需；明确选择的 persona / name 属于 App 导出决策，服务器不读取本地偏好。moc3 要求 MOC3 头、格式枚举 1..6，未来 / 未知枚举拒绝。

companion 的 JSON 逐成员完成严格解析和语义校验。ZIP 目录在循环前已经完整校验，character / model 的引用直接对该目录检查，不依赖被引用文件排在前面。单个 JSON 函数返回后，其完整对象不加入跨成员的 Map；只保留 character 通过标志、model 数量和 moc 版本集合。所有 JSON 仍完整解析，包括未引用的附加数据；所有 model3 仍检查引用，包括未被 character 选中的模型；后续成员仍逐个核 CRC、PNG 和 moc 门。文件、字节、深度及引用的接受规则没有因此收紧或放宽。若一个无效包同时有多个问题，逐成员语义校验可能先报不同的现有 400 验证码；此类包仍拒绝。

这样做移除了随 JSON 成员累计保留的对象图，不是流式 JSON 解析或完整的内存保证。单个 JSON 仍会完整形成对象图；其节点复杂度、解析临时字符串、PNG 完整 scanline、zlib 拼接瞬态和其他请求的缓冲都需要运行时测量。对象离开函数作用域也不保证 GC 立即归还内存。[Workers 内存限制](https://developers.cloudflare.com/workers/platform/limits/#memory) 是每个 isolate 128 MB，一个 isolate 可能同时承载多项请求，不能把 128 MiB 的归档展开门当作堆预算。2026-11-15 在 Node 里实测：45 MiB 的伙伴包（6 张噪声贴图）上传并通过验证，除请求体和测试替身 R2 各自的副本外，额外占用约 45 MiB。

moc 上限 6 来自 `tooling/companion/fixtures/live2d-core-sources-v1.json` 里 2026-11-07 的实测：官方 Core 6.0.1、SHA `8741…ef47`、`latestMocVersion` 6。这份历史记录不证明当前安装 runtime 的聚合摘要一致。版本头通过不等于 Core 一致性或所有模型功能可渲染；批准者仍须用获准的固定 Core 做完整的一致性 / 加载检查，并核对模型许可、内容和实际 App 效果。Worker 不附带 Core / runtime / 模型 / 贴图。companion ≤ 1000 成员、单成员 16 MiB、展开 128 MiB；PNG 沿用 pet 的完整上限，其余数据格式不声称已做音视频或 Core 的完整解码。

## 测试覆盖

测试在 `services/share-worker/test/`：

- `workshop.test.ts`：鉴权、每个作者入口的账号来源断言、GitHub 各种应答的归类、`clientId` 的公布规则、公共 / 管理入口独立性、投稿幂等、审核 / 拒绝、他人访问、版本重写、所有权、撤回与 `blockedVersions`、举报、开关、Range / If-Range、真实 GET checksum、固定错误码，以及管理密钥过短时拒绝管理接口。
- `workshop-state.test.ts`：撤回容量预留、审计保留 186 天与后续写入时的清理。
- `workshop-if-range.test.ts`：强 / 弱 ETag 与 If-Range 日期的各分支。
- `workshop-validation.test.ts`：与 App 共用的合成夹具（`app/test/pets/fixtures/`）、Unicode 15 casefold、inflate 的 EOF 与上限、RGBA 逐像素还原、runtime / 不安全或缺失引用 / 未来 moc 格式、隐藏的额外文件。
- `workshop-companion-sequential.test.ts`：小型合规的多 JSON 夹具，覆盖 stored / deflate 下不同的成员顺序、未选中 model3 的全部引用类别，以及晚到的无效 JSON、CRC、PNG 和 moc 的拒绝。它验证逐成员重构的内容合同，不提供最大 JSON 堆、进程峰值或并发的验收结果。
- `workshop-runtime.test.ts`：本地 workerd 对同一生产 bundle 运行 44 项 App PNG 语料、合法 pet、deflate 的尾随 / 截断 / 输出上限；2048 × 2048、16 bit RGBA 的正常 PNG（33,556,480 字节 scanline，4,194,304 像素）验证成功。没有测量进程峰值，也没有穷举最大压缩包、元数据、并发的叠加。
- `workshop-r2-runtime.test.ts`：本地 workerd 的原生 R2 绑定与合成 GitHub 响应，走完审核与撤回的全流程（R2 checksum、CAS、Range）。
- `workshop-preview.test.ts`：公开 PNG 的 opt-in、首个 idle 格、裁剪像素、色型 / 位深 / Adam7、静态格式及输出门；`workshop-public-preview.test.ts`：登记与 CAS、管理员读取、批准时重验、current / Release / 撤回、开关、GET / HEAD、条件头和同内容多版本的授权。

这些都不是 Cloudflare R2 或 Discourse 的联机验收。

## 还没有做的

- 部署前需要完成正常的 `npm ci` / build / typecheck / test 与 Wrangler dry-run。
- 需要在付费 Worker 的 CPU 预算和每 isolate 128 MB 的内存限制下，测完整路由的峰值与并发压力；不能从像素 payload 上限推导全进程内存。
- 需要配置私有 `BUCKET`（无公开域名）与 `workshop` 前缀的保留策略，并设置满足 `ADMIN_KEY.length >= 32` 的管理密钥（不提交到仓库）；缺失或过短返回 `503 / workshop_admin_unavailable`。配置通过后，请求头 `X-Admin-Key` 的值 `provided` 须非空、满足 `provided.length <= 4096` 且匹配配置，否则返回 `401 / workshop_admin_auth_required`。
- 需要用真实 GitHub 账号确认设备码登录、`/user` 应答，以及在 GitHub 上撤销授权后的行为。
- 需要人工审批测试样本。
- 需要在真实 R2 上验证 CAS、checksum、Range / 断网重试，以及关闭 / 撤回后旧请求的表现。
- 需要由 App 真机验证导入、已有 runtime 保留、导出回导和中文错误。

## 一手依据

- Discourse [User API keys 规范](https://meta.discourse.org/t/user-api-keys-specification/48536) 与 [UserApiKeyScope 实现](https://github.com/discourse/discourse/blob/main/app/models/user_api_key_scope.rb)：身份请求范围和 client header 行为。
- Cloudflare [Request 重定向语义](https://developers.cloudflare.com/workers/runtime-apis/request/)、[Workers node:zlib](https://developers.cloudflare.com/workers/runtime-apis/nodejs/zlib/) 与 [平台限制](https://developers.cloudflare.com/workers/platform/limits/)：需要 `nodejs_compat` 及相应的兼容日期，内存 / CPU 另受平台限制；配置采用 2026-10-01。
- Live2D [Cubism 5.3 兼容性](https://docs.live2d.com/en/cubism-sdk-manual/compatibility-with-cubism-5-3/) 与 [moc3 一致性](https://docs.live2d.com/en/cubism-sdk-manual/moc3-consistency/)：文件版本、Core 检查、renderer 功能是不同层次。
