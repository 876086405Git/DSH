# O4 工作区快照：真实 App 回合验收夹具

本文件与 `workspace-round-fixture.mjs` 只用于测试，不进入移动 profile 或产品装配。它复用已冻结 O0b 的 `round.mjs` 和假模型，不改变 write/edit/read/grep/bash 的五步请求。

fixture 只接受显式 `confirmEmptyTestWorkspace: true`，而且要求引擎启动 cwd 是新空目录。它用已批准且锁定的 isomorphic-git 1.44.9 初始化测试仓库，写入三个被跟踪的初始文件和一个被忽略的文件。第一个工具结果出现后，测试夹具直接修改“仅快照可见.txt”，并把提前在工作区外建好、已有提交的嵌套仓库同步移入被忽略的 `ignored-nested/`。两次变化没有经过 DSH 的 fs/write-intent，故只靠文件工具的退化记录无法发现前者，也不能验证后者是否错误进入快照。

固定 DSH 的 `agent/turn-stopping` 通过串行 dispatch 逐个等待回调。fixture 注入 workspaceChanges 后才注册自己的回调，因此原插件的回合结束快照先完成。随后测试要求：

* summary 有不同的 before/after Git tree ID；
* 中文模型文件和夹具的外部改动都在摘要里；被忽略及未改动文件不在，基线之后进入的忽略嵌套仓库也不在；
* 外部改动的生产 diff 包含 before/after 文本；
* 外层和内层 `.git` 内每个文件的内容摘要和文件集合不变，覆盖用户 index、objects、refs；
* 再经过真实 token→Cookie 认证，调用客户端现有 `/api/changes.summary` 与 `/api/changes.diff`，返回内容与生产服务相同。

断言发生在原回合的停止钩子中；失败会使未修改的 O0b 驱动器把本轮记为 BLOCKED。报告在回合结束前写完，没有靠 sleep 或终止后抢读内存记录。一个新工作区只跑一轮，输出报告必须不存在。

## 运行

需要原 O0b，固定 DSH prefix，以及 O4 的固定 isomorphic-git 安装目录；fixture 按相对位置从 `runtime/ohos/process/package.json` 解析依赖。报告路径在工作区之外。

生成一个 JSON（同时也是有效 YAML）overlay：

```json
[
  {
    "insert": [
      {
        "id": "ohos-workspace-test-fixture",
        "name": "file:///absolute/repository/runtime/tests/ohos/workspace-round-fixture.mjs",
        "config": {
          "confirmEmptyTestWorkspace": true,
          "output": "/absolute/new-workspace-summary.json"
        }
      }
    ]
  }
]
```

先校准未替换的 JIT / native git 路径：

```sh
node runtime/ohos/sim/round.mjs --prefix /absolute/prefix --out /absolute/new-jit-case \
  --mode jit --patch /absolute/workspace-fixture.patch.yml
```

再叠加实际受限 subprocess/sandbox profile、唯一产品 preload 和严格 O0。本次使用精确 allowlist 的 require-builtin addon 与 Linux linked-publication fixture：

```sh
node runtime/ohos/sim/round.mjs --prefix /absolute/prefix --out /absolute/new-sim-case \
  --mode sim --platform --import /absolute/repository/runtime/ohos/preload.mjs \
  --patch /absolute/mobile.patch.yml --patch /absolute/workspace-fixture.patch.yml \
  --allow-addon /absolute/prefix/node_modules/node-addon-require-builtin-openharmony-x64/prebuilt/openharmony-x64-napi-v9.node \
  --linked-publication-fixture /absolute/libpublication-test-linked.so
```

这里不开放 `--expose-internals`，不关闭 addon allowlist；linked fixture 仅是 Linux 测试构件，不是设备 ABI 的证据。两个样本必须用不同的 case 和报告路径，mobile profile 的 workspaceRoots 必须准确指向新 case 的 workspace。父驱动器保留创建子进程的测试能力，严格约束加在被测引擎；不能把父驱动器套进 O0 后再宣称原 git 基线失败。

## 已取得的前后证据

历史 O4a v1 没有 git，其严格仿真得到 `repository baseline snapshot is required`；summary 只有模型文件、没有外部改动，也没有 snapshot 字段，O0b 正确记为 BLOCKED。原 JIT/native git 的历史正对照通过过同一完整五工具、两次审批和上述快照/HTTP/元数据断言。

本次 O4b 在固定 DSH 0.2.1-rc.4、Node 24.22.1 严格通道上重新执行：五工具、两审批、真实外部改动快照、认证 HTTP summary/diff 和原仓库元数据不变全部通过。作者完整报告在该精确补丁交付包的 `strict-round/` 和 `workspace-summary-strict.json`；最终是否通过以对应 SHA 的独立复核为准。该结果不意味着所有 Git CLI 语义等价，也不覆盖 OpenHarmony 真机。

v2 继续用同一新增夹具分别接未改的 v1 和修订实现：v1 的真实 summary 多出 `ignored-nested`、回合记为 BLOCKED；v2 的 summary 只含模型文件及外部正常修改，五工具/两审批和认证 HTTP 对照全部 PASS。前后报告、完整 argv 与 profile 另存于 v2 交付，不覆盖 v1 独审失败或旧通过记录。

这是普通仓库的单轮端到端验收。未合并索引、私有对象库的备选读取、工作树链接、子模块、重命名和二进制计数另由 Git 子项的对照测试覆盖；本文件不把这些尚未执行的情况算入通过。
