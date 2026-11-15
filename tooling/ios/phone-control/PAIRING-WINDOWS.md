# Windows 生成 DSH 使用的 Remote Pairing 记录

核对日期：2026-11-07。本文核对了固定源码、官方发布元数据，并实际下载校验了
Windows CLI ZIP；**没有在 Windows 或 iPhone 上执行配对，不能标为实机 PASS**。
操作后仍要在 DSH 中完成导入和连接检查。
DSH 内的步骤面向已接入本轮配对导入/保存方式 UI 合同的构建；这份文档本身不证明
主线设置页已经完成这些接线，也不替代最终 App 验收。

DSH 的这条 CoreDevice / RSD 路线接收 `RpPairingFile`，即 **Remote Pairing**
记录。USB 上点击“信任此电脑”建立的 **Lockdown** 记录，是生成远程记录的前置
信任关系；它们不是同一种文件。不能把普通 `UDID.plist`、iTunes 备份文件或
Apple ID 凭据改名当作远程记录。固定 CLI 的 `rppairing pair` 通过 USB
CoreDeviceProxy 创建所需记录；全局 `--pairing-file` 是另一条 TCP/Lockdown
provider 的输入，不是这里的输出参数。[1], [2]

## 1. 准备 Windows 和 iPhone

1. 在可信的 Windows 电脑上安装 Apple 提供的 iTunes 及其移动设备组件。
   这是 `idevice_pair` 固定版 README 指定的 Windows 前置条件。
   Apple 当前也提供 Apple Devices App；它能识别手机不等于本指南已验证该组合
   对第三方 usbmuxd 客户端兼容，遇到问题先按所选工具的前置条件核对。[3], [4]
2. 用支持数据传输的 USB 线连接，解锁 iPhone 并停留在主屏幕。用户本人在电脑
   和 iPhone 上处理“信任”提示、设备密码等系统确认。先确认手机在 Apple
   Devices / iTunes 中正常出现。不要把密码、配对 PIN 或记录内容发给模型。[4]
3. 在电脑上选一个只由自己管理、没有主动开启云同步的临时目录保存记录。
   后文示例使用 `%LOCALAPPDATA%\DSH-Pairing`。记录含私钥；不放入代码仓库、
   工单、聊天附件、日志、截图或诊断包。导入 DSH 不会替你删除电脑和文件提供器
   中已有的原始副本。

这里的 Apple USB 服务和手机自用的 VPN / 隧道路由是不同前置条件。Windows
生成文件成功，不会自动配置 iPhone 上的 VPN，也不证明 DDI 或输入服务可用。

## 2. 推荐步骤：固定 CLI，经 USB 生成

### 下载与核对

从官方 [idevice v0.1.68 release][5] 下载
[`idevice-tools-windows-v0.1.68.zip`][6]，不要从不明重打包站点取程序。
本轮实际下载的 ZIP 为 4,379,786 字节，SHA256 与 GitHub release asset 的
digest 相同：

```text
1c15e627652db1bc7c68f3d32675be07238b75282b510cd5828e9f4bec692a2f
```

在 PowerShell 中对自己下载的 ZIP 核对：

```powershell
Get-FileHash .\idevice-tools-windows-v0.1.68.zip -Algorithm SHA256
```

解压到例如 `C:\Tools\idevice-v0.1.68`。该官方 ZIP 实际包含
`idevice-tools.exe`、`idevice_id.exe`、`pair_host.exe`、`pair_apple_tv.exe` 和
`iproxy.exe`；本指南只需要前两个。发布 tag 对应提交
`d32c8189c51c2789496b0768039419c3705498c3`。其中 CLI 的 `main.rs`、
`rppairing.rs` 和 `tools/Cargo.toml` 已逐字节比对，与 DSH 固定依赖提交
`3854a5df4a5a6dee71ffce4d8befc2ea356a8065` 中这三个文件完全相同。
这项比对只证明命令定义和这些文件相同，不是整个依赖树或 Windows 运行验证。

### 选设备，指定输出文件

在已解压目录打开 PowerShell：

```powershell
Set-Location C:\Tools\idevice-v0.1.68
$env:RUST_LOG = 'off'
.\idevice-tools.exe --version
.\idevice_id.exe
```

最后一条列出 usbmuxd 看到的设备；自己从中取目标 iPhone 的 UDID。
`idevice_id.exe` 不带 `-l` 会列出后退出；本版 `-l` 是持续监听，不是一次列表。
日志等级关闭只抑制 tracing；工具自身仍可能输出状态和错误，不要发布整段输出。

下列 `替换成目标设备的UDID` 必须由用户替换；输出必须是一个**尚不存在**的新文件，
防止把上次留下的文件误认为本次配对成功：

```powershell
$deviceUDID = '替换成目标设备的UDID'
$pairingDir = Join-Path $env:LOCALAPPDATA 'DSH-Pairing'
New-Item -ItemType Directory -Force -Path $pairingDir | Out-Null
$pairingOut = Join-Path $pairingDir 'dsh-remote-pairing.plist'
if (Test-Path -LiteralPath $pairingOut) {
  throw '输出文件已存在；请选择新文件名，再重新执行。'
}
& .\idevice-tools.exe --udid $deviceUDID rppairing pair 'DSH-Windows' $pairingOut
if (-not (Test-Path -LiteralPath $pairingOut -PathType Leaf)) {
  throw '没有生成新记录；不要继续导入。'
}
$pairingSize = (Get-Item -LiteralPath $pairingOut).Length
if ($pairingSize -le 0 -or $pairingSize -gt 65536) {
  throw '记录大小不符合 DSH 的导入边界。'
}
```

`DSH-Windows` 是电脑的显示名称，最后一个**位置参数**是完整输出路径；不要改成
不存在的 `--output` 参数。保持手机解锁，根据屏幕提示由用户本人确认。成功路径
会显示保存成功的状态。上述大小检查只是避免空文件或明显错误输入；真正的
格式、密钥对应关系和连接有效性仍由 DSH 导入及连接检查验证。[1]

**两个已经从源码确认的限制：**本版 `rppairing pair` 的若干失败分支只是打印
错误后返回，因此 `$LASTEXITCODE == 0` 单独不足以证明成功；本版
`rppairing tunnel <文件>` 会忽略那个可选文件参数，建立的是 USB tunnel，
不能拿它来证明导出的 Remote Pairing 记录有效。不要用这些结果代替导入后的
真实配对验证。[1], [2]

## 3. 可选图形工具：先了解固定版的自动动作

官方 [`idevice_pair v1.1.0`][7] 提供 Windows x86_64 可执行文件，固定源码提交为
`0f8b8d1d1e3b5afba6e5961f3af6872b2b98d8d0`。GitHub release API 给出的
`idevice_pair--windows-x86_64.exe` 大小为 40,419,840 字节，digest 为：

```text
a47bc9ef999d086b402fb2c9b3bd9cbed6fceb8718ad36b098b5ed32abbbe53b
```

这里记录的是官方发布元数据，**本轮没有下载或执行这个 EXE**。Windows ARM64
及 x86_64 仿真组合也未验证。

启动前需知道：这个固定版在选中设备后，会在 USB 连接上自动尝试开启无线调试；
若查询到没有开发者镜像，还会自动尝试挂载它内置的 Personalized DDI。
只有一个设备时，应用会自动选中它。这些动作发生在 `Inspect` 路径，不能把它
当成纯只读检查；它也不采用 DSH 本轮的“用户先明确点挂载”规则。
如果不希望这些自动动作，使用前面的 CLI USB 步骤。[8], [9]

如果接受这些自动动作，图形步骤是：

1. 从官方 release 下载后运行，连接并解锁手机，选择正确设备。
2. 在 **Pairing file** 中选择 **Remote pairing**，USB 路径点 **Create**。
   不选 Lockdown。必要的信任提示由用户本人在设备上确认。
3. 点 **Validate**；本固定版的 Remote 路径实际调用 pair-verify，显示
   **Works** 才表示该工具完成了这一检查。它仍不证明 DSH 的 VPN 路由可达。
4. 点 **Save to file…**，手动选择前述私有目录。Remote 默认文件名是
   `pairingFile.plist`，可改为容易识别的新文件名。
5. 使用 DSH 的导入入口完成下一节。第三方工具的“Send to an app”列表不作为
   DSH 的导入合同；不要自行往 DSH 容器塞文件。工具的 **Contents** 会显示记录
   原文，不要把该区域截图或复制到诊断材料。[3], [10], [11]

## 4. 导入到这台 iPhone，并自行选择保存方式

用自己已有的受信任文件传输方式，将 `.plist` 送到 iPhone 系统文件选择器可以
访问的位置；本指南不新增上传服务、不替用户传输凭据。打开 DSH 的手机操控
设置，使用导入配对记录的入口，选择这个文件，然后由用户明确选择：[12]

| 选项 | 本轮实现的保存语义 |
| --- | --- |
| 记住在这台手机上 | 使用 `WhenPasscodeSetThisDeviceOnly` 且关闭同步；要求设备设有密码，不随备份或 iCloud Keychain 同步。没有设备密码或写入失败时不静默降级。 |
| 只用这一次 | 只在本次 App 进程内保留，进程退出后需重新导入；不会偷偷留下一个可在下次启动恢复的旧“记住”记录。 |

App 接收的原文件最多 64 KiB，检查 plist 格式、32 字节公私钥、密钥对应关系、
identifier 和可选 `alt_irk`，再规范化。**导入成功只代表记录结构合格**。
保持手机解锁，在 DSH 中执行连接检查，分别查看 VPN/配对/Lockdown/开发者服务的
实际状态；需要 DDI 时再明确批准下载及挂载。普通检查不自动挂载。
这一步也不授权点击、输入、相册或文件访问；那些仍需各自开关和实际调用批准。

Apple 对 `WhenPasscodeSetThisDeviceOnly` 这一具体类别说明了不备份、不同步及
去掉设备密码后失效的语义；不能把所有名称含 `ThisDeviceOnly` 的类别都称为
“不进备份”。[13] DSH 的撤销入口删除本 App 持有的记录并使当前使用失效，
不等于撤销电脑端的 USB 信任；电脑信任的管理遵循 Apple 的系统步骤。[4]

## 5. iOS 26.x / 27 和 DDI 的边界

| 情况 | 有源码支持的做法和限制 |
| --- | --- |
| iOS 26.x 首次生成记录 | 使用上述 USB 路线；`idevice_pair` 固定 README 将 USB Remote Pairing 下限写为 iOS 17.4。本文没有验证 26.x 各小版本。 |
| iOS 27 设备主动在局域网首次配对 | 固定 GUI 的 **Pair over Wi-Fi** 和 CLI 的 `pair_host.exe` 有此路线；电脑与设备须同网且能发现 mDNS。设备选择电脑并输入工具显示的 PIN，必须由用户本人操作。Windows 防火墙/网络条件及实机流程未测，USB 仍是本指南的首选。 |
| 已经通过 USB 信任后在 Wi-Fi 上看到设备 | 与“完全无 USB 的首次配对”是不同情形；不能据此宣称 26.x 支持 iOS 27 的设备主动配对流程。 |
| 配对成功但开发者服务不可用 | 另查 Developer Mode、路由、DDI 与设备版本/芯片匹配；重新导出文件不是这些问题的通用修复。 |
| XCTest 增强 | 本文只解决配对文件生成，不生成、签名或安装 xctrunner；增强模式另按其安装引导准备。 |

若维护者要验证 iOS 27 的 CLI 设备主动配对，固定源对应的命令形态是：

```powershell
.\pair_host.exe --name 'DSH-Windows' --out $pairingOut
```

继续沿用前文“输出文件必须不存在”的约束。它监听并广播一台可配对电脑，在设备
选择它之后显示 PIN。当前程序每次启动生成新的 host identity；不要声称关闭
程序后还保留同一个发现状态。GUI 无线 onboarding 记录在工具进程内，需在退出前
保存为文件。以上是固定源码/README 的能力说明，**不是 Windows 27 实测记录**。[3], [14]

本轮 DSH 的 DDI 策略也不等同于“iOS 17 以后全部一种镜像”：只有 iOS major
至少 27 且服务明确提供 `CryptexInstall` 时选择固定 Cryptex 资产；其余路线
要求 Personalized manifest 与 board/chip 匹配，服务或身份不支持就拒绝。
这是一项保守的源码策略，不是对所有 26.x / 27 设备的兼容承诺。
Windows GUI v1.1.0 的内置 Personalized 挂载逻辑不能替代这个判断。[9], [12]

## 6. 主线验收还需取得的证据

这份说明的验收状态是 **源码与发布物核对完成，Windows / iPhone 待实测**。
下一轮真实验证至少记录：Windows 版本/架构、工具固定版本、Apple 驱动或服务
版本、iPhone/iOS 版本；生成一个新文件并完成 DSH 导入和实际配对检查；分别验证
“记住”和“只用一次”的进程重启行为。只记录阶段、稳定错误码和是否成功，不收集
配对内容、私钥、PIN、剪贴板或完整工具 debug 日志。

## 依据

- CLI 命令、provider 和 iOS 27 host 路线：固定源码 [1]、[2]、[14]。
- Windows 官方发布及实际校验的 CLI ZIP：[5]、[6]、[7]。
- 图形界面的要求、自动动作、验证与保存：[3]、[8]、[9]、[10]、[11]。
- Apple 的设备信任与钥匙串类别说明：[4]、[13]。
- 本轮 DSH 原生合同及未验证范围：[12]。

[1]: https://github.com/jkcoxson/idevice/blob/3854a5df4a5a6dee71ffce4d8befc2ea356a8065/tools/src/rppairing.rs
[2]: https://github.com/jkcoxson/idevice/blob/3854a5df4a5a6dee71ffce4d8befc2ea356a8065/tools/src/main.rs
[3]: https://github.com/jkcoxson/idevice_pair/blob/0f8b8d1d1e3b5afba6e5961f3af6872b2b98d8d0/README.md
[4]: https://support.apple.com/en-gb/109054
[5]: https://github.com/jkcoxson/idevice/releases/tag/v0.1.68
[6]: https://github.com/jkcoxson/idevice/releases/download/v0.1.68/idevice-tools-windows-v0.1.68.zip
[7]: https://github.com/jkcoxson/idevice_pair/releases/tag/v1.1.0
[8]: https://github.com/jkcoxson/idevice_pair/blob/0f8b8d1d1e3b5afba6e5961f3af6872b2b98d8d0/src/backend/worker.rs
[9]: https://github.com/jkcoxson/idevice_pair/blob/0f8b8d1d1e3b5afba6e5961f3af6872b2b98d8d0/src/backend/ddi.rs
[10]: https://github.com/jkcoxson/idevice_pair/blob/0f8b8d1d1e3b5afba6e5961f3af6872b2b98d8d0/src/backend/pairing.rs
[11]: https://github.com/jkcoxson/idevice_pair/blob/0f8b8d1d1e3b5afba6e5961f3af6872b2b98d8d0/src/ui/device_page.rs
[12]: ../phone-self-runner/README.md
[13]: https://support.apple.com/en-nz/guide/security/secb0694df1a/web
[14]: https://github.com/jkcoxson/idevice/blob/3854a5df4a5a6dee71ffce4d8befc2ea356a8065/tools/src/pair_host.rs
