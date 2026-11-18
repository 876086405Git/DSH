# M4-5：虚拟 shell 的执行计数上限

## 决定与用户可见行为

本项保留 just-bash 3.6.0 当前默认 `maxCommandCount = 100000`，也不调整其默认 `maxLoopIterations = 100000`。在 OH 的真实 bash 工具说明中明确写出：

> 单次调用的命令执行计数上限为 100000；超过时以退出码 126 结束，已经完成的写入不会回滚。长循环请拆成独立任务，或连接电脑执行。

这是命令执行计数，不是脚本行数，也不保证含 100000 次循环迭代的脚本可以完成：循环体和其它语句共同消耗预算。现有英文 stderr 仍来自上游，未伪装成主机 shell、未把达到上限当作普通成功，也没有让达到上限回滚已有写入。

唯一用户可见生产变化是工具描述。顺便删除同一句中已过时的“rg include / 部分 Unicode 不可用”提示；M4-1 已有对应能力及差分证据。命令白名单仍由实际 capabilities.commands 生成，未手写另一份清单。

## 源码依据

固定 npm ESM 出口为 just-bash 3.6.0 的 `dist/bundle/index.js`，SHA256 `d769656d8dd94d595c8268c89ab6f447db0515266092304993ed3888838cf137`。该发布物的默认限制对象包含两个 `1e5`，预算扣减会检查将要发生的计数，并以包含 `too many commands executed (>100000)` 的限制错误终止。另有更严格的可选 profile；当前 worker 未选它，也未传入覆盖值。交付证据 input-identities.json 保留准确导出路径、摘要和声明位置，不以文件名猜测来源。

当前 worker SHA256为 `f0e98ffeb285ee5877b6dfe8b72a6f5a0b6fce7b1633ab662a1f0e5f60fcdcc3`。本项不改 worker、运行时调度、上游库、预算值或其它限制。

## 测量及其解释

初始样本在固定 Node24.22.1/Linux、原 runtime `dd17e0b4ca425bc7c42179fb49a150d2e61a78f4a333063bf0cde70853cee8d4` 上运行实际虚拟 worker。相同短脚本执行空操作循环，再打印完成标志。每档只测一次，包含 worker 启动开销。

| 循环迭代输入 | JIT + OH marker | jitless 受限样本 | 退出结果 |
| --- | --- | --- | --- |
| 10000 | 579.952416 ms；进程峰值132508 KiB | 1041.879862 ms；111888 KiB | 0；到达完成标志 |
| 50000 | 716.731362 ms；138244 KiB | 3568.263173 ms；113072 KiB | 0；到达完成标志 |
| 100000 | 1182.343100 ms；158024 KiB | 5920.216919 ms；130144 KiB | 126；没有到达完成标志 |

原始 limits-jit.json / limits-strict.json 保存完整 script、stdout/stderr、退出码和采样。后一组当时 `process.platform` 仍是 linux，报告同时记录 marker=true 与 WebAssembly 不存在；不把它说成实际 OH 平台或手机数据。完成标志实际包含字面的反斜杠n，原样保留；它只用于判定后续命令是否执行，不据此声称 printf 换行语义已测。

RSS 是整个 Node 进程的累计峰值，含 worker，不是每个命令的增量内存或独立 worker 内存；后面的峰值可能沿用先前高水位。没有多次采样、置信区间、独占CPU或目标设备数据，不能把两种模式的差值当作严格性能提升/下降结论。

这些数据足以说明“正常的长循环也会实际到达限制”，以及在本宿主的受限样本中预算耗尽已是秒级工作；它们没有给提高到更大预算提供手机响应性、内存或电量依据。因此本轮保持默认值。未来调高前需要在目标设备、实际混合命令与最坏资源输入上测量，并同时验证取消、后台生命周期和队列公平性。

## 副作用与恢复契约

新增 process-limit-effects.test.mjs 通过实际 VirtualSubprocessRuntime 执行：先写 before 文件，执行超过预算的循环，再尝试写 after 文件。要求退出126、保持 before 内容、after 不存在、worker live 集合归零，然后同一 runtime 的下一次 cat 任务仍能成功。测试不是只对照一条文案。

原 runtime 的 JIT/严格测试各通过1项；随后在 M4-4a/v2 runtime `43dcc5a9b9fcfb5cd16e0a76b7a01f518f262a0afa1962cffebd9df3496799b9` 上再次独立运行，JIT与真正O0/openharmony各1/1，通过实际超限后继续接任务。后者日志给出含后续cat的总时间1568.384604ms与6419.996580ms；这与上表的脚本/开销不同，不能直接相减比较。新命令、环境及输入摘要见 description-validation.json。

工具描述由真正的 Cordis Context 注册 dsh-tool-bash 后读取，不是扫描字符串文件冒充 UI 注册。修复前新增断言真实失败（0/1，缺少执行上限描述）；将新OH补丁通过实际 rtbuild 应用后，完整权限/审批八项在JIT与严格O0各8/8，已批准/未批准的读写边界、Session根及票据拒绝仍保持。

## 补丁集与平台隔离

新 vendor diff 为 `zzzzzzzzzz-ohos-shell-limit-description.diff`，仅登记在 pins 的 ohos 目标中。精确前像已含 M4-4a/v2 的18个OH补丁，后像为19个；Android仍是原11个。

| 对象 | 前像 SHA256 | 后像 SHA256 |
| --- | --- | --- |
| dsh-tool-bash/lib/index.js | a9da6334ca5dedf89eb8add510167318d64addae3a986445bdfb75dba3d9e295 | e1526706c2ac3261e6fea1f6508337b02fc5c26b754e454acf374277eee42f7a |
| pins.json | 88181e46f3d33d67a48d64c5e124952462593ca9c3977e87e6b29b050b9bb88a | 0b547ad7b0f56120518c4c4ba05b26296af018caec3983b2ba17a1d15a3b8990 |

rtbuild 对两边 Android 实际选择集合、当前版本 pins 和diff摘要组成的规范输入完全相同，SHA256均为 `96a45fff361136c725566db51f4ea3bf2bc39b1eaa8b4a79583524db61b8718d`。这是补丁输入隔离证据，不冒充本项重新编译过Android APK。build-runtime/rtbuild/recipe helper均未修改。

验证prefix从既有已核18补丁树只读共享未改文件，rtbuild使用临时文件+replace写新工具文件；原prefix的字节和inode均未变化，新工具文件inode不同。依赖和生成bundle不进入本源码补丁，完整原before/after第三方实现正文也不附包。

## 复跑

需要先按 M4-4a/v2 准备精确 runtime 与固定过程依赖，并对 DSH prefix 运行完整 `patch-dsh --target ohos --dsh-version 0.2.1-rc.4`。运行两个测试时 `OHOS_TEST_PROCESS_PREFIX` 指向该prefix；需要单独指定实现时，`M4_PROCESS_RUNTIME` 为 runtime.mjs 的绝对路径。JIT用sim/marker.mjs，严格模式用--jitless与sim/preload.mjs，并显式设平台覆盖openharmony。完整本次argv/env在description-validation.json，不依赖口头重构命令。

单独测量脚本可通过M4_LIMIT_REPORT保存JSON。正式整合时继续跑同一O0五工具回合；本作者冻结包未自行签发独审或未发生的目标设备通过。OHOS arm64、HAP、手机延迟/电量、调整预算后的行为均NOT_RUN。
