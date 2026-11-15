# 创意工坊上线与日常维护

本文给负责上线和审稿的 owner 使用，对应 `services/share-worker` 中的创意工坊（状态层、GitHub 账号身份、审核台）。命令在电脑的 **Bash 终端**执行；Windows 用户使用具备下列工具的 WSL/Linux 环境。手机用于打开审核台，不用于执行部署命令。

下文命令里的“Worker 目录”指仓库的 `services/share-worker/`。尚未验证的内容集中写在第 9 节，上线前先读一遍。

## 1. 开始前填写这张表

请先准备**完整仓库源码**，且包含审核台（`services/share-worker/src/workshop-admin-page.ts`）。只拿一个 Worker 子目录不够：构建会读取 `site/`、App 的分享查看器输入、宠物规则与 Unicode 数据。电脑需要 Node.js **24.22.1**（与 `.github/workflows/ci.yml` 的 `NODE_VERSION` 一致）、npm、Python 3、Bash、curl、jq、OpenSSL 和 GNU `mktemp`；部署脚本用到的工具见 `services/share-worker/scripts/cloudflare.sh` 与 `services/share-worker/scripts/provision.sh`。缺少工具时先按项目环境说明装齐；不要用临时下载的其他版本掩盖安装错误。

| 要填写的值 | 从哪里拿 | 如何使用 |
|---|---|---|
| Cloudflare 账号 ID | 自己 Cloudflare 账号的 Account ID，32 位十六进制 | 放入 `CF_ACCOUNT_ID`；不是 API token |
| 已托管在该账号的域名 | 自己控制的 zone，例如 `example.com` | 放入 `ZONE_NAME`；脚本选 `go.<zone>`，被占用时试 `s.<zone>` |
| Cloudflare API token 文件 | Cloudflare 创建有本服务权限的 token，保存到仓库外的私有文件 | 文件路径放入 `CF_TOKEN_FILE`，不要把 token 本身贴进命令或提交到仓库 |
| GitHub OAuth App 的 Client ID | 第 1.4 节建好的 OAuth App 页面上的 Client ID（公开值，不是 client secret） | 写入 `wrangler.jsonc` 的 `vars.WORKSHOP_GITHUB_CLIENT_ID` |
| 公开下载域名 | 单独公开下载桶所用的 HTTPS 域名，例如 `https://dl.example.com/` | 写入 `vars.DL_BASE_URL`；不要把私有投稿桶接到这个域名 |
| 管理密钥文件 | 首次开通脚本自动生成；默认 `~/.config/keys/dshgo-share-admin.txt` | 文件路径可用 `ADMIN_FILE` 改，正文采用默认路径 |
| KV ID | 首次 `apply` 发现或创建后写入 `~/keys/dshgo-cloudflare-kv-quota-id` | 不要填随机值；已有同名 KV 时必须核对其真实 ID |

不要把本文的 `example.com`、仓库的 `dshtui.com` 或任何全零 ID 当成自己的配置。如果你正维护仓库默认账号和域名，可保留经你确认的默认域名；新账号必须填自己的值。

账号 ID / KV ID 的真实值通过环境变量或仓库外的文件传入。**不要把公开 `wrangler.jsonc` 中的两个全零占位符直接拿去部署。** 现有脚本（`services/share-worker/scripts/cloudflare.sh`）用临时配置副本填真实 ID，退出时删除副本。

### 1.1 首次上线只支持没有旧工坊状态的起点

在 Cloudflare 的 R2 对象浏览器中，检查私有桶 `dshgo-share` 的精确对象键 **`workshop/state-v1.json`**（定义为 `services/share-worker/src/workshop-state.ts` 中的 `STATE_KEY`）。桶尚未创建，或这个对象尚不存在，才继续下面的首次上线流程。整个桶可以已有分享链接、下载包等其他对象，**不需要清空桶**。

如果这个工坊状态对象已经存在，先保留对象与备份，请维护者核对举报处理字段、审计事件和容量预留，再决定升级。**不要删除状态文件、审计或版本绑定来强行继续。** 老记录缺少举报处理字段能够被读取，不代表任意旧容量都能按当前规则继续写入。具体容量与回滚边界见第 8 节。

### 1.2 Cloudflare 资源与绑定，一项一项核对

工坊复用这个 Worker 的现有绑定，没有新增数据库、独立 KV 或后台服务器。绑定定义在 `services/share-worker/wrangler.jsonc`，类型声明在 `services/share-worker/src/env.ts`。

| 绑定 / 资源 | 实际名字与用途 | 首次怎么准备 |
|---|---|---|
| Worker | `dshgo-share` | `provision.sh apply` 部署 |
| `BUCKET` | R2 桶 `dshgo-share`；私有分享对象、工坊状态和投稿 ZIP（对象键 `workshop/blobs/<sha256>.zip`） | `apply` 创建缺失桶；**保持私有，不开公开域名或 r2.dev** |
| `DL` | R2 桶 `dshgo-dl`；公开发版文件及既有市场镜像 | **先在 R2 后台创建**并连接自己的 `dl.<zone>` 自定义域名（见 `docs/release.md` 的公开下载桶一节）；`apply` 不创建它 |
| `QUOTA` | KV 命名空间 `dshgo-share-quota`；近似小时计数，也供既有 beta 功能使用 | `apply` 发现或新建并记录 ID |
| `ASSETS` | 构建后的 `public/` 静态资源 | `npm run build` / Wrangler 构建生成并上传，不手工建存储桶 |
| `BETA_GUARD` | Durable Object 类 `BetaGuard`，既有 beta 错误密钥计数 | 随配置和 migration `v1` 部署，不自行换类名或 migration 标签 |
| `STATS_SALT` | Durable Object 类 `StatsSalt`，既有统计使用的当日盐 | 随 migration `v2` 部署 |
| `UPLOAD_BURST` | Rate Limiting namespace `42001`，每 60 秒 5 次 | 由部署配置绑定；同账号其他 Worker 不要复用该 namespace |
| `READ_LIMIT` | namespace `42002`，每 60 秒 120 次 | 同上；工坊作者鉴权和公开读取会使用它 |
| `USAGE_LIMIT` | namespace `42003`，每 60 秒 20 次 | 同上；供 App 使用统计，不是工坊投稿额度 |
| `DOWNLOADS` / `CHECKS` / `USAGE` | Analytics Engine 数据集 `dshgo_downloads` / `dshgo_checks` / `dshgo_usage` | 已开 Analytics Engine 时正常部署；未开时本手册用 `--no-analytics` |
| Custom Domain | 脚本选择的 `go.<zone>` 或 `s.<zone>` | `apply` 核对占用情况后部署；DNS 由 Custom Domain 管理 |
| Cron | 每 10 分钟同步既有插件/宠物市场 | 随配置部署；它不是工坊审批器 |
| zone Redirect Rule | 既有插件市场两条路径转公开下载桶 | `apply/deploy` 在镜像一致后创建或更新指定描述的规则 |

`dshgo-share` 的现有生命周期只让 `7d/`、`30d/` 对象到期，并中止未完成的 multipart 上传。**不能给 `workshop/` 前缀添加 7 天、30 天或其他自动删除规则。** 工坊撤回记录、作者绑定、永久版本绑定和审计需要保留。`apply` 会把这个私有桶的生命周期规则替换为脚本的固定规则；如果该桶已有自己维护的其他规则，先请维护者核对，不直接运行。设计说明见 `docs/design/workshop-worker.md`。

### 1.3 配置项和密钥

下表的普通变量在 `services/share-worker/wrangler.jsonc` 的 `vars` 中修改。**在 Bash 中单独 `export WORKSHOP_UPLOAD_ENABLED=0` 不会修改 Worker 的线上变量。** 配置生成器（`cloudflare.sh` 的 `wrangler_config`）只替换账号、KV、域名和 Analytics 选择。

| 名称 | 含义 / 默认值 | 本次怎么填 |
|---|---|---|
| `WORKSHOP_UPLOAD_ENABLED` | 未设置或恰为字符串 `1` 为开启；**其他任何值（`0`、空串、`true` 等）都按关闭处理**，关闭后工坊新投稿、上传和新的批准都被拒绝 | 正常上线保留 `1`；紧急关闭写 `0`，见第 7 节；不要靠删除变量来关闭 |
| `WORKSHOP_COMPANION_ENABLED` | 判断规则同上；关闭后伙伴投稿、批准与对应公开目录/下载被拒绝 | 正常保留 `1`；独立于宠物和旧宠物市场 |
| `WORKSHOP_GITHUB_CLIENT_ID` | GitHub OAuth App 的公开 Client ID；为空或不匹配 `^[A-Za-z0-9._-]{1,64}$` 时 capabilities 给 `clientId: null`，App 不提供登录 | 填第 1.4 节那个 App 的 Client ID；不要填 client secret。`WORKSHOP_GITHUB_API_URL` 只给测试和本地演练用，线上不设 |
| `ADMIN_KEY` | **Worker secret**，供审核台和既有管理员删除接口使用 | 至少 32 个字符，短于 32 个字符时服务端按未配置处理（`503 / workshop_admin_unavailable`）；`apply` 新建时用 33 随机字节生成 44 字符密钥并设文件权限 600，随后上传 secret；复用已有非空文件不调整其权限 |
| `PET_MARKET_ENABLED` | 既有宠物市场镜像开关，当前 `1` | 保持现有值；不是工坊紧急关闭开关 |
| `MARKET_SOURCE_URL` | 既有插件/宠物市场的 HTTPS 上游；未配置沿用项目默认 | 工坊上线不用新增此值；更换上游另按既有市场文档核对 |
| `UPLOADS_PER_HOUR` | 既有分享链接的每客户端小时额度，当前 `20` | **不能用它关闭工坊投稿**；工坊按操作把计数值设为自己的 5/20 |
| `MAX_BYTES` | 既有分享 API 大小上限，当前 20 MiB | 不改变工坊固定 50 MiB ZIP 上限 |
| `DOWNLOAD_ACCESS` | 既有 App 安装包下载方式，当前 `public` | 保持部署方原政策；不是工坊审核/下载开关 |
| `DL_BASE_URL` | 公开下载桶的 HTTPS 基址，当前 `https://dl.dshtui.com/` | 与你已创建的公开桶域名一致 |
| `CN_BASE_URL` | 可选香港下载桶基址，当前空 | 未配置该下载线路时保持空 |
| `BETA_SECRET` | 既有内测密钥哈希/下载签名 secret | 工坊不使用它；已有 beta 服务按原政策保留，生成由 `scripts/beta-keys.sh init` 完成，见 `docs/release.md` |
| `USAGE_SECRET` | 既有 App 使用统计的哈希 secret | 工坊不使用它；开启统计时按 `docs/release.md` 的“统计”一节用 32 个随机字节生成、保存私有文件并上传 secret，不放进 `vars` |
| `GITHUB_TOKEN` | 可选首页 Star 查询 secret | 工坊不使用它；仓库只消费、不生成 GitHub 令牌（`docs/design/share-links.md` 称无需任何权限的 fine-grained token 即可）。若另启用该可选项，由维护者在自己的 GitHub 账号创建；不为工坊临时填一个其他用途的 token。（待确认：账号/组织允许的令牌类型、有效期与后台创建流程，以 GitHub 账号设置页为准） |

脚本输入与 Worker 配置不同：`CF_TOKEN_FILE` 是 Cloudflare API token 的文件路径；`CF_ACCOUNT_ID` / `CF_ACCOUNT_ID_FILE` 是账号 ID 或其文件；`CF_KV_QUOTA_ID` / `CF_KV_QUOTA_ID_FILE` 是 QUOTA ID 或其文件；`ZONE_NAME` 是自己 zone；`ADMIN_FILE` 是管理员密钥文件；`DSH_ANALYTICS=0` 与 `--no-analytics` 作用相同。这些都在 `provision.sh` 与 `cloudflare.sh` 开头定义。不要设置测试用 `CF_API`，也不要为了跳过占用检查随手设置 `ALLOW_EXISTING_WORKER=1`。

### 1.4 GitHub OAuth App

作者用 GitHub 账号登录，App 自己走 GitHub 的设备码流程，Worker 只拿作者请求里的令牌问 `https://api.github.com/user` 认人，不参与登录、不需要 client secret。需要一个 OAuth App（在 GitHub 的 Settings → Developer settings → OAuth Apps 新建）：

| 设置 | 填法 | 原因 |
|---|---|---|
| Homepage URL / Redirect URI | 工坊域名，例如 `https://go.example.com` | 设备码流程不回跳，这两项只是 GitHub 要求必填 |
| Enable Device Flow | 勾上 | App 用的就是设备码流程；不勾会报 `device_flow_disabled`，App 显示「这个工坊还没开通 GitHub 登录」 |
| Expire user access tokens | 不勾 | App 不处理 refresh token；令牌过期后作者只能重新登录 |
| Client secret | 不生成 | 用不到，生成了反而多一个要保管的密钥 |

App 只申请空 scope，令牌只能读公开资料。作者请求必须带 `Authorization: Bearer <token>` 和 `X-Workshop-Account-Origin: https://github.com`。GitHub 回 401 记为 `account_auth_invalid`，其余非 200（含 403 限流）记为 `account_unavailable`。要停掉全部登录，在这个 OAuth App 页面点 Revoke all user tokens。实现在 `services/share-worker/src/workshop-auth.ts`。

## 2. 一次性准备（以下命令在自己的电脑上执行）

先在 Cloudflare 开通 R2，创建上表的 **公开下载桶 `dshgo-dl`** 并连接自己的 `dl.<zone>` 域名；私有投稿桶保持私有。确认账号与域名均归自己控制，且第 1.1 节没有旧工坊状态。

API token 至少需能调用脚本实际涉及的 Workers、R2、KV、zone 查询、Custom Domain/DNS 与单条重定向规则接口。仓库的权限说明在 `docs/design/share-links.md`（创建 token 一节）；脚本还会操作 zone 的 `http_request_dynamic_redirect` ruleset（见 `provision.sh` 末段）。**（待确认：你账号中单条重定向规则权限的具体显示名和授权范围，`docs/design/share-links.md` 的权限列表没有列出它，以 Cloudflare 的 Rulesets API 文档与创建 token 页面为准。）** 仅有 Workers Scripts 写权限不等于有该规则写权限。把权限限定到自己的账号和 zone，不使用别人的 token。

将 API token 用本地编辑器保存到仓库外的私有文件；不要放进聊天、截图、终端历史或 Git。以下命令只含**文件路径和非秘密 ID**。替换大写中文占位文字后再运行；每个框是一条命令。

**C01 — 在仓库根目录生成分享查看器。**

```bash
python3 app/tool/make_replay_viewer.py
```

预期：正常退出，并生成 `site/build/share/`。失败时先按提示找缺失输入，不手工补一个空 `c.html`。CI 也是这样做的（`.github/workflows/ci.yml`）。

**C02 — 进入 Worker 目录。**

```bash
cd services/share-worker
```

此后直到说明离开前，都留在这个目录。

**C03 — 安装锁定依赖。**

```bash
npm ci --ignore-scripts --no-audit --no-fund
```

预期：命令退出 0，使用 `package-lock.json`，不改成随意升级依赖的命令。安装失败先修网络/工具版本；不要跳过依赖直接部署。

**C04 — 构建。**

```bash
npm run build
```

预期末尾出现 `build-site: … paths … → public/`，并正常退出。若报 `site/build/share/c.html is missing`，回到仓库根目录执行 C01；若报 `site/home/dist/index.html is missing`，请维护者检查完整源码中的网站构建产物，不创建假文件绕过检查。

**C05 — 类型检查。**

```bash
npm run typecheck
```

预期退出 0，无 TypeScript 错误。

**C06 — Worker 全部单元测试。**

```bash
npm test
```

预期所有测试通过；失败或跳过必须按实际结果处理，不把 test 文件存在当成通过。`npm test` 会先执行构建再运行 vitest，其中包含审核台和工坊接口的测试。

**C07 — 指定 Cloudflare API token 文件。**

```bash
export CF_TOKEN_FILE="$HOME/.config/keys/dshgo-cloudflare-api-token.txt"
```

把路径改成刚保存的文件，文件应只供自己的账号读取。这里没有把 token 本身打印或写进命令。

**C08 — 指定真实账号 ID。**

```bash
export CF_ACCOUNT_ID='替换成自己的32位十六进制账号ID'
```

预期不输出内容。还未替换占位文字或仍填全零时，后续脚本会拒绝。

**C09 — 指定自己的 zone。**

```bash
export ZONE_NAME='替换成自己的域名'
```

例如填 `example.com`，不是 `https://example.com/`。脚本会核对 zone 与账号是否一致。不设置时脚本默认用 `dshtui.com`，所以新账号必须设置。

**C10 — 固定管理员密钥文件路径。**

```bash
export ADMIN_FILE="$HOME/.config/keys/dshgo-share-admin.txt"
```

首次没有文件时由脚本生成；如果此路径已有非空文件，脚本会复用它而不会自动加长或调整权限。请确认已有密钥至少 32 字符，文件也只由自己读取（需要时按 C27 设置权限）；不要把一行说明文字或旧 Cloudflare token 当成管理密钥。

现在打开 `wrangler.jsonc`，只按第 1.3 节修改需要改的普通变量，尤其 `WORKSHOP_GITHUB_CLIENT_ID` 与公开下载域名。两个功能开关默认保留 `1`；管理密钥不写进这个文件。

## 3. 第一次部署

**C11 — 先只读检查资源。**

```bash
scripts/provision.sh check
```

预期看到 zone/账号、候选域名、Worker 是否存在、私有桶是否存在、KV 名称与 ID，最后退出 0。缺资源可以是首次上线的正常结果；`zone … is on another account`、域名被其他服务占用、KV ID 不匹配或权限错误不是正常结果。修正输入后重新执行本步；不要跳过占用检查。

这个 check **不是全部资源与写权限的完整预检**。例如 R2 查询的 `success=false` 都会被脚本显示为桶不存在，不能单凭退出 0 区分“确实还没建桶”和“权限/API 查询失败”。显示不存在时，还要在自己的 Cloudflare 后台核对；公开下载桶 `dshgo-dl` 也须按第 1.2 节单独准备。

**C12 — 创建缺失资源并部署。** 未开启 Analytics Engine 的账号先采用这一条：

```bash
scripts/provision.sh apply --no-analytics
```

已明确开启 Analytics Engine、并要保留原统计服务的账号，去掉 `--no-analytics`；不要两条轮流试到“看起来成功”。这个选择需与后面的常规 redeploy 保持一致。

本步会真正改 Cloudflare：创建缺失的私有 R2 桶/KV，设置上述生命周期，生成并上传 `ADMIN_KEY`，部署 Worker/绑定/域名/Cron，执行线上分享链接 e2e（`scripts/e2e.mjs`，范围见 `docs/design/share-links.md`），并在满足条件后设置指定的插件市场重定向规则。**它不是只做工坊健康检查。** 不会替你创建 `dshgo-dl`；也不会替你建 GitHub OAuth App 或完成人工审稿。

预期可见 `created bucket` / 已有资源信息、`admin key written to …`（仅首次生成时）、Wrangler 部署结果、e2e 成功和市场重定向成功，最终退出 0。不要分享完整终端输出，先人工检查是否含自己账号或密钥信息。

| 结果不符合时 | 下一步 |
|---|---|
| `creating bucket failed` | 在 Cloudflare 后台确认 R2 已开通、账号/token 权限正确；不要换到其他人的账号 |
| 找不到 `dshgo-dl` 或公开域名 | 回第 1.2 节补建公开下载桶与正确自定义域名 |
| Analytics 绑定失败 | 未开 Analytics Engine 则用同一 `--no-analytics` 方案；不要删除无关绑定 |
| 域名暂未可访问，e2e 失败 | 先在自己的 Cloudflare 后台核域名/证书/Worker 部署；恢复后按 C13 再部署检查，不能据终端最后一行之前的成功字样宣布全部成功 |
| `market … doesn't serve … yet` | Worker 可能已部署，失败的是既有市场镜像/重定向后置检查；核公开桶域名与 Cron，再等镜像更新后用 C13。不要重建私有桶或删工坊状态 |
| 首次脚本中断在上传 ADMIN_KEY 之前 | 先确认部署阶段，再用第 7.3 节的管理密钥设置步骤补齐；不能让审核台 `503` 被误当成密码输错 |

**C13 — 以后部署同一服务的代码。** 使用与首次相同的 Analytics 选择：

```bash
scripts/provision.sh deploy --no-analytics
```

这条命令也会跑线上 e2e 与市场重定向后置检查，但**不会像 `apply` 那样重新上传 `ADMIN_KEY`**。需要轮换管理密钥时使用第 7.3 节。

## 4. 部署后自查

**C14 — 记下部署脚本实际选择的域名。**

```bash
export WORKSHOP_HOST='替换成脚本打印的实际域名'
```

只填 `go.example.com` 这种主机名，不加 `https://`。这是本手册使用的本地便捷变量，不是新增 Worker 绑定。脚本输出里 `domain: …` 一行就是实际域名；下列 URL 按工坊路由拼装。

**C15 — 审核页公开可取。**

```bash
curl -I "https://$WORKSHOP_HOST/workshop/admin"
```

预期 `200`，HTML 类型，并带审核页的 CSP、`nosniff`、`Cache-Control: no-store` 等响应头。在手机浏览器打开同一 HTTPS 地址，应该只看到未连接的审核界面；没有管理密钥时不应出现投稿列表、举报或审计内容。该地址是公开页面，公开可取不等于管理数据公开。

**C16 — 能力声明与账号来源正确。**

```bash
curl -i "https://$WORKSHOP_HOST/api/workshop/v1/capabilities"
```

预期 `200`，JSON 中 `schema: 1`，`features.uploads` / `features.companion` 与你的两个开关一致，`account.origin` 是 `https://github.com`，`account.clientId` 是你填的 Client ID（不是 `null`）；正常默认开关均为 `true`。`limits.archiveBytes` 应是 `20971520`。这个请求不验证真实 GitHub 登录是否成功，只返回服务端配置与能力。

**C17 — 工坊目录可以读取。**

```bash
curl -i "https://$WORKSHOP_HOST/market/workshop.json"
```

预期 `200`、`Cache-Control: no-cache, must-revalidate`，包含 `schema`、`features`、`entries`、`withdrawn`。首次没有作品时，`entries: []` 是正确结果。它不会自动列出尚未审核的稿件。

**C18 — 管理数据确实要求密钥。**

```bash
curl -i "https://$WORKSHOP_HOST/api/workshop/v1/admin/submissions?status=pending&limit=1"
```

本命令故意不带密钥。正确配置下预期 `401`，错误码 `workshop_admin_auth_required`；不能返回投稿数组。`503 / workshop_admin_unavailable` 表示服务端 `ADMIN_KEY` 缺失或不足 32 字符，应修配置；不是多输几次密码能解决。不要为让此检查通过而在 URL 添加密钥。管理接口一律先鉴权再处理请求（`services/share-worker/src/workshop.ts` 的 `adminRoute`）。

**C19 — 伙伴目录与开关一致。**

```bash
curl -i "https://$WORKSHOP_HOST/market/companions.json"
```

开关为 `1` 时预期 `200`，同一 `entries` 结构里只出现伙伴；开关不是 `1` 时预期 `503 / workshop_companion_disabled`。不要拿 `HEAD`、Range 或旧 ETag 作为绕过关闭状态的办法。

**看 HTTP 状态与 JSON，不只看 curl 是否退出 0。** 这些公开/未鉴权检查没有发送真实 GitHub 令牌或管理密钥。

最后在审核页中输入自己的管理密钥，读取待审、举报和审计列表。首次可以都是空列表；退出后刷新页面应重新要求输入密钥。管理密钥只在这个标签页内存中，不自动保存，关闭或离开页面后需重新输入。不要把已登录页面或密钥输入框截图发给别人。

## 5. 日常审稿、撤回和举报处理

### 5.1 审一条稿件

1. 打开 `https://你的域名/workshop/admin`，输入 `ADMIN_KEY`。默认查看待审稿件；用宠物/伙伴筛选和“下一页”分批查看，不把当前一页当成全部稿件。
2. 打开单条详情。核对 GitHub 用户名、作品名称、kind、版本、大小、提交时间、完整元数据、许可与来源、包内路径/大小，以及每条校验提示。元数据中的作品作者字段可以与 GitHub 用户名不同；稳定的投稿身份是 `https://github.com` 和数值 GitHub 用户 id。
3. 按需查看可预览的图片。审核台只显示图片和文字，不执行包中的脚本、模型、motion 或音频。PNG 使用完整校验；JPEG/WebP 的结构/尺寸门不等于完整像素解码或模型加载验收。不可预览的条目仍列文件与原因，不因此把整包称为损坏。
4. 决定批准前，独立确认你有足够依据判断素材授权、来源与内容。通过验证器仅代表通过它实际覆盖的技术规则，不代表你已经取得许可或在 App 上看过实际效果。
5. 选择通过或拒绝，填写理由，再检查确认框里的**同一作品、版本和操作**后确认。接口的理由上限是 2000 码点，且审核操作要求非空理由。拒绝必须解释原因。
6. 等页面刷新这一条，再查看其实际状态与审计。不要只凭上传/按钮动画结束就认为已经发布。`approved` 是这条稿件的审核状态；详情的“当前发布指向”也只是状态里 `current` 列表的指向，实际公开可用性还受功能开关影响。批准新版会替换同 kind/id 的当前行，旧稿仍可能保持 approved。

“通过”操作不等于安装、渲染或运行模型。伙伴素材的完整 Core/模型检查和真机效果仍需采用项目允许的固定运行时及设备流程完成，见 `docs/design/workshop-worker.md` 的“包验证与 App 的关系”。审核页本身不提供模型执行入口。

### 5.2 撤回一个已经发布的版本

在详情中确认 kind、作品 id、version 与当前发布指向，选择撤回并填写原因，经过二次确认后等待刷新。撤回的是那个 **release 版本**：同一个版本的多个已批准投稿会一起受影响。撤回旧版不会隐藏当前新版；撤回当前版不会自动把旧版重新上架。被撤回版本会写入永久撤回记录，不能用同版本换包绕过。规则见 `docs/design/workshop-worker.md`，接口为 `POST /api/workshop/v1/admin/releases/withdraw`。

如果网络断开、响应解析失败或返回存储错误，页面可能不知道写入是否已经发生。此时先刷新同一条详情/当前目录/审计，按服务端实际状态继续；不要连续重复点击，不把之后观察到的状态错误归因给某一次失败的请求。

### 5.3 处理举报

在举报列表查看理由、举报者、目标作品版本、当前发布指向和撤回状态；必要时先查看对应稿件。选择“标记已处理”或“标记不予处理”并填理由，二次确认后刷新举报。这会写入举报处理结果和审计，**不会自动撤回作品**。需要下架时另外执行撤回并核对结果。

同一举报第一次处理后成为终态；重发相同决策只读取已有结果，不覆盖原理由或再写一次审计；改成另一决策会冲突（`409 / workshop_report_state`）。遇到冲突先刷新，不要求 owner 用反复提交来争抢结果。接口为 `POST /api/workshop/v1/admin/reports/<reportId>/resolve`，请求体 `decision` 取 `handled` 或 `dismissed`，合同见 `services/share-worker/docs/workshop-api.md`。

### 5.4 看审计记录

审核页的审计视图只读，按页查看操作者、时间、目标和动作/理由。作者操作能显示 GitHub 身份；管理操作记录的 actor 是 **`admin`，即持有这把管理密钥的人**。单一 `ADMIN_KEY` 不能区分多个管理员个人，不能把它当作实名操作记录。不要把 key 或 key 的摘要当成“谁”。

审计至少保留 186 天（`AUDIT_RETENTION_MS`）；仅在后续写入时清理更老事件。版本归属与撤回账本不是可随意删除的旧日志。

## 6. 查看用量、限流和常见错误

在 Cloudflare 后台分别查看这个 Worker 的请求/错误/CPU，以及两个 R2 桶的容量和操作量、QUOTA KV 的用量。费用和套餐限额以你账号当时的 Cloudflare 后台为准。工坊没有独立的计费看板，也没有把每个浏览请求写入审计。

工坊公开目录/包读取和 GitHub 身份检查使用 `READ_LIMIT`；需要计数的作者侧写尝试使用 `UPLOAD_BURST`。每个 GitHub 账号每小时新建投稿 5 次，archive 尝试、举报和撤回分别 20 次；archive 校验失败的尝试也计数。KV 跨机房最终一致，计数器故障沿现有逻辑放行，所以这些是近似限制，不能宣称全局严格配额。实现在 `services/share-worker/src/workshop-auth.ts` 与 `services/share-worker/src/limits.ts`。

管理员审核、撤回、举报处理不走上述作者小时配额；不能据该表推断管理 key 每小时只能操作 5 或 20 次。管理详情与图片预览另有 `READ_LIMIT` 门，capabilities 查询没有上述公开目录读取门。

| 看到的结果 | owner 应做什么 |
|---|---|
| `401 / workshop_admin_auth_required` | 检查是否使用当前 ADMIN_KEY；不要把 Cloudflare token 或 GitHub 令牌填进审核台 |
| `503 / workshop_admin_unavailable` | 服务端管理密钥缺失/过短；按第 7.3 节补齐，不能改页面绕过鉴权 |
| `409 / workshop_state_conflict` 或 `workshop_submission_state` | 可能有另一操作已提交，或这条记录已不能做该操作；刷新目标和审计后再决定 |
| `429 / workshop_rate_limited` | 按 `Retry-After` 等待；不要自动高速重试或轮换身份绕过限制 |
| `503 / workshop_upload_disabled` | 投稿/上传/新的批准已关闭；核对当前开关 |
| `503 / workshop_companion_disabled` | 伙伴能力关闭；宠物、已有本地资源和管理处置不因此全部关闭 |
| `401 / workshop_account_auth_required` | 作者请求没带合格的 `Authorization: Bearer` 令牌；让用户在 App 里重新登录 |
| `409 / workshop_account_origin` | App 声明的账号来源不是 `https://github.com`；多半是旧版 App，请用户更新 |
| `401 / workshop_account_auth_invalid` | GitHub 不认这个令牌（撤销了授权或令牌失效）；App 会自动登出，请用户重新登录，owner 不索取其令牌 |
| `503 / workshop_account_unavailable` | GitHub 回了 401 以外的非 200（含 403 限流）、跳转、超时或坏正文；看 GitHub 状态页，稍后重试 |
| `503 / workshop_capacity` | 权威状态及预留容量达到门槛；停止扩大写入，交维护者按保留规则处理，不删审计/绑定腾空间 |
| `503 / workshop_state_invalid` | 状态损坏、不兼容 writer 或容量/结构异常；保留数据与版本信息，停止盲目重试或回滚 |
| `503 / workshop_storage_unavailable` | 存储/摘要/读写异常；写入结果可能未知，先查询目标状态再决定，保留错误码和时间 |

完整错误码以 `services/share-worker/src/workshop-auth.ts`、`workshop-state.ts`、`workshop.ts` 与 `services/share-worker/docs/workshop-api.md` 为准。给维护者的材料只需：时间、Worker 版本、请求路径模板、HTTP 状态、固定错误码、非秘密的 submissionId/reportId；发出前人工检查。不要导出完整请求头、GitHub 响应、浏览器存储或含 key 的调试日志。

既有 `scripts/stats.sh` 统计的是下载、更新检查和 App 使用报告，**不是工坊投稿计数**。如需要读它，按 `docs/release.md` 的“统计”一节准备 Account Analytics Read 权限；它不能证明审核台的访问量或工坊配额是否生效。

## 7. 关闭开关与管理密钥维护

### 7.1 紧急关闭投稿

最快的维护方式是先在自己的 Cloudflare 后台打开 **Workers & Pages → `dshgo-share` → Settings → Variables and Secrets**，把普通文本变量 `WORKSHOP_UPLOAD_ENABLED` 改成 **`0`**，保存并部署配置变更。如果界面菜单不同，搜索这个完整变量名；不要删除变量，因为未设置代表开启。后台菜单依据 Cloudflare [环境变量说明](https://developers.cloudflare.com/workers/configuration/environment-variables/)。

部署完成后重新执行 **C16**，确认 `features.uploads: false`。在看到这个结果之前，不宣布紧急关闭已完成。这个检查不需要 key。

随后用编辑器将本地 `services/share-worker/wrangler.jsonc` 中同一值也改为字符串 `"0"`，将这项配置变更交给维护者保存。否则下一次 C13 会用本地仍为 `1` 的配置重新开启。仓库明确记录后台变量会被后续部署覆盖（`docs/release.md` 的 `DOWNLOAD_ACCESS` 一节）；当前脚本没有为普通变量启用保留后台值的特殊选项。

正常维护时，也可先改本地配置，再执行已有的 **C13**，最后用 **C16** 验证。这仍会触发 C13 所述的既有分享 e2e 和市场重定向检查。**在终端 export 同名变量、把 `UPLOADS_PER_HOUR` 改成 0、关闭 `PET_MARKET_ENABLED`，都不能替代工坊开关。**

### 7.2 两个开关分别影响什么

两个开关都由 `services/share-worker/src/workshop-auth.ts` 的 `features` 读取：变量未设置或恰为 `"1"` 才算开启，其他值一律算关闭。下表以写 `"0"` 为例。

| 配置 | API 和审核台 | App 已有状态层的行为 |
|---|---|---|
| `WORKSHOP_UPLOAD_ENABLED="0"` | capabilities 的 uploads 为 false；新建投稿、上传 ZIP 和从 pending 新批准返回 `503 / workshop_upload_disabled`。已有公开目录/下载、本人记录读取、举报、拒绝与撤回仍按各自身份和限流规则工作 | 重新取得 capabilities 后，`canSubmit(kind)` 为 false（`app/lib/state/workshop_auth_state.dart`）；页面应据此停止投稿入口。已缓存的旧开关不能绕过服务端门。已有准备稿和未知写入结果不能因此被当成“肯定没提交” |
| `WORKSHOP_COMPANION_ENABLED="0"`，uploads 仍为 1 | 新伙伴投稿、伙伴 ZIP 上传和新批准返回 `503 / workshop_companion_disabled`；`/market/companions.json` 与伙伴公开 ZIP 下载同样返回 503。主工坊目录保留宠物和所有种类的撤回记录；管理读取、拒绝、撤回、举报处理仍可做 | 能力刷新后不能提交伙伴；目录重新验证后按服务器的可用作品判断能否安装/更新（`app/lib/state/workshop_catalog_state.dart`）。这个开关不会主动删除设备已有文件，也不等于卸载所有本地伙伴 |
| 两者都为 0 | 同时满足以上关闭条件；对于同时检查两门的作者请求，uploads 门先执行，因此可能先见 `workshop_upload_disabled` | 需要按当前错误和重新读取的状态展示，不能靠错误顺序推断伙伴开关已恢复 |
| 恢复为字符串 `"1"` 并部署 | 对后续请求重新放行相应能力，其他鉴权、审核和不可变版本规则照常；不会自动批准积压稿件，不会解除永久撤回 | 刷新能力与目录后再显示可用操作；不能把恢复开关当作投稿成功或安装完成 |

App 页面尚未接线到这两个开关时，表中不承诺某个按钮的实际文字、位置或动画，真实端到端表现需要另行验收（见第 9 节）。

开关是在请求经过对应检查时判断的。**已经通过门的在途写入可能继续完成**；关闭不是撤销已发请求，也不是退回数据。先前批准的资源也不会因为只关闭 uploads 自动下架。需要撤回某个已发布版本时，仍要在审核台明确执行撤回、填写原因并检查结果。

### 7.3 设置或轮换管理密钥

首次 C12 成功时不需要再做一次。如果服务端报 `workshop_admin_unavailable`，或者需要轮换泄露/过期的管理密钥，使用本节。管理密钥同时服务既有分享 API 的管理员入口；轮换会影响所有持有旧 key 的管理端。

先回到 `services/share-worker` 目录，使用 C07–C10 的真实文件路径/账号/zone，按 C14 填实际域名，再执行 **C11** 核对账号、域名和 QUOTA。C11 不是上传密钥操作；不成功就先解决它显示的问题。不要为修密钥而重建桶、KV 或重跑整套 `apply`。

**C20 — 载入仓库已有的 Cloudflare 命令封装。**

```bash
source scripts/cloudflare.sh
```

预期没有输出，当前终端得到 `ACCOUNT`、`KV_ID`、`wrangler_config` 和 `wr`。这是读取本地配置和 ID 文件，不会部署。如果找不到文件，先回 Worker 目录，不把另一份同名脚本拿来代替。

**C21 — 保持与首次部署相同的 Analytics 选择。**

```bash
ANALYTICS=0
```

本手册首次用了 `--no-analytics`，因此这里是 0；已经明确使用 Analytics Engine 的部署才填 1。这是脚本本地变量，不是工坊能力开关。

**C22 — 生成只供本终端使用的 Wrangler 配置。**

```bash
wrangler_config "$WORKSHOP_HOST"
```

预期退出 0，在 Worker 目录创建临时 `.wrangler-*.json`；正常退出终端时由现有 EXIT trap 删除。它使用 C11 已核对的账号/KV 和 C14 域名。失败时先修缺少的 jq/Python/GNU mktemp 或路径权限；不能跳过它，直接拿公开配置里的占位 ID 调管理命令。

**C23 — 将已准备好的管理密钥文件写入 Worker secret。**

```bash
wr secret put ADMIN_KEY < "$ADMIN_FILE"
```

只在确认文件是自己要使用的、至少 32 字符的管理密钥后执行。预期 Wrangler 显示 secret 写入成功。密钥通过标准输入送入，没有作为命令参数或 URL。不要添加调试跟踪，也不要在命令前打印文件内容。

回审核台退出当前会话，用新 key 连接并读取待审/举报/审计；旧 key 应不能再取得管理数据。若失败，区分 401 与 503；不把失败日志中的完整请求头转发出来。只做本节不会验证 GitHub 登录。

**需要生成新 key 时**，在 C23 之前先执行下列 C24–C27，生成成功后再回 C23。已有密钥的只补传操作跳过这四步。

**C24 — 为新 key 选择一个尚不存在的私有文件。**

```bash
export ADMIN_FILE="$HOME/.config/keys/dshgo-share-admin-next.txt"
```

若该文件已用于以前的轮换，改成另一个新文件名；不要覆盖尚用于恢复的旧 key。这里仅更换同一参数的文件路径。

**C25 — 创建密钥文件的父目录。**

```bash
mkdir -p "$(dirname "$ADMIN_FILE")"
```

预期退出 0；权限失败时先检查路径是否是自己的目录，不用共享可写目录。

**C26 — 用仓库的生成方法产生 44 字符 key，并拒绝覆盖旧文件。**

```bash
(set -o pipefail; set -C; umask 077; openssl rand -base64 33 | tr '+/' '-_' | tr -d '=\n' > "$ADMIN_FILE")
```

随机字节数、编码与去换行方法与 `provision.sh` 生成首个管理密钥的做法相同。外层的 `pipefail` 与禁止覆盖（`set -C`）是本手册加的失败保护：已有文件或任一流水线命令失败，整步应非零退出。预期没有密钥内容输出。若生成失败，不上传这个文件；换新路径后查明缺工具或权限原因再生成。不要把失败留下的空文件当成 key。

**C27 — 限制这个文件只由自己的账号读写。**

```bash
chmod 600 "$ADMIN_FILE"
```

正常退出后回 C23 上传。旧 key 只在确认新 key 已生效并妥善保存后，按自己的密钥管理方式退役；不把两把 key 都贴进工单。

## 8. 回滚与已有状态

### 8.1 先判断能否回滚

Cloudflare 的 Worker 回滚改变代码/版本，**不会把 R2 状态、ZIP、KV 或 Durable Object 数据一起退回**。`docs/design/share-links.md` 已说明回滚不影响 R2 数据；平台行为另见 Cloudflare [Rollbacks](https://developers.cloudflare.com/workers/versions-and-deployments/rollbacks/)。因此不能把“上一个版本”自动当成“与当前数据兼容的版本”。

当前状态格式包含举报的 `resolution` 字段和审计动作 `resolve_report`。只要已经处理过举报，不认识这个动作的旧版 Worker 在校验审计时会拒绝它，可能返回 `503 / workshop_state_invalid`。**不要回滚到没有举报处理状态支持的 Worker，也不要让这种旧 writer 和新 writer 分流写同一个状态对象。**

即使还没处理举报，也不能只凭“没有新字段”放行回滚：当前写入规则为处理举报预留了容量，旧 writer 不保证它。选择目标版本时请维护者确认它同时理解当前字段/审计动作、保留这项预留规则，并仍指向正确的存储和密钥配置。没有这样的已发布版本时，优先按第 7.1 节关闭投稿、保留数据，由维护者修复当前兼容版本；不是删除状态文件后再试旧版本。

### 8.2 对已确认兼容的版本回滚

先按第 7.1 节关闭投稿并验证；按 C20–C22 准备同一服务的命令封装。记录当前线上版本和待恢复的版本，不用 Git commit SHA 代替 Cloudflare Worker Version ID。

**C28 — 读取部署历史。**

```bash
wr deployments list
```

预期显示这个 Worker 的近期部署与对应 Version ID。使用 `wr` 是为沿用 `cloudflare.sh` 里的真实账号、token 文件和临时配置。当前 Wrangler 规范见 [Workers commands](https://developers.cloudflare.com/workers/wrangler/commands/workers/#deployments-list)。这是读操作；找不到服务时先核账号/配置，不创建另一个同名 Worker。

**C29 — 回滚到维护者已经核过兼容性的精确 Version ID。**

```bash
wr rollback '替换成已确认兼容的Cloudflare-Version-ID'
```

只替换引号中的值，确认提示中是自己的 `dshgo-share` 及预定版本后再确认。预期产生一个使用该版本的新部署。`docs/design/share-links.md` 记录的是不带参数的 `wrangler rollback`（回到上一个版本）；这里显式给出版本参数（见 [Wrangler rollback 规范](https://developers.cloudflare.com/workers/wrangler/commands/workers/#rollback)），避免省略参数后自动选中不兼容的上一版本。不能使用 `--yes`、忽略错误或任意挑一个能部署的历史版本来代替兼容性核对。

回滚后再次核对线上普通变量和管理密钥是否符合当前维护要求，执行 C15–C19，再进审核台读取状态。目标版本原有开关可能是开启的；若 uploads 被恢复为 true，按第 7.1 节重新关闭并验证。等问题得到确认修复后才恢复投稿。R2/KV/DO 绑定已不存在或迁移不兼容时，平台可能拒绝回滚；保留错误和版本信息交维护者，不重建空桶假装恢复了历史数据。

### 8.3 为什么首次流程要求精确工坊状态不存在

权威状态是私有 R2 的一个 CAS 对象，最大 8 MiB（`STATE_CAP`）。除了撤回容量预留之外，每个**尚未处理的举报**额外预留 20 KiB 和一个审计槽。这样处理举报不会挤掉原先给撤回留的空间。

给维护者核对的具体预算是：当前 JSON 字节数 + 未撤回投稿数 × 24 KiB + 未撤回 release 数 × 12 KiB + 未处理举报数 × 20 KiB，不超过 8 MiB；审计数加上这三个计数不超过 20000；撤回账本与活动 release 的其他数量限制继续保留。实现在 `services/share-worker/src/workshop-state.ts`，说明见 `services/share-worker/docs/workshop-api.md`。正文不要求 owner 手算，只要求识别 `workshop_capacity` 后停止继续扩大写入并保留现状。

较早版本允许的某些状态可能已有很多未处理举报，按当前预留规则不再满足容量门。它能按旧 JSON 形状被读取，仍可能在第一次写入时遭遇 `workshop_capacity`。因此第 1.1 节是**首次上线流程的前提**，不是说程序会自动迁移任意旧数据；也不是允许删掉旧工坊数据。若存在该对象，请维护者在不改线上对象的副本上核计数、序列化字节数、审计保留和兼容 writer，再提出单独的数据升级方案。

不要把早期状态备份直接盖回当前状态：这可能抹去之后有效的撤回、版本绑定或审核结果。需要数据恢复时应先停止相应写入、保留当前对象及备份，由维护者按明确的恢复计划操作。当前审核台不提供删除审计、清空状态或强制重新绑定版本的按钮。

## 9. 尚未验证的内容

这套工坊从未部署到真实 Cloudflare 账号，也从未用真实 GitHub 账号投过稿，管理员审核台从未在真实浏览器里打开过，没有在任何真机或手机上验证过。仓库里的单测、类型检查、CI 和本地假环境只能说明代码按预期逻辑运行，不能替代下面这些首次上线验收；本文的“预期”输出来自源码，而不是真实运行记录。遇到与“预期”不符的结果，按该步说明停下核对，不把异常当成成功。

以下项目由 owner 在自己的环境首次执行时记录，任何失败都保持“未完成”，不要用本地桩测试的成功填入真实结果。

| 项目 | 目前的状况 | 首次上线如何定论 |
|---|---|---|
| Cloudflare 账号、套餐、资源权限 | 绑定名与脚本行为已对照源码；没有接触过真实账号 | C11、C12 的实际结果以及自己的后台资源核对；重定向规则权限的显示名/范围仍待确认 |
| 构建、类型检查、Worker 单元测试 | CI 会运行；owner 自己部署前也要执行 | 自己执行 C01–C06 并看实际输出 |
| 公开域名、TLS、资产路由与 CSP | 路由及配置有源码和单测约束；没有真实部署过 | C15–C19，并在浏览器检查页面无外部请求、同源鉴权与响应头 |
| GitHub 登录 | 设备码流程和 `/user` 身份链路只按源码和 GitHub 文档核对，另在本机向 GitHub 要过一次验证码；没有用真实账号走完投稿 | 在 App 里用自己的 GitHub 账号登录并投一个测试作品；在 GitHub 上撤销授权后确认 App 回到未登录；不要把令牌发给维护者 |
| 审稿、举报与撤回 | 接口和页面脚本有测试；没有在线上操作过 | 在自己部署的测试作品上逐项操作，核对详情、公开目录和审计；确认网络中断时先查状态的流程 |
| 手机浏览器 | 审核页是单列、大按钮的中文页；没有在手机真机上用过 | 在实际手机输入 key、翻页、看长文件名/提示、预览、二次确认、切应用再回来、退出后重新连接 |
| 图片与模型效果 | 图片预览有限制，模型/脚本不执行 | 用自己的合规测试包检查图片可见性；模型实际效果另按固定运行时和真机流程验收 |
| 用量、限流与费用 | 配额和近似计数行为有源码；没测过真实跨机房表现和账单 | 查看自己 Cloudflare 的请求/存储用量与实际 429；不能把本地计数当成计费结论 |
| 回滚与恢复 | 兼容性条件已写明；没有真实执行过 Wrangler 回滚或数据恢复 | 有兼容的已发布版本后，由维护者与 owner 核状态/版本，再按第 8 节执行并验收 |
| App 页面表现 | 状态层（`app/lib/state/workshop_*_state.dart`）已有测试；页面接线是另一项后续工作 | 页面对当前 provider/API 接线完成后单独验收，不能从审核台测试推出 |

### 9.1 出错时留下什么

保存这次部署的源码提交、Worker Version ID、操作时间、步骤编号、HTTP 状态和固定错误码；判断错误发生在本地构建、部署、接口还是浏览器。不要删桶、删 state 或改版本号来消除错误；不要把账号 token、管理 key、GitHub 令牌、完整请求头或未脱敏的私有稿件附到公开工单。维护者需要更多证据时，再按具体问题提供最小范围的材料。
