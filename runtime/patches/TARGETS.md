# 按 Android / OHOS 选择 DSH 补丁（M4-7）

## 目的与边界

Android 构建只应用 `targetSets.android` 里的公共补丁，现在是 main-dd130b31 的 149 个，公共 diff 和各版本 pin 对象保持 main 原字节与数值。OHOS 的 181 项先应用这 149 个公共补丁，再应用 32 个 OHOS 专用补丁；平台判断为 false 并不等于 JavaScript 文件字节没有变化，因此不能把所有 diff 一起打进 Android 再依赖运行时判断。

本次恢复的是 **DSH npm 前缀树的文件字节**。构建工具自身、构建报告、时间戳或压缩器可能改变完整 runtime / APK 的字节；本包没有执行 Android APK、arm64 原生 runtime 或 HAP 构建，也不宣称这些整体产物与旧版完全相同。

## 显式集合

`pins.json` 升为 schema 2，保留原 `patches → DSH version → file → before/after` 结构，并新增：

```json
{
  "schema": 2,
  "targetSets": {
    "android": ["明确审核的公共补丁名.diff"],
    "ohos": ["明确审核的公共补丁名.diff", "明确审核的鸿蒙补丁名.diff"]
  },
  "patches": {}
}
```

上述 JSON 仅表示结构，不是实际配置。文件中的两组实际名字才是权威集合。应用顺序只有一个来源：main 的 `series`（每个 `.diff` 恰好一行）。`targetSets` 只决定各目标选哪些补丁，选中的补丁一律按 `series` 的顺序应用；两个数组也按这个顺序书写。`series` 的前段是 main 原样的整条公共链，其后一段注释下是 OH 覆盖，所以 Android 的顺序与 main 逐行相同，OHOS 先完整的 main 链，再添加 OH 覆盖。这样，后续 main 补丁即使按文件名排在旧 OH 补丁之后，也不会被旧 OH 中间状态改变输入摘要；不需要改名或修改公共补丁。OH 覆盖仍按其原有相对顺序排列，其 rc.4 pin 必须从新的公共最终状态重新计算。目标不是从文件名中是否包含 `ohos` 推断的。两个集合的并集必须等于目录中全部 `.diff`：新增未登记文件、声明了不存在的文件、集合中的重复项、缺少目标集合，均在改写前失败。`--record` 也不能自动把未知补丁归入 Android。

`--target` 必须显式指定为 `android` 或 `ohos`，没有默认值（M5-1）。遗漏目标、缺少目标值或填写其他值时，参数解析直接以 exit 2 结束，尚未读取 pins 或修改前缀、pins、输出报告；`--record` 也必须指定目标。正式 `build-runtime.sh` 已显式传 `--target android`，OHOS 的 `measure.sh` 已显式传 `--target ohos`，新增构建/测试脚本必须同样声明目标。历史对照工具运行的是 `afb5cdd` 的旧 patcher 时，保留旧版不支持 `--target` 的调用；这不构成当前 patcher 的默认值。

schema 1 不再用于新的补丁应用或记录。迁移前先为每个现有 diff 明确登记目标；不能通过改默认目标或跳过未登记检查继续执行。新增已审 O4 / 后续 OHOS diff 时，也要同步将其名字加入 OHOS 集合，并更新对应版本 pins；本包的集成附属差分绑定具体已审基底。

## Android 集合是 OHOS 集合的子集

`zzzzzzz-input-recovery.diff` 和 `zzzzzzzz-model-defaults.diff` 曾经不在 `targetSets.ohos`。前者和 `zzzzzzzzzzzzz-ohos-lifecycle.diff` 都改 `dsh-agent-loop`，后者的 before pin 接在前者之后。现在两个都在。每次合 main 后，Android 的完整公共链作为 OH 的公共前缀；与新公共补丁改同一文件的 OH 覆盖 pin 按新链重算，共享 diff 与 main pin 对象不改。

`runtime/tests/input-recovery.test.mjs` 从 agent-loop 里摘几个 region 来跑。鸿蒙的 agent 在领取输入前会调用 region 之外的 `ohosLifecycle()`，所以它要把这个函数一起摘进去，否则是 ReferenceError，而不是输入丢了。

所以打过 Android 补丁的前缀再跑 `--target ohos` 不再被拒绝，它得到的树和全新前缀一样。反过来仍然被拒绝。真实构建都用全新前缀。

## 恢复被混入公共链的 OHOS 条件

O3a 不仅新增鸿蒙文件：它也在公共 `fs-create-exclusive.diff` 中增加了 OHOS 的 `EACCES` 条件，因而改变后续 `zz-direct-runtime.diff` 对 `dsh-fs-local` 的输入和输出摘要。只排除独立 OHOS 文件无法恢复 Android 字节。

M4-7 将公共 fs diff 恢复到 `afb5cdd` 的精确内容，恢复两版 pins（rc.2、rc.4）中的公共链，再以单独的 `zzzzzzz-ohos-fs-exclusive.diff` 添加原来的 OHOS 条件：

| 阶段 | `dsh-fs-local/lib/index.js` 的 SHA256 |
| --- | --- |
| npm 原始文件 | `63fbb41d2c33e07111884b798be507e68c2752acab8249c821c20ade436e894f` |
| 原公共 exclusive-create 之后 | `dc077d91a07374d64900a45bb6288c941094c531237acc6e1994b0bd88deb1d6` |
| 原公共 direct-runtime 之后，即 Android 最终值 | `b275b221acdc4a0ce217b9c552b6ad4a61922874cb9257b618cdf5a560af8dbd` |
| 新后置 OHOS-only 条件之后 | `6848888183b4f25c9a21ba59840c5ea38dfb265e152668051e7fe4873a80e058` |

最后一个值与拆分前的 OHOS 最终文件相同。`zz-direct-runtime.diff` 本体没有改动；恢复的是它的 fs-local 中间 pins。历史 11 个公共 diff、旧 patcher 和 session-deletion companion 的精确来源摘要记录在 `runtime/tests/ohos/android-before-ohos.json`，来自题面提供的 `afb5cdd` ZIP。

以上是历史记录。合入 main-2cd33b59 时，main 的公共 `fs-create-link-denial.diff` 已在所有平台把 `EACCES` 当作硬链接被拒并走排他创建，`zzzzzzz-ohos-fs-exclusive.diff` 的唯一一处改动因此不再需要，已删除。同一次合并里另有两个 OH 覆盖被 main 的公共补丁取代而删除：`ohos-effect-dispose-completion.diff`（与 main 的 `cordis-effect-dispose-completion.diff` 逐字节相同）和 `ohos-discovery-response-cleanup.diff`（main 的 `piai-discovery-response-cancel.diff` 同样取消未读的响应体，并等它结束）。与新公共补丁改同一文件的 OH 覆盖按新链重新生成上下文，OH pins 用 `patch-dsh --target ohos --record` 在全新前缀上重录，公共 pins 仍是 main 的原值。

合入 main-dd130b31 时 main 新增 `deepseek-attachment-error.diff`、`fork-default-effort.diff`、`config-editor-lock-order.diff`、`piai-overflow-output-limit.diff` 四个公共补丁，改的四个文件没有任何 OH 覆盖碰过，所以 32 个 OH 覆盖和它们的 pins 都没动，只把这四个名字按 `series` 顺序加进两个集合。全新前缀上 OHOS 输出与合并前相比只差这四个文件。

## 严格链、幂等和错误目标拒绝

patcher 先选本目标集合，再构造本目标的 before/after 链。它在写入前核实所有选中 diff 的文件列表、版本 pins 和输入状态，且只接受该链明确列出的原始、中间或最终摘要。较长链的已知中间状态也可继续；这允许先有完整公共链，再添加 OHOS 专用补丁。

Android 不接受 OHOS 最终摘要。对被排除的 OHOS diff，如果它触及 Android 集合没有修改的文件，patcher 按 `series` 中的实际应用顺序取得第一个 before 摘要并核对原始文件，防止把已有 OHOS 修改的目录当作 Android 输出而静默保留。错误目标必须换一个干净前缀；工具不自动反向移除某个平台的补丁。

原 `--out` 仍输出补丁名 JSON 数组，以兼容 runtime manifest。新的 `--target-report` 记录目标、选中/排除集合，以及只由选中 patch 字节、该版本 pins 和对应 companion 形成的 `inputSha256`。Android 构建 recipe 使用这个字段代替对整个 patches 目录取摘要；单独修改未选 OHOS 补丁不会改变这一段 Android 输入指纹。构建脚本和 patcher 自身仍保留原有的 recipe 哈希，不能因此推断整个旧 runtime 归档相同。

## 命令与维护

```sh
python3 -I runtime/lib/rtbuild.py patch-dsh \
  --prefix /absolute/pristine-dsh-prefix \
  --dsh-version 0.2.1-rc.4 --target android \
  --out /absolute/android-patches.json \
  --target-report /absolute/android-target.json

python3 -I runtime/lib/rtbuild.py patch-dsh \
  --prefix /absolute/other-pristine-dsh-prefix \
  --dsh-version 0.2.1-rc.4 --target ohos \
  --out /absolute/ohos-patches.json \
  --target-report /absolute/ohos-target.json
```

记录新版本时，先审源码/差分并登记 targetSets，再从相应原始版本的前缀运行 `--record --target ...`。它记录的是明确选中集合，不能拿一棵未知修改状态的树作为新基线。当前完整发行链仍只为 rc.4 配齐；保留的 rc.2 单项 pins 不代表整套 rc.4 功能都支持 rc.2。

## 验证

单元测试沿用原 strict unified-diff 测试，并新增：显式目标选择、三阶段中间状态、跨目标污染拒绝、未登记/缺失/重复集合、缺少后续 pin 时零写入、未选 OHOS 内容不进入 Android 输入指纹。设置 `DSH_FS_LOCAL_ORIGINAL_JS` 可启用真实 npm fs-local 字节用例，避免跳过该门。

```sh
DSH_FS_LOCAL_ORIGINAL_JS=/absolute/pristine-prefix/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js \
  python3 -I -B runtime/tests/test_patch_dsh.py

python3 -B runtime/tests/ohos/target-patches-live.py \
  --pristine-prefix /absolute/locked-npm-ci-prefix \
  --before-ohos-root /absolute/verified-afb5cdd-source \
  --candidate-root /absolute/current-source \
  --legacy-ohos-root /absolute/catalog-before-target-separation \
  --work /absolute/new-comparison-directory
```

真实对照脚本先核 `afb5cdd` 公共源文件身份，从同一个真实 npm-ci 前缀构造硬链接副本，再运行两边真正的 patcher。除逐项 SHA256 清单外，Android 普通文件还实际按块比较内容；目录/文件模式、符号链接目标及路径集合均比较。它也检查幂等、Android→OHOS 的已知链续打、OHOS→Android 的拒绝不写入，以及硬链接共享的原始输入未变。默认清理自己创建的验证前缀，保留清单、日志和 JSON；不扫描或删除调用者其他目录。

两轮作者测量均使用真实 Linux x64 锁定前缀，比较 30,444 个输出路径项、26,871 个普通文件。第一轮使用 c094 的原补丁目录，旧全补丁默认路径产生 5 个 OHOS 文件差异。第二轮加入已冻结的 O4 marker 版虚拟进程和最终 M3-5 网络补丁，旧默认路径产生 7 个差异。两轮拆分后的 Android 路径均与历史 11 个公共补丁无差异，清单摘要均为 `ef9aa66792594a75bb87d4bd3ed3ddeff63d7f3dd5a11cac9d73955168fa1e36`。第二轮拆分后的 OHOS 最终树与对应旧全补丁路径相同，清单摘要为 `602ca61078a1023d10d2c63bbc484f3a65edbc514cac2c84f38c7c7611c6535c`。

上述测量不是 arm64 npm 安装或设备运行；rc.2 的完整发行链也未运行。集成输入、逐项清单、日志、应用顺序和最终独立复核状态以随包验证记录为准。M3-6 的测量驱动后继修改只给原 `patch-dsh` 调用增加 `--target ohos` 与目标报告输出，不改变其三模式回合、白名单、负对照和输出判定。
