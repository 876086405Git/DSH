# 中断收尾保留显式输入唤醒合同（5675）

基底 `3c8637d2b1279d8b420e148bba4624cb355eb182`，DSH `0.2.2-rc.1`；登记依赖先应用 5672。新增公共片 `input-recovery.diff`，复用已有同名测试，不替换既有 `zzzzzzz-input-recovery.diff`。

触发：本轮已 claim、尚未写入 `user/message` 的 steer 原投 next-step；客户端 cancel 后，在旧轮退出前显式 followup。新输入已进 next-turn 并设置 `wakeRequested`，旧 finally 恢复插话时却清除此唤醒并置 `recoveredInput`，两条输入都留在 inbox。

只改一处：`turn()` 的 finally 成功 recover 时，仅 error/null 收尾继续置 `recoveredInput` 并清 wake；aborted 收尾只恢复输入，保留 abort 后显式 send 设下的 wake，交给 `kick()` 原有条件开下一轮。`kick()` 条件不动，无新状态。

没有显式 wake 的取消只恢复输入，不自行开新轮。recover append 失败仍走原 catch，置 `recoveredInput` 并清 wake；error/null 恢复仍抑制重启。aborted 之后 `turn/end` 写入失败时不另清 wake：新 driver 的 phase 不继承 wake，最多为这条显式输入再试一轮，失败即按 error 收尾停下，不会形成重试风暴；存储只是暂时失败时用户的输入照常送达。

现有回归替换一例：真实类及 inbox 的 steer → assemble 阻塞 → cancel → followup → 放行；断言恰好两轮、下一轮读到两条输入、无 pending/claim 残留。沿用原 fixture 的 post-admission failure 结束第二轮，不宣称执行了模型请求；既有 error/recover append 失败用例不变。

公共片后，OHOS 的 `zzzzzzzzzzzzz-ohos-lifecycle.diff` 继续改同一文件，其旧块仍各唯一匹配，无需修改该片，pins 随新片一起重录。登记为共同第 175 项，Android/OHOS 分别 175/217 项。
