# 端上 XCTest 手机操控（实验）

这一版让 DSH Go 尝试在手机自身启动已签名的 PhoneRunner，复用原有 XCTest 元素快照、编号点击、列表读取和文本输入。**不是把截图坐标模式包装成无障碍，也不是普通 App 直接获得系统无障碍权限。** 原 Mac runner 仍是默认路径。

## 当前边界

- 需要 iOS 17+、开发者模式、兼容的 RP 配对记录、LocalDevVPN 回环，以及已经签名安装的 PhoneRunner。
- **匹配的开发者镜像（DDI）必须已经挂载。** 本版没有自动下载、个性化或挂载 DDI；设备重启后可能需要重新准备。不能宣传“一次 Mac，永久脱离”。
- 这是侧载/开发实验，不是 App Store 能力。没有在本轮环境进行 Apple SDK 编译、iPhone 真机或时延测试；Rust/Linux 测试不代表设备可用。
- 默认 iOS 构建不需要 Rust 或新的原生库。只有显式运行可选构建脚本并生成本地 xcconfig 后才启用；删除生成的 xcconfig 即停用。
- 新 phone 握手不需要 App Group。App 其他功能的 App Group/扩展签名要求没有在本次移除，不能据此承诺整包支持任意免费账号签名。

## 数据与执行路径

```text
已授权的手机工具调用
  -> Swift 单次启动 owner
  -> 本机 10.7.0.1 / RP pairing 隧道
  -> testmanagerd + 已安装的 PhoneRunner xctrunner
  -> XCTest 元素快照 / 点击 / 输入 / 列表
  -> 回环 RPC 返回文本，可按需附图
```

Native 使用固定的 [jkcoxson/idevice](https://github.com/jkcoxson/idevice/tree/3854a5df4a5a6dee71ffce4d8befc2ea356a8065) 与最小本地 RSD XCTest 适配，不合入外部 PR。完整源地址、摘要和本地补丁见 [原生目录](phone-self-runner/)。

App 为每次启动创建内存 RSA 密钥。Runner 的环境里只有公开公钥和 runId；它生成的 RPC 凭据经 RSA-OAEP-SHA256 加密后，通过 XCTest activity 返回。私钥和明文 bearer 不进入启动参数、环境、App Group 文件或测试日志。旧 Mac 发现机制为兼容保留，不用于新端上握手。

取消/超时先使当前准备失效，迟到的 ready 不会执行动作；等待 native 退出确认后才允许新启动。动作发出后连接失败只报告未知，不自动切后端重放。无法确认旧设备进程停止时保持故障状态，不冒充“停止成功”。

## 在 Mac 上准备

先选好 Xcode、准备并安装主 App。首次签名、设备信任、开发者模式及 DDI 由用户在 Mac/设备上完成。

### 1. 构建可选原生库

安装 rustup 后，在仓库根运行：

```sh
bash tooling/ios/build-phone-self-runner.sh
```

该脚本使用目录内固定 Rust 工具链、Cargo.lock 和上游源码摘要；产出设备/模拟器静态库、许可清单及 `app/ios/PhoneSelfRunnerNative/PhoneSelfRunner.xcconfig`。产物不进 git；失败的首次构建不写入启用配置。重新构建主 App 才会带上此能力。

### 2. 准备兼容配对记录

需要的是 `idevice::remote_pairing::RpPairingFile` plist，包含 `public_key`、`private_key` 和 `identifier`，**不是传统 lockdownd 的 HostID/证书 pairing plist**。固定上游的 `rppairing pair` 工具可生成；具体命令及格式见 [原生说明](phone-self-runner/README.md)。不要把记录提交到仓库、粘进聊天或上传诊断。

### 3. 安装 XCTest helper 并导入记录

开启 LocalDevVPN。在已安装主 App、连好 USB、解锁并信任设备后运行：

```sh
bash tooling/ios/prepare-phone-self-runner.sh \
  --device DEVICE_UDID \
  --pairing /private/path/rp-pairing.plist \
  --team APPLE_TEAM_ID
```

这一步构建并安装签名的 `PhoneRunnerUITests-Runner.app`，使用不带 App Group 的 helper entitlement，然后替换主 App 的 `Documents/pairingFile.plist`。它不会发送任何读屏或点击动作。自定义主 App 包名时传 `--app-bundle-id`；默认 helper 包名是主 App 包名加 `.PhoneRunner.xctrunner`。

重新安装启用了可选库的主 App，打开并允许本地网络访问；先测试 `screen`，再测试编号点击和输入。现有一次 30 分钟授权流程保持不变，没有增加每一步确认。

Bonjour 只用于发现本机开发者服务端口，连接地址固定为 LocalDevVPN 的 `10.7.0.1`。可以通过主 App Info.plist 的 `DSHPhoneRemotePairingPort` 明确指定端口；需要自定义 helper 时使用 `DSHPhoneRunnerBundleIdentifier`。

## 相比纯截图路径保留/改善了什么

- 普通读屏返回 XCTest 元素文字、类型、位置和状态；不是每次都传大图给模型。
- `screen(image:true)` 同一张截图同时用于尺寸与图片，避免首次读屏重复截图。
- `tap_xy` 使用那张图片的比例与屏幕号校验，不再为点击另截一张图；越界/过期截图明确拒绝。
- 列表/滚动容器也有元素编号，`collect(list: ...)` 在指定容器读取、滚动，而不是忽略列表参数。
- 原有敏感字段检查、handoff 和 Mac 后端保留。游戏、自绘画布等元素不足的页面仍需截图兜底。

这些是代码路径改善，**没有在这里宣称更快多少毫秒**。性能应在真机分别记录冷启动、热读屏、点击后读屏、图片上传和整轮模型耗时。

## 验证

Linux/macOS 可运行构建契约及 Rust 检查：

```sh
bash tooling/ios/build-phone-self-runner.sh --check
python3 tooling/ios/tests/phone-self-runner.test.py -v
```

Python 中的真实 RSA/Security 测试需要 macOS；Linux 会明确 skip。Xcode CI 还会检查开启编译条件的 Swift C ABI，并在模拟器运行 `IOSPhoneSelfRunnerTests` 的真实 Swift owner 状态机；native 通道用记录器注入，不能替代真实设备启动。

真机至少验证：

1. 无可选库时旧 Mac runner 仍可读屏、编号点击和输入。
2. 可选库+有效配对+预挂 DDI：断开 Mac 后启动 helper，`screen` 返回真实元素；测试设置和一个第三方 App。
3. 测试中文输入、指定列表采集、截图兜底、过期屏幕号与敏感字段拒绝。
4. 准备中取消、引擎停止/重启、后台挂起与隧道掉线后，不执行迟到动作、不重放点击。
5. DDI 缺失、配对失效、helper 未安装或签名过期时明确失败，不返回空的“成功屏幕”。
