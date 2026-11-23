# 伙伴小屋通知 · 界面接入

设置页仅在 `ref.watch(operatingSystemProvider) == 'android'` 时显示通知入口，再通过 `ref.read(companionNoticesProvider)` 取得 `CompanionNotices`。小屋现有处理者负责取件、判定和送达，设置页只需下面四个方法及一个刷新信号。[Dart 通道](../../app/lib/companion/companion_notice_channel.dart)

## 设置与状态

| Dart 方法 | `dsh/companion` 调用 | 返回 |
| --- | --- | --- |
| `status()` | `notices.status`，无参数 | `Future<CompanionNoticeStatus>`。首次进入、从系统授权页回来时重新读。 |
| `setEnabled(bool enabled)` | `notices.setEnabled {enabled: bool}` | 同上。传 `true` 时启用组件，缺少授权就打开系统设置；回来后以新的 `granted` 为准。 |
| `setLevel(String pkg, CompanionNoticeLevel level)` | `notices.setLevel {pkg: String, level: String}` | 同上。三档为 `off` 不看、`glance` 看一眼、`remember` 会记住。默认空名单，`status.level(pkg)` 对未列出的包返回 `off`。 |
| `recentApps()` | `notices.recentApps`，无参数 | `Future<List<CompanionNoticeApp>>`。每项有 `pkg: String`、`name: String`、`count: int`、`icon: Uint8List?`（PNG）。从功能开启并获授权后积累，按最近七个本地日历日汇总。功能关闭、未授权或锁屏时返回空列表。 |

| `CompanionNoticeStatus` 字段 | 含义 |
| --- | --- |
| `enabled, granted, unlocked`（`bool`） | 分别为功能开关、实际通知使用权、屏幕可交互且已解锁。显示“去授权”的条件是 `enabled && !granted`；`readable` 是三个值均为真。 |
| `levels` | `Map<String, CompanionNoticeLevel>`，原生以包名映射到三个字符串档位。最近列表里的包无须预选。 |
| `received, judged, said`（`int`） | 今天实际入箱的新增段数、成功完成判定的通知键数、实际送达的提醒次数。三个数的单位不同。 |
| `epoch, consentEpoch`（`int`） | 前者随锁态、授权或配置变化，后者只随同意范围变化或进程重建。作为失效标记使用。 |

`noticeSignal {epoch: int}` 是原生发给 Dart 的方法回调。使用 `notices.signals`（广播 `Stream<int>`）重读状态或列表，同一 epoch 也可能有新通知。回调没有通知文字。设置调用发生异常时，Dart 收到 `PlatformException`；原生校验拒绝用 `invalid_notice_arguments`，其他平台异常用 `notice_platform_failed`，后者的 message 是异常类名。判定或送达处理中可显示当前 `CompanionAgent.noticeFailure` 的短错误码，例如 `budget` 或 `model_response`；它为可空值，独立于系统授权状态。

## 记忆页

沿用页面已取得的本机 `CompanionMemoryOwner`。`owner.store.noticeMemories()` 给出 `List<MemoryRow>`，按来源时间从新到旧。显示 `text` 和 `source` 中的 `app`、`observed_at_ms`（Unix 毫秒）；`source` 还有 `kind: 'notice'`、`package`、`user_confirmed: false`。行本身的 `collection` 为 `recent`，`expires_at_ms` 为观察时间加七天。到期后停止聊天召回，管理页仍可查看和删除。标题为空或只等于 App 名时无法确定来源人，`say` 会丢弃；可记的近况仍须通过 `remember` 档位和敏感类别检查。

| 操作 | 已有入口 |
| --- | --- |
| 删除一条 | 沿用记忆页 `_write` 调用 `store.deleteCard(id: row['id'] as String, expectedRowRev: row['row_rev'] as int)`，成功后刷新。遇到 `companion/conflict` 重读该行。 |
| 清空通知近况 | `owner.clearNoticeMemories()` 同步写库并触发 `changed()`。两种删除都会记录所删事件的指纹，普通手工卡保留。 |
| 编辑 | 通知近况为只读来源；`saveManual` 修改此类行返回 `companion/notice-readonly`。用户后来亲口确认的消息可成为单独的聊天证据。 |

界面测试可用 `companionNoticesProvider.overrideWithValue(fake)`。现有测试替身为 `FakeCompanionNotices`，可变更状态并模拟 `post`、`lock`；其 `recentApps()` 默认返回空列表。需展示有图标或已卸载 App 的测试，可用同一接口返回相应记录。[测试替身](../../app/test/companion/companion_notice_triage_test.dart) · [记忆管理接口](../../packages/dsh_client/lib/src/companion_notice_store.dart)
