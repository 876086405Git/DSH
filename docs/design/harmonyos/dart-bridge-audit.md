# Dart 与 ArkTS 通道的常驻静态清单

`tooling/ohos/audit-dart-bridges.py` 读取源码，不执行 Dart、ArkTS、fork 初始化或系统 API。
它同时保留两条独立证据：七个固定 fork 的 Dart/OH 入口，以及应用 Dart 调用对应的
ArkTS handler。某个 ArkTS 类存在，不能抵消 Dart 入口先抛错的问题。

## 运行

使用本次实际 `pub get` 的配置；其中未解析到的 fork 或 OH delegate 会明确列为 UNKNOWN：

```sh
python3 tooling/ohos/audit-dart-bridges.py \
  --source . --package-config app/.dart_tool/package_config.json \
  --require-group1 --report /tmp/dart-bridges.json
python3 tooling/ohos/tests/audit-dart-bridges.test.py
```

只读源码审查也可用 `--fork-roots roots.json`，JSON 是包名到本地源目录的映射。这个
模式会在报告写明 `explicit-source-review-roots`，不能当成一次真实依赖解析的收据。
`--package-config` 和 `--fork-roots` 不能同时使用。脚本不下载依赖、不补注册文件。

`--require-group1` 要求 `dsh/secrets`、`dsh/attachment-files`、`dsh/islands`、`dsh/launcher_icon` 的实际 literal 调用、
handler 和 EntryAbility 注册存在，并检查当前仓库明确的五处 secrets 默认选择及
attachments 的 OH/default factory。不能用任意同名 ArkTS 类或同文件的另一套 `case`
使这个门通过。`--require-channel <name>` 可另外选择一个已明确的通道合同。
五处 secrets 检查绑定指定 consumer 类的直接成员：两个可选注入构造器的 `_storage`
初始化、Settings 的 `_secure` 常量、另两个可选注入构造器及 `_storage` getter。
同文件另一函数或类里出现 `AppSecureStorage()` 不满足这些默认表达式；这是固定源码
形状检查，不证明任意调用方没有显式注入其他 storage。

未给任何 require 参数时只产生 `INVENTORY_ONLY`，不是通过结论。指定范围没有缺项时
为 `PASS_SCOPED`；有缺项、未知分派或缺注册时退出 1。JSON 的 `fullInventoryStatus`
独立保留未覆盖项，不能把范围内通过改写成全表或全 App 通过。

## 报告中的判定

| 结果 | 说明 |
| --- | --- |
| `HANDLER_PRESENT` | literal 方法在该通道注册的 dispatcher 中出现；不表示业务成功 |
| `MISSING_CHANNEL` / `MISSING_METHOD` | 在本次输入中未找到对应接收端/方法 |
| `UNCONFIRMED_REGISTRATION` | 找到类与 handler，但没有读到 EntryAbility 的明确注册 |
| `UNKNOWN_DYNAMIC` / `UNKNOWN_HANDLER` | 名称、别名或分派无法在本脚本范围内解析 |
| `SYSTEM_BUILTIN_NOT_APP_ARKTS` | 固定 Flutter SystemChannels 名称，接收端属于 embedding；不证明设备支持 |
| `NATIVE_TO_DART_CALLBACK` | `setMethodCallHandler` 接收原生回调，单独列出方向 |
| `EVENT_HANDLER_PRESENT` | EventChannel 的接收声明存在，不与方法调用混为一类 |
| `PIGEON_MESSAGE_REQUIRES_GENERATED_PROTOCOL_REVIEW` | BasicMessageChannel/Pigeon 消息，保留模板，未假定动态 suffix 和序列化合同正确 |

脚本去掉注释，识别字符串、括号和常见正则字面量。ArkTS 的方法名只从该 channel 的
`setMethodCallHandler` 出发，跟踪同类明确的 `this.method(...)`，收集 `call.method`
switch、比较和 literal allowlist；不会把 MIME switch、未调用方法或另一个 channel
的 case 当成处理证据。Dart 构造器的可注入默认 channel 标为源码默认值，不声称调用方
一定没有注入其他 transport。

这是有限的机械门，不是 Dart/ArkTS 编译器或通用控制流证明。动态方法、跨文件分派、
生成协议和无法确认的注册都保留 UNKNOWN；未来改变默认选择的代码形状时，需要重新
核对并更新对应识别，不以宽泛匹配放过。handler 可以明确返回 unsupported，静态存在
也不代表相应功能可用。

## 七个 fork 与应用替代入口

每次报告都列 `file_picker`、`flutter_secure_storage`、`image_picker`、`path_provider`、
`shared_preferences`、`url_launcher`、`webview_flutter`。记录实际入口和 pubspec SHA、OH
声明、选中的 delegate、可见的 Dart/ArkTS channel 清单及未提供的 platform-interface。
不从目录里恰有一个同名 sibling 推断它被实际依赖选择。

固定 secure fork 的 `_selectOptions` 没有 OH 分支、应用包没有 OH 声明，单独列为源级
缺口。固定 file-picker fork 的 URI→`toFilePath`/`File` 读取路径单独提示：document URI
不等于本地可读路径。第一组改动由应用自己的 OH 默认分支和通道绕开这两个入口，报告
保留原 fork 的事实，不能写成原 fork 已被修好。

静态 before 应在原基底失败；after 必须使用真实组合后的 EntryAbility 和产品源，不能
为测试临时伪造注册。它补充真实 Dart consumer、ArkTS 组件与普通 SDK 门，不替代这些
执行证据，更不替代设备权限、HUKS、Picker URI 生命周期、卸载或内存行为的验证。
