# 切回目标后的短等待与画面复核

`IOSPhoneTaskConsent.waitForTarget` 在用户切出 DSH Go、实际 PiP 保活成立后，
等待至少 750 ms，再把控制交给现有 CoreDevice/XCTest 的新帧复核。
这是 ADDENDUM-07 #5 允许的“有上限的短等待”方案；没有声称连续两帧相同，
也没有把经过 750 ms 当作画面、焦点或输入安全性的证明。

等待用现有睡眠计入的连续时钟，最晚准入时间取本次请求剩余时间与 45 秒的
较小值；原 request 的墙钟到期条件同时保留，系统改时不会延长这段连续时钟
预算。自动 PiP 从第一次观察到后台开始仍只有 3 秒启动机会。PiP 首次成立后
才开始 750 ms 等待，前台时间和等待 PiP 启动的时间不计入它。

每 50 ms 轮询实际后台、protected data、当前 owner/代次、资格和 PiP 保活；
任何被观察到的锁屏、退出后台、保活丢失、取消或资格失效都会拒绝。时钟缺失、
非有限数、倒退或达到期限也拒绝。系统调度可能晚于一次预定唤醒；恢复调度后
仍先检查期限，不因计时器曾等待完就放行。轮询不能证明采样之间每一瞬间都满足
条件，这不是实时调度保证。

该等待器只持有时间与状态，不读取/消费屏幕观察，不生成动作授权。等待结束后
仍由原路径取得新截图，核方向、尺寸、绑定及完整解码像素；之后才允许实际动作。
剪贴板方案二次切回目标也调用同一入口，产生一个新的等待器，不沿用第一次的
等待结果。逐次原生批准及其他准入条件不变。

## 为什么没有排除一个推测的 PiP 矩形

本补丁不排除 PiP 区域，继续完整像素比对。Apple 的 sample-buffer delegate
[`pictureInPictureController(_:didTransitionToRenderSize:)`](https://developer.apple.com/documentation/avkit/avpictureinpicturesamplebufferplaybackdelegate/pictureinpicturecontroller(_:didtransitiontorendersize:))
报告的是内容渲染像素尺寸；其参数没有全屏坐标原点。尺寸本身不能确定一个
全屏矩形的位置。当前 `PetOverlayPictureInPicture.sourceView` 是 App 内的
内容源，App 内 frame 也不能被当成系统浮窗在其他 App 上的矩形。

作为相关但不同的 video-call API，Apple 的
[`activeVideoCallSourceView`](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class/activevideocallsourceview)
用于判断源视图可见性/布局与进出 PiP 的动画；这不提供当前 sample-buffer
系统浮窗的全屏位置。本补丁没有找到足以绑定到当前截图的公开位置依据，因此
不硬编码角落、不根据源视图猜位置，也不把 API 文档未提供这一值扩大为“所有
未来系统都不存在这种能力”的断言。

尚无本工程真实 CoreDevice 截图可证明系统 PiP 一定包含或一定不包含在结果内。
因此 PiP 动画、应用动画、闪烁光标或时钟仍可能使严格复核保守拒绝。750 ms 是
待真机校准的操作预算，不能宣称解决所有动态画面的拒绝。若后续要屏蔽区域，
需要可验证的截图与浮窗坐标绑定、遮挡风险规则和相应真实平台测试。

## 验证边界

既有 `IOSPhoneTaskConsentTests` 新增 7 个方法直接调用生产
`IOSPhoneTargetWait`，覆盖首次后台不立即准入、PiP 启动、750 ms 阈值、45秒/请求
期限、失效状态、异常时钟与二次回目标新计时。它们保留在现有 PBX、Runner scheme
和 Mac CI 已选择的测试类中。当前没有 Swift/Xcode，新增 **7 authored / 0 executed**；
全部 Apple 编译、UI 切换、PiP、截图和真实输入均 UNRUN。
