# 931：代理与两次 App 生命周期的 Linux 测量客户端

`linux-device-measure.mjs` 在宿主Node运行，只用标准库和本仓库的 `research/linux-resume/guest-witness.mjs`；请从完整源码目录执行，不要只复制一个脚本。它通过 `/dsh-go/v1/linux` 鉴权协议驱动App内guest；宿主不执行gh、git、Python或ripgrep。本次931新增状态投影、代理配置和两段持久恢复测量；宿主定向测试的服务/guest仍是明确替身，不代表新版CLI已经在手机、SDK或真实账号上通过。历史930联合测量在文末单独列明。

## 本机入口

先启动包含931控制入口及匹配六资产的App，取得当前NativeHost发布的loopback端口和launchToken。若通过本机hdc端口转发访问手机，先按本机已核的转发方法建立通道，再把转发后的宿主IPv4 loopback地址传给脚本。脚本不执行hdc，也不猜测手机内部端口。旧930端点仍可使用原默认测量；缺少的新字段归为未知/未提供，不能用旧端点声称完成931恢复验证。

把launchToken用本机安全方式写入普通文件；文件可以有一个末尾换行。不要把token值放进CLI参数或shell历史。下列命令中的端口和路径均需换成本机实际值，`--out`必须是尚不存在的目录。

```sh
chmod 600 /secure/current-launch-token.txt

node tooling/ohos/linux-device-measure.mjs \
  --base-url http://127.0.0.1:18080 \
  --token-file /secure/current-launch-token.txt \
  --out /measurements/linux-931-local
```

客户端只接受 `http://127.0.0.1:1..65535`，可有一个尾部斜线；不接受localhost、IPv6、用户名、路径、query或其他目标。它按已有 `/?token=...` → 303 / `dsh-auth-*` cookie流程登录，随后只访问精确控制route。不跟随重定向；TCP连接固定为所选loopback端口，宿主代理环境不能改变目的地。token、cookie、显式guest env和完整请求body都不写证据或console。

默认顺序为启用、轮询真实progress/opened、固定工具版本和功能检查、空仓库本地clone、受控长任务取消、最终shutdown。只有状态中的真实退休条件成立才记 `shutdownConfirmed:true`；客户端不调用nativeStop，不把HTTP成功、202、断连或Node退出当作native joined。 当前普通 off 会进入最终 shutdown/join；取消后的 `stopped` 只有满足同一 `retirementConfirmed` 条件才接受，随后显式 shutdown 复核同 owner 的完成状态。旧服务的 `disabled` 仍只表示取消后关闭 admission，最后仍必须确认真实退休；不能把这个兼容分支用作 join 证明。

## 显式代理配置

`--proxy-file` 读取当前用户私有的普通JSON文件，拒绝符号链接和组/其他用户可读写的模式；建议0600。只接受 `{mode,httpProxy?,httpsProxy?,noProxy?}`，不读取宿主代理变量来替代它。`mode` 是 `inherit`、`direct` 或 `manual`；前两种只允许mode。manual至少提供一个HTTP(S) URL，各字符串不超过4096字节，httpsProxy缺省时由生产端回落httpProxy。URL地址、客体loopback映射和显式env冲突由生产端验证。

本机自行准备私有文件；其中代理URL从手机App及其Linux客体的网络位置解释。`127.0.0.1`或`localhost`表示手机上的App宿主端，会由生产端映射为客体的`10.0.2.2`，并不表示运行此测量CLI的电脑。若代理只在电脑监听，应先建立并实际核实手机到该代理的可达通道；控制API的hdc端口转发本身不提供这条代理通道。以下示例假定HTTP代理已经在手机宿主loopback相应端口可达，且不含凭据：

```json
{"mode":"manual","httpProxy":"http://127.0.0.1:7890","noProxy":"gitee.com,repo.huaweicloud.com"}
```

```sh
chmod 600 /secure/linux-proxy.json
node tooling/ohos/linux-device-measure.mjs \
  --base-url http://127.0.0.1:18080 \
  --token-file /secure/current-launch-token.txt \
  --proxy-file /secure/linux-proxy.json \
  --clone-url https://github.com/octocat/Hello-World.git \
  --out /measurements/linux-931-proxy
```

CLI先检查当前实例/作业归属，再以原instanceId/attemptId发送 `setProxy`。规范化相同设置的重试由服务去重，不能仅凭revision变化猜测该设置是自己的。设置仅影响后续新requestId；已经接受的作业重试保持原号原参数。代理配置只在当前Node/App会话中，第二次App进程需要时再次传同一私有文件。脚本不把URL、noProxy原串、配置摘要、文件路径或凭据写进日志与证据；异常只输出安全错误码。

生产端的HTTP loopback代理映射与普通远程HTTP(S)代理是不同边界。不要自行将HTTPS代理的localhost主机改成IP来绕过证书名称，也不要关闭TLS验证。国内源是否直连由生产端的NO_PROXY规则决定，实际远程连通性仍以当前手机作业结果为准。

**只要本轮提供proxy-file或任何env-file、观察到proxy状态的httpConfigured/httpsConfigured为true，或观察到尚未获得本CLI同号同参202确认的job，本轮全部后续job输出原件都不落盘。** 最后一种包括首次GET的历史job、observe-only观察到的job、异主竞态，以及发送后丢响应、仅GET看到了同号但尚未确认归属的job。当前已切direct不能证明旧job没有使用代理。这项设置在本轮内不会因后来切换direct或收到202而解除。程序仍在内存中做版本、内容和witness校验；证据只保存输出的字节计数、截断位置和 `OUTPUT_OMITTED_PRIVACY`，不保存原bytes、base64或输出hash。这是主动省略原件，不是“原件已脱敏”，也不能声称拥有完整字节证据。首次无job、无敏感配置且正常收到202的默认测量仍保存原始tail。

## 两次 App 进程的持久恢复测量

这两个选项互斥：`--write-witness` 和 `--resume-from PREVIOUS_SUMMARY`。`--observe-only` 不能与它们或proxy-file合用，不会发送配置或写盘操作。

### 第一次：新安装的931实例，写入后正常关闭

使用干净的931 Linux实例，尚未在本App进程开启Linux，也没有下面的固定见证文件。脚本要求初始未创建owner/attempt，开启后必须是 `bootMode:install`，才会执行固定helper的write命令。

```sh
node tooling/ohos/linux-device-measure.mjs \
  --base-url http://127.0.0.1:18080 \
  --token-file /secure/first-launch-token.txt \
  --write-witness \
  --out /measurements/linux-931-first
```

写入固定的 `/workspace/931-persistence.bin`（1 MiB）和 `/workspace/.config/dsh931/settings.json`。原helper使用 `O_EXCL | O_NOFOLLOW`，配置目录也不允许已存在；已有路径会失败，**不会覆盖或为了让测试通过而自动删除后重写**。失败可能留下本轮已经创建的部分见证，不能在同一实例反复运行write去猜测结果。开始新测量前由本机明确选择新的干净实例；CLI不清App数据、不删除已安装用户数据。

write作业不手动sync；正常关闭必须由生产guest发送本epoch的 `rootfsSync:true / syncMethod:syncfs / syncScope:rootfs`，实际native join与持久clean提交也必须确认。第一份SUMMARY应有 `witness.phase:write`、`witnessCleanCheckpoint:true`，并保留最终 `retirement.cleanCheckpoint:true` 和guestClose。`shutdownConfirmed:true` 单独不足以作为恢复输入。

### 第二次：实际结束并重开整个App，读取同一份数据

第一次完成后，本机实际force-stop并重新启动整个App，重新取得当前token和端口，重新建立需要的hdc转发。脚本不替本机执行进程关闭，不把Node线程重启当成整个App进程已重启。第二段**不再传write-witness**：

```sh
node tooling/ohos/linux-device-measure.mjs \
  --base-url http://127.0.0.1:18080 \
  --token-file /secure/second-launch-token.txt \
  --resume-from /measurements/linux-931-first/SUMMARY.json \
  --out /measurements/linux-931-resume
```

如需代理，两段都可以另加 `--proxy-file /secure/linux-proxy.json`，并接受输出原件省略的保密规则。默认版本、工具、取消和关闭检查仍会执行。

第二段先读前次SUMMARY，核前次实际clean及write见证；没有clean时，在任何HTTP操作前失败。随后要求新的instanceId、同一个persistentInstanceId、`bootMode:resume`，执行原helper的read命令，校验数据/config字节与SHA、UID/GID/模式、inode/mtime和实际root挂载范围。helper的read分支不写见证文件。第二次关闭还必须有新epoch的同步closed和clean；全部成立才给 `resumeConfirmed:true`。同一App身份、不同持久UUID、重新安装、文件被替换、缺clean或复用旧关闭epoch都不能通过。

`witness` 只保存经过验证的固定字段投影；`witnessComparison` 是两份见证的比较结果，前次文件只记录摘要SHA和身份，不记录其宿主路径。当前helper同时核实际agent/init源码SHA；资产可因ext4 UUID/时间而有不同自洽字节，不能因此跳过guest源码核验。这套结果验证正常关闭后的同盘恢复，不宣称突然掉电耐久性、任意旧内核写回错误都能观察，或仅凭客户端instanceId独立鉴定手机OS进程身份。

## 两个显式外部读取选项

### 小型HTTPS远程仓库clone

```sh
node tooling/ohos/linux-device-measure.mjs \
  --base-url http://127.0.0.1:18080 \
  --token-file /secure/current-launch-token.txt \
  --clone-url https://HOST/OWNER/SMALL-REPOSITORY.git \
  --out /measurements/linux-930-network
```

`--clone-url`仅允许HTTPS，无userinfo、query、fragment或控制字符。URL作为一个独立 `git clone` argv传给guest，绝不拼进shell。实际命令使用 `--depth 1 --single-branch --no-tags`，随后另跑 `git rev-parse --verify HEAD`，区分clone退出0与确实取得非空历史。失败不换目录重试，不伪造成功或删除无法确认的部分结果。此分支没有自动配置私有仓库凭据；本机宜先选一个小的、明确可读取的仓库。

### 读取已有PR

必须同时给 `--gh-pr-list`、`--gh-repo OWNER/REPOSITORY` 和 `--env-file`。仅提供env文件不启用账号操作。JSON文件是平的环境键→字符串映射，例如本机自行填写的 `GH_TOKEN`，必要时可有 `GH_HOST`。它只转发到 `gh pr list`，不会自动继承宿主进程的凭据，也不会转发到版本、rg或clone检查。

```sh
chmod 600 /secure/guest-gh-env.json

node tooling/ohos/linux-device-measure.mjs \
  --base-url http://127.0.0.1:18080 \
  --token-file /secure/current-launch-token.txt \
  --clone-url https://HOST/OWNER/SMALL-REPOSITORY.git \
  --gh-pr-list --gh-repo OWNER/REPOSITORY \
  --env-file /secure/guest-gh-env.json \
  --out /measurements/linux-930-account
```

实际只调用 `gh pr list --repo ... --limit 5 --json number,state,title,url`。空JSON数组可以是成功读取“没有打开的PR”；鉴权、网络或仓库失败按真实非零结果保留。没有创建commit、commit-tree、tag、push或PR。根AGENTS的Git限制同样适用于测试仓库。

## 固定输入与预期观察

| 检查 | 本轮锁定工具/预期 | 能证明的范围 |
|---|---|---|
| `gh --version` | github-cli 2.97.0-r2；首行 `gh version 2.97.0 (2026-10-14)` | 当前guest实际CLI版本，不是账号或联网成功 |
| `python3 -c 'print(1)'` | stdout字节恰 `1\n`；Python版本另核 `Python 3.14.10`，APK 3.14.10-r1 | guest解释器，不是App native CPython 3.14.7 |
| `rg --version`、stdin搜索 | ripgrep 15.1.0-r0；输入两行，stdout恰 `2:beta needle\n` | 真实guest rg、batch stdin和双流输出 |
| `git --version` | git 2.54.0-r0；`git version 2.54.0` | guest git实际版本 |
| 默认小仓库clone | 新建空bare，`file://` clone，核工作树、remote和无HEAD；`DSH_EMPTY_CLONE_OK\n` | 本地git及空仓库流程；不声称公网或非空对象传输 |
| 可选远程clone | clone退出0，HEAD为实际40或64位十六进制对象ID | 所选远程仓库与非空历史读取；不外推所有网络/账号 |
| 可选PR读取 | 真实退出0及JSON数组 | 所给仓库/凭据在此时的读取，不是创建/修改PR |
| 取消 | Python先产出 `DSH_CANCEL_READY\n`，然后sleep；off后观察cancelRequested、settled和真实outcome | 只测协作取消/服务观察，不把发送取消当完成 |
| shutdown | resourcesRetired=true，native存在时joined严格true且retirementError严格false | 本次控制服务的资源退休事实，不证明全部VM设备堆或持久化完成 |
| 可选两段witness | 首次install写入/clean；新App同持久UUID以resume读取/比较，再次clean且epoch不同 | 当前版本的正常关闭恢复链；与默认native退休检查分别成立 |

默认本地clone在guest私有 `/workspace/dsh-measure-<随机UUID>`；可选远程clone在 `/workspace/dsh-remote-<随机UUID>`。每轮使用新目录，保留供本机检查；不会覆盖既有仓库。只有首次资产安装已把私有workspace正确交给UID/GID60081后，写入检查才应成功；不能改cwd到/tmp掩盖初始化缺陷。

## 时间、二进制tail与结局

输出目录权限0700，证据文件0600：

- `SUMMARY.json`：版本、请求范围、每项固定requestId、是否收到202去重确认、客户端观察耗时、真实outcome、取消与最终退休事实；可选持久见证/比较、clean和内存释放策略。没有环境值或请求body。
- `events.jsonl`：UTC时间、相对单调纳秒、HTTP阶段/状态/长度、progress及完整白名单状态投影。
- 没有触发保密省略时，`jobs/<id>/stdout-*.bin`、`stderr-*.bin` 保存收到的原始二进制尾部，不经UTF-8替换。每次字节改变保存新快照；相同字节可以复用先前文件。触发省略后不保存这些文件及输出hash。

实际保存的tail引用有SHA256、totalBytes、retainedBytes、truncated和startOffset。省略的输出只有 `outputWithheld:true / reason:OUTPUT_OMITTED_PRIVACY` 及计数/截断位置，没有file、data、bytes或sha256。服务只保留每流16,384字节尾部，因此保存下来的文件也不是承诺完整stdout/stderr的拼接日志；不得把重叠快照直接串接。所有计时是客户端发送/采样观察，包含HTTP和轮询间隔，不冒称guest内部精确启动时间。GET读取不是新的guest ACK。

网络失败后，run请求先查询同instance/attempt，再只重发原有requestId和完全相同的序列化body，最多3次。仅GET看到同一个数字ID不足以证明是本客户端请求：必须拿到同号同参的202去重确认。不会自行使用nextRequestId重做副作用。instance/attempt变化会拒绝继续，也不会shutdown替代实例。初始已有未结局job时只保留观察，不接管或停止它。

**测量必须有独占控制窗口。** 开始前暂停其他App控制入口或测量客户端。初始无job只是一次观察，不构成排他租约；本协议的off/shutdown作用于整个owner。客户端在每次off/shutdown发送前重新GET，仅当当前job属于本次已获202确认的ID集合（或没有job）才继续。发现其他job时不发送off/shutdown，记录 `shutdownStatus:UNCONFIRMED_FOREIGN_JOB`、`shutdownConfirmed:false`，保留观察，不接管。run还同时要求enabled、guestOpened、state=enabled和admission成立，矛盾的unknown/admission不能授权运行。检查GET与后续POST之间仍非原子；现协议没有expectedJobId条件或排他lease，因此不能声称任意跨客户端竞态都不会影响他人的任务。

UNKNOWN保留outcome=null；UNKNOWN的历史作业可以与后来确认的native退休同时存在。`filesRemoved:false`、`dataRetained:true`与资源已退役可以同时成立。默认模式只核原native退休；两段witness模式另核同步closed、持久clean和恢复，不混为一个布尔。

`job.diagnostic` 是stderr所报告的DNS/连接/TLS中断/证书类别或unknown，中文按固定枚举重建，不透传服务端任意message。它只允许已settled、未取消、非signal的普通非零退出；不改变原exitCode/signal/cancelled，也不能证明是谁中断网络。`nativeMemoryRelease:'process-exit'` 表示保留的VM原生对象仍须整个App进程退出后回收。当前普通off也走最终shutdown/join，同一App进程不能再启该VM；受控join后主RAM内部整页可以执行advice，但join不等于全部heap释放，advised字节也不等于实际RSS/PSS回收。null或旧v1缺字段表示没有这个事实，绝不等于零内存或已释放；CLI不从PSS差值估算VM字节数。

退出0可能是 `PASS_LOCAL_ONLY`、只启用一个外部选项的 `PASS_PARTIAL_SCOPE`、两选项都启用的 `PASS_SCOPED`，或只读取状态的 `OBSERVED_ONLY`；必须结合逐项NOT_RUN和scope读取。真实内容/退出码不符为FAIL、退出1。未确认、UNKNOWN、协议/网络错误为INCOMPLETE/UNKNOWN、退出2；收到SIGINT/SIGTERM后仍尝试同owner收尾，退出130。客户端或网络/存储中断不是资源已回收的证明，不要重新跑整套命令去猜结果。

只读后续状态可以使用一个新的输出目录：

```sh
node tooling/ohos/linux-device-measure.mjs \
  --base-url http://127.0.0.1:18080 \
  --token-file /secure/current-launch-token.txt \
  --observe-only --out /measurements/linux-930-observe
```

默认每250ms轮询，单HTTP请求5s，安装观察10分钟，每job观察2分钟，shutdown观察3分钟。可用 `--poll-ms`、`--request-timeout-ms`、`--install-timeout-ms`、`--job-timeout-ms`、`--shutdown-timeout-ms` 调整有界窗口。到期只标“未确认/观察超时”，作业超时会请求off并观察真实取消；没有补造完成状态。

## 已做与未做

宿主定向测试：`node --test tooling/ohos/tests/linux-device-measure.test.mjs`，仍登记统一门 `linux-device-measure`。原12项场景延续；其中精确非UTF8 tail断言移至本CLI已202确认的job，历史job只读观察按新保密合同改为省略。新增14项覆盖931字段、代理幂等重试、sticky输出省略、env-file保密、历史代理job与失响应、proxy矛盾值拒绝、配置前异主job、两CLI进程的write/read协议、clean/identity/epoch拒绝、固定见证不得覆盖及只读参数约束，原26项的历史通过范围不变。1289另加普通off已真实报告退休与join未确认两项兼容检查；最终结果以该版本的实际执行记录为准。HTTP控制服务和guest输出是显式替身；两CLI进程不是两台或两次真实guest。测试不调用git/gh、不运行VM、不登录账号，不能替代本机执行上面的命令。此前decoder丢失931持久UUID，以及后续独审发现的proxy无效值接受、历史代理输出落盘反例，均已用实际调用先红后绿。

历史930另以CLI SHA256 `72bd2e4840e84a2415822cc736206132b49113368364798aa5e455a995a987c5` 接真实BrowserAuth/HTTP/control/owner/backend/native/guest，默认套件8项PASS、2项显式NOT_RUN，整体66.643秒。测得本表锁定版本、stdin搜索、空库clone及取消；实际结局为cancelled=true、requestedSignal=SIGTERM、signal=SIGKILL。生产端在harness后续清理前已核native joined、数据FD为0和发布盘保留，与CLI的shutdownConfirmed一致。该流程仅下载传输使用已核本地归档替身，不证明华为源网络、手机、SDK、远程clone或账号。原始SUMMARY SHA256 `667e090c67db50e39a379c06eab18145b17431e4139f9c422d87d38b765aa915`，完整producer与CLI证据随930交付归档提供。它是旧版历史结果，不能替代本次931新增代理与两App测量路径的最终组合验证和手机复跑。
