# Android 与 OHOS 的远程网关心跳

ohos-api-gateway-idle.diff 保留历史文件名。该片现用于两个目标，沿用已验证的实现。在准入的 WebSocket 连接之间共享一个定时器，最后一个客户端关闭时清除它。下次连接成功时重新按当前设置启动。活动连接的 ping 周期、无响应终止界限、服务结束和未准入连接的处理沿原协议。

默认周期为2秒。进程继续运行、已接过客户端且目前没有客户端时，每空闲1分钟省去30个检查空集合的定时回调。受控时间的计数位于 runtime/tests/ohos-api-gateway-idle.test.mjs。现有 runtime/tests/ohos/api-gateway-idle.test.mjs 用真实 Cordis、WebServer 和 WebSocket 检查多连接、重新连接及服务退役，完整已打片前缀可供两个目标运行。
