# M5-2：保留已审 Android recipe 身份

## 结论与适用输入

追加8所说的版本后缀变化会触发已有本机运行环境的重新安装。`RuntimeInstaller.isCurrent()` 直接比较已安装 `rootfs.version` 与资产 manifest 的完整 `runtimeVersion`；不等时 `RuntimeController.install()` 调用安装器，重新校验整包、解压到 staging、激活并写新版本。已有 installedVersion、没有选择放弃本机的用户在正常启动流程中会自动进入这条升级路径。

依据为 c0949d6 的 `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/RuntimeInstaller.kt:35–45,70–101`、`RuntimeController.kt:108–114,180–194`，以及 `app/lib/ui/shell/root_gate.dart:49–83,330–348`、`app/lib/ui/onboarding/runtime_setup_page.dart:87–104`。完整13文件调用链和 SHA256 在本项交付证据 `source-chain.json`、`M5-2-android-reinstall-source.md`。没有改 Android、Flutter、direct 或 bridge 源码，也没有运行 Android 安装器。约750MB来自追加8，本次没有测量该数值。

本补丁接 M4-7 的显式目标目录与 M5-1 的 required `--target`。版本锁定 DSH `0.2.1-rc.4`；只在本批精确已审的源码上保留 afb5cdd recipe 身份。DSH Android 选择集为既有11个公共 diff。M4-7、M5-1 的实际树对照覆盖30,444路径、26,871普通文件，字节及模式一致；那份测量用于证明补丁选择的等价性。这里另外验证 recipe 自身，不能用前一结论代替后一结论。

## 为什么单独筛选 diff 不够

afb5cdd 的 recipe 是一串带换行的输入，经 SHA256 后取前12位。除了归档摘要、锁文件和构建变量，还含：

1. `build-runtime.sh` 全文摘要；
2. `lib/rtbuild.py` 全文摘要；
3. `find patches bridge boot direct -type f` 按 `LC_ALL=C` 排序后，`sha256sum` 输出的“摘要、双空格、相对路径、换行”。其中 pins.json 是当时完整原文。

M4-7 改动了两个脚本、pins 结构和补丁目录，还把原逐路径流换成聚合 `inputSha256`。即使选中的11个 diff 完全相同，直接使用这些新字节也不可能得到旧输入流。本次先运行两个实际脚本中的完整 hash 块，已经复现此差异。

## 实现：有限的源码兼容映射

`runtime/lib/android_recipe.py` 负责输出 recipe 的源码部分；构建变量、下载归档及两个 npm 锁文件仍由原 shell 代码计算。helper 调用同一个 `rtbuild.select_dsh_patches(..., "android")`，继承完整目标目录校验，不通过文件名前缀猜测目标。

`runtime/locks/android-recipe-compat.json` 是本批审核依据，记录：

| 输入 | 当前已审 SHA256 | recipe 中采用的 afb5cdd 身份 |
| --- | --- | --- |
| build-runtime.sh | `790b434704a39632a123d66756c60c150c14ebe088db25945d7004a8532ce3b1` | `4f6147d742217ce3c749925220805f1769eeca23ac60c5f9f8df5370f927ad43` |
| rtbuild.py，含 M5-1 | `f527d91b56e108305ec84de512db67fbb64060cf60f39727596490b020b6dc5a` | `235370e7cfd7173a34cd71a348a909b083cc49d118e5ac8ed27a298d6aa821aa` |
| 当前版本的 Android pins，规范序列化 | `cb782f6be753fb693ad5901ffec39e126574e8007045e171e2527ae0ac69d1c8` | 旧 pins 原文 `34db3fa0ce38e9eeb865c2de2a9e82e3db7b47390c50bd82fc3857cc182fa508` |

这几个旧摘要是版本身份的兼容别名。实际源文件的完整性检查必须使用表中当前摘要或交付 manifest，不能拿输出的旧身份去验证当前文件。

映射的条件是完整 SHA256 精确相等。某个脚本有任何未经登记的新字节，该项立即使用实际新摘要。因此真正修改 Android 构建或打补丁代码会更新 recipe。新 helper 自身也有精确摘要；它发生未登记修改时，额外加入 helper 的实际摘要和路径。映射表放在独立文件，避免脚本保存自身摘要造成循环依赖。

选中 diff 始终散列当前真实字节。pins 只取实际 Android 集合中、实际 DSH 版本的记录，按键排序并用固定 JSON 分隔符计算语义摘要；其值等于已审基线才映射到旧 pins 原文字节的摘要。有效 Android pins 变化会更新 recipe；OHOS-only pins、未使用 DSH 版本的 pins、JSON 空白和对象键顺序不改变当前 Android 身份。

bridge、boot、direct 仍逐个散列实际普通文件。所有路径用字节序排序，GNU sha256sum 自己处理路径转义，保留旧流的路径文本、双空格和换行。新 TARGETS 说明及 OHOS-only diff 没有进入 Android recipe。

另一个真实输入是 `runtime/session-deletion/core.mjs`：patch-dsh 会把它复制进 DSH，但 afb 的 find 范围漏掉了它。当前字节等于旧基线时不增加旧流；一旦它发生变化，即加入实际摘要与路径，使后缀更新。它没有被当作永久不变的外部常量。

### 后续维护约束

新增 OHOS-only diff 或修改其 pins 不需要更新映射。将来改变两个共享构建脚本时，默认会使 Android 后缀变化。只有重新证明 Android 实际输出不变并独立复核具体新源码，才可以增加或替换精确已审映射。**不得为了让等值测试变绿，自动把未知源码摘要写进白名单。** 有意升级 Android 输入时保留新后缀，并相应更新这份迁移专用回归的预期。

映射表中影响运算的字段也有实际变更测试：源当前摘要、旧摘要、helper 摘要、pins 两个摘要、companion 摘要任一被改，均能改变当前输出。schema、baseline、target 是审核说明字段；实际目标在 helper 调用中固定为 android。代码没有尝试从源码文本推测语义等价。

## 证据与复跑

```sh
python3 -I runtime/tests/ohos/android-recipe-compat.test.py \
  --baseline /absolute/path/to/verified-afb5cdd/runtime \
  --runtime runtime --out /tmp/android-recipe-contract.json

python3 -I -m unittest discover -s runtime/tests -p test_patch_dsh.py -v
```

测试先核 afb5cdd 的两个脚本与 pins 原文 SHA256，再从两个真实脚本提取原 hash 块，在 Bash 内分别运行；另外捕获完整输入流，逐字节比较，最后核捕获流的 SHA256 与实际 shell 输出相同。外部归档采用两边完全相同的小文件夹具，仓库源码和 npm 锁文件使用真实文件。测试没有下载全部 Android 二进制输入或构建 APK/rootfs。

| ABI | afb5cdd 夹具后缀 | 修复前后缀 | 修复后后缀 | 完整流比较 |
| --- | --- | --- | --- | --- |
| x86_64 | `4efe7f0c55cc` | `8f09308b6bee` | `4efe7f0c55cc` | 4,503字节完全相同 |
| arm64-v8a | `9d11b018d2a4` | `925a7a34dab1` | `9d11b018d2a4` | 4,506字节完全相同 |

这两行是夹具重放得到的后缀，不能作为实际发布 APK 的版本号。等值证明还依赖一个可直接检查的事实：原 shell 的共同前半段完全没变。对任意相同的真实归档摘要和构建变量，共同前半段相同；本次验证的源码后半段也与 afb 逐字节相同，因此整个 recipe 流相同。

31项实际用例覆盖：两ABI的完整流与 hash 块；OHOS diff/pins/新增注册、未使用版本、JSON格式；Android diff、active pins、选择集、两个脚本、helper、companion、bridge/boot/direct、两锁文件、Node归档、recipe变量；相关映射字段；未知和重复补丁拒绝；恢复原输入后的重复等值。生产源冻结后复核报告须绑定补丁的完整 SHA256。完整手机解压、APK 构建和实际发布镜像字节比较仍为 NOT_RUN。
