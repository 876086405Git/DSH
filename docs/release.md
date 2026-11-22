# 发版与应用内更新

App 以 APK 分发、不上商店，更新靠 App 自己查 GitHub Releases、下载、校验、调系统安装器。本文是发版约定和步骤，以及更新链路的取舍。代码在 `app/lib/update/`（检查、下载、校验）、`app/lib/state/update_state.dart`（状态与节流）、`app/lib/ui/update/`（设置行、弹窗）、`app/android/.../update/`（PackageInstaller 安装）。

> **正式发版前必须先换成固定的发布密钥**（见「签名」）。存在 `app/android/key.properties` 时 release 使用其中的发布密钥；缺少配置时仅为本地构建回落到 debug key，不可用于正式发布。

## 资产约定

每个版本一个 GitHub Release，仓库 `ccch1mneyyy/dsh-go`，必须公开（私有仓库匿名访问一律 404，App 只会显示「暂时检查不了」）。同一组文件也放在公开下载桶：`https://dl.dshtui.com/download/<版本>/<文件>`，最新版的清单在 `https://dl.dshtui.com/update.json`（见「公开下载桶 dl」）。

正式版统一提供 arm64 安装包。`update.json` 供更新清单回退读取，`SHA256SUMS` 供缺少 GitHub digest 时校验 APK，`*.dshdelta` 是从最近几个旧版升上来的增量补丁（`docs/design/delta-update.md`），都由 App 自己用，不要求用户手动下载。GitHub 自动生成的 Source code 压缩包是源码快照，不是安装包。

| 项 | 约定 | 例子 |
|---|---|---|
| 版本名 | `app/pubspec.yaml` 的 `version: X.Y.Z[-pre]`，即 versionName；后面的 `+1` 只是占位 | `1.2.0` |
| 构建号 | Android versionCode，由 `tooling/build-apk.sh` 按构建时间生成，见「构建号」 | `10251234` |
| tag | `v` + 版本名（不带 `+N`） | `v1.2.0`、`v1.3.0-beta.1` |
| APK | `dsh-go-<版本名>-<flavor>.apk`，正式版 flavor 固定为 `arm64`；文件名不带 `+N`（GitHub 会改写 `+`） | `dsh-go-1.2.0-arm64.apk` |
| iOS 安装包 | `dsh-go-<版本名>-ios-unsigned.ipa`：iOS 编译工作流 `ios-unsigned-ipa` 产物里的 `DSH-Go-unsigned.ipa`（必须是发版提交上的那次运行，且「Archive as for TestFlight, and look inside」这一步通过；归档检查失败时 IPA 照样会上传，那份不能用），上传 Release 时改成这个名字；只挂在 GitHub Release，不进 `SHA256SUMS` 和 `update.json` | `dsh-go-1.2.0-ios-unsigned.ipa` |
| 增量补丁 | `dsh-go-<版本名>-from-<旧版本名>-arm64.dshdelta`，只发不到整包 60 % 的 | `dsh-go-1.2.0-from-1.1.0-arm64.dshdelta` |
| 校验和 | `SHA256SUMS`，`sha256sum` 的标准输出，APK 和补丁都在里面 | `<hex>  dsh-go-1.2.0-arm64.apk` |
| 清单 | `update.json`（schema 1），镜像和自托管源都读它 | 见下 |
| 更新说明 | Release 正文（Markdown），App 弹窗里原样渲染 | |

`update.json` 由脚本生成，不要手写：

```json
{
  "schema": 1,
  "version": "1.2.0+10251234",
  "tag": "v1.2.0",
  "title": "DSH 1.2.0",
  "publishedAt": "2026-11-01T08:00:00Z",
  "notes": "## 新功能\n…",
  "page": "https://github.com/ccch1mneyyy/dsh-go/releases/tag/v1.2.0",
  "assets": {
    "arm64": { "name": "dsh-go-1.2.0-arm64.apk", "size": 180107933, "sha256": "…" }
  },
  "patches": {
    "arm64": [
      { "from": "<1.1.0 APK 的 SHA-256>", "fromVersion": "1.1.0+10201200",
        "name": "dsh-go-1.2.0-from-1.1.0-arm64.dshdelta", "size": 13278848, "sha256": "…" }
    ]
  }
}
```

`assets.*.url` 可省：省略时 App 用 tag 和文件名拼 GitHub 下载地址；自托管时写绝对地址或相对 `update.json` 的地址（脚本的 `--base-url`）。公开下载桶的清单写绝对地址（`https://dl.dshtui.com/download/<版本>/<文件>`）。`patches` 没有补丁时不出现，条目不带 `url`：补丁在每条线路上都和 APK 在同一目录。旧版 App 不认识它，照常下整包。

版本比较按 semver：预发布版低于正式版（`1.3.0-beta.1 < 1.3.0`），`+N` 只在两边都有时才参与比较（GitHub API 只给 tag，不带 `+N`）。所以 **同一个版本名重新打包不会被当成新版本**，要发就升版本名。

## 构建号

所有 APK，不论开发包还是正式包，一律用 `tooling/build-apk.sh` 出：

```sh
tooling/build-apk.sh                 # release arm64（真机）
tooling/build-apk.sh -f x64          # 本地模拟器验证，不公开发布
tooling/build-apk.sh -f all          # 双架构本地验证；正式发版不用此选项
tooling/build-apk.sh --dry-run -f all   # 只打印要执行的命令
```

脚本把构建时间编成 versionCode，传给 `--build-number`，同时传 `--build-name` 和 `DSH_APP_VERSION`：

```text
versionCode = (年 - 2026) × 10^8 + MMDDhhmm      时钟固定按 UTC+8
2026-10-25 12:34 → 10251234    2027-01-02 03:04 → 101020304    2046-12-31 23:59 → 2012312359
```

- **一条序列**：开发包和正式包按同一个时钟编号，后打的包号一定更大，正式包总能覆盖之前装的开发包。
- **每次都变**：系统和厂商 ROM 常按「包名 + versionCode」决定要不要刷新缓存的图标。号一直不变时，换了图标资源，通知和状态栏也可能一直显示旧的（vivo OriginOS 上出现过）。
- **看得懂**：设置里显示 `1.0.0 (10251234)`，一眼知道是 10 月 25 日 12:34 打的包；`python3 tooling/build_number.py --decode N` 可反查。
- **上限**：Android 限 2,100,000,000，这套编码用到 2046 年底。
- **绕过脚本时**（`flutter run`、IDE）：`build.gradle.kts` 发现 versionCode 还是占位的 `1`，就按同一公式现算。否则装到已有新号的设备上会被当成降级，`flutter run` 会先卸载旧版再装，数据全清。
- 测试：`python3 -m unittest discover -s tooling -p 'test_*.py'`。

## 发版步骤

1. **改版本名**：`app/pubspec.yaml` 的 `version:`，版本名按 semver 升；`+1` 不动。之后打的开发包也带新版本名，不会被提示「更新」到这一版。
   - **同步使用说明**：按本版界面改动更新 `docs/guide/`，把 `docs/guide/README.md` 的 `> dsh-go X.Y.Z` 改成新版本名，`python3 app/tool/guide_sync.py` 重新生成 App 内置技能，`python3 app/tool/guide_sync.py --check` 通过再打包（它核对入口路径、界面文字、页面链接与版本号）。
2. **只打包 arm64 正式版**（运行时要先 `runtime/build-runtime.sh` 产出 `runtime/out/`）。x64 仅供必要的本地模拟器验证，不上传、不放入正式更新清单：

   ```sh
   tooling/build-apk.sh
   ```

   运行时里的 Node 和 Linux ONNX Runtime 装包前把调试信息（DWARF）清零了，文件布局不动。带调试信息的原件和打进 APK 的运行时出自同一次构建：用 Runtime 工作流的产物打包，就取同一次运行的 `runtime-debug-arm64-v8a` artifact（只保留 90 天）；在本机构建，就取 `runtime/out/arm64-v8a/debug/`。两种情况都连同同一次的 `build-report.json`（记着原件和装包件的 SHA-256）一起留存，以后定位引擎崩溃用，不上传到发布线路。

   脚本顺带传 `DSH_APP_VERSION=<版本名>+<构建号>`（`app/lib/state/app_info.dart`），作为诊断信息和更新状态的编译期默认版本。设置和关于页读取更新状态中的版本；原生版本读取成功且版本名可解析时，更新状态改用系统提供的 `versionName` / `versionCode`，读取失败或版本名无法解析时保留默认值。

   脚本给正式包自动打开求 star 提示（开头一行带 `· star prompt`）：`DSH_STAR_PROMPT=true` 写在 `tooling/star-prompt-on.json` 里，排在 `--` 后面的额外参数前面传给 flutter，所以额外参数里再写 `DSH_STAR_PROMPT`（行内或文件）以额外参数为准。`--beta`、`--side`、`--debug`/`--profile` 的包不加，`--no-star` 可以手动关掉。以前要手动加这个参数，最近的正式包漏了（1.3.0 确认没加，1.1.0、1.2.0 的打包记录里也没有），装这些版本的人一次都没被问过。提示的触发条件见 `docs/design/star-prompt.md`；使用时长从装上这个包算起。
3. **确认签名**：对要发布的 arm64 APK 执行 `apksigner verify -v --min-sdk-version 21 --print-certs`。v1、v2、v3 三种签名都要是 `true`（v1 给仍读 JAR 签名的安装器和安全扫描；不加 `--min-sdk-version` 时 apksigner 按 minSdk 26 不查 v1），证书主题不得含 `CN=Android Debug`，证书 SHA-256 必须与上一版一致。验证失败时不要生成或上传 `dist/`、`update.json`。
4. **生成资产**（改名、算校验和、写 `update.json`）。默认只收录 arm64；版本名取 pubspec，构建号用 `aapt2` 从 APK 里读。版本名不匹配或构建号还是占位的 `1` 时脚本直接报错：

   ```sh
   python3 tooling/release_assets.py --notes notes.md      # 产物在 dist/
   ```

   顺带为最近 3 个已发布版本各做一个增量补丁（`--delta-from N`，`0` 不做、不联网）：用 `gh` 取各版的 arm64 APK（缓存在 `~/.cache/dshgo-release/apk/`，按该版的 `SHA256SUMS` 核对），只留不到整包 60 % 的，写进 `dist/`、`SHA256SUMS` 和 `update.json` 的 `patches`。换了运行时的版本补丁接近整包，会全部被丢掉，正常。格式、App 端回落规则和实测大小见 `docs/design/delta-update.md`。

   > **不要只跑 `gh release create`。** 它只更新 GitHub；内测通道的 `beta/update.json` 会停在旧版本。带着内测令牌装的旧版本会先问内测通道，于是报「已是最新」（1.0.4 卡住就是这个原因）。公测发版一律走下面这个脚本：它同时写 R2、GitHub（`--github`）并回下载核对。
5. **上传并上线**：`services/share-worker/scripts/publish-release.sh`，`SHA256SUMS` 里的每个文件（APK、补丁）一次传到所有线路（R2、公开下载桶 dl、香港桶、GitHub Release），分别下载回来核对，全部一致才上线。见下面「发版到三条线路」。
   - 公测起加 `--github`：GitHub Release 由脚本建（标题 `DSH Go <版本>`，正文取 `docs/changelog.md` 对应一节）。`release_assets.py` 最后打印的 `gh release create …` 不用再手动跑。
   - 测试版（版本名带 `-`）脚本自动加 `--prerelease`：`releases/latest` 和 `releases/latest/download/…` 都跳过预发布，公开下载桶根目录的 `update.json` 也不换，只有正式版会推给用户。
6. **内测期间**（`DOWNLOAD_ACCESS=key`）不加 `--github`，见下面「内测通道」。
7. **验证**：在装着上一版的手机上 设置 → 关于 → 检查更新，走完下载和安装。

## 内测通道（go.dshtui.com/beta）

内测包不公开：人凭**密钥**在 `https://go.dshtui.com/beta` 下载，已装的 App 凭构建时注入的**通道令牌**检查更新、App 内下载。两者分开：群里的密钥可以随时换、随时吊销，已装 App 照常收到更新。服务端是 `services/share-worker`（设计见 `docs/design/share-links.md` §14），凭据只以文件形式存在发版机器上，放在仓库之外：

| 文件（脚本的默认位置，权限 600） | 内容 | 用在 |
|---|---|---|
| `~/keys/dshgo-beta-secret` | Worker secret `BETA_SECRET`：密钥哈希的盐、下载链接的签名钥 | `beta-keys.sh` |
| `~/keys/dshgo-beta-channel.token` | 通道令牌（`dshc_…`） | `build-apk.sh --beta` 才编进内测包（公测包不带）；`publish-release.sh` 实测 |
| Cloudflare API token | 部署、写 R2 / KV | 各脚本的 `CF_TOKEN_FILE` |
| `~/keys/dshgo-cloudflare-account-id` | Cloudflare 账号 id（32 位十六进制）。公开仓库的 `wrangler.jsonc` 只有占位符（`tooling/oss-redact.txt`），R2 的地址和部署靠它 | 所有用到账号的脚本（`scripts/cloudflare.sh`）；也可以用 `CF_ACCOUNT_ID` 直接给 |
| `~/keys/dshgo-cloudflare-kv-quota-id` | KV 命名空间 `dshgo-share-quota` 的 id（32 位十六进制），`wrangler.jsonc` 里同样只有占位符；`provision.sh apply` 发现或新建 KV 时写这个文件 | `provision.sh`、`beta-keys.sh`；也可以用 `CF_KV_QUOTA_ID` 直接给 |

部署和管密钥（`provision.sh`、`beta-keys.sh`）在公开仓库里就能跑：两个 id 只写进 `wrangler.jsonc` 旁边的临时副本（`.wrangler-*.json`，`wrangler --config` 用它，退出即删），跟踪的 `wrangler.jsonc` 不改；读到的是占位符时，什么都不做就报错。`provision.sh` 还会核对：账号是不是 `dshtui.com` 所在的账号、KV id 是不是 `dshgo-share-quota` 的。

**一次性开通**（每台发版机器一次）：

```sh
cd services/share-worker
CF_TOKEN_FILE=<token 文件> scripts/beta-keys.sh init                 # 生成 BETA_SECRET 并设为 Worker secret
CF_TOKEN_FILE=<token 文件> scripts/beta-keys.sh channel-add app-1    # 生成通道令牌并登记
CF_TOKEN_FILE=<token 文件> scripts/beta-keys.sh add beta-1 --out <文件>   # 给人用的密钥，明文只写进 <文件>
```

**每次发内测版**：

1. 改版本名（`app/pubspec.yaml`）并同步使用说明（同上「发版步骤」第 1 步，`guide_sync.py --check` 通过），在 `docs/changelog.md` 写好 `## X.Y.Z · 日期`，下面 `### 中文`、`### English` 两节——页面和 App 弹窗的更新说明从这里取，缺一节脚本就停。
2. 打包：`tooling/build-apk.sh --beta`（arm64）。须有非空的通道令牌文件，缺失时脚本报错。第一行要带 `· beta channel`，说明令牌已编进去；`--debug` / `--profile` 不带通道令牌，不走内测通道。
3. 确认签名（同上第 3 步），生成资产：`python3 tooling/release_assets.py`，产物在 `dist/`。
4. 上传并实测：

   ```sh
   cd services/share-worker
   CF_TOKEN_FILE=<token 文件> BETA_KEY_FILE=<存着一把有效密钥的文件> scripts/publish-release.sh ../../dist --no-dl
   ```

   `--no-dl`：公开下载桶谁都能读，内测包不能放上去。

   脚本核对 `dist/` 的大小和 SHA-256，把 `SHA256SUMS` 里的文件和它本身传到 R2 `beta/<版本>/`（配了香港桶也传过去，见下一节），以 App 的身份（通道令牌）整包下载回来比对，全部一致后才传改写过的 `update.json`（下载地址指向 `/beta/<版本>/`，`page` 指向 `/beta`，`notes` 和 `notesByLocale` 来自更新日志，`routes` 记着文件在哪几条线路上），最后换 `beta/update.json`。之后再以人的身份（密钥 → 签名链接）下载一次。`--no-latest` 只传文件不换最新版；同一版本已上传且大小不同会被拒绝，修包要升版本名。
5. 手机上验证：装着上一版内测包的手机 设置 → 关于 → 检查更新。

**密钥**（`scripts/beta-keys.sh`，都要 `CF_TOKEN_FILE`）：

| 操作 | 命令 |
|---|---|
| 新建 | `add <标签> [--expires 2026-12-31] [--out 文件]`，格式 `dsh-` + 8 位（不含 0 1 i l o），不加 `--out` 时打印到终端 |
| 查看 | `list`：标签、创建、过期、状态，不显示密钥 |
| 吊销 | `revoke <标签>`；KV 全球生效要一分钟左右，已发出的下载链接最多再用 10 分钟 |
| 换掉所有密钥 | `init --rotate` 换 `BETA_SECRET`，旧密钥全部失效（通道令牌不受影响），再 `add` 新的 |
| 通道令牌 | `channel-add <标签>` / `channel-list` / `channel-revoke <标签>`。换令牌：新令牌另存一个文件，`BETA_TOKEN_FILE=<新文件> … channel-add app-2`，之后的包用新令牌（`DSH_BETA_TOKEN_FILE=<新文件> tooling/build-apk.sh --beta`）；等旧包的人都升级了再吊销 `app-1`，否则他们就收不到更新了 |

**回滚**：把上一版的清单重新设为最新，新版文件留着不影响（在 `services/share-worker` 下，环境变量 `CLOUDFLARE_API_TOKEN` 取自 token 文件，`CLOUDFLARE_ACCOUNT_ID` 取自 `~/keys/dshgo-cloudflare-account-id`）。公开下载桶、GitHub 和香港桶见「发版到三条线路」的回滚表。

```sh
npx wrangler r2 object get dshgo-share/beta/<上一版>/update.json --file prev.json --remote
npx wrangler r2 object put dshgo-share/beta/update.json --file prev.json --content-type 'application/json; charset=utf-8' --remote
```

**限制**：令牌编在 APK 里，拿到 APK 的人能取出来，所以它挡的是「没有安装包的人」，不是装过的人；泄露了就按上表换令牌。没有令牌的旧包（包括 0.9.1）不会走内测通道，要用户在页面上手动下载一次带令牌的新包。

## 发版到三条线路（公测起）

下载页（`go.dshtui.com`）给同一个 APK 三条线路，SHA-256 和大小都一样：

| 线路 | 下载地址 | 存在哪 | 谁默认用它 |
|---|---|---|---|
| 国内线路 | `<CN_BASE_URL><版本>/<文件>` | 香港对象存储（阿里云 OSS 或腾讯云 COS），公共读 | `request.cf.country` 为 `CN` |
| 海外线路 | 公开模式 `https://dl.dshtui.com/download/<版本>/<文件>`（清单 `routes` 里没有 `dl` 的旧版本是 `/download/<版本>/<文件>`）；密钥模式是 10 分钟的签名链接 | 公开模式：公开 R2 桶 `dshgo-dl`，字节不经 Worker；旧版本和密钥模式：R2 `beta/<版本>/`，经 Worker | 其他地区 |
| GitHub | `github.com/ccch1mneyyy/dsh-go/releases/download/v<版本>/<文件>` | GitHub Release | 手动切换 |

- 页面上用分段按钮切换（纯 CSS，不跑脚本）；`?via=cn|global|github` 直接指定线路，`?lang=zh|en` 指定语言（默认跟浏览器）。
- 一条线路只在**配置了**并且**这一版确实传上去了**时出现：`beta/update.json` 的 `routes` 由发布脚本在下载核对之后写入。`CN_BASE_URL` 为空时国内线路整项隐藏；没有 `routes` 的旧清单只给海外线路。
- 安装说明（Android 8.0+、允许浏览器安装未知应用）和「社区作品，非 DeepSeek 官方应用」在页面上；微信、QQ 内置浏览器里仍是「在浏览器打开」提示页。
- App 内更新：带通道令牌的包走 `/beta/update.json` 和 R2，其余走 GitHub 和公共加速镜像；公开下载桶根目录的 `update.json` 也给 App 读（App 侧见 `app/lib/update/`）。香港桶目前只给网页用。

### 公开下载桶 dl（dl.dshtui.com）

只放发版文件的 R2 桶 `dshgo-dl`，绑自定义域名 `https://dl.dshtui.com`，公开读。海外线路的下载直接从这里出，不经 Worker（不占 Worker 请求、没有 Worker 的 CPU / 时长限制），R2 出口流量不收费。用户上传的分享链接所在的 `dshgo-share` 保持私有：它要是公开了，拿到对象键的人就能绕过 Worker 的过期和额度。

| 路径 | 内容 | `Cache-Control` |
|---|---|---|
| `download/<版本>/<文件>` | `SHA256SUMS` 里的每个文件（APK、补丁）、`SHA256SUMS`、这一版的 `update.json` | `public, max-age=31536000, immutable`：同一版本永远不换文件 |
| `update.json` | 最新正式版的清单（schema 1，`release_assets.py` 的内容 + 更新日志的 `notes` / `notesByLocale`，`assets.*.url` 是上面的绝对地址，`patches` 原样）；预发布版不换它 | `public, max-age=300` |

- 页面上：`wrangler.jsonc` 的 `DL_BASE_URL`（`https://dl.dshtui.com/`）配了、且这一版的 `routes` 有 `dl`，海外按钮（经 `/download/get` 计数）才 302 到这里；否则还是 `/download/<版本>/<文件>`。Worker 的 `/download/<版本>/<文件>` 一直保留，给已经发出去的链接。
- 脚本：`publish-release.sh` 默认就传（`DL_BUCKET` 默认 `dshgo-dl`，`DL_BASE_URL` 默认读 `wrangler.jsonc`），`--no-dl` 跳过。用的是 R2 那把 token 派生的 S3 凭据，token 要有账号级的 Workers R2 Storage:Edit。
- **一次性开通**（后台操作，脚本不建）：R2 新建桶 `dshgo-dl`，在桶的设置里给它连接自定义域名 `dl.dshtui.com`（DNS 记录由 Cloudflare 自动建）；不要开 `r2.dev` 公开地址。之后 `curl -I https://dl.dshtui.com/update.json` 是 404 就对了，第一次发版后变成 200。

### 开关：DOWNLOAD_ACCESS

Worker 变量，写在 `services/share-worker/wrangler.jsonc` 的 `vars` 里：

| 值 | `/beta` | `/download` | `/download/<版本>/<文件>` |
|---|---|---|---|
| `key`（默认） | 输入密钥 → 三条线路 | 404 | 404 |
| `public` | 302 → `/download`（带上查询参数） | 三条线路，不要密钥 | APK、`SHA256SUMS` 公开下载 |

两种模式都不变：App 的通道令牌、`/beta/update.json`、`/beta/<版本>/<文件>`（令牌或签名链接）、`/beta/api/unlock`；`/update.json` 一直是 404。跳转用 302 不用 301：切回 `key` 时浏览器不会记着旧跳转。

公测当天：

1. `wrangler.jsonc`：`"DOWNLOAD_ACCESS": "public"`；香港桶开通了就同时填 `"CN_BASE_URL"`。提交。
2. `CF_TOKEN_FILE=<token 文件> scripts/provision.sh deploy`（部署并跑线上 e2e）。
3. 发版（下一小节，带 `--github`）。顺序反过来也行：清单里没有 `routes` 的版本只显示海外线路，不会出现死链。
4. 看一眼 `https://go.dshtui.com/download`、`/beta`（应跳到 `/download`）、`/download?via=cn`。

- 变量以 `wrangler.jsonc` 为准：在 Cloudflare 后台改的值，下次部署会被文件覆盖。
- 切回：改回 `"key"` 再部署；已经发出去的 `/download` 链接变回 404。

### 香港桶（可选）

二选一，开一个只放安装包的桶：

| | 阿里云 OSS | 腾讯云 COS |
|---|---|---|
| 地域 | 中国香港，`cn-hongkong` | 中国香港，`ap-hongkong` |
| 桶名 | 例如 `dshgo-cn` | 例如 `dshgo-cn-<APPID>`（COS 桶名带 APPID） |
| 读写权限 | 公共读（先关掉「阻止公共访问」） | 公有读私有写 |
| `CN_BASE_URL` | `https://<桶名>.oss-cn-hongkong.aliyuncs.com/` | `https://<桶名>.cos.ap-hongkong.myqcloud.com/` |
| 命令行 | ossutil 2.x（`ossutil version` 显示 2.x） | coscli |
| AccessKey | RAM 用户，只授权这一个桶，策略见下 | CAM 子用户，只授权这一个桶，策略见下 |

要交给发版机器的：桶名、地域、`CN_BASE_URL`，以及 AccessKey 的 ID 和 Secret（各存一个文件，权限 600）。另外建议在控制台设**费用 / 流量告警**：香港桶的外网流量按量计费（价格以控制台为准），180 MB 的包下载 1000 次约 180 GB；公共读地址谁都能刷。

阿里云 RAM 自定义策略（`dshgo-cn` 换成桶名）：

```json
{
  "Version": "1",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["oss:PutObject", "oss:GetObject", "oss:ListObjects", "oss:ListParts", "oss:AbortMultipartUpload"],
    "Resource": ["acs:oss:*:*:dshgo-cn", "acs:oss:*:*:dshgo-cn/*"]
  }]
}
```

腾讯云 CAM 自定义策略（换成 APPID 和桶名）：

```json
{
  "version": "2.0",
  "statement": [{
    "effect": "allow",
    "action": ["name/cos:HeadBucket", "name/cos:PutObject", "name/cos:HeadObject", "name/cos:GetObject",
               "name/cos:InitiateMultipartUpload", "name/cos:UploadPart", "name/cos:CompleteMultipartUpload",
               "name/cos:AbortMultipartUpload", "name/cos:ListParts", "name/cos:ListMultipartUploads"],
    "resource": ["qcs::cos:ap-hongkong:uid/<APPID>:dshgo-cn-<APPID>/*", "qcs::cos:ap-hongkong:uid/<APPID>:dshgo-cn-<APPID>/"]
  }]
}
```

两份策略都没在真账号上试过；命令行报 AccessDenied 时，按报错里的 Action 补上。第一次真传建议用一个测试版本加 `--no-latest`。

### 发版

```sh
cd services/share-worker
export CF_TOKEN_FILE=<Cloudflare token 文件>
export CN_PROVIDER=oss CN_BUCKET=dshgo-cn CN_REGION=cn-hongkong          # COS：cos、dshgo-cn-<APPID>、ap-hongkong
export CN_ACCESS_KEY_ID_FILE=<AccessKey ID 文件> CN_ACCESS_KEY_SECRET_FILE=<AccessKey Secret 文件>
scripts/publish-release.sh ../../dist --github --dry-run    # 先看一遍要做什么
scripts/publish-release.sh ../../dist --github
```

| 步骤 | 做什么 |
|---|---|
| 1 R2 | `SHA256SUMS` 里的每个文件（APK、补丁）和 `SHA256SUMS` → `dshgo-share/beta/<版本>/`，以及公开桶 `dshgo-dl/download/<版本>/`（带 immutable 的 Cache-Control）。rclone 分片续传，没有就 wrangler |
| 2 国内 | 同样这些 → 香港桶 `<版本>/`（`ossutil cp` / `coscli cp`，带 Content-Type 和 Cache-Control）。`CN_BASE_URL` 为空时跳过 |
| 3 GitHub | `gh release create v<版本> … --draft`：arm64 APK、补丁、`SHA256SUMS`、`update.json`（不带 `url`，App 自己拼 GitHub 地址），正文先提供 arm64 直接下载链接，并说明清单、校验文件和补丁无需手动下载，再列更新日志的「中文」「English」两节；正式版没有 x64 下载入口 |
| 4 核对 | 每条线路、每个文件下载回来比大小和 SHA-256：R2 用通道令牌，公开桶和香港桶用公开地址，GitHub 草稿用 API |
| 5 上线 | 全部一致才：发布 GitHub 草稿（并确认公开地址可下）→ 公开桶的 `download/<版本>/update.json` 和根目录 `update.json` → 传 `beta/<版本>/update.json` → 最后换 `beta/update.json` |
| 之后 | 确认 `dl.dshtui.com/update.json` 是这一版、线上页面（`/download` 或 `/beta`）给出这一版和每条线路的链接，再从页面的海外线路下载一次 |

| 参数 / 变量 | 作用 |
|---|---|
| `--dry-run` | 每一步打印将要执行的命令，什么都不传、不下载、不联网 |
| `--github` | 建 GitHub Release；默认不建 |
| `--no-dl` | 这次不传公开下载桶（密钥模式发内测版时必须加） |
| `--no-cn` | 这次不传香港桶 |
| `--no-latest` | 只传和核对，不上线（GitHub 留在草稿） |
| `--skip-verify` | 不下载核对；必须同时 `--no-latest` |
| `CN_PROVIDER` `CN_BUCKET` `CN_REGION` | 香港桶：`oss`/`cos`、桶名、地域 |
| `CN_ACCESS_KEY_ID_FILE` `CN_ACCESS_KEY_SECRET_FILE` | 只写这个桶的 AccessKey，各一个文件 |
| `CN_BASE_URL` | 默认读 `wrangler.jsonc`，脚本和页面用同一个值 |
| `DL_BUCKET` `DL_BASE_URL` | 公开下载桶，默认 `dshgo-dl` 和 `wrangler.jsonc` 的 `DL_BASE_URL`；任一为空就不传 |
| `CF_ACCOUNT_ID` `CF_ACCOUNT_ID_FILE` | R2 所在的账号；不设时读 `~/keys/dshgo-cloudflare-account-id`，再不行才读 `wrangler.jsonc`。读到的是占位符就在第一步之前报错 |
| `GH_TOKEN_FILE` | 可选；不设就用 `gh auth login` 的登录（要有仓库写权限） |
| `BETA_TOKEN_FILE` `BETA_KEY_FILE` | 通道令牌（读回 R2）；密钥模式下还要一把有效密钥（核对 `/beta`） |

- 凭据只从文件读，写进私有临时目录里的配置文件（退出时 shred）或单条命令的环境变量，不打印、不上命令行。
- 重跑是安全的：已经传上去且大小一致的文件跳过（第 4 步照样下载核对）；同一版本换了文件在任何一条线路上都会被拒绝，修包要升版本名。
- **正式版的 GitHub Release 一发布，`releases/latest` 就指向它**：所有不带通道令牌的 App（0.9.1 及更早、开发包）都会收到更新提示。
- 演练：`npm run smoke:publish`（假的 dist（带一个补丁）、假的 ossutil / coscli / gh、本地目录充当公开桶、本地 `wrangler dev`，不连任何真实服务）。

### 回滚

| 撤回什么 | 做法 |
|---|---|
| 页面和带令牌的 App | 上一版的清单设为最新（「内测通道」的回滚两行）。上一版若是旧脚本发的、清单里没有 `routes`，回滚后页面只给海外线路 |
| 公开桶的 `update.json` | `npx wrangler r2 object get dshgo-dl/download/<上一版>/update.json --file prev.json --remote`，再 `npx wrangler r2 object put dshgo-dl/update.json --file prev.json --content-type 'application/json; charset=utf-8' --cache-control 'public, max-age=300' --remote`（环境变量同上）；边缘最多再给 5 分钟旧的。上一版没传过公开桶（回滚的是第一个走 dl 的版本）时没有可回的清单，删掉 `dshgo-dl/update.json` 即可 |
| GitHub 上的这一版 | `gh release edit v<版本> --repo ccch1mneyyy/dsh-go --draft=true` 撤回成草稿，`releases/latest` 回到上一版；彻底删除用 `gh release delete v<版本> --repo ccch1mneyyy/dsh-go --cleanup-tag` |
| 香港桶 | 不用动：页面跟着清单走，不再指向新版；要删就删 `<版本>/` |
| 公开下载 | `DOWNLOAD_ACCESS` 改回 `"key"` 再部署 |

## 统计

下载、更新检查和 App 的匿名使用报告都记在 Cloudflare 的 Analytics Engine 里，不存 IP；数据模型和隐私说明见 `docs/design/share-links.md` §15。

**开通**（一次，我们的账号已经做完）。`wrangler.jsonc` 绑定了三个数据集，`provision.sh` 默认带着部署；没开 Analytics Engine 的账号带着它们部署会失败，所以先开通。没开通期间（`--no-analytics`）下载和更新检查不计数，`/api/usage/v1` 是 404。

1. 在 Cloudflare 后台的 Analytics Engine 页面开通（免费计划可用）。
2. `USAGE_SECRET` 和带上数据集的部署：

   ```sh
   cd services/share-worker
   (umask 077; openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' > <USAGE_SECRET 文件>)
   CLOUDFLARE_API_TOKEN="$(cat <token 文件>)" CLOUDFLARE_ACCOUNT_ID="$(cat ~/keys/dshgo-cloudflare-account-id)" \
     npx wrangler secret put USAGE_SECRET < <USAGE_SECRET 文件>
   CF_TOKEN_FILE=<token 文件> scripts/provision.sh deploy   # 默认绑定 DOWNLOADS、CHECKS、USAGE（数据集第一次写入时自动建）
   ```

3. 点一次下载页的按钮，几分钟后 `scripts/stats.sh` 有数。没开通 Analytics Engine 的账号（fork）部署时要带 `--no-analytics`（或 `DSH_ANALYTICS=0`），否则部署失败。

- 读数用的 token 要加一项权限：Account → Account Analytics → Read（部署用的那把可以一起加，也可以另开一把只读的）。
- `USAGE_SECRET` 不要换：换了以后安装编号的哈希对不上，留存从那天断开。丢了也只是从头算，不影响 App。
- 没设 `USAGE_SECRET` 时 `/api/usage/v1` 是 404，下载和更新检查照常计数。

**看数**：

```sh
CF_TOKEN_FILE=<token 文件> scripts/stats.sh              # 最近 14 天（UTC+8）
CF_TOKEN_FILE=<token 文件> scripts/stats.sh --days 30
scripts/stats.sh --dry-run                               # 只打印 SQL
scripts/github-downloads.sh                              # GitHub 每个 release 每个文件的累计下载数
```

AE 只留约 3 个月，想长期保留就定期把输出存下来。

## 签名

Android 只接受和已装版本**同一签名**的覆盖安装。`build.gradle.kts` 从 `app/android/key.properties` 读取发布签名；配置缺失时回落到打包机器的 `~/.android/debug.keystore`，仅供本地构建。正式发版必须先配置发布密钥。

做法：生成一把发布密钥，只在发版机器上用，并离线备份（丢了等于以后再也发不了更新，所有用户都得卸载重装）。

```sh
keytool -genkeypair -v -keystore /home/you/keys/dsh-release.jks -keyalg RSA -keysize 4096 -validity 36500 -alias dsh
```

`app/android/key.properties`（**加进 .gitignore，不要提交**）：

```properties
storeFile=/home/you/keys/dsh-release.jks
storePassword=…
keyAlias=dsh
keyPassword=…
```

`app/android/app/build.gradle.kts`：

```kotlin
import java.util.Properties

val keyProps = Properties().apply {
    rootProject.file("key.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

android {
    signingConfigs {
        create("release") {
            storeFile = keyProps.getProperty("storeFile")?.let { file(it) }
            storePassword = keyProps.getProperty("storePassword")
            keyAlias = keyProps.getProperty("keyAlias")
            keyPassword = keyProps.getProperty("keyPassword")
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (keyProps.isEmpty) "debug" else "release")
        }
    }
}
```

**换钥匙的代价**：已经装了 debug 签名版的人，第一次更新会被系统拒绝。App 会在安装前比对签名，提示「签名不一致，不能直接覆盖」，引导去发布页下载；他们得**卸载旧版再装新版一次**，卸载会清空本地数据（对话、Linux 环境、设置、Keystore 里的 API Key）。之后的更新都正常。

想让老用户免卸载，有两条路，各有代价：

| 做法 | 好处 | 代价 |
|---|---|---|
| 把现在那台机器的 `debug.keystore` 当发布密钥长期用 | 老用户无感 | 证书是「Android Debug」，口令是公开的 `android`，安全全靠文件不外泄；以后想换还是要走一次这个流程 |
| APK 签名 v3 密钥轮换（`apksigner rotate` 生成 lineage，用 `apksigner sign --lineage` 重签） | Android 9+ 的老用户直接覆盖更新 | AGP 不直接支持，要在构建后手工重签；Android 8.x（minSdk 26）不认 lineage，仍需重装 |

App 的签名预检认 lineage：新包的签名历史里含已装版本的签名，就当作一致。

## App 怎么更新

```text
启动 6 秒后（每天最多一次，设置里可关）或 设置 → 关于 → 检查更新
  → 依次问元数据源（见「镜像与回落」），第一个给出可用版本的为准
  → 比已装版本新、且没被「跳过」→ 弹窗：版本、下载大小（有补丁可用时是补丁的大小）、更新说明
  → 立即更新：有补丁就下补丁、用已装 APK 拼出新包，否则下整包；都在 cache/updates/，断点续传，可取消，关掉弹窗也继续
  → SHA-256 校验（不一致删掉、换下一个源从头下）
  → 没有「安装未知应用」权限 → 引导到系统设置，回来自动继续
  → 预检：包名、签名和已装版本一致
  → PackageInstaller 会话安装，系统弹确认框 → App 被替换并退出
```

- **节流**：成功检查后 24 小时内不再自动查；失败后 4 小时内不重试；时钟被往回拨视为到期。手动检查不受限。
- **跳过这个版本**：这个版本不再自动弹，有更新的版本照常提醒；「关于」里显示「已跳过」。手动检查仍会打开弹窗。
- **稍后**：只关弹窗，下次自动检查（次日）还会提醒。
- **上次的结果会缓存**：重启后不联网也能看到「新版本」标记；装好新版后自动清掉缓存和残留安装包。
- **导出安装包**：「可以安装」，或签名不一致 / 安装被拦截的失败界面，可以「导出安装包」：把校验过的包复制到 `Download/DSH-Go/`（MediaStore，文件名就是清单里的资产名）。这是给「首次安装被厂商拦、只能自己重签」的人兜底，不是常规更新路径——重签后的包和官方签名不同，App 内更新会一直停在「签名不一致」，以后每版都得手动重签覆盖装。能走 Shizuku / 本机 ADB 就别走这条路。导出只是复制，`cache/updates/` 里的原文件、安装和清理逻辑都不变（提权安装器要求文件直接在 `cache/updates` 下，别把下载目录搬走）。
- **磁盘**：开始下载前要求可用空间 ≥ 安装包 × 2 + 64 MB（下载 + 安装暂存）。走补丁也是这个门槛：补丁拼完就删，峰值仍是安装暂存那一刻。
- 安装用 PackageInstaller 会话（把文件流写进会话），不用 FileProvider，也不需要 `content://`。

### 增量更新

`update.json` 可以带 `patches`，按 flavor 列出从某个旧 APK 到这一版 APK 的补丁：

```json
"patches": {
  "arm64": [
    { "from": "<旧 APK 的 SHA-256>", "fromVersion": "1.0.7", "name": "<补丁文件名>", "size": 12345678, "sha256": "<补丁文件的 SHA-256>" }
  ]
}
```

补丁和 APK 放在同一个版本、同样的镜像上，地址照 APK 的推：APK 地址的最后一段换成 `name`，然后是 GitHub 这一版的同名附件经各个镜像。缺字段的补丁条目直接忽略；APK 和补丁的 `name` 会成为下载目录里的文件名，必须是普通文件名（字母或数字开头，只含字母、数字和 `._+-`），否则那一项也忽略。没有 `patches` 的旧清单行为不变。

补丁格式 `DSHDLT01`，整数一律大端：

| 部分 | 内容 |
|---|---|
| 头（80 字节） | 8 字节 `DSHDLT01` · 32 字节旧 APK 的 SHA-256 · 32 字节新 APK 的 SHA-256 · u64 新 APK 长度 |
| `0x01` COPY | u64 旧 APK 里的偏移 · u64 长度：复制旧 APK 的这一段 |
| `0x02` DATA | u64 长度 · 这么多字节：原样写出 |
| `0x00` END | 结束；写出的必须正好是头里的长度，SHA-256 也要对上 |

App 这边（`app/lib/update/delta.dart`、`app/lib/state/update_state.dart`）：

1. **已装 APK 的哈希**：清单里有本机 flavor 的补丁时，才去算 `applicationInfo.sourceDir` 的 SHA-256，在后台 isolate 里算，按 versionCode + 安装时间缓存（`update_installed_sha256`），每个装上的包只算一次。检查要等它算完才算结束，所以弹窗一出来就是对的大小。
2. **用补丁**：某条补丁的 `from` 等于这个哈希 → 下载补丁（续传、换源、超时都和 APK 一样）→ 校验补丁的 SHA-256 → 头里的旧 APK 哈希、新 APK 哈希和长度都要对上 → 从已装 APK 流式拼到整包下载会用的同一个文件（先写 `.part`，对上了才改名）→ 长度和 SHA-256 等于清单里 APK 的 → 删掉补丁，后面的签名预检和 PackageInstaller 安装不变。
3. **回落**：上面任何一步失败 → 不提示，当场改下整包，并记住这一版不再试补丁（`update_patch_failed`）。没有 `from` 对得上的补丁不算失败，直接下整包。取消下载不算失败，下次接着下补丁。
4. **内存**：补丁顺序读、旧 APK 按偏移读，各一个 64 KiB 缓冲，边写边算哈希。180 MB、约 42 万个操作的合成补丁，桌面上（AOT）2.1 秒、常驻内存 8 MB。

补丁不改变信任链：它只是拿到同一个 APK 的另一种办法，最后核对的仍是清单里 APK 的 SHA-256，安装前照旧过签名预检。

## 镜像与回落

源列表集中在 `app/lib/update/update_config.dart`。元数据按下表从上到下问，下载按镜像顺序试。除了内测通道和 GitHub API，**上次成功的源排到最前**，连不上某个源的手机不会每次都先等它超时；GitHub API 哪怕上次成功也排最后。

| 源 | 用于 | 好处 | 坏处 |
|---|---|---|---|
| 内测通道 `go.dshtui.com/beta/update.json`（带通道令牌的包才有，永远排第一，不参与「上次成功排最前」） | 元数据 + APK（同一令牌） | 不公开；国内可达；发版即生效 | 令牌编在包里，可被提取；没令牌的包用不了 |
| 自有下载站 `dl.dshtui.com`（R2 公共桶，所有包默认都有） | 元数据 `/update.json`（最新公开版，资产带绝对地址）+ APK 和补丁 `/download/<版本>/<文件>`（下载也排第一） | 自己的，完全可控；不占 GitHub 配额；有补丁 | 流量和可达性要自己盯；国内速度看 Cloudflare 线路 |
| `github.com/…/releases/latest/download/update.json` | 元数据 + APK | 不占 API 配额；和 APK 同一个 CDN | 国内常慢或不通 |
| 公共加速镜像（默认 `ghfast.top`、`gh-proxy.com`） | 元数据 + APK | 零成本，国内大多能用 | 第三方：随时失效、换域名（几个月一换很常见），有的整段网络一律 403（`ghfast.top` 2026-11 起从我们机器出去全是 403，仍留在列表里，被拒只多一次请求）；能看到下载者 IP；大文件可能限速；理论上能篡改内容（见下） |
| GitHub API `releases/latest`（最后） | 元数据 | 官方；带 digest，不额外请求校验和 | 匿名 60 次/小时/IP，校园网、运营商 NAT 和代理出口下常常已经 403；回答里没有补丁；国内常超时 |

构建时可以改（`--dart-define`，不用改代码）：

| 变量 | 作用 |
|---|---|
| `DSH_UPDATE_MIRROR=https://…` | 换掉 `dl.dshtui.com`（同样的 `/update.json` + `/download/<版本>/<文件>` 布局）；设成空串就不用自有站，只剩 GitHub 和加速镜像 |
| `DSH_UPDATE_FEED=https://…/update.json` | 只换要问的清单，下载仍先试自有站；空串 = 不问清单 |
| `DSH_UPDATE_MIRRORS=a,b` | 换掉公共加速镜像列表（前缀 + 完整 GitHub 地址）；空串 = 不用 |
| `DSH_BETA_CHANNEL_ORIGIN` | 换内测通道的域名 |
| `DSH_WORKSHOP_ORIGIN=https://…` | 换创意工坊的部署，默认 `https://go.dshtui.com`；空串 = 这个包不带工坊入口 |

公共镜像要定期确认还活着，失效的直接从列表删。

下载的超时策略：连接 15 秒、30 秒没收到数据算断线；同一个地址断线续传最多再试 2 次，连不上或返回错误就换下一个源。补丁和 APK 用同一套。

## 安全

- **SHA-256**：来自元数据（API 的 `digest`、`update.json` 的 `sha256`，都没有时读 `SHA256SUMS`）。缺校验和的版本 App 不装，只给发布页链接。它防的是传输损坏，以及只篡改 APK 的镜像。
- **签名**才是最后一道防线：镜像如果同时篡改清单和 APK，校验和也能对上，但它签不出我们的签名，系统和 App 的预检都会拒绝覆盖安装。所以发布密钥必须固定且保密，绝不能用一把谁都拿得到的钥匙。
- **降级**：系统拒绝 versionCode 更低的包；App 也只在版本更新时提示。正式包要在升完版本名之后、用 `build-apk.sh` 现打，不要拿早先打好的包去发：手机上若装着更晚打的旧版本名开发包，App 会提示更新，系统却会按降级拒装。

## 出问题时 App 的表现

| 情况 | 表现 |
|---|---|
| 还没有 release、仓库私有、限流、断网 | 「关于」里显示「暂时检查不了」；手动检查弹一条提示，不弹错误对话框；自动检查静默 |
| 新版没有本机 flavor 的 APK | 弹窗说明，按钮改为「打开发布页」 |
| 下载断了 | 保留已下载部分，「重试」接着下 |
| 校验不通过 | 删除文件，换源重下；都不通过就报错 |
| 签名不一致 | 安装前拦下，说明要卸载重装，按钮「打开发布页」「导出安装包」 |
| 用户在系统确认框里取消 | 回到「安装包已下载」，可再装 |

## 真机验证清单（尚未在真机上跑过）

- [ ] 首次安装：「安装未知应用」引导页能打开，授权后回到 App 自动继续安装
- [ ] 同签名覆盖：确认后 App 退出，重开后版本号变化、对话和设置还在，运行时按新版本升级
- [ ] 签名不同的包：安装前提示「签名不一致」，不出现系统报错
- [ ] 系统确认框按返回：回到「已取消安装」，可以再装
- [ ] 下载中切到后台、断网再恢复、杀进程后重进：都能续传
- [ ] 国产 ROM（vivo / 小米 / 华为）：自带的安装拦截页、「安全安装」流程不会让 App 卡在「安装中」（App 回到前台 3 秒后会自动放开）
- [ ] 公共镜像实测可用；GitHub 不通时能回落
