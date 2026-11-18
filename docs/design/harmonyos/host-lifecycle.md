# Ark 前后台与本机 lifecycle 控制

适用基底：530f183906be2a218b1b09000400e01c9a572dba。交付主 patch.diff 从纯基底直接应用，包含37号 lazy-only 的同字节前提；已经应用37时，仅用 lifecycle-only.diff。两种路径恢复到同一最终源码，不能叠用。生命周期增量只改鸿蒙入口、鸿蒙运行时模块及其测试，不改 Android、Flutter 界面、Node 构建或宿主 CMake。验证状态以交付包内精确补丁 SHA 和独立报告为准。

## 状态与调用

UIAbility 的 `onForeground`、`onBackground`、`onDestroy` 更新 RuntimeController 内存观察。当前 Ability 有所有权；旧实例迟到的后台或销毁回调不得盖掉新实例的前台状态。引擎尚未启动时不加载原生库、不读文件、不查询权限、不建立网络请求。Node 真正 ready 后，现有 collect 轮询取宿主提供的固定 IPv4 loopback 地址和启动凭证，发送最新观察。

每次观察的 `revision` 单调增加。引擎地址或启动凭证变化会退休旧 transport。前后台新事件、stop 或引擎结束撤销上一请求和重试定时器；已抵达 Node 的旧请求仍可能执行，因此后端也按 revision 拒绝倒退。不能用 HTTP Promise 的取消代替后端时序检查。

认证沿用当前运行时的 BrowserAuth：先用宿主启动凭证访问 `/?token=...`，禁止自动重定向，要求303和一个合法签名 `dsh-auth-*` cookie，再向 `/dsh-go/v1/lifecycle` 发 JSON：

```json
{"operation":"host","revision":2,"foreground":false,"computePermission":"unknown"}
```

目标固定为 `http://127.0.0.1:<port>`，端口1至65535，只接受宿主给的地址，不接收Dart指定URL。关闭系统代理和缓存；连接超时1秒，读取超时3秒，响应上限65536字节。使用公开 `@ohos.net.http` 的 REDIRECTION 拦截器，安装失败时不发请求。401会丢弃旧cookie，下次重试重新认证。日志和UI只暴露固定错误码或固定中文提示，不传播原始网络异常、凭证或响应体。

成功确认只携带固定数量字段：v、host、closed、blocked、paused、confirmedPause、controlVersion；不会携带所有历史工具调用。Ark核对版本、revision、foreground、computePermission及closed/blocked。旧请求的迟到确认与错误不能盖掉新观察。

这一接口复用已有登录所有者权限，没有新增只能由原生宿主持有的身份凭证。已通过既有认证、具备同等运行时控制权限的客户端也可发送host操作。不能把它称为原生来源证明或对运行时所有者的安全边界。实际签名cookie、Host/Origin检查和失效凭证拒绝已在Linux用固定生产认证代码及真实套接字验证；OH网络栈行为仍待设备核实。

## 暂停原因必须分别保留

手动暂停与宿主后台观察是两个原因。只有最新宿主处于前台，且没有手动暂停，才能释放工具准入门。手动resume仅释放手动原因；宿主前台事件仅释放后台原因。原先两个路径互相覆盖会导致后台继续写文件，回归证据保存了真实文件效果、日志与固定AgentLoop/ToolRuntime调用。

pause/resume归属日志新增 `manualPaused` 布尔字段，仍使用既有版本。旧日志没有此字段时，把旧pause保守视作手动暂停。重开恢复已持久化的手动意图；host观察不当成重启后的系统事实，要等当前Ability重新上报。重复host请求等待对应控制写入后，重新读取当前状态，不能返回过期的paused快照。最新控制版本决定准入门是否能开启。

该门约束后续工具准入，不撤销已经发生的副作用，也不自动重放prompt或工具。已在运行的工具继续遵守原O8取消、预算、边界记录与恢复规则。Ark回调到HTTP确认之间存在异步窗口；系统可以在请求送达前冻结整个App，所以本功能不承诺在每次后台切换瞬间就停止所有Node执行。

## 重试与既有Dart消费端

失败时只重试同一个幂等host观察，载荷在同revision期间保持不变，退避1、2、4、8、16、30秒，此后上限30秒。仅一个定时器；新观察重置退避并退休旧请求。每次重试不重新查询权限，否则同revision会隐含不同载荷。下一次真正前后台观察会重新查询。

当前失败通过既有status事件的顶层error和notice事件显示“前后台状态尚未同步，本机任务可能仍在暂停或运行；正在重试。”。连续同类失败不重复发notice；轮询和正在进行的重试保持失败可见，只有当前确认或引擎结束才清除。Node phase仍是实际宿主状态，不能伪装为引擎退出。另附嵌套lifecycle诊断字段，但没有依赖Dart读取这组新字段：真实未修改RuntimeStatus模型已验证能读顶层error。没有修改Flutter界面，也没有运行Flutter widget测试。

## computePermission 的精确含义

这是计算型长时任务的只读前置资格观察，仍保持 `background.policy = may-freeze`：

| 查询结果 | 上报 | 能推出的结论 |
| --- | --- | --- |
| 自应用KEEP_BACKGROUND_RUNNING明确未授予 | denied | 一个必要前提不满足 |
| 普通权限已授予，MODE_TASK_KEEPING的isModeSupported返回true | granted | 本次资格检查通过；没有创建后台任务 |
| 普通权限已授予，模式检查明确false | denied | 本次模式资格不满足 |
| 系统能力缺失、异常、未知返回值或9800005 | unknown | 无足够证据判定，不冒充用户拒绝 |

没有请求权限，没有添加manifest权限或backgroundModes，没有调用startBackgroundRunning。granted不表示正在保活、获得不间断CPU或免于系统冻结。公开SDK26.0.0.38的两个声明及官方固定源码在交付research/background-permission内逐SHA保存；实现依据如下：

- [固定公开SDK声明](https://github.com/openharmony/interface_sdk-js/blob/8a86234f0d542e5062e24e948652f5a484d90904/api/@ohos.resourceschedule.backgroundTaskManager.d.ts)。实际工具包已过滤系统API，生产代码只用其公开子集。
- [固定官方长时任务说明](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/task-management/continuous-task.md)。计算模式、ACL、Ability配置和实际任务创建是不同前提。
- [权限查询实现](https://github.com/openharmony/security_access_token/blob/17d88bfb36bea6c9370ba919ac41a22d16dd66b3/frameworks/js/napi/accesstoken/src/napi_atmanager.cpp)。0/-1区分获授与未授予，异常不等同拒绝。
- [模式资格服务实现](https://github.com/openharmony/resourceschedule_background_task_mgr/blob/cff2ff475e3885ee814651f6a13d7f8a5782efdd/services/continuous_task/src/bg_continuous_task_mgr.cpp)及[内部错误定义](https://github.com/openharmony/resourceschedule_background_task_mgr/blob/cff2ff475e3885ee814651f6a13d7f8a5782efdd/frameworks/common/include/bgtaskmgr_inner_errors.h)。9800005不能单凭错误码归为用户拒绝；资格查询不创建任务。

## 验证与设备门

Linux测试运行生产ETS方法体，只替换不可用的平台模块和计时器边界；真实公开ArkTS编译另走check-arkts。HTTP测试用实际固定BrowserAuth/HostConnectionService、真实loopback、原生flock和fsync；这些不等同手机的@ohos.net.http实现。冷重开9项是实际关闭后重新打开日志，不冒称SIGKILL。O8原有冻结与严格回归另列，不能用此处新测试顶替。

设备必须核对：UIAbility事件顺序及旧实例迟到；后台/锁屏/低电量冻结前后；无本机引擎时NativeHost保持未加载；303/Set-Cookie形状与重定向拦截；destroy后的真实网络结算与FD回收；签名cookie过期重认证；权限与MODE_TASK_KEEPING查询在无ACL/有ACL及配置变化时的结果；失败提示在现有界面的实际展示与清除；后台与手动暂停重叠时真实工具副作用和预算。未测层一律NOT_RUN_DEVICE，不从Linux运行时间推断设备延迟上界。
