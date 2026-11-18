# 长期后台回合：TASK_KEEPING

本实现面向调试签名或指定设备安装。构建配置必须声明 KEEP_BACKGROUND_RUNNING、KEEP_BACKGROUND_RUNNING_SYSTEM 和 taskKeeping；受限权限的 ACL/Profile 由签名流程提供。没有权限、模式不支持或系统拒绝开始时，自动使用现有短时任务，不向回合报告权限错误。不得用静音音频或 DATA_TRANSFER 替代。

## 系统合同

公开 SDK API 26 的 `@ohos.resourceschedule.backgroundTaskManager.d.ts` 在 MODE_TASK_KEEPING 的说明中明确：非 PC/2in1 设备在获得 KEEP_BACKGROUND_RUNNING_SYSTEM ACL 后可以使用此模式。使用 API 21 的 ContinuousTaskRequest 和带任务 id 的 stopBackgroundRunning。开始成功由系统显示长时任务通知；wantAgent 指向当前 UIAbility。

参考：

- https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/task-management/continuous-task.md
- https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/ide-signing-auto
- 固定 SDK 声明 SHA256：846b061552680ebf976ecd69b3fbe716768e9c64760676f166c717ab6455b708。

SDK 合同支持上述实现；具体手机系统版本、签名 ACL 下发、通知显示与点击、长时间熄屏运行仍待真机验证。Linux 夹具不能证明这些行为。

## 准入与撤销

后台观察仍要求当前原生 owner/revision 的新鲜 busy ACK。权限检查只是申请条件，异步 OS start 成功且 owner/generation 仍当前才写原生 Continuous 状态。它使用新增 phase=7，保持原生快照布局不变；不借用短时任务 deadline，也不声称永不被系统暂停。Node 从原生只读桥读取此状态，HTTP 数据不能授予长期后台权限；手动暂停仍优先。

回到前台、回合 idle、手动暂停、owner 退役先关闭原生准入，再按本任务 id 停止 OS 任务。系统 Cancel 立即撤销，Suspend 立即撤销并停止该任务；随后可走原短时 fallback，不信任随后 Active 事件。旧请求晚成功只清理其返回的 id，不能激活新 owner。停止失败最多三次，保留诊断，不无限重试。

SDK 将 continuousTaskId 声明为可选。若成功结果缺 id，不能安全按 id 回收；context 范围停止会误伤新任务，因此本实现关闭准入、保留 ohos_continuous_missing_id 与 cleanupPending，且在途请求计入退役 owner 的保留条件。此时不声称系统任务已经回收。正常 SDK 返回 id 与此异常分支均需真机核验。

## 验证范围

作者测试覆盖无权限/开始拒绝回退、未获 OS 接受不能准入、前后台及 owner 竞态、缺 id 晚回不误停新任务、Cancel/Suspend、手动暂停和停止失败。C++ 状态测试与真实双 DSO 的 Linux 单 Node 链路验证 phase=7 可驱动工具执行和 journal 提交，并在撤销后关闭准入。ArkTS 编译与设备验证的结论分别记录，不将桌面 N-API/hilog 适配器称作公开 SDK 或手机运行。
