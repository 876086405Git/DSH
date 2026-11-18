# 鸿蒙核心通道：P3a 网络状态

基底 `c818155`；仅此文列明的通道已实现。其余 P3 通道另包交付。

**ArkTS 尚未编译，未在真机核实。** 本包的 Linux 测试直接对产品 `.ets` 做 TypeScript 语法擦除，运行真实通道方法；OpenHarmony 网络服务与 Flutter messenger 是可控替身。这能验证协议和异步资源归属，不能证明 ArkTS 类型检查、HAP 装载或系统回调成立。

## 通道与兼容性

| 通道 | 方法/事件 | 返回 |
| --- | --- | --- |
| `dev.fluttercommunity.plus/connectivity` | `check` | `List<String>`，使用 wifi/mobile/ethernet/bluetooth/vpn/other/none；不是单个字符串。 |
| `dev.fluttercommunity.plus/connectivity_status` | EventChannel | 同形状列表；成功订阅后发当前状态，后续只在内容变化时发事件。 |

依据 `app/pubspec.lock` 锁定的 `connectivity_plus_platform_interface 2.1.0` 原包，SHA256 `3c09627c536d22fd24691a905cdd8b14520de69da52c7a97499c8be5284a32ed`。其 `lib/method_channel_connectivity.dart` 使用以上两个精确名称，`lib/src/utils.dart` 解释列表元素。官方发布包：[pub.dev 固定归档](https://pub.dev/api/archives/connectivity_plus_platform_interface-2.1.0.tar.gz)。没有引入新 Dart 依赖或修改 Android。

本实现回答默认网络的承载类型，不以有 Wi-Fi/蜂窝连接断言互联网可达。仅 `getDefaultNet().netId === 0` 返回 none；服务查询失败返回 `ohos_network_query`。存在网络但没有已知承载类型返回 other。列表去重并排序，避免仅顺序不同造成重复事件。

未知方法返回 notImplemented。订阅失败返回 `ohos_network_watch`，不会伪造一个 none 事件或悄悄改成轮询。

## 订阅资源与竞争

每次监听建立一个 `NetConnection`。退订、引擎分离和重新订阅均使旧 generation 失效；晚到的 register 成功回调会注销自己的 observer。每次实际查询有顺序号，较慢的旧查询不能覆盖较新的状态。旧 observer 的回调会在查询之前被拒绝，不能使新订阅正在等待的首次查询失效。

注销失败仅写不含用户数据的 hilog 诊断，仍清除 Flutter handler 和当前接收者；实际系统服务故障后的观察者回收需设备验证，不声称此错误路径在手机上已确认释放。

`ohos.permission.GET_NETWORK_INFO` 已在基底 `module.json5` 申请，本包不增加权限。使用的公开接口为 createNetConnection、NetConnection.on/register/unregister、getDefaultNet、getNetCapabilities 与 NetBearType。

## 固定 API 依据

- OpenHarmony 官方接口声明：[interface_sdk-js `8a86234f0d542e5062e24e948652f5a484d90904`，`@ohos.net.connection.d.ts`](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@ohos.net.connection.d.ts)。本次源码归档 SHA256 `772f9db136c163e7b0ad0111230768f547fa9a7acc230c115a88aea8565f1099`。已核默认网络、枚举、callback 注册和注销签名；最终以本机 API 26 SDK 为编译门。
- oh-flutter `3.47.9-ohos-1.0.0`、修订 `e5f752df3e25ec897da3c98a74bcced7c21b0bd3` 的 `flutter_embedding/flutter/index.ets`、FlutterPlugin/MethodChannel/EventChannel。按该源码使用 `getBinaryMessenger()`、MethodResult 和 StreamHandler。这里只取接口约定，没有复制其他移植项目实现。

## Linux 验证与本机门

先按现有 `runtime/ohos/process/package-lock.json` 执行 npm ci。运行：

```sh
OHOS_TYPESCRIPT_PREFIX=/absolute/runtime/ohos/process \
  node --test --test-isolation=none runtime/tests/ohos/connectivity-channel.test.mjs
```

测试覆盖精确通道名与列表协议、已知/未知承载类型、无默认网络、查询错误、首次状态及去重、取消后晚注册、查询完成乱序、旧监听干扰新监听、同步系统异常及引擎销毁清理。开发候选曾在注册同步失败、注销同步失败、旧事件使新查询失效三项失败；修正后 8/8 通过。失败与通过日志均随交付保存。

本机须运行 hvigor 编译并在设备切换 Wi-Fi/蜂窝/VPN、开关飞行模式、销毁重建引擎，检查列表形状、权限拒绝提示和 observer 数量；本包不把这些列为已通过。
