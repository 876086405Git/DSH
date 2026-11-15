# CoreDevice 停止：前台等待与迟到清理确认

对应 ios5 ADDENDUM-09 §2.1。父为 ae4b0564d73e17d8c134c8d84bf05f367feca995；独立于音频包 16，不叠加被退回的旧 24。本文描述本补丁的源码行为；Apple SDK、Swift/XCTest、真机执行均 UNRUN。

## 两种 fault 的区别

| 原因 | 对外状态 | 后续同一次 native 确认 |
| --- | --- | --- |
| Swift 本地停止等待超时，或前台单调时钟无效/倒退 | phase=faulted，code=ERR_PHONE_STOP_UNCONFIRMED；保留原 run/handle 屏障与 event callback | 只接受同一 active run、runID、已绑定非零 handle 的 kind 2/3，且成功解码 cleanupConfirmed=true；可释放旧屏障。 |
| native kind 4 报告清理未确认 | 继续 faulted/不可切后端；不转成本地 timeout 分类 | 不能被之后的 kind 2/3 或 ready 清除；native kind 4 即使带相矛盾的 cleanupConfirmed=true 也仍锁存。 |

开始时的句柄协议不一致也不会被归入可恢复的本地 timeout 分类，仍禁止切换后端。

本地 timeout 后 ready、结果回调、错 run/handle、缺失或 false 的 cleanupConfirmed 都不恢复任务。native kind 4 可以把本地 timeout 升级为 native fault，反向不允许。清理确认不是动作成功：kind 2 到 idle，kind 3 到 failed 并保留失败码；两者都不恢复 capability、不重发旧请求、不自动创建运行。后续仍须由现有授权/owner 准入发起工作。

Rust 的 finish 先核对并释放匹配 owner，才发送 cleanupConfirmed=true 的终态，因而这项明确的迟到证据可以解除 Swift 的本地等待屏障。仅收到停止请求、计时结束或某个回调本身不等于资源清理完成。

## 45 秒只累计 App 活跃前台时间

Rust Session.cleanup 的四段预算是 5 + 5 + 5 + 15 秒；Swift 本地停止预算为 45 秒。预算不是操作系统级清理保证，也不覆盖底层阻塞 DNS/runtime 析构的物理截止。

停止时建立单调时间锚点，100 ms 的实际 watcher 检查累计值。willResignActive 在同一 MainActor 顺序中结算已有的活跃片段并清锚点；inactive/background 都暂停，didEnterBackground 再清锚点兜底。didBecomeActive 开始新片段，不计两次活跃期间之间的后台/睡眠时间。生命周期状态另行锁存，所以 willResignActive 发出时 applicationState 仍是 active，也不会被下一次轮询误算成继续活跃。

重复 stop、新 prepare 或重复通知不重置已经用掉的预算。时间采样须有限、非负且不倒退；保留 lastSample 与当前片段 anchor 的不同职责。后台不读取停止时钟，因此后台不可用的采样不会导致新 fault；回前台后的无效采样只建立本地 timeout 屏障，仍可被准确清理确认解除。无 native handle 的取消直接终结，不启动 watcher。

原 run 的 watcher 只处理那个 run，终态会取消它。有效的清理终态在检查本地过期前处理，因此恰在 45 秒、或 watchdog 因调度延迟尚未运行时到达的确认不会被本地计时丢弃。App 挂起时不会承诺及时更新画面；恢复后只累计明确的活跃片段。

## 后端切换和模型错误文字

Runner 的 12 秒路线切换等待保持为一个调用等待上限，超时只返回 ERR_PHONE_STOPPING，不会据此设置永久 fault。已有 fault 在进入等待前立即失败；等待中出现 fault 也立即结束，不再白等剩余时间。await 返回后仍重新核对当前调用和 maySwitchBackend，避免把异步 helper 的旧结果当成持续授权。

Core prepare 的 STOP_UNCONFIRMED 和切换等待的 fault 路径使用同一说明，明确要求用户彻底关闭 DSH Go 后重开、由用户重新发起，并禁止自动重试。本地 timeout 若随后收到有效迟到确认，状态也可自行解除；这不等于重新执行先前动作。其他 prepare 失败、逐次批准、精确 owner、no replay、returnToApp 和手动接手机制保持原有约束。

## Dart 可见契约

| 项目 | 本包变化 |
| --- | --- |
| Flutter 方法名、参数、状态键 | 无新增、无删除。 |
| phase 值 | 沿用 idle/starting/ready/stopping/faulted/failed；没有新增值。 |
| 错误码 | 沿用 ERR_PHONE_STOPPING、ERR_PHONE_STOP_UNCONFIRMED、ERR_PHONE_ACTION_UNCONFIRMED 等现有码；没有新增码。 |
| 状态时序 | 本地停止超过 45 秒累计活跃时间后可从 stopping 进入 faulted；准确的迟到 kind 2/3 可从本地 faulted 变成 idle/failed。native kind 4 仍需重启。 |
| 模型可见文字 | 清理 fault 明确包含彻底关闭 App 后重开与不自动重试；route 等待不再在已 faulted 时耗满 12 秒。 |

不修改 app/lib/ui 或 app/lib/l10n；维护者已有 faulted 提示和按钮策略会接收同样的 phase/code 值。新增 isFaulted、故障来源分类、时钟和生命周期注入均是 Swift 内部实现，不是新的 Dart 状态字段。

## 验证范围

IOSPhoneCoreDeviceTests 新增 16 个方法，原 18 个方法保留，共 34 个 authored、0 executed。测试使用真实 Swift owner 与 Runner 的实际切换等待函数、合成配对记录、记录型 native 适配器、可控单调钟和独立 NotificationCenter。覆盖 44.999/45 秒、inactive/大后台间隔、重复通知/stop、迟到 2/3、native 4 锁存、错身份、无效和倒退时钟、旧请求与新 owner 隔离、同步通知/ACK 重入，以及既有/等待中新 fault 的快速失败。

这些是已编写的 XCTest，未编译或运行。注入适配器直接调用 Swift event sink；真正 C 回调注册表的保留和删除只有源码审查，不能冒充已执行的 ABI 或设备验证。没有用 Linux 测试替代 UIKit 通知、Swift 编译或真实清理耗时。既有 CI 已选择 IOSPhoneCoreDeviceTests，本包不新增测试 target 或依赖。

## 来源

- [Core owner 与事件门](../../../app/ios/Runner/IOSPhoneCoreDevice.swift)
- [Runner 路线切换](../../../app/ios/Runner/IOSPhoneRunner.swift)
- [真实 XCTest 源](../../../app/ios/RunnerTests/IOSPhoneCoreDeviceTests.swift)
- [Rust finish 与 Session.cleanup](../phone-self-runner/src/core_device.rs)

旧 24 的 12 秒连续时钟与拒绝迟到确认设计已被 ADD09 退回；本补丁替换该方案，不应叠加旧 24。旧冻结、旧审查与失败原因保留为历史证据。
