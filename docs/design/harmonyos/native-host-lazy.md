# P2 懒加载：56e682b 基底增量

本版是56e682bf76368074e14c4d9be02db53cc6616c4b上的小增量。该基底已合26、27、28、31；保留主线Host默认服务、原生实现、host-adapter夹具、O8和组成修复。本增量仅迁入34包中实际仍缺的懒加载及文件通道归属变更，不再重复整包34、26或27，不改C++、CMake、node工具链、Android或Flutter UI。

## 首次加载发生在何时

此前 RuntimeController、FilesMediaPlugin 在模块顶层导入 libdsh_host.so，Entry注册即到达这些模块。根据追加7，宿主的NEEDED已包含约82MB libnode；因此这些静态导入会令只用远程主机的用户也请求本机库。82MB来自主线报告，不是本次手机内存测量。

NativeHost.ets只保留type import。peekNativeHost与nativeHostState在未加载时返回空引用或idle，不访问动态导入。guestRoot、getStatus、事件订阅、安装、日志、诊断和未启动时stop均不请求原生模块。第一次start或需安全openUserFile的文件操作才await同一个loadNativeHost Promise。并发请求共享一次import；加载失败保留错误并允许重试，不把失败当作Node已消费。

动态import解析后取default对象；default缺失时返回ohos_native_unavailable。这个分支有明确边界夹具反例，不声称已在设备观察到缺库的具体返回方式。首次真正load后的状态来自实际native对象，不把空闲默认状态盖住已经运行的宿主。

start在await加载结束后再次核startCancelled，封闭用户在加载期间stop而随后仍启动的交错。这里取消的是尚未进入native的start；已经开始的Node停止仍等待真实终态。文件打开在await之后重验原窗口generation，再用受控根与相对路径打开，避免旧窗口加载完成后继续打开文件。

## 文件通道重挂修复

真实ETS反例：一个FilesMediaPlugin实例重新附着新Engine时，旧Ability未退休；迟到旧Engine detach又能清掉新Engine。新增明确engineBinding，重新附着时退休旧状态，两个MethodChannel handler捕获其本次binding，旧handler返回cancelled，旧detach不影响当前绑定。新Ability尚未到达时不借用旧Ability。

测试前这两项0/2，修后完整文件通道22/22。该修复只证明实际方法体的归属门，不代表系统窗口或Flutter进程生命周期已经在手机上观察。

## 实际验证

34既有证据与本增量复跑命令均覆盖：NativeHost 5项、Runtime通道32项、托管技能19项、FilesMedia22项，共78项，零skip/TODO；系统模块和Flutter/native加载边界明确替身，文件IO及安全FD opener是真实Linux执行。旧静态图反例0/1，修后无顶层native值导入；并发一次加载、失败重试、缺default、远程通道不加载、加载中stop、旧Engine/Ability与原日志/技能/安装回归均保留。

严格ArkTS由公开SDK26.0.0.38、hvigor6.26.9和release embedding 1.0.0-e034e7a293实际构建。每轮独立工程，编前编后核每个ETS及native声明SHA，HAP内ABC必须与提取ABC相同，另附反汇编。NativeHost.loadNativeHost中实际出现dynamicimport指令；类型导入不形成原生值导入。私有编译夹具只补齐基底缺失的icon资源，字节等于原foreground.png，产品资产不改。正式门以交付中该新基底精确日志为准。

34的2c组合曾附26中的原生布局历史证据；本增量保留新56e基底三份C++原字节，不把34的旧C++后像覆盖回去。主线56e已复制lifecycle目录；真实最终组成物与Host入口一致性门由后续组成包独立验证，本版不假称完成。目标Clang23/静态libc++、改名NAPI同进程加载、真实HAP安装路径和设备驻留成本仍需主线/设备验证。

## 集成和设备门

在原始56e基底上直接应用本增量；不要重复叠31/O8/26/27/34。Worker和新组成按各自独立包的依赖接入。后续Share/NativeMedia等如需安全opener，复用同一个loadNativeHost；不能再在Entry可达模块顶层值import libdsh_host.so。HMS不在本包，另包保持UNCOMPILED_HMS。

设备验证需观察：冷启动只连远程时进程映射是否没有libdsh_host/libnode；首次本机start或安全文件操作才映射；并发首次需求只装载一次；加载失败重试不会消费Node；加载期间stop不会迟到启动；Flutter重挂和真实Ability变化不会复用旧上下文。Linux逻辑与字节码证据不能替代这些测量。公开动态native模块约定见 https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/arkts-import-native-module 。
