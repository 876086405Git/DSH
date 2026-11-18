# 第一次上真机

从 Linux 把 HAP 装到鸿蒙手机或平板上，不需要 Mac 和 DevEco Studio。放行条件和完整检查项见[真机验证清单](device-validation.md)，这里只讲怎么装上、怎么把现象带回来。

目前还没有人走通过这一页。走通或卡住后，把实际结果改进来。

## 准备

| 项 | 要求 |
|---|---|
| 设备 | HarmonyOS 7.0（API 26）或更新，手机或平板。这版 Flutter 引擎的硬要求，低了装不上。在 `设置 > 关于本机` 看版本 |
| 账号 | 华为开发者账号。实名后调试证书 180 天，未实名只有 14 天，都不能续期 |
| 工具 | OpenHarmony SDK 和 JDK 17（见 `tooling/ohos/check-arkts.sh`），里面有 `hdc` 和 `hap-sign-tool` |
| 包 | `tooling/ohos/check-arkts.sh --full` 打出的未签名 HAP。第一次用不带 `--distribution` 的 |

## 步骤

1. **打开调试。** `设置 > 关于`，连点软件版本 7 次；`设置 > 系统 > 开发者选项` 里打开 USB 调试；连上电脑，在设备上点允许。
2. **看设备。** 确认 API 版本，记下 UDID：

   ```bash
   tooling/ohos/device.sh info
   ```

3. **生成密钥。** 只需一次，换了密钥要重新申请证书：

   ```bash
   tooling/ohos/device.sh keygen
   ```

   密钥和密码在 `~/keys/dsh-ohos/`，不进仓库，也不要发给任何人。

4. **在 AGC 上申请。** 登录 AppGallery Connect：
   1. 创建 HarmonyOS 应用，包名 `ccchimneyyy.dsh.go`；
   2. 登记设备 UDID；
   3. 上传 `debug.csr`，申请调试证书，下载存为 `~/keys/dsh-ohos/debug.cer`；
   4. 申请调试 Profile，勾选设备，下载存为 `~/keys/dsh-ohos/debug.p7b`。

   **第一次先别申请受限权限，也别用带权限的包：声明了受限权限的 HAP，Profile 里没有对应 ACL 就装不上。** 先把下面的前 5 项走通，再回来申请 `READ_PASTEBOARD`、`KEEP_BACKGROUND_RUNNING_SYSTEM`，换 `check-arkts.sh --full --distribution debug` 打的包，才能试粘贴和长期后台。文档说审批前可得一个有效期较短的临时 Profile。

   `PUBLISH_AGENT_REMINDER` 也只进带权限的包：SDK 的权限表写的是 normal、system_grant，但手机上的代理提醒要先在 AGC 开通服务并重签 Profile。没带这个权限的包里，AI 设闹钟或计时器会收到系统没有接受提醒。

5. **签名并安装。**

   ```bash
   tooling/ohos/device.sh install entry-default-unsigned.hap
   ```

6. **出问题时收日志。** 复现时运行，发给别人前先看一遍，里面可能有对话内容：

   ```bash
   tooling/ohos/device.sh log 120
   ```

## 第一次要看什么

按这个顺序，前一项不过，后面的结果不算数：

| # | 看什么 | 没过说明 |
|---|---|---|
| 1 | 能不能装上 | 2026-11-06 在 HBN-AL00（HarmonyOS 7.0.0.111）上装上了，`compileSdkType` 是 OpenHarmony 也不拒；被拒先看签名和 Profile 里的包名、UDID |
| 2 | 能不能打开，首屏出来没有 | 闪退多半是原生库加载，`libnode.so`、`libc++_shared.so` 从没在目标设备上加载过 |
| 3 | 远程主机模式能不能连上、聊天 | 不碰本机引擎，先证明 Flutter 这一层是好的 |
| 4 | 存 API key 重启后还在 | HUKS 和凭据库 |
| 5 | 本机引擎：解包多久、能否启动、第一轮对话 | 运行时安装和 Node，最大的未知 |
| 6 | 回复中切到后台再回来 | 挂起后回合能否续上，决定暂停提示和后台页的说法 |
| 7 | 手感：转场、键盘、振动、边缘返回、中文输入 | 这些只能在设备上调 |
| 8 | 分享、语音、PDF | 只对照占位声明编译过，最可能有问题 |

平板上还要看：WebView 默认多进程（手机是单进程），一个渲染进程崩溃时插件岛和页面的表现；宽屏布局。

## 看动效

开发者选项里打开「显示刷新频率」，另开一个终端，只收动效相关的行，里面没有对话内容：

```bash
tooling/ohos/device.sh motion 300
```

下面的数字来自引擎源码，还没在设备上看过。先开日志再启动 App，设置 → 性能 的刷新率留在「自动」。启动时应有一行 `LTPO enabled`，没有的话后面都不算数。

| 操作 | 屏幕角上应该看到 | 日志 |
|---|---|---|
| 快速滑动列表再松手 | 120，停下约 0.8 秒后回落 | `DshFrameRate` 的 `start: active`，之后 `stop: inactive` |
| 点一下升起 Sheet | 动画全程 120 | 同上 |
| 进入页面再返回 | 120 | 同上 |
| 键盘弹出和收起 | 120 | 同上，另有 `DshKeyboard` 各行 |
| 流式输出，不碰屏幕超过 3 秒 | 仍是 120。之前会掉到 60 | 不出现 `stop` |
| 停在输入框，光标闪，不碰屏幕 | 不是 120 | 键盘停稳后没有新的 `start` |
| 切后台或锁屏 | | 立刻 `stop: background`，之后不再有 `nativeLTPODispatchHighFrameRate`。这一项不过就是定时器漏了，会烫手费电 |

`SetExpectedFrameRateRange` 只在变化时打印，`{30,120,120}` 是要 120，`{0,0,0}` 是交给系统，`{30,120,60}` 是最后一次调用 3 秒后要 60。运行时每秒约 12 行 `nativeLTPODispatchHighFrameRate` 是正常的。`SetExpectedFrameRateRange` 也跟着一直刷，说明屏幕没到 120，先看系统的屏幕刷新率设置和省电模式。

再看这些：

- **帧缓存。** 同一个手势（手指慢拖列表，再快速滑动）开关各做几次，比跟手和顺滑。立刻生效，不用重启；关掉后重启一次，确认还是关的。
- **键盘。** 记下 `DshKeyboard` 的 `willShow`、`willHide` 里的 `animated` 和 `config`（曲线、时长、参数），以及 `height`、`avoidArea` 靠近 `will` 还是 `did`，也就是高度在动画开始还是结束时报告。设备不支持时是一行 `no keyboardWillShow`。`keyboard_motion.dart` 的 250 ms 是猜的，按这些改。
- **左边缘右滑。** 在二级页面试，记下是 Flutter 返回了，还是被系统拿走了。
- **第一次的一帧卡顿。** 全新启动后第一次按下带水波的按钮，第一次把列表拉过头，和第二次比。卡一帧多半是加载着色器（`InkSparkle`、拉伸）。
- **按住不动再拖。** 手指停住超过约 0.8 秒再拖动，开头约 3 帧可能不到 120，这是已知代价，看能不能感觉到。
- **最高。** 切到「最高」用几分钟看发热，再切回。

动效和模糊中途消失时，先别怀疑代码，先看是不是热了：设置 → 性能 的页脚写着「正在减少效果，降温后恢复」，日志有 `stop: thermal`，诊断包 `performance` 一节（`performanceDiagnostics`）的 `thermal.level`、`thermal.lightweight` 和 `defaults.lightweight` 能确认。进入轻量后要连续凉 30 秒才恢复。如果默认的「自动」就能把设备烫到这里，要把这个结果带回来，它决定默认值还能不能这样定。

## 把设备还回去

```bash
hdc uninstall ccchimneyyy.dsh.go
```

然后在开发者选项里关闭开关，设备会重启。
