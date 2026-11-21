# H02｜固定找稿 Host：实际范围与复跑

依赖完整 G04 → H01-r3；H01-r1/r2 为保留历史，不叠加。H02 仍须 H03 SDK、H04 手机入口及整组验收。
依据规格 09o 的固定 `host.find_draft` 动作与共同持久、原对象、预算和来源打开要求。

## 请求与有限执行

沿已有真实配对 owner admission、`/dsh-go/v1/companion/tasks`、单个 `companion_tasks` Domain/JSON aggregate。
不新增持久仓、模型工具、通用任务框架或任意路径执行。新增 kind 严格接受六个 args：
`folderRef/scope:currentLevel/localDate/timeZone/dateBy:modified/extensions`；格式是非空去重 md/txt 子集。
日期以首次受理时的 Temporal 当地日固定半开范围，精确原 create 重放不重新算时区。

创建显式 kind；H amend/cancel 也显式 kind。旧 F 操作省略 kind 的原 JSON 不添默认字段，
因此原操作指纹不变。kind 在原任务和先到改撤屏障均不可换；先改后到 create 只运行当前完整约定，
先撤后到 create 不启动原查找。H done/partial 可明确改约新 rev；cancelled 不能用 amend 复活。

production `mountCompanionTasks` 在同一服务按 kind 分派。H 只取得实际 fs，不调用 Agent、Session、
模型、批准卡或 F 的出版接点。已有 F 执行 owner 和写批准语义保留。能力只在真实 find runner、
Domain 及 Linux anchored FS 接点可用时公布 H/sourceRead。未知插件的额外读审批不在此承诺内。

`afterExit:continue` 可运行；共同 pause 仍等待 `foreground_control_unavailable`，无列举/核读/模型工作。
这不是已闭合的前台执行与离页暂停能力。累计预算仍为同单 300000ms 的 spent+held，改约及重开不清零。
每次新增文件 IO 前核原修订、改撤、截止和剩余 claim；一次受控墙钟前跳也会阻止下一个 IO。

## 持久边界和恢复

只有 `selectInputs`、`readInputs` 两个固定步骤。扫描使用 H01 的最多200项/20候选接点；
第201项和第21候选只证明截断。每个入选对象先保存 sourceRef、原目录 identity、版本、metadata，
正文核读上限完整64KiB。正文只短暂用于确认原版本可读；不参与搜索、不进模型、不入任务持久文件。

`finishFindSelection` 的一次 aggregate put 同存扫描选择、结算 select 及创建 read claim。
若扫描返回后原约定已改撤或到期，read claim 的 reserve 为0，只能收束观察，不能新增 IO。
这消除“已取得扫描但尚未认领核读，重启后被终态过滤掉”的间隙。

`finishFind` 的一次 aggregate put 同存私有来源登记、公共报告、read 步完成、合法当前头及 receipt 序号。
公共报告仅在 `readInputs.result.completion`，含 scope/coverage/matches，不造 artifact 或第二顶层结果。
原报告随完整历史快照保留；迟到旧 rev 的真实观察不把新头改回 done。全范围核得且每个候选可读为 done；
真实零匹配也可 done；截断、范围缺口或任一不能打开为 partial。根目录未开始则具体失败，不伪造空查全。

重启时：未保存 scan 的未结算 select 只记 unknown/scan_interrupted，不自动重列；
已保存 scan 的未结算 read 只用原 metadata 形成 partial/verification_interrupted，不自动再读取或加入新文件。
若原 scan 已完整且零候选，不需要任何正文核读，可纯持久证据收束为 done。
未知旧段时长用 elapsed=null，保留原 held，不把重启当预算退款。原 create 重放和 GET 都不让已知中断扫描重跑。

## 原来源只读打开

`GET /tasks/{taskId}/sources/{sourceRef}?hostStoreId=原库&hostExecutionId=原执行号`
仅接受这两个查询身份，拒绝重复参数及 path/folder/name。IO前校验实际 owner、库、任务、执行号和已登记 sourceRef。
只按原目录 identity、原文件 version 重读完整64KiB；已有成功核验 digest 还须一致。
原先未核读成功的来源没有伪造历史 digest；用户显式打开仍只能核同一原版本。

回执 available/missing/changed/not_readable/unknown；只有 available 含当前原版本正文。
缺失或变动不以同名新稿替代，不私藏全文来冒充仍可打开；GET不重扫、不唤醒runner、不推进任务水位或修订。
旧 rev/已撤/已到期任务的来源仍可按当前实际权限作这一有界只读查询。

## 已执行证据

同一组27个H用例与89个既有F回归，共116项，在严格锁定 Android/OHOS **JS源码变体**上分别于Linux实际执行，
各116 PASS、0skip。两目标和早期21/27子集不叠加为不同用例。H01自身同46项的已签证据独立保留。
源准备逐包核原SHA及依赖tree SHA，只复制已存在锁定源码；无下载/安装/完整engine启动。

H覆盖 actual Domain/JSON/PID锁/Node文件IO/loopback HTTP、真正只读 Sandbox、完整source打开、199/200边界的H01链，
本片21候选和201项报告、OS EACCES、64KiB/二进制/UTF8、同size/mtime对象替换、改撤竞态、零匹配、
跨纽约25小时日的各mtime实际offset、原报告保留、累计预算，以及真实close/reopen后的持久状态恢复。
H恢复测试由明确保存的claim/checkpoint再关闭重开构造，不冒称在每个机器指令位置做了断电试验。
report提交前故障、挂起读边界、墙钟与耗尽预算是标明的受控故障/状态；目录、文件、权限和存储读写是真实的。
production mount 函数确实执行；Cordis inject/provide/lifecycle 是显式测试peer，不是完整框架启动。
旧F中的固定模型/loopback响应为受控peer，没有付费真实模型调用。

本次执行 uid/gid1000；H联合权限案例要求Linux非root身份。JSON statfs capability 在CI overlay上注入本地支持值，
只是运行真实持久分支的受控前提，不证明该overlay本身获生产持久支持；H的读取不调用F出版statfs证明。
完整Cordis/AgentLoop、Dart、Flutter、Android/OHOS原生、真实设备与端到端手机入口均NOT_RUN。

在已经正确补丁化的锁定 prefix 上：

```sh
python runtime/tests/fixtures/prepare-companion-task-source.py \
  --node-modules "$DSH_PREFIX/node_modules" --target android --out "$PWD/.find-source"
COMPANION_TASK_HARNESS="$PWD/.find-source" DSH_FS_NOTES_SOURCE="$DSH_PREFIX/node_modules/@deepseek-ai" \
  node --test runtime/tests/companion-find-runner-source.test.mjs \
  runtime/tests/companion-task-store-source.test.mjs runtime/tests/companion-task-execution-source.test.mjs \
  runtime/tests/companion-task-http.test.mjs runtime/tests/companion-notes-content.test.mjs \
  runtime/tests/companion-notes-runner.test.mjs runtime/tests/companion-notes-model-source.test.mjs
```

OHOS变体须使用其对应prefix与 `--target ohos`。源码缺失或pin不匹配必须失败，不能静默skip。
原CI已运行 `runtime/tests/*.test.mjs`，无新增工作流。实际wire fixture由本测试HTTP产生，随冻结证据保存。

## 回退

先停手机新接单，再按H组逆序回退。H01/H02本身不修改用户稿件、不新建输出文件；
已经受理的Host aggregate、原source登记、旧报告与预算属于历史数据，不因回退删除。
较旧仅F的schema不能读取含H kind的新数据：保留新store备份并使用前向兼容版本查询，
不能把回退代码能启动误当成新任务数据可被旧版本解释。不要删库来“修复”这个有界格式扩展。
