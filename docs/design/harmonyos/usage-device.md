# HarmonyOS 设备查询

`dsh/usage` 的 `device` 由 UsagePlugin 注册，返回安装包实际 versionName/versionCode、厂商归一化结果和公开设备 ABI 列表首项。ABI 是支持列表回退值，不是实测当前进程架构。空列表保持空值；没有序列号、UDID、机型或广告标识。查询不发网络请求，也不请求额外权限。

`platform` 固定为 `ohos`；`apiVersion` 是公开 `deviceInfo.sdkApiVersion`。旧 `sdk` 字段在当前 Dart usage v1 中表示 Android API level，因此使用既有未知值 0，不能将 HarmonyOS API26 冒充 Android26。

当前 `UsageDeviceChannel` 仍消费旧字段；`UsageStatsController` 构造的 v1 payload 不携带 platform/apiVersion，`usageProblem` 要求 Android sdk 26..60。未知值 0 会被拒绝，**不会因为这次恢复设备查询而启用 OHOS 遥测上传**。当前既有行为会丢弃不合格的待发送日记录，并非保存队列等待将来重传；本改动不改变该策略。要启用跨平台统计，须另行定义服务端与 Dart 的平台化协议，不能只改数值范围。

bundle/device 读取失败返回稳定 `ohos_usage_unavailable`，不泄露系统原始错误。通道退役或被新 binding 代替时，旧异步读取不会把成功交给新引擎；未知方法走 notImplemented。Dart 已有 PlatformException 回退仍保留。

SDK依据是固定公开SDK26的 `@ohos.deviceInfo.d.ts` 和 `bundleManager.BundleInfo`，不是 HMS 私有接口。真实设备属性内容及生命周期表现仍待真机核实。

测试：`runtime/tests/ohos/usage-channel.test.mjs` 执行真实 EntryAbility 与 UsagePlugin 经 TS erasure 的方法体，系统与Flutter边界显式替身；`app/test/usage/ohos_device_contract_test.dart` 执行真实Dart消费者及统计控制器，只用FakeUsageHttp，不访问真实统计服务。设置 `OHOS_USAGE_FACTS` 可读入 ETS 测试生成的 JSON；不设时使用明确的同合同夹具。

本包不注册 dsh/update，也不改保存取消协议。仅给 update 的 info 实现会误解除当前 MissingPluginException 的 APK 禁用门；保存取消若返回null，会被 FilesChannel 兜成假 Download/DSH-Go 成功路径。这两项需独立完整消费者合同，不能以半个原生处理器交付。
