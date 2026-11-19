# 媒体预留的启动恢复合同

## 触发与部署前提

用户已经批准生成，`admitGeneration` 已持久化 `reserved`，但尚未进入 `begin` 时 Host 进程消失。旧预留仍计入同一上海日；默认日额和单次未知价预留均为 ¥20 时，重启后再次准入会得到 `budget_exceeded`。

本合同采用 Android 同一个 `DSH_HOME` 只有一个 Host、插件启动时没有活着的旧 producer 这一部署前提。启动恢复直接使用此边界，不新增 PID、lease、锁、重试或设置项。

## 恢复边界

生产入口 `apply` 先对 `<DSH_HOME>/media/dsh-media/budget` 执行一次 `releaseReserved`，完成后检查原有 fiber 是否仍存活，再调用原有 `installMedia`。因此工具、事件与 jobs 订阅都在恢复完成后建立；恢复失败直接向宿主传播，不继续注册。配置和凭据更新的 `refresh` 不执行恢复。

恢复复用账本原有事务与持久化，只把所有日期中 `state === 'reserved'` 的条目改成 `released`，保留条目身份、金额与其它字段。已有 `released`、`submission_unknown`（不确定是否已提交）、`submitted`、`settled` 一律不改。有修改时按原事务规则增加一次 revision；无匹配时不增加 revision。不删除账本或历史条目，不改变默认金额、单次审批、上海日界线或既有费用保护。

## 非常规双 Host 的代价

如果两个 Host 共用同一个 `DSH_HOME`，后启动的一方会释放另一方尚未 `begin` 的预留。本次产品决定接受“最多让当天多花一次预算”的代价；精确到本地记账，一次启动清理最多重新打开一份当日日额的预留容量。固定同一日额 `L`，同一个上海日内原 `reserved` 占用为 `R`、其余占用为 `C` 时，可用容量由 `max(0, L-R-C)` 变为 `max(0, L-C)`，增加量不超过 `L`。这不是供应商实际收费上界，也不是反复启动下的全天额外费用承诺。

既有 `beginSubmission` 仍要求条目处于 `reserved`。如果旧调用在其条目被释放后才进入 `begin`，它会失败，不能靠旧闭包继续发送；如果 `begin` 已经持久化 `submission_unknown`，启动恢复不会碰它。发送仍在 `begin` 之后。此片不为非常规并发增加协调协议，也不削弱上述提交门槛。

## 单条回归

`runtime/media/dsh-media/test/startup-reserved-recovery.test.js` 使用真实预算准入和账本：子进程完成默认满额预留后以 `SIGKILL` 消失；继任侧调用真实插件 `apply`，确认工具注册时原预留已经释放，再在同一上海日成功完成新的准入。父子使用同一预算时间，避免跨日造成假通过。宿主注册服务使用测试夹具；不声称完整 Cordis Host、Android 设备或供应商调用实测。

本片不改引擎覆片、series、targetSets 或 pins。执行结果与未验证项记录在补丁说明；完整 Linux CI 以 owner 后续回执为准。
