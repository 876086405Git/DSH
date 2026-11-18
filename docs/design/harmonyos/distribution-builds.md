# 调试、指定设备发布与上架构建

签名配置和Flutter编译模式是两个维度：`--distribution debug`默认仍编译release，使用调试证书/Profile；只有显式`--debug`才切换Flutter调试引擎。当前固定embedding补丁只覆盖release HAR，Flutter debug的粘贴、振动与输入法行为仍需单独验证，不能用“调试签名成功”代替这些能力验证。

```sh
# 调试Profile（通过DevEco自动签名取得；可包含申请期间的临时ACL授权）
tooling/ohos/build-hap.sh --distribution debug
# AGC指定设备发布所需的发布证书及对应Profile
tooling/ohos/build-hap.sh --release --distribution device
# 一键剥离两项受限权限和taskKeeping声明，再以对应上架Profile签名
tooling/ohos/build-hap.sh --release --distribution store
```

旧调用不带`--distribution`时保持生成unsigned HAP，并使用store权限集合。以上显式distribution调用只有签名及verify-app实际成功才报告signed HAP；目标为`app/build/hap/dsh-go-<distribution>-signed.hap`。device模式不接受Flutter debug构建。脚本不申请AGC账号权限、不生成授权Profile、不把应用自动发布到设备或市场。

Linux 上没有 OHOS 版 `flutter build hap`，HAP 由 `check-arkts.sh --full` 打出，所以它也有同样的选项：

```sh
tooling/ohos/check-arkts.sh --sdk <SDK> --full --aot <dir> --native <dir> --runtime <zip> --node-headers <dir> --distribution device
```

声明了受限权限的 HAP，要 Profile 里有对应 ACL 才装得上。Profile 还没批下来时，用 `--distribution store` 或不加这个选项，粘贴和长期后台退回无权限的行为。

## 签名材料

这些是本项目新增的环境变量，不是SDK预定义变量。材料文件必须在仓库之外，GitHub Actions可由已有secrets写到runner临时目录，传其路径；不要打印变量或开启shell追踪。

| 环境变量 | 内容 |
|---|---|
| `DSH_OHOS_SIGN_KEYSTORE` | 匹配证书的.p12/.jks密钥库路径 |
| `DSH_OHOS_SIGN_CERTIFICATE` | 应用签名证书路径 |
| `DSH_OHOS_SIGN_PROFILE` | 已签名.p7b Profile路径；签名类型、bundle、设备范围和ACL由申请方确认 |
| `DSH_OHOS_SIGN_KEY_ALIAS` | 密钥别名 |
| `DSH_OHOS_SIGN_KEY_PASSWORD` | 密钥原始密码；不是DevEco加密后的build-profile字段 |
| `DSH_OHOS_SIGN_STORE_PASSWORD` | 密钥库原始密码 |
| `DSH_OHOS_SIGN_TOOL` | 当前HarmonyOS SDK的hap-sign-tool.jar路径 |
| `JAVA_HOME` | 与签名工具匹配的JDK，本机验证工具为JDK17 |

沿用`FLUTTER_OHOS`、`DSH_OHOS_NATIVE_LIBS`、`DSH_NODE_HEADERS`和`DSH_OHOS_RUNTIME`。签名采用SDK真实`sign-app -mode localSign`及`verify-app`，SHA256withECDSA，API26。脚本要求build-profile里的signingConfigs为空，避免hvigor把凭据纳入项目模型/缓存。凭据不继承给Flutter及构建子进程，只传签名辅助程序；辅助程序在仓库外0700临时目录创建0600 Java参数文件，关闭签名工具日志、丢弃工具原始输出，结束时删除临时参数及提取的证书/Profile。错误只报固定说明，不打印密码、证书、Profile或UDID。签名成品自然包含安装校验所需的签名和Profile，这是交付包自身的内容。

不要将自动签名获得的调试Profile当成指定设备发布Profile。指定设备发布需要AGC相应发布流程提供的材料；本脚本使用外部提供的Profile，不声称能更改其中设备名单、有效期或ACL。真机安装及设备范围尚未核实。

## 权限覆盖及以后上架待裁能力

只临时改本次OHOS模块声明，正常/失败退出均恢复原module字节；Android文件和依赖图不变。debug/device添加`KEEP_BACKGROUND_RUNNING`、受限`KEEP_BACKGROUND_RUNNING_SYSTEM`、`READ_PASTEBOARD`，EntryAbility增加taskKeeping。store显式删除两项受限权限和taskKeeping，保留其他能力既有声明。不能靠修改manifest获得系统授权；没有对应权限时运行时应走既有短时任务或粘贴回退。

| 能力 | 不上架构建 | 上架构建/待裁决 | 尚需核实 |
|---|---|---|---|
| 长时后台AI回合 | 请求KEEP_BACKGROUND_RUNNING_SYSTEM，taskKeeping模式，通知可见 | 一键移除受限权限及taskKeeping；是否获正式ACL以后决定 | 手机支持、Profile授权、系统回收、通知及耗电 |
| 用户触发的剪贴板读取 | READ_PASTEBOARD，EntryAbility inuse并带用途说明 | 一键移除权限；保留现有无权限行为/安全控件路径 | 临时ACL有效期、用户授权、Flutter文本框和按钮 |
| 短时后台 | 既有短时任务；无长时权限时回退 | 保留 | 实际额度和冻结时序 |
| 分享、语音、PDF、实况窗 | 不因市场审核提前裁剪已有实现 | 分别审查HMS权益、隐私要求及不可用回退 | 普通SDK加HMS替身编译不等于官方HMS/真机通过 |
| exec/JIT、其他App读取与自由悬浮窗 | 系统限制继续生效 | 同样受系统限制 | 签名方案不能解除这些边界 |

## 核验依据与范围

- 华为[声明ACL权限](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/declare-permissions-in-acl)与[自动签名](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/ide-signing-auto)：API26自动签名流程可关联ACL申请；审批前临时Profile与审批后正式Profile的有效期不同，不能把临时资格当市场批准。
- 华为[申请调试Profile](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-debug-profile-0000002248181278)：Profile绑定调试设备，权限变更后需重新生成Profile。
- 华为[动态修改签名配置示例](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/ide-hmos-hvigor-config-ohos-sample)说明hvigor signingConfigs字段；本入口刻意不把这些秘密写到工程配置，而在unsigned构建后签名。
- 本机SDK26.0.0.38的hap-sign-tool.jar实际`-help`已执行，核对sign-app/verify-app参数；普通SDK严格ArkTS与权限overlay能在Linux验证。未持有用户调试/指定设备发布签名材料，因此实际合法签名和手机安装必须在本机完成，不能把模拟签名测试报成可安装HAP。
