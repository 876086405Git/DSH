# DSH Go 插件市场

这是待拆出到公开仓库 `ccch1mneyyy/dsh-go-market` 的完整目录。安装入口是 DSH Go 的插件市场；本仓库只维护锁定版本的目录与静态检查结果，不托管或执行插件代码。

发布产物：`index.json` 使用 DSH 格式 1，`dsh-go.json` 使用 DSH Go sidecar schema 1，`audit.json` 保留本次结构化扫描证据。Worker 对外提供 `https://go.dshtui.com/market/`，分享页为 `https://go.dshtui.com/p/<encodeURIComponent(包名)>`。

## 提交插件

1. 先向 npm 发布一个有 OSI 开源许可证的 DSH bundle；市场只接受精确版本，例如 `1.2.3`，不接受 `latest`、范围或 Git 地址。
2. Fork 市场仓库，在 `plugins/` 增加一个 JSON。非 scoped 包用 `<包名>.json`；`@scope/name` 用 `@scope__name.json`。
3. 填写下例信息，向 main 提 PR。一次只增加或修改一个条目。升级同样修改这个文件的版本号，不追加历史版本。
4. 全部自动检查成功后启用 GitHub 自动合并；无需人工审批。风险特征不会单独挡住上架，会写入 App 展示的数据。结构、许可、完整性或查询失败会挡住并给出原因。

```json
{
  "name": "@someone/dsh-weather",
  "version": "1.2.0",
  "title": {"zh": "天气", "en": "Weather"},
  "summary": {"zh": "查看天气预报", "en": "Weather forecasts"},
  "category": "tools",
  "screenshots": [],
  "homepage": "https://github.com/someone/dsh-weather"
}
```

标题和简介必须有英文 `en`，可附中文 `zh`；截图仅 HTTPS，最多四张。分类为 `tools`、`media`、`productivity`、`communication`、`other`。**不要提交 `tier`、risk、integrity 或审核结论**。官方身份仅取维护者控制的 `policy.json.officialPackages`；历史禁用版本在 `policy.json.blockedVersions` 管理，任何作者都不能自行宣布官方身份或抹掉警告。

## 本地检查与生成

需要 Node.js 22 或更新版本。以下命令在本目录运行：

```sh
npm ci --ignore-scripts
npm test                      # 离线测试（含原始 npm tarball 夹具）
npm run check                 # 在线实扫，结构化结果写 reports/ 并输出 JSON
npm run build                 # 重新在线实扫，成功后生成 dist/ 下三个文件
npm run watch                 # 查 dist-tags.latest 并检查新版，输出 reports/updates.json
```

`check` 和 `build` 可附目录参数，例如 `node scripts/check.mjs candidates`。候选失败是预期现象。构建不消费提交者提供的扫描结果；始终重新下载 tarball、核对 npm SHA-512、读取包内实际 package.json 与文件，再查询 npm 公告。不会执行包中的脚本，也不会解压到宿主路径。文件大小、展开大小、条目数、链接、路径穿越、重复解包目标和解压上限都有限制；归档路径不能含空段、冒号或段尾点/空格，目录末尾的 `/` 与无后缀目录按同一个目标检查，目标忽略大小写去重以避免 Windows 别名冲突。

生成器直接调用锁文件固定的 `@deepseek-ai/dsh-plugin-market-index@0.2.1-rc.2` 的 `parseMarketIndex`；不是自行模拟官方校验器。每个条目恰好一个 npm 版本。两个索引的名称和版本相同。

## 检查规则与边界

阻止：精确版本不存在；许可不在 SPDX 的 OSI 清单中；超过 50 MiB 压缩或展开体积；包身份、SHA-512 或 DSH bundle patch 不一致；格式 1 无效；npm 公告中该版本命中 high/critical；提交 `tier`；检查必需的网络查询失败。`OR` 许可只需一个可选 OSI 分支，`AND` 需要全部 OSI；带 exception 的复杂表达式保守拒绝，维护者可扩展规则。

放行并标记：安装生命周期脚本 / 原生二进制（high），子进程 / 文件写入 / 大型压缩混淆源码（medium），网络 / 未声明并静态通过原生协议（low）。风险等级取最高值。每项记录最多 12 个实际文件路径供定位。工作区路径依赖运行时，文字扫描无法证明写入始终在工作区内，遇到文件写 API 会保守标记 `filesystem`，因此可能误报。

**自动检查发现的特征，不代表插件有恶意。** 这是可复现的启发式扫描，不是沙箱、签名认证或恶意代码证明。动态导入、拼接、间接调用可能漏检。npm bulk advisory 只查询当前发布包的精确版本，**不解析依赖树，不声称依赖也已审核**。依赖可在安装时解析成不同版本，宿主仍应实施自己的锁定和安全策略。查询失败会拒绝本次构建，保留已发布版本。

`integrity` 证明扫描的是 npm 当时给出的这份 tarball；不证明作者身份或后续宿主实际安装字节。当前 DSH `pluginManager.installBundle` 不接收 expected integrity，也不返回实际安装 tarball hash，App 只能做安装前的注册表比对，不能声称端到端完整性强制成立。

## 鸿蒙兼容性（静态）

可信检查器现在从实际包字节生成 `platforms.ohos`：`dsh-go.json` 中位于每个插件条目，格式 1 索引中位于 `metadata.platforms.ohos`。作者的 `plugins/*.json` 仍不接受该字段。报告区分原生模块、子进程、Wasm、命令入口和安装脚本，保留文件哈希与源码位置；没有执行插件或脚本。

`usable / partial / unavailable` 对应「可用 / 部分可用 / 不可用」，仅表示已扫描范围的静态判断。未扫描的必需依赖会使结果为 `partial`；该标签不保证存在可运行的功能子集。所有结果均标记 `deviceValidated: false`。鸿蒙应用内安装插件包的能力仍不可用，不因此字段变更；现有 App 读者会忽略新元数据，本补丁不改变界面或安装授权。

单包、锁定安装树、固定市场快照与版本/完整性绑定的数据补丁命令，见 [鸿蒙扫描说明](docs/ohos-compatibility.md)。`platforms/ohos-2026-11-02.json` 是一次精确版本快照的数据补充，不作为以后版本的兼容性承诺，也不替代每次发布的在线安全检查。

## 原生适配声明

复用 DSH Go 已有 `package.json.dshGo` 协议 v1，不引入另一套清单：

```json
{"dshGo":{"v":1,"minApp":"1.0.3","contributes":{}}}
```

实际最小 App 版本由作者按功能确定。检查器通过 SDK manifest JSON Schema 后，还需要有实际贡献插槽，或源码包含 `dsh-go/view` / `dsh-go/media`。只有空声明没有实现时仍为 `not-adapted`。features 从这些特征生成；`minApp` 从有效清单传递。静态通过并不等于已在 App 运行验证。SDK schema 快照与来源见 `vendor/native-schema/README.md`。

## 维护与发布准备

公开目录仓库为 [ccch1mneyyy/dsh-go-market](https://github.com/ccch1mneyyy/dsh-go-market)，Pages 地址为 https://ccch1mneyyy.github.io/dsh-go-market/ 。本目录保存对应的维护源码；独立仓库以本目录内容作为根目录，`.github` 位于根目录。

部署配置与维护要求：

- 创建 `ccch1mneyyy/dsh-go-market`，默认分支 main，允许 GitHub Actions 创建 PR，并启用 auto-merge 和 squash。
- 为 main 配置严格分支保护：要求最新 base 和 `market/catalog` 状态；其他必须通过的检查也加入 required checks。按 GitHub Actions 来源约束此状态，避免其他写入者伪造。工作流检测缺少这条保护会拒绝自动合并，不会自行降低保护。
- 在 Pages 设置选择 GitHub Actions 发布。`publish.yml` 只给部署作业 `pages:write` 和 `id-token:write`；无需 Cloudflare 密钥。
- 单条插件 PR 用 `pull_request_target` 跑 **可信 base** 的代码，固定 base/head SHA 比较变更，再沿该 head 的 commit → tree → blob 读取唯一 JSON，验证它是普通文件；拒绝符号链接和子模块，绝不 checkout / 执行 PR 脚本。成功状态写在实际 PR head SHA 上；自动合并再次核对 SHA。其他维护变更不走自动合并，需要维护者审查与单独验证。
- 每日 `watch.yml` 为通过扫描的新版创建只改一个条目的 PR，并显式调用 `workflow_dispatch` 复用完整检查。GitHub 的 GITHUB_TOKEN 不会递归触发普通 PR/push 事件；发布工作流另有每十分钟定时补偿（GitHub 排程可能延迟），手动 dispatch 也可立即发布。相关行为见 [GitHub 官方事件文档](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)。
- Worker 默认上游是 `https://ccch1mneyyy.github.io/dsh-go-market/`；可用 `MARKET_SOURCE_URL` 改为另一个 HTTPS 发布根地址。复用已有 QUOTA KV 存整组成功副本，不设过期，十分钟刷新；上游失败继续返回旧副本并带 `X-Market-Stale: true`，未有成功副本时返回 503。缓存不等于永久在线保证，KV 写入失败时仅当前 isolate 内存可保留新副本。

首批候选及不能上架的实际原因见 `candidates/README.md`。媒体包发布后再移入 plugins，不占用空包、不生成虚假的审核数据。
